"""Части выпуска и latest.json — на маленьком файле вместо модели."""

import hashlib
import json

from tools.gen_model import release


def test_split_and_latest(tmp_path, monkeypatch):
    monkeypatch.setattr(release, "OUT", tmp_path)
    monkeypatch.setattr(release, "PART_BYTES", 1000)
    data = bytes(range(256)) * 10  # 2560 байт → 3 части
    model = tmp_path / release.gguf_name("1.2.3")
    model.write_bytes(data)
    (tmp_path / "verify.json").write_text(json.dumps({
        "version": "1.2.3", "file": model.name, "size": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "base_revision": release.REVISION, "quant": release.QUANT,
    }))
    parts = release.split("1.2.3")
    assert [p["size"] for p in parts] == [1000, 1000, 560]
    assert [p["file"] for p in parts][-1] == "tridot-gen-1.2.3.gguf.003"
    glued = b"".join((tmp_path / "parts" / p["file"]).read_bytes() for p in parts)
    assert glued == data
    out = release.latest("1.2.3", "https://github.com/x/y/releases/download/gen-latest/", tmp_path / "latest.json")
    m = out["model"]
    assert out["format"] == "tridot-gen-latest/1"
    assert m["size"] == len(data) and m["sha256"] == hashlib.sha256(data).hexdigest()
    assert m["parts"][0]["url"] == "https://github.com/x/y/releases/download/gen-latest/tridot-gen-1.2.3.gguf.001"
    assert m["parts"][1]["sha256"] == hashlib.sha256(data[1000:2000]).hexdigest()
    assert m["base_revision"] == release.REVISION and m["min_ram_mb"] == release.MIN_RAM_MB


def test_part_under_github_limit():
    assert release.PART_BYTES < 2 * 1024**3
