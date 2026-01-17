.PHONY: generate build run clean install

# Generate Xcode project from project.yml
generate:
	xcodegen generate

# Build the app
build: generate
	xcodebuild -project Obstickian.xcodeproj -scheme Obstickian -configuration Release build

# Build and run
run: generate
	xcodebuild -project Obstickian.xcodeproj -scheme Obstickian -configuration Debug build
	open build/Debug/Obstickian.app

# Clean build artifacts
clean:
	rm -rf build
	rm -rf Obstickian.xcodeproj

# Install to /Applications
install: build
	cp -r build/Release/Obstickian.app /Applications/
	@echo "Installed to /Applications/Obstickian.app"

# Development: rebuild and restart
dev: generate
	xcodebuild -project Obstickian.xcodeproj -scheme Obstickian -configuration Debug build
	pkill -x Obstickian || true
	open build/Debug/Obstickian.app
