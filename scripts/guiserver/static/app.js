(() => {
  const qs = new URLSearchParams(location.search);
  let token = qs.get("token") || localStorage.getItem("pagerToken") || "";
  if (qs.get("token")) {
    localStorage.setItem("pagerToken", token);
  }

  async function api(path, opts = {}) {
    const headers = Object.assign({ "X-Pager-Token": token }, opts.headers || {});
    const res = await fetch(path, Object.assign({}, opts, { headers }));
    if (res.status === 401) {
      throw new Error("Unauthorized - open this page with ?token=YOUR_TOKEN once (see webui.sh --set-token on the device)");
    }
    return res.json();
  }

  async function run(script, args, { background = false, timeout = 60 } = {}) {
    return api("/api/run", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ script, args, background, timeout }),
    });
  }

  function showOut(el, result) {
    if (typeof result === "string") { el.textContent = result; return; }
    const lines = [];
    if (result.stdout) lines.push(result.stdout.trim());
    if (result.stderr) lines.push(result.stderr.trim());
    if (result.error) lines.push("ERROR: " + result.error);
    el.textContent = lines.join("\n") || "(no output)";
  }

  // BIG CHANGE: pairs with server.py's new /api/tail endpoint. Every
  // --background-launched action here (deauth, sniff, bluetooth flood/jam)
  // used to show a static "Starting..." message with NO further feedback
  // until you manually pressed its Status button - the exact "black box,
  // no visible progress" problem this whole toolkit's other UX fixes this
  // session were about (sniff.sh's own live-tail, PayloadRunner.sh's
  // --status). Polls the script's known log file every 1.5s and appends
  // only the lines that are actually new (never re-fetches the whole log),
  // same bounded-poll pattern the server-side endpoint itself uses - no
  // long-lived connection, nothing left running if you navigate away
  // (starting a new tail always clears any previous one first).
  const tailers = {}; // scriptName -> interval id
  function stopTailing(script) {
    if (tailers[script]) { clearInterval(tailers[script]); delete tailers[script]; }
  }
  const MAX_TAIL_LINES = 500; // cap growth for a long unattended engagement
  function startTailing(script, outEl) {
    stopTailing(script);
    let since = 0;
    tailers[script] = setInterval(async () => {
      try {
        const r = await api(`/api/tail?script=${encodeURIComponent(script)}&since=${since}`);
        if (r.lines && r.lines.length) {
          outEl.textContent += (outEl.textContent ? "\n" : "") + r.lines.join("\n");
          // Same "guard against unbounded growth over a long unattended
          // run" principle applied elsewhere in this toolkit (crash_logger's
          // ring-buffer handling, sniff.sh's watchers) - .out is visually
          // scrollable already (see style.css), but the underlying
          // textContent string itself had no cap, so a multi-hour tailed
          // session would keep growing this DOM node's text forever.
          const allLines = outEl.textContent.split("\n");
          if (allLines.length > MAX_TAIL_LINES) {
            outEl.textContent = allLines.slice(allLines.length - MAX_TAIL_LINES).join("\n");
          }
          outEl.scrollTop = outEl.scrollHeight;
        }
        if (typeof r.total === "number") since = r.total;
      } catch (e) { /* transient network hiccup - keep trying, don't stop the whole tail over one dropped poll */ }
    }, 1500);
  }

  // BUG FOUND AND FIXED (found via code review): every one of these attack
  // actions (deauth, bluetooth flood/jam/adv-spam, evil-twin clone) passes
  // "-y" to skip that script's own "only run this against networks/
  // devices you're authorized to test" confirmation - the CLI and payload
  // paths ALWAYS show that prompt first; the Control Panel silently
  // bypassed it entirely with no substitute, the one place in this whole
  // toolkit where that guardrail didn't exist at all. A plain native
  // confirm() before firing is the same authorization gate every other
  // entry point already has, just implemented for a browser button instead
  // of a terminal prompt.
  function confirmAuthorized(message) {
    return window.confirm(message + "\n\nOnly run this against networks/devices you are authorized to test.");
  }

  function btn(id) { return document.getElementById(id); }
  function val(id) { return document.getElementById(id).value; }
  function checked(id) { return document.getElementById(id).checked; }

  // Wraps a button's onclick body so a network error / timeout / dropped
  // connection surfaces in its output box instead of leaving the loading
  // message ("Starting...", "Scanning...") stuck forever with no feedback.
  function onClick(id, fn) {
    const b = btn(id);
    b.onclick = async () => {
      b.disabled = true;
      try {
        await fn();
      } catch (e) {
        console.error(e);
        const out = b.closest("section")?.querySelector(".out");
        if (out) out.textContent = "ERROR: " + (e && e.message ? e.message : String(e));
      } finally {
        b.disabled = false;
      }
    };
  }

  async function refreshBattery() {
    try {
      const r = await run("battery.sh", [], { timeout: 10 });
      document.getElementById("battery").textContent = (r.stdout || "?").trim();
    } catch (e) { /* ignore */ }
  }

  async function refreshWifiStatus() {
    const out = btn("wifiStatusOut");
    out.textContent = "...";
    try {
      const r = await run("wifi.sh", ["--status"], { timeout: 15 });
      showOut(out, r);
    } catch (e) { out.textContent = String(e); }
  }

  async function refreshEvilTwinStatus() {
    const out = btn("etOut");
    out.textContent = "...";
    try {
      const r = await run("EvilTwin.sh", ["--status"], { timeout: 15 });
      showOut(out, r);
    } catch (e) { out.textContent = String(e); }
  }

  async function refreshPayloads() {
    const sel = btn("payloadSelect");
    sel.innerHTML = "<option>Loading...</option>";
    try {
      const r = await api("/api/payloads");
      const lines = (r.stdout || "").split("\n").filter(l => /^\s*\d+\)/.test(l));
      sel.innerHTML = "";
      if (lines.length === 0) {
        sel.innerHTML = "<option value=''>No payloads found</option>";
        return;
      }
      for (const line of lines) {
        const m = line.match(/^\s*(\d+)\)\s+(\S+)\s+(\S+)\s+(.*)$/);
        if (!m) continue;
        const [, , category, name, desc] = m;
        const opt = document.createElement("option");
        opt.value = `${category}/${name}`;
        opt.textContent = `${category}/${name} - ${desc || ""}`;
        sel.appendChild(opt);
      }
      if (sel.options.length === 0) sel.innerHTML = "<option value=''>No payloads found</option>";
    } catch (e) {
      sel.innerHTML = "<option value=''>Error loading</option>";
    }
  }

  async function refreshLoot() {
    const out = btn("lootOut");
    out.textContent = "...";
    try {
      const r = await run("loot.sh", ["--list"], { timeout: 15 });
      showOut(out, r);
    } catch (e) { out.textContent = String(e); }
  }

  btn("wifiStatus").onclick = refreshWifiStatus;
  btn("etStatus").onclick = refreshEvilTwinStatus;
  btn("payloadRefresh").onclick = refreshPayloads;
  btn("lootList").onclick = refreshLoot;

  // ===========================================================================
  // BIG CHANGE (real rearchitecture, not a dedup): this file used to be ~25
  // independently hand-written onClick handlers. Every one of them re-
  // implemented the same shape by hand - grab the output element, maybe
  // validate some inputs, maybe confirm, show a "starting" message, run the
  // script, dump the result, maybe start/stop a live tail - with its own
  // copy-pasted version of that sequence. Nothing enforced the shape was
  // followed consistently (it drifted purely by whoever wrote which handler
  // and when); adding a new button meant writing a whole new handler from
  // scratch instead of declaring what's actually different about it.
  //
  // ACTIONS is now the single declarative source of truth for every button:
  // what script/args to run, how to validate/confirm first, what message to
  // show, whether to tail. runAction() is the ONE generic executor every
  // button goes through - the control-flow model of the whole file changed
  // from "N imperative handlers" to "one declarative table + one interpreter
  // for it", not two lookalike blocks merged into one.
  //
  // Each entry's `build()` (only where an action actually needs input
  // validation, dynamic args, or a per-call timeout) returns a context
  // object - `{ abort: "message" }` to stop right there with that message
  // shown (replacing every handler's old inline "if (!x) { ...; return; }"),
  // or the pieces the executor needs (`args`, and optionally `timeout`/
  // `background`) plus whatever the entry's own `confirm`/`starting`
  // functions need to read back off it.
  const ACTIONS = {
    // -- WiFi master --
    wifiOn:  { out: "wifiStatusOut", script: "wifi.sh", args: ["--on", "-y"], timeout: 45, starting: "Turning on..." },
    wifiOff: { out: "wifiStatusOut", script: "wifi.sh", args: ["--off", "-y"], timeout: 45, starting: "Turning off..." },

    // -- Evil Twin --
    etStart: {
      out: "etOut", script: "EvilTwin.sh", timeout: 60, starting: "Starting clone AP...",
      // BUG FOUND AND FIXED (carried over from the handler this replaced):
      // selecting "wifi client" uplink used to always fail - EvilTwin.sh
      // requires --wifi SSID (and takes an optional --wifi-pw) for that
      // mode, but the old handler never sent either.
      build: () => {
        const ssid = val("etSsid");
        if (!ssid) return { abort: "Enter a cloned SSID first." };
        const args = ["--cloned", ssid, "-y"];
        const pw = val("etPw");
        if (pw) args.push("--clone-pw", pw);
        const uplink = val("etUplink");
        args.push("--uplink", uplink);
        if (uplink === "wifi") {
          const wifiSsid = val("etWifiSsid");
          if (!wifiSsid) return { abort: "Uplink is 'wifi client' but no Uplink WiFi SSID was given." };
          args.push("--wifi", wifiSsid);
          const wifiPw = val("etWifiPw");
          if (wifiPw) args.push("--wifi-pw", wifiPw);
        }
        if (checked("etHidden")) args.push("--hidden");
        if (checked("etMimic")) args.push("--mimic");
        if (checked("etRecord")) args.push("--record");
        return { args, ssid };
      },
      confirm: (ctx) => `Start a clone AP broadcasting "${ctx.ssid}"?`,
    },
    etOn:   { out: "etOut", script: "EvilTwin.sh", args: ["--on"], timeout: 45, starting: "Restoring..." },
    etStop: { out: "etOut", script: "EvilTwin.sh", args: ["--stop"], timeout: 30, starting: "Stopping..." },

    // -- LAN Scan --
    lanScan: {
      out: "lanOut", script: "LanScan.sh", timeout: 300, starting: "Scanning (this can take a while)...",
      build: () => ({ args: ["--mode", val("lanMode"), "-y"] }),
    },

    // LAN Kill (DeadNet) is deliberately not wired up here - see index.html's
    // hint for why (no entry for it in this table on purpose).

    // -- WiFi Deauth --
    deauthSend: {
      out: "deauthOut", script: "deauth.sh", timeout: 15, tail: true,
      starting: "Starting deauth in the background - press Stop to end it...",
      build: () => {
        const bssid = val("deauthBssid"), target = val("deauthTarget"), channel = val("deauthChannel");
        if (!bssid || !channel) return { abort: "BSSID and channel are required (target defaults to all clients if left blank)." };
        const args = ["--bssid", bssid, "--channel", channel, "--background", "-y"];
        if (target) args.push("--target", target);
        return { args, bssid, target };
      },
      confirm: (ctx) => `Continuously deauth ${ctx.target || "all clients"} from ${ctx.bssid} until stopped?`,
    },
    deauthStop: { out: "deauthOut", script: "deauth.sh", args: ["--stop"], timeout: 15, tailOff: "deauth.sh" },

    // -- PineAP --
    mimicOn:  { out: "pineapOut", script: "mimic.sh", args: ["--on"], timeout: 15 },
    mimicOff: { out: "pineapOut", script: "mimic.sh", args: ["--off"], timeout: 15 },
    // BUG FOUND AND FIXED (found via code review, same class just fixed for
    // reconNew above): openap.sh --on/--off and mgmt.sh --on/--off are all
    // gated behind a confirm() prompt whenever ASSUME_YES isn't set (openap.sh
    // for --off, mgmt.sh for both --on and --off - see those files' own
    // comments on why). None of these four passed "-y", so none of them
    // could actually complete non-interactively through server.py's
    // subprocess - confirm()'s `read` on a stdin with nothing behind it
    // either dies immediately with "Aborted." or blocks until this
    // action's own timeout. Added "-y" (server-side bypass) plus a
    // confirm() (this file's substitute gate for the browser) for the two
    // that are actually consequential the same way EvilTwin/mgmt's own
    // CLI paths already treat them - openOn doesn't need one (turning on
    // an Open AP has no "disconnects you" risk the way disabling one, or
    // touching the Management AP, does).
    openOn: {
      out: "pineapOut", script: "openap.sh", timeout: 20,
      build: () => { const ssid = val("openSsid"); return ssid ? { args: ["--on", "--name", ssid, "-y"] } : { abort: "Enter an Open AP SSID first." }; },
    },
    openOff: {
      out: "pineapOut", script: "openap.sh", args: ["--off", "-y"], timeout: 15,
      confirm: () => "Disable the Open AP? This disconnects any clients currently connected to it.",
    },
    mgmtOn: {
      out: "pineapOut", script: "mgmt.sh", timeout: 20,
      build: () => {
        const ssid = val("mgmtSsid"), pw = val("mgmtPw");
        return (ssid && pw) ? { args: ["--on", "--name", ssid, "--pw", pw, "-y"], ssid } : { abort: "Mgmt AP needs both an SSID and a password." };
      },
      confirm: (ctx) => `Set the Management AP to "${ctx.ssid}"? If you're connected to it over Management WiFi right now (not USB-C), you'll need to reconnect with the new credentials afterward.`,
    },
    mgmtOff: {
      out: "pineapOut", script: "mgmt.sh", args: ["--off", "-y"], timeout: 15,
      confirm: () => "Disable the Management AP? If you're connected to it over Management WiFi right now (not USB-C), this WILL disconnect your current session.",
    },

    // -- Recon --
    hopPause:  { out: "reconOut", script: "reconsession.sh", args: ["--pause"], timeout: 15 },
    hopResume: { out: "reconOut", script: "reconsession.sh", args: ["--resume"], timeout: 15 },
    // BUG FOUND AND FIXED (found via code review): reconsession.sh --new is
    // gated behind a confirm() prompt (added earlier this session) - every
    // other ACTIONS entry that calls a confirm()-gated script passes "-y"
    // (this file's own confirmAuthorized() is the substitute gate for the
    // browser), but this one was missed. server.py's subprocess.run()
    // doesn't redirect the child's stdin, so confirm()'s `read` here either
    // hits immediate EOF (ASSUME_YES unset -> "Aborted.") or blocks until
    // this action's own request timeout - either way, clicking this button
    // could never actually start a new recon session.
    reconNew:  {
      out: "reconOut", script: "reconsession.sh", args: ["--new", "-y"], timeout: 15,
      confirm: () => "Start a fresh recon session? Whatever was accumulating under the current one keeps existing in the database, but a new session becomes the active one.",
    },

    // -- Payload Runner --
    payloadRun: {
      out: "payloadOut", script: "PayloadRunner.sh", timeout: 120,
      build: () => {
        const target = val("payloadSelect");
        if (!target) return { abort: "Pick a payload first." };
        const bg = checked("payloadBg");
        return { args: ["--run", target, "-y"], background: bg, bg };
      },
      starting: (ctx) => ctx.bg ? "Launched in background." : "Running (waiting for it to finish)...",
    },

    // -- Loot --
    lootArchive: { out: "lootOut", script: "loot.sh", args: ["--archive", "-y"], timeout: 30, starting: "Archiving..." },

    // -- LAN Sniffer --
    sniffAdapters: { out: "sniffOut", script: "sniff.sh", args: ["--adapters"], timeout: 15 },
    sniffStart: {
      out: "sniffOut", script: "sniff.sh", timeout: 15, tail: true,
      starting: "Starting capture in the background...",
      build: () => ({ args: ["--iface", val("sniffIface") || "eth1", "--duration", val("sniffDuration") || "30", "--background", "-y"] }),
    },
    sniffStop:   { out: "sniffOut", script: "sniff.sh", args: ["--stop"], timeout: 15, tailOff: "sniff.sh" },
    sniffStatus: { out: "sniffOut", script: "sniff.sh", args: ["--status"], timeout: 15 },

    // -- PC Link --
    pcLinkDetect: { out: "pcLinkOut", script: "pc_link.sh", args: ["--detect"], timeout: 15 },
    pcLinkCapture: {
      out: "pcLinkOut", script: "pc_link.sh", starting: "Detecting + capturing (waiting for it to finish)...",
      build: () => {
        const duration = val("pcLinkDuration") || "30";
        return { args: ["--capture", "--duration", duration, "-y"], timeout: parseInt(duration, 10) + 30 || 60 };
      },
    },

    // -- Bluetooth --
    btScan: { out: "btOut", script: "bluetooth.sh", args: ["--scan", "--ble", "--duration", "15", "-y"], timeout: 40, starting: "Scanning (classic + BLE, 15s)..." },
    btFloodStart: {
      out: "btOut", script: "bluetooth.sh", timeout: 15, tail: true,
      starting: "Starting flood in the background - press Stop to end it...",
      build: () => { const mac = val("btFloodMac"); return mac ? { args: ["--flood", mac, "--background", "-y"], mac } : { abort: "Enter a target MAC first (from a scan)." }; },
      confirm: (ctx) => `L2CAP-flood ${ctx.mac}? This is a real denial-of-service against it.`,
    },
    btJamStart: {
      out: "btOut", script: "bluetooth.sh", args: ["--jam-area", "--background", "-y"], timeout: 15, tail: true,
      starting: "Scanning then jamming everything found, in the background - press Stop to end it...",
      confirm: () => "Scan then L2CAP-flood EVERY Bluetooth device found nearby?",
    },
    btAdvspamStart: {
      out: "btOut", script: "bluetooth.sh", args: ["--advspam", "-y"], timeout: 20, starting: "Registering BLE advertising instances...",
      confirm: () => "Flood the area with fake BLE advertising packets?",
    },
    btStop:   { out: "btOut", script: "bluetooth.sh", args: ["--stop"], timeout: 15, tailOff: "bluetooth.sh" },
    btStatus: { out: "btOut", script: "bluetooth.sh", args: ["--status"], timeout: 15 },

    // -- Report --
    reportRefresh: { out: "reportOut", script: "report.sh", args: [], timeout: 20, starting: "Generating..." },
  };

  // The one generic executor. Every ACTIONS entry, no matter how different
  // its inputs/validation/confirmation, goes through exactly this sequence.
  async function runAction(id) {
    const spec = ACTIONS[id];
    const out = btn(spec.out);
    const ctx = spec.build ? spec.build() : {};
    if (ctx.abort) { out.textContent = ctx.abort; return; }
    if (spec.confirm && !confirmAuthorized(spec.confirm(ctx))) return;
    if (spec.tailOff) stopTailing(spec.tailOff);
    if (spec.starting !== undefined) {
      out.textContent = typeof spec.starting === "function" ? spec.starting(ctx) : spec.starting;
    }
    const args = ctx.args || spec.args || [];
    const timeout = ctx.timeout || spec.timeout || 60;
    const background = ctx.background ?? spec.background ?? false;
    const result = await run(spec.script, args, { timeout, background });
    showOut(out, result);
    if (spec.tail) startTailing(spec.script, out);
  }

  for (const id of Object.keys(ACTIONS)) {
    onClick(id, () => runAction(id));
  }
  // ===========================================================================

  // BIG CHANGE: a page refresh (or just opening the Control Panel fresh
  // while an attack from an earlier visit is still running in the
  // background) used to lose live output entirely - the tailer only ever
  // started right after a button click, so you'd have to remember to
  // press Status manually to even notice something was still running.
  // Checks each backgrounded script's real status on load and resumes
  // tailing automatically if it's already active.
  async function resumeTailingIfRunning(script, outEl) {
    try {
      const r = await run(script, ["--status"], { timeout: 10 });
      if (r.stdout && /running/i.test(r.stdout)) {
        outEl.textContent = (outEl.textContent ? outEl.textContent + "\n" : "") + "-- already running, resuming live output --";
        startTailing(script, outEl);
      }
    } catch (e) { /* ignore - not critical, worst case is the same as before this change */ }
  }

  // Initial load
  if (!token) {
    document.body.innerHTML = "<main style='padding:40px;text-align:center;font-family:sans-serif;color:#eee;background:#14161a;min-height:100vh'>" +
      "<h2>No access token</h2><p>Open this page with <code>?token=YOUR_TOKEN</code> once.<br>Set one on the device with <code>webui --set-token</code>.</p></main>";
  } else {
    refreshBattery();
    refreshWifiStatus();
    refreshEvilTwinStatus();
    refreshPayloads();
    refreshLoot();
    resumeTailingIfRunning("deauth.sh", btn("deauthOut"));
    resumeTailingIfRunning("sniff.sh", btn("sniffOut"));
    resumeTailingIfRunning("bluetooth.sh", btn("btOut"));
    setInterval(refreshBattery, 30000);
  }
})();
