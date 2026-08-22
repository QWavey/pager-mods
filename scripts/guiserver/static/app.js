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

  // -- WiFi master --
  onClick("wifiOn", async () => { const out = btn("wifiStatusOut"); out.textContent = "Turning on..."; showOut(out, await run("wifi.sh", ["--on", "-y"], { timeout: 45 })); });
  onClick("wifiOff", async () => { const out = btn("wifiStatusOut"); out.textContent = "Turning off..."; showOut(out, await run("wifi.sh", ["--off", "-y"], { timeout: 45 })); });
  btn("wifiStatus").onclick = refreshWifiStatus;

  // -- Evil Twin --
  onClick("etStart", async () => {
    const out = btn("etOut");
    const ssid = val("etSsid");
    if (!ssid) { out.textContent = "Enter a cloned SSID first."; return; }
    const args = ["--cloned", ssid, "-y"];
    const pw = val("etPw");
    if (pw) args.push("--clone-pw", pw);
    const uplink = val("etUplink");
    args.push("--uplink", uplink);
    // BUG FOUND AND FIXED: selecting "wifi client" here always failed -
    // EvilTwin.sh requires --wifi SSID (and takes an optional --wifi-pw)
    // for that uplink mode, but this handler never sent either, so it
    // always hit EvilTwin.sh's own "no --wifi SSID was given" die(). The
    // HTML now has matching fields; wire them in only for this mode.
    if (uplink === "wifi") {
      const wifiSsid = val("etWifiSsid");
      if (!wifiSsid) { out.textContent = "Uplink is 'wifi client' but no Uplink WiFi SSID was given."; return; }
      args.push("--wifi", wifiSsid);
      const wifiPw = val("etWifiPw");
      if (wifiPw) args.push("--wifi-pw", wifiPw);
    }
    if (checked("etHidden")) args.push("--hidden");
    if (checked("etMimic")) args.push("--mimic");
    if (checked("etRecord")) args.push("--record");
    if (!confirmAuthorized(`Start a clone AP broadcasting "${ssid}"?`)) return;
    out.textContent = "Starting clone AP...";
    showOut(out, await run("EvilTwin.sh", args, { timeout: 60 }));
  });
  onClick("etOn", async () => { const out = btn("etOut"); out.textContent = "Restoring..."; showOut(out, await run("EvilTwin.sh", ["--on"], { timeout: 45 })); });
  onClick("etStop", async () => { const out = btn("etOut"); out.textContent = "Stopping..."; showOut(out, await run("EvilTwin.sh", ["--stop"], { timeout: 30 })); });
  btn("etStatus").onclick = refreshEvilTwinStatus;

  // -- LAN Scan --
  onClick("lanScan", async () => {
    const out = btn("lanOut");
    out.textContent = "Scanning (this can take a while)...";
    showOut(out, await run("LanScan.sh", ["--mode", val("lanMode"), "-y"], { timeout: 300 }));
  });

  // LAN Kill (DeadNet) is deliberately not wired up here - see index.html's
  // hint for why (its buttons were removed, this section intentionally
  // has no onClick handlers left for it).

  // -- WiFi Deauth --
  // BUG FIXED: this used to send a "--wifi" flag that deauth.sh has never
  // actually had (it's WiFi-only already, no mode flag needed) plus other
  // args that no longer match its real interface - the button silently
  // failed with "Unknown argument: --wifi" every time. deauth.sh also now
  // runs continuously until stopped (not a single fire-and-forget shot),
  // target defaults to FF:FF:FF:FF:FF:FF (all clients) if left blank, and
  // background+stop mirror the CLI/payload behavior.
  onClick("deauthSend", async () => {
    const out = btn("deauthOut");
    const bssid = val("deauthBssid"), target = val("deauthTarget"), channel = val("deauthChannel");
    if (!bssid || !channel) { out.textContent = "BSSID and channel are required (target defaults to all clients if left blank)."; return; }
    const args = ["--bssid", bssid, "--channel", channel, "--background", "-y"];
    if (target) args.push("--target", target);
    if (!confirmAuthorized(`Continuously deauth ${target || "all clients"} from ${bssid} until stopped?`)) return;
    out.textContent = "Starting deauth in the background - press Stop to end it...";
    showOut(out, await run("deauth.sh", args, { timeout: 15 }));
    startTailing("deauth.sh", out);
  });
  onClick("deauthStop", async () => {
    const out = btn("deauthOut");
    stopTailing("deauth.sh");
    showOut(out, await run("deauth.sh", ["--stop"], { timeout: 15 }));
  });

  // -- PineAP --
  onClick("mimicOn", async () => { const out = btn("pineapOut"); showOut(out, await run("mimic.sh", ["--on"], { timeout: 15 })); });
  onClick("mimicOff", async () => { const out = btn("pineapOut"); showOut(out, await run("mimic.sh", ["--off"], { timeout: 15 })); });
  onClick("openOn", async () => {
    const out = btn("pineapOut");
    const ssid = val("openSsid");
    if (!ssid) { out.textContent = "Enter an Open AP SSID first."; return; }
    showOut(out, await run("openap.sh", ["--on", "--name", ssid], { timeout: 20 }));
  });
  onClick("openOff", async () => { const out = btn("pineapOut"); showOut(out, await run("openap.sh", ["--off"], { timeout: 15 })); });
  onClick("mgmtOn", async () => {
    const out = btn("pineapOut");
    const ssid = val("mgmtSsid"), pw = val("mgmtPw");
    if (!ssid || !pw) { out.textContent = "Mgmt AP needs both an SSID and a password."; return; }
    showOut(out, await run("mgmt.sh", ["--on", "--name", ssid, "--pw", pw], { timeout: 20 }));
  });
  onClick("mgmtOff", async () => { const out = btn("pineapOut"); showOut(out, await run("mgmt.sh", ["--off"], { timeout: 15 })); });

  // -- Recon --
  onClick("hopPause", async () => { const out = btn("reconOut"); showOut(out, await run("reconsession.sh", ["--pause"], { timeout: 15 })); });
  onClick("hopResume", async () => { const out = btn("reconOut"); showOut(out, await run("reconsession.sh", ["--resume"], { timeout: 15 })); });
  onClick("reconNew", async () => { const out = btn("reconOut"); showOut(out, await run("reconsession.sh", ["--new"], { timeout: 15 })); });

  // -- Payload Runner --
  btn("payloadRefresh").onclick = refreshPayloads;
  onClick("payloadRun", async () => {
    const out = btn("payloadOut");
    const target = val("payloadSelect");
    if (!target) { out.textContent = "Pick a payload first."; return; }
    const bg = checked("payloadBg");
    out.textContent = bg ? "Launched in background." : "Running (waiting for it to finish)...";
    showOut(out, await run("PayloadRunner.sh", ["--run", target, "-y"], { background: bg, timeout: 120 }));
  });

  // -- Loot --
  btn("lootList").onclick = refreshLoot;
  onClick("lootArchive", async () => { const out = btn("lootOut"); out.textContent = "Archiving..."; showOut(out, await run("loot.sh", ["--archive", "-y"], { timeout: 30 })); });

  // -- LAN Sniffer --
  onClick("sniffAdapters", async () => { const out = btn("sniffOut"); showOut(out, await run("sniff.sh", ["--adapters"], { timeout: 15 })); });
  onClick("sniffStart", async () => {
    const out = btn("sniffOut");
    const iface = val("sniffIface") || "eth1";
    const duration = val("sniffDuration") || "30";
    out.textContent = "Starting capture in the background...";
    showOut(out, await run("sniff.sh", ["--iface", iface, "--duration", duration, "--background", "-y"], { timeout: 15 }));
    startTailing("sniff.sh", out);
  });
  onClick("sniffStop", async () => { const out = btn("sniffOut"); stopTailing("sniff.sh"); showOut(out, await run("sniff.sh", ["--stop"], { timeout: 15 })); });
  onClick("sniffStatus", async () => { const out = btn("sniffOut"); showOut(out, await run("sniff.sh", ["--status"], { timeout: 15 })); });

  // -- PC Link --
  onClick("pcLinkDetect", async () => { const out = btn("pcLinkOut"); showOut(out, await run("pc_link.sh", ["--detect"], { timeout: 15 })); });
  onClick("pcLinkCapture", async () => {
    const out = btn("pcLinkOut");
    const duration = val("pcLinkDuration") || "30";
    out.textContent = "Detecting + capturing (waiting for it to finish)...";
    showOut(out, await run("pc_link.sh", ["--capture", "--duration", duration, "-y"], { timeout: parseInt(duration, 10) + 30 || 60 }));
  });

  // -- Bluetooth --
  onClick("btScan", async () => {
    const out = btn("btOut");
    out.textContent = "Scanning (classic + BLE, 15s)...";
    showOut(out, await run("bluetooth.sh", ["--scan", "--ble", "--duration", "15", "-y"], { timeout: 40 }));
  });
  onClick("btFloodStart", async () => {
    const out = btn("btOut");
    const mac = val("btFloodMac");
    if (!mac) { out.textContent = "Enter a target MAC first (from a scan)."; return; }
    if (!confirmAuthorized(`L2CAP-flood ${mac}? This is a real denial-of-service against it.`)) return;
    out.textContent = "Starting flood in the background - press Stop to end it...";
    showOut(out, await run("bluetooth.sh", ["--flood", mac, "--background", "-y"], { timeout: 15 }));
    startTailing("bluetooth.sh", out);
  });
  onClick("btJamStart", async () => {
    const out = btn("btOut");
    if (!confirmAuthorized("Scan then L2CAP-flood EVERY Bluetooth device found nearby?")) return;
    out.textContent = "Scanning then jamming everything found, in the background - press Stop to end it...";
    showOut(out, await run("bluetooth.sh", ["--jam-area", "--background", "-y"], { timeout: 15 }));
    startTailing("bluetooth.sh", out);
  });
  onClick("btAdvspamStart", async () => {
    const out = btn("btOut");
    if (!confirmAuthorized("Flood the area with fake BLE advertising packets?")) return;
    out.textContent = "Registering BLE advertising instances...";
    showOut(out, await run("bluetooth.sh", ["--advspam", "-y"], { timeout: 20 }));
  });
  onClick("btStop", async () => { const out = btn("btOut"); stopTailing("bluetooth.sh"); showOut(out, await run("bluetooth.sh", ["--stop"], { timeout: 15 })); });
  onClick("btStatus", async () => { const out = btn("btOut"); showOut(out, await run("bluetooth.sh", ["--status"], { timeout: 15 })); });

  // -- Report --
  onClick("reportRefresh", async () => { const out = btn("reportOut"); out.textContent = "Generating..."; showOut(out, await run("report.sh", [], { timeout: 20 })); });

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
