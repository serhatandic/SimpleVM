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

