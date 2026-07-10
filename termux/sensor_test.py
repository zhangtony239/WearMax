#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
WearMax 传感器采集测试脚本（纯标准库，无第三方依赖）

作用：
    逐个采集本项目关心的传感器，每条数据补上接收时间戳，
    导出到脚本所在目录下的 sensor_test.txt，供开发确认 JSON 结构。

在 Termux 里运行（先 adb push 到手表，例如 /sdcard/ 或 ~/）：
    python3 sensor_test.py            # 采集全部预设传感器
    python3 sensor_test.py --list     # 仅列出可用传感器后退出
    python3 sensor_test.py --delay 50 --count 200   # 全局覆盖采样参数
    python3 sensor_test.py --out /sdcard/sensor_test.txt

注意：
    1. 请先 pkg install termux-api（脚本会检测 termux-sensor 是否存在）。
    2. 首次运行 termux-sensor 手表会弹传感器权限，请允许。
    3. 采集时手表请佩戴贴肤、尽量保持静止。
    4. 若某传感器采集到 0 行，多半是名称对不上 termux-sensor -l 的实际输出，
       文件开头已写入 -l 列表，原样发回我来修正。
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import threading
import time
from datetime import datetime

# ---------- 感兴趣的传感器预设 ----------
# (传感器名, 采样间隔ms, 采样次数, 说明)
SENSORS = [
    ("pah8011_ppg PPG Sensor Non-wakeup", 50, 200,
     "PPG 原始波形 20Hz*10s（PyPPG 主输入）"),
    ("pah8011_offbody_detect Non-wakeup", 1000, 10,
     "离体检测（标记无效数据段，没戴时 PPG 无意义）"),
    ("lsm6dso Accelerometer Non-wakeup", 50, 200,
     "加速度 20Hz*10s（运动伪影主因）"),
    ("lsm6dso Gyroscope Non-wakeup", 50, 200,
     "陀螺仪 20Hz*10s（手腕旋转/摆动）"),
    ("linear_acceleration", 50, 200,
     "线性加速度 20Hz*10s（去重力，活动分级/运动段剔除）"),
    ("lifeq_lel_heart_rate Non-wakeup", 1000, 15,
     "厂商心率 15s（对照 PyPPG 算出的心率）"),
    ("lifeq_lel_heart_beat Non-wakeup", 1000, 15,
     "心跳事件 15s（对照）"),
    ("lifeq_lel_rr RR Sensor Non-wakeup", 1000, 15,
     "RR 间期 15s（HRV 对照）"),
    ("ltr308 Ambient Light Sensor Non-wakeup", 1000, 10,
     "环境光 10s（光学干扰判断）"),
]


def now_ms():
    return datetime.now().isoformat(timespec="milliseconds")


def drain_stderr(stream, sink):
    """后台线程：持续读取 stderr，避免管道死锁。"""
    try:
        for line in iter(stream.readline, ""):
            sink.append(line)
    except Exception:
        pass


def watchdog(proc, timeout):
    """超时看门狗：termux-sensor 卡死时强制结束。"""
    time.sleep(timeout)
    if proc.poll() is None:
        proc.kill()


def run_sensor_list(fh):
    """运行 termux-sensor -l，把可用传感器列表写入文件头。"""
    fh.write("\n" + "=" * 70 + "\n")
    fh.write("===== termux-sensor -l 可用传感器列表 =====\n")
    fh.flush()
    try:
        proc = subprocess.run(
            ["termux-sensor", "-l"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, timeout=20,
        )
        out = proc.stdout or ""
        err = proc.stderr or ""
        fh.write(out + "\n")
        if err.strip():
            fh.write(f"[stderr] {err}\n")
        if proc.returncode != 0:
            fh.write(f"[返回码 {proc.returncode}]\n")
    except Exception as e:
        fh.write(f"[列出失败] {e}\n")
    fh.flush()


def collect_sensor(name, delay, count, note, fh):
    """采集单个传感器，逐行补接收时间戳写入文件，返回采到行数。"""
    header = (
        "\n" + "=" * 70 + "\n"
        f"===== 传感器: {name} =====\n"
        f"命令: termux-sensor -s \"{name}\" -n {count} -d {delay}\n"
        f"说明: {note}\n"
        f"采集开始: {now_ms()}\n"
        "----- 数据（每行 JSON: recv_ts / sensor / data 或 raw）-----\n"
    )
    fh.write(header)
    fh.flush()

    cmd = ["termux-sensor", "-s", name, "-n", str(count), "-d", str(delay)]
    timeout = count * delay / 1000.0 + 20  # 预计耗时 + 20s 余量
    try:
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1,
        )
    except FileNotFoundError:
        fh.write("[错误] 找不到 termux-sensor，请先 pkg install termux-api\n")
        fh.flush()
        return 0

    err_sink = []
    t = threading.Thread(target=drain_stderr, args=(proc.stderr, err_sink), daemon=True)
    t.start()
    wd = threading.Thread(target=watchdog, args=(proc, timeout), daemon=True)
    wd.start()

    n = 0
    try:
        for line in iter(proc.stdout.readline, ""):
            if not line:
                break
            recv = now_ms()
            line = line.rstrip("\n")
            try:
                data = json.loads(line)
                rec = {"recv_ts": recv, "sensor": name, "data": data}
            except Exception:
                # 非 JSON 行（提示/错误文本）原样保留
                rec = {"recv_ts": recv, "sensor": name, "raw": line}
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
            fh.flush()
            n += 1
    finally:
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()
        t.join(timeout=2)

    err_text = "".join(err_sink).strip()
    fh.write(f"----- 汇总: 采到 {n} 行, 结束 {now_ms()} -----\n")
    if err_text:
        fh.write(f"[stderr] {err_text}\n")
    fh.flush()
    return n


def main():
    ap = argparse.ArgumentParser(description="WearMax 传感器采集测试")
    ap.add_argument("--out", default=None,
                    help="输出文件路径，默认脚本所在目录下 sensor_test.txt")
    ap.add_argument("--list", action="store_true",
                    help="仅列出可用传感器后退出")
    ap.add_argument("--delay", type=int, default=None,
                    help="覆盖所有传感器的采样间隔(ms)")
    ap.add_argument("--count", type=int, default=None,
                    help="覆盖所有传感器的采样次数")
    args = ap.parse_args()

    if not shutil.which("termux-sensor"):
        print("[错误] 未找到 termux-sensor。请先执行: pkg install termux-api")
        sys.exit(1)

    out_path = args.out or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "sensor_test.txt"
    )

    print("=" * 50)
    print(" WearMax 传感器采集测试")
    print("=" * 50)
    print("请确认：手表已佩戴贴肤、尽量保持静止。")
    print("若首次运行 termux-sensor，手表会弹传感器权限，请允许。")
    print(f"输出文件: {out_path}")
    print()

    with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("WearMax 传感器采集测试\n")
        fh.write(f"生成时间: {now_ms()}\n")
        fh.write(f"Python: {sys.version.split()[0]}\n")

        print("[1/?] 列出可用传感器 (termux-sensor -l) ...")
        run_sensor_list(fh)
        print("      完成\n")

        if args.list:
            print(f"--list 模式: 已写入 {out_path}")
            return

        total = len(SENSORS)
        summary = []
        for i, (name, delay, count, note) in enumerate(SENSORS):
            d = args.delay if args.delay is not None else delay
            c = args.count if args.count is not None else count
            print(f"[{i+1}/{total}] 采集 {name}  (-n {c} -d {d}) ...")
            n = collect_sensor(name, d, c, note, fh)
            print(f"        采到 {n} 行")
            summary.append((name, n))

        fh.write("\n" + "=" * 70 + "\n")
        fh.write("===== 采集汇总 =====\n")
        for name, n in summary:
            fh.write(f"{n:>6} 行  {name}\n")
        fh.write(f"结束时间: {now_ms()}\n")

    print()
    print("采集完成。")
    print(f"请把 {out_path} 的内容发回，用于确认各传感器 JSON 结构。")


if __name__ == "__main__":
    main()
