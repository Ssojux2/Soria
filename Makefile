SHELL := /bin/sh

.PHONY: build clean run run-clean release-dmg clean-dist

build:
	xcodebuild build \
		-scheme Soria \
		-project Soria.xcodeproj \
		-derivedDataPath .build/DerivedData \
		-destination 'platform=macOS' \
		CODE_SIGNING_ALLOWED=NO \
		CODE_SIGNING_REQUIRED=NO

clean:
	xcodebuild clean \
		-scheme Soria \
		-project Soria.xcodeproj \
		-derivedDataPath .build/DerivedData \
		-destination 'platform=macOS' \
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
