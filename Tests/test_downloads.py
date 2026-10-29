"""Real HTTP resume and integrity behavior, exercised against an in-process fake server."""
import hashlib
import importlib.util
import io
from pathlib import Path
import pytest

spec = importlib.util.spec_from_file_location("download_assets", Path(__file__).resolve().parents[1] / "scripts/download_assets.py")
assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assets)


class Response(io.BytesIO):
    def __init__(self, data, status=200):
        super().__init__(data)
        self.status = status


def test_resume_honors_partial_response(tmp_path, monkeypatch):
    target = tmp_path / "model.bin"
    target.with_suffix(".bin.partial").write_bytes(b"abc")
    def request(req, **kwargs):
        assert req.get_header("Range") == "bytes=3-"
        return Response(b"def", 206)
    monkeypatch.setattr(assets.urllib.request, "urlopen", request)
    assets.download("https://example.invalid/model", target, 6, hashlib.sha256(b"abcdef").hexdigest())
    assert target.read_bytes() == b"abcdef"


def test_server_ignoring_range_restarts_download(tmp_path, monkeypatch):
    target = tmp_path / "model.bin"
    target.with_suffix(".bin.partial").write_bytes(b"abc")
    monkeypatch.setattr(assets.urllib.request, "urlopen", lambda *a, **k: Response(b"abcdef"))
    assets.download("https://example.invalid/model", target, 6)
    assert target.read_bytes() == b"abcdef"


def test_corrupt_download_never_replaces_good_target(tmp_path, monkeypatch):
    target = tmp_path / "model.bin"
    target.write_bytes(b"old")
    monkeypatch.setattr(assets.urllib.request, "urlopen", lambda *a, **k: Response(b"wrong"))
    with pytest.raises(ValueError, match="Checksum"):
        assets.download("https://example.invalid/model", target, sha256=hashlib.sha256(b"good").hexdigest())
    assert target.read_bytes() == b"old"
    assert not target.with_suffix(".bin.partial").exists()


def test_complete_partial_finalizes_without_network(tmp_path, monkeypatch):
    target = tmp_path / "model.bin"
    target.with_suffix(".bin.partial").write_bytes(b"done")
    def forbidden(*args, **kwargs):
        pytest.fail("A completed partial should not request bytes past EOF")
    monkeypatch.setattr(assets.urllib.request, "urlopen", forbidden)
    assets.download("https://example.invalid/model", target, 4, hashlib.sha256(b"done").hexdigest())
    assert target.read_bytes() == b"done"


@pytest.mark.parametrize("include_jsut, expected", [(False, {"starter-en", "starter-zh"}), (True, {"starter-en", "starter-zh", "starter-ja"})])
def test_optional_reference_needs_explicit_opt_in(tmp_path, monkeypatch, include_jsut, expected):
    import json
    import sys
    import types
    sources = json.loads((assets.ROOT / "resources/starter-sources.json").read_text())
    monkeypatch.setattr(assets, "RUNTIME", tmp_path)
    hashes = {}
    for item in sources:
        raw = tmp_path / "downloads" / item["filename"]
        raw.parent.mkdir(exist_ok=True)
        raw.touch()
        hashes[raw] = item["sha256"]
        target = tmp_path / "voices" / (item["id"] + ".wav")
        target.parent.mkdir(exist_ok=True)
        target.touch()
    monkeypatch.setattr(assets, "checksum", lambda p: hashes[Path(p)])
    monkeypatch.setitem(sys.modules, "soundfile", types.SimpleNamespace(info=lambda p: types.SimpleNamespace(duration=5)))
    assets.install_voices(include_jsut=include_jsut)
    profiles = json.loads((tmp_path / "starter-voices.json").read_text())
    assert {p["id"] for p in profiles} == expected
    # A subsequent repair must retain a voice the user already opted into.
    assets.install_voices()
    assert {p["id"] for p in json.loads((tmp_path / "starter-voices.json").read_text())} == expected
