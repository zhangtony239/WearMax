"""WearMax 总起进程 — 拉起三大常驻服务并统一管理生命周期。

拉起的三个进程：
    1. zeroclaw daemon  —— AI 大脑（外部二进制，`~/zeroclaw daemon`）
    2. hr.daemon        —— 传感器采集落盘（本包）
    3. hr.server        —— Streamlit 仪表盘（本包，本期 stub）

设计要点：
    - 任一进程意外退出 → 视为整体故障，主动终止其余进程后退出（fail-fast，
      让外层看门狗/登录脚本重启，避免半残状态）。
    - 收到 SIGINT/SIGTERM → 优雅终止三个子进程。
    - 子进程 stdout/stderr 透传到本进程控制台，带前缀区分来源。
    - 用 sys.executable -m 调起本包模块，不依赖 console script 是否安装；
      zeroclaw 为外部二进制，路径可由环境变量 WEARMAX_ZEROCLAW 覆盖。

CLI:
    wearmax          # 拉起三进程，常驻
    python -m main   # 等价入口
"""
from __future__ import annotations

import logging
import os
import signal
import subprocess
import sys
import threading
from dataclasses import dataclass, field

log = logging.getLogger("wearmax")

# zeroclaw 二进制路径：手表上默认 ~/zeroclaw，可由环境变量覆盖
ZEROCLAW_BIN = os.environ.get("WEARMAX_ZEROCLAW", os.path.expanduser("~/zeroclaw"))
# 子进程退出后，主进程等待清理的宽限时间
SHUTDOWN_GRACE = 3.0


@dataclass
class ManagedProc:
    """一个被管理的常驻子进程。"""
    name: str
    cmd: list[str]
    proc: subprocess.Popen | None = None
    env: dict[str, str] | None = None

    def start(self) -> None:
        self.proc = subprocess.Popen(
            self.cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,   # 合并到 stdout 便于加前缀
            text=True,
            bufsize=1,
            env=self.env,
        )
        log.info("[%s] 已启动 (pid=%s): %s", self.name, self.proc.pid, " ".join(self.cmd))

    def forward_output(self, stop: threading.Event) -> None:
        """把子进程输出加 [name] 前缀透传到控制台。"""
        p = self.proc
        if p is None or p.stdout is None:
            return
        try:
            for line in iter(p.stdout.readline, ""):
                if stop.is_set():
                    break
                sys.stdout.write(f"[{self.name}] {line}")
                sys.stdout.flush()
        except Exception as e:
            log.warning("[%s] 输出转发异常: %s", self.name, e)

    def stop(self) -> None:
        p = self.proc
        if p is None or p.poll() is not None:
            return
        log.info("[%s] 终止中…", self.name)
        try:
            p.terminate()
        except Exception:
            pass
        try:
            p.wait(timeout=SHUTDOWN_GRACE)
        except Exception:
            try:
                p.kill()
            except Exception:
                pass

    def poll(self) -> int | None:
        return self.proc.poll() if self.proc else None


def build_procs() -> list[ManagedProc]:
    """构造三个被管理进程的命令。"""
    py = sys.executable or "python3"
    procs: list[ManagedProc] = [
        ManagedProc(
            name="zeroclaw",
            cmd=[ZEROCLAW_BIN, "daemon"],
        ),
        ManagedProc(
            name="hr-daemon",
            cmd=[py, "-m", "hr.daemon"],
        ),
        ManagedProc(
            name="hr-server",
            # server.main() 内部会 spawn `streamlit run`
            cmd=[py, "-m", "hr.server"],
        ),
    ]
    return procs


def run() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )
    if not os.path.exists(ZEROCLAW_BIN):
        log.warning("zeroclaw 二进制不存在: %s（该子进程会失败，但仍拉起其余服务）", ZEROCLAW_BIN)

    procs = build_procs()
    stop_evt = threading.Event()

    def _shutdown(signum=None, frame=None) -> None:
        if stop_evt.is_set():
            return
        log.info("收到信号 %s，开始优雅停止…", signum)
        stop_evt.set()

    signal.signal(signal.SIGINT, _shutdown)
    signal.signal(signal.SIGTERM, _shutdown)

    # 启动 + 输出转发
    for p in procs:
        try:
            p.start()
        except FileNotFoundError as e:
            log.error("[%s] 启动失败: %s", p.name, e)
            p.proc = None
        threading.Thread(
            target=p.forward_output, args=(stop_evt,), daemon=True
        ).start()

    # 监视循环：任一进程退出即整体停止（fail-fast）
    watcher_stop = threading.Event()

    def watcher() -> None:
        while not watcher_stop.wait(1.0):
            for p in procs:
                rc = p.poll()
                if rc is not None and not stop_evt.is_set():
                    log.error("[%s] 已退出 (rc=%s)，触发整体停止", p.name, rc)
                    stop_evt.set()
                    return

    threading.Thread(target=watcher, daemon=True).start()

    stop_evt.wait()
    watcher_stop.set()

    # 清理：逆序停止，给足宽限
    for p in reversed(procs):
        p.stop()

    log.info("WearMax 已全部停止")
    return 0


def main() -> None:
    sys.exit(run())


if __name__ == "__main__":
    main()
