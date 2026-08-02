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

const els = {
  map: document.getElementById("map"),
  mapWrap: document.getElementById("map-wrap"),
  eventlog: document.getElementById("eventlog"),
  sidepanel: document.getElementById("sidepanel"),
  log: document.getElementById("log-entries"),
  idCount: document.getElementById("id-switch-count"),
  statsTracks: document.getElementById("stats-tracks"),
  statsDark: document.getElementById("stats-dark"),
  statsTotal: document.getElementById("stats-total"),
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
  btnBathymetry: document.getElementById("btn-bathymetry"),
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
  trajectoryHeading: document.getElementById("trajectory-heading"),
  trajectoryNote: document.getElementById("trajectory-note"),
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
  globalVessels: new Map(),
  globalRevision: 0,
  globalStatus: {},
  selectedMmsi: null,
  selectedVessel: null,
  trajectoryMode: "all",
  trajectoryAnimationFrame: null,
  trajectoryRenderId: 0,
  predictionCache: new Map(),
  gfwCache: new Map(),
  localView: null,
  preSelectionView: null,
  lastFrameRisk: null,
  bathymetryOn: false,
};

const tracks = new Map(); // track_id -> { marker, trailGroup, ellipseLayer, positions, color }
const globalMarkers = new Map(); // mmsi -> marker

// ------------------------------------------------------------------- map

const map = L.map(els.map, {
  zoomControl: false,
  attributionControl: true,
  worldCopyJump: true,
}).setView([20, 0], 3);

const AegisZoomControl = L.Control.extend({
  options: { position: "topleft" },
  onAdd(targetMap) {
    const control = L.DomUtil.create("div", "aegis-zoom-control");
    const zoomIn = L.DomUtil.create("button", "aegis-zoom-button", control);
    const zoomOut = L.DomUtil.create("button", "aegis-zoom-button", control);
    zoomIn.type = "button";
    zoomOut.type = "button";
    zoomIn.title = "Zoom in";
    zoomOut.title = "Zoom out";
    zoomIn.setAttribute("aria-label", "Zoom in");
    zoomOut.setAttribute("aria-label", "Zoom out");
    zoomIn.innerHTML = '<span aria-hidden="true"></span>';
    zoomOut.innerHTML = '<span aria-hidden="true"></span>';
    L.DomEvent.disableClickPropagation(control);
    L.DomEvent.on(zoomIn, "click", () => targetMap.zoomIn());
    L.DomEvent.on(zoomOut, "click", () => targetMap.zoomOut());
    return control;
  },
});
new AegisZoomControl().addTo(map);
map.attributionControl.setPrefix(false);

const BoatCanvasRenderer = L.Canvas.extend({
  _updateCircle(layer) {
    if (!layer.options.boatShape) {
      return L.Canvas.prototype._updateCircle.call(this, layer);
    }
    if (!this._drawing || layer._empty()) return;
    const point = layer._point;
    const zoom = this._map.getZoom();
    const densitySize = zoom <= 3
      ? 0.9
      : zoom <= 4
        ? 1.25
        : zoom <= 6
          ? 1.8
          : zoom <= 9
            ? 3
            : 5.5;
    const size = layer.options.boatSelected ? 10 : densitySize;
    const bearing = (Number(layer.options.boatBearing) || 0) * Math.PI / 180;
    const ctx = this._ctx;
    ctx.save();
    ctx.translate(point.x, point.y);
    ctx.rotate(bearing);
    ctx.beginPath();
    ctx.moveTo(0, -size * 1.45);
    ctx.lineTo(size * 0.72, size * 0.35);
    ctx.lineTo(size * 0.6, size * 1.25);
    ctx.lineTo(0, size * 0.9);
    ctx.lineTo(-size * 0.6, size * 1.25);
    ctx.lineTo(-size * 0.72, size * 0.35);
    ctx.closePath();
    ctx.restore();
    this._fillStroke(ctx, layer);
  },
});

L.tileLayer(
  // CARTO retired the "dark_matter" path (404s now); "dark_all" is the
  // live equivalent -- confirmed by curl against basemaps.cartocdn.com.
  "https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png",
  {
    subdomains: "abcd",
    maxZoom: 19,
    updateWhenZooming: true,
    updateWhenIdle: false,
    keepBuffer: 3,
    attribution:
      '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> · ' +
      '&copy; <a href="https://carto.com/attributions">CARTO</a>',
  }
).addTo(map);

let cameraInFlight = false;
let cameraSequence = 0;
function stopMapFlight() {
  cameraSequence += 1;
  cameraInFlight = false;
  map.stop();
  restoreVesselPane();
}
function flyMap(action, durationSeconds) {
  map.stop();
  const sequence = ++cameraSequence;
  cameraInFlight = true;
  return new Promise((resolve) => {
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      if (sequence !== cameraSequence) {
        resolve();
        return;
      }
      cameraInFlight = false;
      map.invalidateSize({ pan: false });
      globalRenderer._update();
      restoreVesselPane();
      resolve();
    };
    action();
    // Leaflet can emit a stale moveend from a just-cancelled flyTo. Waiting for
    // the declared duration prevents paths and runners from rendering midway
    // through the replacement camera animation.
    window.setTimeout(finish, durationSeconds * 1000 + 120);
  });
}

const bathymetryLayer = L.tileLayer.wms("https://wms.gebco.net/mapserv?", {
  layers: "GEBCO_LATEST",
  format: "image/png",
  transparent: true,
  opacity: 0.3,
  attribution: "GEBCO 2026",
});
els.btnBathymetry.addEventListener("click", () => {
  state.bathymetryOn = !state.bathymetryOn;
  els.btnBathymetry.classList.toggle("active", state.bathymetryOn);
  if (state.bathymetryOn) bathymetryLayer.addTo(map);
  else map.removeLayer(bathymetryLayer);
});

const zonesLayer = L.featureGroup().addTo(map); // needs getBounds(); plain layerGroup lacks it
const localLayer = L.layerGroup().addTo(map);
const globalLayer = L.layerGroup();
const globalProjectionLayer = L.layerGroup().addTo(globalLayer);
map.createPane("vesselPane");
map.getPane("vesselPane").style.zIndex = 390;
map.getPane("vesselPane").style.transition = "opacity 80ms linear";
const globalRenderer = new BoatCanvasRenderer({
  padding: 0.5,
  tolerance: 8,
  pane: "vesselPane",
});
let vesselPaneRestoreTimer = null;
function restoreVesselPane() {
  if (vesselPaneRestoreTimer !== null) {
    window.clearTimeout(vesselPaneRestoreTimer);
    vesselPaneRestoreTimer = null;
  }
  map.getPane("vesselPane").style.opacity = "1";
}
function hideVesselPaneDuringZoom() {
  map.getPane("vesselPane").style.opacity = "0";
  if (vesselPaneRestoreTimer !== null) {
    window.clearTimeout(vesselPaneRestoreTimer);
  }
  vesselPaneRestoreTimer = window.setTimeout(restoreVesselPane, 2200);
}
map.on("zoomstart", hideVesselPaneDuringZoom);
map.on("zoomend", () => {
  globalRenderer._update();
  if (!cameraInFlight) restoreVesselPane();
});

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

function globalContactCounts() {
  const status = state.globalStatus;
  if (Number.isFinite(Number(status.total_contacts))) {
    return {
      active: Number(status.active_contacts) || 0,
      dark: Number(status.dark_contacts) || 0,
      total: Number(status.total_contacts) || 0,
    };
  }
  let dark = 0;
  for (const vessel of state.globalVessels.values()) {
    if (vessel.dark) dark += 1;
  }
  return { active: state.globalVessels.size - dark, dark, total: state.globalVessels.size };
}

function updateStats(msg) {
  if (state.globalLayerOn) {
    const counts = globalContactCounts();
    els.statsTracks.textContent = counts.active;
    els.statsDark.textContent = counts.dark;
    els.statsTotal.textContent = counts.total;
    els.idCount.textContent = state.globalStatus.identity_switches ?? 0;
    return;
  }
  const s = msg.stats || {};
  const total = Number(s.n_tracks ?? 0);
  const dark = Number(s.n_dark ?? 0);
  els.statsTracks.textContent = Math.max(0, total - dark);
  els.statsDark.textContent = dark;
  els.statsTotal.textContent = total;
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
  const hasExposure =
    Number(risk.low_usd) > 0
    || Number(risk.high_usd) > 0
    || (risk.items || []).length > 0;
  const amount = hasExposure
    ? `${formatUsd(risk.low_usd)}–${formatUsd(risk.high_usd)}`
    : "No active exposure";
  const detail = hasExposure
    ? `${escapeHtml(scope)} · planning range, not realized loss`
    : `${escapeHtml(scope)} · monitoring only`;
  els.riskSummary.innerHTML =
    `<div class="risk-total"><span class="hint">Estimated response budget</span>` +
    `<span class="amount">${amount}</span>` +
    `<span class="hint">${detail}</span></div>`;
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
    els.riskList.innerHTML =
      `<p class="hint">Monitoring live safety signals. No response action is currently triggered.</p>`;
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
  if (state.globalLayerOn) {
    els.assocBadge.textContent = "AIS LIVE";
    els.assocBadge.classList.remove("naive");
    return;
  }
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
      `<div class="provenance">model: ${b.model_used} · ` +
      `${Number(b.cost_usd) > 0 ? `model cost: $${b.cost_usd.toFixed(4)}` : "no external model charge"} · ` +
      `sources: ${b.source_ids.join(", ")}</div>`;
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

function globalMarkerStyle(v, stale = false) {
  const critical = (v.risk?.items || []).some((item) => item.severity === "critical");
  const selected = Number(v.mmsi) === state.selectedMmsi;
  const color = selected ? "#7dd3fc" : stale ? "#94a3b8" : critical ? "#ef4444" : "#ffb020";
  return {
    boatShape: true,
    boatSelected: selected,
    boatBearing: Number(v.course) || 0,
    color,
    weight: selected ? 2.2 : v.dark ? 1.5 : 0.8,
    opacity: stale ? 0.45 : 0.95,
    fillColor: color,
    fillOpacity: selected ? 0.82 : v.dark ? 0.08 : 0.78,
    dashArray: selected ? null : v.dark ? "3 2" : null,
  };
}

function renderOceanCurrents(ocean) {
  if (!ocean?.available) return;
  const driftSeconds = 1800;
  for (const vector of ocean.vectors || []) {
    const lat = Number(vector.lat);
    const lon = Number(vector.lon);
    const end = [
      lat + Number(vector.north_mps) * driftSeconds / 111320,
      lon + Number(vector.east_mps) * driftSeconds /
        (111320 * Math.max(0.1, Math.cos(lat * Math.PI / 180))),
    ];
    L.polyline([[lat, lon], end], {
      color: "#38bdf8",
      weight: 1.5,
      opacity: 0.65,
      interactive: false,
      className: "ocean-current-vector",
    }).addTo(globalProjectionLayer);
    L.circleMarker(end, {
      radius: 2,
      color: "#7dd3fc",
      weight: 1,
      fillColor: "#7dd3fc",
      fillOpacity: 0.8,
      interactive: false,
    }).addTo(globalProjectionLayer);
    L.marker([lat, lon], {
      icon: L.divIcon({
        className: "current-arrow-icon",
        html:
          `<span style="transform:rotate(${Number(vector.bearing_deg) - 90}deg)">➤</span>`,
        iconSize: [14, 14],
        iconAnchor: [7, 7],
      }),
      interactive: true,
      keyboard: false,
    })
      .bindTooltip(
        `Copernicus current · ${Number(vector.speed_mps).toFixed(2)} m/s · ` +
        `${Number(vector.bearing_deg).toFixed(0)}°`
      )
      .addTo(globalProjectionLayer);
  }
}

function stopTrajectoryAnimation() {
  if (state.trajectoryAnimationFrame !== null) {
    cancelAnimationFrame(state.trajectoryAnimationFrame);
    state.trajectoryAnimationFrame = null;
  }
}

function trajectoryRunnerIcon(color) {
  return L.divIcon({
    className: "trajectory-runner-icon",
    html:
      `<svg viewBox="0 0 14 20" aria-hidden="true" style="color:${color}">` +
      `<path d="M7 1 L12 9 L11 17 L7 14.5 L3 17 L2 9 Z"></path>` +
      `</svg>`,
    iconSize: [14, 20],
    iconAnchor: [7, 10],
  });
}

function startTrajectoryAnimation(runners) {
  stopTrajectoryAnimation();
  let readinessFrames = 0;
  const begin = () => {
    if (
      runners.some((runner) => runner.marker.getElement() === null)
      && readinessFrames < 4
    ) {
      readinessFrames += 1;
      state.trajectoryAnimationFrame = requestAnimationFrame(begin);
      return;
    }
    const startedAt = performance.now();
    const durationMs = 4800;
    const travelEnd = 0.88;
    const fadeStart = 0.8;
    const animate = (now) => {
      const phase = ((now - startedAt) % durationMs) / durationMs;
      const progress = Math.min(1, phase / travelEnd);
      const eased = progress * progress * (3 - 2 * progress);
      const opacity = phase < fadeStart
        ? 1
        : Math.max(0, (travelEnd - phase) / (travelEnd - fadeStart));
      for (const runner of runners) {
        const scaled = eased * (runner.path.length - 1);
        const segment = Math.min(runner.path.length - 2, Math.floor(scaled));
        const fraction = scaled - segment;
        const from = runner.path[segment];
        const to = runner.path[segment + 1];
        const bearing = Math.atan2(
          (to[1] - from[1]) * Math.cos(from[0] * Math.PI / 180),
          to[0] - from[0]
        ) * 180 / Math.PI;
        runner.marker.setLatLng([
          from[0] + (to[0] - from[0]) * fraction,
          from[1] + (to[1] - from[1]) * fraction,
        ]);
        const element = runner.marker.getElement();
        if (element) {
          element.style.opacity = String(opacity);
          const boat = element.querySelector("svg");
          if (boat) boat.style.transform = `rotate(${bearing}deg)`;
        }
      }
      state.trajectoryAnimationFrame = requestAnimationFrame(animate);
    };
    state.trajectoryAnimationFrame = requestAnimationFrame(animate);
  };
  state.trajectoryAnimationFrame = requestAnimationFrame(begin);
}

function hideTrajectory({ restoreView = true } = {}) {
  stopMapFlight();
  stopTrajectoryAnimation();
  setTrajectoryModesDisabled(false);
  state.trajectoryRenderId += 1;
  const returnView = state.preSelectionView;
  state.preSelectionView = null;
  if (state.selectedMmsi !== null) {
    postJson("/api/global/pin", { mmsi: null }).catch(() => {});
  }
  const selectedMarker = globalMarkers.get(state.selectedMmsi);
  state.selectedMmsi = null;
  if (selectedMarker) {
    selectedMarker.setStyle(globalMarkerStyle(selectedMarker._fix || {}));
    selectedMarker.closeTooltip();
  }
  state.selectedVessel = null;
  globalProjectionLayer.clearLayers();
  els.trajectoryPanel.classList.add("hidden");
  if (els.trajectoryPanel.parentElement !== els.mapWrap) {
    els.mapWrap.appendChild(els.trajectoryPanel);
  }
  map.invalidateSize({ pan: false });
  if (state.lastFrameRisk) renderRiskPanel(state.lastFrameRisk, "Current frame");
  if (restoreView && returnView && state.globalLayerOn) {
    flyMap(
      () => map.flyTo(returnView.center, returnView.zoom, {
        animate: true,
        duration: 1.45,
        easeLinearity: 0.18,
      }),
      1.45
    );
  }
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

function refreshSelectedVessel(v) {
  state.selectedVessel = v;
  const age = Math.max(0, Number(v.age_s) || 0);
  const lastFix = new Date((Number(v.last_seen) || Date.now() / 1000) * 1000);
  const risk = v.risk || { low_usd: 0, high_usd: 0, items: [] };
  els.trajectoryName.textContent = v.name || `MMSI ${v.mmsi}`;
  els.trajectoryMeta.innerHTML =
    `Last fix: ${escapeHtml(lastFix.toISOString().slice(11, 19))} UTC<br>` +
    `${v.dark ? `Dark for: ${Math.round(age)} s<br>` : ""}` +
    `MMSI: ${escapeHtml(v.mmsi)}${v.imo ? ` · IMO: ${escapeHtml(v.imo)}` : ""}<br>` +
    `Track: ${Number(v.course || 0).toFixed(0)}° · ${Number(v.speed_kn || 0).toFixed(1)} kn` +
    `${v.destination ? `<br>Destination: ${escapeHtml(v.destination)}` : ""}` +
    `${v.call_sign ? ` · Call sign: ${escapeHtml(v.call_sign)}` : ""}`;
  els.trajectoryRisk.innerHTML =
    `<div class="trajectory-heading">Financial response range</div>` +
    `<div class="trajectory-cost">${formatUsd(risk.low_usd)}–${formatUsd(risk.high_usd)}</div>`;
  renderRiskPanel(risk, v.name || `MMSI ${v.mmsi}`);
}

function trajectoryBounds(scenarios, start) {
  const bounds = L.latLngBounds(
    scenarios.flatMap((scenario) => scenario.path).concat([start])
  );
  for (const scenario of scenarios) {
    const end = scenario.path[scenario.path.length - 1];
    const radiusM = Math.max(0, Number(scenario.uncertainty_radius_m) || 0);
    const latRadius = radiusM / 111320;
    const lonRadius = latRadius /
      Math.max(0.1, Math.cos(Number(end[0]) * Math.PI / 180));
    bounds.extend([Number(end[0]) - latRadius, Number(end[1]) - lonRadius]);
    bounds.extend([Number(end[0]) + latRadius, Number(end[1]) + lonRadius]);
  }
  return bounds;
}

function setTrajectoryModesDisabled(disabled) {
  for (const button of document.querySelectorAll(".trajectory-mode")) {
    button.disabled = disabled;
  }
}

async function showTrajectory(v, { adjustCamera = true } = {}) {
  const renderId = ++state.trajectoryRenderId;
  if (adjustCamera) stopMapFlight();
  if (state.selectedMmsi === null) {
    const center = map.getCenter();
    state.preSelectionView = {
      center: [center.lat, center.lng],
      zoom: map.getZoom(),
    };
  }
  const previousMarker = globalMarkers.get(state.selectedMmsi);
  if (state.selectedMmsi !== v.mmsi) {
    postJson("/api/global/pin", { mmsi: v.mmsi }).catch(() => {});
  }
  state.selectedMmsi = v.mmsi;
  if (previousMarker && previousMarker !== globalMarkers.get(v.mmsi)) {
    previousMarker.setStyle(globalMarkerStyle(previousMarker._fix || {}));
  }
  const selectedMarker = globalMarkers.get(v.mmsi);
  if (selectedMarker) selectedMarker.setStyle(globalMarkerStyle(v));
  stopTrajectoryAnimation();
  globalProjectionLayer.clearLayers();
  const start = [Number(v.lat), Number(v.lon)];
  const context = v.context || {};
  refreshSelectedVessel(v);

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
  if (els.trajectoryPanel.parentElement !== els.eventlog) {
    els.eventlog.appendChild(els.trajectoryPanel);
  }
  els.trajectoryPanel.classList.remove("hidden");
  const modeSwitch = els.trajectoryPanel.querySelector(".trajectory-mode-switch");
  modeSwitch.classList.toggle("hidden", !v.dark);
  if (!v.dark) {
    setTrajectoryModesDisabled(false);
    els.trajectoryHeading.textContent = "AIS transmitting · live contact";
    els.trajectoryOptions.innerHTML =
      `<div class="trajectory-option"><span class="trajectory-swatch"></span>` +
      `<span>Current reported position</span><span class="trajectory-distance">LIVE</span></div>`;
    els.trajectoryNote.textContent =
      "No predicted trajectory is shown while this vessel is actively transmitting AIS.";
    if (adjustCamera) {
      await flyMap(
        () => map.flyTo(start, Math.max(map.getZoom(), 14), {
          animate: true,
          duration: 1.05,
          easeLinearity: 0.18,
        }),
        1.05
      );
    }
    return;
  }
  els.trajectoryHeading.textContent = "Calculating Monte Carlo branches…";
  setTrajectoryModesDisabled(true);
  els.trajectoryOptions.innerHTML = "";
  els.trajectoryNote.textContent =
    "Using observed AIS motion, a bounded decaying turn model, silence duration, ocean currents, and available coastline constraints.";
  const cacheKey = `${v.mmsi}:${v.last_seen}`;
  let prediction = state.predictionCache.get(cacheKey);
  try {
    if (!prediction) {
      prediction = await getJson(`/api/global/${encodeURIComponent(v.mmsi)}/prediction`);
      state.predictionCache.set(cacheKey, prediction);
    }
  } catch (_err) {
    if (state.trajectoryRenderId === renderId) {
      setTrajectoryModesDisabled(false);
      els.trajectoryHeading.textContent = "Prediction unavailable";
      els.trajectoryNote.textContent = "The dark-contact model could not be calculated.";
    }
    return;
  }
  if (state.trajectoryRenderId !== renderId || state.selectedMmsi !== v.mmsi) return;

  const colors = ["#2dd4bf", "#5ec8d8", "#a78bfa", "#f59e0b", "#f472b6",
    "#60a5fa", "#34d399", "#fb7185", "#c084fc", "#facc15"];
  const allScenarios = prediction.scenarios || [];
  const scenarios = state.trajectoryMode === "single"
    ? allScenarios.slice(0, 1)
    : allScenarios;
  const bounds = trajectoryBounds(scenarios, start);
  if (adjustCamera && bounds.isValid()) {
    await flyMap(
      () => map.flyToBounds(bounds, {
        padding: [64, 64],
        maxZoom: 15,
        animate: true,
        duration: 1.15,
        easeLinearity: 0.18,
      }),
      1.15
    );
  }
  if (state.trajectoryRenderId !== renderId || state.selectedMmsi !== v.mmsi) return;
  const runners = [];
  els.trajectoryHeading.textContent =
    `${prediction.samples} Monte Carlo runs · ${allScenarios.length} branches · ` +
    `${prediction.horizon_minutes} minute outlook`;
  els.trajectoryOptions.innerHTML = "";
  renderOceanCurrents(prediction.ocean_conditions);

  if ((v.history || []).length > 1) {
    L.polyline(v.history, {
      color: "#ffb020",
      weight: 2,
      opacity: 0.65,
      interactive: false,
    }).addTo(globalProjectionLayer);
  }
  scenarios.forEach((scenario, index) => {
    const color = colors[index % colors.length];
    const path = scenario.path;
    const end = path[path.length - 1];
    L.polyline(path, {
      color,
      weight: 2,
      opacity: 0.9,
      dashArray: "6 5",
      interactive: false,
      className: `trajectory-path trajectory-path-${index}`,
    }).addTo(globalProjectionLayer);
    L.circle(end, {
      radius: Number(scenario.uncertainty_radius_m) || 100,
      color,
      weight: 1,
      opacity: 0.75,
      fillColor: color,
      fillOpacity: 0.08,
      dashArray: "3 4",
      interactive: false,
      className: "trajectory-radius",
    }).addTo(globalProjectionLayer);
    const runner = L.marker(start, {
      icon: trajectoryRunnerIcon(color),
      interactive: false,
      keyboard: false,
      zIndexOffset: 1000,
    }).addTo(globalProjectionLayer);
    runner._trajectoryRunner = true;
    runners.push({ marker: runner, path });

    const row = document.createElement("div");
    row.className = "trajectory-option";
    row.innerHTML =
      `<span class="trajectory-swatch" style="background:${color}"></span>` +
      `<span>Branch ${index + 1} · ${(Number(scenario.probability) * 100).toFixed(1)}%</span>` +
      `<span class="trajectory-distance">${Number(scenario.distance_nm).toFixed(1)} nm</span>`;
    els.trajectoryOptions.appendChild(row);
  });
  const unavailable = Object.entries(prediction.signal_availability || {})
    .filter(([, available]) => !available)
    .map(([name]) => name.replaceAll("_", " "));
  const drivers = prediction.uncertainty_drivers || [];
  const current = prediction.ocean_conditions?.center;
  const currentText = current
    ? `Copernicus surface current: ${Number(current.speed_mps).toFixed(2)} m/s ` +
      `toward ${Number(current.bearing_deg).toFixed(0)}°. `
    : prediction.ocean_conditions?.pending
      ? "Copernicus current is warming asynchronously; this result uses AIS motion only. "
    : "";
  const timingText =
    `Path spans ${Number(prediction.path_minutes_from_last_fix).toFixed(0)} minutes ` +
    `from the last AIS fix, including ${Math.round(Number(v.age_s) / 60)} minutes silent. `;
  els.trajectoryNote.textContent =
    currentText +
    timingText +
    `${drivers.length ? `Uncertainty increased by: ${drivers.join(", ")}. ` : ""}` +
    `${unavailable.length ? `Unavailable: ${unavailable.join(", ")}.` : ""}`;
  startTrajectoryAnimation(runners);
  setTrajectoryModesDisabled(false);
}

function applyGlobalFix(v) {
  let m = globalMarkers.get(v.mmsi);
  if (!m) {
    m = L.circleMarker([v.lat, v.lon], {
      renderer: globalRenderer,
      radius: 8,
      ...globalMarkerStyle(v),
      interactive: true,
      bubblingMouseEvents: false,
    }).addTo(globalLayer);
    m.on("click", () => showTrajectory(m._fix));
    m.bindTooltip("", { sticky: true });
    globalMarkers.set(v.mmsi, m);
  } else {
    m.setLatLng([v.lat, v.lon]);
    m.setStyle(globalMarkerStyle(v));
  }
  m._stale = false;
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
  if (state.selectedMmsi === v.mmsi) {
    const resumedAis = state.selectedVessel?.dark && !v.dark;
    if (resumedAis) showTrajectory(v);
    else refreshSelectedVessel(v);
  }
}

els.trajectoryClose.addEventListener("click", hideTrajectory);
for (const button of document.querySelectorAll(".trajectory-mode")) {
  button.addEventListener("click", () => {
    if (button.disabled) return;
    state.trajectoryMode = button.dataset.trajectoryMode;
    for (const other of document.querySelectorAll(".trajectory-mode")) {
      other.classList.toggle("active", other === button);
    }
    if (state.selectedVessel) {
      showTrajectory(state.selectedVessel, { adjustCamera: false });
    }
  });
}

function globalStatusText() {
  if (state.globalLive) {
    return `LIVE AISSTREAM · ${globalContactCounts().total} contacts`;
  }
  if (!state.globalStatus.configured) {
    return "LIVE AIS DISABLED · ADD AISSTREAM_API_KEY TO .env";
  }
  if (state.globalStatus.connected) {
    return "AISSTREAM CONNECTED · WAITING FOR POSITION REPORTS";
  }
  return "AISSTREAM CONNECTING / RETRYING";
}

function renderLiveRail(status) {
  if (!document.getElementById("live-rail-contacts")) {
    els.log.innerHTML =
      `<div class="log-line log-track"><span class="tag">[AIS]</span><span id="live-rail-contacts"></span></div>` +
      `<div class="log-line log-fusion"><span class="tag">[STREAM]</span><span id="live-rail-messages"></span></div>` +
      `<div class="log-line log-event"><span class="tag">[IDENTITY]</span><span id="live-rail-identities"></span></div>` +
      `<div class="log-line log-zone"><span class="tag">[CONTEXT]</span>NOAA · NGA · Natural Earth · cables · OFAC</div>` +
      `<div class="log-line log-log"><span class="tag">[ENRICH]</span>Global Fishing Watch on contact selection</div>`;
  }
  const counts = globalContactCounts();
  document.getElementById("live-rail-contacts").textContent =
    `${counts.active.toLocaleString()} active · ` +
    `${counts.dark.toLocaleString()} dark · ` +
    `${counts.total.toLocaleString()} total`;
  document.getElementById("live-rail-messages").textContent =
    `${Number(status.position_reports || 0).toLocaleString()} positions · ` +
    `${Number(status.static_reports || 0).toLocaleString()} static/voyage`;
  document.getElementById("live-rail-identities").textContent =
    `${Number(status.identity_switches || 0).toLocaleString()} observed changes`;
}

function setGlobalLayer(on) {
  state.globalLayerOn = on;
  document.body.classList.toggle("live-mode", on);
  els.btnGlobalLayer.classList.toggle("active", on);
  if (on) {
    state.localView = { center: map.getCenter(), zoom: map.getZoom() };
    map.removeLayer(localLayer);
    map.removeLayer(zonesLayer);
    globalLayer.addTo(map);
    const counts = globalContactCounts();
    els.statsTracks.textContent = counts.active;
    els.statsDark.textContent = counts.dark;
    els.statsTotal.textContent = counts.total;
    els.idCount.textContent = state.globalStatus.identity_switches ?? 0;
    els.assocBadge.textContent = "AIS LIVE";
    els.assocBadge.classList.remove("naive");
    renderLiveRail(state.globalStatus);
    els.globalBadge.classList.remove("hidden");
    els.globalBadge.textContent = globalStatusText();
  } else {
    hideTrajectory({ restoreView: false });
    map.removeLayer(globalLayer);
    localLayer.addTo(map);
    zonesLayer.addTo(map);
    setAssocUi(state.assocMode);
    if (state.localView) {
      map.setView(state.localView.center, state.localView.zoom, { animate: false });
      state.localView = null;
    }
    els.globalBadge.classList.add("hidden");
  }
}
els.btnGlobalLayer.addEventListener("click", () => setGlobalLayer(!state.globalLayerOn));

let globalPollTimer = null;
async function pollGlobal() {
  try {
    const data = await getJson(`/api/global?since=${state.globalRevision}`);
    state.globalLive = !!data.live;
    state.globalStatus = data.status || {};
    if (data.full) {
      for (const marker of globalMarkers.values()) globalLayer.removeLayer(marker);
      globalMarkers.clear();
      state.globalVessels.clear();
    }
    for (const v of data.vessels || []) {
      state.globalVessels.set(v.mmsi, v);
      applyGlobalFix(v);
    }
    for (const mmsi of data.removed || []) {
      const marker = globalMarkers.get(mmsi);
      if (!marker) continue;
      if (state.selectedMmsi === mmsi) {
        marker._stale = true;
        marker.setStyle(globalMarkerStyle(marker._fix || {}, true));
        marker.setTooltipContent(
          `${escapeHtml(marker._fix?.name || `MMSI ${mmsi}`)} · selected · awaiting feed refresh`
        );
        continue;
      }
      globalLayer.removeLayer(marker);
      globalMarkers.delete(mmsi);
      state.globalVessels.delete(mmsi);
    }
    state.globalRevision = Number(data.revision) || state.globalRevision;
    if (state.globalLayerOn) {
      const counts = globalContactCounts();
      els.statsTracks.textContent = counts.active;
      els.statsDark.textContent = counts.dark;
      els.statsTotal.textContent = counts.total;
      const status = data.status || {};
      els.idCount.textContent = status.identity_switches ?? 0;
      renderLiveRail(status);
      els.globalBadge.textContent = state.globalLive
        ? `LIVE AISSTREAM · ${counts.total.toLocaleString()} contacts · ` +
          `${Number(status.position_reports || 0).toLocaleString()} positions · ` +
          `${Number(status.static_reports || 0).toLocaleString()} static/voyage · ` +
          `${Number(status.identity_switches || 0).toLocaleString()} identity changes · ` +
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
      if (!state.globalLayerOn) {
        const entries = [fusionEntry(msg)].concat((msg.history_alerts || []).map(alertEntry)).concat((msg.history_log || []).map(parseLogLine));
        renderLogEntries(entries, { replace: true });
      }
    } else {
      if (!state.globalLayerOn) {
        const entries = [fusionEntry(msg)].concat((msg.alerts || []).map(alertEntry)).concat((msg.log || []).map(parseLogLine));
        renderLogEntries(entries, { replace: false });
      }
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
