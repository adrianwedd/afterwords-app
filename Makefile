.PHONY: project open build test clean

project:
	xcodegen generate

open: project
	open Afterwords.xcodeproj

build: project
	xcodebuild -project Afterwords.xcodeproj -scheme Afterwords -configuration Debug build

test: project
	xcodebuild test -project Afterwords.xcodeproj -scheme Afterwords -destination 'platform=macOS'

clean:
	rm -rf Afterwords.xcodeproj
	rm -rf build/