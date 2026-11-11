SHELL := /bin/bash

SCHEME := Workdeck
DESTINATION := platform=macOS
BUILD_DIR := build
APP := $(BUILD_DIR)/Build/Products/Release/Workdeck.app
INSTALL_DIR := /Applications
INSTALLED_BIN := $(INSTALL_DIR)/Workdeck.app/Contents/MacOS/Workdeck

.PHONY: build test install clean release-prep screenshots

## build: Release build into ./build (signed with the project's development team)
build:
	set -o pipefail; xcodebuild -scheme $(SCHEME) -destination 'generic/platform=macOS' -configuration Release \
		-derivedDataPath $(BUILD_DIR) build 2>&1 | grep -E "error:|warning:|\*\* BUILD" | grep -v appintents

## test: run the unit test suite
test:
	set -o pipefail; xcodebuild -scheme $(SCHEME) -destination '$(DESTINATION)' test 2>&1 \
		| grep -E "error:|recorded an issue|Test run with|\*\* TEST"

## install: build, quit the installed Workdeck, copy it to /Applications, and launch it
install: build
	@for pid in $$(pgrep -U $$(id -u) -x Workdeck); do \
		path=$$(ps -o comm= -p $$pid); \
		if [ "$$path" != "$(INSTALLED_BIN)" ]; then \
			echo "error: Workdeck is running from $$path (pid $$pid), probably under the Xcode debugger."; \
			echo "Stop it in Xcode (Product > Stop) or quit it, then run make install again."; \
			exit 1; \
		fi; \
	done
	@if pgrep -U $$(id -u) -x Workdeck > /dev/null; then \
		echo "Quitting installed Workdeck"; \
		pkill -U $$(id -u) -x Workdeck; \
		for i in $$(seq 50); do pgrep -U $$(id -u) -x Workdeck > /dev/null || break; sleep 0.2; done; \
		if pgrep -U $$(id -u) -x Workdeck > /dev/null; then echo "error: Workdeck did not quit within 10 seconds"; exit 1; fi; \
	fi
	rm -rf "$(INSTALL_DIR)/Workdeck.app"
	ditto "$(APP)" "$(INSTALL_DIR)/Workdeck.app"
	open "$(INSTALL_DIR)/Workdeck.app"

## clean: remove ./build
clean:
	rm -rf $(BUILD_DIR)

## release-prep: on develop, move CHANGELOG's Unreleased under VERSION, bump the versions, commit (then docs/releasing.md)
release-prep:
	@if [ -z "$(VERSION)" ]; then echo "usage: make release-prep VERSION=1.2.3"; exit 1; fi
	python3 -I scripts/release/release.py prepare $(VERSION)

## screenshots: render the README and landing page images from demo data into docs/media/screenshots
## (the animations and the Your week stills are then squeezed losslessly by oxipng: brew install oxipng)
screenshots:
	@command -v oxipng >/dev/null || { echo "error: make screenshots needs oxipng to compress the notch animations: brew install oxipng"; exit 1; }
	@mkdir -p $(BUILD_DIR)
	@set -o pipefail; TEST_RUNNER_WORKDECK_SCREENSHOTS=1 TEST_RUNNER_TZ=Europe/Berlin xcodebuild -scheme $(SCHEME) \
		-destination '$(DESTINATION)' test -only-testing:WorkdeckTests/ScreenshotTests 2>&1 \
		| tee $(BUILD_DIR)/screenshots.log | grep -E "error:|recorded an issue|Test run with|\*\* TEST|^Wrote "
	@n=$$(grep -c '^Wrote .*docs/media/screenshots/[a-z-]*\.png' $(BUILD_DIR)/screenshots.log); \
		if [ "$$n" -lt 25 ]; then echo "error: only $$n images written; the switch may not have reached the tests"; exit 1; fi
	@# Lossless, keeps the animation: about a third smaller than ImageIO's deflate. The landing page's Your week
	@# stills too: the page loads them with the tour.
	@oxipng -q -o 4 --strip safe docs/media/screenshots/*-animated.png docs/media/screenshots/week-*.png \
		docs/media/screenshots/alert-session.png docs/media/screenshots/closed-lid.png
	@ls -lh docs/media/screenshots/*-animated.png docs/media/screenshots/week-*.png | awk '{print "Compressed " $$9 " to " $$5}'
	@# The landing page loads each animation with its tab: about 4 MB at most (landing tour animations spec §4.4).
	@for f in docs/media/screenshots/*-animated.png; do \
		n=$$(stat -f %z "$$f"); if [ "$$n" -gt 4500000 ]; then echo "error: $$f is $$n bytes after oxipng (limit 4.5 MB)"; exit 1; fi; \
	done
