.PHONY: generate build run clean setup-python

generate:
	xcodegen generate

build: generate
	xcodebuild -project ModelrV3.xcodeproj -scheme ModelrV3 -configuration Debug -derivedDataPath build build

run: build
	./build/Build/Products/Debug/ModelrV3.app/Contents/MacOS/ModelrV3

clean:
	rm -rf ModelrV3.xcodeproj
	rm -rf build

setup-python:
	mkdir -p build/uv_cache
	mkdir -p build/python_runtimes
	cd Resources && \
	UV_PROJECT_ENVIRONMENT=../build/.venv \
	UV_PYTHON_INSTALL_DIR=../build/python_runtimes \
	UV_CACHE_DIR=../build/uv_cache \
	UV_PYTHON_PREFERENCE=only-managed \
	uv sync
