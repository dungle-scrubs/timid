.PHONY: generate build run clean install

# Generate Xcode project from project.yml
generate:
	xcodegen generate

# Build the app
build: generate
	xcodebuild -project Timid.xcodeproj -scheme Timid -configuration Release build

# Build and run
run: generate
	xcodebuild -project Timid.xcodeproj -scheme Timid -configuration Debug build
	open build/Debug/Timid.app

# Clean build artifacts
clean:
	rm -rf build
	rm -rf Timid.xcodeproj

# Install to /Applications
install: build
	cp -r build/Release/Timid.app /Applications/
	@echo "Installed to /Applications/Timid.app"

# Development: rebuild and restart
dev: generate
	xcodebuild -project Timid.xcodeproj -scheme Timid -configuration Debug build
	pkill -x Timid || true
	open build/Debug/Timid.app
