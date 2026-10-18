HOOK_DIR = $(HOME)/Library/Application Support/Meanwhile/bin

.PHONY: build test run install-hook clean

build:
	swift build

test:
	swift test

# Runs the notch process in the foreground; Ctrl-C or Quit from the menu bar stops it.
run: build
	@pkill -x meanwhile || true
	.build/debug/meanwhile run

# Builds meanwhile-hook and copies it to where the agents' hook configs point.
install-hook:
	swift build -c release --product meanwhile-hook
	mkdir -p "$(HOOK_DIR)"
	cp ".build/release/meanwhile-hook" "$(HOOK_DIR)/meanwhile-hook"

clean:
	rm -rf .build
