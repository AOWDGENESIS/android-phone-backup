@echo off
rem ============================================================
rem  Handy-Kopie mit grafischer Oberflaeche (UI-Version)
rem  Baumansicht, Haekchen-Auswahl, Fortschritt, Duplikat-Frage
rem ============================================================
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0HandyKopieUI.ps1"
echo.
pause
