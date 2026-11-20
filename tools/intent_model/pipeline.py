"""Шаги сборки: prepare → holdout (пробы на снимках) → model (обучение и
выгрузка) → calibrate → index → verify → pack. `build` — всё подряд.

Раскладка out/<уровень>/:
  data/train.jsonl, data/stats.json      обучающие фразы текущего корпуса
  calib/<проба>.npz                      векторы int8 снимка и пробы
  model/                                 model.int8.onnx, токенизатор, model_info.json,
                                         train_emb.npy (fp16), train.jsonl
  calibration.json, metrics.json
  pack/                                  содержимое архива
  tridot-intent-<уровень>-<версия>.zip
"""

from __future__ import annotations

import json
import shutil
import tempfile
from pathlib import Path

import numpy as np

from . import config, data, knn, pack
from .model import log


def _out(tier: config.Tier) -> Path:
    return config.tier_dir(tier.name)


def _src(tier: config.Tier) -> Path:
    """Папка уровня, чья модель и пробы используются (web → light)."""
    return config.tier_dir(tier.source)


def prepare(tier: config.Tier) -> list[dict]:
    rows, stats = data.prepare(data.corpus_files())
    data.check_descriptions([r["label"] for r in rows], data.load_descriptions())
    d = _src(tier) / "data"
    data.write_jsonl(d / "train.jsonl", rows)
    (d / "stats.json").write_text(json.dumps(stats, ensure_ascii=False, indent=1), encoding="utf-8")
    log(f"[{tier.source}] корпус: {stats['train_rows']} фраз, {stats['train_labels']} меток")
    return rows


def holdout(tier: config.Tier, name: str) -> Path:
    """Модель на снимке корпуса до разбора пробы `name` → векторы int8 снимка и пробы."""
    from .model import Int8Encoder, export, train

    if tier.model_from:
        raise SystemExit(f"Уровень {tier.name} берёт пробы уровня {tier.model_from}")
    snap = data.snapshots()[name]["commit"]
    evals = data.load_eval(name)
    rows, stats = data.prepare(data.corpus_files(snap), [e["text"] for e in evals])
    log(f"[{tier.name}/{name}] снимок {snap[:7]}: {stats['train_rows']} фраз, утечка убрана: {stats.get('removed_leak', 0)}")
    model, info = train(tier, rows)
    config.OUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=config.OUT) as tmp:
        export(model, Path(tmp), tier.per_channel)
        del model
        enc = Int8Encoder(Path(tmp), prefix=tier.prefix)
        tr = enc.encode([r["text"] for r in rows])
        ev = enc.encode([e["text"] for e in evals])
    path = _out(tier) / "calib" / f"{name}.npz"
    path.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(
        path, train=tr.astype(np.float16), labels=np.array([r["label"] for r in rows]),
        eval=ev.astype(np.float16), eval_ids=np.array([e["id"] for e in evals]),
        snapshot=np.array(snap), info=np.array(json.dumps({**info, **stats})),
    )
    log(f"[{tier.name}/{name}] готово: {path}")
    return path


def build_model(tier: config.Tier) -> Path:
    """Модель уровня на всём текущем корпусе (без отсева проб: это выпуск)."""
    from .model import Int8Encoder, export, train

    rows = prepare(tier)
    model, info = train(tier, rows)
    d = _out(tier) / "model"
    if d.exists():
        shutil.rmtree(d)
    minfo = export(model, d, tier.per_channel)
    del model
    enc = Int8Encoder(d, prefix=tier.prefix)
    np.save(d / "train_emb.npy", enc.encode([r["text"] for r in rows]).astype(np.float16))
    data.write_jsonl(d / "train.jsonl", rows)
    minfo["train"] = info
    (d / "model_info.json").write_text(json.dumps(minfo, ensure_ascii=False, indent=1), encoding="utf-8")
    log(f"[{tier.name}] модель: {d}")
    return d


def _honest_preds(tier: config.Tier) -> dict[str, tuple[list[dict], list[dict]]]:
    out = {}
    for name in config.EVAL_SETS:
        path = _src(tier) / "calib" / f"{name}.npz"
        if not path.exists():
            raise SystemExit(f"Нет {path}: сначала holdout --tier {tier.source} --set {name}")
        z = np.load(path)
        evals = data.load_eval(name, tier.connectors)
        ids = [str(x) for x in z["eval_ids"]]
        if ids != [e["id"] for e in evals]:
            raise SystemExit(f"{path}: фразы пробы {name} изменились — пересоберите holdout")
        labels = [data.restrict(str(x), tier.connectors) for x in z["labels"]]
        out[name] = (evals, knn.knn(z["train"], labels, z["eval"]))
    return out


def _report(per_set: dict[str, tuple[list[dict], list[dict]]], t: float) -> dict:
    res = {name: knn.at_threshold(ev, pr, t) for name, (ev, pr) in per_set.items()}
    test = [n for n in config.EVAL_SETS if n != config.DEV_SET]
    for group, names in (("test", test), ("all", list(config.EVAL_SETS))):
        ev = [e for n in names for e in per_set[n][0]]
        pr = [p for n in names for p in per_set[n][1]]
        res[group] = knn.at_threshold(ev, pr, t)
    return res


def calibrate(tier: config.Tier) -> dict:
    """Порог на int8, честно: каждая проба — на модели снимка до её разбора.

    Выбор — на fresh (наибольший catch в бюджете), проверка — held2+held3.
    """
    per_set = _honest_preds(tier)
    ev, pr = per_set[config.DEV_SET]
    t = knn.pick_threshold(ev, pr)
    if t is None:
        raise SystemExit(f"[{tier.name}] на {config.DEV_SET} нет порога в бюджете ошибок")
    grid = {str(g): _report(per_set, g)["all"] for g in config.GRID if round(g * 1000) % 25 == 0}
    res = {"threshold": t, "k": config.K, "picked_on": config.DEV_SET, "honest": _report(per_set, t), "grid_all": grid}
    (_out(tier) / "calibration.json").parent.mkdir(parents=True, exist_ok=True)
    (_out(tier) / "calibration.json").write_text(json.dumps(res, ensure_ascii=False, indent=1), encoding="utf-8")
    h = res["honest"]
    log(
        f"[{tier.name}] порог {t}: честно (все пробы) catch {h['all']['catch']} %, wrong {h['all']['wrong']} %, "
        f"неверных из подсказок {h['all']['wrong_of_suggested']} %, ложные тревоги {h['all']['false_alarm']} %"
    )
    return res


def index(tier: config.Tier) -> Path:
    """index.bin (векторы fp16 и номера меток) и labels.json уровня."""
    md = _src(tier) / "model"
    rows = data.read_jsonl(md / "train.jsonl")
    emb = np.load(md / "train_emb.npy")
    labels = [data.restrict(r["label"], tier.connectors) for r in rows]
    pd = _out(tier) / "pack"
    if pd.exists():
        shutil.rmtree(pd)
    pd.mkdir(parents=True)
    desc = data.load_descriptions()
    data.check_descriptions(labels, desc)
    names = pack.write_index(pd / "index.bin", emb, labels)
    pack.write_labels(pd / "labels.json", names, desc)
    for f in ["model.int8.onnx", *[p.name for p in md.iterdir() if p.name in pack.TOKENIZER_FILES]]:
        shutil.copy(md / f, pd / f)
    log(f"[{tier.name}] индекс: {len(labels)} примеров, {len(names)} меток")
    return pd


def verify(tier: config.Tier) -> dict:
    """Метрики пакета: честные (из калибровки) и прогон собранного пакета на
    пробах (модель видела их разбор — только для сравнения), задержка, размеры."""
    from .model import Int8Encoder

    cal = json.loads((_out(tier) / "calibration.json").read_text(encoding="utf-8"))
    t = cal["threshold"]
    pd = _out(tier) / "pack"
    emb, labels = pack.read_index(pd / "index.bin", pd / "labels.json")
    md = _src(tier) / "model"
    enc = Int8Encoder(pd, prefix=tier.prefix, info_dir=md)
    per_set = {}
    texts = []
    for name in config.EVAL_SETS:
        ev = data.load_eval(name, tier.connectors)
        per_set[name] = (ev, knn.knn(emb, labels, enc.encode([e["text"] for e in ev])))
        texts += [e["text"] for e in ev]
    lat = {"1_thread": Int8Encoder(pd, threads=1, prefix=tier.prefix, info_dir=md).latency_ms(texts[:300])}
    honest = cal["honest"]["all"]
    m = {
        "threshold": t,
        "k": config.K,
        "budget": {"max_wrong_of_suggested": config.MAX_WRONG_OF_SUGGESTED, "max_false_alarm": config.MAX_FALSE_ALARM},
        "honest": cal["honest"],
        "seen": _report(per_set, t),
        "latency_ms": lat,
        "sizes_mb": {p.name: round(p.stat().st_size / 1e6, 2) for p in sorted(pd.iterdir())},
        "ok": knn.within_budget(honest),
    }
    (_out(tier) / "metrics.json").write_text(json.dumps(m, ensure_ascii=False, indent=1), encoding="utf-8")
    log(
        f"[{tier.name}] проверка: честно catch {honest['catch']} %, неверных из подсказок {honest['wrong_of_suggested']} %, "
        f"ложные тревоги {honest['false_alarm']} %; на текущем корпусе catch {m['seen']['all']['catch']} %; "
        f"задержка {lat['1_thread']['median']} мс — {'в бюджете' if m['ok'] else 'ВНЕ БЮДЖЕТА'}"
    )
    return m


def do_pack(tier: config.Tier, version: str) -> Path:
    m = json.loads((_out(tier) / "metrics.json").read_text(encoding="utf-8"))
    md = _src(tier) / "model"
    info = json.loads((md / "model_info.json").read_text(encoding="utf-8"))
    rows = data.read_jsonl(md / "train.jsonl")
    z = pack.make_pack(
        _out(tier) / "pack",
        _out(tier) / f"tridot-intent-{tier.name}-{version}.zip",
        tier=tier,
        version=version,
        info=info,
        corpus_hash=data.corpus_hash(rows),
        metrics=m,
    )
    log(f"[{tier.name}] пакет: {z} ({z.stat().st_size / 1e6:.1f} МБ)")
    return z


def finish(tier: config.Tier, version: str, strict: bool = True) -> Path:
    calibrate(tier)
    index(tier)
    m = verify(tier)
    if strict and not m["ok"]:
        raise SystemExit(f"[{tier.name}] честные метрики вне бюджета — пакет не собран (metrics.json)")
    return do_pack(tier, version)


def build(tier: config.Tier, version: str, reuse: bool = False, strict: bool = True) -> Path:
    src = config.tier(tier.source)
    for name in config.EVAL_SETS:
        if not (reuse and (_src(tier) / "calib" / f"{name}.npz").exists()):
            holdout(src, name)
    if not (reuse and (_src(tier) / "model" / "model.int8.onnx").exists()):
        build_model(src)
    return finish(tier, version, strict)


def webcheck(tier: config.Tier) -> dict:
    """Модель пакета в onnxruntime-web (WASM) через node: те же векторы, что на CPU.

    Нужны node и `npm ci` в tools/intent_model/webcheck. Пишет webcheck.json:
    операции графа, версия onnxruntime-web, расхождение векторов.
    """
    import subprocess

    import onnx

    from .model import Int8Encoder

    pd = _out(tier) / "pack"
    md = _src(tier) / "model"
    wc = config.PKG / "webcheck"
    if not (wc / "node_modules" / "onnxruntime-web").exists():
        raise SystemExit(f"Нет onnxruntime-web: cd {wc} && npm ci")
    g = onnx.load(str(pd / "model.int8.onnx"))
    ops = sorted({n.op_type for n in g.graph.node})
    enc = Int8Encoder(pd, threads=1, prefix=tier.prefix, info_dir=md)
    texts = [e["text"] for e in data.load_eval(config.DEV_SET)][:16]
    feeds = enc.feeds(texts)
    want = enc.sess.run(None, feeds)[0]
    with tempfile.TemporaryDirectory() as tmp:
        fin, fout = Path(tmp) / "feeds.json", Path(tmp) / "out.json"
        fin.write_text(json.dumps({"inputs": {k: v.tolist() for k, v in feeds.items()}, "dims": list(want.shape[:1]) + [feeds["input_ids"].shape[1]]}))
        run = subprocess.run(["node", str(wc / "check.mjs"), str(pd / "model.int8.onnx"), str(fin), str(fout)],
                             capture_output=True, text=True)
        if run.returncode != 0:
            raise SystemExit(f"onnxruntime-web не открыл модель:\n{run.stderr[-3000:]}")
        got = json.loads(fout.read_text())
    arr = np.array(got["data"], dtype=np.float32).reshape(got["dims"])
    cos = (arr * want).sum(1) / (np.linalg.norm(arr, axis=1) * np.linalg.norm(want, axis=1))
    version = json.loads((wc / "package.json").read_text())["dependencies"]["onnxruntime-web"]
    res = {
        "onnxruntime_web": version,
        "backend": "wasm",
        "opset": [{"domain": o.domain or "ai.onnx", "version": o.version} for o in g.opset_import],
        "ops": ops,
        "phrases": len(texts),
        "min_cosine_vs_cpu": round(float(cos.min()), 6),
        "max_abs_diff": round(float(np.abs(arr - want).max()), 6),
        "ok": bool(cos.min() > 0.999),
    }
    (_out(tier) / "webcheck.json").write_text(json.dumps(res, ensure_ascii=False, indent=1), encoding="utf-8")
    log(f"[{tier.name}] onnxruntime-web {version}: {'совпадает' if res['ok'] else 'РАСХОДИТСЯ'} "
        f"(косинус ≥ {res['min_cosine_vs_cpu']}), операции: {', '.join(ops)}")
    if not res["ok"]:
        raise SystemExit("onnxruntime-web считает не то же, что CPU")
    return res
