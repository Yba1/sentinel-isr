import json

from aegis.runtime_config import carto_api_key, runtime_carto_config_js


def test_runtime_carto_config_js_encodes_the_env_key(monkeypatch):
    monkeypatch.setenv("CARTOAPIKEY", 'cb1_test"value')

    body = runtime_carto_config_js()

    assert body.startswith("window.AEGIS_CARTO_KEY=")
    assigned = json.loads(body.split("=", 1)[1].rstrip(";\n"))
    assert assigned == 'cb1_test"value'


def test_runtime_carto_config_js_is_empty_without_a_key(monkeypatch):
    for name in ("CARTOAPIKEY", "CARTO_API_KEY", "CARTO_KEY"):
        monkeypatch.delenv(name, raising=False)

    assert runtime_carto_config_js() == 'window.AEGIS_CARTO_KEY="";\n'


def test_carto_key_accepts_railway_alias_and_strips_quotes(monkeypatch):
    monkeypatch.delenv("CARTOAPIKEY", raising=False)
    monkeypatch.setenv("CARTO_API_KEY", '"cb1_from_railway"')

    assert carto_api_key() == "cb1_from_railway"
