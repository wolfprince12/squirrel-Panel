APP_NAME    := Squirrel Panel
EXEC        := SquirrelPanel
DIST        := dist
BUNDLE      := $(DIST)/$(APP_NAME).app
CONTENTS    := $(BUNDLE)/Contents
CODESIGN_ID ?= -
RESOURCES   := Resources
VERSION     := $(shell plutil -extract CFBundleShortVersionString raw "$(RESOURCES)/AppInfo.plist" 2>/dev/null || echo 0.2.3)
# 某些沙箱化的终端环境下 SwiftPM 无法执行清单编译，可用
#   make release SWIFT_BUILD="swift build --disable-sandbox"
SWIFT_BUILD ?= swift build

.PHONY: all debug release bundle universal dmg install uninstall run clean icons python-tarball

all: release

## 从 Resources/AppLogo.png 重新生成 AppIcon.icns 与 build-icon/AppIcon.iconset
icons:
	@swift tools/make_icon_from_logo.swift
	@iconutil -c icns build-icon/AppIcon.iconset -o Resources/AppIcon.icns
	@echo "✅ 已生成 Resources/AppIcon.icns"

## 本机架构构建（开发用，最快）
debug:
	$(SWIFT_BUILD)

release:
	$(SWIFT_BUILD) -c release
	@$(MAKE) bundle BIN=.build/release/$(EXEC)

## Intel + Apple Silicon 通用二进制（发版用）
universal:
	$(SWIFT_BUILD) -c release --arch arm64 --arch x86_64
	@$(MAKE) bundle BIN=.build/apple/Products/Release/$(EXEC)

## 组装 .app bundle
## 注意：自 2.0.0 起 Python+MLX 运行时不再内置进 App（改为「运行依赖」里按需从
## GitHub Releases 下载），因此 release 打包不再调用 bundle-python，App 体积大幅减小。
## 本地开发若想自带 Python 调试，可手动 `make bundle-python` 后再 `make release`。
bundle: prepare-engine
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@cp "$(BIN)" "$(CONTENTS)/MacOS/$(EXEC)"
	@cp "$(dir $(BIN))SP-AIEnergyAgent" "$(CONTENTS)/MacOS/SP-AIEnergyAgent" 2>/dev/null || true
	@cp "$(RESOURCES)/AppInfo.plist" "$(CONTENTS)/Info.plist"
	@cp -R "$(RESOURCES)/"* "$(CONTENTS)/Resources/"
	@rm -f "$(CONTENTS)/Resources/AppInfo.plist"
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@codesign --force --deep --sign "$(CODESIGN_ID)" "$(BUNDLE)" 2>/dev/null || true
	@echo "✅ 已生成 $(BUNDLE)"

## 生成 DMG 安装包（需要 npm install -g appdmg）
dmg: release
	@swift tools/make_dmg_cover.swift
	@rm -rf "$(DIST)/dmg-staging"
	@mkdir -p "$(DIST)/dmg-staging"
	@cp -R "$(BUNDLE)" "$(DIST)/dmg-staging/"
	@ln -sf /Applications "$(DIST)/dmg-staging/Applications"
	@cp tools/fix.command "$(DIST)/dmg-staging/fix.command"
	@cp tools/appdmg.json "$(DIST)/dmg-staging/appdmg.json"
	@cd "$(DIST)/dmg-staging" && \
	  NODE_PATH=/Users/wolfprince/.workbuddy/binaries/node/workspace/node_modules \
	  /Users/wolfprince/.workbuddy/binaries/node/versions/22.22.2/bin/node \
	  /Users/wolfprince/.workbuddy/binaries/node/workspace/node_modules/.bin/appdmg \
	  appdmg.json "../Squirrel-Panel-$(VERSION).dmg"
	@rm -rf "$(DIST)/dmg-staging"
	@echo "✅ 已生成 $(DIST)/Squirrel-Panel-$(VERSION).dmg"

## 安装到 /Applications
install: release
	@rm -rf "/Applications/$(APP_NAME).app"
	@cp -R "$(BUNDLE)" /Applications/
	@echo "✅ 已安装到 /Applications/$(APP_NAME).app"

uninstall:
	@rm -rf "/Applications/$(APP_NAME).app"
	@echo "已移除 /Applications/$(APP_NAME).app"

run: release
	@open "$(BUNDLE)"

clean:
	@rm -rf .build "$(DIST)"
	@echo "已清理构建产物"

## 同步内置 AI 引擎包（Resources/AIEnergyEngine/）到 bundle 资源。
## 注意：Resources/AIEnergyEngine/ 本身即“源”（lua 叠加层 + 服务 + 内核都在这里直接维护），
## 这里只负责补一份 vendored 内核 bzx_ai.py（运行时 `from bzx_ai import AIClient` 需要），
## 绝不 rm -rf 整个目录、绝不反向用旧副本覆盖我们的最新改动。
prepare-engine:
	@mkdir -p "$(RESOURCES)/AIEnergyEngine/lua"
	@echo "✅ 已就绪：AIEnergyEngine 源即权威副本（lua 叠加层 + 续写服务 + 规则兜底），无需 vendored 内核"

## 将受控 Python + MLX 推理栈打包进 App（D6）。失败不致命：回退系统 Python。
## 仅本地开发/调试用；release 打包已不再调用它。
bundle-python:
	@bash "$(CURDIR)/Tools/bundle_python.sh" || echo "⚠️  bundle-python 跳过（将回退系统 Python）"

## 生成可上传到 GitHub Releases 的 Python 运行时压缩包（ wolfprince12/squirrel-Panel-aienergy-runtime ）。
## App 内的「运行依赖 → Python + MLX 运行时」卡片会按 aienergy-python-*.tar.gz 资产名拉取它。
## 压缩包顶层目录为 python/，解压后落到 <Rime 用户目录>/aienergy/python。
python-tarball:
	@bash "$(CURDIR)/Tools/bundle_python.sh"
	@mkdir -p "$(DIST)"
	@tar -czf "$(DIST)/aienergy-python-macos-arm64.tar.gz" -C "$(RESOURCES)/aienergy-python" .
	@echo "✅ 已生成 $(DIST)/aienergy-python-macos-arm64.tar.gz"
	@echo "   请将其作为资产上传到 GitHub Releases：wolfprince12/squirrel-Panel-aienergy-runtime（建议 tag：v1.0.0）"
