DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR
# Debug hosts only scan this (PluginTrust.scansDevPluginsDirectory is #if DEBUG).
DEV_PLUGINS := $(HOME)/Library/Application Support/com.ainkrad.app/Cache/DevPlugins
SCHEME := LeylinePlugin
XCB := xcodebuild -scheme $(SCHEME) -configuration Debug -derivedDataPath build -destination 'platform=macOS'
.PHONY: generate build test sideload release
generate: ; xcodegen generate
build: generate ; $(XCB) build
test: generate ; $(XCB) test
sideload: build
	mkdir -p "$(DEV_PLUGINS)"
	rm -rf "$(DEV_PLUGINS)/$(SCHEME).bundle"
	ditto build/Build/Products/Debug/$(SCHEME).bundle "$(DEV_PLUGINS)/$(SCHEME).bundle"
release: ; ./scripts/release.sh $(V)
