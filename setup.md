# WearMax 安装指南

安装分四个阶段，前一个在电脑上完成，后三个在手表上完成：

| 阶段 | 在哪做 | 做什么 | 谁来做 |
|------|--------|--------|--------|
| ① 电脑侧部署 | Windows 电脑 | 下载资源 + adb 推送到手表 | [`install.ps1`](install.ps1) |
| ② Termux 初始化 | 手表 Termux | 升级系统、装依赖、就位文件 | [`setup-wearmax.sh`](termux/setup-wearmax.sh) |
| ③ zeroclaw 引导 | 手表 Termux | 走 onboarding、填 API Key 等 | 你手动交互 |
| ④ 收尾部署 | 手表 Termux | 就位登录脚本/人格文件、配置后台保活 | [`finish-setup.sh`](termux/finish-setup.sh) |

> 💡 每个脚本都会在屏幕上打印彩色进度（`✓` 成功 / `·` 进行中 / `✗` 失败），跟着提示走即可。遇到 `✗` 先看报错，多数是文件没推到位或设备没连好。

---

## 前置条件

**电脑侧（Windows）**

- Windows 10（1803+）或 Windows 11（自带 `tar.exe`，用于解压）
- PowerShell 5.1+
- 已安装 ADB 并加入 PATH（`adb` 可在命令行直接调用）
- 手表已通过 USB 连接，并开启「开发者选项 → USB 调试」

**手表侧**

- 已通过阶段①安装好 Termux 应用
- 能连 Wi-Fi（首次 `pkg update` 需要联网）

---

## 阶段 ① 电脑侧部署（[`install.ps1`](install.ps1)）

在 Windows 电脑上打开 **PowerShell**，进入项目根目录，执行：

```powershell
.\install.ps1
```

这个脚本会自动完成两件事：

**阶段一 · 资源准备**
- 通过 GitHub Releases API 动态解析最新版本（不硬编码版本号）
- 下载 `zeroclaw`（armv7 二进制 tar.gz）、`termux-app`（APK）、`termux-api`（APK）
- 解压 `zeroclaw` 并只保留二进制本体，删掉压缩包

**阶段二 · adb 部署到手表**
- 启动 adb server，检测已连接的设备
- 安装两个 Termux APK（先 termux-app，后 termux-api）
- 把 `zeroclaw` 二进制推送到手表 `/sdcard/`
- 把项目 `termux/` 目录下全部内容（配置、脚本、人格文件）推送到手表 `/sdcard/`
- 清理本地缓存目录 `.install/`

脚本跑完会提示「下一步请在手表上完成」。此时所有原料都已就位在手表的 `/sdcard/` 下。

> ⚠️ 如果报「未检测到就绪的 Android 设备」，检查：① 手表是否已授权此电脑（留意手表屏幕弹出的 USB 调试授权框）；② 是否开启了 USB 调试。

---

## 阶段 ② Termux 初始化（[`setup-wearmax.sh`](termux/setup-wearmax.sh))

拔下手表，在手表上打开 **Termux** 应用，依次执行下面两条命令。

### 2.1 授权存储访问

```sh
termux-setup-storage
```

这会弹出手表系统的存储权限请求，**允许**它。授权后 Termux 会在家目录下创建 `storage/` 符号链接，其中 `storage/shared` 指向 `/sdcard`——下一步脚本就靠它读到阶段①推送过来的文件。

### 2.2 运行初始化脚本

```sh
sh storage/shared/setup-wearmax.sh
```

脚本会自动完成 5 步：

1. **预检**：确认 `/sdcard/` 下的 `termux.properties`、`zeroclaw`、`finish-setup.sh` 都在
2. **更新升级**：`pkg update` + `pkg upgrade`（配置文件提示一律选 Y）
3. **安装依赖**：`tur-repo`、`termux-api`、`python3.11`、`python-is-python3.11`
4. **就位文件**：
   - `termux.properties` → `~/.termux/`（Termux 行为配置：隐藏软键盘、竖线光标、黑色主题、快捷键 STOP/ENTER）
   - `zeroclaw`、`finish-setup.sh` → `~/`
5. **赋权 + 重载**：给二进制加可执行权限，执行 `termux-reload-settings` 让配置生效

跑完会打印后续操作指引。到这里手表环境已经就绪，进入下一步手动引导。

---

## 阶段 ③ zeroclaw 引导（手动交互）

```sh
~/zeroclaw onboard
```

这会启动 zeroclaw 的 onboarding 向导，跟着屏幕提示一步步完成（绑定账号、填 API Key 等）。

> 🔑 **手表上输入长文本的技巧**
>
> 手表屏幕小、键盘输入慢，这里有两个办法：
>
> - **日常键盘输入**：用 `scrcpy --otg` 把电脑键盘映射成手表的 USB 输入设备，逐字符输入比较顺手。
> - **灌入长字段（如 API Key）**：逐字符输入太慢，临时**关掉 scrcpy**，改用 adb 一次性灌入：
>   ```sh
>   adb shell input text "your_key"
>   ```
>   注意空格要用 `%s` 转义，例如 `adb shell input text "hello%sworld"` 会输入 `hello world`。
>
> 也就是说：能用 `scrcpy --otg` 就用着，遇到长字符串就切 `adb shell input text` 灌进去，灌完再切回 scrcpy。

---

## 阶段 ④ 收尾部署（[`finish-setup.sh`](termux/finish-setup.sh)）

zeroclaw onboard 走完后，回 Termux 执行：

```sh
~/finish-setup.sh
```

它会完成 3 步：

1. **预检**：确认 `/sdcard/` 下的 `termux-login.sh`、`SOUL.md`、`IDENTITY.md` 都在
2. **就位文件**：
   - [`termux-login.sh`](termux/termux-login.sh) → `~/../usr/etc/`（作为 Termux 启动登录脚本）
   - [`SOUL.md`](termux/SOUL.md)、[`IDENTITY.md`](termux/IDENTITY.md) → `~/.zeroclaw/workspace/`（AI 的人格与身份定义）
3. **启用后台保活**：执行 `termux-wake-lock`，让设备保持唤醒，避免休眠后守护进程被杀

跑完打印「收尾完成」，整个安装就结束了。

---

## 安装后：日常使用

安装完成后，每次在手表上打开 Termux，[`termux-login.sh`](termux/termux-login.sh) 会给你 **1 秒** 的选择窗口：

- **不按任何键**（1 秒超时）→ 自动启动 `~/zeroclaw daemon` 守护进程，手表进入 AI 终端模式
- **按下回车**（或任意键）→ 进入普通 Bash 命令行，方便临时调试

这样日常一开表就是 AI，想捣鼓命令行时按一下回车即可。

> 如果某天想关掉唤醒锁（比如要省电），执行 `termux-wake-unlock` 即可。

---

## 速查：全部命令

```sh
# —— 阶段① 在 Windows 电脑 PowerShell 里 ——
.\install.ps1

# —— 以下在手表 Termux 里 ——
termux-setup-storage
sh storage/shared/setup-wearmax.sh
~/zeroclaw onboard          # 手动走引导，长文本用 adb shell input text
~/finish-setup.sh
```

就这五行命令，WearMax安装完成。
