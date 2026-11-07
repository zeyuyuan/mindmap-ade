CONFIGURATION ?= debug
APP_BUNDLE := $(CURDIR)/dist/MindmapADE.app

.PHONY: build app run check test format format-check clean

build:
	xcrun swift build --configuration "$(CONFIGURATION)"

app: build
	bash Scripts/bundle-app.sh "$(CONFIGURATION)"

run: app
	open -n "$(APP_BUNDLE)"

check: format-check build test

test:
	xcrun swift test

format:
	xcrun swift format format --in-place --recursive Package.swift Sources Tests

format-check:
	xcrun swift format lint --strict --recursive Package.swift Sources Tests

clean:
	xcrun swift package clean
	rm -rf "$(CURDIR)/dist"
