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

.PHONY: all debug release bundle universal dmg install uninstall run clean icons

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
bundle:
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@cp "$(BIN)" "$(CONTENTS)/MacOS/$(EXEC)"
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
	@osacompile -o "$(DIST)/dmg-staging/Fix.app" tools/fix.applescript
	@codesign --force --sign - "$(DIST)/dmg-staging/Fix.app" 2>/dev/null || true
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
