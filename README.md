# SimpleVM

SimpleVM is a native, distribution-neutral Linux virtual machine manager for
macOS on Apple Silicon.

The app supports:

- Generic ARM64 EFI ISO installation with Apple Virtualization
- x86_64 full-system compatibility through an external QEMU installation
- Managed preinstalled raw disks with APFS copy-on-write provisioning
- Rootfs archives and OCI images through a separately signed provisioning helper
- Rosetta sharing for supported ARM64 Linux guests
- Persistent machine disks, EFI state, snapshots, restore, and instant clones
- NAT networking, QEMU TCP port forwarding, virtiofs shares, and versioned
  guest-agent transports

## Development

Requirements:

- Apple Silicon Mac
- macOS 15 or newer
- Xcode 16 or newer
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- QEMU from Homebrew or a configured `SIMPLEVM_QEMU_PREFIX` for x86_64 guests

```sh
brew install xcodegen
make test
make run
```

`project.yml` is the source of truth for the generated Xcode project.
`make build` also builds, embeds, and signs the rootfs/OCI provisioning helper.

## Using the native ARM64 milestone

1. Launch SimpleVM with `make run`.
2. Open **Images** in the sidebar.
3. Import any ARM64 EFI installer ISO, or download the bundled Ubuntu catalog
   entry.
4. Choose **New Machine…**, select the installer, and configure CPU, memory, and
   disk.
5. Start the machine and complete the guest installer.
6. Shut the guest down, choose **Eject Installer**, then start it from its
   persistent system disk.

Local and catalog installer media use the same managed image, machine, storage,
and Apple Virtualization paths. x86_64 media is identified but requires the
future QEMU compatibility backend.

## ARM64 EFI hardware smoke test

The opt-in app-hosted test boots a real ARM64 EFI ISO and verifies graphical
framebuffer output. The fixture is never committed:

```sh
SIMPLEVM_ARM64_ISO_FIXTURE=/absolute/path/to/arm64-installer.iso \
  xcodebuild \
    -project SimpleVM.xcodeproj \
    -scheme SimpleVM \
    -derivedDataPath .build/DerivedData \
    -only-testing:SimpleVMAppTests/FoundationTests/testRealARM64EFIISOStaysRunningWithDisplayAttached \
    test
```
