DERIVED = .build/xcode
APP = $(DERIVED)/Build/Products/Debug/Meanwhile.app

.PHONY: project build test run clean

project:
	cd App && xcodegen generate --quiet

build: project
	xcodebuild -project App/Meanwhile.xcodeproj -scheme Meanwhile -configuration Debug \
		-destination "platform=macOS,arch=arm64" -derivedDataPath $(DERIVED) -quiet build

test:
	swift test

run: build
	@pkill -x Meanwhile || true
	open $(APP)

clean:
	rm -rf .build App/Meanwhile.xcodeproj
