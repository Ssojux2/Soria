SHELL := /bin/sh
MACOS_DESTINATION ?= platform=macOS,arch=$(shell uname -m)
PYTHON ?= $(if $(wildcard analysis-worker/.venv/bin/python),analysis-worker/.venv/bin/python,python3)

.PHONY: build clean run run-clean release-dmg clean-dist test test-swift test-swift-full test-worker

build:
	xcodebuild build \
		-scheme Soria \
		-project Soria.xcodeproj \
		-derivedDataPath .build/DerivedData \
		-destination '$(MACOS_DESTINATION)' \
		CODE_SIGNING_ALLOWED=NO \
		CODE_SIGNING_REQUIRED=NO

clean:
	xcodebuild clean \
		-scheme Soria \
		-project Soria.xcodeproj \
		-derivedDataPath .build/DerivedData \
		-destination '$(MACOS_DESTINATION)' \
		CODE_SIGNING_ALLOWED=NO \
		CODE_SIGNING_REQUIRED=NO

run:
	./Scripts/run_debug_app.sh

run-clean:
	./Scripts/run_debug_app.sh --clean

release-dmg:
	./Scripts/create_release_dmg.sh

clean-dist:
	rm -rf dist

test: test-swift test-worker

test-swift:
	xcodebuild test \
		-scheme Soria \
		-project Soria.xcodeproj \
		-derivedDataPath .build/TestDerivedData \
		-destination '$(MACOS_DESTINATION)' \
		-only-testing:SoriaTests \
		-skip-testing:SoriaTests/LibraryPreviewTests \
		CODE_SIGNING_ALLOWED=NO \
		CODE_SIGNING_REQUIRED=NO

test-swift-full:
	xcodebuild test \
		-scheme Soria \
		-project Soria.xcodeproj \
		-derivedDataPath .build/TestDerivedData \
		-destination '$(MACOS_DESTINATION)' \
		-only-testing:SoriaTests \
		CODE_SIGNING_ALLOWED=NO \
		CODE_SIGNING_REQUIRED=NO

test-worker:
	PYTHONPATH=analysis-worker $(PYTHON) -m pytest analysis-worker/tests
