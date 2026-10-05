SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

SCHEME := Workdeck
DESTINATION := platform=macOS
BUILD_DIR := build
APP := $(BUILD_DIR)/Build/Products/Release/Workdeck.app
INSTALL_DIR := /Applications
INSTALLED_BIN := $(INSTALL_DIR)/Workdeck.app/Contents/MacOS/Workdeck

.PHONY: build test install clean

## build: Release build into ./build (signed with the project's development team)
build:
	xcodebuild -scheme $(SCHEME) -destination 'generic/platform=macOS' -configuration Release \
		-derivedDataPath $(BUILD_DIR) build 2>&1 | grep -E "error:|warning:|\*\* BUILD" | grep -v appintents

## test: run the unit test suite
test:
	xcodebuild -scheme $(SCHEME) -destination '$(DESTINATION)' test 2>&1 \
		| grep -E "error:|recorded an issue|Test run with|\*\* TEST"

## install: build, quit the installed Workdeck, copy it to /Applications, and launch it
install: build
	@for pid in $$(pgrep -x Workdeck); do \
		path=$$(ps -o comm= -p $$pid); \
		if [ "$$path" != "$(INSTALLED_BIN)" ]; then \
			echo "error: Workdeck is running from $$path (pid $$pid), probably under the Xcode debugger."; \
			echo "Stop it in Xcode (Product > Stop) or quit it, then run make install again."; \
			exit 1; \
		fi; \
	done
	@if pgrep -x Workdeck > /dev/null; then \
		echo "Quitting installed Workdeck"; \
		pkill -x Workdeck; \
		for i in $$(seq 50); do pgrep -x Workdeck > /dev/null || break; sleep 0.2; done; \
		if pgrep -x Workdeck > /dev/null; then echo "error: Workdeck did not quit within 10 seconds"; exit 1; fi; \
	fi
	rm -rf "$(INSTALL_DIR)/Workdeck.app"
	ditto "$(APP)" "$(INSTALL_DIR)/Workdeck.app"
	open "$(INSTALL_DIR)/Workdeck.app"

## clean: remove ./build
clean:
	rm -rf $(BUILD_DIR)
