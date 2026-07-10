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

## 四、关键假设（待确认）

1. **运行环境**：代码在手表 Termux 运行；uv 仅做本地开发/打包
2. **hr.daemon 数据获取**：daemon 自己 spawn `termux-sensor -s <sensor> -n -d <ms>`，按行读 stdout JSON
3. **CSV 路径**：`data/hr.csv`（相对运行目录）；列暂定 `timestamp, heart_rate, ...`
4. **hr.get 注册**：作为 `[project.scripts]` 的 console_script `hr-get`
5. **zeroclaw 启动**：main 直接 subprocess 启动二进制

## 五、❓ 开工前需要你拍板

1. **PPG 数据格式**：termux-sensor 的传感器名 + 真实 JSON 输出样例
   （决定 daemon 解析、CSV 列设计、data_process 用 PyPPG 时的输入信号）
2. **zeroclaw 启动**：daemon 模式命令/参数/环境？`hr.get` 工具如何被 zeroclaw/AI 调用
   （MCP？entry-point 扫描？直接 CLI？）
3. **PyPPG 用法**：版本/调用方式有偏好吗，还是我按官方 README 来？
