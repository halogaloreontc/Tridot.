"""Квантование «только веса» для веб-уровня (config.Tier.quant)."""

import numpy as np
import onnx
import onnxruntime as ort
from onnx import TensorProto, helper, numpy_helper

from tools.intent_model import config, model


def _tiny(path):
    rng = np.random.default_rng(0)
    w = rng.standard_normal((64, 32)).astype(np.float32)
    g = helper.make_graph(
        [helper.make_node("MatMul", ["x", "w"], ["y"])],
        "t",
        [helper.make_tensor_value_info("x", TensorProto.FLOAT, [None, 64])],
        [helper.make_tensor_value_info("y", TensorProto.FLOAT, [None, 32])],
        [numpy_helper.from_array(w, "w")],
    )
    onnx.save(helper.make_model(g, opset_imports=[helper.make_opsetid("", 17)]), str(path))


def test_weight_only_keeps_fp32_compute(tmp_path):
    src, dst = tmp_path / "a.onnx", tmp_path / "b.onnx"
    _tiny(src)
    assert model.quantize_weight_only(src, dst) == 1
    ops = {n.op_type for n in onnx.load(str(dst)).graph.node}
    assert ops == {"DequantizeLinear", "MatMul"}
    x = np.random.default_rng(1).standard_normal((4, 64)).astype(np.float32)
    a = ort.InferenceSession(str(src)).run(None, {"x": x})[0]
    b = ort.InferenceSession(str(dst)).run(None, {"x": x})[0]
    cos = (a * b).sum(1) / np.linalg.norm(a, axis=1) / np.linalg.norm(b, axis=1)
    assert cos.min() > 0.999


def test_web_tier_uses_weight_only():
    assert config.tier("web").quant == "weight_only"
    assert config.tier("accurate").quant == "dynamic"
