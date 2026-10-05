SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

SCHEME := Workdeck
DESTINATION := platform=macOS
BUILD_DIR := build
APP := $(BUILD_DIR)/Build/Products/Release/Workdeck.app
INSTALL_DIR := /Applications

.PHONY: build test install clean

## build: Release build into ./build (signed with the project's development team)
build:
	xcodebuild -scheme $(SCHEME) -destination 'generic/platform=macOS' -configuration Release \
		-derivedDataPath $(BUILD_DIR) build 2>&1 | grep -E "error:|warning:|\*\* BUILD" | grep -v appintents

## test: run the unit test suite
test:
	xcodebuild -scheme $(SCHEME) -destination '$(DESTINATION)' test 2>&1 \
		| grep -E "error:|recorded an issue|Test run with|\*\* TEST"

## install: build, quit a running Workdeck, copy it to /Applications, and launch it
install: build
	@if pgrep -x Workdeck > /dev/null; then \
		echo "Quitting running Workdeck"; \
		pkill -x Workdeck; \
		while pgrep -x Workdeck > /dev/null; do sleep 0.2; done; \
	fi
	rm -rf "$(INSTALL_DIR)/Workdeck.app"
	ditto "$(APP)" "$(INSTALL_DIR)/Workdeck.app"
	open "$(INSTALL_DIR)/Workdeck.app"

## clean: remove ./build
clean:
	rm -rf $(BUILD_DIR)
