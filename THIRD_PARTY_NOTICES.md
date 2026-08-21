# Third-Party Notices

SimpleVM's original code is licensed under the PolyForm Noncommercial License
1.0.0. The following third-party projects remain under their own licenses.

## Included source

### CocoaSpice

`Packages/CocoaSpice` is derived from
[utmapp/CocoaSpice](https://github.com/utmapp/CocoaSpice) and is distributed
under the Apache License 2.0. Its license is preserved at
[`Packages/CocoaSpice/LICENSE`](Packages/CocoaSpice/LICENSE).

The package also contains upstream compatibility headers. Copyright and
license notices in those files remain in place and continue to apply.

SimpleVM carries compatibility changes in:

- `CSDisplay+Renderer_Protected.h`
- `CSSession.m`
- `CSMetalRenderer.h`
- `CSMetalRenderer.m`

## External runtime and build dependencies

These projects are not relicensed by SimpleVM:

- [UTM](https://github.com/utmapp/UTM), used for QEMU and SPICE frameworks
- [QEMU](https://www.qemu.org/), used for Windows ARM64 virtualization,
  x86_64 emulation, firmware, and disk tooling
- [virtio-win](https://github.com/virtio-win/kvm-guest-drivers-windows),
  whose signed ARM64 drivers are extracted locally from the pinned UTM support
  image; its bundled license is preserved on generated media
- [swtpm](https://github.com/stefanberger/swtpm) and
  [libtpms](https://github.com/stefanberger/libtpms), used through UTM's
  framework for Windows TPM 2.0
- [SPICE](https://www.spice-space.org/) and
  [phodav](https://gitlab.gnome.org/GNOME/phodav), used for Windows display,
  clipboard, and WebDAV folder integration
- [TianoCore EDK II](https://github.com/tianocore/edk2), supplied through UTM
  for ARM UEFI and Secure Boot
- [Karabiner-Elements](https://github.com/pqrs-org/Karabiner-Elements), used
  for optional virtual-HID keyboard remapping
- [Apple containerization](https://github.com/apple/containerization), used
  by the provisioning helper
- [Swift System](https://github.com/apple/swift-system), used by the
  provisioning helper
- Apple's Virtualization framework, supplied by macOS

Users and redistributors are responsible for complying with the applicable
third-party license terms.
