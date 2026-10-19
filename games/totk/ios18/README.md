# TOTK iOS 18 / Metal 3 port

Source-only iOS port of the TOTK Metal 3 runtime in this repository. It builds a
sideloadable unsigned `.ipa` for iOS 18 / iPadOS 18 on Apple silicon devices.

This directory contains **no game code, keys, RomFS, shaders, AppIcon or prebuilt
libopus**. Build it with your own legally owned game files and your own toolchain.

## What is here

- `SourcesRuntime/` — UIKit launcher, virtual pad, save profile, settings
- `RuntimeOverlay/` — iOS frontend, iOS shader request path, build-patched v143 verification
- `Generated/embed.S` — template for the four rewritten game modules
- `InfoRuntime.plist` — app identity, landscape, Game Mode keys, file sharing
- `project.yml` — XcodeGen project for the `TOTK` target

## Build inputs you must supply

1. TOTK 1.4.3 and your own `prod.keys`.
2. The same rewritten module images used by the Mac M3 build:
   `main.{x0,w,x1}.bin`, `subsdk0.{x0,w,x1}.bin`, `sdk.{x0,w,x1}.bin` in
   `Generated/`. Generate `embed.S` with the project's `tools/gen_embed.py`
   (or edit the template) so the `.incbin` paths point at those files.
3. A device `libopus` static library at `Vendor/libopus-ios.a`, or build one
   from the vendored Opus source.
4. An optional `Resources/AppIcon.png`.

## Build

```sh
xcodegen generate
xcodebuild -project TOTKiOS.xcodeproj -scheme TOTK \
  -configuration Release -sdk iphoneos \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

The result is `build/Build/Products/Release-iphoneos/TOTK.app`; package it as
`Payload/TOTK.app` in a zip and sign with your sideloading tool.

## Known limitations

- Needs iOS/iPadOS 18+; Metal 3 compatibility path.
- The runtime still shows the upstream renderer warnings around
  block-compressed render targets, vpool fallbacks and texture upload fallbacks.
- 60 FPS is not stable on iPhone 16 Pro; 30 FPS is the recommended cap.
- No game data is included in this directory or this PR.
