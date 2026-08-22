#!/usr/bin/env bash
#
# bundle_python.sh — 将受控的 Python 运行时 + MLX 推理栈打包进 App（实现方案 D6）。
#
# 产出：<Resources>/aienergy-python/  （含 bin/python3 + site-packages/mlx_lm 等）
# 这样最终 .app 自带 Python，用户「点按即装、零外部依赖」，无需系统自带 Python 或自装 mlx-lm。
#
# 仅 Apple Silicon 有意义（mlx 只能在 M 芯片跑）；其他架构此处会跳过并回退到系统 Python。
#
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Resources/aienergy-python"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ARCH="$(uname -m)"
if [[ "$ARCH" != "arm64" ]]; then
  echo "⚠️  非 Apple Silicon（当前 $ARCH），跳过内置 Python 打包；将回退系统 Python。"
  exit 0
fi

# python-build-standalone（已迁移至 astral-sh）：自带 OpenSSL/sqlite 等，免系统依赖
PVER="3.12.8"
REL="20241219"
URL="https://github.com/astral-sh/python-build-standalone/releases/download/${REL}/cpython-${PVER}+${REL}-aarch64-apple-darwin-install_only.tar.gz"

echo "⬇️  下载 Python ${PVER} (standalone)…"
if ! curl -fL --retry 3 -o "$TMP/py.tgz" "$URL"; then
  echo "⚠️  下载失败，跳过内置 Python 打包（App 将回退系统 Python）。"
  exit 0
fi

echo "📦  解压到 $DEST …"
rm -rf "$DEST"
mkdir -p "$TMP/ext"
tar -xzf "$TMP/py.tgz" -C "$TMP/ext"
# install_only 包解压出 ./python/
mv "$TMP/ext/python" "$DEST"

PY="$DEST/bin/python3"
"$PY" -m ensurepip --upgrade >/dev/null 2>&1 || true
"$PY" -m pip install --upgrade pip >/dev/null 2>&1 || true

echo "📥  安装 MLX 推理栈（mlx-lm / mlx / requests / jieba / pynput / huggingface_hub / modelscope）…"
if ! "$PY" -m pip install --no-cache-dir mlx-lm mlx requests jieba pynput huggingface_hub modelscope 2>&1 | tail -5; then
  echo "⚠️  pip 安装失败，跳过内置 Python 打包（App 将回退系统 Python）。"
  rm -rf "$DEST"
  exit 0
fi

echo "✅ 内置 Python 已就绪：$PY"
"$PY" -c "import mlx_lm, huggingface_hub, modelscope, jieba, requests; print('mlx_lm + deps OK')"
