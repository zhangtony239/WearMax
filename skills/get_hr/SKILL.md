# get_hr — 获取用户心率 / 体征数据

> 这个工具让你（zeroclaw / AI）能从 WearMax 的 CSV 数据库里取到用户的实时心率、HRV、RR 间期、PPG 原始波形等体征数据。
> 用途：用户问"我现在心率多少"、"最近一分钟 HRV 怎么样"、需要体征做健康分诊时调用。

## 怎么调用

直接在 shell 里执行 `hr-get`，结果以 **JSON** 输出到 stdout。

```bash
# 最近 60 秒摘要（默认）—— 含心率 / HRV / RR / 呼吸率
hr-get

# 指定摘要窗口（秒）
hr-get --window 300          # 最近 5 分钟

# 取最近 N 个原始 PPG 波形点
hr-get --raw 100             # 最近 100 个点（fs≈20Hz → 5 秒）

# 指定时间区间（ISO8601）
hr-get --since "2026-07-11T09:33:00" --until "2026-07-11T09:34:00"
```

## 返回结构

### 摘要模式（`hr-get` / `--window`）
```json
{
  "generated_at": "2026-07-11T09:35:00",
  "mode": "summary_recent",
  "window_s": 60,
  "n_samples": 1200,
  "fs": 20.0,
  "duration_s": 60.0,
  "heart_rate": 72.5,
  "hrv_rmssd": 38.2,
  "rr_ms": [812, 824, 805, ...],
  "resp_rate": 16.3,
  "spo2": null,
  "window_start": "...",
  "window_end": "..."
}
```

### 原始模式（`--raw N`）
```json
{
  "mode": "raw",
  "n": 100,
  "fs": 20.0,
  "ppg_ir": [177156.5, 176931.9, ...],
  "timestamps": ["2026-07-11T09:33:16.806", ...]
}
```

## 字段说明

| 字段 | 含义 | 单位/范围 | 备注 |
|------|------|-----------|------|
| heart_rate | 心率 | bpm | 由 PyPPG 算出；不可用时降级估算 |
| hrv_rmssd | 心率变异性(RMSSD) | ms | 越高副交感越好 |
| rr_ms | RR 间期序列 | ms | HRV 分析基础数据 |
| resp_rate | 呼吸率 | 次/分 | PPG 衍生 |
| spo2 | 血氧 | % | 后续迭代支持 |
| ppg_ir | PPG 红外原始波形 | ADC 原始值 | 双通道之一 |
| offbody | 离体标记 | — | 见 CSV |

## 错误处理

- 数据文件不存在时返回 `{"error": "no data file: ..."}`，提示 hr.daemon 未运行。
- 时间格式错误：exit code 2，错误信息走 stderr。
- 样本太少（<20 点）：心率等指标为 `null`，但仍返回统计信息。

## 数据来源

- CSV：`data/hr.csv`（由 `hr.daemon` 持续写入）
- 列：`ts, sensor, ppg_ir, ppg_red, ppg_led_curr, acc_x/y/z, gyro_x/y/z, linacc_x/y/z, rr_ms, heart_beat, offbody, lux`
- 处理逻辑见 `hr.data_process`（PyPPG），与 `hr.server` 展示口径一致。
