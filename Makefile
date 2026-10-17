APP := build/DroidDrop.app
VERSION ?= $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
DMG := build/DroidDrop-$(VERSION).dmg
INSTALL_DIR ?= $(HOME)/Applications

.PHONY: help build universal dmg install uninstall run clean

# Show this list of commands
help:
	@echo "Usage: make <command>"
	@echo
	@awk '/^# /{desc = substr($$0, 3); next} /^[a-z]+:/ && desc {printf "  %-10s %s\n", substr($$1, 1, length($$1) - 1), desc} {desc = ""}' $(MAKEFILE_LIST)

# Build build/DroidDrop.app for this Mac
build:
	VERSION=$(VERSION) ./build.sh

# Build build/DroidDrop.app for Apple silicon and Intel (needs Xcode)
universal:
	VERSION=$(VERSION) ./build.sh --universal

# Package the universal app, README, and LICENSE into build/DroidDrop-<version>.dmg
dmg: universal
	rm -rf build/dmg "$(DMG)"
	mkdir -p build/dmg
	ditto "$(APP)" build/dmg/DroidDrop.app
	cp README.md build/dmg/README.md
	cp LICENSE build/dmg/LICENSE.txt
	ln -s /Applications build/dmg/Applications
	hdiutil create -volname DroidDrop -srcfolder build/dmg -format UDZO -ov "$(DMG)"
	rm -rf build/dmg
	@echo "Built $(DMG)"

# Build and copy the app to ~/Applications (change with INSTALL_DIR=...)
install: build
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/DroidDrop.app"
	ditto "$(APP)" "$(INSTALL_DIR)/DroidDrop.app"
	@echo "Installed $(INSTALL_DIR)/DroidDrop.app"

# Remove the installed app
uninstall:
	rm -rf "$(INSTALL_DIR)/DroidDrop.app"

# Build and launch the app
run: build
	open "$(APP)"

# Delete all build output
clean:
	rm -rf build .build
