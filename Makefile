DERIVED    := .derived
XCODEBUILD := xcodebuild -project Modelr.xcodeproj -scheme Modelr \
              -derivedDataPath $(DERIVED)

.PHONY: run build release package test smoke gen clean

# Build (Debug) and launch the app
run: build
	open $(DERIVED)/Build/Products/Debug/Modelr.app

# Regenerate the Xcode project from project.yml
gen:
	xcodegen generate

build: gen
	$(XCODEBUILD) -configuration Debug CODE_SIGNING_ALLOWED=NO build

# Apple-silicon-only Release build (Float16 has no x86_64 slice).
# Ad-hoc signed like `build`, so a machine without the upstream team certificate can make an
# optimised build to run locally. Use `make release-signed` for a distributable one.
release: gen
	$(XCODEBUILD) -configuration Release ARCHS=arm64 \
		CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="-" build
	@echo "app: $(DERIVED)/Build/Products/Release/Modelr.app"

# Release build signed with the real team certificate (needed for `package`/distribution).
release-signed: gen
	$(XCODEBUILD) -configuration Release ARCHS=arm64 CODE_SIGNING_ALLOWED=YES build
	@echo "app: $(DERIVED)/Build/Products/Release/Modelr.app"

# Zip a signed Release app for distribution. `ditto` preserves the app bundle's
# metadata and resource forks, unlike a plain `zip` invocation.
package: release-signed
	rm -rf dist
	mkdir -p dist
	ditto -c -k --sequesterRsrc --keepParent \
		$(DERIVED)/Build/Products/Release/Modelr.app dist/Modelr.zip

test: gen
	$(XCODEBUILD) CODE_SIGNING_ALLOWED=NO test

# Headless self-drive: onboarding -> import -> generate -> paint -> export -> screenshots
smoke: build
	MODELR_UI_SMOKE=1 MODELR_SMOKE_MODEL=small \
	MODELR_SMOKE_OUT=$(CURDIR)/docs/e2e/smoke-make \
	$(DERIVED)/Build/Products/Debug/Modelr.app/Contents/MacOS/Modelr

clean:
	rm -rf $(DERIVED)
