DERIVED    := .derived
XCODEBUILD := xcodebuild -project Modelr.xcodeproj -scheme Modelr \
              -derivedDataPath $(DERIVED) CODE_SIGNING_ALLOWED=NO

.PHONY: run build release test smoke gen clean

# Build (Debug) and launch the app
run: build
	open $(DERIVED)/Build/Products/Debug/Modelr.app

# Regenerate the Xcode project from project.yml
gen:
	xcodegen generate

build: gen
	$(XCODEBUILD) -configuration Debug build

# Apple-silicon-only Release build (Float16 has no x86_64 slice)
release: gen
	$(XCODEBUILD) -configuration Release ARCHS=arm64 build
	@echo "app: $(DERIVED)/Build/Products/Release/Modelr.app"

test: gen
	$(XCODEBUILD) test

# Headless self-drive: onboarding -> import -> generate -> paint -> export -> screenshots
smoke: build
	MODELR_UI_SMOKE=1 MODELR_SMOKE_MODEL=small \
	MODELR_SMOKE_OUT=$(CURDIR)/docs/e2e/smoke-make \
	$(DERIVED)/Build/Products/Debug/Modelr.app/Contents/MacOS/Modelr

clean:
	rm -rf $(DERIVED)
