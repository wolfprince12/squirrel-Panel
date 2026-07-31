# 鼠须管控制面板 · Squirrel Panel

一个独立的、第三方的 [鼠须管（Squirrel）](https://github.com/rime/squirrel) macOS 输入法图形设置工具。

> 本项目与鼠须管输入法本体相互独立。用户安装本 App 后，即可在图形界面里控制自己电脑上的鼠须管输入法，无需手动编辑 YAML。

---

## 功能

- **外观**：配色方案、字体、候选窗布局、实时预览。
- **输入方案**：启用/禁用/排序方案、切换快捷键、菜单标题。
- **按键行为**：每页候选数、Caps Lock 行为、各修饰键动作。
- **应用适配**：按 App 设置 ASCII 模式、内联/非内联、Vim 模式。
- **词库与同步**：用户词库概览、同步目录与 ID、一键同步/部署。
- **关于与维护**：运行状态、路径跳转、恢复默认、YAML 预览。

所有改动以 Rime 标准的 `*.custom.yaml` 补丁形式写入，不会覆盖你手写的其他配置；应用前会自动生成 `.bak` 备份。

---

## 下载 / 安装

1. 从 [Releases](https://github.com/wolfprince12/squirrel-Panel/releases) 下载最新 `Squirrel-Panel.dmg`。
2. 打开 DMG，将 `Squirrel Panel.app` 拖入 **应用程序** 文件夹。
3. 首次运行如提示「无法打开」，请前往 **系统设置 → 隐私与安全性** 点击「仍要打开」。

> 使用前请确保你的 Mac 已安装鼠须管输入法（[官方下载](https://rime.im/download/)）。

## 语言

界面跟随系统语言，目前支持简体中文与英文。

---

## 自行构建

需要 macOS 13+、Xcode 15+ / Swift 5.9+。

```bash
git clone https://github.com/wolfprince12/squirrel-Panel.git
cd squirrel-Panel
make release
# 产物：dist/Squirrel Panel.app
```

如果终端启用了沙箱导致 SwiftPM 无法执行清单编译：

```bash
make release SWIFT_BUILD="swift build --disable-sandbox"
```

---

## 它是如何工作的

本 App 不链接 `librime`，也不直接操作输入法进程，而是通过三种官方/安全机制与鼠须管交互：

1. 读写 `~/Library/Rime/*.custom.yaml` 补丁文件。
2. 调用 `Squirrel.app/Contents/MacOS/Squirrel --reload / --sync / --quit` 等命令行接口。
3. 向 `SquirrelReloadNotification` 等分布式通知发送消息，触发输入法重新部署。

因此，即使本控制面板出现 bug，最多只会影响补丁文件；卸载本 App 不会影响鼠须管输入法本身。

---

## 项目关系

- [rime/squirrel](https://github.com/rime/squirrel) —— 鼠须管输入法本体。
- [wolfprince12/squirrel-Panel](https://github.com/wolfprince12/squirrel-Panel) —— 本控制面板（第三方独立项目）。

---

## 关于作者

**Mr 大狼** —— 导演 / 制作人 / AI 产品创作者。

20 余年影视传媒与演出制作经验，现用 AI 把经验激烈跨界重构成产品。

- 公众号：**爻知云AI**
- 智能合同管理：[DealV](https://www.dealv.cn)

---

## 赞助 · 请杯咖啡

如果这个项目帮到了你，欢迎扫微信二维码请作者一杯咖啡 ☕

<img src="./docs/assets/WeChatPay-QRCode.jpg" width="240" alt="微信支付二维码">

---

## 许可

[GNU General Public License v3.0](./LICENSE)

---

# Squirrel Panel (English)

A standalone, third-party graphical settings app for the [Squirrel](https://github.com/rime/squirrel) Rime input method on macOS.

This project is independent of the Squirrel input method itself. After installing this app, users can control their local Squirrel installation through a GUI, without editing YAML by hand.

## About the Author

**Mr. Dawolf** — Director / Producer / AI Product Creator.

20+ years in film, television, and live production. Reconstructing cross-domain experience into AI-powered products.

- WeChat Official Account: **爻知云AI**
- Smart contract management: [DealV](https://www.dealv.cn)

## Sponsor · Buy Me a Coffee

If this project helped you, feel free to buy me a coffee via WeChat Pay ☕

<img src="./docs/assets/WeChatPay-QRCode.jpg" width="240" alt="WeChat Pay QR Code">

## License

[GNU General Public License v3.0](./LICENSE)
