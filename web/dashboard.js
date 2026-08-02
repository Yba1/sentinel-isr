"use strict";
/* Aegis dashboard. The local safety and financial-risk values are supplied
 * by the server:
 * every value drawn for the local-pack tracks/zones/alerts is a verbatim
 * field from the server's FrameDelta. The one addition
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
  riskSummary: document.getElementById("risk-summary"),
  riskList: document.getElementById("risk-list"),
  trajectoryPanel: document.getElementById("trajectory-panel"),
  trajectoryClose: document.getElementById("trajectory-close"),
  trajectoryName: document.getElementById("trajectory-name"),
  trajectoryMeta: document.getElementById("trajectory-meta"),
  trajectoryContext: document.getElementById("trajectory-context"),
  trajectoryGfw: document.getElementById("trajectory-gfw"),
  trajectoryRisk: document.getElementById("trajectory-risk"),
  trajectoryOptions: document.getElementById("trajectory-options"),
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
  globalVessels: [],
  globalStatus: {},
  selectedMmsi: null,
  selectedVessel: null,
  trajectoryMode: "triple",
  trajectoryAnimationFrame: null,
  gfwCache: new Map(),
  localView: null,
  lastFrameRisk: null,
};

const tracks = new Map(); // track_id -> { marker, trailGroup, ellipseLayer, positions, color }
const globalMarkers = new Map(); // mmsi -> marker

// ------------------------------------------------------------------- map

const map = L.map(els.map, {
  zoomControl: true,
  attributionControl: true,
  worldCopyJump: true,
}).setView([20, 0], 3);

L.tileLayer(
  // CARTO retired the "dark_matter" path (404s now); "dark_all" is the
  // live equivalent -- confirmed by curl against basemaps.cartocdn.com.
  "https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png",
  {
    subdomains: "abcd",
    maxZoom: 19,
    attribution: "&copy; OpenStreetMap contributors &copy; CARTO",
  }
).addTo(map);

const zonesLayer = L.featureGroup().addTo(map); // needs getBounds(); plain layerGroup lacks it
const localLayer = L.layerGroup().addTo(map);
const globalLayer = L.layerGroup();
const globalProjectionLayer = L.layerGroup().addTo(globalLayer);
const contextReferenceLayer = L.layerGroup();

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
  if (zones && zones.length && !state.globalLayerOn) {
    state.zonesDrawn = true;
    map.fitBounds(zonesLayer.getBounds().pad(6), { animate: false });
  }
}

async function loadContextLayers() {
  try {
    const data = await getJson("/api/context/layers");
    for (const layer of data.layers || []) {
      L.geoJSON(layer.geojson, {
        pointToLayer: (_feature, latlng) => L.circleMarker(latlng, {
          radius: 6,
          color: layer.style.color,
          weight: 2,
          fillColor: layer.style.color,
          fillOpacity: 0.35,
        }),
        style: {
          ...layer.style,
          opacity: 0.75,
          interactive: true,
        },
      })
        .bindTooltip(`${escapeHtml(layer.name)} · ${escapeHtml(layer.kind)}`)
        .addTo(contextReferenceLayer);
    }
  } catch (err) {
    console.warn("Reference layers unavailable", err);
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
  if (state.globalLayerOn) {
    els.statsTracks.textContent = state.globalVessels.length;
    els.statsDark.textContent = state.globalVessels.filter((v) => v.dark).length;
    els.idCount.textContent = "—";
    return;
  }
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

function formatUsd(value) {
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: 0,
  }).format(Number(value || 0));
}

function updateFinancialRisk(msg) {
  const risk = msg.financial_risk || { low_usd: 0, high_usd: 0, items: [] };
  state.lastFrameRisk = risk;
  if (state.selectedMmsi !== null) return;
  renderRiskPanel(risk, "Current frame");
}

function renderRiskPanel(risk, scope) {
  els.riskSummary.innerHTML =
    `<div class="risk-total"><span class="hint">Estimated response budget</span>` +
    `<span class="amount">${formatUsd(risk.low_usd)}–${formatUsd(risk.high_usd)}</span>` +
    `<span class="hint">${escapeHtml(scope)} · planning range, not realized loss</span></div>`;
  els.riskList.innerHTML = "";
  for (const item of risk.items || []) {
    const div = document.createElement("div");
    div.className = `risk-card ${item.severity === "critical" ? "critical" : ""}`;
    div.innerHTML =
      `<div class="risk-range">${formatUsd(item.low_usd)}–${formatUsd(item.high_usd)}</div>` +
      `<div class="risk-label">${escapeHtml(item.label)}</div>` +
      `<div class="risk-basis">${escapeHtml(item.basis || "Deterministic Aegis response-cost rule.")}</div>`;
    els.riskList.appendChild(div);
  }
  if (!(risk.items || []).length) {
    els.riskList.innerHTML = `<p class="hint">No active incident-response costs in this frame.</p>`;
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

function globalMarkerIcon(v) {
  const severity = (v.risk?.items || []).some((item) => item.severity === "critical")
    ? " critical"
    : (v.risk?.items || []).length ? " warning" : "";
  return L.divIcon({
    className: "global-dot",
    html: `<div class="global-contact${v.dark ? " dark" : ""}${severity}"></div>`,
    iconSize: [8, 8],
    iconAnchor: [4, 4],
  });
}

function projectedPoint(lat, lon, bearingDeg, distanceNm) {
  const radiusNm = 3440.065;
  const angular = distanceNm / radiusNm;
  const bearing = bearingDeg * Math.PI / 180;
  const lat1 = lat * Math.PI / 180;
  const lon1 = lon * Math.PI / 180;
  const lat2 = Math.asin(
    Math.sin(lat1) * Math.cos(angular) +
    Math.cos(lat1) * Math.sin(angular) * Math.cos(bearing)
  );
  const lon2 = lon1 + Math.atan2(
    Math.sin(bearing) * Math.sin(angular) * Math.cos(lat1),
    Math.cos(angular) - Math.sin(lat1) * Math.sin(lat2)
  );
  return [lat2 * 180 / Math.PI, lon2 * 180 / Math.PI];
}

function trajectoryScenarios(v) {
  const course = Number(v.course) || 0;
  const speed = Math.max(0, Number(v.speed_kn) || 0);
  const runNm = speed * 0.5;
  const scenarios = [
    { label: "Maintain course", bearing: course, distance: runNm, color: "#2dd4bf" },
    { label: "Turn +35°", bearing: course + 35, distance: runNm, color: "#5ec8d8" },
    { label: "Turn −35°", bearing: course - 35, distance: runNm, color: "#a78bfa" },
  ];
  return state.trajectoryMode === "single" ? scenarios.slice(0, 1) : scenarios;
}

function stopTrajectoryAnimation() {
  if (state.trajectoryAnimationFrame !== null) {
    cancelAnimationFrame(state.trajectoryAnimationFrame);
    state.trajectoryAnimationFrame = null;
  }
}

function startTrajectoryAnimation(runners) {
  stopTrajectoryAnimation();
  const startedAt = performance.now();
  const durationMs = 4800;
  const animate = (now) => {
    const phase = ((now - startedAt) % durationMs) / durationMs;
    const eased = phase < 0.5
      ? 2 * phase * phase
      : 1 - Math.pow(-2 * phase + 2, 2) / 2;
    for (const runner of runners) {
      runner.marker.setLatLng([
        runner.start[0] + (runner.end[0] - runner.start[0]) * eased,
        runner.start[1] + (runner.end[1] - runner.start[1]) * eased,
      ]);
    }
    state.trajectoryAnimationFrame = requestAnimationFrame(animate);
  };
  state.trajectoryAnimationFrame = requestAnimationFrame(animate);
}

function hideTrajectory() {
  stopTrajectoryAnimation();
  state.selectedMmsi = null;
  state.selectedVessel = null;
  globalProjectionLayer.clearLayers();
  els.trajectoryPanel.classList.add("hidden");
  if (state.lastFrameRisk) renderRiskPanel(state.lastFrameRisk, "Current frame");
}

function renderGfwIdentity(data) {
  if (!data.configured) {
    els.trajectoryGfw.innerHTML =
      `<div class="trajectory-heading">Global Fishing Watch</div>` +
      `<div>Token not configured in local <code>.env</code>.</div>`;
    return;
  }
  if (!data.matched) {
    const reason = data.error ? ` · ${escapeHtml(data.error)}` : "";
    els.trajectoryGfw.innerHTML =
      `<div class="trajectory-heading">Global Fishing Watch</div>` +
      `<div>No identity match${reason}.</div>`;
    return;
  }
  const details = [
    data.name,
    data.flag ? `flag ${data.flag}` : "",
    data.imo && data.imo !== "0" ? `IMO ${data.imo}` : "",
    (data.ship_types || []).join(", "),
    Number.isFinite(Number(data.positions_count))
      ? `${Number(data.positions_count).toLocaleString()} historical positions`
      : "",
  ].filter(Boolean);
  els.trajectoryGfw.innerHTML =
    `<div class="trajectory-heading">Global Fishing Watch identity</div>` +
    `<div>${details.map(escapeHtml).join(" · ")}</div>`;
}

async function loadGfwIdentity(mmsi) {
  if (state.gfwCache.has(mmsi)) {
    renderGfwIdentity(state.gfwCache.get(mmsi));
    return;
  }
  els.trajectoryGfw.innerHTML =
    `<div class="trajectory-heading">Global Fishing Watch</div><div>Checking vessel identity…</div>`;
  try {
    const data = await getJson(`/api/global/${encodeURIComponent(mmsi)}/gfw`);
    state.gfwCache.set(mmsi, data);
    if (state.selectedMmsi === mmsi) renderGfwIdentity(data);
  } catch (err) {
    if (state.selectedMmsi === mmsi) {
      renderGfwIdentity({ configured: true, matched: false, error: "request_failed" });
    }
  }
}

function showTrajectory(v) {
  state.selectedMmsi = v.mmsi;
  state.selectedVessel = v;
  stopTrajectoryAnimation();
  globalProjectionLayer.clearLayers();
  const start = [Number(v.lat), Number(v.lon)];
  const scenarios = trajectoryScenarios(v);
  const age = Math.max(0, Number(v.age_s) || 0);
  const lastFix = new Date((Number(v.last_seen) || Date.now() / 1000) * 1000);
  const context = v.context || {};
  const risk = v.risk || { low_usd: 0, high_usd: 0, items: [] };

  els.trajectoryName.textContent = v.name || `MMSI ${v.mmsi}`;
  els.trajectoryMeta.innerHTML =
    `Last fix: ${escapeHtml(lastFix.toISOString().slice(11, 19))} UTC<br>` +
    `${v.dark ? `Dark for: ${Math.round(age)} s<br>` : ""}` +
    `MMSI: ${escapeHtml(v.mmsi)}${v.imo ? ` · IMO: ${escapeHtml(v.imo)}` : ""}<br>` +
    `Track: ${Number(v.course || 0).toFixed(0)}° · ${Number(v.speed_kn || 0).toFixed(1)} kn` +
    `${v.destination ? `<br>Destination: ${escapeHtml(v.destination)}` : ""}` +
    `${v.call_sign ? ` · Call sign: ${escapeHtml(v.call_sign)}` : ""}`;

  const contextLines = [];
  if (context.ofac) {
    contextLines.push(
      `<strong class="context-critical">OFAC match:</strong> ${escapeHtml(context.ofac.name)} ` +
      `(${escapeHtml(context.ofac.program)}, via ${escapeHtml(context.ofac.match_basis)})`
    );
  }
  if (context.in_sanctuary) contextLines.push("Inside Monterey Bay sanctuary");
  if (context.in_port) {
    contextLines.push(
      `${escapeHtml(context.port?.name || "SAN FRANCISCO")} port · ` +
      `${Number(context.port?.distance_km || 0).toFixed(1)} km · NGA World Port Index`
    );
  }
  if (context.on_land) contextLines.push("Position intersects coastline data");
  for (const cable of context.near_cables || []) {
    contextLines.push(`${escapeHtml(cable.name)} cable · ${Number(cable.distance_km).toFixed(1)} km`);
  }
  els.trajectoryContext.innerHTML = contextLines.length
    ? `<div class="trajectory-heading">Reference-data matches</div>${contextLines.map((line) => `<div>${line}</div>`).join("")}`
    : `<div class="context-clear">No bundled reference-data match at this position.</div>`;
  loadGfwIdentity(v.mmsi);
  els.trajectoryRisk.innerHTML =
    `<div class="trajectory-heading">Financial response range</div>` +
    `<div class="trajectory-cost">${formatUsd(risk.low_usd)}–${formatUsd(risk.high_usd)}</div>`;
  renderRiskPanel(risk, v.name || `MMSI ${v.mmsi}`);
  els.trajectoryOptions.innerHTML = "";
  const runners = [];

  if ((v.history || []).length > 1) {
    L.polyline(v.history, {
      color: "#ffb020",
      weight: 2,
      opacity: 0.65,
      interactive: false,
    }).addTo(globalProjectionLayer);
  }

  scenarios.forEach((scenario, index) => {
    const end = projectedPoint(start[0], start[1], scenario.bearing, scenario.distance);
    L.polyline([start, end], {
      color: scenario.color,
      weight: 2,
      opacity: 0.9,
      dashArray: "6 5",
      interactive: false,
      className: `trajectory-path trajectory-path-${index}`,
    }).addTo(globalProjectionLayer);
    L.circle(end, {
      radius: 450 + age * 8,
      color: scenario.color,
      weight: 1,
      opacity: 0.75,
      fillColor: scenario.color,
      fillOpacity: 0.08,
      dashArray: "3 4",
      interactive: false,
      className: "trajectory-radius",
    }).addTo(globalProjectionLayer);
    const runner = L.circleMarker(start, {
      radius: 4,
      color: scenario.color,
      weight: 2,
      fillColor: "#ffffff",
      fillOpacity: 1,
      interactive: false,
      className: "trajectory-runner",
    }).addTo(globalProjectionLayer);
    runners.push({ marker: runner, start, end });

    const row = document.createElement("div");
    row.className = "trajectory-option";
    row.innerHTML =
      `<span class="trajectory-swatch" style="background:${scenario.color}"></span>` +
      `<span>${escapeHtml(scenario.label)}</span>` +
      `<span class="trajectory-distance">${scenario.distance.toFixed(1)} nm</span>`;
    els.trajectoryOptions.appendChild(row);
  });
  startTrajectoryAnimation(runners);
  els.trajectoryPanel.classList.remove("hidden");
  if (map.getZoom() < 9) map.setView(start, 9, { animate: true });
}

function applyGlobalFix(v) {
  let m = globalMarkers.get(v.mmsi);
  if (!m) {
    m = L.marker([v.lat, v.lon], {
      icon: globalMarkerIcon(v),
      interactive: true,
      keyboard: true,
      riseOnHover: true,
    }).addTo(globalLayer);
    m.on("click", () => showTrajectory(m._fix));
    m.bindTooltip("", { sticky: true });
    globalMarkers.set(v.mmsi, m);
  } else {
    m.setLatLng([v.lat, v.lon]);
    const riskHigh = Number(v.risk?.high_usd || 0);
    if (m._dark !== !!v.dark || m._riskHigh !== riskHigh) m.setIcon(globalMarkerIcon(v));
  }
  m._fix = v;
  m._dark = !!v.dark;
  m._riskHigh = Number(v.risk?.high_usd || 0);
  const contextFlags = [
    v.context?.ofac ? "OFAC MATCH" : "",
    v.context?.in_sanctuary ? "SANCTUARY" : "",
    (v.context?.near_cables || []).length ? "CABLE PROXIMITY" : "",
  ].filter(Boolean);
  m.setTooltipContent(
    `${escapeHtml(v.name || `MMSI ${v.mmsi}`)} · ${Number(v.course || 0).toFixed(0)}° · ` +
    `${Number(v.speed_kn || 0).toFixed(1)} kn${v.dark ? " · DARK / COASTING" : ""}` +
    `${contextFlags.length ? ` · ${contextFlags.join(" · ")}` : ""}`
  );
  if (state.selectedMmsi === v.mmsi) showTrajectory(v);
}

els.trajectoryClose.addEventListener("click", hideTrajectory);
for (const button of document.querySelectorAll(".trajectory-mode")) {
  button.addEventListener("click", () => {
    state.trajectoryMode = button.dataset.trajectoryMode;
    for (const other of document.querySelectorAll(".trajectory-mode")) {
      other.classList.toggle("active", other === button);
    }
    if (state.selectedVessel) showTrajectory(state.selectedVessel);
  });
}

function globalStatusText() {
  if (state.globalLive) {
    return `LIVE AISSTREAM · ${state.globalVessels.length} contacts`;
  }
  if (!state.globalStatus.configured) {
    return "LIVE AIS DISABLED · ADD AISSTREAM_API_KEY TO .env";
  }
  if (state.globalStatus.connected) {
    return "AISSTREAM CONNECTED · WAITING FOR POSITION REPORTS";
  }
  return "AISSTREAM CONNECTING / RETRYING";
}

function setGlobalLayer(on) {
  state.globalLayerOn = on;
  document.body.classList.toggle("live-mode", on);
  els.btnGlobalLayer.classList.toggle("active", on);
  if (on) {
    state.localView = { center: map.getCenter(), zoom: map.getZoom() };
    map.removeLayer(localLayer);
    globalLayer.addTo(map);
    map.setView([20, 0], 3, { animate: false });
    els.statsTracks.textContent = state.globalVessels.length;
    els.statsDark.textContent = state.globalVessels.filter((v) => v.dark).length;
    els.globalBadge.classList.remove("hidden");
    els.globalBadge.textContent = globalStatusText();
  } else {
    hideTrajectory();
    map.removeLayer(globalLayer);
    localLayer.addTo(map);
    if (state.localView) {
      map.setView(state.localView.center, state.localView.zoom, { animate: false });
      state.localView = null;
    }
    els.globalBadge.classList.add("hidden");
  }
}
els.btnGlobalLayer.addEventListener("click", () => setGlobalLayer(!state.globalLayerOn));

map.on("zoomend", () => {
  if (map.getZoom() >= 7) {
    if (!map.hasLayer(contextReferenceLayer)) contextReferenceLayer.addTo(map);
  } else if (map.hasLayer(contextReferenceLayer)) {
    map.removeLayer(contextReferenceLayer);
  }
  if (state.selectedMmsi) return;
  const shouldGlobal = map.getZoom() < GLOBAL_ZOOM_THRESHOLD;
  if (shouldGlobal !== state.globalLayerOn) setGlobalLayer(shouldGlobal);
});

let globalPollTimer = null;
async function pollGlobal() {
  try {
    const data = await getJson("/api/global");
    state.globalLive = !!data.live;
    state.globalStatus = data.status || {};
    state.globalVessels = data.vessels || [];
    const seen = new Set();
    for (const v of state.globalVessels) {
      seen.add(v.mmsi);
      applyGlobalFix(v);
    }
    for (const [mmsi, marker] of globalMarkers) {
      if (seen.has(mmsi)) continue;
      globalLayer.removeLayer(marker);
      globalMarkers.delete(mmsi);
      if (state.selectedMmsi === mmsi) hideTrajectory();
    }
    if (state.globalLayerOn) {
      els.statsTracks.textContent = state.globalVessels.length;
      els.statsDark.textContent = state.globalVessels.filter((v) => v.dark).length;
      const status = data.status || {};
      els.globalBadge.textContent = state.globalLive
        ? `LIVE AISSTREAM · ${state.globalVessels.length} contacts · ` +
          `${Number(status.position_reports || 0).toLocaleString()} positions · ` +
          `${Number(status.static_reports || 0).toLocaleString()} static/voyage · ` +
          `${status.regions || 0} regions`
        : globalStatusText();
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
    updateFinancialRisk(msg);
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
  else if (ev.key === "Escape" && state.selectedMmsi !== null) hideTrajectory();
  else if (ev.key === "Escape") els.btnReset.click();
});

setGlobalLayer(true);
connect();
jtmsReset().then(loadBrief);
loadContextLayers();
