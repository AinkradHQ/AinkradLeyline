DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR
# Debug hosts only scan this (PluginTrust.scansDevPluginsDirectory is #if DEBUG).
DEV_PLUGINS ?= $(HOME)/Library/Application Support/com.ainkrad.app/Cache/DevPlugins
SCHEME := LeylinePlugin
XCB := xcodebuild -scheme $(SCHEME) -configuration Debug -derivedDataPath build -destination 'platform=macOS'
.PHONY: generate build test sideload release
generate: ; xcodegen generate
build: lint generate ; $(XCB) build
test: lint generate ; $(XCB) test
sideload: build
	@case "$(DEV_PLUGINS)" in "$(HOME)/Library/Application Support/"*) \
		[ "$(CONFIRM_DAILY)" = 1 ] || { echo "refusing: DEV_PLUGINS is the daily app's folder (set DEV_PLUGINS=<fixture>/DevPlugins or CONFIRM_DAILY=1)"; exit 1; };; esac
	mkdir -p "$(DEV_PLUGINS)"
	rm -rf "$(DEV_PLUGINS)/$(SCHEME).bundle"
	ditto build/Build/Products/Debug/$(SCHEME).bundle "$(DEV_PLUGINS)/$(SCHEME).bundle"
release: ; ./scripts/release.sh $(V)

include scripts/guardrails.mk
