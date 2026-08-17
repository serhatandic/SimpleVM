PROJECT := SimpleVM.xcodeproj
SCHEME := SimpleVM
DERIVED_DATA := $(CURDIR)/.build/DerivedData
TEST_DERIVED_DATA := $(CURDIR)/.build/TestDerivedData
APP := $(DERIVED_DATA)/Build/Products/Debug/SimpleVM.app
GIT_SAFE_ENV := GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all GIT_CONFIG_KEY_1=credential.interactive GIT_CONFIG_VALUE_1=never
PROVISIONING_HELPER := $(shell $(GIT_SAFE_ENV) swift build --package-path Tools/ProvisioningHelper --show-bin-path -c release)/SimpleVMProvisioningHelper
DEVELOPMENT_SIGN_IDENTITY := $(shell security find-identity -v -p codesigning | awk '/Apple Development/{print $$2; exit}')
SIGN_IDENTITY := $(if $(DEVELOPMENT_SIGN_IDENTITY),$(DEVELOPMENT_SIGN_IDENTITY),-)
XCODE_SIGNING := CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=$(SIGN_IDENTITY)
TEST_DESTINATION := platform=macOS,arch=arm64

.PHONY: project build test app-test ui-test run clean

project:
	xcodegen generate

build: project
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration Debug \
		-derivedDataPath "$(DERIVED_DATA)" \
		$(XCODE_SIGNING) \
		build
	$(GIT_SAFE_ENV) swift build --package-path Tools/ProvisioningHelper -c release
	mkdir -p "$(APP)/Contents/Helpers"
	cp "$(PROVISIONING_HELPER)" "$(APP)/Contents/Helpers/SimpleVMProvisioningHelper"
	codesign --force --sign "$(SIGN_IDENTITY)" --options runtime "$(APP)/Contents/Helpers/SimpleVMProvisioningHelper"
	codesign \
		--force \
		--sign "$(SIGN_IDENTITY)" \
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
		$(XCODE_SIGNING) \
		SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
		build

app-test: project
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration Debug \
		-derivedDataPath "$(TEST_DERIVED_DATA)" \
		-destination "$(TEST_DESTINATION)" \
		-parallel-testing-enabled NO \
		$(XCODE_SIGNING) \
		-only-testing:SimpleVMAppTests \
		test

ui-test: project
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration Debug \
		-derivedDataPath "$(TEST_DERIVED_DATA)" \
		-destination "$(TEST_DESTINATION)" \
		-parallel-testing-enabled NO \
		$(XCODE_SIGNING) \
		-only-testing:SimpleVMUITests \
		test

run: build
	open -n "$(APP)"

clean:
	rm -rf "$(DERIVED_DATA)"
	swift package --package-path Packages/SimpleVMCore clean
