APP_NAME := NotchFlow
PROJECT := NotchFlow.xcodeproj
SCHEME := NotchFlow
CONFIGURATION := Debug
DERIVED_DATA := /private/tmp/notchflow-derived
APP_BUNDLE := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(APP_NAME).app

.DEFAULT_GOAL := help
.PHONY: help build dev install-release install-release-customer verify-dev run start stop restart status

help:
	@echo "NotchFlow commands:"
	@echo "  make dev      Build and launch the locally entitled Debug app"
	@echo "  make verify-dev  Launch Debug and verify its menu and approval bridges"
	@echo "  make run      Alias for make dev"
	@echo "  make build    Build and sign the locally entitled Debug app"
	@echo "  make install-release  Build Release, stamped with the latest tag, and install it"
	@echo "  make install-release-customer  Same, but licensed as a customer (trial, lock) for testing"
	@echo "  make start    Alias for make run"
	@echo "  make stop     Close NotchFlow"
	@echo "  make restart  Close, rebuild, and relaunch NotchFlow"

# `LicenseService` grants this configuration a compile-time local developer
# entitlement. Release builds deliberately omit DEBUG and always use Lemon
# Squeezy licensing instead.
build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA) CODE_SIGNING_ALLOWED=NO build
	@# Sign with the same identity reinstall.sh and CI use. Without this the dev
	@# build is ad-hoc, its designated requirement changes on EVERY build, and
	@# macOS silently drops the Accessibility grant each time — which makes any
	@# permission-dependent feature (the alert ears, clipboard reads) untestable
	@# in the dev loop. Signs last, after the frameworks are in place: signing a
	@# bundle and then adding files to it invalidates the signature.
	@./scripts/codesign-app.sh --debug $(APP_BUNDLE)

dev:
	@./scripts/build_and_run.sh --verify
	@bash Tests/verify_menu_bar_icon.sh
	@bash Tests/verify_approval_bridges.sh

# The product users get, built locally. It is stamped with the newest release
# tag so the updater doesn't offer that same release back as an "update".
install-release:
	@BUILD_CONFIGURATION=Release MARKETING_VERSION=$$(git tag --list 'v*' --sort=-v:refname | head -1 | sed 's/^v//') \
		./scripts/build_and_run.sh --verify

# Release as a customer sees it on this Mac: owner unlock off, trial kept in a
# separate Keychain entry. See `CustomerSimulation` in LicenseService.swift.
install-release-customer:
	@BUILD_CONFIGURATION=Release EXTRA_SWIFT_FLAGS=-DNOTCHFLOW_CUSTOMER_SIMULATION \
		MARKETING_VERSION=$$(git tag --list 'v*' --sort=-v:refname | head -1 | sed 's/^v//') \
		./scripts/build_and_run.sh --verify

verify-dev: dev
	@swift test

run: dev

start: run

stop:
	@osascript -e 'tell application id "com.notchflow.app" to quit' >/dev/null 2>&1 || true
	@echo "$(APP_NAME) closed"

restart: run

status:
	@pgrep -x "$(APP_NAME)" >/dev/null 2>&1 \
		&& echo "$(APP_NAME) is running" \
		|| echo "$(APP_NAME) is not running"
