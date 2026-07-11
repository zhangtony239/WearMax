#!/data/data/com.termux/files/usr/bin/sh
# WearMax Termux 收尾脚本（二阶段）
# 用法：zeroclaw onboard 完成后执行  ~/finish-setup.sh
# 前置条件：termux-login.sh / SOUL.md / IDENTITY.md
#           skills/get_hr/SKILL.md
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

banner "WearMax Termux 收尾（二阶段）"

# ---------- 1. 预检 /sdcard 下的文件 ----------
banner "步骤 1/4  检查 /sdcard 下的部署文件"
need_file termux-login.sh
need_file SOUL.md
need_file IDENTITY.md
# skills 目录（含 get_hr/SKILL.md，zeroclaw 调用 hr-get 需要它）
if [ -d "$SRC/skills" ]; then
    ok "找到 skills/"
else
    err "缺少 skills/ 目录，zeroclaw 将无法发现 hr-get 工具说明"
    exit 1
fi

# ---------- 2. 挪动文件到对应位置 ----------
banner "步骤 2/4  部署文件"

# termux-login.sh ->  ~/../usr/etc/
ETC="$HOME/../usr/etc"
mkdir -p "$ETC"
cp -f "$SRC/termux-login.sh" "$ETC/termux-login.sh"
chmod +x "$ETC/termux-login.sh"
ok "termux-login.sh   ->  ~/../usr/etc/"

# SOUL.md / IDENTITY.md ->  ~/.zeroclaw/workspace/
WS="$HOME/.zeroclaw/workspace"
mkdir -p "$WS"
cp -f "$SRC/SOUL.md"     "$WS/SOUL.md"
cp -f "$SRC/IDENTITY.md" "$WS/IDENTITY.md"
ok "SOUL.md           ->  ~/.zeroclaw/workspace/"
ok "IDENTITY.md       ->  ~/.zeroclaw/workspace/"

# skills/ ->  ~/.zeroclaw/workspace/skills/  （zeroclaw 据此发现 hr-get 工具说明）
SKILLS_DST="$WS/skills"
mkdir -p "$SKILLS_DST"
cp -rf "$SRC/skills/"* "$SKILLS_DST/" 2>/dev/null || true
ok "skills/get_hr     ->  ~/.zeroclaw/workspace/skills/"

# ---------- 3. 验证 WearMax 命令可用 ----------
banner "步骤 3/4  验证 WearMax 命令"
if command -v hr-get >/dev/null 2>&1; then
    ok "hr-get 命令可用"
else
    err "hr-get 未找到，可能是 setup-wearmax.sh 未执行或 PATH 未生效"
    info "请执行 export PATH=\$HOME/.local/bin:\$PATH 后重开 Termux，再重试 ~/finish-setup.sh"
fi

# ---------- 4. 申请唤醒锁 ----------
banner "步骤 4/4  申请唤醒锁"
if command -v termux-wake-lock >/dev/null 2>&1; then
    termux-wake-lock
    ok "termux-wake-lock 已启用，设备将保持唤醒"
else
    err "termux-wake-lock 不可用，请先执行  pkg install termux-api  后重试"
    exit 1
fi

# ---------- 完成 ----------
banner "收尾完成"

printf "\n\033[1m环境已就绪：\033[0m\n"
printf "   - 登录脚本已就位于 \033[33m~/../usr/etc/termux-login.sh\033[0m\n"
printf "   - SOUL / IDENTITY 已放入 \033[33m~/.zeroclaw/workspace/\033[0m\n"
printf "   - hr-get 工具说明已放入 \033[33m~/.zeroclaw/workspace/skills/get_hr/\033[0m\n"
printf "   - 唤醒锁已开启，如需取消执行：\033[33mtermux-wake-unlock\033[0m\n"
printf "   - 启动 WearMax 全套服务：\033[33mwearmax\033[0m（拉起 zeroclaw/hr-daemon/hr-server）\n\n"

printf "\033[1;36m==========================================\033[0m\n"
