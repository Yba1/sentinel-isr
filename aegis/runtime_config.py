"""Browser-facing runtime values loaded from the process environment."""

from __future__ import annotations

import json
import os


def runtime_carto_config_js(api_key: str | None = None) -> str:
    """Publish the CARTO basemap key to the browser as a JS assignment.

    Raster tiles from basemaps.cartocdn.com require `?key=` or they arrive
    watermarked. The key is domain-restricted by CARTO, so it is meant to
    appear on the tile URL rather than stay server-only.
    """
    key = (
        api_key if api_key is not None else os.environ.get("CARTOAPIKEY", "")
    ).strip()
    return f"window.AEGIS_CARTO_KEY={json.dumps(key)};\n"
