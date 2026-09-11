#!/usr/bin/env python3
"""TPS 统计服务：读 turn_usage/model_usage 按轮折叠，供 ZCode 渲染层注入脚本取数。

口径（对齐 DeepSeek harness；聚合键 = (session_id, turn_id)，数据库主键同此）：
  - 只返回已结束回合（turn_usage.completed_at 非空）
  - 整轮墙钟 run_ms = turn_usage.completed_at − started_at（含工具执行时段）
  - 首 token = turn_usage.time_to_first_token_ms，是整轮首 token 延迟
    （first_token_at − started_at，从提问到第一个 token，非首次模型调用的 TTFT）
  - tok/s = Σ样本token ÷ Σ样本解码时间；样本 = completed 且 main_turn、
    0 ≤ ttft < duration 的调用，解码时间 = duration − ttft（扣除该次首 token 等待）
  - series/peak_tps = 每步（单次调用）平均速度 / 单步最高均速（非瞬时采样）

端点：
  GET /healthz            → "ok"
  GET /turns?limit=500    → {"turns":[{turn_id,session_id,status,start_ms,end_ms,run_ms,ttft_ms,tps,
                             peak_tps,series,decode_ms,measured_tokens,out_tokens,models}]}
                             （仅已结束回合，按 end_ms 降序；measured_tokens 与 decode_ms 为同一
                             测速样本的 token 数/解码时长，series/peak_tps 为每步均速/单步最高均速）

常驻：launchd LaunchAgent（com.zcode-tps-footer.server），127.0.0.1:3117，仅本机。
"""
from __future__ import annotations

import json
import os
import sqlite3
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

DB = os.path.expanduser("~/.zcode/cli/db/db.sqlite")

PORT = 3117
CACHE_TTL_MS = 1500

_cache: dict = {"at": 0.0, "turns": []}


def fold_turns() -> list[dict]:
    """主查询走 turn_usage（CLI 权威按轮聚合，含 user_message_id 桥），只返回已结束回合
    （completed_at 非空）——进行中的回合数据不全，画出来也不会再刷新，索性不出。
    速度口径（与 DeepSeek harness 对齐）：
      - 测速样本 = completed 且 main_turn、TTFT 与 duration 齐备、duration−TTFT>0 的单次调用；
        分子分母只从样本累计，token 绝不会计入时间缺失的调用（避免均值虚高超过峰值）
      - tok/s = Σ样本token ÷ Σ样本解码时间；measured_tokens/decode_ms 即这对样本值
      - series/peak_tps = 每步（单次调用）平均速度，峰值为单步最高均速，非瞬时采样"""
    cut = int(time.time() * 1000) - 24 * 60 * 60 * 1000
    conn = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    try:
        turns = conn.execute(
            """
            SELECT session_id, turn_id, user_message_id, status,
                   started_at, completed_at, time_to_first_token_ms, output_tokens
            FROM turn_usage
            WHERE started_at >= ? AND user_message_id IS NOT NULL AND user_message_id != ''
              AND completed_at IS NOT NULL
            ORDER BY started_at ASC
            """,
            (cut,),
        ).fetchall()
        # 逐行扫 model_usage：折叠解码时间 + 收集每步 tok/s 序列与用过的模型
        # 聚合键必须是 (session_id, turn_id) 复合键——跨会话 turn_id 撞车时按 tid 聚会混算
        dec = {}
        series = {}
        raw_peak = {}  # 未取整的单步最高均速（series 为紧凑展示只留 1 位小数，取峰值不能用它）
        models_by_turn = {}
        for sid, tid, model_id, dur, ttft, tok in conn.execute(
            """
            SELECT session_id, turn_id, model_id, duration_ms, time_to_first_token_ms, output_tokens
            FROM model_usage
            WHERE status = 'completed' AND query_source = 'main_turn'
              AND started_at >= ?
            ORDER BY started_at ASC
            """,
            (cut,),
        ):
            key = (sid, tid)
            d, t = dec.get(key, (0, 0))
            # 分子分母同步累计；样本合法性显式校验：时间齐备且 0 <= ttft < dur
            # （dur 缺失时不允许靠 or 0 拼出正的解码时间，负 TTFT 一律排除）
            if dur is not None and ttft is not None and 0 <= ttft < dur and tok and tok > 0:
                step_ms = dur - ttft
                d += step_ms
                t += tok
                rate = tok * 1000.0 / step_ms
                series.setdefault(key, []).append(round(rate, 1))
                raw_peak[key] = max(raw_peak.get(key, 0.0), rate)
            dec[key] = (d, t)
            if model_id:
                models_by_turn.setdefault(key, [])
                if model_id not in models_by_turn[key]:
                    models_by_turn[key].append(model_id)
    finally:
        conn.close()

    out = []
    for sid, tid, msg_id, status, started, completed, ttft, out_tok in turns:
        key = (sid, tid)
        decode_ms, decode_tok = dec.get(key, (0, 0))
        tps = (decode_tok * 1000.0 / decode_ms) if decode_ms > 0 else None
        steps = series.get(key, [])
        out.append(
            {
                "turn_id": tid,
                "msg_id": msg_id,  # 桥：界面 section[data-turn-id] 实为用户消息 ID
                "session_id": sid,
                "status": status,
                "start_ms": started,
                "end_ms": completed,
                "run_ms": max(0, completed - started),
                "ttft_ms": ttft,
                "tps": round(tps, 2) if tps else None,
                "peak_tps": round(raw_peak[key], 2) if key in raw_peak else None,
                "series": steps,
                "decode_ms": decode_ms,
                "measured_tokens": decode_tok,  # 参与测速的 token 数（与 decode_ms 同样本）
                "out_tokens": out_tok or 0,     # 整轮总输出（可能与测速样本不同）
                "models": models_by_turn.get(key, []),
            }
        )
    out.sort(key=lambda t: t["end_ms"], reverse=True)
    return out


def get_turns() -> list[dict]:
    now = time.time()
    if now - _cache["at"] > CACHE_TTL_MS / 1000.0:
        try:
            _cache["turns"] = fold_turns()
        except sqlite3.Error:
            pass  # 库忙时沿用上次结果
        _cache["at"] = now
    return _cache["turns"]


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, body: bytes, ctype: str = "application/json") -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        try:
            u = urlparse(self.path)
            if u.path == "/healthz":
                return self._send(200, b"ok", "text/plain")
            if u.path == "/ping":
                qs = parse_qs(u.query)
                print(f"[PING] secs={qs.get('secs', ['?'])[0]} snap={qs.get('snap', [''])[0][:1500]}", flush=True)
                return self._send(200, b"pong", "text/plain")
            if u.path == "/turns":
                qs = parse_qs(u.query)
                limit = min(int(qs.get("limit", ["500"])[0]), 2000)
                data = json.dumps({"turns": get_turns()[:limit]}).encode()
                return self._send(200, data)
            return self._send(404, b'{"error":"not found"}')
        except Exception:
            try:
                return self._send(500, b'{"error":"internal"}')
            except Exception:
                pass

    def log_message(self, fmt: str, *args) -> None:
        import sys
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))
        sys.stderr.flush()


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
