# SimpleVM

<p align="center">
  <img
    src="docs/images/simplevm-omarchy-workspace.jpg"
    alt="SimpleVM running a tiled Omarchy workspace with btop and Files"
    width="100%"
  >
</p>

[![CI](https://github.com/serhatandic/SimpleVM/actions/workflows/ci.yml/badge.svg)](https://github.com/serhatandic/SimpleVM/actions/workflows/ci.yml)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black)](https://www.apple.com/macos/)
[![License: PolyForm Noncommercial 1.0.0](https://img.shields.io/badge/license-PolyForm%20Noncommercial%201.0.0-blue)](LICENSE.md)

SimpleVM is a focused, source-available Linux virtual machine manager for
Apple Silicon Macs. It uses Apple's Virtualization framework for native ARM64
guests and a QEMU/SPICE/Metal path for x86_64 compatibility.

> [!IMPORTANT]
> SimpleVM is currently a `0.1.0` source build. There is no signed DMG or
> notarized binary yet.

## Highlights

- Standard ARM64 EFI ISO installation with near-native Apple Virtualization
- x86_64 full-system emulation with QEMU TCG and a Metal-rendered SPICE display
- Immersive fullscreen that forwards macOS shortcuts and workspace swipes
- Host-derived guest resolution, absolute pointer input, and single-cursor mode
- Managed image imports and downloads with architecture detection and checksums
- Exportable library media and stopped-machine raw disks for migration
- Persistent disks, EFI state, snapshots, restore, and APFS-backed clones
- NAT networking, TCP port forwarding, and virtiofs directory sharing
- Rosetta support for Intel Linux binaries in supported ARM64 guests
- Preinstalled raw disks, rootfs archives, and OCI image provisioning

SimpleVM has been exercised with Ubuntu 26.04 ARM64 and Omarchy 4.0 x86_64.
Other standard Linux EFI installers may work, but are not yet part of the
release test matrix.

## Architecture

| Guest | Backend | CPU | Display |
| --- | --- | --- | --- |
| ARM64 Linux | Apple Virtualization | Hardware virtualization | `VZVirtualMachineView` |
| x86_64 Linux | QEMU | TCG software emulation | UTM QEMU, SPICE, CocoaSpice, Metal |

The x86_64 display path is GPU-accelerated, but its CPU remains fully emulated.
It is intended for compatibility and will not match native ARM64 performance.

## Requirements

### Host and toolchain

- Apple Silicon Mac
- macOS 15 or newer
- Xcode with Swift 6.2 or newer
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- GNU Make

### Runtime dependencies

- [UTM](https://mac.getutm.app/) installed at `/Applications/UTM.app`
  - Required by the current source build for its QEMU and SPICE frameworks
  - UTM 4.7.5 is the currently validated version
- [QEMU](https://www.qemu.org/) from Homebrew
  - Required for x86_64 disk tooling and the software-display fallback
- [Karabiner-Elements](https://karabiner-elements.pqrs.org/) for reliable
  macOS-style shortcut mapping in native ARM64 immersion

Karabiner-Elements is not required for ordinary windowed input or the QEMU
keyboard path.

## Build from source

```sh
brew install xcodegen qemu
brew install --cask utm

git clone https://github.com/serhatandic/SimpleVM.git
cd SimpleVM
make run
```

`project.yml` is the source of truth for the generated Xcode project.
`make build` also builds and embeds the separately signed rootfs/OCI
provisioning helper.

The generated project uses portable ad-hoc signing by default. If an Apple
Development identity is available, `make build` uses it when re-signing the
app and helper. A stable development identity prevents macOS from treating
each rebuild as a new app when granting Accessibility permission.

## Create a machine

1. Open **Images** in the sidebar.
2. Import a Linux EFI installer ISO, or download a catalog image.
3. Choose **New Machine...**, select the image, and configure CPU, memory,
   storage, sharing, and port forwarding.
4. Start the machine and complete the guest installer.
5. Shut the guest down, choose **Eject Installer**, and boot from its
   persistent disk.

Machine state is stored in:

```text
~/Library/Application Support/SimpleVM/
```

VM disks and installer media are intentionally excluded from Git.

### Export and migrate

- In **Images**, open an available image's action menu and choose
  **Export...**. The original media filename is preserved when possible.
- On a stopped machine, open **Machine actions** and choose
  **Export Disk...**. The result is a raw disk that can be brought into
  another SimpleVM installation with **Import Disk**.

Machine exports contain the disk only. CPU, memory, networking, EFI variables,
shares, snapshots, and other machine settings are not included.

## Immersion and permissions

Immersion removes the surrounding SimpleVM interface and routes host-level
keyboard and workspace input into the guest. The reserved exit chord is:

```text
Control + Option + Command + Escape
```

SimpleVM asks for macOS Accessibility permission when system-level input
capture is needed. That permission allows the app to intercept shortcuts such
as `Command+Tab` and suppress macOS workspace swipes while the guest is
immersive.

For Apple Virtualization guests, SimpleVM can install one app-scoped
Karabiner-Elements rule for reliable virtual-HID modifier delivery. The rule is
active only while SimpleVM immersion is active. SimpleVM does not need
Karabiner-Elements for QEMU guests.

### Hyprland and Karabiner-Elements

Use the **macOS-style Hyprland** keyboard profile for Omarchy and other
Hyprland guests. The setup depends on the VM backend:

- **QEMU / x86_64:** SimpleVM sends mapped key events directly through SPICE.
  Karabiner-Elements is not involved.
- **Apple Virtualization / ARM64:** Karabiner-Elements provides the virtual-HID
  modifiers that `VZVirtualMachineView` cannot reliably receive from synthetic
  AppKit events.

For an ARM64 Hyprland guest:

1. Install and open
   [Karabiner-Elements](https://karabiner-elements.pqrs.org/):

   ```sh
   brew install --cask karabiner-elements
   ```

2. Complete Karabiner-Elements' onboarding prompts. Allow its background
   services, Accessibility access, and DriverKit extension when macOS asks.
   On older Karabiner releases, macOS may also request Input Monitoring.
3. In **System Settings > General > Login Items & Extensions > Driver
   Extensions**, confirm the Karabiner virtual-HID driver is enabled.
4. Open **SimpleVM > Settings** and confirm:
   - **VZ Keyboard Mapping:** `Virtual HID ready`
   - **System input capture:** `Ready`
   - **Keyboard profile:** `macOS-style Hyprland`
5. Start the guest and choose **Enter Immersion**. SimpleVM creates or updates
   the `SimpleVM Immersion Mappings` rule and activates it only for the
   frontmost `com.simplevm.app` session.
6. Exit at any time with `Control+Option+Command+Escape`.

The Hyprland profile provides these host-friendly bindings:

| macOS input | Guest input | Hyprland action |
| --- | --- | --- |
| `Command+Return` | `Super+Return` | Open terminal |
| `Shift+Command+Return` | `Super+Shift+Return` | Open browser |
| `Shift+Command+F` | `Super+Shift+F` | Open file manager |
| `Shift+Command+N` | `Super+Shift+N` | Open editor |
| `Command+Space` | `Super+Space` | Open launcher |
| `Command+Tab` | `Alt+Tab` | Focus next window |
| `Shift+Command+Tab` | `Alt+Shift+Tab` | Focus previous window |
| `Command+Arrow` | `Super+Arrow` | Focus in a direction |
| `Shift+Command+Arrow` | `Super+Shift+Arrow` | Swap in a direction |
| `Control+Command+F` | `Super+F` | Toggle fullscreen |
| `Command+1...0` | `Super+1...0` | Switch workspace |
| Horizontal workspace swipe | Numbered workspace chord | Previous or next workspace |

Do not add a second set of manual Karabiner rules for these shortcuts.
Duplicate mappings can cause double key presses or stuck modifiers. SimpleVM
backs up `~/.config/karabiner/karabiner.json` before replacing its own scoped
rule.

If **Virtual HID ready** does not appear, open Karabiner-Elements once, finish
its permission prompts, verify that `Karabiner DriverKit VirtualHIDKeyboard`
appears in its connected devices, then relaunch SimpleVM. If mappings change,
exit and re-enter immersion so SimpleVM can regenerate the active profile.
See Karabiner-Elements'
[required macOS settings](https://karabiner-elements.pqrs.org/docs/manual/misc/required-macos-settings/)
for version-specific permission screens.

## Test

Run the platform-independent core suite:

```sh
swift test --package-path Packages/SimpleVMCore
```

Run the deterministic core suite and strict app build:

```sh
make test
```

Run app-hosted integration tests and UI automation separately:

```sh
make app-test
make ui-test
```

The hosted suites require the build dependencies above. XCTest injection can
take several minutes on first launch while macOS validates the external
frameworks. UI tests also require macOS Developer Mode and XCTest automation
approval.

An opt-in hardware smoke test can boot a real ARM64 EFI installer:

```sh
SIMPLEVM_ARM64_ISO_FIXTURE=/absolute/path/to/arm64-installer.iso \
  xcodebuild \
    -project SimpleVM.xcodeproj \
    -scheme SimpleVM \
    -derivedDataPath .build/DerivedData \
    -only-testing:SimpleVMAppTests/FoundationTests/testRealARM64EFIISOStaysRunningWithDisplayAttached \
    test
```

The fixture path and installer image remain local and are never committed.

## Current limitations

- Linux guests only
- Apple Silicon hosts only
- No prebuilt or notarized release artifact
- x86_64 CPU execution uses TCG software emulation
- The accelerated x86_64 build currently expects UTM in `/Applications`
- Guest tools are not installed automatically
- System workspace-swipe capture relies on macOS event behavior that may
  change between macOS releases

## License

SimpleVM's original code is available under the
[PolyForm Noncommercial License 1.0.0](LICENSE.md). It is source-available and
free for personal and other noncommercial use. Commercial use requires a
separate license from the copyright holder.

This is not an OSI-approved open-source license. Third-party components remain
under their own licenses; see [Third-Party Notices](THIRD_PARTY_NOTICES.md).

## Contributing

Bug reports and feature requests are welcome through GitHub Issues. To keep
commercial rights centralized, code pull requests are not currently accepted.
See [CONTRIBUTING.md](CONTRIBUTING.md) before opening an issue.

## Acknowledgments

SimpleVM builds on Apple's
[Virtualization framework](https://developer.apple.com/documentation/virtualization),
[UTM](https://github.com/utmapp/UTM),
[QEMU](https://www.qemu.org/),
[CocoaSpice](https://github.com/utmapp/CocoaSpice),
[Karabiner-Elements](https://github.com/pqrs-org/Karabiner-Elements), and
[Apple containerization](https://github.com/apple/containerization).
