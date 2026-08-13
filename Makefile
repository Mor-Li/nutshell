APP_NAME   := Nutshell
BUILD_DIR  := .build/release
STAGE_DIR  := build
APP_BUNDLE := $(STAGE_DIR)/$(APP_NAME).app
INSTALL_DIR := $(HOME)/Applications

.PHONY: all build app install run stop restart clean

all: app

## 编译可执行文件
build:
	swift build -c release

## 组装成 .app（菜单栏程序必须是 app bundle，裸可执行文件没法在菜单栏待着）
app: build
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@# SPM 把资源打进 <包名>_<target名>.bundle，搬到 app 的 Resources 下 Bundle.module 才找得到
	@if [ -d "$(BUILD_DIR)/$(APP_NAME)_$(APP_NAME).bundle" ]; then \
		cp -R "$(BUILD_DIR)/$(APP_NAME)_$(APP_NAME).bundle" $(APP_BUNDLE)/Contents/Resources/; \
	else \
		echo "!! 没找到资源 bundle，markdown 渲染会瞎"; exit 1; \
	fi
	@# 辅助功能权限是认签名的，签一下省得系统每次都当成陌生程序
	codesign --force --sign - $(APP_BUNDLE)
	@echo "✅ 打好了：$(APP_BUNDLE)"

## 装到 ~/Applications 并启动
install: app stop
	mkdir -p $(INSTALL_DIR)
	rm -rf $(INSTALL_DIR)/$(APP_NAME).app
	cp -R $(APP_BUNDLE) $(INSTALL_DIR)/
	open $(INSTALL_DIR)/$(APP_NAME).app
	@echo "✅ 装好并启动了：$(INSTALL_DIR)/$(APP_NAME).app"

## 直接跑构建目录里的版本（调试用，日志能看见）
run: app stop
	open $(APP_BUNDLE)

## 杀进程后要等一下：立刻 open 会撞上 LaunchServices 的 -600（进程还没真正退干净）
stop:
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@sleep 1.2

restart: stop
	@open $(INSTALL_DIR)/$(APP_NAME).app

clean:
	rm -rf .build $(STAGE_DIR)
