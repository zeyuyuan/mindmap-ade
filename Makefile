CONFIGURATION ?= debug
APP_BUNDLE := $(CURDIR)/dist/MindmapADE.app

.PHONY: build app run check format format-check clean

build:
	xcrun swift build --configuration "$(CONFIGURATION)"

app: build
	bash Scripts/bundle-app.sh "$(CONFIGURATION)"

run: app
	open -n "$(APP_BUNDLE)"

check: format-check build

format:
	xcrun swift format format --in-place --recursive Package.swift Sources

format-check:
	xcrun swift format lint --strict --recursive Package.swift Sources

clean:
	xcrun swift package clean
	rm -rf "$(CURDIR)/dist"
