CONFIGURATION ?= debug
SWIFT_BUILD_SYSTEM ?=
SWIFT_BUILD_SYSTEM_FLAG = $(if $(SWIFT_BUILD_SYSTEM),--build-system $(SWIFT_BUILD_SYSTEM))
APP_BUNDLE := $(CURDIR)/dist/MindmapADE.app

.PHONY: build app run check test format format-check clean

build:
	xcrun swift build $(SWIFT_BUILD_SYSTEM_FLAG) --configuration "$(CONFIGURATION)"

app: build
	bash Scripts/bundle-app.sh "$(CONFIGURATION)" $(SWIFT_BUILD_SYSTEM_FLAG)

run: app
	open -n "$(APP_BUNDLE)"

check: format-check build test

test:
	xcrun swift test $(SWIFT_BUILD_SYSTEM_FLAG)

format:
	xcrun swift format format --in-place --recursive Package.swift Sources Tests

format-check:
	xcrun swift format lint --strict --recursive Package.swift Sources Tests

clean:
	xcrun swift package clean
	rm -rf "$(CURDIR)/dist"
