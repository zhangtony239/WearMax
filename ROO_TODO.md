# ROO_TODO.md — WearMax 开发计划

> 本地用 **uv** 做包管理；代码运行环境为手表 **Termux (Python 3.11)**。

## ✅ 实现状态总览

| 模块 | 文件 | 状态 |
|------|------|------|
| 总起 | [`src/main.py`](src/main.py) | ✅ 拉起 zeroclaw/hr.server/hr.daemon 三进程 + fail-fast 生命周期 |
| 采集 daemon | [`src/hr/daemon.py`](src/hr/daemon.py) | ✅ 流式帧拼装器 + 多流采集 + CSV 落盘 |
| 数据处理 | [`src/hr/data_process.py`](src/hr/data_process.py) | ✅ PyPPG 真实 API + 降级 + 升采样 |
| AI 取数工具 | [`src/hr/get.py`](src/hr/get.py) | ✅ CLI → JSON |
| 仪表盘 | [`src/hr/server.py`](src/hr/server.py) | ✅ Streamlit stub |
| 包配置 | [`pyproject.toml`](pyproject.toml) | ✅ uv 依赖 + console_scripts |
| 工具说明书 | [`skills/get_hr/SKILL.md`](skills/get_hr/SKILL.md) | ✅ 给 zeroclaw |
| 采集脚本 | [`termux/sensor_test.py`](termux/sensor_test.py) | ✅ 纯标准库 |
| 测试 | [`tests/`](tests/) | ✅ 18 个 pytest 全过 |

## 一、架构与进程拓扑

`main.py` 作为总起，拉起三个常驻进程：

| 进程 | 角色 | 启动命令 |
|------|------|---------|
| zeroclaw daemon | AI 大脑（外部二进制） | `~/zeroclaw daemon` |
| hr.server | Streamlit 仪表盘（本期 stub） | `python -m hr.server` |
| hr.daemon | 监听 termux-sensor PPG 推流 → CSV | `python -m hr.daemon` |

`hr.get` 是工具（非常驻），注册为 console_script `hr-get`，zeroclaw 走 shell 调用。

## 二、关键决策记录

1. **PPG 双通道全留**：pah8011 含 IR(values[0])+Red(values[1]) 双通道——IR 是标准心率/HRV 波形源，Red 配合 IR 可算 SpO2。落盘 ppg_ir + ppg_red 两列。
2. **heart_rate 弃用**（实测报 No valid sensors）；**heart_beat 保留**；**offbody_detect 用双空格名争取**厂商算法。
3. **zeroclaw 启动**：`~/zeroclaw daemon` 直接 subprocess。
4. **hr.get 集成**：CLI console_script，说明书在 [`skills/get_hr/SKILL.md`](skills/get_hr/SKILL.md)。
5. **PyPPG 包名**：PyPI 上是 `pyPPG`（注意大小写），import 名也是 `pyPPG`。

## 三、CSV Schema（data/hr.csv）

```
ts, sensor, ppg_ir, ppg_red, ppg_led_curr,
acc_x, acc_y, acc_z,
gyro_x, gyro_y, gyro_z,
linacc_x, linacc_y, linacc_z,
rr_ms, heart_beat, offbody, lux
```

- `ts`：接收时间戳 ISO8601 毫秒
- `sensor`：传感器名（溯源）
- PPG：双通道 + LED 电流标志
- IMU：加速度/陀螺仪/线性加速度 三轴（运动伪影降噪）
- 厂商：rr_ms(RR间期) / heart_beat(心跳) / offbody(离体)
- 环境光 lux（光学干扰判断）

## 四、核心技术难点与解法

### 4.1 termux-sensor 输出是「多行 pretty-print JSON」
不是每行一个完整 JSON，而是跨多行帧。daemon 用 [`FrameAssembler`](src/hr/daemon.py) 类：逐行累积，靠大括号深度判断帧边界，深度归零时整体 `json.loads`。

### 4.2 传感器名称双空格陷阱
`lifeq_lel_heart_rate`、`pah8011_offbody_detect` 与 `Non-wakeup` 间是双空格。daemon 先跑 `termux-sensor -l` 拿真实列表，按子串匹配规避。

### 4.3 PyPPG 真实 API（非猜测，来自 example.py）
```
DotMap s ← .v .fs .start .end .name
Preprocessing(s) → s.filt_sig / filt_d1 / filt_d2 / filt_d3
PPG(s) → FpCollection(s).get_fiducials(s) → Fiducials(fp)
BmCollection(s, fp).get_biomarkers() → bm_defs/bm_vals/bm_stats
get_ppgSQI(s.filt_sig, s.fs, fp.sp) → 信号质量%
```
关键指标：`Tpp`(peak-to-peak间期) → 心率 60/Tpp；RR = Tpp×1000ms；RMSSD 由 RR 序列算。

## 五、测试

```bash
uv run pytest tests/ -v   # 18 passed
```
覆盖：FrameAssembler 帧拼装（真实 wear 数据）、CSV 读写、升采样、PyPPG 调用链路、降级路径。
