PROJECT := SimpleVM.xcodeproj
SCHEME := SimpleVM
DERIVED_DATA := $(CURDIR)/.build/DerivedData
APP := $(DERIVED_DATA)/Build/Products/Debug/SimpleVM.app

.PHONY: project build test run clean

project:
	xcodegen generate

build: project
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration Debug \
		-derivedDataPath "$(DERIVED_DATA)" \
		build
	codesign \
		--force \
		--sign - \
		--options runtime \
		--entitlements Config/SimpleVM.entitlements \
		"$(APP)"

test: project
	swift test --package-path Packages/SimpleVMCore
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration Debug \
		-derivedDataPath "$(DERIVED_DATA)" \
		test

run: build
	open -n "$(APP)"

clean:
	rm -rf "$(DERIVED_DATA)"
	swift package --package-path Packages/SimpleVMCore clean
