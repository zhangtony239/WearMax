"""WearMax 心率（hr）子包。

模块职责：
- `daemon`   : 常驻进程，监听 termux-sensor 的 PPG/IMU 推流，落盘 CSV
- `data_process` : 共享数据处理（PyPPG），供 server 与 get 复用
- `get`      : 工具，读 CSV 直接返回 JSON 给 AI（CLI console_script）
- `server`   : Streamlit 仪表盘（本期 stub）
"""

__all__ = ["daemon", "data_process", "get", "server"]
