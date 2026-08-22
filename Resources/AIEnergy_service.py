#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AIEnergy_service.py - AI 增强服务（自研，替代 bzx_service.py）

与 vendored 的 bzx 服务协议同源（/tmp 文件 IPC），但两点关键差异：
  1. 不经手 keystroke 模拟（bzx_ipc.py 会 osascript 按 "0" 键）；
     候选注入改由 Rime 原生 filter（AIEnergy_filter.lua）完成，更干净。
  2. 飞行中取消：单槽顺序处理，写入响应前校验请求是否已被新按键覆盖，
     被覆盖（过期）的响应直接丢弃。

AI 调用核心沿用 vendored 的 bzx_ai.AIClient（OpenAI 兼容客户端），
通过 --follow-core 指向 vendor/ai-rime/bzx，保持「跟随更新他的核心」。

用法：
  python AIEnergy_service.py --config AIEnergy_config.json
"""

import argparse
import json
import os
import sys
import time

# ============================================================
# 定位并导入 vendored 核心（bzx_ai.AIClient）
# ============================================================
HERE = os.path.dirname(os.path.abspath(__file__))

def _import_core():
    # 1) 同目录已部署的 bzx_ai.py（deploy 时复制过来）
    candidates = [
        os.path.join(HERE, "bzx_ai.py"),
        os.path.join(HERE, "vendor", "ai-rime", "bzx", "bzx_ai.py"),
        os.path.join(HERE, "..", "vendor", "ai-rime", "bzx", "bzx_ai.py"),
    ]
    for path in candidates:
        path = os.path.abspath(path)
        if os.path.exists(path):
            sys.path.insert(0, os.path.dirname(path))
            from bzx_ai import AIClient
            return AIClient
    raise ImportError("找不到 vendored 核心 bzx_ai.py，请先 deploy 或检查 vendor 路径")


AIClient = _import_core()

# ============================================================
# IPC 文件
# ============================================================
TEMP_DIR = "/tmp"
REQ_FILE = os.path.join(TEMP_DIR, "aienergy_rime_req.txt")
RESP_FILE = os.path.join(TEMP_DIR, "aienergy_rime_resp.txt")

# ============================================================
# 各功能系统提示词
# ============================================================
PROMPTS = {
    "correct": (
        "你是中文输入法智能纠错助手。用户会给你一段拼音或可能含错别字的文本，"
        "请输出最合理的正确中文文本。直接输出结果，不要解释，不要添加额外字符。"
    ),
    "translate": (
        "你是翻译助手。将用户给出的文本翻译为另一种语言："
        "若为中文则译为英文，若为英文则译为中文。只输出译文，不要解释。"
    ),
    "chat": (
        "你是嵌入在输入法中的简洁 AI 助手，用中文简要回答用户问题。"
    ),
}


def load_config(path):
    with open(path, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    engine = cfg.get("engine", {})
    return {
        "api_url": engine.get("api_url", "http://localhost:8080/v1/chat/completions"),
        "api_key": engine.get("api_key", ""),
        "model": engine.get("model", "Qwen2.5-1.5B-Instruct-4bit"),
        "temperature": engine.get("temperature", 0.1),
        "max_tokens": engine.get("max_tokens", 512),
        "top_p": engine.get("top_p", 1.0),
    }


def read_req():
    try:
        with open(REQ_FILE, "r", encoding="utf-8") as f:
            return f.read().strip()
    except Exception:
        return None


def write_resp(reqid, result, error=None):
    payload = {"reqid": reqid, "result": result or "", "error": error}
    with open(RESP_FILE, "w", encoding="utf-8") as f:
        f.write(json.dumps(payload, ensure_ascii=False))
        f.flush()


def main():
    parser = argparse.ArgumentParser(description="AIEnergy service")
    parser.add_argument("--config", required=True, help="AIEnergy_config.json 路径")
    args = parser.parse_args()

    cfg = load_config(args.config)
    client = AIClient(
        api_url=cfg["api_url"],
        api_key=cfg["api_key"],
        model=cfg["model"],
        temperature=cfg.get("temperature", 0.1),
        max_tokens=cfg.get("max_tokens", 512),
        top_p=cfg.get("top_p", 1.0),
    )

    # 创建空响应文件，供 lua 的 exists() 判定服务已启动
    open(RESP_FILE, "w", encoding="utf-8").close()

    print(f"[AIEnergy] 服务启动，引擎: {cfg['api_url']} / {cfg['model']}", flush=True)

    current = None        # 正在处理（或待处理）的请求
    current_mtime = 0
    arrived_at = 0.0      # 请求到达时间（防抖计时起点）
    last_mtime = -1

    # 停顿触发（防抖）：用户停止输入 DEBOUNCE_MS 毫秒后才触发一次推理，
    # 避免「每键触发」在快速打字时请求堆叠、导致慢半拍。
    DEBOUNCE_MS = 450

    while True:
        try:
            # 读取请求文件最新修改时间
            if os.path.exists(REQ_FILE):
                mtime = os.path.getmtime(REQ_FILE)
            else:
                mtime = -1

            # 请求文件有更新（mtime 变化）-> 读取最新请求，并重置防抖计时
            if mtime != last_mtime:
                last_mtime = mtime
                raw = read_req()
                if raw:
                    try:
                        current = json.loads(raw)
                        current_mtime = mtime
                        arrived_at = time.time()
                    except Exception:
                        current = None
                else:
                    current = None

            # 有待处理请求，且已连续停顿 DEBOUNCE_MS（期间无新请求）-> 推理
            if current is not None and (time.time() - arrived_at) >= DEBOUNCE_MS / 1000.0:
                reqid = current.get("reqid")
                func_type = current.get("type", "correct")
                text = current.get("text", "")
                prompt = PROMPTS.get(func_type, PROMPTS["correct"])

                result = None
                error = None
                try:
                    result = client.chat(prompt, text)
                except Exception as e:
                    error = str(e)

                # 飞行中取消：推理期间若请求文件又被更新（新按键），则丢弃本次结果
                now_mtime = os.path.getmtime(REQ_FILE) if os.path.exists(REQ_FILE) else -1
                if now_mtime == current_mtime:
                    write_resp(reqid, result, error)

                current = None

        except Exception as e:
            print(f"[AIEnergy] 循环异常: {e}", flush=True)
            current = None

        time.sleep(0.02)


if __name__ == "__main__":
    main()
