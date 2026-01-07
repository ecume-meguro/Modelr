.PHONY: generate build run clean setup-python

# Generate Xcode project from project.yml configuration
# Usage: make generate
generate:
	xcodegen generate

# Build the application for Debug configuration
# Prerequisites: Xcode project must exist (run 'make generate' first)
# Usage: make build
build: generate
	xcodebuild -project Modelr.xcodeproj -scheme Modelr -configuration Debug -derivedDataPath build build

# Build and run the application
# Usage: make run
run: build
	./build/Build/Products/Debug/Modelr.app/Contents/MacOS/Modelr
	
debug3d: build
	./build/Build/Products/Debug/Modelr.app/Contents/MacOS/Modelr --debug-3d-viewer

runsetup: build
	./build/Build/Products/Debug/Modelr.app/Contents/MacOS/Modelr --force-setup
	
# Run unit and integration tests
# Usage: make test
test: generate
	xcodebuild -project Modelr.xcodeproj -scheme ModelrTests -configuration Debug -derivedDataPath build test -destination 'platform=macOS'

# Clean build artifacts and generated Xcode project
# Usage: make clean
clean:
	rm -rf Modelr.xcodeproj
	rm -rf ModelrV3.xcodeproj
	rm -rf build

# Setup Python environment with uv (for development)
# Creates virtual environment and installs dependencies from Resources/pyproject.toml
# Usage: make setup-python
setup-python:
	mkdir -p build/uv_cache
	mkdir -p build/python_runtimes
	cd Resources && \
	UV_PROJECT_ENVIRONMENT=../build/.venv \
	UV_PYTHON_INSTALL_DIR=../build/python_runtimes \
	UV_CACHE_DIR=../build/uv_cache \
	UV_PYTHON_PREFERENCE=only-managed \
	uv sync
