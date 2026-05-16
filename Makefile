.PHONY: project open build test dmg clean

APP_NAME    := Afterwords
DMG_NAME    := $(APP_NAME).dmg
BUILD_DIR   := build/Release
STAGING_DIR := build/dmg-staging

project:
	xcodegen generate

open: project
	open Afterwords.xcodeproj

build: project
	xcodebuild -project Afterwords.xcodeproj -scheme Afterwords -configuration Debug build

test: project
	xcodebuild test -project Afterwords.xcodeproj -scheme Afterwords -destination 'platform=macOS'

dmg: project
	xcodebuild -project Afterwords.xcodeproj -scheme $(APP_NAME) -configuration Release \
		-derivedDataPath build/DerivedData build
	mkdir -p $(STAGING_DIR) $(BUILD_DIR)
	cp -r build/DerivedData/Build/Products/Release/$(APP_NAME).app $(STAGING_DIR)/
	ln -sf /Applications $(STAGING_DIR)/Applications
	hdiutil create -volname $(APP_NAME) -srcfolder $(STAGING_DIR) -ov \
		-format UDZO -o $(BUILD_DIR)/$(DMG_NAME)
	rm -rf $(STAGING_DIR)
	@echo "DMG ready: $(BUILD_DIR)/$(DMG_NAME)"

clean:
	rm -rf Afterwords.xcodeproj
	rm -rf build/