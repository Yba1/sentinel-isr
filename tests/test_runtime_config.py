import json

from aegis.runtime_config import runtime_carto_config_js


def test_runtime_carto_config_js_encodes_the_env_key(monkeypatch):
    monkeypatch.setenv("CARTOAPIKEY", 'cb1_test"value')

    body = runtime_carto_config_js()

    assert body.startswith("window.AEGIS_CARTO_KEY=")
    assigned = json.loads(body.split("=", 1)[1].rstrip(";\n"))
    assert assigned == 'cb1_test"value'


def test_runtime_carto_config_js_is_empty_without_a_key(monkeypatch):
    monkeypatch.delenv("CARTOAPIKEY", raising=False)

    assert runtime_carto_config_js() == 'window.AEGIS_CARTO_KEY="";\n'
