"""WearMax hr.server — Streamlit 仪表盘（本期 stub）。

职责：
    读取 hr.daemon 落盘的 CSV，可视化展示 PPG/IMU/心率等数据。
    本期为占位 stub，后续迭代再开发完整图表。

运行方式：
    python -m hr.server   # main() 会 spawn `streamlit run __file__`
    streamlit run hr/server.py
"""
from __future__ import annotations

import os
import subprocess
import sys

# 运行数据目录（与 hr.daemon 一致）
DATA_DIR = os.environ.get("WEARMAX_DATA_DIR", "data")
CSV_PATH = os.path.join(DATA_DIR, "hr.csv")


def render() -> None:
    """Streamlit 渲染入口（被 `streamlit run` 时执行）。

    本期为 stub：只做最小展示，确认数据链路通即可。
    真正的图表在后续迭代补上（届时 data_process 提供处理后的指标）。
    """
    # 延迟导入：直接 python 运行本文件时 streamlit 不渲染，避免报错
    import streamlit as st

    st.set_page_config(page_title="WearMax", page_icon="🩺", layout="wide")
    st.title("WearMax 健康仪表盘")
    st.caption("本期为占位版本，完整图表开发中。")

    st.subheader("原始数据预览")
    if not os.path.exists(CSV_PATH):
        st.warning(f"暂无数据文件：{CSV_PATH}\n请确认 hr.daemon 已运行。")
        return
    try:
        import pandas as pd

        df = pd.read_csv(CSV_PATH)
        st.write(f"共 {len(df)} 行，列：{', '.join(df.columns)}")
        st.dataframe(df.tail(200), use_container_width=True)
    except Exception as e:
        st.error(f"读取数据失败：{e}")


def main() -> None:
    """console_script / `python -m hr.server` 入口：spawn streamlit run。

    Streamlit 必须由 `streamlit run` 调起脚本，不能直接执行 main()，
    因此这里用子进程包装，使 main.py 可统一用 `python -m` 拉起三个服务。
    """
    script = os.path.abspath(__file__)
    py = sys.executable or "python3"
    try:
        subprocess.run([py, "-m", "streamlit", "run", script], check=False)
    except FileNotFoundError:
        print("[hr.server] 未找到 streamlit，请先安装（uv sync）", file=sys.stderr)
        sys.exit(1)


# 被 `streamlit run` 执行时直接落到这里
if __name__ == "__main__":
    render()
