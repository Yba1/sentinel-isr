# Aegis

Aegis is a maritime safety and financial-risk operations dashboard. It fuses
anonymous AIS and radar detections, maintains vessel tracks through crossings,
detects protected-area intrusions, and continues predicting a vessel's position
when its transmitter goes dark.

## Safety and financial risk

- Two-stage global association preserves track continuity without using vessel identity.
- Dark contacts coast on a Kalman prediction with a visible uncertainty ellipse.
- Protected-zone entry, identity changes, and reacquisition create evidence-backed alerts.
- Each active safety event receives a transparent incident-response budget range.
  These figures are planning estimates—not claimed losses or cargo valuations.
- Clicking a global contact shows course, speed, and four 30-minute trajectory
  scenarios with widening uncertainty.

## Architecture

- `aegis/` — pure-Python orchestration, evidence graph, fusion, rendering, and briefs
- `tracker/` — Kalman filter, assignment, lifecycle, dark-vessel, and evaluation kernels
- `data/` — scenario loading, replay, geometry, and optional live AIS ingestion
- `web/` — aiohttp API/WebSocket server and Leaflet dashboard
- `scenarios/` — synthetic and real-traffic demonstration packs

The browser receives render-ready frame deltas. Tracking, severity, financial
ranges, and uncertainty calculations remain server-side.

## Run

Requires Python 3.12 (tested).

```bash
./setup_env.sh
.venv/bin/python web/server.py
```

Open <http://localhost:8765/>.

Windows:

```powershell
.\setup_env.ps1
.\.venv\Scripts\python.exe web\server.py
```

Optional `.env` values:

```dotenv
AISSTREAM_API_KEY=
AEGIS_PACK=s02_synthetic_demo
AEGIS_FRAMES=-1
AEGIS_LLM=mockllm
PORT=8765
```

Without an AISStream key, the global view is clearly labeled synthetic. Without
an LLM provider key, Aegis uses deterministic offline brief text.

With `AISSTREAM_API_KEY` set, Aegis subscribes to position plus static/voyage
reports across ten high-traffic maritime regions. It retains bounded track
history, detects stale/dark contacts, and displays vessel name, MMSI, IMO,
call sign, type, destination, heading, speed, turn rate, and navigation status
when AISStream supplies those fields. A whole-world box is intentionally not
used because its message rate can starve a single-process dashboard.

## Test

```bash
.venv/bin/python -m pytest tests/ -q
```

The suite covers association, covariance stability, dark-vessel reacquisition,
geofencing, evidence retraction, scenario contracts, financial ranges, and the
complete replay pipeline.

## Data and attribution

See `DATA_SOURCES.md` for map and scenario data sources.

Every bundled reference dataset participates at runtime:

- California coastline checks impossible/grounding positions.
- Monterey Bay sanctuary and Port of San Francisco boundaries add geofence context.
- Submarine-cable geometry adds proximity alerts.
- The OFAC vessel subset screens live contacts by MMSI, IMO, call sign, and name.
- All four scenario packs remain selectable from the dashboard.

The same layers are drawn on the map, and each live-contact click combines
reference matches, AIS history, trajectory scenarios, and a transparent
response-cost range.

Aegis includes an organizer-approved rewrite of prior maritime-tracking work
from [Yba1/sentinel-isr](https://github.com/Yba1/sentinel-isr). The runtime has
been migrated to ordinary Python and extended with Aegis branding, financial
risk estimates, global contact projections, and a redesigned dashboard.
