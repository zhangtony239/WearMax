# ROO_TODO.md — WearMax 开发计划

> 本地用 **uv** 做包管理；代码运行环境为手表 **Termux (Python 3.11)**。
> 先记录计划与待确认项，与你对齐后再开工写各 `.py`。

## 一、架构与进程拓扑

`main.py` 作为总起，拉起三个常驻进程：

| 进程 | 角色 | 本期状态 |
|------|------|---------|
| zeroclaw daemon | AI 大脑（外部二进制） | 由 main 拉起 |
| hr.server | Streamlit 仪表盘，读 CSV 展示 | 本期留空 stub |
| hr.daemon | 监听 termux-sensor 的 PPG 推流，落盘 CSV | 本期实现 |

`hr.get` 是一个**工具**（非常驻进程），注册到 pyproject，供 AI 调用以读 CSV 取数。

## 二、文件职责

- [`src/main.py`](src/main.py) — 总起；用 subprocess 拉起三进程，统一日志/退出/信号处理
- [`src/hr/server.py`](src/hr/server.py) — Streamlit 展示（本期 stub，保留入口）
- [`src/hr/daemon.py`](src/hr/daemon.py) — 监听 termux-sensor PPG JSON 推流 → 写 CSV
- [`src/hr/get.py`](src/hr/get.py) — 工具：读 CSV 直接返回（给 AI 看）
- [`src/hr/data_process.py`](src/hr/data_process.py) — 共享数据处理（PyPPG）：信号清洗 / 心率 / HRV 等指标

## 三、待办清单

- [ ] 搭 `pyproject.toml`：依赖（streamlit、pyppg 等）、`[project.scripts]` 注册 `hr-get`
- [ ] `main.py`：拉起三进程 + 生命周期/信号
- [ ] `hr.daemon`：termux-sensor 推流解析 → CSV
- [ ] `hr.data_process`：PyPPG 处理函数
- [ ] `hr.get`：读 CSV 返回
- [ ] `hr.server`：Streamlit stub

## 四、关键假设（已确认 / 调整）

1. **运行环境**：代码在手表 Termux (Python 3.11) 运行；uv 仅做本地开发/打包
2. **hr.get 集成**：CLI console_script，zeroclaw 走 shell 调用取 stdout JSON
3. **CSV 路径**：`data/hr.csv`（相对运行目录）

## 五、❓ 传感器数据格式分析（来自 sensor_test_bg/wear.txt 实测）

### 5.1 致命发现：termux-sensor 输出是「多行 pretty-print JSON」
不是每行一个完整 JSON，而是一个 frame 跨多行：
```
{
  "lsm6dso Accelerometer Non-wakeup": {
    "values": [
      -0.172,
      5.25,
      8.31
    ]
  }
}
```
→ daemon 必须用「流式帧拼装器」：累积行直到 `{`...`}` 大括号平衡，再整体 `json.loads`，
不能按行解析（我测试脚本按行读导致拆碎，需修正）。

### 5.2 各传感器 values 结构
| 传感器 | values 内容 | 备注 |
|--------|-----------|------|
| pah8011_ppg | [ch0~177k, ch1~143k, 128, 0...] | 前2个是PPG双通道，第3位恒128，余0；离体全0 |
| lsm6dso Accelerometer | [x, y, z] m/s² | 三轴 |
| lsm6dso Gyroscope | [x, y, z] rad/s | 三轴 |
| linear_acceleration | [x, y, z] m/s² | 去重力 |
| lifeq_lel_rr | [rr_ms~751, 0...] | 首位=RR间期ms |
| ltr308 Ambient Light | [lux~190] | 单值 |
| pah8011_offbody / heart_rate / heart_beat | ❌ | 报 "No valid sensors were registered!" |

### 5.3 ⚠️ 三个传感器名称有空格陷阱
`-l` 列表里 `lifeq_lel_heart_rate`、`lifeq_lel_heart_beat`、`pah8011_offbody_detect`
与 `Wakeup`/`Non-wakeup` 之间是**双空格**，我脚本用单空格 → 不识别。
→ 修正：daemon 不应硬编码名称，而应先 `-l` 拿列表，按子串匹配（如 "offbody_detect" + "Non-wakeup"），规避空格问题。

### 5.4 PPG 离体验证
- bg（桌面不戴）：PPG values 全 0 ✓ 与 offbody 语义一致
- wear（佩戴半抬臂）：values[0]~177k、values[1]~143k 有真实波形

## 六、❓ 仍需你拍板

1. **三个失败传感器要不要修测**：offbody_detect 对标记无效段很有用，
   需要你用双空格名称重测确认能出值。heart_rate/heart_beat 同理。
2. **PPG 双通道取舍**：values[0]/[1] 都记下来，还是只记其一？
   （data_process 里再决定哪个更适合 PyPPG，但落盘阶段先都留）
3. **PyPPG 用法**：版本/调用方式有偏好吗，还是按官方 README 来？
4. **zeroclaw 启动**：main 直接 subprocess 启动二进制即可？
