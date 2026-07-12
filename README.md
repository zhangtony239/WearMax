# ⌚ WearMax

English | [简体中文](README_zh.md)

> Turn a dusty armv7 WearOS watch into a "wrist-worn electronic badge" that runs an AI Agent and can sense your heartbeat.

WearMax is a full-stack deployment template for **armv7-architecture WearOS watches**. It spins up Termux + ZeroClaw Agent on a slimmed-down system and leaves interfaces for reading biometric data from the watch's heart-rate sensor / accelerometer / gyroscope — taking the first step toward **BayMax** from *Big Hero 6*.

> 📖 For detailed, staged installation instructions see [`setup.md`](setup.md).

## ✨ What It Can Do

WearMax organizes its scripts in a `folder/device-codename.ps1` structure — the idea being to **cover the entire armv7 WearOS ecosystem**, not just one specific watch. Currently, the Xiaomi Watch 1st Gen (codename **baiji**) serves as the first adapted implementation:

### [`init_env/baiji.ps1`](init_env/baiji.ps1) — Environment Initialization

- Solves the problem that the watch **must be paired with a phone to be usable**.
- Slims down a large amount of pre-installed system software (using `pm uninstall --user 0`, which does not affect other users).
- Disables NFC / mobile data / location, enables airplane mode, and turns off the screensaver — turning the watch into a pure Linux terminal.

### [`update_watchface/baiji.ps1`](update_watchface/baiji.ps1) — Photo Watch Face Update

- Solves the problem that the photo watch face **requires an app to change its background**.
- Automatically reads the screen resolution, validates the image dimensions, and pushes a new watch face via adb with a single click.

### [`install.ps1`](install.ps1) — One-Click Deployment

- **Dynamically resolves** the latest version via the GitHub Releases API (no hardcoded version numbers), downloading `zeroclaw` (armv7 binary), `termux-app`, and `termux-api`.
- Installs the Termux APK onto the watch via adb, pushes zeroclaw and all configurations under [`termux/`](termux/) to `/sdcard/`, and finally cleans up the local cache.

### `termux/` — Watch-Side Initialization & Daemon

| File | Purpose |
|------|---------|
| [`setup-wearmax.sh`](termux/setup-wearmax.sh) | Upgrades the system, installs tur-repo / termux-api / Python 3.11, and places the configuration files |
| [`finish-setup.sh`](termux/finish-setup.sh) | Places the login script and AI persona file, enables `termux-wake-lock` for background keep-alive |
| [`termux-login.sh`](termux/termux-login.sh) | AI on boot: auto-starts `zeroclaw daemon` with a 1-second timeout; press Enter for a normal Bash shell |
| [`termux.properties`](termux/termux.properties) | Hides the soft keyboard, sets the line cursor, and configures STOP / ENTER shortcuts |
| [`SOUL.md`](termux/SOUL.md) | The AI's "soul" — a BayMax-style, round-the-clock health guardian persona definition |
| [`IDENTITY.md`](termux/IDENTITY.md) | The AI's identity template, left for the user to fill in during the first conversation |

---

## 🚀 Installation

For the full, staged installation guide (prerequisites, PC-side deployment, Termux initialization, ZeroClaw bootstrap, and final keep-alive setup), see 👉 [`setup.md`](setup.md).

> 💡 If your watch is still in its factory-fresh state (stuck on forced pairing), run [`init_env/baiji.ps1`](init_env/baiji.ps1) first to remove the pairing constraint and slim down the system. It will ask whether to proceed with installing WearMax.

---

## 💗 Why "BayMax": The Heart-Rate Sensor

Dig into the code details and you'll find things aren't that simple — why does the title reference BayMax from *Big Hero 6*? What's the irreplaceable advantage of running an Agent on a watch?

The answer lies in the **heart-rate sensor** on the back of the watch. Testing has confirmed that this watch's core **PPG sensor (heart rate), accelerometer, gyroscope, etc. can all be read via `termux-api`**. This is a rare opportunity to let your favorite Agent access real biometric data — without enduring the vendor's not-yet-fully-open sports & health API and its potential restrictions.

In theory, by implementing your own data algorithms, you can achieve far more than just heart rate: features like ECG and medical-parameter metrics that only arrived on later watches might be within reach...

### ⚠️ NEED HELP

My personal tech stack is honestly quite limited: my primary language is only Python, and I haven't gotten into Rust yet. Given the watch's memory- and compute-constrained scenario... is there a kind-hearted Rust dev who could lend a hand qwq? A half-finished Python implementation is available on the [dev branch](https://github.com/zhangtony239/WearMax/tree/dev) — those interested can take a look.

> If any medical-major students want to develop this into a research project, feel free to [DM me](mailto:zt239@outlook.com)!

## ⚠️ Disclaimer

> We currently lack the manpower and financial resources to pursue any medical certification! The project currently **does not have medical validity**! <br />
> If any of you friends feel unwell, please **see a doctor promptly and follow medical advice**!
