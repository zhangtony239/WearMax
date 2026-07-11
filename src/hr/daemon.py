"""WearMax hr.daemon — 传感器采集常驻进程。

职责：
    监听 termux-sensor 推送的 PPG / IMU 传感器数据流，解析后落盘为 CSV，
    供 hr.server（展示）与 hr.get（AI 取数）复用。

关键技术点（来自 sensor_test_*.txt 实测）：
    1. termux-sensor 的输出是「跨多行的 pretty-print JSON」，不是一个完整 JSON/行。
       形如：
           {
             "pah8011_ppg PPG Sensor Non-wakeup": {
               "values": [ 177156.5, 143458.4, ... ]
             }
           }
       → 必须用「流式帧拼装器」：累积行到大括号平衡后再整体 json.loads。
    2. 部分传感器名在 termux-sensor -l 列表里，名称与 Wakeup/Non-wakeup 之间是
       双空格（如 "lifeq_lel_heart_rate  Non-wakeup"）。硬编码单空格名称会报
       "No valid sensors were registered!"。
       → 先跑 -l 拿真实名称，按「关键字 + Non-wakeup」子串匹配，规避空格陷阱。
    3. 不同传感器采样率差异大（PPG 20Hz vs 环境光 1Hz），各开一条子进程流，
       独立解析、独立写入，互不阻塞。

CLI:
    hr-daemon                # 前台运行，按默认配置采集
    hr-daemon --once         # 只跑一轮采集用于验证（不等同测试脚本）
    python -m hr.daemon      # 等价入口
"""
from __future__ import annotations

import argparse
import csv
import json
import logging
import os
import queue
import signal
import subprocess
import sys
import threading
import time
from collections import deque
from dataclasses import dataclass, field
from datetime import datetime
from typing import Callable

log = logging.getLogger("hr.daemon")

# --------------------------------------------------------------------------- #
# 配置
# --------------------------------------------------------------------------- #

# 运行数据目录（相对运行目录；手表上即 ~/.zeroclaw 或项目根）
DATA_DIR = os.environ.get("WEARMAX_DATA_DIR", "data")
CSV_PATH = os.path.join(DATA_DIR, "hr.csv")

# 各采集流配置：(匹配关键字, 采样间隔ms, 单次样本数, 写出的 CSV 列提取器)
# Non-wakeup：持续采集、无需唤醒锁额外开销；关键字用于从 -l 列表里子串匹配真实名。
# 列提取器把 values 数组映射成「列名 -> 值」的 dict，None 表示该样本无效（如离体）。
SENSOR_SPECS: list[dict] = [
    {
        "key": "pah8011_ppg PPG Sensor",      # 主信号：IR + Red 双通道
        "delay_ms": 50,                        # 20Hz
        "count": 10_000_000,                   # 常驻：天文数字循环（-n 大数）
        "columns": ["ppg_ir", "ppg_red", "ppg_led_curr"],
        "extract": lambda v: {
            "ppg_ir": v[0] if len(v) > 0 else None,
            "ppg_red": v[1] if len(v) > 1 else None,
            # pah8011 第 3 位恒为 128（LED 电流/增益标志），保留以备排查
            "ppg_led_curr": v[2] if len(v) > 2 else None,
        },
    },
    {
        "key": "lsm6dso Accelerometer",        # 运动伪影主因
        "delay_ms": 50,
        "count": 10_000_000,
        "columns": ["acc_x", "acc_y", "acc_z"],
        "extract": lambda v: {
            "acc_x": v[0] if len(v) > 0 else None,
            "acc_y": v[1] if len(v) > 1 else None,
            "acc_z": v[2] if len(v) > 2 else None,
        },
    },
    {
        "key": "lsm6dso Gyroscope",             # 手腕旋转/摆动
        "delay_ms": 50,
        "count": 10_000_000,
        "columns": ["gyro_x", "gyro_y", "gyro_z"],
        "extract": lambda v: {
            "gyro_x": v[0] if len(v) > 0 else None,
            "gyro_y": v[1] if len(v) > 1 else None,
            "gyro_z": v[2] if len(v) > 2 else None,
        },
    },
    {
        "key": "linear_acceleration",          # 去重力线性加速度
        "delay_ms": 50,
        "count": 10_000_000,
        "columns": ["linacc_x", "linacc_y", "linacc_z"],
        "extract": lambda v: {
            "linacc_x": v[0] if len(v) > 0 else None,
            "linacc_y": v[1] if len(v) > 1 else None,
            "linacc_z": v[2] if len(v) > 2 else None,
        },
    },
    {
        "key": "lifeq_lel_rr RR Sensor",       # 厂商 RR 间期（HRV 对照）
        "delay_ms": 1000,
        "count": 10_000_000,
        "columns": ["rr_ms"],
        "extract": lambda v: {"rr_ms": v[0] if len(v) > 0 else None},
    },
    {
        "key": "lifeq_lel_heart_beat",         # 厂商心跳事件（对照）
        "delay_ms": 1000,
        "count": 10_000_000,
        "columns": ["heart_beat"],
        "extract": lambda v: {"heart_beat": v[0] if len(v) > 0 else None},
    },
    {
        "key": "pah8011_offbody_detect",       # 离体检测（标记无效段）
        "delay_ms": 1000,
        "count": 10_000_000,
        "columns": ["offbody"],
        "extract": lambda v: {"offbody": v[0] if len(v) > 0 else None},
    },
    {
        "key": "ltr308 Ambient Light Sensor",  # 环境光（光学干扰判断）
        "delay_ms": 1000,
        "count": 10_000_000,
        "columns": ["lux"],
        "extract": lambda v: {"lux": v[0] if len(v) > 0 else None},
    },
]

# 所有写入 CSV 的列（顺序即表头顺序）：
#   ts          接收时间戳（daemon 收到该样本的时刻，ISO8601 毫秒）
#   sensor      传感器名（用于溯源/排查）
#   + 各 spec.columns 展开
CSV_COLUMNS = ["ts", "sensor"]
for _s in SENSOR_SPECS:
    CSV_COLUMNS.extend(_s["columns"])

# 数据采集与写入之间的有界队列，避免内存无限增长（手表内存有限）
WRITE_QUEUE: "queue.Queue[dict|None]" = queue.Queue(maxsize=20000)


# --------------------------------------------------------------------------- #
# termux-sensor 流式帧拼装器
# --------------------------------------------------------------------------- #

class FrameAssembler:
    """把 termux-sensor 的多行 pretty-print stdout 拼成完整 JSON 帧。

    termux-sensor 每个采样帧形如（跨多行）：
        {
          "传感器名": {
            "values": [ ... ]
          }
        }
    本类逐行累积，靠大括号深度判断帧边界，深度归零时整体 json.loads。
    同时容忍 {} 空对象帧（实测会先吐若干 {"传感器名": {}} 再出真实值）。
    """

    def __init__(self) -> None:
        self._buf: list[str] = []
        self._depth = 0

    def feed(self, line: str) -> list[dict]:
        """喂入一行，返回本行触发解析出的 0 个或多个完整帧。"""
        frames: list[dict] = []
        if not line:
            return frames
        self._depth += line.count("{")
        self._depth -= line.count("}")
        self._buf.append(line)
        if self._depth <= 0:
            raw = "".join(self._buf).strip()
            self._buf.clear()
            self._depth = 0
            if raw:
                try:
                    obj = json.loads(raw)
                    if isinstance(obj, dict):
                        frames.append(obj)
                except json.JSONDecodeError as e:
                    log.debug("帧解析失败（忽略）: %s | raw=%.80s", e, raw)
        return frames


# --------------------------------------------------------------------------- #
# 单条采集流
# --------------------------------------------------------------------------- #

@dataclass
class SensorStream:
    """一条 termux-sensor 子进程数据流。"""
    spec: dict
    sensor_name: str           # 从 -l 解析出的真实名称
    proc: subprocess.Popen | None = None
    _stop = threading.Event()

    def stop(self) -> None:
        self._stop.set()
        p = self.proc
        if p and p.poll() is None:
            try:
                p.terminate()
            except Exception:
                pass

    def run(self) -> None:
        """拉起 termux-sensor，读 stdout 拼帧，提取 values 入队。"""
        cmd = [
            "termux-sensor",
            "-s", self.sensor_name,
            "-n", str(self.spec["count"]),
            "-d", str(self.spec["delay_ms"]),
        ]
        assembler = FrameAssembler()
        try:
            self.proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
            )
        except FileNotFoundError:
            log.error("找不到 termux-sensor，请先 pkg install termux-api")
            return
        # 后台排空 stderr，防管道死锁
        threading.Thread(target=_drain, args=(self.proc.stderr,), daemon=True).start()
        assert self.proc.stdout is not None
        for line in iter(self.proc.stdout.readline, ""):
            if self._stop.is_set():
                break
            for frame in assembler.feed(line):
                self._handle_frame(frame)
        try:
            if self.proc.poll() is None:
                self.proc.terminate()
        except Exception:
            pass

    def _handle_frame(self, frame: dict) -> None:
        # 帧形如 {"传感器名": {"values": [...]}}；也可能含非目标传感器
        for name, body in frame.items():
            if name != self.sensor_name:
                # termux 偶尔把帧键名做了规范化，做一次子串兜底
                if self.spec["key"].lower() not in name.lower():
                    continue
            values = (body or {}).get("values") if isinstance(body, dict) else None
            if not values:
                # 空帧（{} 或 values 缺失）：跳过，不污染 CSV
                continue
            try:
                row = self.spec["extract"](values)
            except Exception as e:
                log.debug("提取 %s 失败: %s values=%s", name, e, values)
                continue
            row["ts"] = datetime.now().isoformat(timespec="milliseconds")
            row["sensor"] = name
            _enqueue(row)


def _drain(stream) -> None:
    """持续读空一个流，防管道死锁。"""
    try:
        for _ in iter(stream.readline, ""):
            pass
    except Exception:
        pass


def _enqueue(row: dict) -> None:
    """非阻塞入队；队列满则丢最旧样本并告警（保最新、防 OOM）。"""
    try:
        WRITE_QUEUE.put_nowait(row)
    except queue.Full:
        try:
            WRITE_QUEUE.get_nowait()  # 丢最旧
        except queue.Empty:
            pass
        try:
            WRITE_QUEUE.put_nowait(row)
        except queue.Full:
            pass


# --------------------------------------------------------------------------- #
# CSV 写出器（单线程消费队列，合并同一时刻的多传感器样本）
# --------------------------------------------------------------------------- #

@dataclass
class CsvWriter:
    path: str
    _lock = threading.Lock()
    _header_written = False

    def ensure(self) -> None:
        os.makedirs(os.path.dirname(self.path) or ".", exist_ok=True)
        if not os.path.exists(self.path) or os.path.getsize(self.path) == 0:
            with self._lock, open(self.path, "w", newline="", encoding="utf-8") as f:
                csv.DictWriter(f, fieldnames=CSV_COLUMNS).writeheader()
            self._header_written = True
        else:
            self._header_written = True

    def write_row(self, row: dict) -> None:
        with self._lock, open(self.path, "a", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=CSV_COLUMNS)
            # 补全缺失列，避免 DictWriter 因 extrasaction 抛错
            full = {c: row.get(c, "") for c in CSV_COLUMNS}
            w.writerow(full)


def writer_loop(writer: CsvWriter, stop_evt: threading.Event) -> None:
    """消费队列写 CSV。"""
    writer.ensure()
    while not stop_evt.is_set():
        try:
            row = WRITE_QUEUE.get(timeout=1.0)
        except queue.Empty:
            continue
        if row is None:
            break
        try:
            writer.write_row(row)
        except Exception as e:
            log.error("写 CSV 失败: %s", e)


# --------------------------------------------------------------------------- #
# 传感器名解析（解决双空格陷阱）
# --------------------------------------------------------------------------- #

def resolve_sensor_names() -> dict[str, str]:
    """跑 termux-sensor -l，按 spec.key 子串匹配真实名称。

    返回 {spec_key: 真实名}。匹配不到的 spec 跳过并告警，
    这样 daemon 仍能采集其余可用传感器，而非整体崩溃。
    """
    resolved: dict[str, str] = {}
    try:
        proc = subprocess.run(
            ["termux-sensor", "-l"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, timeout=20,
        )
    except FileNotFoundError:
        log.error("找不到 termux-sensor，请先 pkg install termux-api")
        return resolved
    except Exception as e:
        log.error("termux-sensor -l 失败: %s", e)
        return resolved
    try:
        listing = json.loads(proc.stdout or "{}").get("sensors", [])
    except Exception:
        listing = []
    listing = [s for s in listing if "Non-wakeup" in s]
    for spec in SENSOR_SPECS:
        key = spec["key"].lower()
        hit = next((s for s in listing if key in s.lower()), None)
        if hit:
            resolved[spec["key"]] = hit
            log.info("传感器匹配: %s -> %s", spec["key"], hit)
        else:
            log.warning("未找到传感器 %s（跳过该流）", spec["key"])
    return resolved


# --------------------------------------------------------------------------- #
# 主流程
# --------------------------------------------------------------------------- #

def run_daemon(once: bool = False) -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )
    log.info("WearMax hr.daemon 启动")
    log.info("CSV 路径: %s", os.path.abspath(CSV_PATH))

    names = resolve_sensor_names()
    if not names:
        log.error("没有可用传感器，退出")
        return

    streams: list[SensorStream] = []
    for spec in SENSOR_SPECS:
        name = names.get(spec["key"])
        if not name:
            continue
        streams.append(SensorStream(spec=spec, sensor_name=name))

    writer = CsvWriter(path=CSV_PATH)
    stop_evt = threading.Event()
    wt = threading.Thread(target=writer_loop, args=(writer, stop_evt), daemon=True)
    wt.start()

    threads: list[threading.Thread] = []
    for s in streams:
        t = threading.Thread(target=s.run, daemon=True)
        t.start()
        threads.append(t)
    log.info("已启动 %d 条采集流", len(threads))

    def _shutdown(signum=None, frame=None) -> None:
        log.info("收到信号，停止采集…")
        stop_evt.set()
        for s in streams:
            s.stop()
    signal.signal(signal.SIGINT, _shutdown)
    signal.signal(signal.SIGTERM, _shutdown)

    if once:
        time.sleep(5)
        _shutdown()
        return

    # 常驻：等任意流结束或信号
    for t in threads:
        t.join()
    stop_evt.set()
    WRITE_QUEUE.put(None)
    wt.join(timeout=3)
    log.info("hr.daemon 已停止")


def main() -> None:
    ap = argparse.ArgumentParser(description="WearMax 传感器采集 daemon")
    ap.add_argument("--once", action="store_true", help="只跑一轮用于验证后退出")
    args = ap.parse_args()
    run_daemon(once=args.once)


if __name__ == "__main__":
    main()
