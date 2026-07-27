"use strict";
/* Sentinel-ISR dashboard. Same "dumb frontend" discipline as web/app.js:
 * every value drawn for the local-pack tracks/zones/alerts is a verbatim
 * field from the server's FrameDelta (jac/render.jac). The one addition
 * this file computes itself is the zoomed-out GLOBAL layer's screen
 * projection for live AIS positions streamed from data/global_ais.py --
 * those come through as bare lat/lon/course, same as any Leaflet marker.
 */

const TRAIL_LEN = 20;
const MAX_LOG_LINES = 400;
const GLOBAL_ZOOM_THRESHOLD = 6; // below this zoom, show the global layer instead of local tracks

const els = {
  map: document.getElementById("map"),
  log: document.getElementById("log-entries"),
  idCount: document.getElementById("id-switch-count"),
  statsTracks: document.getElementById("stats-tracks"),
  statsDark: document.getElementById("stats-dark"),
  btnPlay: document.getElementById("btn-play"),
  btnReset: document.getElementById("btn-reset"),
  scrubber: document.getElementById("scrubber"),
  frameReadout: document.getElementById("frame-readout"),
  connStatus: document.getElementById("conn-status"),
  speedBtns: Array.from(document.querySelectorAll(".speed-btn")),
  packPicker: document.getElementById("pack-picker"),
  btnAssoc: document.getElementById("btn-assoc"),
  assocBadge: document.getElementById("assoc-badge"),
  btnRetract: document.getElementById("btn-retract"),
  btnGlobalLayer: document.getElementById("btn-global-layer"),
  globalBadge: document.getElementById("global-badge"),
  banner: document.getElementById("banner"),
  briefList: document.getElementById("brief-list"),
  jtmsFacts: document.getElementById("jtms-facts"),
  jtmsConcls: document.getElementById("jtms-concls"),
  evalSummary: document.getElementById("eval-summary"),
  evalList: document.getElementById("eval-list"),
};

const state = {
  ws: null,
  totalFrames: 0,
  frameIntervalS: 30,
  playing: false,
  speed: 10,
  lastIdSwitches: 0,
  scrubDragging: false,
  zonesDrawn: false,
  assocMode: "global",
  packId: null,
  globalLayerOn: false,
  globalLive: false, // true once a real aisstream.io fix has arrived
};

const tracks = new Map(); // track_id -> { marker, trailGroup, ellipseLayer, positions, color }
const globalMarkers = new Map(); // mmsi -> marker

// ------------------------------------------------------------------- map

const map = L.map(els.map, {
  zoomControl: true,
  attributionControl: false,
  worldCopyJump: true,
}).setView([20, 0], 3);

L.tileLayer(
  // CARTO retired the "dark_matter" path (404s now); "dark_all" is the
  // live equivalent -- confirmed by curl against basemaps.cartocdn.com.
  "https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png",
  { subdomains: "abcd", maxZoom: 19 }
).addTo(map);

const zonesLayer = L.featureGroup().addTo(map); // needs getBounds(); plain layerGroup lacks it
const localLayer = L.layerGroup().addTo(map);
const globalLayer = L.layerGroup();

function drawZones(zones) {
  zonesLayer.clearLayers();
  state.zonesDrawn = false;
  for (const z of zones || []) {
    L.geoJSON(z.geojson, {
      style: {
        color: z.style.color,
        weight: 2,
        opacity: 0.9,
        fillOpacity: z.style.fillOpacity,
        dashArray: z.style.dashArray || null,
      },
    })
      .bindTooltip(`${z.name} (${z.kind})`)
      .addTo(zonesLayer);
  }
  if (zones && zones.length) {
    state.zonesDrawn = true;
    map.fitBounds(zonesLayer.getBounds().pad(6), { animate: false });
  }
}

function triangleIcon(color, headingDeg) {
  return L.divIcon({
    className: "track-icon",
    html: `<div class="track-triangle" style="border-bottom-color:${color};transform:rotate(${headingDeg}deg);"></div>`,
    iconSize: [16, 18],
    iconAnchor: [8, 10],
  });
}

function ensureTrack(tp) {
  let t = tracks.get(tp.track_id);
  if (t) return t;
  const marker = L.marker([tp.lat, tp.lon], {
    icon: triangleIcon(tp.color, tp.heading_deg),
    riseOnHover: true,
  }).addTo(localLayer);
  const trailGroup = L.layerGroup().addTo(localLayer);
  const ellipseLayer = L.layerGroup().addTo(localLayer);
  t = { marker, trailGroup, ellipseLayer, positions: [], color: tp.color, heading: tp.heading_deg };
  tracks.set(tp.track_id, t);
  return t;
}

function redrawTrail(t) {
  t.trailGroup.clearLayers();
  const pos = t.positions;
  const segs = pos.length - 1;
  for (let i = 0; i < segs; i++) {
    const age = (i + 1) / segs;
    L.polyline([pos[i], pos[i + 1]], {
      color: t.color, weight: 2, opacity: 0.12 + 0.6 * age, interactive: false,
    }).addTo(t.trailGroup);
  }
}

function redrawEllipse(t, tp) {
  t.ellipseLayer.clearLayers();
  if (!tp.dark || !tp.ellipse_latlon || !tp.ellipse_latlon.length) return;
  L.polygon(tp.ellipse_latlon, {
    color: "#ffb020", weight: 1.5, fillColor: "#ffb020", fillOpacity: 0.08,
    dashArray: "3 3", interactive: false,
  }).addTo(t.ellipseLayer);
}

function updateTrackVisual(t, tp) {
  t.marker.setLatLng([tp.lat, tp.lon]);
  const el = t.marker.getElement();
  if (el) {
    const tri = el.querySelector(".track-triangle");
    if (tri) {
      tri.style.borderBottomColor = tp.color;
      tri.style.transform = `rotate(${tp.heading_deg}deg)`;
    }
  }
  t.marker.setTooltipContent(`${tp.label} · ${tp.status}`);
  t.color = tp.color;
}

function removeTrack(id) {
  const t = tracks.get(id);
  if (!t) return;
  localLayer.removeLayer(t.marker);
  localLayer.removeLayer(t.trailGroup);
  localLayer.removeLayer(t.ellipseLayer);
  tracks.delete(id);
}

function updateTracks(payloads) {
  const seen = new Set();
  for (const tp of payloads || []) {
    seen.add(tp.track_id);
    const t = ensureTrack(tp);
    if (!t.marker.getTooltip()) t.marker.bindTooltip("", { sticky: true });
    t.positions.push([tp.lat, tp.lon]);
    if (t.positions.length > TRAIL_LEN) t.positions.shift();
    redrawTrail(t);
    redrawEllipse(t, tp);
    updateTrackVisual(t, tp);
  }
  for (const id of Array.from(tracks.keys())) {
    if (!seen.has(id)) removeTrack(id);
  }
}

// -------------------------------------------------------------- event log

function escapeHtml(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

const LOG_TAG_RE = /^\[(\d+):(\d{2}):(\d{2})\]\s*(EVENT|TRACK|ZONE)\s+(.*)$/;

function parseLogLine(line) {
  const m = LOG_TAG_RE.exec(line);
  if (!m) return { t: 0, cls: "log-log", html: escapeHtml(line) };
  const t = Number(m[1]) * 3600 + Number(m[2]) * 60 + Number(m[3]);
  const tag = m[4];
  return { t, cls: `log-${tag.toLowerCase()}`, html: `<span class="tag">[${tag}]</span>${escapeHtml(m[5])}` };
}

function alertEntry(a) {
  const who = a.track_id ? `${a.track_id}: ` : "";
  return { t: a.t, cls: `log-alert-${a.severity}`, html: `<span class="tag">[Alert]</span>${escapeHtml(who + a.headline)}` };
}

function fusionEntry(msg) {
  const tentative = (msg.tracks || []).filter((t) => t.status === "tentative").length;
  const s = msg.stats || {};
  return {
    t: msg.t, cls: "log-fusion",
    html: `<span class="tag">[Fusion]</span>f${msg.frame_idx} · ${s.n_meas ?? 0} meas → ${s.n_tracks ?? 0} tracks · ${tentative} hyp open`,
  };
}

function renderLogEntries(entries, { replace }) {
  entries.sort((a, b) => a.t - b.t);
  const frag = document.createDocumentFragment();
  for (let i = entries.length - 1; i >= 0; i--) {
    const e = entries[i];
    const div = document.createElement("div");
    div.className = `log-line ${e.cls}`;
    div.innerHTML = e.html;
    frag.appendChild(div);
  }
  if (replace) {
    els.log.replaceChildren(frag);
  } else {
    els.log.insertBefore(frag, els.log.firstChild);
    while (els.log.children.length > MAX_LOG_LINES) els.log.removeChild(els.log.lastChild);
  }
}

// ----------------------------------------------------------------- stats

function updateStats(msg) {
  const s = msg.stats || {};
  els.statsTracks.textContent = s.n_tracks ?? 0;
  els.statsDark.textContent = s.n_dark ?? 0;
  if (typeof msg.id_switches === "number") {
    els.idCount.textContent = msg.id_switches;
    if (msg.id_switches > state.lastIdSwitches) {
      els.idCount.classList.remove("flash");
      void els.idCount.offsetWidth;
      els.idCount.classList.add("flash");
    }
    state.lastIdSwitches = msg.id_switches;
  }
}

function updateScrubber(frameIdx) {
  if (!state.scrubDragging) els.scrubber.value = String(frameIdx);
  const t = frameIdx * state.frameIntervalS;
  const clock = new Date(t * 1000).toISOString().substr(11, 8);
  els.frameReadout.textContent = `frame ${frameIdx} / ${state.totalFrames - 1} · ${clock}`;
}

// ------------------------------------------------------------- transport ui

function setPlayingUi(playing) {
  state.playing = playing;
  els.btnPlay.textContent = playing ? "⏸ Pause" : "▶ Play";
  els.btnPlay.classList.toggle("is-playing", playing);
}

function setSpeedUi(speed) {
  state.speed = speed;
  for (const b of els.speedBtns) b.classList.toggle("active", Number(b.dataset.speed) === speed);
}

function setAssocUi(mode) {
  state.assocMode = mode;
  const naive = mode === "greedy";
  els.btnAssoc.textContent = naive ? "NAIVE (greedy)" : "GLOBAL (Hungarian)";
  els.btnAssoc.classList.toggle("naive", naive);
  els.assocBadge.textContent = naive ? "NAIVE" : "GLOBAL";
  els.assocBadge.classList.toggle("naive", naive);
}

async function postJson(path, body) {
  const res = await fetch(path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body || {}) });
  return res.json();
}
async function getJson(path) {
  const res = await fetch(path);
  return res.json();
}

els.btnPlay.addEventListener("click", async () => {
  const r = state.playing ? await postJson("/api/pause") : await postJson("/api/play", { speed: state.speed });
  setPlayingUi(r.playing);
});
els.btnReset.addEventListener("click", () => postJson("/api/reset"));
for (const b of els.speedBtns) {
  b.addEventListener("click", async () => {
    const r = await postJson("/api/speed", { speed: Number(b.dataset.speed) });
    setSpeedUi(r.speed);
  });
}
let seekDebounce = null;
els.scrubber.addEventListener("input", () => {
  state.scrubDragging = true;
  const frame = Number(els.scrubber.value);
  els.frameReadout.textContent = `frame ${frame} / ${state.totalFrames - 1} · scrubbing…`;
  clearTimeout(seekDebounce);
  seekDebounce = setTimeout(() => postJson("/api/seek", { frame }), 35);
});
els.scrubber.addEventListener("change", () => {
  postJson("/api/seek", { frame: Number(els.scrubber.value) });
  state.scrubDragging = false;
});

async function switchPack(pack_id) {
  els.packPicker.disabled = true;
  els.connStatus.textContent = `loading ${pack_id}…`;
  await postJson("/api/switch", { pack_id });
  els.packPicker.disabled = false;
}
async function toggleAssoc() {
  const next = state.assocMode === "greedy" ? "global" : "greedy";
  els.btnAssoc.disabled = true;
  await postJson("/api/switch", { assoc_mode: next });
  els.btnAssoc.disabled = false;
}
els.btnAssoc.addEventListener("click", toggleAssoc);
els.packPicker.addEventListener("change", () => switchPack(els.packPicker.value));

// ------------------------------------------------------------------ tabs

for (const btn of document.querySelectorAll(".tab-btn")) {
  btn.addEventListener("click", () => {
    for (const b of document.querySelectorAll(".tab-btn")) b.classList.toggle("active", b === btn);
    for (const p of document.querySelectorAll(".tab-pane")) p.classList.toggle("active", p.id === `tab-${btn.dataset.tab}`);
  });
}

// -------------------------------------------------------------------- jtms

function renderJtms(data) {
  els.jtmsFacts.innerHTML = "<h3>Facts</h3>";
  for (const [fid, f] of Object.entries(data.facts || {})) {
    const div = document.createElement("div");
    div.className = "jtms-node";
    div.innerHTML = `<span class="node-id">${fid}</span>${escapeHtml(f.label)}<br><span class="${f.believed ? "status-believed" : "status-disbelieved"}">${f.believed ? "believed" : "disbelieved"}</span>`;
    els.jtmsFacts.appendChild(div);
  }
  els.jtmsConcls.innerHTML = "<h3>Conclusions</h3>";
  for (const [cid, c] of Object.entries(data.conclusions || {})) {
    const div = document.createElement("div");
    div.className = "jtms-node";
    const flipped = (data.flipped || []).includes(cid);
    div.innerHTML = `<span class="node-id">${cid}${flipped ? " ⚙ flipped" : ""}</span>${escapeHtml(c.label)}<br><span class="status-${c.status.toLowerCase()}">${c.status}</span><div class="provenance">${escapeHtml(c.brief)}</div>`;
    els.jtmsConcls.appendChild(div);
  }
}

async function jtmsReset() { renderJtms(await postJson("/api/jtms/reset")); }
async function jtmsRetract(factId) { renderJtms(await postJson("/api/jtms/retract", { fact_id: factId })); await loadBrief(); }
async function jtmsReinstate(factId) { renderJtms(await postJson("/api/jtms/reinstate", { fact_id: factId })); await loadBrief(); }

els.btnRetract.addEventListener("click", () => jtmsRetract("broadcast_b_mmsi"));

// ------------------------------------------------------------------- brief

async function loadBrief() {
  const data = await getJson("/api/brief?concl_ids=identity_a_confirmed,identity_b_confirmed,spoof_detected&use_llm=1");
  els.briefList.innerHTML = "";
  for (const b of data.briefs || []) {
    const div = document.createElement("div");
    div.className = "brief-card";
    div.innerHTML =
      `<span class="concl-id">${b.concl_id}</span>` +
      `<span class="status-${b.status.toLowerCase()}">${b.status}</span> — ${escapeHtml(b.text)}` +
      `<div class="provenance">model: ${b.model_used} · cost: $${b.cost_usd.toFixed(4)} · sources: ${b.source_ids.join(", ")}</div>`;
    els.briefList.appendChild(div);
  }
}

// -------------------------------------------------------------------- eval

async function loadEval() {
  els.evalSummary.textContent = "running tracker/eval.py …";
  els.evalList.innerHTML = "";
  const data = await getJson("/api/eval");
  const t = data.totals;
  els.evalSummary.innerHTML =
    `<div class="eval-summary-row">` +
    `<div class="chip pass">${t.passed} pass</div>` +
    `<div class="chip fail">${t.failed} fail</div>` +
    `<div class="chip skip">${t.skipped} skip</div>` +
    `</div>`;
  for (const p of data.packs || []) {
    const div = document.createElement("div");
    div.className = "eval-pack";
    let rows = "";
    for (const c of p.checks) rows += `<div class="check-row"><span class="outcome-${c.outcome}">${c.outcome.toUpperCase()}</span> ${escapeHtml(c.key)} — ${escapeHtml(c.detail)}</div>`;
    div.innerHTML = `<span class="pack-id">${p.pack_id} (${p.passed}/${p.passed + p.failed + p.skipped})</span>${rows}`;
    els.evalList.appendChild(div);
  }
}
document.querySelector('[data-tab="eval"]').addEventListener("click", loadEval);
document.querySelector('[data-tab="jtms"]').addEventListener("click", () => { if (!Object.keys(els.jtmsConcls.dataset).length) {} });

// ----------------------------------------------------------- global layer

function globalMarkerIcon() {
  return L.divIcon({ className: "global-dot", html: `<div style="width:5px;height:5px;border-radius:50%;background:#ffb020;box-shadow:0 0 4px #ffb020;"></div>`, iconSize: [5, 5], iconAnchor: [2, 2] });
}

function applyGlobalFix(v) {
  let m = globalMarkers.get(v.mmsi);
  if (!m) {
    m = L.marker([v.lat, v.lon], { icon: globalMarkerIcon(), interactive: false }).addTo(globalLayer);
    globalMarkers.set(v.mmsi, m);
  } else {
    m.setLatLng([v.lat, v.lon]);
  }
}

function setGlobalLayer(on) {
  state.globalLayerOn = on;
  els.btnGlobalLayer.classList.toggle("active", on);
  if (on) {
    map.removeLayer(localLayer);
    globalLayer.addTo(map);
    els.globalBadge.classList.remove("hidden");
    els.globalBadge.textContent = state.globalLive
      ? "LIVE GLOBAL AIS · aisstream.io"
      : "DEMO · SYNTHETIC GLOBAL TRAFFIC · NOT LIVE AIS";
  } else {
    map.removeLayer(globalLayer);
    localLayer.addTo(map);
    els.globalBadge.classList.add("hidden");
  }
}
els.btnGlobalLayer.addEventListener("click", () => setGlobalLayer(!state.globalLayerOn));

map.on("zoomend", () => {
  const shouldGlobal = map.getZoom() < GLOBAL_ZOOM_THRESHOLD;
  if (shouldGlobal !== state.globalLayerOn) setGlobalLayer(shouldGlobal);
});

let globalPollTimer = null;
async function pollGlobal() {
  try {
    const data = await getJson("/api/global");
    state.globalLive = !!data.live;
    for (const v of data.vessels || []) applyGlobalFix(v);
    if (state.globalLayerOn) {
      els.globalBadge.textContent = state.globalLive
        ? `LIVE GLOBAL AIS · aisstream.io · ${data.vessels.length} contacts`
        : "DEMO · SYNTHETIC GLOBAL TRAFFIC · NOT LIVE AIS";
    }
  } catch (err) {
    // Global layer is best-effort; local pack streaming must never depend on it.
  }
}
globalPollTimer = setInterval(pollGlobal, 4000);
pollGlobal();

// ---------------------------------------------------------------- websocket

function applyMessage(msg) {
  if (msg.type === "init") {
    state.totalFrames = msg.total_frames;
    state.frameIntervalS = msg.frame_interval_s;
    state.packId = msg.pack_id;
    els.scrubber.max = String(Math.max(0, msg.total_frames - 1));
    if (msg.assoc_mode) setAssocUi(msg.assoc_mode);
    if (msg.known_packs) {
      els.packPicker.innerHTML = "";
      for (const p of msg.known_packs) {
        const opt = document.createElement("option");
        opt.value = p; opt.textContent = p;
        if (p === msg.pack_id) opt.selected = true;
        els.packPicker.appendChild(opt);
      }
    } else if (msg.pack_id) {
      els.packPicker.value = msg.pack_id;
    }
    drawZones(msg.zones);
    return;
  }

  if (msg.type === "state") {
    setPlayingUi(msg.playing);
    setSpeedUi(msg.speed);
    return;
  }

  if (msg.type === "frame" || msg.type === "sync") {
    updateTracks(msg.tracks);
    updateStats(msg);
    updateScrubber(msg.frame_idx);
    setPlayingUi(msg.playing);
    setSpeedUi(msg.speed);
    if (msg.assoc_mode) setAssocUi(msg.assoc_mode);

    if (msg.type === "sync") {
      drawZones(msg.zones && msg.zones.length ? msg.zones : null);
      const entries = [fusionEntry(msg)].concat((msg.history_alerts || []).map(alertEntry)).concat((msg.history_log || []).map(parseLogLine));
      renderLogEntries(entries, { replace: true });
    } else {
      const entries = [fusionEntry(msg)].concat((msg.alerts || []).map(alertEntry)).concat((msg.log || []).map(parseLogLine));
      renderLogEntries(entries, { replace: false });
      const crit = (msg.alerts || []).find((a) => a.severity === "critical");
      if (crit) {
        els.banner.textContent = `⚠ ${crit.headline}`;
        els.banner.classList.remove("hidden");
      }
    }
  }
}

function setConn(status) {
  els.connStatus.textContent = status;
  els.connStatus.className = "conn-status " + (status === "connected" ? "ok" : status === "connecting…" ? "" : "bad");
}

function connect() {
  const proto = location.protocol === "https:" ? "wss" : "ws";
  const ws = new WebSocket(`${proto}://${location.host}/ws`);
  state.ws = ws;
  setConn("connecting…");
  ws.onopen = () => setConn("connected");
  ws.onmessage = (ev) => {
    try { applyMessage(JSON.parse(ev.data)); } catch (err) { console.error("bad message", err, ev.data); }
  };
  ws.onclose = () => { setConn("disconnected — retrying"); setTimeout(connect, 1000); };
  ws.onerror = () => ws.close();
}

// ------------------------------------------------------------- keyboard

document.addEventListener("keydown", (ev) => {
  if (ev.target.tagName === "INPUT" || ev.target.tagName === "SELECT") return;
  if (ev.code === "Space") { ev.preventDefault(); els.btnPlay.click(); }
  else if (ev.code === "ArrowRight") postJson("/api/seek", { frame: Number(els.scrubber.value) + 1 });
  else if (ev.code === "ArrowLeft") postJson("/api/seek", { frame: Math.max(0, Number(els.scrubber.value) - 1) });
  else if (ev.key === "m" || ev.key === "M") toggleAssoc();
  else if (ev.key === "x" || ev.key === "X") jtmsRetract("broadcast_b_mmsi");
  else if (ev.key === "r" || ev.key === "R") jtmsReinstate("broadcast_b_mmsi");
  else if (ev.key === "Escape") els.btnReset.click();
});

connect();
jtmsReset().then(loadBrief);
