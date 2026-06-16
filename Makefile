# MacDirStat
#
# All Swift invocations go through `xcrun`, which selects Xcode's default
# toolchain. This is deliberate: MacDirStat is a SwiftUI app and depends on
# Apple's SwiftUI macro plugins (e.g. @State / @Observable expansion), which
# ship ONLY inside Xcode. A bare `swift` on your PATH may resolve to a
# Swiftly-managed swift.org toolchain that lacks those macros, producing:
#
#   error: external macro implementation type 'SwiftUIMacros.StateMacro'
#          could not be found ... plugin for module 'SwiftUIMacros' not found
#
# Using `xcrun swift` sidesteps that regardless of PATH ordering.

SWIFT := xcrun swift

APP_NAME := MacDirStat
APP_BUNDLE := .build/$(APP_NAME).app

.DEFAULT_GOAL := build

.PHONY: build release run run-release bundle open-app clean xcode toolchain

## build: debug build
build:
	$(SWIFT) build

## release: optimized build
release:
	$(SWIFT) build -c release

## run: build and run (debug)
run:
	$(SWIFT) run MacDirStat

## run-release: build and run (release)
run-release:
	$(SWIFT) run -c release MacDirStat

## bundle: package the release binary into MacDirStat.app
bundle: release
	rm -rf "$(APP_BUNDLE)"
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	cp ".build/release/$(APP_NAME)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	cp Packaging/Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	@[ -f Packaging/AppIcon.icns ] && cp Packaging/AppIcon.icns "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns" || echo "note: no Packaging/AppIcon.icns — using generic icon"
	@# Ad-hoc sign so macOS keeps a stable identity (e.g. for TCC disk-access grants)
	codesign --force --sign - "$(APP_BUNDLE)"
	@echo "Built $(APP_BUNDLE)"

## open-app: build the bundle and launch it
open-app: bundle
	open "$(APP_BUNDLE)"

## clean: remove build artifacts
clean:
	$(SWIFT) package clean
	rm -rf .build

## xcode: open the package in Xcode
xcode:
	open Package.swift

## toolchain: print which toolchain is actually being used
toolchain:
	@echo "xcrun swift -> $$(xcrun --find swift)"
	@$(SWIFT) --version
