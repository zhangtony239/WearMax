"""WearMax hr.get — 给 AI 取数的工具（CLI）。

职责：
    读 hr.daemon 落盘的 CSV，加工成简洁 JSON 直接返回给 AI。
    被 zeroclaw 通过 shell 调用：`hr-get [选项]` → stdout 输出 JSON。

设计：
    - 不做花里胡哨的展示，纯数据，便于 AI 解析。
    - 复用 hr.data_process 的处理函数，保证与 server 口径一致。
    - 默认返回最近一分钟的摘要；可指定时间窗 / 原始点数。
    - 输出 UTF-8 JSON 到 stdout，日志走 stderr（不污染 stdout）。

用法（zeroclaw 会用）：
    hr-get                      # 最近 60s 摘要（心率/HRV/RR 等）
    hr-get --window 300         # 最近 300s 摘要
    hr-get --raw 100            # 最近 100 个原始 PPG 点
    hr-get --since "2026-07-11T09:33:00" --until "2026-07-11T09:34:00"
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from datetime import datetime

from hr import data_process as dp

# 日志只进 stderr，保持 stdout 纯 JSON（给 AI 读）
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    stream=sys.stderr,
)
log = logging.getLogger("hr.get")


def _parse_dt(s: str | None) -> datetime | None:
    if not s:
        return None
    try:
        return datetime.fromisoformat(s)
    except ValueError:
        log.error("时间格式错误: %s（需 ISO8601，如 2026-07-11T09:33:00）", s)
        sys.exit(2)


def build_payload(args: argparse.Namespace) -> dict:
    """构造返回给 AI 的 JSON payload。"""
    path = args.data or dp.CSV_PATH

    if not os.path.exists(path):
        return {"error": f"no data file: {path}", "hint": "请确认 hr.daemon 已运行"}

    since = _parse_dt(args.since)
    until = _parse_dt(args.until)

    payload: dict = {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "data_file": path,
    }

    if args.raw:
        # 原始点数模式
        rows, ts = dp.load_ppg_series(path, since=since, until=until)
        n = args.raw
        rows = rows[-n:]
        ts = ts[-n:]
        payload["mode"] = "raw"
        payload["n"] = len(rows)
        payload["fs"] = dp.DEFAULT_FS
        payload["ppg_ir"] = rows
        payload["timestamps"] = [t.isoformat(timespec="milliseconds") for t in ts]
        return payload

    # 摘要模式
    if since or until:
        rows, _ = dp.load_ppg_series(path, since=since, until=until)
        metrics = dp.compute_metrics(rows, path=path)
        metrics["window_start"] = since.isoformat() if since else None
        metrics["window_end"] = until.isoformat() if until else None
        payload["mode"] = "summary_window"
        payload.update(metrics)
    else:
        lookback = args.window
        payload["mode"] = "summary_recent"
        payload["window_s"] = lookback
        payload.update(dp.latest_summary(path=path, lookback_s=lookback))

    return payload


def main() -> None:
    ap = argparse.ArgumentParser(
        description="WearMax hr.get — 读 CSV 返回 JSON 给 AI",
    )
    ap.add_argument("--data", default=None, help="CSV 路径，默认 data/hr.csv")
    ap.add_argument("--window", type=int, default=60,
                    help="摘要窗口秒数（默认最近 60s）")
    ap.add_argument("--raw", type=int, default=None,
                    help="返回最近 N 个原始 PPG 点")
    ap.add_argument("--since", default=None, help="起始时间 ISO8601")
    ap.add_argument("--until", default=None, help="结束时间 ISO8601")
    args = ap.parse_args()

    payload = build_payload(args)
    sys.stdout.write(json.dumps(payload, ensure_ascii=False))
    sys.stdout.write("\n")
    sys.stdout.flush()


if __name__ == "__main__":
    main()
