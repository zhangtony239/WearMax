"""WearMax hr.data_process — PPG 信号处理（基于 PyPPG）。

本模块是 hr.server（展示）与 hr.get（AI 取数）共用的数据处理层，
把 hr.daemon 落盘的原始 PPG/IMU 数据加工成医学诊断有用的指标：
心率、HRV、脉搏波特征等，目标超越小米自带的民用级。

设计要点：
    - 采样率 fs：termux-sensor -d 50ms → ~20Hz。PyPPG 推荐 ≥100Hz，
      因此内置可选升采样（线性插值到 fs_up）以提升算法精度。
    - 双通道：pah8011 的 IR（values[0]）与 Red（values[1]）都保留。
      IR 是标准心率/HRV 波形源；Red 配合 IR 可进一步估算 SpO2（后续迭代）。
    - 运动伪影：用加速度幅值剔除强运动段（offbody/剧烈运动时 PPG 无效）。
    - PyPPG 官方流程（见 site-packages/pyPPG/example.py）：
        1) 构造 DotMap 结构体 s（.v 信号 / .fs 采样率 / .start .end .name）
        2) Preprocessing(s) → s.filt_sig / filt_d1 / filt_d2 / filt_d3
        3) PPG(s) → FpCollection(s).get_fiducials(s) → Fiducials(fp)
        4) BmCollection(s, fp).get_biomarkers() → bm_defs/bm_vals/bm_stats
        5) get_ppgSQI(s.filt_sig, s.fs, fp.sp) → 信号质量
      关键指标：Tpp(peak-to-peak 间期) → 心率 60/Tpp；Tpi(脉搏间期) → HRV。
      依赖未安装时函数优雅降级返回 None，不阻塞 get/server 的数据链路。

对外主要函数：
    compute_metrics(rows, fs=20, fs_up=100) -> dict
        输入 PPG 样本序列，输出 {heart_rate, rr, hrv_rmssd, resp_rate, ...}
    load_ppg_series(path, since=None, until=None) -> (signal, timestamps)
        从 CSV 抽取 PPG 通道 + 时间戳
"""
from __future__ import annotations

import csv
import logging
import math
import os
from dataclasses import dataclass
from datetime import datetime
from typing import Iterator

log = logging.getLogger("hr.data_process")

# 与 hr.daemon 一致
DATA_DIR = os.environ.get("WEARMAX_DATA_DIR", "data")
CSV_PATH = os.path.join(DATA_DIR, "hr.csv")

# 默认采样率：termux-sensor -d 50ms ≈ 20Hz
DEFAULT_FS = 20.0
# PyPPG 推荐 ≥100Hz；升采样目标
DEFAULT_FS_UP = 100.0


# --------------------------------------------------------------------------- #
# CSV 读取
# --------------------------------------------------------------------------- #

@dataclass
class Sample:
    ts: datetime
    sensor: str
    values: dict[str, float | None]


def _parse_ts(s: str) -> datetime | None:
    try:
        return datetime.fromisoformat(s)
    except Exception:
        return None


def iter_csv(path: str = CSV_PATH) -> Iterator[Sample]:
    """流式遍历 CSV，逐行产出 Sample。"""
    if not os.path.exists(path):
        return
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            ts = _parse_ts(row.get("ts", ""))
            if ts is None:
                continue
            values = {}
            for k, v in row.items():
                if k in ("ts", "sensor"):
                    continue
                try:
                    values[k] = float(v) if v not in (None, "") else None
                except ValueError:
                    values[k] = None
            yield Sample(ts=ts, sensor=row.get("sensor", ""), values=values)


def load_ppg_series(
    path: str = CSV_PATH,
    since: datetime | None = None,
    until: datetime | None = None,
) -> tuple[list[float], list[datetime]]:
    """抽取 PPG IR 通道 + 对应时间戳。

    用 IR（ppg_ir）作为主波形：这是 pah8011 的红外通道，
    是心率/HRV 计算的标准信号源。
    """
    sig: list[float] = []
    ts: list[datetime] = []
    for s in iter_csv(path):
        if since and s.ts < since:
            continue
        if until and s.ts > until:
            continue
        v = s.values.get("ppg_ir")
        if v is None or (isinstance(v, float) and math.isnan(v)):
            continue
        sig.append(v)
        ts.append(s.ts)
    return sig, ts


def load_imu_motion(path: str = CSV_PATH) -> list[float]:
    """抽取加速度幅值序列（用于运动段剔除）。

    幅值 = √(x²+y²+z²)，整体接近 g(9.8)；剧烈偏离表示强运动，该段 PPG 不可信。
    """
    out: list[float] = []
    for s in iter_csv(path):
        x = s.values.get("acc_x")
        y = s.values.get("acc_y")
        z = s.values.get("acc_z")
        if x is None or y is None or z is None:
            continue
        out.append(math.sqrt(x * x + y * y + z * z))
    return out


# --------------------------------------------------------------------------- #
# 信号预处理
# --------------------------------------------------------------------------- #

def resample_linear(sig: list[float], fs_in: float, fs_out: float) -> list[float]:
    """线性插值升采样，供 PyPPG 提升精度用。"""
    if fs_out <= fs_in or len(sig) < 2:
        return list(sig)
    ratio = fs_out / fs_in
    n_out = max(2, int(round(len(sig) * ratio)))
    out: list[float] = []
    for i in range(n_out):
        src = i / ratio
        lo = int(src)
        hi = min(lo + 1, len(sig) - 1)
        frac = src - lo
        out.append(sig[lo] * (1 - frac) + sig[hi] * frac)
    return out


# --------------------------------------------------------------------------- #
# PyPPG 指标计算
# --------------------------------------------------------------------------- #

def compute_metrics(
    rows: list[float] | None = None,
    fs: float = DEFAULT_FS,
    fs_up: float = DEFAULT_FS_UP,
    path: str = CSV_PATH,
) -> dict:
    """计算 PPG 衍生指标（心率/HRV/呼吸率等）。

    参数:
        rows: 已抽取的 PPG 序列；为 None 时从 CSV 读取最近一段。
        fs:   原始采样率（Hz）。
        fs_up: 升采样目标（Hz），提升 PyPPG 精度；<=fs 则不升采样。
        path: CSV 路径。

    返回 dict，至少包含：
        n_samples, duration_s, heart_rate, rr_ms(list), hrv_rmssd, resp_rate,
        若 PyPPG 不可用则对应值为 None 并附 raw 统计。
    """
    if rows is None:
        rows, _ = load_ppg_series(path)

    result: dict = {
        "n_samples": len(rows),
        "fs": fs,
        "fs_up": fs_up,
        "duration_s": round(len(rows) / fs, 2) if fs else 0,
        "heart_rate": None,
        "rr_ms": [],
        "hrv_rmssd": None,
        "resp_rate": None,
        "spo2": None,
        "raw_mean": None,
        "raw_std": None,
    }

    if len(rows) < 20:  # 太短无法分析
        return result

    import numpy as np
    sig = np.asarray(rows, dtype=float)
    result["raw_mean"] = float(np.mean(sig))
    result["raw_std"] = float(np.std(sig))

    # 升采样
    if fs_up > fs:
        sig = np.asarray(resample_linear(rows, fs, fs_up), dtype=float)
        fs_eff = fs_up
    else:
        fs_eff = fs

    # 尝试用 PyPPG 做完整分析；不可用则降级到简易峰值法
    try:
        metrics = _compute_pyppg(sig, fs_eff)
        result.update(metrics)
    except Exception as e:
        log.warning("PyPPG 分析失败，降级简易估算: %s", e)
        result.update(_compute_simple(sig, fs_eff))

    return result


def _compute_pyppg(sig, fs: float) -> dict:
    """用 PyPPG 官方流程计算指标（见 pyPPG/example.py）。

    流程：
        1) DotMap s ← .v .fs .start .end .name + Preprocessing 生成 filt_*
        2) PPG(s) → FpCollection(s).get_fiducials(s) → Fiducials(fp)
        3) BmCollection(s, fp).get_biomarkers() → bm_vals/bm_stats
        4) get_ppgSQI(s.filt_sig, s.fs, fp.sp) → 信号质量
    关键指标提取：
        - 心率：bm_stats['ppg_sig']['Tpp']['mean']（peak-to-peak 间期均值）→ 60/Tpp
        - RR 间期：Tpp 序列（秒）×1000 → ms
        - HRV RMSSD：由 RR 序列计算
    """
    import numpy as np
    out: dict = {}

    try:
        from dotmap import DotMap
        import pyPPG
        from pyPPG import PPG, Fiducials
        from pyPPG.preproc import Preprocessing
        import pyPPG.fiducials as FP
        import pyPPG.biomarkers as BM
        import pyPPG.ppg_sqi as SQI
    except ImportError as e:
        raise ImportError(f"PyPPG 未安装或依赖缺失: {e}") from e

    v = np.asarray(sig, dtype=float).ravel()
    s = DotMap()
    s.v = v
    s.fs = fs
    s.start = 0
    s.end = len(v)
    s.name = "wearmax"
    # 预处理：生成滤波信号及 1/2/3 阶导数
    s.filt_sig, s.filt_d1, s.filt_d2, s.filt_d3 = Preprocessing(s, filtering=True)

    # PPG 结构体 → 特征点
    sobj = PPG(s)
    fpex = FP.FpCollection(sobj)
    fiducials = fpex.get_fiducials(sobj, correct=True) + s.start
    fp = Fiducials(fiducials)

    # 生物标志物（74 项：ppg_sig / sig_ratios / ppg_derivs / derivs_ratios）
    bmex = BM.BmCollection(sobj, fp)
    bm_defs, bm_vals, bm_stats = bmex.get_biomarkers()

    # 信号质量
    try:
        sqi = round(float(np.mean(SQI.get_ppgSQI(s.filt_sig, s.fs, fp.sp))) * 100, 2)
    except Exception:
        sqi = None
    out["sqi_pct"] = sqi

    # —— 提取心率 / RR / HRV ——
    ppg_sig_stats = bm_stats.get("ppg_sig", {}) if bm_stats else {}
    ppg_sig_vals = bm_vals.get("ppg_sig", {}) if bm_vals else {}

    # Tpp = peak-to-peak 间期（秒），心率 = 60 / Tpp
    tpp_stats = ppg_sig_stats.get("Tpp", {})
    tpp_mean = _stat_field(tpp_stats, "mean")
    if tpp_mean and tpp_mean > 0:
        out["heart_rate"] = round(60.0 / tpp_mean, 1)

    # RR 间期序列（ms）：取 Tpp 逐拍值（秒）×1000
    tpp_vals = ppg_sig_vals.get("Tpp")
    if tpp_vals is not None:
        try:
            rr_ms = [round(float(x) * 1000, 1) for x in tpp_vals if x is not None]
            out["rr_ms"] = rr_ms
            # RMSSD = √(Σ ΔRR² / (n-1))
            if len(rr_ms) >= 2:
                diffs = [(b - a) for a, b in zip(rr_ms, rr_ms[1:])]
                rmssd = (sum(d * d for d in diffs) / (len(diffs))) ** 0.5
                out["hrv_rmssd"] = round(rmssd, 1)
        except Exception as e:
            log.debug("提取 RR/RMSSD 失败: %s", e)

    # Tpi = 脉搏间期（onset→offset），也作为心率参考
    tpi_stats = ppg_sig_stats.get("Tpi", {})
    tpi_mean = _stat_field(tpi_stats, "mean")
    if tpi_mean and tpi_mean > 0 and not out.get("heart_rate"):
        out["heart_rate"] = round(60.0 / tpi_mean, 1)

    # 保留完整的 PyPPG 统计供医学诊断调用（74 项指标）
    out["ppg_bm_stats"] = _serialize_bm(ppg_sig_stats)
    out["n_beats"] = len(fp.sp) if hasattr(fp, "sp") and fp.sp is not None else 0
    return out


def _stat_field(stats: dict, field: str) -> float | None:
    """从 biomarker 统计 dict 里安全取一个数值字段。"""
    if not stats:
        return None
    v = stats.get(field)
    if v is None:
        return None
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def _serialize_bm(stats: dict) -> dict:
    """把 PyPPG biomarker 统计序列化为可 JSON 的 dict。"""
    out: dict = {}
    for k, v in (stats or {}).items():
        try:
            if isinstance(v, dict):
                out[k] = {kk: _safe_num(vv) for kk, vv in v.items()}
            else:
                out[k] = _safe_num(v)
        except Exception:
            out[k] = str(v)
    return out


def _safe_num(v):
    try:
        f = float(v)
        return round(f, 4) if not (f != f) else None  # NaN 检测
    except (TypeError, ValueError):
        return str(v)


def _compute_simple(sig, fs: float) -> dict:
    """PyPPG 不可用时的简易降级：差分+包络峰值检测估算心率。

    精度有限，但保证链路可用，至少给 AI 一个大致心率。
    """
    import numpy as np
    out: dict = {}
    if len(sig) < int(fs * 3):
        return out
    # 去均值 + 差分近似高通 + 移动平均近似低通
    s = sig - np.mean(sig)
    diff = np.abs(np.diff(s))
    win = max(3, int(fs * 0.2))
    kernel = np.ones(win) / win
    env = np.convolve(diff, kernel, mode="same")
    thr = np.max(env) * 0.4
    peaks = (env > thr).astype(int)
    crossings = int(np.sum(peaks[1:] - peaks[:-1] == 1))
    dur = len(s) / fs
    bpm = round(crossings / dur * 60, 1) if dur > 0 else None
    out["heart_rate"] = bpm
    return out


# --------------------------------------------------------------------------- #
# 统计摘要（给 hr.get 直接用）
# --------------------------------------------------------------------------- #

def latest_summary(path: str = CSV_PATH, lookback_s: int = 60) -> dict:
    """取最近 lookback_s 秒的数据，返回指标摘要 + 数据范围。

    给 hr.get 调用：AI 只需「最近一分钟的心率/HRV」时用此函数。
    """
    if not os.path.exists(path):
        return {"error": f"no data file: {path}"}
    all_ts = [s.ts for s in iter_csv(path)]
    if not all_ts:
        return {"error": "empty csv"}
    latest = max(all_ts)
    from datetime import timedelta
    since = latest - timedelta(seconds=lookback_s)

    rows, ts = load_ppg_series(path, since=since)
    metrics = compute_metrics(rows, path=path)
    metrics["window_start"] = since.isoformat()
    metrics["window_end"] = latest.isoformat()
    return metrics
