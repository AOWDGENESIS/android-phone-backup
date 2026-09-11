# Changelog / Änderungsprotokoll

All notable changes to HandyKopie are documented here.
Format based on "Keep a Changelog". Dates in YYYY-MM-DD.

## [2.0.0] - 2026-09-11
### Added
- Turbo mode: copy via `adb pull` (much faster than MTP) for internal storage,
  with automatic fallback to MTP (SD card / missing adb).
- Incremental backup mode: skip files that already exist at the destination
  with same name and same size - no prompt, ideal for recurring backups.
- "Copy mode" group in the UI (Turbo / Incremental checkboxes).
- Multilingual repository: README and manual in DE, EN, FR, RU, ZH.
- GitHub-ready repository layout (app/, docs/, tools/, release/).

## [1.3.0] - 2026-09-08
### Added
- App manager: list third-party apps (adb) and uninstall them cleanly
  (pm uninstall + removal of leftover Android/data + Android/obb folders).
- adb (Android SDK Platform-Tools) bundled in `platform-tools/` - no separate
  installation required.

## [1.2.0] - 2026-09-08
### Added
- Filter search: checking a file type (images, videos, audio, APK, ...) scans
  the whole phone and lists all folders containing matches; open a folder,
  download single files (double click) or copy the whole folder.
- Thumbnail/icon view for the right-side browser (like Windows Explorer).
- System folders (Android, MIUI, cache, ...) hidden by default, toggleable.
- All copies are stored below `<destination>\<phone name>\`.
- Cleanup: category "outdated Android updates"; file counts in scan results;
  "clean app cache via adb (pm trim-caches)" button.

## [1.1.0] - 2026-09-07
### Added
- Cleanup dialog: thumbnails, app caches, temp folders with size scan and
  silent delete (SHFileOperation).
- Fault-tolerant per-file copy engine: errors are logged immediately to a
  temp TXT and the run continues with the next file (no blocking dialogs,
  flags 0x614, name sanitization).

## [1.0.0] - 2026-09-06
### Added
- Initial release: checkbox folder tree, internal/SD switch, right-side file
  browser, destination picker, live progress, duplicate prompt (yes/no),
  portable ZIP with launcher BAT.
