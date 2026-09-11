# HandyKopie – Android-Handy-Backup für Windows (MTP + adb)

**Sprache / Language:** [English](README.md) · [Deutsch](README.de.md) ·
[Français](README.fr.md) · [Русский](README.ru.md) · [中文](README.zh.md)

HandyKopie ist ein kostenloses, portables Windows-Tool, das Dateien von
Android-Handys (per USB/MTP, z. B. Xiaomi/Redmi) auf den PC kopiert – mit
Ordnerauswahl, Dateityp-Suche, Einzeldatei-Download, inkrementellem Backup,
schnellem adb-„Turbo"-Modus, Handy-Reinigung (Caches/Update-Reste) und einem
sauberen App-Deinstaller. Keine Installation, keine Cloud, keine Werbung –
alle Daten bleiben auf Ihrem PC.

> Sofort lauffähig: [`release/HandyKopie_UI.zip`](release/HandyKopie_UI.zip)
> (inkl. `adb`; SHA256 siehe [`release/SHA256SUMS.txt`](release/SHA256SUMS.txt))

## Funktionen

- **Ordnerauswahl-Baum** (links) mit Kontrollkästchen, inkl. Teilauswahl
  (abgewählte Unterordner werden ausgeschlossen).
- Umschaltung **Interner Speicher / SD-Karte**.
- **Browser rechts**: Ordner links anklicken und sofort dessen Dateien sehen;
  navigieren per Doppelklick und „Hoch".
- **Dateityp-Filter mit Handy-Suche**: z. B. *Bilder*, *Videos*, *Audio*,
  *APK*, *Dokumente* ankreuzen (oder eigene Endungen ergänzen) und
  „Handy durchsuchen" – alle Ordner mit Treffern werden aufgelistet; Ordner
  öffnen, **einzelne Datei** per Doppelklick herunterladen oder den ganzen
  Ordner kopieren.
- **Miniaturansicht** (große Symbole mit Vorschau, wie im Windows-Explorer).
- **Systemordner standardmäßig ausgeblendet** (Android, MIUI, Caches …) –
  per Häkchen einblendbar.
- **Turbo-Modus (adb pull)** – bei großen Datenmengen vielfach schneller als
  MTP (interner Speicher; sonst automatischer MTP-Rückfall).
- **Inkrementelles Backup** – beim Wiederholungslauf werden nur neue/geänderte
  Dateien übertragen; Duplikate (gleicher Name + Größe) ohne Nachfrage
  übersprungen.
- **Duplikat-Erkennung** mit klarer Ja/Nein-Frage (überschreiben oder
  überspringen).
- **Handy-Ordner im Ziel**: alles landet unter
  `<Ziel>\<Handyname>\…` – mehrere Geräte bleiben sauber getrennt.
- **Fehlertolerant**: Eine einzelne defekte Datei bricht den Lauf niemals ab –
  Fehler werden sofort in ein Temp-Protokoll geschrieben
  (`%TEMP%\HandyKopie_Fehler_*.txt`, wird danach automatisch geöffnet) und es
  geht mit der nächsten Datei weiter.
- **Reinigung** gegen ein langsames Handy: Miniaturansichten, App-Caches
  (per adb `pm trim-caches`, wenn Android sie für MTP ausblendet),
  Temp-Ordner und veraltete Android-Update-Reste – jeweils mit Größe **und
  Dateianzahl** angezeigt.
- **App-Verwaltung**: installierte Dritt-Apps auflisten und *sauber*
  deinstallieren (App + Restordner `Android/data` / `Android/obb`).
- **Fotos nach Aufnahmedatum sortiert**: JPGs werden zusätzlich unter `Fotos_sortiert\YYYY-MM` abgelegt (EXIF-Datum).
- **Live-Fortschritt** (Prozent, Dateizähler, aktuelle Datei) und
  funktionierender Abbrechen-Knopf.

## Voraussetzungen

- Windows 10/11 mit PowerShell 5.1 (in Windows enthalten).
- USB-Kabel; Handy entsperrt; USB-Modus „Dateiübertragung / MTP".
- Empfohlen: **USB-Debugging** aktivieren (Einstellungen → Über das Telefon →
  7× auf die Build-Nummer tippen → Entwickleroptionen → USB-Debugging) und
  diesem PC vertrauen – nötig für Turbo, Tiefenreinigung und App-Verwaltung.
- `adb` liegt bei (`platform-tools/`); falls gelöscht, lädt
  `tools/get_platform_tools.ps1` das offizielle Paket von Google.

## Schnellstart (3 Schritte)

1. [`release/HandyKopie_UI.zip`](release/HandyKopie_UI.zip) herunterladen und
   in **einen** Ordner entpacken (`platform-tools` darin lassen).
2. Handy anschließen (entsperrt, MTP), `Start_HandyKopie_UI.bat` doppelklicken.
3. Links Ordner ankreuzen, Ziel wählen, **Kopieren starten**.
   (Erste adb-Nutzung: am Handy „Diesem Computer vertrauen" bestätigen.)

## Dokumentation

- Vollständige Anleitung: [`docs/`](docs/) – `MANUAL.de.txt` usw.
- Quellcode: [`app/HandyKopieUI.ps1`](app/HandyKopieUI.ps1) (WinForms-
  PowerShell-App in einer Datei), Starter:
  [`app/Start_HandyKopie_UI.bat`](app/Start_HandyKopie_UI.bat)

## Sicherheit & Datenschutz

- Ihre Dateien verlassen den PC nie: direkte USB-Kopie, keine Cloud, keine
  Telemetrie.
- Reinigung und Deinstallation tasten System-Apps und persönliche Dateien
  nicht an; jede zerstörende Aktion fragt nach und wird protokolliert.
- Das Programm bricht nie still ab: Jeder Fehler wird mit Zeitstempel
  protokolliert.

## Lizenz & Drittkomponenten

- Eigener Code: **MIT** (siehe [`LICENSE`](LICENSE)).
- Beigelegte Android SDK Platform-Tools (adb): **Apache-2.0**,
  Copyright (C) Google LLC, unverändert verteilt (siehe [`NOTICE`](NOTICE)).

## Integrität prüfen

```powershell
Get-FileHash release\HandyKopie_UI.zip -Algorithm SHA256
# vergleichen mit release\SHA256SUMS.txt
```

## Änderungsprotokoll

Siehe [`CHANGELOG.md`](CHANGELOG.md).
