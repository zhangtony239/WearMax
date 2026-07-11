"""hr.data_process 单元测试。

覆盖：CSV 读取、PPG 序列抽取、升采样、compute_metrics 降级路径、
PyPPG 真实调用（用合成 PPG 信号验证不抛异常且返回结构正确）。
"""
import csv
import os
import math
from datetime import datetime, timedelta

import numpy as np
import pytest

from hr import data_process as dp


@pytest.fixture
def sample_csv(tmp_path):
    """造一个含 PPG/IMU 数据的 CSV，模拟 daemon 落盘结果。"""
    path = tmp_path / "hr.csv"
    base = datetime(2026, 7, 11, 9, 33, 16)
    # 生成 2 秒 PPG（20Hz=40 点）+ 加速度样本
    fs = 20.0
    n = int(fs * 2)
    t = np.arange(n) / fs
    # 合成一个 ~1.2Hz 的 PPG 脉搏波（~72bpm） + 直流偏置
    ppg = 150000 + 5000 * np.sin(2 * math.pi * 1.2 * t) + np.random.RandomState(42).randn(n) * 50

    rows = []
    for i in range(n):
        ts = (base + timedelta(milliseconds=i * 50)).isoformat(timespec="milliseconds")
        rows.append({
            "ts": ts,
            "sensor": "pah8011_ppg PPG Sensor Non-wakeup",
            "ppg_ir": round(float(ppg[i]), 4),
            "ppg_red": round(float(ppg[i]) - 500, 4),
            "ppg_led_curr": 128,
        })
    # 加几行加速度
    for i in range(0, n, 1):
        ts = (base + timedelta(milliseconds=i * 50)).isoformat(timespec="milliseconds")
        rows.append({
            "ts": ts,
            "sensor": "lsm6dso Accelerometer Non-wakeup",
            "acc_x": 0.1, "acc_y": 0.2, "acc_z": 9.8,
        })

    fields = ["ts", "sensor", "ppg_ir", "ppg_red", "ppg_led_curr",
              "acc_x", "acc_y", "acc_z"]
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)
    return str(path)


class TestCsvReading:
    def test_iter_csv_yields_samples(self, sample_csv):
        samples = list(dp.iter_csv(sample_csv))
        assert len(samples) > 0
        assert all(isinstance(s, dp.Sample) for s in samples)

    def test_load_ppg_series_extracts_ir(self, sample_csv):
        sig, ts = dp.load_ppg_series(sample_csv)
        assert len(sig) == 40  # 2秒 * 20Hz
        assert all(isinstance(v, float) for v in sig)
        assert len(ts) == len(sig)

    def test_load_ppg_series_time_filter(self, sample_csv):
        base = datetime(2026, 7, 11, 9, 33, 16, 500000)
        sig, ts = dp.load_ppg_series(sample_csv, since=base)
        assert all(t >= base for t in ts)

    def test_load_imu_motion_amplitude(self, sample_csv):
        motion = dp.load_imu_motion(sample_csv)
        assert len(motion) == 40
        # 幅值 ≈ √(0.01+0.04+96.04) ≈ 9.81
        assert all(abs(m - 9.81) < 0.1 for m in motion)


class TestResample:
    def test_upsample_increases_length(self):
        sig = [0.0, 1.0, 2.0, 3.0]
        out = dp.resample_linear(sig, fs_in=10.0, fs_out=20.0)
        assert len(out) == 8

    def test_no_upsample_when_fs_equal(self):
        sig = [1.0, 2.0, 3.0]
        out = dp.resample_linear(sig, fs_in=100.0, fs_out=100.0)
        assert out == [1.0, 2.0, 3.0]

    def test_interpolation_preserves_endpoints(self):
        sig = [0.0, 10.0]
        out = dp.resample_linear(sig, fs_in=10.0, fs_out=20.0)
        assert out[0] == pytest.approx(0.0)
        assert out[-1] == pytest.approx(10.0)


class TestComputeMetrics:
    def test_short_signal_returns_nulls(self):
        """太短的信号应返回 None 指标不抛异常。"""
        result = dp.compute_metrics([1.0, 2.0], fs=20.0)
        assert result["heart_rate"] is None
        assert result["n_samples"] == 2

    def test_synthetic_ppg_returns_structure(self, sample_csv):
        """合成 PPG 信号应返回完整的指标结构（不抛异常）。"""
        result = dp.compute_metrics(path=sample_csv, fs=20.0, fs_up=100.0)
        assert "n_samples" in result
        assert "duration_s" in result
        assert result["n_samples"] > 0
        # PyPPG 或降级法至少应算出心率（或 None 但不崩）
        assert "heart_rate" in result

    def test_latest_summary_returns_window(self, sample_csv):
        result = dp.latest_summary(path=sample_csv, lookback_s=60)
        assert "window_start" in result
        assert "window_end" in result
        assert "n_samples" in result
