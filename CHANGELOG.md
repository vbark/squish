# Changelog

All notable changes to Squish are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- The README shows a demo GIF and screenshots of the Stats, Folders, Formats and SVG pages, in `assets/readme`. They were captured from a separate demo copy of the app with sample files, so they hold no personal data.

## [1.2.0] - 2026-11-14

### Added

- **Stats page** (Settings › Stats), for today, this week, month, year or all time:
  - Bytes saved, with before → after sizes and the average reduction.
  - Fun equivalents: floppy disks, time saved on hotel Wi-Fi, iPhone photos' worth.
  - Files squished, files that were already perfect, time spent squishing, and the current and best daily streak.
  - Savings by kind (images, video, audio, PDF, SVG → PNG) and an activity chart by hour, day or month. Hover a bar for its numbers.
  - Records: the heaviest file, the best compression (files of 10 KB and up) and the biggest single saving.
  - Habits: your favorite time of day ("Night owl"), best day ever, top format, where files mostly come from, and the date you started squishing.
  - A heatmap of the last 30 weeks and a breakdown by Mac.
- **Stats sync** through the sync folder. Each Mac writes its own `Stats/<id>.json`, and the page adds them all up, so Macs never overwrite each other's numbers. Without sync the file stays in Application Support, and it moves into the sync folder when sync is turned on.
  - Restoring an original from the result card removes that file's savings.
  - **Reset This Mac…** clears only this Mac's stats.
- The menu shows today's saved total, counted across all sources, instead of the total for the current session.

### Fixed

- The settings window showed an opaque grey bar over the top of the page. SwiftUI's Settings window re-applied its own title bar style, which covered the page header. The title bar is now transparent through SwiftUI's toolbar modifiers, so the backdrop runs to the top edge and the traffic lights sit inside the sidebar.

### Changed

- **Faster: a screenshot saved to a watched folder is optimized in 1.2 s instead of 2.6 s** (measured with a 1600×1360 screenshot):
  - A new file is picked up once it has been unchanged for 0.5 s, checked every 0.25 s, instead of comparing two checks a full second apart. Files moved in from elsewhere, which keep their old date, are picked up at the first check. A file still being written is still never touched.
  - oxipng runs with `--zc 10` instead of its default compression level. This is about 40% faster on screenshots, for files about 1.5% larger.
- **Faster clipboard pickup.** The clipboard is checked every 0.15 s while you are using the keyboard or mouse, and less often only after 30 s without input. Before, it slowed to every 1–2 s when nothing had been copied for a while, so the first screenshot after a quiet spell could wait up to 2 s before Squish even noticed it.
- **Immediate feedback.** When a job takes longer than 0.3 s, a "Squishing…" card appears right away and is replaced by the result. If there was nothing to save, it disappears quietly.
- An SVG folder's sizes now render in parallel. SVG rendering also shares the optimizer's concurrency limit, so "Convert Existing" on hundreds of SVGs no longer starts hundreds of resvg processes at once.

### Technical

- Building from a fresh clone is two commands: `brew install rustup cmake nasm`, then `Scripts/bundle.sh`. `Scripts/bundle.sh` builds any missing bundled tool first, and `Scripts/build-tools.sh` sets up a Rust toolchain when Homebrew's rustup has none.
- The README's build requirement was wrong: the package needs Swift 6.2 (Xcode 26), not Xcode 16.

## [1.1.0] - 2026-11-14

### Added

- **Auto-convert SVG folders.** Settings › SVG › Auto-convert folders. Each folder has its own sizes (0.5×, 1×, 2×, 3×, several at once) and a Subfolders option. Every new or changed SVG gets a PNG next to it for each size, then the PNG is optimized. The SVG is kept.
  - A PNG you made yourself is never replaced, and no numbered copy (`icon 2.png`) is created next to it.
  - Changes that leave the drawing untouched, such as Finder tags or sync bookkeeping, don't render it again.
  - **Convert Existing** makes PNGs for the SVGs already in the folder.
- **Keyboard shortcuts.** A new Settings › Shortcuts page with a shortcut recorder for each action. The shortcuts work in any app:
  - Optimize the files selected in Finder.
  - Convert the SVGs selected in Finder to PNG. This opens the size picker; press Return for the default size.
  - Choose files to optimize.
  - Pause or resume automatic optimization.
- Shortcuts start empty, sync with the other settings, and warn when macOS or another app already owns the combination. Giving a combination to a second action takes it off the first.
- Finder access status on the Shortcuts page, with buttons to grant access or open Privacy & Security › Automation.
- The audio quality slider shows the resulting AAC bitrate.
- `CHANGELOG.md`.

### Changed

- **Redesigned settings window.** It now has a sidebar and a Tokyo Night look in dark mode (Tokyo Night Day in light mode), with Liquid Glass panels on macOS 26 and later and a translucent material on older systems.
  - The window is a fixed 800×680, so no page needs to scroll. Only a long list of watched folders scrolls.
  - The Formats page shows the mode and quality for each format on one line.
  - Segmented choices, file-type and size toggles, and buttons share one custom style instead of mixing with stock grey controls.
  - The Formats page notes suggested quality values: 80 as a starting point, 85–90 for PNG screenshots with text.
- Sync buttons on the General page wrap onto a second line when there are several OneDrive accounts.
- Watched folders nested inside another watched folder no longer produce duplicate events.

### Technical

- `Support/Info.plist` has an `NSAppleEventsUsageDescription`. `Support/Squish.entitlements` adds `com.apple.security.automation.apple-events`, which `Scripts/bundle.sh` signs into the app so hardened-runtime builds can read the Finder selection.
- Global shortcuts use Carbon's `RegisterEventHotKey`, so they need no Accessibility permission.
- The settings file gains `svgFolders` and `shortcuts`. Files from 1.0 load unchanged. Shortcut names this version doesn't know (from a newer version, through sync) are skipped instead of breaking the file.

## [1.0.0] - 2026-11-13

### Added

- Menu bar app with a recent-files list, drag and drop, pause, and restore from the result card.
- Optimization pipeline for PNG (oxipng, pngquant), JPEG (mozjpeg), GIF (gifsicle), WebP (cwebp), HEIC and TIFF, lossless by default with a lossy mode and quality per format.
- Video (HEVC via VideoToolbox), audio (AAC; MP3 tags only) and PDF (qpdf) optimization.
- Clipboard optimization. It skips concealed and transient items and its own writes, and turns copied TIFF into PNG.
- Folder monitoring with FSEvents. It waits for files to settle, ignores partial downloads and cloud placeholders, prevents loops, and keeps backups.
- SVG to PNG with resvg: a scale popup, a Finder Services menu item, and drag and drop.
- Settings sync through a `settings.json` in iCloud Drive, OneDrive or any folder.
- DMG packaging with optional Developer ID signing and notarization.

[Unreleased]: https://github.com/vbark/squish/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/vbark/squish/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/vbark/squish/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/vbark/squish/releases/tag/v1.0.0
