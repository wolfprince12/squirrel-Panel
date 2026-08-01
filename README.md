<div align="center">

<img src="Resources/AppLogo.png" width="120" alt="Squirrel Panel">

# 鼠须管控制面板 · Squirrel Panel

**Squirrel Panel** —— 一个独立的、第三方的 [鼠须管（Squirrel）](https://github.com/rime/squirrel) macOS 输入法图形设置工具。

> 本项目与鼠须管输入法本体相互独立。安装本 App 后，即可在图形界面里控制自己电脑上的鼠须管，无需手动编辑 YAML；卸载本 App 也不会影响输入法本身。

---

</div>

## 功能

- **🎨 外观**：配色方案、字体、候选窗布局、实时预览。
- **⌨️ 输入方案**：启用/禁用/排序方案、切换快捷键、菜单标题。
- **🖱️ 按键行为**：每页候选数、Caps Lock 行为、各修饰键动作，以及 **Tab / Shift+Tab 翻页**。
- **🪟 应用适配**：按 App 设置 ASCII 模式、内联/非内联、Vim 模式。
- **📚 词库与同步**：用户词库概览、同步目录与 ID、一键同步。
- **🚀 部署与排障**：一键重新部署并回显结果、schema_list 可视化勾选、检测「已启用但不可用」的方案（例如雾凇安装后打不出中文的场景）。
- **📦 第三方词库**：列出所有可安装到鼠须管的第三方词库（首批含「雾凇拼音」「Rime 设置集」）。每次打开面板自动检查更新；已安装的包可手动点击「更新」升级到最新版本，安装/更新都会自动备份被覆盖的文件。
- **🔧 关于与维护**：运行状态、路径跳转、恢复默认、YAML 预览。

所有改动以 Rime 标准的 `*.custom.yaml` 补丁形式写入，不会覆盖你手写的其他配置；应用前会自动生成 `.bak` 备份。

## 下载 / 安装

1. 从 [Releases](https://github.com/wolfprince12/squirrel-Panel/releases) 下载最新 `Squirrel-Panel.dmg`。
2. 打开 DMG，将 `Squirrel Panel.app` 拖入 **应用程序** 文件夹。
3. 首次运行如提示「无法打开」，请前往 **系统设置 → 隐私与安全性** 点击「仍要打开」。

> 使用前请确保你的 Mac 已安装鼠须管输入法（[官方下载](https://rime.im/download/)）。

## 语言

界面跟随系统语言，目前支持简体中文、繁体中文与英文。App 名称也会随系统语言切换：英文系统显示 **Squirrel Panel**，简体中文显示**鼠须管控制面板**，繁体中文显示**鼠鬚管控制面板**。

## 自行构建

需要 macOS 13+、Xcode 15+ / Swift 5.9+。

```bash
git clone https://github.com/wolfprince12/squirrel-Panel.git
cd squirrel-Panel
make release
# 产物：dist/Squirrel Panel.app
```

如果修改过 `Resources/AppLogo.png`，需要先重新生成图标：

```bash
make icons
```

如果终端启用了沙箱导致 SwiftPM 无法执行清单编译：

```bash
make release SWIFT_BUILD="swift build --disable-sandbox"
```

## 它是如何工作的

本 App 不链接 `librime`，也不直接操作输入法进程，而是通过三种官方/安全机制与鼠须管交互：

1. 读写 `~/Library/Rime/*.custom.yaml` 补丁文件。
2. 调用 `Squirrel.app/Contents/MacOS/Squirrel --reload / --sync / --quit` 等命令行接口。
3. 向 `SquirrelReloadNotification` 等分布式通知发送消息，触发输入法重新部署。

因此，即使本控制面板出现 bug，最多只会影响补丁文件；卸载本 App 不会影响鼠须管输入法本身。

## 项目关系

- [rime/squirrel](https://github.com/rime/squirrel) —— 鼠须管输入法本体。
- [wolfprince12/squirrel-Panel](https://github.com/wolfprince12/squirrel-Panel) —— 本控制面板（第三方独立项目）。

## 关于作者

**Mr大狼（Winter Zheng）** —— 二十年影视传媒老兵，做过音乐节、纪录片、综艺导演，作品上过央视春晚、北影节音乐节。八年前独立运营「大狼导演工作室」，近年转型用 AI 把跨界底子焊成产品：爻知云AI 微信服务号、DealV 智能合同平台、鼠须管输入法图形控制台等。

鼠须管是好用的输入法，但改配置要手写 YAML，对普通人门槛太高。做这个面板，就是想把它变得「看得见、点得到」。


## 赞助 · 请杯咖啡

如果这个项目帮到了你，欢迎扫微信二维码请作者一杯咖啡 ☕ —— 所有赞助都会变成更多折腾输入法的时间，继续打磨这个面板。

<img src="./docs/assets/WeChatPay-QRCode.jpg" width="240" alt="微信支付二维码">

也可以留个 Star ⭐，这是对独立开发者最大的鼓励。

## 许可

[GNU General Public License v3.0](./LICENSE)

---

# Squirrel Panel (English)

> This English section is a translation of the Chinese section above. In case of conflict, the Chinese version prevails.

<div align="center">

<img src="Resources/AppLogo.png" width="120" alt="Squirrel Panel">

**Squirrel Panel** — a standalone, third-party graphical settings app for the [Squirrel](https://github.com/rime/squirrel) Rime input method on macOS.

> This project is independent of the Squirrel input method itself. After installing this app, users can control their local Squirrel installation through a GUI, without editing YAML by hand — and uninstalling it won't affect Squirrel.

---

</div>

## Features

- **🎨 Appearance**: color schemes, fonts, candidate window layout, live preview.
- **⌨️ Schemas**: enable/disable/reorder schemes, switch hotkeys, menu title.
- **🖱️ Key behavior**: candidates per page, Caps Lock behavior, modifier-key actions, and **Tab / Shift+Tab paging**.
- **🪟 Per-app**: ASCII mode, inline/non-inline, Vim mode per application.
- **📚 Dictionary & sync**: user dictionary overview, sync dir & ID, one-click sync.
- **🚀 Deploy & diagnose**: one-click redeploy with result log, visual schema_list selection, and detection of enabled-but-unavailable schemas (e.g. rime-ice installed but cannot type Chinese).
- **📦 Dictionary packages**: curated third-party packages including **Rime Ice (rime-ice)** and **Rime Settings Set**, with automatic update checks, one-click install/update/uninstall, and automatic backup/restore of overwritten files.
- **🔧 About & maintenance**: running status, path jump, restore defaults, YAML preview.

All changes are written as Rime-standard `*.custom.yaml` patches — they never overwrite your other hand-written config, and a `.bak` backup is created automatically before applying.

## Install

1. Download the latest `Squirrel-Panel.dmg` from [Releases](https://github.com/wolfprince12/squirrel-Panel/releases).
2. Open the DMG and drag `Squirrel Panel.app` into **Applications**. The app name follows your system language: **Squirrel Panel** (English), **鼠须管控制面板** (Simplified Chinese), or **鼠鬚管控制面板** (Traditional Chinese).
3. If the first launch says "cannot be opened", go to **System Settings → Privacy & Security** and click "Open Anyway".

> Make sure the Squirrel input method is installed on your Mac ([official download](https://rime.im/download/)).

## How it works

This app does not link `librime` nor directly manipulate the input method process. It interacts with Squirrel through three official/safe mechanisms:

1. Reading and writing `~/Library/Rime/*.custom.yaml` patch files.
2. Invoking the `Squirrel.app/Contents/MacOS/Squirrel --reload / --sync / --quit` command-line interface.
3. Sending distributed notifications such as `SquirrelReloadNotification` to trigger redeploy.

So even if this panel has a bug, at worst it only affects the patch files; uninstalling it won't affect the Squirrel input method itself.

## About the Author

**Mr大狼 (Winter Zheng)** — 20+ years in film, TV and live production; runs "Big Wolf Director Studio" independently; now rebuilding cross-domain experience into AI products: 爻知云AI WeChat Official Account, DealV smart contract platform, Squirrel Panel (input-method GUI), and more.

Squirrel is a great input method, but configuring it means hand-editing YAML — too high a bar for most people. This panel exists to make it visible and clickable.


## Sponsor · Buy Me a Coffee

If this project helped you, feel free to buy me a coffee via WeChat Pay ☕

<img src="./docs/assets/WeChatPay-QRCode.jpg" width="240" alt="WeChat Pay QR Code">

## License

[GNU General Public License v3.0](./LICENSE)
