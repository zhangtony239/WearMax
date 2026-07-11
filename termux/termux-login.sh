#!/bin/sh

echo "提示：按 [回车键] 进入普通命令行，否则 1 秒后自动启动 WearMax..."

# 保存当前的终端设置
OLD_STTY=$(stty -g)

# 设置终端为：10分之10秒（即1秒）超时，且不需要攒满一行，输入1个字符就响应
stty raw -echo min 0 time 10

# 读取一个字符（由于上面设置了 raw，按回车、空格或任何键都会立刻触发）
CHAR=$(dd bs=1 count=1 2>/dev/null)

# 恢复原本的终端设置
stty "$OLD_STTY"

# 判断用户是否按下了键
# 如果 CHAR 不为空，说明在 1 秒内按了键
if [ -n "$CHAR" ]; then
    echo "\r\n已检测到按键，正在进入 Bash..."
    exec bash
else
    echo "\r\n超时未响应，正在启动 WearMax（zeroclaw + hr-daemon + hr-server）..."
    # wearmax（main.py）会拉起 zeroclaw daemon + hr-daemon + hr-server 三进程
    exec wearmax
fi