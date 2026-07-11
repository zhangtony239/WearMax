"""pytest 共享配置：把 src/ 加入 sys.path，使测试能 import main / hr 包。

uv run pytest 会自动安装本包（src 布局），但为确保开发期不依赖安装态，
这里显式把 src 挂到路径最前。
"""
import os
import sys

SRC = os.path.join(os.path.dirname(__file__), "src")
if SRC not in sys.path:
    sys.path.insert(0, SRC)
