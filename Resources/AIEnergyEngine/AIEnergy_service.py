#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AIEnergy_service.py — 鼠须管控制面板「AI 联想层」续写服务（Phase 2 MVP）

本地 HTTP 服务（默认 127.0.0.1:8080）：
  POST /associate  {"context": "..."}  ->  {"suggestions": ["...","...","..."]}
  GET  /health                       ->  {"ok": true}

推理策略：
  - 若提供了可用模型（--model 指向含 config.json + 权重的目录）且运行环境装了
    mlx_lm / transformers，则用本地模型做续写（低温度、短生成）。
  - 否则走「规则兜底」：基于上下文给出 2-3 条常见中文续写片段。保证在没有模型权重时
    整条链路（打字 → 停顿/边界 → 浮动条浮现 → 点击插入）也能端到端跑通，用于验证。

零配置：不修改用户 Python 环境；除可选模型外无强制第三方依赖（服务本体仅用标准库）。
"""
import sys
import os
import json
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 8080
MODEL_PATH = ""
MAX_SUGGESTIONS = 3

# ---- 规则兜底：常见中文续写片段（不依赖模型，保证链路可跑） ----
TAILS = [
    "，我们可以", "。这是一个", "，我觉得", "，这个项目", "，所以我们需要",
    "，现在我", "，其实", "，总的来说", "，接下来", "，比如",
]


def rule_based(context: str):
    ctx = (context or "").strip()
    if not ctx:
        return ["你好，", "我们", "今天"]
    last = ctx[-1]
    out = []
    # 以句末标点结尾：给一个起句，而非继续拼接
    if last in "。！？!?；;":
        out = ["然后我们", "接下来", "后来"]
    else:
        for t in TAILS[:MAX_SUGGESTIONS]:
            out.append(ctx + t)
    # 去重保序
    seen = set()
    res = []
    for s in out:
        if s not in seen:
            seen.add(s)
            res.append(s)
    return res[:MAX_SUGGESTIONS] or [ctx + "，"]


# ---- 模型推理（可选） ----
_model = None
_model_loaded = False


def ensure_model():
    """懒加载本地模型；加载失败则回退规则兜底。"""
    global _model, _model_loaded
    if _model_loaded:
        return _model
    _model_loaded = True
    if not MODEL_PATH:
        return None
    try:
        from mlx_lm import load, generate  # type: ignore
        _model = (load(MODEL_PATH), generate)
        sys.stderr.write("[AIEnergy] 已加载本地模型: %s\n" % MODEL_PATH)
        sys.stderr.flush()
    except Exception as e:  # noqa: BLE001
        sys.stderr.write("[AIEnergy] mlx_lm 不可用，回退规则兜底: %s\n" % e)
        sys.stderr.flush()
        _model = None
    return _model


PROMPT = (
    "你是中文输入法的「联想续写」助手。给定用户刚输入的短语上下文，"
    "输出 %d 个最可能的下一短语/续写片段（每个不超过 8 字、自然常用、不重复）。"
    "只输出 JSON 数组，如 [\"…\",\"…\",\"…\"]，不要解释。上下文："
) % MAX_SUGGESTIONS


def model_based(context: str):
    m = ensure_model()
    if not m:
        return None
    model, generate = m
    try:
        prompt = PROMPT + (context or "")
        text = generate(model, prompt, temp=0.2, max_tokens=64)
        start = text.find("[")
        end = text.rfind("]")
        if start >= 0 and end > start:
            arr = json.loads(text[start:end + 1])
            if isinstance(arr, list):
                return [str(x) for x in arr][:MAX_SUGGESTIONS]
    except Exception as e:  # noqa: BLE001
        sys.stderr.write("[AIEnergy] 模型推理失败: %s\n" % e)
        sys.stderr.flush()
    return None


def suggest(context: str):
    res = model_based(context)
    if res:
        return res
    return rule_based(context)


class Handler(BaseHTTPRequestHandler):
    def _send(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/health"):
            self._send({"ok": True})
        else:
            self._send({"error": "not found"}, 404)

    def do_POST(self):
        if not self.path.startswith("/associate"):
            self._send({"error": "not found"}, 404)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length) if length > 0 else b"{}"
            data = json.loads(raw.decode("utf-8"))
        except Exception:  # noqa: BLE001
            self._send({"suggestions": []})
            return
        ctx = data.get("context", "")
        try:
            sugs = suggest(ctx)
        except Exception as e:  # noqa: BLE001
            sugs = []
            sys.stderr.write("[AIEnergy] suggest error: %s\n" % e)
            sys.stderr.flush()
        self._send({"suggestions": sugs or []})

    def log_message(self, *args):  # 静默访问日志
        pass


def main():
    global PORT, MODEL_PATH, MAX_SUGGESTIONS
    ap = argparse.ArgumentParser(description="AI 联想层续写服务")
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--model", type=str, default="",
                    help="本地模型目录（含 config.json + 权重）。留空则走规则兜底。")
    ap.add_argument("--max-suggestions", type=int, default=MAX_SUGGESTIONS)
    args = ap.parse_args()
    PORT = args.port
    MODEL_PATH = args.model
    if args.max_suggestions:
        MAX_SUGGESTIONS = args.max_suggestions
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    sys.stderr.write("[AIEnergy] 续写服务已启动于 127.0.0.1:%d\n" % PORT)
    sys.stderr.flush()
    server.serve_forever()


if __name__ == "__main__":
    main()
