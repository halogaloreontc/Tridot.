#!/usr/bin/env bash
# Исходники llama.cpp для native/tridot_llama (ADR-046): из пакета
# llama-cpp-python на PyPI — та же версия, на которой меряли модели
# (tools/gen_model). Архив сверяется по sha256.
set -euo pipefail
VERSION=0.3.38
SHA256=0570c9736b5e2a239b651da18687238eeba7fc2369dcdfd8cbb009dc1321e23f
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/third_party/llama.cpp"
[ -f "$DEST/CMakeLists.txt" ] && { echo "$DEST"; exit 0; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
URL="https://files.pythonhosted.org/packages/source/l/llama_cpp_python/llama_cpp_python-$VERSION.tar.gz"
curl -fsSL --retry 4 -o "$TMP/src.tar.gz" "$URL"
echo "$SHA256  $TMP/src.tar.gz" | sha256sum -c - >/dev/null
tar -xzf "$TMP/src.tar.gz" -C "$TMP"
mkdir -p "$ROOT/third_party"
mv "$TMP/llama_cpp_python-$VERSION/vendor/llama.cpp" "$DEST"
rm -f "$DEST/.git"
echo "$DEST"
