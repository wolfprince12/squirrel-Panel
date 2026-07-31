APP_NAME    := Squirrel Panel
EXEC        := SquirrelPanel
DIST        := dist
BUNDLE      := $(DIST)/$(APP_NAME).app
CONTENTS    := $(BUNDLE)/Contents
CODESIGN_ID ?= -
# 某些沙箱化的终端环境下 SwiftPM 无法执行清单编译，可用
#   make release SWIFT_BUILD="swift build --disable-sandbox"
SWIFT_BUILD ?= swift build

.PHONY: all debug release bundle universal install uninstall run clean

all: release

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
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$(CONTENTS)/Resources/"; fi
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@codesign --force --deep --sign "$(CODESIGN_ID)" "$(BUNDLE)" 2>/dev/null || true
	@echo "✅ 已生成 $(BUNDLE)"

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
