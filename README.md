# ⌚ WearMax

> 把吃灰的 armv7 WearOS 手表，变成一块能跑 AI Agent、能感知你心跳的「腕上电子吧唧」。

WearMax 是一套面向 **armv7 架构 WearOS 手表** 的全栈部署模板。它在精简后的系统上跑起 Termux + ZeroClaw Agent，并预留了读取手表心率/加速度/陀螺仪等生物数据的接口——朝着《超能陆战队》里 **大白（BayMax）** 的方向迈出第一步。

> 📖 详细的分阶段安装指引见 [`setup.md`](setup.md)。

## ✨ 它能做什么

WearMax 采用 `文件夹/设备代号.ps1` 的结构组织脚本——这样做的初衷是**让项目可以照顾到整个 armv7 WearOS 生态**，而不只是某一台手表。目前以小米手表一代（代号 **baiji**）作为首个适配实现：

### [`init_env/baiji.ps1`](init_env/baiji.ps1) — 环境初始化

- 解决了手表**必须匹配手机才能使用**的问题。
- 精简大量系统预装软件（采用 `pm uninstall --user 0`，不影响其它用户）。
- 关闭 NFC / 移动数据 / 定位，开启飞行模式、关闭屏保，让手表变成一块纯净的 Linux 终端。

### [`update_watchface/baiji.ps1`](update_watchface/baiji.ps1) — 相册表盘更新

- 解决了相册表盘**必须用 APP 更换背景**的问题。
- 自动读取屏幕分辨率，校验图片尺寸，通过 adb 一键推送新表盘。

### [`install.ps1`](install.ps1) — 一键部署

- 通过 GitHub Releases API **动态解析**最新版本（不硬编码版本号），下载 `zeroclaw`（armv7 二进制）、`termux-app`、`termux-api`。
- 通过 adb 把 Termux APK 安装到手表、把 zeroclaw 与 [`termux/`](termux/) 下的全部配置推送到 `/sdcard/`，最后清理本地缓存。

### `termux/` — 手表侧的初始化与守护

| 文件 | 作用 |
|------|------|
| [`setup-wearmax.sh`](termux/setup-wearmax.sh) | 升级系统、安装 tur-repo / termux-api / Python 3.11，就位配置文件 |
| [`finish-setup.sh`](termux/finish-setup.sh) | 就位登录脚本与 AI 人格文件，启用 `termux-wake-lock` 后台保活 |
| [`termux-login.sh`](termux/termux-login.sh) | 开表即 AI：1 秒超时自动启动 `zeroclaw daemon`，按回车进入普通 Bash |
| [`termux.properties`](termux/termux.properties) | 隐藏软键盘、竖线光标、配置 STOP / ENTER 快捷键 |
| [`SOUL.md`](termux/SOUL.md) | AI 的「灵魂」——大白式全天候健康守护人格定义 |
| [`IDENTITY.md`](termux/IDENTITY.md) | AI 的身份模板，留给用户在首次对话中填写 |

---

## 🚀 安装

完整的分阶段安装指引（前置条件、电脑侧部署、Termux 初始化、ZeroClaw 引导、收尾保活）见 👉 [`setup.md`](setup.md)。

> 💡 如果手表还是全新出厂状态（被强制配对卡住），先跑 [`init_env/baiji.ps1`](init_env/baiji.ps1) 解除配对约束、精简系统，它会询问是否继续安装 WearMax。

---

## 💗 为什么是「大白」：心率传感器

翻开代码细节你会发现事情没那么简单——为什么标题里谈到《超能陆战队》里的大白？手表跑 Agent 有什么不可替代的优势？

答案在手表背后的**心率传感器**上。这块表的传感器经实测，其核心的 **PPG 传感器（心率）、加速度计、陀螺仪等均可通过 `termux-api` 读取**。这大概是十分罕见的一次，能让你心仪的 Agent 接触到真实生物数据的机会——还不需要忍受厂商那尚未完全对外开放的运动健康 API 和潜在限制。

理论上，自己实现数据算法，可以做到不止是官方只出的心率：后期手表才有的心电图、医疗参数指标没准也能搞出来……

### ⚠️ NEED HELP

我个人的技术栈实在有限：主力语言只修了 Python，Rust 尚未入门。考虑到手表这个内存与算力受限的场景…有没有好心的rust佬救一下qwq。半成品的 Python 实现已放在 [dev 分支](https://github.com/zhangtony239/WearMax/tree/dev)，感兴趣的可以去看看。

> 若有医学专业的同学打算把这个发展成课题，欢迎[私信我](mailto:zt239@outlook.com)！

## ⚠️ 免责声明

> 我们暂无人力财力去考虑任何的医疗资质认证！项目当前也**不具备医疗效力**！<br />
> 若各位佬友有任何不适，请**及时就诊，谨遵医嘱**！
