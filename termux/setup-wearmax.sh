#!/data/data/com.termux/files/usr/bin/sh
# WearMax Termux 环境初始化脚本
# 用法：在 Termux 内执行  sh setup-wearmax.sh
# 前置条件：termux.properties / zeroclaw / finish-setup.sh
#           已通过 adb push 放到 /sdcard/ 下

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

# ---------- 0. 预检 /sdcard 下的文件 ----------
banner "步骤 0/4  检查 /sdcard 下的部署文件"
need_file termux.properties
need_file zeroclaw
need_file finish-setup.sh

# ---------- 1. 换阿里云源（http） ----------
banner "步骤 1/4  切换 Termux 软件源为阿里云镜像"
SRC_LIST="$PREFIX/etc/apt/sources.list"
if grep -q "mirrors.aliyun.com" "$SRC_LIST" 2>/dev/null; then
    info "已是阿里云源，跳过"
else
    # 把原有 stable 源注释掉，并追加阿里云源（http，兼容旧版 Termux）
    sed -i 's@^\(deb.*stable main\)$@#\1\ndeb http://mirrors.aliyun.com/termux/termux-packages-24 stable main@' "$SRC_LIST"
    ok "已写入阿里云源"
fi

# ---------- 2. 更新 & 升级 ----------
banner "步骤 2/4  更新软件包列表并升级系统"
pkg update -y
info "更新索引完成，开始升级（对配置文件提示一律选 Y）"
yes Y | pkg upgrade -y
ok "升级完成"

# ---------- 3. 复制配置文件到对应位置 ----------
banner "步骤 3/4  部署配置文件"

# termux.properties ->  ~/.termux/
mkdir -p ~/.termux
cp -f "$SRC/termux.properties" ~/.termux/termux.properties
ok "termux.properties   ->  ~/.termux/"

# zeroclaw / finish-setup.sh ->  ~/
cp -f "$SRC/zeroclaw"        ~/zeroclaw
cp -f "$SRC/finish-setup.sh" ~/finish-setup.sh
ok "zeroclaw            ->  ~/"
ok "finish-setup.sh     ->  ~/"

# ---------- 4. 赋予执行权限 & 重载设置 ----------
banner "步骤 4/4  赋予执行权限并重载设置"
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
printf "   onboard 走完后，执行：\033[33m~/finish-setup.sh\033[0m\n\n"

printf "\033[1;36m==========================================\033[0m\n"
