APP_NAME := NotchFlow
PROJECT := NotchFlow.xcodeproj
SCHEME := NotchFlow
CONFIGURATION := Debug
DERIVED_DATA := /private/tmp/notchflow-derived
APP_BUNDLE := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(APP_NAME).app

.DEFAULT_GOAL := help
.PHONY: help build run start stop restart status

help:
	@echo "NotchFlow commands:"
	@echo "  make run      Build and launch NotchFlow"
	@echo "  make build    Build an unsigned local Debug app"
	@echo "  make start    Alias for make run"
	@echo "  make stop     Close NotchFlow"
	@echo "  make restart  Close, rebuild, and relaunch NotchFlow"

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

run:
	@./script/build_and_run.sh --verify

start: run

stop:
	@osascript -e 'tell application id "com.notchflow.app" to quit' >/dev/null 2>&1 || true
	@echo "$(APP_NAME) closed"

restart: run

status:
	@pgrep -x "$(APP_NAME)" >/dev/null 2>&1 \
		&& echo "$(APP_NAME) is running" \
		|| echo "$(APP_NAME) is not running"
