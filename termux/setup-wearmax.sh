#!/data/data/com.termux/files/usr/bin/sh
# WearMax Termux 环境初始化脚本
# 用法：在 Termux 内执行  sh setup-wearmax.sh
# 前置条件：termux.properties / zeroclaw / finish-setup.sh
#           wearmax-*.whl / sensor_test.py / skills/
#           已通过 adb push 放到 /sdcard/ 下
# 安装方式：pkg install uv → uv tool install wearmax-*.whl（不依赖 pipx）

set -e

SRC=/sdcard

# ---------- 工具函数 ----------
ok()    { printf "  [\033[32m✓\033[0m] %s\n" "$1"; }
info()  { printf "  [\033[36m·\033[0m] %s\n" "$1"; }
err()   { printf "  [\033[31m✗\033[0m] %s\n" "$1"; }

need_file() {
    # 检查 /sdcard/ 下是否存在某个文件，不存在则报错退出
    f="$SRC/$1"
    if [ -f "$f" ]; then
        ok "找到 $1"
    else
        err "缺少 $f，请先用 adb push 推送到 /sdcard/ 后重试"
        exit 1
    fi
}

banner() {
    printf "\n\033[1;36m==========================================\033[0m\n"
    printf "\033[1;36m  %s\033[0m\n" "$1"
    printf "\033[1;36m==========================================\033[0m\n"
}

banner "WearMax Termux 环境初始化"

# ---------- 1. 预检 /sdcard 下的文件 ----------
banner "步骤 1/6  检查 /sdcard 下的部署文件"
need_file termux.properties
need_file zeroclaw
need_file finish-setup.sh
need_file sensor_test.py
# 预检 whl（文件名含版本号，用通配匹配）
whl=$(ls "$SRC"/wearmax-*.whl 2>/dev/null | head -1)
if [ -n "$whl" ]; then
    ok "找到 $(basename "$whl")"
else
    err "缺少 wearmax-*.whl，请先在开发机执行 uv build --wheel --out-dir termux 后重新 adb push"
    exit 1
fi

# ---------- 2. 更新 & 升级 ----------
banner "步骤 2/6  更新软件包列表并升级系统"
pkg update -y
info "更新索引完成，开始升级（对配置文件提示一律选 Y）"
yes Y | pkg upgrade -y
ok "升级完成"

# ---------- 3. 安装 tur-repo / termux-api / Python 环境 ----------
banner "步骤 3/6  安装 tur-repo / termux-api / Python 环境"
pkg install -y tur-repo termux-api
pkg update -y
pkg install -y python3.11 python-is-python3.11
ok "tur-repo / termux-api / Python 3.11 安装完成"

# ---------- 4. uv 安装 WearMax 包 ----------
banner "步骤 4/6  uv 安装 WearMax（whl + 依赖）"
# Termux 官方源提供 uv（有预编译 arm 二进制），无需 pipx
pkg install -y uv
info "uv 安装 WearMax whl 及其依赖（numpy/scipy/pandas/pyPPG 等，首次较慢）"
# uv tool install 把 whl 装进隔离环境，自动暴露 console_scripts（hr-get 等）
# 首次需 --force：若已装过旧版则覆盖
uv tool install --force "$whl"
ok "WearMax 已安装，可用命令：hr-get / hr-daemon / hr-server / wearmax"
# uv tool 的 bin 目录默认 ~/.local/bin，确保在 PATH 中
UV_BIN="$HOME/.local/bin"
case ":$PATH:" in
    *":$UV_BIN:"*) ;;
    *) info "将 $UV_BIN 加入 PATH（~/.bashrc）"
       echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> ~/.bashrc
       export PATH="$UV_BIN:$PATH" ;;
esac
# 验证 console script 可用
if command -v hr-get >/dev/null 2>&1; then
    ok "hr-get 命令验证通过"
else
    err "hr-get 未找到，请执行 export PATH=\$HOME/.local/bin:\$PATH 后重试，或重开 Termux"
fi
# sensor_test.py 是纯标准库脚本，直接放到 ~/
cp -f "$SRC/sensor_test.py" ~/sensor_test.py
ok "sensor_test.py      ->  ~/"

# ---------- 5. 复制配置文件到对应位置 ----------
banner "步骤 5/6  部署配置文件"

# termux.properties ->  ~/.termux/
mkdir -p ~/.termux
cp -f "$SRC/termux.properties" ~/.termux/termux.properties
ok "termux.properties   ->  ~/.termux/"

# zeroclaw / finish-setup.sh ->  ~/
cp -f "$SRC/zeroclaw"        ~/zeroclaw
cp -f "$SRC/finish-setup.sh" ~/finish-setup.sh
ok "zeroclaw            ->  ~/"
ok "finish-setup.sh     ->  ~/"

# ---------- 6. 赋予执行权限 & 重载设置 ----------
banner "步骤 6/6  赋予执行权限并重载设置"
chmod +x ~/zeroclaw
chmod +x ~/finish-setup.sh
ok "zeroclaw / finish-setup.sh 已可执行"

termux-reload-settings 2>/dev/null || info "termux-reload-settings 不可用，可稍后手动执行"
ok "设置已重载"

# ---------- 完成，告知用户后续操作 ----------
banner "初始化完成，请按以下步骤继续"

printf "\n\033[1m1. 完成 zeroclaw onboard\033[0m\n"
printf "   运行：\033[33m~/zeroclaw\033[0m\n"
printf "   随界面引导完成 onboarding 流程。\n\n"

printf "\033[1m2. 长文本输入技巧\033[0m\n"
printf "   手表上输入长文本不便时，可用 adb 远程输入：\n"
printf '   \033[33madb shell input text "your_text"\033[0m\n'
printf '   注：空格需用 \033[33m%%s\033[0m 转义，例如 \033[33madb shell input text "hello%%sworld"\033[0m 将输入 hello world\n\n'

printf "\033[1m3. 完成后收尾\033[0m\n"
printf "   onboard 走完后，执行：\033[33m~/finish-setup.sh\033[0m\n"
printf "   它会部署 hr-get 工具说明并验证 WearMax 命令。\n\n"

printf "\033[1m4. 日常运行\033[0m\n"
printf "   本步骤已用 uv tool install 安装 WearMax whl（hr-get / hr-daemon / hr-server / wearmax）。\n"
printf "   收尾完成后，每次 Termux 登录超时会自动启动 \033[33mwearmax\033[0m，\n"
printf "   由它拉起 zeroclaw daemon + hr-daemon + hr-server 三进程。\n\n"

printf "\033[1;36m==========================================\033[0m\n"
