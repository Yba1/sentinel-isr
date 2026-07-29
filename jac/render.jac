"""Server-side rendering prep: the frontend draws, it never computes.

Everything Leaflet needs arrives pre-chewed in one FrameDelta dict per frame:
uncertainty ellipses as ready-to-draw polygon rings (eigendecomposition in
data.geometry, Python), colors picked here from the status tables, log lines
already formatted, headings/speeds already derived. If JavaScript would have
to calculate it, it belongs in this module instead.

The Renderer walker snapshots Track nodes; `frame_delta` assembles the final
dict from the driver's, fusion's and renderer's outputs.
"""

import from data.geometry { cov_ellipse_points, heading_speed }
import from data.scenario { enu_to_lla }
import from jac.graph {
    Mission, Track, Zone,
    zones_of, LIVE_STATUSES, STATUS_COASTING,
}
import from jac.driver { fmt_t }

# Operator color language: calm cyan for a healthy fused track, amber once we
# are extrapolating, hard red for alerts. Tentative stays dim until confirmed.
glob TRACK_COLORS: dict = {
    "tentative": "#5b6673",
    "confirmed": "#2dd4bf",
    "coasting": "#f59e0b",
    "dead": "#374151",
};

glob ZONE_STYLES: dict = {
    "sanctuary": {"color": "#34d399", "fillOpacity": 0.12, "dashArray": "6 4"},
    "restricted": {"color": "#f87171", "fillOpacity": 0.15, "dashArray": "2 4"},
    "zone": {"color": "#93c5fd", "fillOpacity": 0.08, "dashArray": ""},
};

glob SEVERITY_COLORS: dict = {
    "info": "#93c5fd",
    "warning": "#f59e0b",
    "critical": "#ef4444",
};

glob MEAS_STYLE: dict = {
    "ais": {"color": "#94a3b8", "radius": 3},
    "radar": {"color": "#e879f9", "radius": 6},
};


def track_color(status: str, in_zone: bool) -> str {
    if status == STATUS_COASTING and in_zone {
        return "#ef4444";      # dark inside protected water: the demo moment
    }
    return TRACK_COLORS.get(status, "#5b6673");
}


"""Ellipse growth is the visual story of a dark vessel; scale the sigma bound
so a freshly updated track shows a tight ring and a long coast fills the bay."""
def ellipse_for(trk: Track) -> list {
    return [
        [round(p[0], 1), round(p[1], 1)]
        for p in cov_ellipse_points(
            trk.x, trk.y, trk.p00, trk.p01, trk.p11,
            k_sigma=2.0, n_points=24,
        )
    ];
}


"""Same ring as ellipse_for(), converted to (lat, lon) against the mission
origin. ellipse_for() stays in ENU metres for anything that scores or tests
against ground-truth geometry; a Leaflet frontend needs lat/lon and must not
be the one doing that conversion (this project's "frontend does no
computation" rule -- see web/app.js's module docstring)."""
def ellipse_latlon_for(trk: Track, origin: tuple) -> list {
    return [
        [round(lat, 6), round(lon, 6)]
        for (lat, lon) in [enu_to_lla(p[0], p[1], origin[0], origin[1])
                           for p in cov_ellipse_points(
                               trk.x, trk.y, trk.p00, trk.p01, trk.p11,
                               k_sigma=2.0, n_points=24,
                           )]
    ];
}


walker Renderer {
    has origin: tuple = (0.0, 0.0);
    has payloads: list = [];

    can start with Mission entry {
        visit [here -->[?:Track]];
    }

    can snap with Track entry {
        if here.status not in LIVE_STATUSES {
            return;
        }
        (hdg, spd) = heading_speed(here.vx, here.vy);
        (lat, lon) = enu_to_lla(here.x, here.y, self.origin[0], self.origin[1]);
        in_zone = len(here.zones_in) > 0;
        self.payloads.append({
            "track_id": here.track_id,
            "x": round(here.x, 1),
            "y": round(here.y, 1),
            "lat": round(lat, 6),
            "lon": round(lon, 6),
            "heading_deg": round(hdg, 1),
            "speed_mps": round(spd, 2),
            "speed_kn": round(spd * 1.94384, 1),
            "status": here.status,
            "dark": here.status == STATUS_COASTING,
            "color": track_color(here.status, in_zone),
            "ellipse": ellipse_for(here),
            "ellipse_latlon": ellipse_latlon_for(here, self.origin),
            "zones": list(here.zones_in),
            "last_source": here.last_source,
            "label": f"{here.track_id} · {round(spd * 1.94384, 1)} kn",
        });
    }
}


"""Zones ship once (frame 0 or on seek), styled and in both coordinate systems
so the map layer is a pure passthrough."""
def zone_payloads(m: Mission) -> list {
    out = [];
    for z in zones_of(m) {
        style = ZONE_STYLES.get(z.kind, ZONE_STYLES["zone"]);
        out.append({
            "zone_id": z.zone_id,
            "name": z.name,
            "kind": z.kind,
            "ring": [[round(p[0], 1), round(p[1], 1)] for p in z.ring],
            "geojson": z.geojson,
            "style": style,
        });
    }
    return out;
}


def alert_payload(a: object) -> dict {
    return {
        "alert_id": a.alert_id,
        "kind": a.kind,
        "severity": a.severity,
        "color": SEVERITY_COLORS.get(a.severity, "#93c5fd"),
        "t": a.t,
        "stamp": fmt_t(a.t),
        "track_id": a.track_id,
        "zone_id": a.zone_id,
        "headline": a.headline,
        "detail": a.detail,
        "model_used": a.model_used,
    };
}


def meas_payloads(meas: list) -> list {
    return [
        {
            "meas_id": m.meas_id,
            "x": round(m.x, 1),
            "y": round(m.y, 1),
            "source": m.source,
            "style": MEAS_STYLE.get(m.source, MEAS_STYLE["ais"]),
        }
        for m in meas
    ];
}


"""One frame, one dict, ready for the WebSocket. The frontend renders this
verbatim -- any computation spotted in the JS layer is a bug in THIS file."""
def frame_delta(m: Mission, driver: object, fusion: object,
                renderer: object, include_zones: bool) -> dict {
    return {
        "frame_idx": m.frame_idx,
        "t": m.t,
        "clock": fmt_t(m.t),
        "tracks": renderer.payloads,
        "measurements": meas_payloads(driver.effective),
        "alerts": [alert_payload(a) for a in fusion.new_alerts],
        "log": driver.log + fusion.log,
        "removed_track_ids": fusion.dropped_ids,
        "zones": zone_payloads(m) if include_zones else [],
        "stats": {
            "n_tracks": len(renderer.payloads),
            "n_dark": len([p for p in renderer.payloads if p["dark"]]),
            "n_meas": len(driver.effective),
            "n_suppressed": driver.suppressed_count,
            "n_matched": fusion.n_matched,
        },
    };
}


# ----------------------------------------------------------------------- tests

import from tracker.kalman { CVKalman }
import from tracker.assoc { Track as RTrack }

test "ellipse is a closed ring that grows with covariance" {
    t1 = Track(track_id="T-1", x=0.0, y=0.0, p00=100.0, p01=0.0, p11=100.0);
    ring = ellipse_for(t1);
    assert ring[0] == ring[-1];          # closed
    assert len(ring) == 25;              # 24 points + closure
    t2 = Track(track_id="T-2", x=0.0, y=0.0, p00=10000.0, p01=0.0, p11=10000.0);
    big = ellipse_for(t2);
    # 2-sigma of sigma=100 m should reach ~200 m; of sigma=10 m only ~20 m.
    assert max([abs(p[0]) for p in big]) > 5 * max([abs(p[0]) for p in ring]);
}

test "dark track inside a zone renders alarm red" {
    assert track_color("coasting", True) == "#ef4444";
    assert track_color("coasting", False) == TRACK_COLORS["coasting"];
    assert track_color("confirmed", True) == TRACK_COLORS["confirmed"];
}

test "renderer snapshots only live tracks with derived kinematics" {
    m = Mission(pack_id="r");
    root ++> m;
    rt = RTrack(id=1, kf=CVKalman());
    live = Track(track_id="T-1", _rt=rt, status="confirmed",
                 x=100.0, y=0.0, vx=5.0, vy=0.0, p00=25.0, p11=25.0);
    gone = Track(track_id="T-2", _rt=rt, status="dead");
    m ++> live;
    m ++> gone;
    r = Renderer(origin=(37.825, -122.4)) spawn m;
    assert len(r.payloads) == 1;
    p = r.payloads[0];
    assert p["track_id"] == "T-1";
    assert abs(p["heading_deg"] - 90.0) < 0.1;     # due east
    assert abs(p["speed_kn"] - 9.7) < 0.2;         # 5 m/s
    assert abs(p["lat"] - 37.825) < 0.01;
}
