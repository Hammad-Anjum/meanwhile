DERIVED = .build/xcode
APP = $(DERIVED)/Build/Products/Debug/Meanwhile.app
HOOK_DIR = $(HOME)/Library/Application Support/Meanwhile/bin

.PHONY: project build test run install-hook clean

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

# Builds meanwhile-hook and copies it to where the agents' hook configs point.
install-hook:
	swift build -c release --product meanwhile-hook
	mkdir -p "$(HOOK_DIR)"
	cp .build/release/meanwhile-hook "$(HOOK_DIR)/meanwhile-hook"

clean:
	rm -rf .build App/Meanwhile.xcodeproj
