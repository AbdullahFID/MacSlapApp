APP_NAME   := MacSlapApp
VERSION    := 3.0.0
BUILD      := $(shell git rev-list --count HEAD 2>/dev/null || echo 1)

DIST       := dist
APP        := $(DIST)/$(APP_NAME).app
RELEASE_ZIP := $(DIST)/$(APP_NAME)-v$(VERSION).zip

# /Applications when writable (admin accounts), otherwise ~/Applications.
INSTALL_DIR := $(shell [ -w /Applications ] && echo /Applications || echo $(HOME)/Applications)
INSTALLED  := $(INSTALL_DIR)/$(APP_NAME).app

# Leftovers from 2.x (bare binary + LaunchAgent).
LEGACY_AGENT_LABEL := com.slapmacpro
LEGACY_AGENT := $(HOME)/Library/LaunchAgents/$(LEGACY_AGENT_LABEL).plist
LEGACY_BIN   := $(HOME)/Desktop/slapmac/bin/SlapMacPro

.PHONY: build app run debug test install uninstall release icon clean

build:
	swift build -c release

# Assemble and ad-hoc sign the .app bundle.
app: build
	@rm -rf "$(APP)"
	@mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	@cp .build/release/$(APP_NAME) "$(APP)/Contents/MacOS/$(APP_NAME)"
	@sed -e 's/__VERSION__/$(VERSION)/' -e 's/__BUILD__/$(BUILD)/' Resources/Info.plist > "$(APP)/Contents/Info.plist"
	@cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	@printf 'APPL????' > "$(APP)/Contents/PkgInfo"
	@codesign --force --sign - --timestamp=none "$(APP)"
	@echo "Built $(APP) ($(VERSION) build $(BUILD))"

# Run the bundle from dist/ with logs in this terminal.
run: app
	"$(APP)/Contents/MacOS/$(APP_NAME)"

debug:
	swift build
	.build/debug/$(APP_NAME)

test:
	swift test

install: app
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@launchctl bootout gui/$$(id -u)/$(LEGACY_AGENT_LABEL) 2>/dev/null || true
	@rm -f "$(LEGACY_AGENT)" "$(LEGACY_BIN)"
	@pkill -x SlapMacPro 2>/dev/null || true
	@mkdir -p "$(INSTALL_DIR)"
	@rm -rf "$(INSTALLED)"
	@ditto "$(APP)" "$(INSTALLED)"
	@xattr -dr com.apple.quarantine "$(INSTALLED)" 2>/dev/null || true
	@mkdir -p "$(HOME)/Library/Application Support/$(APP_NAME)/Sounds"
	@open "$(INSTALLED)"
	@echo "Installed $(INSTALLED) and launched it. It adds itself to Login Items on first launch."
	@echo "Sounds folder: ~/Library/Application Support/$(APP_NAME)/Sounds"
	@echo "Logs: ~/Library/Logs/$(APP_NAME)/$(APP_NAME).log"

uninstall:
	@for app in "/Applications/$(APP_NAME).app" "$(HOME)/Applications/$(APP_NAME).app"; do \
		if [ -x "$$app/Contents/MacOS/$(APP_NAME)" ]; then "$$app/Contents/MacOS/$(APP_NAME)" --unregister-login-item; fi; \
	done
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@rm -rf "/Applications/$(APP_NAME).app" "$(HOME)/Applications/$(APP_NAME).app"
	@launchctl bootout gui/$$(id -u)/$(LEGACY_AGENT_LABEL) 2>/dev/null || true
	@rm -f "$(LEGACY_AGENT)" "$(LEGACY_BIN)"
	@pkill -x SlapMacPro 2>/dev/null || true
	@echo "Uninstalled. Your sounds (~/Library/Application Support/$(APP_NAME)) and settings were kept."

# Zip for GitHub Releases: MacSlapApp.app + install.sh + README.
release: test app
	@rm -rf "$(DIST)/release" "$(RELEASE_ZIP)"
	@mkdir -p "$(DIST)/release/$(APP_NAME)-v$(VERSION)"
	@ditto "$(APP)" "$(DIST)/release/$(APP_NAME)-v$(VERSION)/$(APP_NAME).app"
	@cp install.sh README.md "$(DIST)/release/$(APP_NAME)-v$(VERSION)/"
	@cd "$(DIST)/release" && ditto -c -k --keepParent "$(APP_NAME)-v$(VERSION)" "../$(APP_NAME)-v$(VERSION).zip"
	@rm -rf "$(DIST)/release"
	@echo "Release archive: $(RELEASE_ZIP)"

icon:
	swift scripts/make-icon.swift

clean:
	swift package clean
	rm -rf .build $(DIST)
