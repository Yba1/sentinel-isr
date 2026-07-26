"use strict";
/* Sentinel-ISR frontend. Dumb by design: every value drawn here is a
 * verbatim field from the server's FrameDelta (jac/render.jac). If this file
 * starts computing something -- a position, a color, a severity -- that
 * computation belongs on the server instead.
 *
 * The one thing this file DOES do is merge: the server streams a full
 * snapshot of every live track each tick (not a diff), and this file is what
 * turns a sequence of snapshots into continuity -- trails, smooth marker
 * motion, a scrolling log -- keyed by track_id.
 */

const TRAIL_LEN = 20;
const MAX_LOG_LINES = 400;

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
};

const tracks = new Map(); // track_id -> { marker, trailGroup, positions, color }

// ------------------------------------------------------------------- map

const map = L.map(els.map, {
  zoomControl: true,
  attributionControl: false,
  worldCopyJump: false,
}).setView([37.808, -122.42], 12);

L.tileLayer(
  "https://{s}.basemaps.cartocdn.com/dark_matter/{z}/{x}/{y}{r}.png",
  { subdomains: "abcd", maxZoom: 19 }
).addTo(map);

const zonesLayer = L.layerGroup().addTo(map);

function drawZones(zones) {
  if (state.zonesDrawn) return;
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
    // Frame the operating area, not an arbitrary default center -- the very
    // first thing on screen should be the water the tracks live in.
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
  }).addTo(map);
  const trailGroup = L.layerGroup().addTo(map);
  t = { marker, trailGroup, positions: [], color: tp.color, heading: tp.heading_deg };
  tracks.set(tp.track_id, t);
  return t;
}

function redrawTrail(t) {
  t.trailGroup.clearLayers();
  const pos = t.positions;
  const segs = pos.length - 1;
  for (let i = 0; i < segs; i++) {
    const age = (i + 1) / segs; // 0 = oldest segment, 1 = newest
    L.polyline([pos[i], pos[i + 1]], {
      color: t.color,
      weight: 2,
      opacity: 0.12 + 0.6 * age,
      interactive: false,
    }).addTo(t.trailGroup);
  }
}

function updateTrackVisual(t, tp) {
  // Mutate the existing marker DOM in place rather than calling setIcon(),
  // which would tear down and rebuild the element every tick and flicker at
  // 60x. The .track-icon transition in style.css then animates the position
  // change smoothly between ticks.
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
  map.removeLayer(t.marker);
  map.removeLayer(t.trailGroup);
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
    updateTrackVisual(t, tp);
  }
  // The server sends the full live-track snapshot every tick (see
  // jac/render.jac Renderer -- it re-visits every live Track, not a diff),
  // so anything drawn here that is absent from this frame is gone: dropped,
  // or the run jumped past it on a seek. One rule handles both.
  for (const id of Array.from(tracks.keys())) {
    if (!seen.has(id)) removeTrack(id);
  }
}

// -------------------------------------------------------------- event log

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

const LOG_TAG_RE = /^\[(\d+):(\d{2}):(\d{2})\]\s*(EVENT|TRACK|ZONE)\s+(.*)$/;

function parseLogLine(line) {
  const m = LOG_TAG_RE.exec(line);
  if (!m) return { t: 0, cls: "log-log", html: escapeHtml(line) };
  const t = Number(m[1]) * 3600 + Number(m[2]) * 60 + Number(m[3]);
  const tag = m[4];
  return {
    t,
    cls: `log-${tag.toLowerCase()}`,
    html: `<span class="tag">[${tag}]</span>${escapeHtml(m[5])}`,
  };
}

function alertEntry(a) {
  const who = a.track_id ? `${a.track_id}: ` : "";
  return {
    t: a.t,
    cls: `log-alert-${a.severity}`,
    html: `<span class="tag">[Alert]</span>${escapeHtml(who + a.headline)}`,
  };
}

function fusionEntry(msg) {
  const tentative = (msg.tracks || []).filter((t) => t.status === "tentative").length;
  const s = msg.stats || {};
  return {
    t: msg.t,
    cls: "log-fusion",
    html:
      `<span class="tag">[Fusion]</span>f${msg.frame_idx} · ${s.n_meas ?? 0} meas ` +
      `→ ${s.n_tracks ?? 0} tracks · ${tentative} hyp open`,
  };
}

function renderLogEntries(entries, { replace }) {
  entries.sort((a, b) => a.t - b.t); // chronological, then flipped to newest-first below
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
    while (els.log.children.length > MAX_LOG_LINES) {
      els.log.removeChild(els.log.lastChild);
    }
  }
}

// ----------------------------------------------------------------- stats

function updateStats(msg) {
  const s = msg.stats || {};
  els.statsTracks.textContent = `${s.n_tracks ?? 0} live`;
  els.statsDark.textContent = `${s.n_dark ?? 0} dark`;

  if (typeof msg.id_switches === "number") {
    els.idCount.textContent = msg.id_switches;
    if (msg.id_switches > state.lastIdSwitches) {
      els.idCount.classList.remove("flash");
      // restart the animation even if it's already mid-flash
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
  for (const b of els.speedBtns) {
    b.classList.toggle("active", Number(b.dataset.speed) === speed);
  }
}

async function postJson(path, body) {
  const res = await fetch(path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body || {}),
  });
  return res.json();
}

els.btnPlay.addEventListener("click", async () => {
  const r = state.playing ? await postJson("/api/pause") : await postJson("/api/play", { speed: state.speed });
  setPlayingUi(r.playing);
});

els.btnReset.addEventListener("click", () => postJson("/api/reset"));

for (const b of els.speedBtns) {
  b.addEventListener("click", async () => {
    const speed = Number(b.dataset.speed);
    const r = await postJson("/api/speed", { speed });
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

// ---------------------------------------------------------------- websocket

function applyMessage(msg) {
  if (msg.type === "init") {
    state.totalFrames = msg.total_frames;
    state.frameIntervalS = msg.frame_interval_s;
    els.scrubber.max = String(Math.max(0, msg.total_frames - 1));
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

    if (msg.type === "sync") {
      drawZones(msg.zones && msg.zones.length ? msg.zones : null);
      const entries = [fusionEntry(msg)]
        .concat((msg.history_alerts || []).map(alertEntry))
        .concat((msg.history_log || []).map(parseLogLine));
      renderLogEntries(entries, { replace: true });
    } else {
      const entries = [fusionEntry(msg)]
        .concat((msg.alerts || []).map(alertEntry))
        .concat((msg.log || []).map(parseLogLine));
      renderLogEntries(entries, { replace: false });
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
    try {
      applyMessage(JSON.parse(ev.data));
    } catch (err) {
      console.error("bad message", err, ev.data);
    }
  };
  ws.onclose = () => {
    setConn("disconnected — retrying");
    setTimeout(connect, 1000);
  };
  ws.onerror = () => ws.close();
}

connect();
