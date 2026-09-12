# Changelog / Änderungsprotokoll

All notable changes to HandyKopie are documented here.
Format based on "Keep a Changelog". Dates in YYYY-MM-DD.

## [2.1.3] - 2026-09-12
### Fixed
- Search ("browse phone") always died with a cryptic NULL error: the
  search worker code uses `$fs`, but the launcher was injecting the shared
  object as `fsync`. The worker now receives `fs` - search works.
- Turbo mode nested pulled folders doubly (e.g. `DCIM\DCIM\Camera`):
  `adb pull` places the source folder inside the target. Pull now goes to the
  parent directory; the structure matches the MTP copy.

### Verified
- New end-to-end harness (Linux): real worker script blocks in real
  runspaces, MTP simulated via a filesystem shell, adb as a fake
  executable. 30/30 assertions pass: MTP copy + duplicate dialog
  (yes/no), EXIF sort, turbo, single-file copy, filter search, app manager.

## [2.1.2] - 2026-09-11
### Fixed
- Copy worker crashed with "Sanitize-Seg not recognized": the helper was
  defined after its first use (PowerShell defines functions at runtime, in
  order). Definition moved to the top of the worker.
- App manager crashed with an Int32 conversion error: `count + ' text'`
  forces PowerShell to parse the text as a number. Now string-interpolated.
- Robustness against flaky MTP connections: NULL guards on every
  GetFolder/ParseName navigation step in copy, search, single-file copy,
  thumbnails, cleanup and browser - instead of cryptic NULL errors the UI
  now shows clear hints (e.g. "unlock phone").

## [2.1.1] - 2026-09-11
### Fixed
- Critical bugfix: the duplicate prompt (Ja/Nein dialog) was missing its
  worker function Ask-Dups - copies with duplicates in standard mode failed.
  Implemented with cancel-aware waiting; "No" answers are honored
  ([void] event reset prevents the overwrite flag from being clobbered).

## [2.1.0] - 2026-09-11
### Added
- EXIF photo sorting: after each copy run, copied JPGs are additionally filed
  by their real capture date into `Fotos_sortiert\YYYY-MM\` (checkbox
  "Sort photos by capture date"; incremental - existing files are skipped).

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
