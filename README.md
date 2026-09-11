# HandyKopie – Android phone backup for Windows (MTP + adb)

**Read this in / Lesen in / Lire en / Читать на / 阅读:**
[English](README.md) · [Deutsch](README.de.md) · [Français](README.fr.md) · [Русский](README.ru.md) · [中文](README.zh.md)

HandyKopie is a free, portable Windows tool that copies files from Android
phones (connected via USB/MTP, e.g. Xiaomi/Redmi) to your PC – with folder
selection, file-type search, single-file downloads, incremental backups,
a fast adb "Turbo" mode, phone cleanup (caches/update leftovers) and a clean
app uninstaller. No installation, no cloud, no ads – everything stays on your PC.

> Ready-to-run release: [`release/HandyKopie_UI.zip`](release/HandyKopie_UI.zip)
> (includes `adb`; SHA256 see [`release/SHA256SUMS.txt`](release/SHA256SUMS.txt))

## Features

- **Folder selection tree** (left) with checkboxes, including partial
  selection (unchecked subfolders are excluded).
- **Internal storage / SD card** switch.
- **Right-side browser**: click a folder on the left and instantly see its
  files; navigate with double click and "Up".
- **File-type filter with full-phone search**: tick e.g. *Images*, *Videos*,
  *Audio*, *APK*, *Documents* (or add your own extensions) and press
  "Search phone" – all folders containing matches are listed; open a folder,
  download a **single file** with a double click, or copy the whole folder.
- **Thumbnail view** (large icons with previews, like Windows Explorer).
- **System folders hidden by default** (Android, MIUI, caches …) – toggleable.
- **Turbo mode (adb pull)** – many times faster than MTP for large amounts
  of data (internal storage; automatic MTP fallback otherwise).
- **Incremental backup** – on repeat runs only new/changed files are
  transferred; duplicates (same name + size) are skipped without asking.
- **Duplicate detection** with a clear yes/no prompt (overwrite or skip).
- **Phone folder at destination**: everything is stored below
  `<destination>\<phone name>\…`, keeping several phones separate.
- **Fault tolerant**: a single bad file never aborts the run – errors are
  written immediately to a temp log (`%TEMP%\HandyKopie_Fehler_*.txt`,
  opened automatically afterwards) and copying continues.
- **Cleanup** against a slowing phone: thumbnails, app caches (via adb
  `pm trim-caches` when Android hides them from MTP), temp folders and
  outdated Android update leftovers – each shown with size **and file count**.
- **App manager**: list installed third-party apps and uninstall them
  *cleanly* (app + leftover `Android/data` / `Android/obb` folders).
- **Live progress** (percent, file counters, current file) and working
  cancel button.

## Requirements

- Windows 10/11 with PowerShell 5.1 (preinstalled on Windows).
- USB cable; phone unlocked; USB mode "File transfer / MTP".
- Optional but recommended: **USB debugging** enabled (Settings → About phone →
  tap build number 7× → Developer options → USB debugging) and trust this PC –
  needed for Turbo mode, cleanup-deep-clean and the app manager.
- `adb` is bundled (`platform-tools/`); if you delete it, `tools/get_platform_tools.ps1`
  downloads the official package from Google.

## Quick start (3 steps)

1. Download and extract [`release/HandyKopie_UI.zip`](release/HandyKopie_UI.zip)
   into **one** folder (keep `platform-tools` inside it).
2. Connect the phone (unlocked, MTP), double-click `Start_HandyKopie_UI.bat`.
3. Tick folders on the left, choose the destination, press **Copy**.
   (First adb use: confirm "trust this computer" on the phone.)

## Documentation

- Full manual: [`docs/`](docs/) – `MANUAL.de.txt`, `MANUAL.en.txt`,
  `MANUAL.fr.txt`, `MANUAL.ru.txt`, `MANUAL.zh.txt`
- Source: [`app/HandyKopieUI.ps1`](app/HandyKopieUI.ps1) (single-file WinForms
  PowerShell app), launcher: [`app/Start_HandyKopie_UI.bat`](app/Start_HandyKopie_UI.bat)

## Safety & privacy

- Your files never leave your PC: direct USB copy, no cloud, no telemetry.
- Cleanup and app uninstall never touch system apps or your personal files;
  every destructive action asks for confirmation and is logged.
- The program never aborts silently: every error is logged with timestamp.

## License & third-party components

- Own code: **MIT** (see [`LICENSE`](LICENSE)).
- Bundled Android SDK Platform-Tools (adb): **Apache-2.0**, Copyright (C)
  Google LLC, distributed unmodified (see [`NOTICE`](NOTICE)).

## Verify integrity

```powershell
Get-FileHash release\HandyKopie_UI.zip -Algorithm SHA256
# compare with release\SHA256SUMS.txt
```

## Changelog

See [`CHANGELOG.md`](CHANGELOG.md).
