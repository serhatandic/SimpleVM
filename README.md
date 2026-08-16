# SimpleVM

SimpleVM is a native, distribution-neutral Linux virtual machine manager for
macOS on Apple Silicon.

The initial release focuses on generic ARM64 EFI ISO installation with Apple
Virtualization. QEMU-based x86_64 compatibility follows after the native path is
proven end to end.

## Development

Requirements:

- Apple Silicon Mac
- macOS 15 or newer
- Xcode 16 or newer
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

```sh
brew install xcodegen
make test
make run
```

`project.yml` is the source of truth for the generated Xcode project.

## ARM64 EFI hardware smoke test

The opt-in app-hosted test boots a real ARM64 EFI ISO and verifies graphical
framebuffer output. The fixture is never committed:

```sh
SIMPLEVM_ARM64_ISO_FIXTURE=/absolute/path/to/arm64-installer.iso \
  xcodebuild \
    -project SimpleVM.xcodeproj \
    -scheme SimpleVM \
    -derivedDataPath .build/DerivedData \
    -only-testing:SimpleVMAppTests/FoundationTests/testRealARM64EFIISOReachesGraphicalOutput \
    test
```
