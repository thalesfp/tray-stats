APP := Tray Stats.app
STAGE := .build/$(APP)
INSTALLED := /Applications/$(APP)
BINARY := .build/release/TrayStats

.DEFAULT_GOAL := help
.PHONY: help build test fmt fmt-check lint verify bundle run install clean

help: ## Show this help
	@awk -F'##' '/^[a-z-]+:.*##/ { \
		split($$1, target, ":"); sub(/^ +/, "", $$2); \
		printf "  \033[1m%-10s\033[0m %s\n", target[1], $$2 }' $(MAKEFILE_LIST)

build: ## Build the debug binary
	swift build

test: ## Run the tests
	swift test

fmt: ## Format the sources
	swift format --in-place --recursive Sources Tests Package.swift

fmt-check: ## Check the sources are formatted
	swift format lint --strict --recursive Sources Tests Package.swift

lint: ## Build treating warnings as errors
	swift build -Xswiftc -warnings-as-errors

verify: fmt-check lint test ## Check formatting, lint, and test

bundle: ## Assemble Tray Stats.app
	swift build -c release
	rm -rf "$(STAGE)"
	mkdir -p "$(STAGE)/Contents/MacOS"
	cp $(BINARY) "$(STAGE)/Contents/MacOS/TrayStats"
	cp Resources/Info.plist "$(STAGE)/Contents/Info.plist"
	codesign --force --sign - --identifier me.thales.traystats "$(STAGE)"

run: bundle ## Build and open the bundled app
	@pkill -x TrayStats; while pgrep -qx TrayStats; do sleep 0.1; done
	open "$(STAGE)"

install: bundle ## Install the app into /Applications and open it
	@pkill -x TrayStats; while pgrep -qx TrayStats; do sleep 0.1; done
	rm -rf "$(INSTALLED)"
	cp -R "$(STAGE)" "$(INSTALLED)"
	open "$(INSTALLED)"

clean: ## Delete the build directory
	swift package clean
	rm -rf "$(STAGE)"
