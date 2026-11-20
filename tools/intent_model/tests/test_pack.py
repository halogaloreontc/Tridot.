"""Индекс, манифест, архив и latest.json — на поддельной модели."""

import hashlib
import json
import zipfile

import numpy as np

from tools.intent_model import config, pack


def _fake_pack(tmp_path, tier_name="light"):
    d = tmp_path / tier_name
    d.mkdir()
    rng = np.random.default_rng(0)
    emb = rng.normal(size=(6, 8)).astype(np.float32)
    emb /= np.linalg.norm(emb, axis=1, keepdims=True)
    labels = ["tasks:task.create", "none", "calc:calc.evaluate", "tasks:task.create", "none", "calc:calc.evaluate"]
    names = pack.write_index(d / "index.bin", emb, labels)
    pack.write_labels(d / "labels.json", names, {"tasks:task.create": "создать задачу", "calc:calc.evaluate": "посчитать"})
    (d / "model.int8.onnx").write_bytes(b"not a real model")
    (d / "tokenizer.json").write_text("{}", encoding="utf-8")
    return d, emb, labels, names


def test_index_roundtrip(tmp_path):
    d, emb, labels, names = _fake_pack(tmp_path)
    assert names[0] == "none"
    got, got_labels = pack.read_index(d / "index.bin", d / "labels.json")
    assert got_labels == labels
    assert np.allclose(got, emb, atol=1e-3)
    raw = (d / "index.bin").read_bytes()
    assert raw[:4] == b"TRIX" and len(raw) == 16 + 6 * 8 * 2 + 6 * 2
    body = json.loads((d / "labels.json").read_text(encoding="utf-8"))
    assert body["labels"][1] == {"id": "calc:calc.evaluate", "connector": "calc", "command": "calc.evaluate",
                                 "description": "посчитать"}


def test_pack_manifest_and_latest(tmp_path):
    d, *_ = _fake_pack(tmp_path)
    metrics = {"threshold": 0.9, "k": 5, "honest": {"all": {"catch": 40.0, "wrong": 2.0, "wrong_of_suggested": 4.8,
                                                             "false_alarm": 1.5}},
               "latency_ms": {"1_thread": {"median": 1.0}}}
    info = {"dims": 8, "max_length": 64, "pooling": "cls", "inputs": ["input_ids", "attention_mask"], "output": "embedding"}
    z = pack.make_pack(d, tmp_path / "tridot-intent-light-1.2.3.zip", tier=config.tier("light"), version="1.2.3",
                       info=info, corpus_hash="ab" * 32, metrics=metrics)
    with zipfile.ZipFile(z) as f:
        names = set(f.namelist())
        m = json.loads(f.read("manifest.json"))
        assert names == {"index.bin", "labels.json", "model.int8.onnx", "tokenizer.json", "manifest.json"}
        for name, meta in m["files"].items():
            assert hashlib.sha256(f.read(name)).hexdigest() == meta["sha256"]
    assert m["format"] == "tridot-intent/1" and m["tier"] == "light" and m["threshold"] == 0.9
    assert m["base_model"] == "cointegrated/rubert-tiny2" and m["base_license"] == "MIT"
    assert m["metrics"]["honest_false_alarm"] == 1.5
    # тот же вход — тот же архив
    z2 = pack.make_pack(d, tmp_path / "again.zip", tier=config.tier("light"), version="1.2.3", info=info,
                        corpus_hash="ab" * 32, metrics=metrics)
    assert pack.sha256(z) == pack.sha256(z2)

    latest = pack.latest("1.2.3", "https://example.org/dl/", [z])
    light = latest["tiers"]["light"]
    assert latest["version"] == "1.2.3"
    assert light["url"] == "https://example.org/dl/tridot-intent-light-1.2.3.zip"
    assert light["sha256"] == pack.sha256(z) and light["size"] == z.stat().st_size
    assert light["threshold"] == 0.9


def test_web_tier_has_light_model_and_own_connectors():
    web = config.tier("web")
    assert web.base_model == config.tier("light").base_model
    assert web.source == "light"
    assert set(web.connectors) == {"warehouse", "calc", "talk"}
