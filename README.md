<img src="assets/icon.svg" width="64" height="64" alt="">

# Squish

A free, open-source macOS menu bar app that makes images smaller: lossless by default, metadata stripped, originals kept for restore. Inspired by Clop.

Status: **M1**. Manual optimization of PNG and JPEG (menu bar "Optimize Files…" or drag onto the menu panel), toast with restore, the full settings window, and settings sync. Clipboard watching (M2), folder watching (M3), SVG to PNG (M4), and video, audio and PDF (M5) are next.

Requires macOS 14 or later. Licensed under the [GNU GPL v3](LICENSE).

## Build

Everything is a Swift package, so Xcode is optional: Command Line Tools with Swift 6.2 or later work.

```sh
# 1. Build the bundled optimizers (one time, takes a few minutes)
brew install rustup cmake nasm && rustup-init -y
Scripts/build-tools.sh            # writes universal binaries to Vendor/bin

# 2. Build and run the app
Scripts/bundle.sh                 # writes build/Squish.app, ad-hoc signed
open build/Squish.app
```

For a quick loop without bundling: `SQUISH_BIN_DIR=$PWD/Vendor/bin swift run Squish`.

### Tests

```sh
swift test
```

With Command Line Tools only (no Xcode), the Swift Testing macro plugin has to be passed explicitly:

```sh
swift test -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

## Layout

| Path | Job |
|---|---|
| `Sources/SquishKit` | Settings model and JSON sync file, optimizer protocol and registry, PNG/JPEG optimizers, tool runner, pipeline with concurrency limit, backups |
| `Sources/Squish` | The menu bar app: `MenuBarExtra` panel, toast panel, settings window, settings store |
| `Tests/SquishKitTests` | Registry selection, settings decoding, pipeline replace/skip/error paths, JPEG orientation |
| `Scripts/build-tools.sh` | Builds pinned optimizer versions from source as universal binaries |
| `Scripts/bundle.sh` | Assembles and signs `Squish.app` |

## Settings sync

General › Sync settings writes a `settings.json` to a folder you pick: iCloud Drive, any OneDrive account under `~/Library/CloudStorage`, or any other folder. Each Mac checks the file every 15 seconds and the newest change wins. Watched folders are stored relative to your home folder (`~/Desktop`), so the same file works on every Mac. Pause, open at login and the choice of sync folder stay on each Mac.

When you turn sync on and the folder already has settings, Squish asks whether to use them or replace them.

## Bundled tools

| Tool | Version | License | Used for |
|---|---|---|---|
| [oxipng](https://github.com/oxipng/oxipng) | 10.2.1 | MIT | Lossless PNG |
| [pngquant](https://github.com/kornelski/pngquant) | 3.0.3 | GPL-3.0-or-later | Lossy PNG |
| [mozjpeg](https://github.com/mozilla/mozjpeg) (`jpegtran`, `cjpeg`) | 4.1.5 | IJG, BSD-3-Clause, zlib | JPEG |

Tools for GIF, WebP, SVG, video and PDF are added with their milestones. `Scripts/build-tools.sh` pins the exact source tags we ship.

## Releasing (Developer ID + notarization)

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" Scripts/bundle.sh
ditto -c -k --keepParent build/Squish.app build/Squish.zip
xcrun notarytool submit build/Squish.zip --keychain-profile squish-notary --wait
xcrun stapler staple build/Squish.app
```

Create the keychain profile once with `xcrun notarytool store-credentials squish-notary`. DMG packaging is part of M5.
