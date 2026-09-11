param(
    [string]$PhoneMatch  = 'Redmi',
    [string]$DefaultDest = 'C:\Users\aowdg\Desktop\Neuer Ordner'
)

# --- Sicherheits-Relaunch: MTP/Shell-COM benoetigt einen STA-Thread ---
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $argList = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', '"' + $PSCommandPath + '"')
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList
    exit
}

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ======================= Konfiguration =======================
$cfgDir  = Join-Path $env:APPDATA 'HandyKopie'
$cfgPath = Join-Path $cfgDir 'config.json'
$cfg = $null
if (Test-Path $cfgPath) { try { $cfg = Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json } catch { $cfg = $null } }
$script:DestInit = if ($cfg -and $cfg.Dest) { $cfg.Dest } else { $DefaultDest }

# ======================= Gemeinsamer Zustand (UI <-> Worker) =======================
$sync = [hashtable]::Synchronized(@{
    Phase         = 'Idle'
    Log           = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
    ScanFiles     = 0
    ScanBytes     = [long]0
    ScanStatus    = ''
    TotalFiles    = 0
    TotalBytes    = [long]0
    DoneFiles     = 0
    DoneBytes     = [long]0
    SkippedFiles  = 0
    CurrentFolder = ''
    CurrentFile   = ''
    Question      = $null
    Answered      = $true
    OverwriteAnswer = $true
    DupSamples    = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
    Cancel        = $false
    Job           = $null
    ErrorMsg      = ''
    ErrorFile     = ''
    ErrorCount    = 0
    SortCount     = 0
})
$sync.QuestionEvent = New-Object System.Threading.ManualResetEvent($false)

function Log([string]$m) { $sync.Log.Enqueue((Get-Date).ToString('HH:mm:ss') + '  ' + $m) }
function Format-Size([long]$b) {
    if ($b -ge 1GB) { '{0:N2} GB' -f ($b / 1GB) }
    elseif ($b -ge 1MB) { '{0:N1} MB' -f ($b / 1MB) }
    elseif ($b -ge 1KB) { '{0:N0} KB' -f ($b / 1KB) }
    else { "$b B" }
}
function Sanitize-Seg([string]$s) {
    $x = [System.Text.RegularExpressions.Regex]::Replace($s, '[\\/:*?"<>|]', '_')
    $x = $x.TrimEnd(' ', '.')
    if ($x -eq '') { $x = '_' }
    $x
}
# Liefert die aktuelle Filter-Endungsliste (Hashtable) oder $null fuer 'Alle'.
# pendIdx/pendChecked: beruecksichtigt einen noch nicht angewendeten Klick (ItemCheck).
function Get-FilterExts([int]$pendIdx, $pendChecked) {
    $checkedAny = $false
    $states = @{}
    for ($i = 0; $i -lt $clbFilter.Items.Count; $i++) {
        $st = if ($i -eq $pendIdx) { ($pendChecked -eq $true) } else { $clbFilter.GetItemChecked($i) }
        $states[$i] = $st
        if ($st) { $checkedAny = $true }
    }
    if (-not $checkedAny) { return $null }
    if ($states[0]) { return $null }   # 'Alle Dateitypen'
    $set = @{}
    $idx = 0
    foreach ($k in $script:filterDefs.Keys) {
        if ($idx -gt 0 -and $states[$idx]) {
            foreach ($e in ($script:filterDefs[$k] -split ' ')) { if ($e) { $set[$e] = $true } }
        }
        $idx++
    }
    $extra = @($txtFilterExtra.Text -split '[,; ]+' | Where-Object { $_ })
    foreach ($e in $extra) { $set[($e.TrimStart('.').ToLower())] = $true }
    if ($set.Count -eq 0) { return $null }
    $set
}

# ======================= Worker (läuft in eigenem STA-Thread) =======================
$workerScript = {
    function WLog([string]$m) { $sync.Log.Enqueue((Get-Date).ToString('HH:mm:ss') + '  ' + $m) }
    function FmtSize([long]$b) {
        if ($b -ge 1GB) { '{0:N2} GB' -f ($b / 1GB) }
        elseif ($b -ge 1MB) { '{0:N1} MB' -f ($b / 1MB) }
        elseif ($b -ge 1KB) { '{0:N0} KB' -f ($b / 1KB) }
        else { "$b B" }
    }
    function Sanitize-Seg([string]$s) {
        $x = [System.Text.RegularExpressions.Regex]::Replace($s, '[\\/:*?"<>|]', '_')
        $x = $x.TrimEnd(' ', '.')
        if ($x -eq '') { $x = '_' }
        $x
    }
    function IsUnderHole([string]$relL, $holes) {
        foreach ($h in $holes) { if ($relL -eq $h -or $relL.StartsWith($h + '\')) { return $true } }
        return $false
    }
    function DirSize([string]$p) {
        $s = (Get-ChildItem -LiteralPath $p -Recurse -File -ErrorAction SilentlyContinue |
              Measure-Object -Property Length -Sum).Sum
        if ($null -eq $s) { [long]0 } else { [long]$s }
    }
    function EnumFolder($folder, [string]$rel, $t) {
        foreach ($item in $folder.Items()) {
            if ($sync.Cancel) { return }
            $name  = $item.Name
            $crel  = if ($rel) { $rel + '\' + $name } else { $name }
            $crelL = $crel.ToLower()
            if (IsUnderHole $crelL $t.Holes) { continue }
            if ($extFilter -and -not $item.IsFolder) {
                $di = $name.LastIndexOf('.')
                $ext = if ($di -ge 0) { $name.Substring($di + 1).ToLower() } else { '' }
                if (-not $extFilter.ContainsKey($ext)) { continue }
            }
            if ($item.IsFolder) {
                $gf = $item.GetFolder
                if ($gf) { EnumFolder $gf $crel $t }
            } else {
                $sz = [long]0
                try { $sz = [long]$item.Size } catch { }
                $target = (Join-Path (Join-Path $base $t.Name) $crel).ToLower()
                $isDup = $false
                if ($destMap.ContainsKey($target) -and $sz -gt 0 -and [long]$destMap[$target] -eq $sz) { $isDup = $true }
                [void]$t.Files.Add(@{ Rel = $crel; Size = $sz; Item = $item; Dup = $isDup })
                $t.Bytes = $t.Bytes + $sz
                if ($isDup) {
                    $t.Dups = $t.Dups + 1
                    $t.DupBytes = $t.DupBytes + $sz
                    if ($sync.DupSamples.Count -lt 10) { [void]$sync.DupSamples.Add(($t.Name + '\' + $crel)) }
                }
                $sync.ScanFiles  = $sync.ScanFiles + 1
                $sync.ScanBytes  = $sync.ScanBytes + $sz
                $sync.ScanStatus = $t.Name + '\' + $crel
            }
        }
    }

    function Ask-Dups([int]$n, [long]$bytes) {
        $sync.Question = $n.ToString('N0') + ' doppelte Datei(en) im Ziel gefunden (' + (FmtSize $bytes) + ').' + "`r`n`r`n" +
                         'Ja  = vorhandene Dateien ueberschreiben' + "`r`n" +
                         'Nein = Duplikate ueberspringen'
        $sync.OverwriteAnswer = $false
        $sync.Answered = $false
        $sync.Phase = 'Ask'
        [void]$sync.QuestionEvent.Reset()
        while (-not $sync.QuestionEvent.WaitOne(250)) {
            if ($sync.Cancel) { $sync.Question = $null; return $false }
        }
        $sync.Question = $null
        [bool]$sync.OverwriteAnswer
    }

    function Get-ExifDate([string]$path, [datetime]$fallback) {
        $img = $null
        try {
            $img = [System.Drawing.Image]::FromFile($path)
            foreach ($tag in @(0x9003, 0x0132)) {
                try {
                    $pi = $img.GetPropertyItem($tag)
                    $s = ([System.Text.Encoding]::ASCII.GetString($pi.Value)).Trim([char]0).Trim()
                    return [datetime]::ParseExact($s, 'yyyy:MM:dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
                } catch { }
            }
            return $fallback
        } catch {
            return $fallback
        } finally {
            if ($img) { $img.Dispose() }
        }
    }

    function Sort-Photos([string]$baseDir) {
        Add-Type -AssemblyName System.Drawing
        $sortedRoot = Join-Path $baseDir 'Fotos_sortiert'
        $count = 0
        $all = Get-ChildItem -LiteralPath $baseDir -Recurse -File -ErrorAction SilentlyContinue |
               Where-Object { ($_.Extension -in '.jpg', '.jpeg') -and ($_.FullName -notlike (Join-Path $sortedRoot '*')) }
        foreach ($fi in $all) {
            if ($sync.Cancel) { break }
            $dt = Get-ExifDate $fi.FullName $fi.LastWriteTime
            $dir = Join-Path $sortedRoot ($dt.ToString('yyyy-MM'))
            $dst = Join-Path $dir $fi.Name
            if (Test-Path -LiteralPath $dst) { continue }
            try {
                [void][System.IO.Directory]::CreateDirectory($dir)
                Copy-Item -LiteralPath $fi.FullName -Destination $dst -Force -ErrorAction Stop
                $count++
                $sync.CurrentFile = 'Sortiere: ' + $fi.Name
            } catch { }
        }
        $count
    }

    try {
        $job   = $sync.Job
        $shell = New-Object -ComObject Shell.Application
        $pc    = $shell.Namespace(17)
        $dev   = $pc.Items() | Where-Object { $_.IsFolder -and $_.Name -like "*$($job.PhoneMatch)*" } | Select-Object -First 1
        if (-not $dev) { throw 'Telefon nicht gefunden. USB-Verbindung und USB-Modus (Dateiübertragung) prüfen.' }
        $df  = $dev.GetFolder
        if (-not $df) { throw 'Telefon-Speicher nicht lesbar. Handy entsperrt und USB-Modus "Dateiuebertragung" aktiv?' }
        $vol = $df.Items() | Where-Object { $_.IsFolder -and $_.Name -eq $job.VolumeName } | Select-Object -First 1
        if (-not $vol) { throw "Speicherbereich '$($job.VolumeName)' nicht gefunden." }
        $volRoot = $vol.GetFolder
        if (-not $volRoot) { throw "Speicherbereich '$($job.VolumeName)' nicht lesbar." }

        # ---- uebergeordneter Handy-Ordner im Ziel ----
        $phoneDir = Sanitize-Seg $job.PhoneName
        $base = Join-Path $job.Dest $phoneDir
        if (-not (Test-Path -LiteralPath $base)) { New-Item -ItemType Directory -Path $base -Force | Out-Null }
        WLog ('Handy-Ordner im Ziel: ' + $base)

        # ---- Phase 1: Zielordner scannen (vorhandene Dateien) ----
        $sync.Phase = 'Scan'
        WLog 'Scanne Zielordner auf bereits vorhandene Dateien...'
        $destMap = @{}
        Get-ChildItem -LiteralPath $base -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            $destMap[$_.FullName.ToLower()] = $_.Length
        }
        WLog ('Zielordner enthält ' + $destMap.Count + ' vorhandene Dateien.')

        $extFilter = $job.FilterExts

        $incremental = [bool]$job.Incremental
        $turbo = [bool]($job.Turbo -and $job.AdbPath -and ($job.VolumeKind -eq 'internal'))
        if ($turbo) { WLog 'Turbo-Modus aktiv: adb pull statt MTP-Kopie.' }
        else { WLog 'MTP-Modus (Shell-Kopie).' }

        if ($turbo) {
            $tempRoot = Join-Path $env:TEMP ('HandyKopie_Turbo_' + (Get-Date).ToString('HHmmss'))
            [void][System.IO.Directory]::CreateDirectory($tempRoot)
            $tops = New-Object System.Collections.Generic.List[object]
            foreach ($s in $job.Selections) {
                if ($sync.Cancel) { break }
                $relPosix = ($s.Path -join '/')
                $src = '/storage/emulated/0/' + $relPosix
                $tempTop = Join-Path $tempRoot $s.Name
                [void][System.IO.Directory]::CreateDirectory($tempTop)
                $sync.Phase = 'Scan'
                $sync.ScanStatus = 'adb pull ' + $relPosix
                WLog ('Turbo: adb pull ' + $src + ' ...')
                $outF = Join-Path $env:TEMP 'handykopie_pull.txt'
                $errF = Join-Path $env:TEMP 'handykopie_pull_err.txt'
                $p = Start-Process -FilePath $job.AdbPath -ArgumentList @('pull', $src, $tempTop) -Wait -NoNewWindow -PassThru -RedirectStandardOutput $outF -RedirectStandardError $errF
                $po = ''; $pe = ''
                if (Test-Path -LiteralPath $outF) { $po = (Get-Content -Raw -LiteralPath $outF) }
                if (Test-Path -LiteralPath $errF) { $pe = (Get-Content -Raw -LiteralPath $errF) }
                if ($p.ExitCode -ne 0) {
                    $msg = 'adb pull fehlgeschlagen: ' + $src + '  (' + ($po + $pe).Trim() + ')'
                    $sync.ErrorCount = $sync.ErrorCount + 1
                    try { [System.IO.File]::AppendAllText($errFile, $msg + "`r`n", [System.Text.Encoding]::UTF8) } catch { }
                    WLog ('FEHLER: ' + $msg)
                    continue
                }
                foreach ($h in $s.Holes) {
                    $hWin = Join-Path $tempTop ($h -replace '/', '\')
                    if (Test-Path -LiteralPath $hWin) { Remove-Item -LiteralPath $hWin -Recurse -Force -ErrorAction SilentlyContinue }
                }
                if ($extFilter) {
                    Get-ChildItem -LiteralPath $tempTop -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
                        $di = $_.Name.LastIndexOf('.')
                        $ex2 = if ($di -ge 0) { $_.Name.Substring($di + 1).ToLower() } else { '' }
                        -not $extFilter.ContainsKey($ex2)
                    } | Remove-Item -Force -ErrorAction SilentlyContinue
                }
                $t = [pscustomobject]@{
                    Name = $s.Name; TempDir = $tempTop
                    Files = New-Object System.Collections.Generic.List[object]
                    Bytes = [long]0; Dups = 0; DupBytes = [long]0
                }
                Get-ChildItem -LiteralPath $tempTop -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
                    $relw = $_.FullName.Substring($tempTop.Length + 1)
                    $sz = $_.Length
                    $target = (Join-Path (Join-Path $base $s.Name) $relw).ToLower()
                    $isDup = ($destMap.ContainsKey($target) -and $sz -gt 0 -and [long]$destMap[$target] -eq $sz)
                    [void]$t.Files.Add(@{ Rel = $relw; Size = $sz; Dup = $isDup; TempFull = $_.FullName })
                    $t.Bytes = $t.Bytes + $sz
                    if ($isDup) {
                        $t.Dups = $t.Dups + 1; $t.DupBytes = $t.DupBytes + $sz
                        if ($sync.DupSamples.Count -lt 10) { [void]$sync.DupSamples.Add(($s.Name + '\' + $relw)) }
                    }
                    $sync.ScanFiles = $sync.ScanFiles + 1
                    $sync.ScanBytes = $sync.ScanBytes + $sz
                    $sync.ScanStatus = $s.Name + '\' + $relw
                }
                [void]$tops.Add($t)
                $sync.TotalFiles = $sync.TotalFiles + $t.Files.Count
                $sync.TotalBytes = $sync.TotalBytes + $t.Bytes
                WLog ('Turbo: ' + $s.Name + ' geholt (' + $t.Files.Count + ' Dateien, ' + (FmtSize $t.Bytes) + ')')
            }
            if ($tops.Count -eq 0) { throw 'Turbo: adb pull lieferte nichts. USB-Debugging aktiv? Diesem PC vertraut? Handy entsperrt?' }

            $totalDups = 0; $dupBytes = [long]0
            foreach ($t in $tops) { $totalDups += $t.Dups; $dupBytes += $t.DupBytes }
            $overwrite = $true
            if ($totalDups -gt 0) {
                if ($incremental) { $overwrite = $false; WLog ('Inkrementell: ' + $totalDups + ' Duplikate automatisch uebersprungen.') }
                else { $overwrite = Ask-Dups $totalDups $dupBytes }
            }

            $sync.Phase = 'Copy'
            foreach ($t in $tops) {
                if ($sync.Cancel) { break }
                $sync.CurrentFolder = $t.Name
                $targetDir = Join-Path $base $t.Name
                foreach ($f in $t.Files) {
                    if ($sync.Cancel) { break }
                    if (-not $overwrite -and $f.Dup) {
                        $sync.SkippedFiles = $sync.SkippedFiles + 1
                        $sync.DoneFiles = $sync.DoneFiles + 1
                        $sync.DoneBytes = $sync.DoneBytes + $f.Size
                        continue
                    }
                    $full = Join-Path $targetDir $f.Rel
                    try {
                        $dir = Split-Path -Parent $full
                        [void][System.IO.Directory]::CreateDirectory($dir)
                        Copy-Item -LiteralPath $f.TempFull -Destination $full -Force -ErrorAction Stop
                    } catch {
                        $sync.ErrorCount = $sync.ErrorCount + 1
                        $msg = ($t.Name + '\' + $f.Rel + '  ->  ' + $_.Exception.Message)
                        try { [System.IO.File]::AppendAllText($errFile, $msg + "`r`n", [System.Text.Encoding]::UTF8) } catch { }
                        WLog ('FEHLER, weiter mit naechster Datei: ' + $msg)
                    }
                    $sync.DoneBytes = $sync.DoneBytes + $f.Size
                    $sync.DoneFiles = $sync.DoneFiles + 1
                    $sync.CurrentFile = $t.Name + '\' + $f.Rel
                }
                WLog ('Fertig: ' + $t.Name)
            }
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            if (-not $sync.Cancel -and $job.ExifSort) {
                $sync.Phase = 'Sort'
                WLog 'Sortiere Fotos nach Aufnahmedatum (Jahr/Monat)...'
                $sync.SortCount = Sort-Photos $base
                WLog ('Fotos sortiert: ' + $sync.SortCount + ' neue Datei(en) nach Fotos_sortiert\Jahr-Monat.')
            }
            if ($sync.Cancel) { $sync.Phase = 'Canceled'; WLog 'Kopiervorgang abgebrochen.' }
            else { $sync.Phase = 'Done' }
        } else {

        # ---- ausgewählte Ordner auf dem Telefon suchen ----
        $tops = New-Object System.Collections.Generic.List[object]
        foreach ($s in $job.Selections) {
            if ($sync.Cancel) { throw 'Abbruch durch Benutzer.' }
            $parent = $volRoot
            $ok = $true
            for ($i = 0; $i -lt $s.Path.Count - 1; $i++) {
                $n = $parent.ParseName($s.Path[$i])
                if (-not $n -or -not $n.IsFolder) { WLog ("Ordner '" + $s.Path[$i] + "' nicht gefunden - Auswahl übersprungen."); $ok = $false; break }
                $parent = $n.GetFolder
                if (-not $parent) { WLog ("Ordner '" + $s.Path[$i] + "' nicht lesbar - Auswahl uebersprungen."); $ok = $false; break }
            }
            if (-not $ok) { continue }
            $topItem = $parent.ParseName($s.Path[$s.Path.Count - 1])
            if (-not $topItem -or -not $topItem.IsFolder) { WLog ("Auswahl '" + $s.Name + "' nicht gefunden - übersprungen."); continue }
            $tFolder = $topItem.GetFolder
            if (-not $tFolder) { WLog ("Auswahl '" + $s.Name + "' nicht lesbar - übersprungen."); continue }
            $t = [pscustomobject]@{
                Name     = $s.Name
                Item     = $topItem
                Folder   = $tFolder
                Holes    = $s.Holes
                Files    = New-Object System.Collections.Generic.List[object]
                Bytes    = [long]0
                Dups     = 0
                DupBytes = [long]0
            }
            $tops.Add($t)
        }
        if ($tops.Count -eq 0) { throw 'Keine gültigen Ordner auf dem Telefon gefunden.' }

        # ---- Phase 2: Telefon-Ordner scannen + Duplikate feststellen ----
        foreach ($t in $tops) {
            if ($sync.Cancel) { throw 'Abbruch durch Benutzer.' }
            WLog ('Scanne Telefon-Ordner: ' + $t.Name)
            EnumFolder $t.Folder '' $t
            $sync.TotalFiles = $sync.TotalFiles + $t.Files.Count
            $sync.TotalBytes = $sync.TotalBytes + $t.Bytes
        }
        WLog ('Scan fertig: ' + $sync.TotalFiles + ' Dateien, ' + (FmtSize $sync.TotalBytes))

        # ---- Phase 3: bei Duplikaten nachfragen ----
        $totalDups = 0; $dupBytes = [long]0
        foreach ($t in $tops) { $totalDups += $t.Dups; $dupBytes += $t.DupBytes }
        $overwrite = $true
        if ($totalDups -gt 0) {
            if ($job.Incremental) {
                $overwrite = $false
                WLog ('Inkrementell-Modus: ' + $totalDups + ' Duplikate werden automatisch uebersprungen.')
            } else {
                $overwrite = Ask-Dups $totalDups $dupBytes
            }
        }

        # ---- Phase 4: kopieren (Datei fuer Datei, FEHLERTOLERANT) ----
        # Kein Block-Modus mehr: Einzelne Fehler duerfen NIEMALS den ganzen
        # Vorgang stoppen. Fehler kommen sofort ins Fehlerprotokoll (temp-TXT).
        $sync.Phase = 'Copy'
        $done = [long]0
        $flags = 0x614   # SILENT + NOCONFIRMATION + NOERRORUI + NOCONFIRMMKDIR (keine Dialoge!)
        $errFile = Join-Path $env:TEMP ('HandyKopie_Fehler_' + (Get-Date).ToString('yyyy-MM-dd_HH-mm-ss') + '.txt')
        $sync.ErrorFile = $errFile
        $errCount = 0
        [System.IO.File]::WriteAllText($errFile, ('HandyKopie Fehlerprotokoll vom ' + (Get-Date).ToString() + "`r`n" + 'Ziel: ' + $job.Dest + "`r`n`r`n"), [System.Text.Encoding]::UTF8)
        foreach ($t in $tops) {
            if ($sync.Cancel) { break }
            $sync.CurrentFolder = $t.Name
            $targetDir = Join-Path $base $t.Name
            if (-not (Test-Path -LiteralPath $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
            $modeTxt = if ($overwrite) { 'vorhandene werden ueberschrieben' } else { 'Duplikate werden uebersprungen' }
            WLog ('Kopiere ' + $t.Name + ' Datei fuer Datei (' + $t.Files.Count + ' Dateien, ' + (FmtSize $t.Bytes) + ', ' + $modeTxt + ') ...')
            $dirCache = @{}
            foreach ($f in $t.Files) {
                if ($sync.Cancel) { break }
                if (-not $overwrite -and $f.Dup) {
                    $sync.SkippedFiles = $sync.SkippedFiles + 1
                    $sync.DoneFiles    = $sync.DoneFiles + 1
                    continue
                }
                $relSafe = @($f.Rel.Split('\') | ForEach-Object { Sanitize-Seg $_ }) -join '\'
                $full = Join-Path $targetDir $relSafe
                $dir  = Split-Path -Parent $full
                try {
                    if (-not $dirCache.ContainsKey($dir)) {
                        [void][System.IO.Directory]::CreateDirectory($dir)
                        $dirCache[$dir] = $shell.Namespace($dir)
                    }
                    $ns = $dirCache[$dir]
                    if (-not $ns) { throw 'Zielordner nicht verfuegbar: ' + $dir }
                    $ns.CopyHere($f.Item, $flags)
                    if (-not (Test-Path -LiteralPath $full)) {
                        throw 'Datei nach Kopie nicht vorhanden (Name fuer Windows ungueltig oder Datei auf dem Telefon gesperrt).'
                    }
                } catch {
                    $errCount++
                    $msg = ($t.Name + '\' + $f.Rel + '  ->  ' + $_.Exception.Message)
                    try { [System.IO.File]::AppendAllText($errFile, $msg + "`r`n", [System.Text.Encoding]::UTF8) } catch { }
                    WLog ('FEHLER, werde mit naechster Datei fortgesetzt: ' + $msg)
                }
                $done = $done + $f.Size
                $sync.DoneBytes = $done
                $sync.DoneFiles = $sync.DoneFiles + 1
                $sync.CurrentFile = $t.Name + '\' + $f.Rel
            }
            WLog ('Fertig: ' + $t.Name)
        }
        $sync.ErrorCount = $errCount
        if ($errCount -gt 0) { WLog ($errCount + ' Fehler - Protokoll: ' + $errFile) }
        if (-not $sync.Cancel -and $job.ExifSort) {
            $sync.Phase = 'Sort'
            WLog 'Sortiere Fotos nach Aufnahmedatum (Jahr/Monat)...'
            $sync.SortCount = Sort-Photos $base
            WLog ('Fotos sortiert: ' + $sync.SortCount + ' neue Datei(en) nach Fotos_sortiert\Jahr-Monat.')
        }
        if ($sync.Cancel) { $sync.Phase = 'Canceled'; WLog 'Kopiervorgang abgebrochen.' }
        else              { $sync.Phase = 'Done' }
        } # Ende MTP-Zweig

    } catch {
        $sync.ErrorMsg = $_.Exception.Message
        $sync.Phase = 'Error'
        WLog ('FEHLER: ' + $_.Exception.Message)
    }
}

function Start-Worker {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync', $sync)
    $script:workerPS = [powershell]::Create()
    $script:workerPS.Runspace = $rs
    [void]$script:workerPS.AddScript($workerScript.ToString())
    $script:workerHandle = $script:workerPS.BeginInvoke()
}

# ======================= Filter-Suche (Hintergrund) =======================
$fsync = [hashtable]::Synchronized(@{
    Phase  = 'Idle'
    Status = ''
    Job    = $null
    Map    = $null
    List   = $null
    Files  = 0
    Folders = 0
    Error  = ''
})

$searchScript = {
    function SScan($folder, [string]$rel, $map, $exts, $fs, $hideSys) {
        foreach ($item in $folder.Items()) {
            $name = $item.Name
            $crel = if ($rel) { $rel + '\' + $name } else { $name }
            if ($item.IsFolder) {
                if ($hideSys -and ($fs.SysNames -contains $name.ToLower())) { continue }
                $gf = $item.GetFolder
                if ($gf) { try { SScan $gf $crel $map $exts $fs $hideSys } catch { } }
            } else {
                $di = $name.LastIndexOf('.')
                $ext = if ($di -ge 0) { $name.Substring($di + 1).ToLower() } else { '' }
                if ($exts.ContainsKey($ext)) {
                    $key = $rel.ToLower()
                    if (-not $map.ContainsKey($key)) { $map[$key] = @{ Rel = $rel; Files = New-Object System.Collections.Generic.List[object]; Bytes = [long]0 } }
                    $sz = [long]0
                    try { $sz = [long]$item.Size } catch { }
                    [void]$map[$key].Files.Add(@{ Name = $name; Size = $sz })
                    $map[$key].Bytes = $map[$key].Bytes + $sz
                    $fs.Files = $fs.Files + 1
                    if (($fs.Files % 50) -eq 0) { $fs.Status = $crel }
                }
            }
        }
    }
    try {
        $fs.Phase = 'Scan'
        $job = $fs.Job
        $shell = New-Object -ComObject Shell.Application
        $pc = $shell.Namespace(17)
        $dev = $pc.Items() | Where-Object { $_.IsFolder -and $_.Name -like "*$($job.PhoneMatch)*" } | Select-Object -First 1
        if (-not $dev) { throw 'Telefon nicht gefunden.' }
        $vol = $dev.GetFolder.Items() | Where-Object { $_.IsFolder -and $_.Name -eq $job.VolumeName } | Select-Object -First 1
        if (-not $vol) { throw 'Speicherbereich nicht gefunden.' }
        $vr = $vol.GetFolder
        if (-not $vr) { throw 'Speicherbereich nicht lesbar. Handy ggf. entsperren und erneut versuchen.' }
        $map = @{}
        SScan $vr '' $map $job.Exts $fs $job.HideSys
        $fs.Map = $map
        $fs.Folders = $map.Count
        $fs.Phase = 'Done'
    } catch {
        $fs.Error = $_.Exception.Message
        $fs.Phase = 'Error'
    }
}

function Start-Search($extsOverride) {
    if ($script:busy -or $script:searching) { return }
    if ($script:volIndex -lt 0) { return }
    $exts = if ($extsOverride) { $extsOverride } else { Get-FilterExts -1 $false }
    if (-not $exts) { return }
    $script:extSetUI = $exts
    $fsync.Job = @{ PhoneMatch = $PhoneMatch; VolumeName = $script:volumes[$script:volIndex].Name; Exts = $exts; HideSys = (-not $script:showSys); SysNames = $script:sysNames }
    $fsync.Phase = 'Scan'; $fsync.Status = ''; $fsync.Error = ''
    $fsync.Files = 0; $fsync.Folders = 0; $fsync.Map = $null
    $script:searching = $true
    $lblSearchInfo.Text = 'Filter-Suche laeuft auf dem ganzen Speicher...'
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('fsync', $fsync)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($searchScript.ToString())
    [void]$ps.BeginInvoke()
}

# ======================= Einzel-Dateien kopieren (Hintergrund) =======================
$fileCopyScript = {
    function WLog([string]$m) { $sync.Log.Enqueue((Get-Date).ToString('HH:mm:ss') + '  ' + $m) }
    function Sanitize-Seg([string]$s) {
        $x = [System.Text.RegularExpressions.Regex]::Replace($s, '[\\/:*?"<>|]', '_')
        $x = $x.TrimEnd(' ', '.')
        if ($x -eq '') { $x = '_' }
        $x
    }
    try {
        $job = $sync.Job
        $phoneDir = Sanitize-Seg $job.PhoneName
        $base = Join-Path $job.Dest $phoneDir
        if (-not (Test-Path -LiteralPath $base)) { New-Item -ItemType Directory -Path $base -Force | Out-Null }
        $errFile = Join-Path $env:TEMP ('HandyKopie_Fehler_' + (Get-Date).ToString('yyyy-MM-dd_HH-mm-ss') + '.txt')
        $sync.ErrorFile = $errFile
        $errCount = 0
        [System.IO.File]::WriteAllText($errFile, ('HandyKopie Fehlerprotokoll vom ' + (Get-Date).ToString() + "`r`n" + 'Ziel: ' + $base + "`r`n`r`n"), [System.Text.Encoding]::UTF8)

        $shell = New-Object -ComObject Shell.Application
        $pc = $shell.Namespace(17)
        $dev = $pc.Items() | Where-Object { $_.IsFolder -and $_.Name -like "*$($job.PhoneMatch)*" } | Select-Object -First 1
        if (-not $dev) { throw 'Telefon nicht gefunden.' }
        $vol = $dev.GetFolder.Items() | Where-Object { $_.IsFolder -and $_.Name -eq $job.VolumeName } | Select-Object -First 1
        if (-not $vol) { throw 'Speicherbereich nicht gefunden.' }
        $volRoot = $vol.GetFolder
        if (-not $volRoot) { throw 'Speicherbereich nicht lesbar.' }

        # Dateien aufloesen
        $files = New-Object System.Collections.Generic.List[object]
        $totalBytes = [long]0
        foreach ($rel in $job.Files) {
            $segs = @($rel.Split('\') | Where-Object { $_ })
            $parent = $volRoot
            $ok = $true
            for ($i = 0; $i -lt $segs.Count - 1; $i++) {
                $n = $parent.ParseName($segs[$i])
                if (-not $n -or -not $n.IsFolder) { $ok = $false; break }
                $parent = $n.GetFolder
                if (-not $parent) { $ok = $false; break }
            }
            $fname = $segs[$segs.Count - 1]
            $it = $null
            if ($ok) { $it = $parent.ParseName($fname) }
            if (-not $it -or $it.IsFolder) {
                $errCount++
                $msg = $rel + '  ->  Datei auf dem Telefon nicht (mehr) vorhanden.'
                try { [System.IO.File]::AppendAllText($errFile, $msg + "`r`n", [System.Text.Encoding]::UTF8) } catch { }
                WLog ('FEHLER, continue: ' + $msg)
                continue
            }
            $sz = [long]0
            try { $sz = [long]$it.Size } catch { }
            [void]$files.Add(@{ Rel = $rel; Item = $it; Size = $sz; Name = $fname })
            $totalBytes = $totalBytes + $sz
        }

        $sync.Phase = 'Copy'
        $sync.TotalFiles = $files.Count
        $sync.TotalBytes = $totalBytes
        $flags = 0x614
        $dirCache = @{}
        $done = [long]0
        foreach ($f in $files) {
            if ($sync.Cancel) { break }
            $segs = @($f.Rel.Split('\') | Where-Object { $_ })
            $dirSegs = if ($segs.Count -gt 1) { @($segs[0..($segs.Count - 2)]) } else { @() }
            $relDirSafe = @($dirSegs | ForEach-Object { Sanitize-Seg $_ }) -join '\'
            $safeName = Sanitize-Seg $f.Name
            $dir = if ($relDirSafe) { Join-Path $base $relDirSafe } else { $base }
            $full = Join-Path $dir $safeName
            $sync.CurrentFile = $f.Rel
            $sync.CurrentFolder = $f.Name
            try {
                if (-not $dirCache.ContainsKey($dir)) {
                    [void][System.IO.Directory]::CreateDirectory($dir)
                    $dirCache[$dir] = $shell.Namespace($dir)
                }
                $ns = $dirCache[$dir]
                if (-not $ns) { throw 'Zielordner nicht verfuegbar: ' + $dir }
                $ns.CopyHere($f.Item, $flags)
                if (-not (Test-Path -LiteralPath $full)) {
                    throw 'Datei nach Kopie nicht vorhanden (Name fuer Windows ungueltig oder Datei gesperrt).'
                }
            } catch {
                $errCount++
                $msg = ($f.Rel + '  ->  ' + $_.Exception.Message)
                try { [System.IO.File]::AppendAllText($errFile, $msg + "`r`n", [System.Text.Encoding]::UTF8) } catch { }
                WLog ('FEHLER, werde mit naechster Datei fortgesetzt: ' + $msg)
            }
            $done = $done + $f.Size
            $sync.DoneBytes = $done
            $sync.DoneFiles = $sync.DoneFiles + 1
        }
        $sync.ErrorCount = $errCount
        if ($sync.Cancel) { $sync.Phase = 'Canceled'; WLog 'Kopiervorgang abgebrochen.' }
        else { $sync.Phase = 'Done' }
    } catch {
        $sync.ErrorMsg = $_.Exception.Message
        $sync.Phase = 'Error'
        WLog ('FEHLER: ' + $_.Exception.Message)
    }
}

function Start-FileCopy($relPaths) {
    if ($script:busy) { return }
    if ($script:volIndex -lt 0) { return }
    if (-not $relPaths -or $relPaths.Count -eq 0) { return }
    $dest = $txtDest.Text.Trim()
    if (-not $dest) { return }
    try { if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null } } catch { return }
    Save-Config
    $sync.Phase = 'Scan'; $sync.Cancel = $false
    $sync.ScanFiles = 0; $sync.ScanBytes = [long]0; $sync.ScanStatus = ''
    $sync.TotalFiles = 0; $sync.TotalBytes = [long]0
    $sync.DoneFiles = 0; $sync.DoneBytes = [long]0; $sync.SkippedFiles = 0
    $sync.CurrentFolder = ''; $sync.CurrentFile = ''
    $sync.ErrorMsg = ''; $sync.ErrorFile = ''; $sync.ErrorCount = 0
    $sync.Question = $null; $sync.Answered = $true
    $sync.DupSamples.Clear()
    $pbOverall.Value = 0; $pbOverall.Style = 'Marquee'
    $lblOverall.Text = ''; $lblDetail.Text = ''; $lblFile.Text = ''
    $script:notified = $false
    $sync.Job = @{
        PhoneMatch = $PhoneMatch
        VolumeName = $script:volumes[$script:volIndex].Name
        Dest       = $dest
        PhoneName  = $(if ($script:phoneName) { $script:phoneName } else { $PhoneMatch })
        Files      = @($relPaths)
    }
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync', $sync)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($fileCopyScript.ToString())
    [void]$ps.BeginInvoke()
    $script:busy = $true
    $btnStart.Enabled = $false
    $btnCancel.Enabled = $true
    $tree.Enabled = $false
    Log ('Einzelkopie: ' + $relPaths.Count + ' Datei(en) -> ' + $dest)
}

# ======================= Miniaturansichten (Hintergrund) =======================
$tsync = [hashtable]::Synchronized(@{
    Q     = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
    Job   = $null
    Phase = 'Idle'
})

$thumbScript = {
    try {
        Add-Type -AssemblyName System.Drawing
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ThumbHelper {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int SHCreateItemFromParsingName(string path, IntPtr pbc, ref Guid riid, out IntPtr ppv);
    [DllImport("gdi32.dll")]
    public static extern bool DeleteObject(IntPtr h);
    [ComImport, Guid("BCC18B79-BA16-442F-80C4-8A59C30C463B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IShellItemImageFactory {
        [PreserveSig] int GetImage(SIZE size, int flags, out IntPtr hbitmap);
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct SIZE { public int cx; public int cy; }
    public static System.Drawing.Image GetThumb(string path, int px) {
        Guid iidItem = new Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe");
        IntPtr pItem = IntPtr.Zero;
        int hr = SHCreateItemFromParsingName(path, IntPtr.Zero, ref iidItem, out pItem);
        if (hr != 0 || pItem == IntPtr.Zero) return null;
        try {
            Guid iidFac = new Guid("BCC18B79-BA16-442F-80C4-8A59C30C463B");
            IntPtr pFac = IntPtr.Zero;
            hr = Marshal.QueryInterface(pItem, ref iidFac, out pFac);
            if (hr != 0 || pFac == IntPtr.Zero) return null;
            try {
                IShellItemImageFactory fac = (IShellItemImageFactory)Marshal.GetObjectForIUnknown(pFac);
                SIZE sz = new SIZE(); sz.cx = px; sz.cy = px;
                IntPtr hb = IntPtr.Zero;
                hr = fac.GetImage(sz, 0, out hb);
                if (hr != 0 || hb == IntPtr.Zero) return null;
                System.Drawing.Image bmp = System.Drawing.Image.FromHbitmap(hb);
                DeleteObject(hb);
                return bmp;
            } finally { Marshal.Release(pFac); }
        } finally { Marshal.Release(pItem); }
    }
}
'@
        $job = $tsync.Job
        $shell = New-Object -ComObject Shell.Application
        $pc = $shell.Namespace(17)
        $dev = $pc.Items() | Where-Object { $_.IsFolder -and $_.Name -like "*$($job.PhoneMatch)*" } | Select-Object -First 1
        if (-not $dev) { $tsync.Phase = 'Done'; return }
        $vol = $dev.GetFolder.Items() | Where-Object { $_.IsFolder -and $_.Name -eq $job.VolumeName } | Select-Object -First 1
        if (-not $vol) { $tsync.Phase = 'Done'; return }
        $f = $vol.GetFolder
        if (-not $f) { $tsync.Phase = 'Done'; return }
        foreach ($seg in $job.Base) {
            $n = $f.ParseName($seg)
            if (-not $n -or -not $n.IsFolder) { $tsync.Phase = 'Done'; return }
            $f = $n.GetFolder
            if (-not $f) { $tsync.Phase = 'Done'; return }
        }
        foreach ($nm in $job.Names) {
            try {
                $it = $f.ParseName($nm)
                if (-not $it -or $it.IsFolder) { continue }
                $bmp = [ThumbHelper]::GetThumb($it.Path, 96)
                if ($bmp) { $tsync.Q.Enqueue(@{ N = $nm; B = $bmp }) }
            } catch { }
        }
        $tsync.Phase = 'Done'
    } catch { $tsync.Phase = 'Done' }
}

function Start-ThumbWorker($baseArr, $names) {
    if (-not $script:iconView) { return }
    $names = @($names | Select-Object -First 120)
    if ($names.Count -eq 0 -or $script:volIndex -lt 0) { return }
    while ($tsync.Q.Count -gt 0) { [void]$tsync.Q.Dequeue() }
    $tsync.Job = @{ PhoneMatch = $PhoneMatch; VolumeName = $script:volumes[$script:volIndex].Name; Base = @($baseArr); Names = $names }
    $tsync.Phase = 'Scan'
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('tsync', $tsync)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($thumbScript.ToString())
    [void]$ps.BeginInvoke()
}

function Make-Placeholder([string]$ext) {
    $bmp = New-Object Drawing.Bitmap(96, 96)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.Clear([Drawing.Color]::FromArgb(240, 240, 245))
    $g.DrawRectangle([Drawing.Pens]::Gray, 4, 4, 87, 87)
    $font = New-Object Drawing.Font('Segoe UI', 14, [Drawing.FontStyle]::Bold)
    $sf = New-Object Drawing.StringFormat
    $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
    $txtUp = ($ext.ToUpper())
    if ($txtUp.Length -gt 5) { $txtUp = $txtUp.Substring(0, 5) }
    $g.DrawString($txtUp, $font, [Drawing.Brushes]::DarkSlateBlue, (New-Object Drawing.RectangleF(4, 4, 88, 88)), $sf)
    $g.Dispose()
    $bmp
}

function Ensure-BaseImages {
    if (-not $imgThumbs.Images.ContainsKey('folder')) {
        [void]$imgThumbs.Images.Add('folder', [System.Drawing.SystemIcons]::Folder.ToBitmap())
    }
}

function Set-RowImage($li, [bool]$isFolder, [string]$name, [string]$ext) {
    if (-not $script:iconView) { return }
    Ensure-BaseImages
    if ($isFolder) { $li.ImageKey = 'folder'; return }
    $key = 'ph_' + $ext
    if (-not $imgThumbs.Images.ContainsKey($key)) { [void]$imgThumbs.Images.Add($key, (Make-Placeholder $ext)) }
    $li.ImageKey = $key
}

# ======================= UI Aufbau =======================
$form = New-Object Windows.Forms.Form
$form.Text = 'Handy-Kopie: Redmi -> Desktop (mit Auswahl und Fortschritt)'
$form.Font = New-Object Drawing.Font('Segoe UI', 9)
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object Drawing.Size(1150, 740)
$form.MinimumSize = New-Object Drawing.Size(980, 640)

$outer = New-Object Windows.Forms.TableLayoutPanel
$outer.Dock = 'Fill'; $outer.ColumnCount = 1; $outer.RowCount = 2
[void]$outer.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))
[void]$outer.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 270)))
$form.Controls.Add($outer)

$split = New-Object Windows.Forms.SplitContainer
$split.Dock = 'Fill'; $split.Orientation = 'Vertical'
$split.SplitterWidth = 6
$split.FixedPanel = 'Panel1'
$outer.Controls.Add($split, 0, 0)

# ---------- links: Speicherwahl + Ordnerbaum ----------
$leftP = New-Object Windows.Forms.TableLayoutPanel
$leftP.Dock = 'Fill'; $leftP.ColumnCount = 1; $leftP.RowCount = 7
[void]$leftP.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 96)))
[void]$leftP.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 40)))
[void]$leftP.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 70)))
[void]$leftP.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
[void]$leftP.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))
[void]$leftP.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 172)))
[void]$leftP.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
$split.Panel1.Controls.Add($leftP)

$grpStor = New-Object Windows.Forms.GroupBox
$grpStor.Text = 'Speicher am Handy'
$grpStor.Dock = 'Fill'
$leftP.Controls.Add($grpStor, 0, 0)

$btnCleanOpen = New-Object Windows.Forms.Button
$btnCleanOpen.Text = 'Cache & Datenmuell bereinigen'
$btnCleanOpen.Dock = 'Fill'
$btnCleanOpen.BackColor = [Drawing.Color]::FromArgb(255, 235, 205)
$leftP.Controls.Add($btnCleanOpen, 0, 1)

$rbInternal = New-Object Windows.Forms.RadioButton
$rbInternal.Location = New-Object Drawing.Point(12, 22)
$rbInternal.Size = New-Object Drawing.Size(215, 20)
$rbInternal.Text = 'Interner Speicher'
$rbInternal.Enabled = $false
$grpStor.Controls.Add($rbInternal)

$rbExternal = New-Object Windows.Forms.RadioButton
$rbExternal.Location = New-Object Drawing.Point(12, 48)
$rbExternal.Size = New-Object Drawing.Size(215, 20)
$rbExternal.Text = 'SD-Karte / extern'
$rbExternal.Enabled = $false
$grpStor.Controls.Add($rbExternal)

$btnRefreshVol = New-Object Windows.Forms.Button
$btnRefreshVol.Location = New-Object Drawing.Point(232, 32)
$btnRefreshVol.Size = New-Object Drawing.Size(78, 30)
$btnRefreshVol.Text = 'Neu laden'
$grpStor.Controls.Add($btnRefreshVol)

$lblHint = New-Object Windows.Forms.Label
$lblHint.Text = 'Häkchen setzen = Ordner wird kopiert (inkl. aller Unterordner). Häkchen entfernen = Unterordner ausschließen.'
$lblHint.AutoSize = $true
$lblHint.MaximumSize = New-Object Drawing.Size(300, 0)
$lblHint.ForeColor = [Drawing.Color]::Gray
$grpCopyOpts = New-Object Windows.Forms.GroupBox
$grpCopyOpts.Text = 'Kopier-Modus'
$grpCopyOpts.Dock = 'Fill'
$chkTurbo = New-Object Windows.Forms.CheckBox
$chkTurbo.Text = 'Turbo (adb pull, viel schneller)'
$chkTurbo.Location = New-Object Drawing.Point(10, 16)
$chkTurbo.Size = New-Object Drawing.Size(300, 16)
$chkIncr = New-Object Windows.Forms.CheckBox
$chkIncr.Text = 'Inkrementell (nur Neues + Aenderungen)'
$chkIncr.Location = New-Object Drawing.Point(10, 32)
$chkIncr.Size = New-Object Drawing.Size(300, 16)
$chkExif = New-Object Windows.Forms.CheckBox
$chkExif.Text = 'Fotos nach Aufnahmedatum sortieren'
$chkExif.Location = New-Object Drawing.Point(10, 48)
$chkExif.Size = New-Object Drawing.Size(300, 16)
$grpCopyOpts.Controls.Add($chkTurbo)
$grpCopyOpts.Controls.Add($chkIncr)
$grpCopyOpts.Controls.Add($chkExif)
$leftP.Controls.Add($grpCopyOpts, 0, 2)
$leftP.Controls.Add($lblHint, 0, 3)

$tree = New-Object Windows.Forms.TreeView
$tree.Dock = 'Fill'
$tree.CheckBoxes = $true
$tree.HideSelection = $false
$leftP.Controls.Add($tree, 0, 4)

$grpFilter = New-Object Windows.Forms.GroupBox
$grpFilter.Text = 'Datei-Filter (was kopiert wird)'
$grpFilter.Dock = 'Fill'
$leftP.Controls.Add($grpFilter, 0, 5)

$script:filterDefs = [ordered]@{
    'Alle Dateitypen (Standard)'  = ''
    'Bilder (jpg, png, heic...)'  = 'jpg jpeg png gif webp heic heif bmp'
    'Videos (mp4, mov...)'        = 'mp4 3gp mov mkv avi webm m4v'
    'Audio (mp3, m4a...)'         = 'mp3 aac m4a flac wav ogg opus'
    'Dokumente (pdf, docx...)'    = 'pdf doc docx xls xlsx ppt pptx txt md csv rtf'
    'APK (apk, xapk)'             = 'apk xapk apkm aab'
    'Archive (zip, rar...)'       = 'zip rar 7z tar gz'
}
$clbFilter = New-Object Windows.Forms.CheckedListBox
$clbFilter.Location = New-Object Drawing.Point(8, 18)
$clbFilter.Size = New-Object Drawing.Size(300, 108)
$clbFilter.Anchor = 'Top,Left,Right'
$clbFilter.MultiColumn = $true
$clbFilter.ColumnWidth = 152
$clbFilter.CheckOnClick = $true
foreach ($k in $script:filterDefs.Keys) { [void]$clbFilter.Items.Add($k) }
$clbFilter.SetItemChecked(0, $true)
$grpFilter.Controls.Add($clbFilter)

$lblExtra = New-Object Windows.Forms.Label
$lblExtra.Text = 'Eigene Endungen (kommagetrennt):'
$lblExtra.Location = New-Object Drawing.Point(8, 128)
$lblExtra.Size = New-Object Drawing.Size(190, 16)
$grpFilter.Controls.Add($lblExtra)

$txtFilterExtra = New-Object Windows.Forms.TextBox
$txtFilterExtra.Location = New-Object Drawing.Point(200, 126)
$txtFilterExtra.Size = New-Object Drawing.Size(108, 22)
$grpFilter.Controls.Add($txtFilterExtra)

$btnSearchPhone = New-Object Windows.Forms.Button
$btnSearchPhone.Text = 'Handy durchsuchen'
$btnSearchPhone.Location = New-Object Drawing.Point(8, 148)
$btnSearchPhone.Size = New-Object Drawing.Size(140, 22)
$btnSearchPhone.BackColor = [Drawing.Color]::FromArgb(215, 235, 255)
$grpFilter.Controls.Add($btnSearchPhone)

$chkSys = New-Object Windows.Forms.CheckBox
$chkSys.Text = 'Systemordner zeigen'
$chkSys.Location = New-Object Drawing.Point(154, 150)
$chkSys.Size = New-Object Drawing.Size(150, 20)
$chkSys.Checked = $false
$grpFilter.Controls.Add($chkSys)

$lblSelInfo = New-Object Windows.Forms.Label
$lblSelInfo.Text = 'Ordner LINKS anklicken = rechts erscheinen die Dateinamen.'
$lblSelInfo.AutoSize = $true
$lblSelInfo.MaximumSize = New-Object Drawing.Size(300, 0)
$lblSelInfo.ForeColor = [Drawing.Color]::Gray
$leftP.Controls.Add($lblSelInfo, 0, 6)

# ---------- rechts: Browser ----------
$rightP = New-Object Windows.Forms.TableLayoutPanel
$rightP.Dock = 'Fill'; $rightP.ColumnCount = 1; $rightP.RowCount = 3
[void]$rightP.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 40)))
[void]$rightP.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 38)))
[void]$rightP.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))
$split.Panel2.Controls.Add($rightP)

$toolbar = New-Object Windows.Forms.Panel
$toolbar.Dock = 'Fill'
$rightP.Controls.Add($toolbar, 0, 0)

$btnUp = New-Object Windows.Forms.Button
$btnUp.Text = '< Hoch'
$btnUp.Location = New-Object Drawing.Point(4, 6)
$btnUp.Size = New-Object Drawing.Size(70, 26)
$toolbar.Controls.Add($btnUp)

$lblPath = New-Object Windows.Forms.Label
$lblPath.Location = New-Object Drawing.Point(82, 11)
$lblPath.Size = New-Object Drawing.Size(600, 20)
$lblPath.Anchor = 'Left,Top,Right'
$lblPath.AutoEllipsis = $true
$toolbar.Controls.Add($lblPath)

$btnNavRefresh = New-Object Windows.Forms.Button
$btnNavRefresh.Text = 'Aktualisieren'
$btnNavRefresh.Size = New-Object Drawing.Size(95, 26)
$btnNavRefresh.Location = New-Object Drawing.Point(900, 6)
$btnNavRefresh.Anchor = 'Top,Right'
$toolbar.Controls.Add($btnNavRefresh)

$btnApps = New-Object Windows.Forms.Button
$btnApps.Text = 'Apps verwalten'
$btnApps.Size = New-Object Drawing.Size(130, 26)
$btnApps.Location = New-Object Drawing.Point(760, 6)
$btnApps.Anchor = 'Top,Right'
$btnApps.BackColor = [Drawing.Color]::FromArgb(230, 220, 245)
$toolbar.Controls.Add($btnApps)

$list = New-Object Windows.Forms.ListView
$list.Dock = 'Fill'
$list.View = 'Details'
$list.FullRowSelect = $true
$list.GridLines = $true
[void]$list.Columns.Add('Name', 340)
[void]$list.Columns.Add('Größe', 110)
[void]$list.Columns.Add('Typ', 90)
[void]$list.Columns.Add('Geändert', 170)
$list.MultiSelect = $true
$imgThumbs = New-Object Windows.Forms.ImageList
$imgThumbs.ImageSize = New-Object Drawing.Size(96, 96)
$imgThumbs.ColorDepth = 'Depth32Bit'
$list.LargeImageList = $imgThumbs
$rightP.Controls.Add($list, 0, 2)

$actionRow = New-Object Windows.Forms.FlowLayoutPanel
$actionRow.Dock = 'Fill'
$btnCopySel = New-Object Windows.Forms.Button
$btnCopySel.Text = 'Markierte Dateien kopieren'
$btnCopySel.AutoSize = $true
$btnCopySel.Enabled = $false
$btnCopyFolder = New-Object Windows.Forms.Button
$btnCopyFolder.Text = 'Diesen Ordner komplett kopieren'
$btnCopyFolder.AutoSize = $true
$btnCopyFolder.Enabled = $false
$btnView = New-Object Windows.Forms.Button
$btnView.Text = 'Ansicht: Miniaturen'
$btnView.AutoSize = $true
$lblSearchInfo = New-Object Windows.Forms.Label
$lblSearchInfo.Text = ''
$lblSearchInfo.AutoSize = $true
$lblSearchInfo.ForeColor = [Drawing.Color]::DarkBlue
$lblSearchInfo.Margin = New-Object Windows.Forms.Padding(8, 8, 3, 3)
$actionRow.Controls.Add($btnCopySel)
$actionRow.Controls.Add($btnCopyFolder)
$actionRow.Controls.Add($btnView)
$actionRow.Controls.Add($lblSearchInfo)
$rightP.Controls.Add($actionRow, 0, 1)

# ---------- unten: Ziel + Fortschritt + Log ----------
$bottom = New-Object Windows.Forms.TableLayoutPanel
$bottom.Dock = 'Fill'; $bottom.ColumnCount = 1; $bottom.RowCount = 3
[void]$bottom.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
[void]$bottom.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 118)))
[void]$bottom.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))
$outer.Controls.Add($bottom, 0, 1)

$destRow = New-Object Windows.Forms.TableLayoutPanel
$destRow.Dock = 'Fill'; $destRow.ColumnCount = 5; $destRow.RowCount = 1
$destRow.AutoSize = $true
[void]$destRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::AutoSize)))
[void]$destRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
[void]$destRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::AutoSize)))
[void]$destRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::AutoSize)))
[void]$destRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::AutoSize)))
$bottom.Controls.Add($destRow, 0, 0)

$lblZiel = New-Object Windows.Forms.Label
$lblZiel.Text = 'Zielordner:'
$lblZiel.AutoSize = $true
$lblZiel.Anchor = 'Left'
$lblZiel.Margin = New-Object Windows.Forms.Padding(3, 8, 3, 3)
$destRow.Controls.Add($lblZiel, 0, 0)

$txtDest = New-Object Windows.Forms.TextBox
$txtDest.Text = $script:DestInit
$txtDest.Dock = 'Fill'
$txtDest.Margin = New-Object Windows.Forms.Padding(3, 5, 3, 3)
$destRow.Controls.Add($txtDest, 1, 0)

$btnBrowse = New-Object Windows.Forms.Button
$btnBrowse.Text = 'Durchsuchen...'
$btnBrowse.AutoSize = $true
$btnBrowse.Margin = New-Object Windows.Forms.Padding(3, 4, 3, 3)
$destRow.Controls.Add($btnBrowse, 2, 0)

$btnStart = New-Object Windows.Forms.Button
$btnStart.Text = 'Kopieren starten'
$btnStart.AutoSize = $true
$btnStart.BackColor = [Drawing.Color]::FromArgb(210, 240, 210)
$btnStart.Margin = New-Object Windows.Forms.Padding(8, 4, 3, 3)
$destRow.Controls.Add($btnStart, 3, 0)

$btnCancel = New-Object Windows.Forms.Button
$btnCancel.Text = 'Abbrechen'
$btnCancel.AutoSize = $true
$btnCancel.Enabled = $false
$btnCancel.Margin = New-Object Windows.Forms.Padding(3, 4, 3, 3)
$destRow.Controls.Add($btnCancel, 4, 0)

$progPanel = New-Object Windows.Forms.TableLayoutPanel
$progPanel.Dock = 'Fill'; $progPanel.ColumnCount = 1; $progPanel.RowCount = 4
[void]$progPanel.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
[void]$progPanel.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 28)))
[void]$progPanel.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
[void]$progPanel.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
$bottom.Controls.Add($progPanel, 0, 1)

$lblStatus = New-Object Windows.Forms.Label
$lblStatus.Text = 'Bereit. Telefon verbinden, dann "Neu laden" klicken.'
$lblStatus.Dock = 'Fill'
$lblStatus.AutoEllipsis = $true
$lblStatus.Margin = New-Object Windows.Forms.Padding(3, 4, 3, 1)
$progPanel.Controls.Add($lblStatus, 0, 0)

$progRow = New-Object Windows.Forms.TableLayoutPanel
$progRow.Dock = 'Fill'; $progRow.ColumnCount = 2; $progRow.RowCount = 1
[void]$progRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
[void]$progRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute, 210)))
$progPanel.Controls.Add($progRow, 0, 1)

$pbOverall = New-Object Windows.Forms.ProgressBar
$pbOverall.Dock = 'Fill'
$progRow.Controls.Add($pbOverall, 0, 0)

$lblOverall = New-Object Windows.Forms.Label
$lblOverall.Text = '0 %'
$lblOverall.Dock = 'Fill'
$lblOverall.TextAlign = 'MiddleRight'
$progRow.Controls.Add($lblOverall, 1, 0)

$lblDetail = New-Object Windows.Forms.Label
$lblDetail.Text = ''
$lblDetail.Dock = 'Fill'
$lblDetail.AutoEllipsis = $true
$progPanel.Controls.Add($lblDetail, 0, 2)

$lblFile = New-Object Windows.Forms.Label
$lblFile.Text = ''
$lblFile.Dock = 'Fill'
$lblFile.AutoEllipsis = $true
$lblFile.ForeColor = [Drawing.Color]::Gray
$progPanel.Controls.Add($lblFile, 0, 3)

$txtLog = New-Object Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.Dock = 'Fill'
$txtLog.BackColor = [Drawing.Color]::White
$bottom.Controls.Add($txtLog, 0, 2)

# ======================= Telefon / Shell Zugriff (UI-Thread) =======================
$script:shell   = New-Object -ComObject Shell.Application
$script:volumes = @()
$script:volIndex = -1
$script:navStack = @()
$script:intVol = $null
$script:extVol = $null
$script:busy = $false
$script:notified = $false
$script:inCheck = $false
$script:navigating = $false
$script:inFilter = $false
$script:phoneName = ''
$script:extSetUI = $null
$script:viewMode = 'browser'
$script:searchStack = @()
$script:searchMap = @{}
$script:searchList = @()
$script:searching = $false
$script:iconView = $false
$script:showSys = $false
$script:sysNames = @('android', 'miui', '.ota', 'system', '.cache', 'cache', 'tmp', 'temp', 'logs', 'lost.dir', '.trash', '.recycle', '.thumbnails', '.data', '.bundletest')

function Is-SystemName([string]$name) {
    if ($script:showSys) { return $false }
    return ($script:sysNames -contains $name.ToLower())
}

function Find-Device {
    $pc = $script:shell.Namespace(17)
    $pc.Items() | Where-Object { $_.IsFolder -and $_.Name -like "*$PhoneMatch*" } | Select-Object -First 1
}

function Navigate-To($pathArr) {
    if ($script:volIndex -lt 0) { throw 'Kein Speicher ausgewählt.' }
    $vol = $script:volumes[$script:volIndex]
    $f = $vol.Item.GetFolder
    if (-not $f) { throw 'Speicherbereich nicht lesbar. Handy entsperren und "Neu laden" klicken.' }
    foreach ($seg in $pathArr) {
        $n = $f.ParseName($seg)
        if (-not $n -or -not $n.IsFolder) { throw "Ordner '$seg' nicht (mehr) vorhanden." }
        $f = $n.GetFolder
        if (-not $f) { throw "Ordner '$seg' nicht lesbar." }
    }
    $f
}

function Show-Folder($pathArr) {
    $script:navStack = @($pathArr | Where-Object { $null -ne $_ -and $_ -ne '' })
    $script:viewMode = 'browser'
    $script:searchStack = @()
    $list.BeginUpdate()
    $list.Items.Clear()
    try {
        $volName = if ($script:volIndex -ge 0) { $script:volumes[$script:volIndex].Name } else { '?' }
        $lblPath.Text = $volName + $(if ($pathArr.Count -gt 0) { '\' + ($pathArr -join '\') } else { '' })
        $f = Navigate-To $pathArr
        $fileNames = @()
        foreach ($item in $f.Items()) {
            if ($item.IsFolder -and (Is-SystemName $item.Name)) { continue }
            if (-not $item.IsFolder -and $script:extSetUI) {
                $di = $item.Name.LastIndexOf('.')
                $fext = if ($di -ge 0) { $item.Name.Substring($di + 1).ToLower() } else { '' }
                if (-not $script:extSetUI.ContainsKey($fext)) { continue }
            }
            $li = $list.Items.Add($item.Name)
            $li.Tag = @{ IsFolder = $item.IsFolder; Name = $item.Name }
            $rowExt = ''
            if (-not $item.IsFolder) {
                $di2 = $item.Name.LastIndexOf('.')
                $rowExt = if ($di2 -ge 0) { $item.Name.Substring($di2 + 1).ToLower() } else { '' }
                $fileNames += $item.Name
            }
            Set-RowImage $li $item.IsFolder $item.Name $rowExt
            if ($item.IsFolder) {
                [void]$li.SubItems.Add('')
                [void]$li.SubItems.Add('Ordner')
            } else {
                $sz = [long]0
                try { $sz = [long]$item.Size } catch { }
                [void]$li.SubItems.Add((Format-Size $sz))
                [void]$li.SubItems.Add('Datei')
            }
            $dt = ''
            try {
                $v = $item.ExtendedProperty('System.DateModified')
                if ($v) { $dt = ([datetime]$v).ToString('dd.MM.yyyy HH:mm') }
            } catch { }
            [void]$li.SubItems.Add($dt)
        }
        Start-ThumbWorker $script:navStack $fileNames
    } catch {
        $lblPath.Text = 'Fehler beim Lesen des Ordners.'
        Log ('Browser-Fehler: ' + $_.Exception.Message)
    } finally {
        $list.EndUpdate()
        $btnUp.Enabled = $true
        Update-ActionButtons
    }
}

function Update-ActionButtons {
    $canFolder = (-not $script:busy) -and
        (($script:viewMode -eq 'drill' -and $script:searchStack.Count -gt 0) -or
         ($script:viewMode -eq 'browser' -and $script:navStack.Count -gt 0))
    $btnCopyFolder.Enabled = $canFolder
    $anyFile = $false
    foreach ($it in $list.SelectedItems) { if ($it.Tag -and -not $it.Tag.IsFolder) { $anyFile = $true; break } }
    $btnCopySel.Enabled = ((-not $script:busy) -and $script:viewMode -eq 'drill' -and $anyFile)
}

function Show-SearchResults {
    $script:viewMode = 'results'
    $script:searchStack = @()
    $list.BeginUpdate()
    $list.Items.Clear()
    $volName = if ($script:volIndex -ge 0) { $script:volumes[$script:volIndex].Name } else { '?' }
    $lblPath.Text = 'Suchergebnisse (' + $volName + '): Ordner, in denen gefundene Dateien liegen - Doppelklick oeffnet den Ordner'
    foreach ($rel in $script:searchList) {
        $en = $script:searchMap[$rel]
        $li = $list.Items.Add($en.Rel)
        $li.Tag = @{ IsFolder = $true; Rel = $en.Rel }
        Set-RowImage $li $true $en.Rel ''
        [void]$li.SubItems.Add((Format-Size $en.Bytes))
        [void]$li.SubItems.Add(($en.Files.Count.ToString() + ' Datei(en)'))
        [void]$li.SubItems.Add('')
    }
    $list.EndUpdate()
    $btnUp.Enabled = $false
    Update-ActionButtons
}

function Show-Drill([string]$rel) {
    $script:viewMode = 'drill'
    $script:searchStack = @($rel.Split('\') | Where-Object { $_ })
    $list.BeginUpdate()
    $list.Items.Clear()
    $volName = if ($script:volIndex -ge 0) { $script:volumes[$script:volIndex].Name } else { '?' }
    $lblPath.Text = $volName + '\' + $rel
    $relL = $rel.ToLower()
    $en = $script:searchMap[$relL]
    $drillNames = @()
    if ($en) {
        foreach ($f in $en.Files) {
            $li = $list.Items.Add($f.Name)
            $li.Tag = @{ IsFolder = $false; Rel = ($rel + '\' + $f.Name) }
            $di2 = $f.Name.LastIndexOf('.')
            $rowExt = if ($di2 -ge 0) { $f.Name.Substring($di2 + 1).ToLower() } else { '' }
            $drillNames += $f.Name
            Set-RowImage $li $false $f.Name $rowExt
            [void]$li.SubItems.Add((Format-Size $f.Size))
            [void]$li.SubItems.Add('Datei')
            [void]$li.SubItems.Add('')
        }
    }
    foreach ($r in $script:searchList) {
        if ($r.StartsWith($relL + '\')) {
            $rest = $r.Substring($relL.Length + 1)
            if ($rest -notlike '*\*') {
                $sub = $script:searchMap[$r]
                $li = $list.Items.Add($rest)
                $li.Tag = @{ IsFolder = $true; Rel = $sub.Rel }
                Set-RowImage $li $true $rest ''
                [void]$li.SubItems.Add((Format-Size $sub.Bytes))
                [void]$li.SubItems.Add(($sub.Files.Count.ToString() + ' Datei(en)'))
                [void]$li.SubItems.Add('')
            }
        }
    }
    $list.EndUpdate()
    $btnUp.Enabled = $true
    Start-ThumbWorker $script:searchStack $drillNames
    Update-ActionButtons
}

function Populate-Children($node) {
    $f = Navigate-To $node.Tag.Path
    foreach ($item in $f.Items()) {
        if (-not $item.IsFolder) { continue }
        if (Is-SystemName $item.Name) { continue }
        $c = New-Object Windows.Forms.TreeNode($item.Name)
        $c.Tag = @{ Path = ($node.Tag.Path + @($item.Name)); Loaded = $false }
        if ($node.Checked) { $c.Checked = $true }
        [void]$c.Nodes.Add('_')
        [void]$node.Nodes.Add($c)
    }
}

function Select-VolIndex([int]$idx) {
    if ($idx -lt 0 -or $idx -ge $script:volumes.Count) { return }
    $script:volIndex = $idx
    $script:navStack = @()
    $tree.Nodes.Clear()
    $rootNode = New-Object Windows.Forms.TreeNode($script:volumes[$idx].Name)
    $rootNode.Tag = @{ Path = @(); Loaded = $false }
    [void]$rootNode.Nodes.Add('_')
    [void]$tree.Nodes.Add($rootNode)
    Show-Folder @()
    try {
        $rootNode.Nodes.Clear()
        Populate-Children $rootNode
        $rootNode.Tag.Loaded = $true
        $rootNode.Expand()
    } catch {
        Log ('Fehler beim Laden der Ordnerliste: ' + $_.Exception.Message)
    }
    if ($script:extSetUI) { Start-Search }
    Update-TurboState
}

function Update-TurboState {
    $adb = Find-Adb
    $script:adbPath = $adb
    $internal = ($script:volIndex -ge 0) -and ($script:volumes[$script:volIndex].Kind -eq 'internal')
    $chkTurbo.Enabled = [bool]($adb -and $internal)
    if (-not $chkTurbo.Enabled) { $chkTurbo.Checked = $false }
}

function Refresh-All([bool]$silent = $false) {
    if ($script:busy) { return }
    $dev = Find-Device
    if (-not $dev) {
        $script:volumes = @(); $script:volIndex = -1
        $script:phoneName = ''
        $chkTurbo.Enabled = $false; $chkTurbo.Checked = $false
        $tree.Nodes.Clear(); $list.Items.Clear()
        $rbInternal.Enabled = $false; $rbInternal.Text = 'Interner Speicher (nicht gefunden)'
        $rbExternal.Enabled = $false; $rbExternal.Text = 'SD-Karte / extern (nicht gefunden)'
        $lblStatus.Text = 'Kein Telefon verbunden.'
        if (-not $silent) {
            [Windows.Forms.MessageBox]::Show($form,
                "Das Telefon '$PhoneMatch' wurde nicht gefunden.`r`n`r`nBitte prüfen:`r`n1) USB-Kabel verbunden`r`n2) Handy ist entsperrt`r`n3) Am Handy den USB-Modus 'Dateiübertragung / MTP' auswählen",
                'Telefon nicht gefunden', 'OK', 'Warning')
        }
        return
    }
    $df = $dev.GetFolder
    if (-not $df) { throw 'Telefon-Speicher nicht lesbar. Handy entsperrt?' }
    $vols = @()
    foreach ($v in $df.Items()) {
        if (-not $v.IsFolder) { continue }
        $kind = 'other'
        if ($v.Name -match 'Interner|Internal') { $kind = 'internal' }
        elseif ($v.Name -match 'SD|Karte|Card|Extern|External') { $kind = 'external' }
        $vols += [pscustomobject]@{ Name = $v.Name; Kind = $kind; Item = $v }
    }
    $script:volumes = $vols
    $int = $vols | Where-Object { $_.Kind -eq 'internal' } | Select-Object -First 1
    $ext = $vols | Where-Object { $_.Kind -eq 'external' } | Select-Object -First 1
    if (-not $ext) { $ext = $vols | Where-Object { $_.Kind -eq 'other' } | Select-Object -First 1 }
    $script:intVol = $int
    $script:extVol = $ext
    $rbInternal.Enabled = [bool]$int
    $rbInternal.Text = if ($int) { $int.Name } else { 'Interner Speicher (nicht gefunden)' }
    $rbExternal.Enabled = [bool]$ext
    $rbExternal.Text = if ($ext) { $ext.Name } else { 'SD-Karte / extern (nicht gefunden)' }
    $script:phoneName = $dev.Name
    $lblStatus.Text = 'Telefon verbunden: ' + $dev.Name
    if ($int)      { $rbInternal.Checked = $true; Select-VolIndex ([array]::IndexOf($script:volumes, $int)) }
    elseif ($ext)  { $rbExternal.Checked = $true; Select-VolIndex ([array]::IndexOf($script:volumes, $ext)) }
}

function Save-Config {
    try {
        if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null }
        @{ Dest = $txtDest.Text.Trim() } | ConvertTo-Json | Set-Content -LiteralPath $cfgPath -Encoding UTF8
    } catch { }
}

# ======================= Auswahl (Häkchen) auswerten =======================
function Collect-Holes($node, [string]$rel, $holes) {
    foreach ($c in $node.Nodes) {
        if ($null -eq $c.Tag) { continue }
        $crel = if ($rel) { $rel + '\' + $c.Text } else { $c.Text }
        if ($c.Checked) { Collect-Holes $c $crel $holes }
        else { [void]$holes.Add($crel.ToLower()) }
    }
}

function Walk-Sel($node, $sel) {
    if ($null -eq $node.Tag) { return }
    if ($node.Checked) {
        $holes = New-Object System.Collections.Generic.List[string]
        Collect-Holes $node '' $holes
        $p = $node.Tag.Path
        [void]$sel.Add(@{ Path = $p; Name = $p[$p.Count - 1]; Holes = $holes })
    } else {
        foreach ($c in $node.Nodes) { Walk-Sel $c $sel }
    }
}

function Get-Selection {
    $sel = New-Object System.Collections.Generic.List[object]
    if ($tree.Nodes.Count -eq 0) { return ,$sel }
    $rootNode = $tree.Nodes[0]
    foreach ($child in $rootNode.Nodes) { Walk-Sel $child $sel }
    return ,$sel
}

function Cascade-Check($node, [bool]$state) {
    foreach ($c in $node.Nodes) {
        if ($null -eq $c.Tag) { continue }
        $c.Checked = $state
        Cascade-Check $c $state
    }
}

# ======================= Reinigung: Cache & Datenmuell =======================
$cleanForm = New-Object Windows.Forms.Form
$cleanForm.Text = 'Cache & Datenmuell bereinigen'
$cleanForm.Font = New-Object Drawing.Font('Segoe UI', 9)
$cleanForm.Size = New-Object Drawing.Size(640, 560)
$cleanForm.StartPosition = 'CenterParent'
$cleanForm.FormBorderStyle = 'FixedDialog'
$cleanForm.MaximizeBox = $false
$cleanForm.MinimizeBox = $false

$clp = New-Object Windows.Forms.TableLayoutPanel
$clp.Dock = 'Fill'; $clp.ColumnCount = 1; $clp.RowCount = 5
[void]$clp.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
[void]$clp.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))
[void]$clp.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
[void]$clp.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 26)))
[void]$clp.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 40)))
$cleanForm.Controls.Add($clp)

$lblCleanHint = New-Object Windows.Forms.Label
$lblCleanHint.Text = 'Kategorien anhaekeln, dann "Scannen" (Groessen ermitteln) und "Auswahl loeschen". ' +
    'Thumbnails und App-Caches sind unbedenklich: Sie werden bei Bedarf neu erzeugt. ' +
    'Eigene Dateien (Fotos, Dokumente) werden NICHT angefasst. ' +
    'Hinweis: Ab Android 11 sind manche App-Cache-Ordner ueber MTP nicht sichtbar - fuer eine Tiefenreinigung siehe ANLEITUNG (adb).'
$lblCleanHint.AutoSize = $true
$lblCleanHint.MaximumSize = New-Object Drawing.Size(600, 0)
$clp.Controls.Add($lblCleanHint, 0, 0)

$clb = New-Object Windows.Forms.CheckedListBox
$clb.Dock = 'Fill'
$clb.CheckOnClick = $true
$clp.Controls.Add($clb, 0, 1)

$btnRow = New-Object Windows.Forms.FlowLayoutPanel
$btnRow.Dock = 'Fill'
$btnRow.AutoSize = $true
$btnScan = New-Object Windows.Forms.Button
$btnScan.Text = 'Scannen'
$btnScan.AutoSize = $true
$btnClean = New-Object Windows.Forms.Button
$btnClean.Text = 'Auswahl loeschen'
$btnClean.AutoSize = $true
$btnClean.Enabled = $false
$btnAdb = New-Object Windows.Forms.Button
$btnAdb.Text = 'App-Cache per adb leeren'
$btnAdb.AutoSize = $true
$btnCleanClose = New-Object Windows.Forms.Button
$btnCleanClose.Text = 'Schliessen'
$btnCleanClose.AutoSize = $true
$btnRow.Controls.Add($btnScan)
$btnRow.Controls.Add($btnClean)
$btnRow.Controls.Add($btnAdb)
$btnRow.Controls.Add($btnCleanClose)
$clp.Controls.Add($btnRow, 0, 2)

$lblCleanStatus = New-Object Windows.Forms.Label
$lblCleanStatus.Text = 'Bereit.'
$lblCleanStatus.Dock = 'Fill'
$lblCleanStatus.AutoEllipsis = $true
$clp.Controls.Add($lblCleanStatus, 0, 3)

$txtCleanLog = New-Object Windows.Forms.TextBox
$txtCleanLog.Multiline = $true
$txtCleanLog.ReadOnly = $true
$txtCleanLog.ScrollBars = 'Vertical'
$txtCleanLog.Dock = 'Fill'
$clp.Controls.Add($txtCleanLog, 0, 4)

$csync = [hashtable]::Synchronized(@{
    Phase  = 'Idle'
    Log    = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
    Status = ''
    Cats   = $null
    Job    = $null
    DeletePaths = $null
    Error  = ''
})

$cleanScanScript = {
    function CLog($m) { $csync.Log.Enqueue((Get-Date).ToString('HH:mm:ss') + '  ' + $m) }
    function SizeOf($folder) {
        $total = [long]0; $cnt = 0
        foreach ($it in $folder.Items()) {
            if ($it.IsFolder) { $g = $it.GetFolder; if ($g) { $r = SizeOf $g; $total = $total + $r[0]; $cnt = $cnt + $r[1] } }
            else { try { $total = $total + [long]$it.Size } catch { }; $cnt++ }
        }
        ,@($total, $cnt)
    }
    try {
        $job = $csync.Job
        $csync.Phase = 'Scan'
        $shell = New-Object -ComObject Shell.Application
        $pc = $shell.Namespace(17)
        $dev = $pc.Items() | Where-Object { $_.IsFolder -and $_.Name -like "*$($job.PhoneMatch)*" } | Select-Object -First 1
        if (-not $dev) { throw 'Telefon nicht gefunden.' }
        $vol = $dev.GetFolder.Items() | Where-Object { $_.IsFolder -and $_.Name -eq $job.VolumeName } | Select-Object -First 1
        if (-not $vol) { throw 'Speicherbereich nicht gefunden.' }
        $root = $vol.GetFolder
        if (-not $root) { throw 'Speicherbereich nicht lesbar.' }

        $cats = New-Object System.Collections.Generic.List[object]

        # 1) Miniaturansichten
        $thumbPaths = @(); $thumbSize = [long]0; $thumbCount = 0
        foreach ($seg in @('DCIM', 'Pictures')) {
            $p = $root.ParseName($seg)
            if ($p -and $p.IsFolder) {
                $th = $p.GetFolder.ParseName('.thumbnails')
                if ($th -and $th.IsFolder) {
                    $r = SizeOf $th.GetFolder
                    $thumbSize = $thumbSize + $r[0]
                    $thumbCount = $thumbCount + $r[1]
                    $thumbPaths += $th.Path
                }
            }
        }
        [void]$cats.Add(@{ Id = 'thumbs'; Label = 'Miniaturansichten (DCIM/.thumbnails u.a.)'; Size = $thumbSize; Count = $thumbCount; Paths = $thumbPaths })
        CLog ('Thumbnails: ' + $thumbSize + ' Bytes, ' + $thumbCount + ' Datei(en) in ' + $thumbPaths.Count + ' Ordnern.')

        # 2) App-Caches unter Android/data/*/cache
        $cachePaths = @(); $cacheSize = [long]0; $cacheCount = 0; $cacheFiles = 0
        $android = $root.ParseName('Android')
        if ($android -and $android.IsFolder) {
            $data = $android.GetFolder.ParseName('data')
            if ($data -and $data.IsFolder) {
                foreach ($app in $data.GetFolder.Items()) {
                    if (-not $app.IsFolder) { continue }
                    $c = $app.GetFolder.ParseName('cache')
                    if ($c -and $c.IsFolder) {
                        $r = SizeOf $c.GetFolder
                        if ($r[0] -gt 0) { $cachePaths += $c.Path; $cacheSize = $cacheSize + $r[0]; $cacheCount++; $cacheFiles = $cacheFiles + $r[1] }
                    }
                    $csync.Status = 'App-Cache pruefen: ' + $app.Name
                }
            }
        }
        $cacheLbl = 'App-Caches (Android/data/*/cache): ' + $cacheCount + ' Ordner'
        if ($cacheCount -eq 0) { $cacheLbl += ' - Android 11+ blendet diese Ordner ueber MTP oft aus -> Knopf "App-Cache per adb leeren" nutzen' }
        [void]$cats.Add(@{ Id = 'caches'; Label = $cacheLbl; Size = $cacheSize; Count = $cacheFiles; Paths = $cachePaths })
        CLog ('App-Caches: ' + $cacheCount + ' Ordner mit Daten gefunden (' + $cacheFiles + ' Dateien).')

        # 3) Temp-/Restordner im Hauptverzeichnis
        $tmpPaths = @(); $tmpSize = [long]0; $tmpNames = @(); $tmpCount = 0
        foreach ($n in @('.cache', 'cache', 'tmp', 'temp', '.tmp', '.temp', 'logs')) {
            $t = $root.ParseName($n)
            if ($t -and $t.IsFolder) {
                $r = SizeOf $t.GetFolder
                $tmpSize = $tmpSize + $r[0]
                $tmpCount = $tmpCount + $r[1]
                $tmpPaths += $t.Path
                $tmpNames += $n
            }
        }
        [void]$cats.Add(@{ Id = 'temp'; Label = ('Temp-/Restordner im Hauptverzeichnis' + $(if ($tmpNames.Count) { ' (' + ($tmpNames -join ', ') + ')' } else { '' })); Size = $tmpSize; Count = $tmpCount; Paths = $tmpPaths })
        CLog ('Temp-Ordner: ' + $tmpPaths.Count + ' gefunden.')

        # 4) veraltete Android-Updates (OTA-/Update-Pakete)
        $updPaths = @(); $updSize = [long]0; $updCount = 0
        $updFolders = @(@{ F = $root; Tag = 'Root' })
        $dl = $root.ParseName('Download')
        if ($dl -and $dl.IsFolder) { $updFolders += @{ F = $dl.GetFolder; Tag = 'Download' } }
        $miui = $root.ParseName('MIUI')
        if ($miui -and $miui.IsFolder) { $updFolders += @{ F = $miui.GetFolder; Tag = 'MIUI' } }
        $ota = $root.ParseName('.ota')
        if ($ota -and $ota.IsFolder) { $updFolders += @{ F = $ota.GetFolder; Tag = '.ota' } }
        foreach ($uf in $updFolders) {
            foreach ($it in $uf.F.Items()) {
                if ($it.IsFolder) { continue }
                $nLow = $it.Name.ToLower()
                $di = $it.Name.LastIndexOf('.')
                $ext = if ($di -ge 0) { $it.Name.Substring($di + 1).ToLower() } else { '' }
                $hit = $false
                if ($ext -in @('ota', 'bin')) { $hit = $true }
                elseif (($ext -in @('zip', 'apk', 'jar')) -and ($nLow -match 'ota|update')) { $hit = $true }
                if ($hit) {
                    $sz = [long]0
                    try { $sz = [long]$it.Size } catch { }
                    $updPaths += $it.Path
                    $updSize = $updSize + $sz
                    $updCount++
                    CLog ('Update-Rest gefunden: ' + $uf.Tag + '/' + $it.Name + ' (' + $sz + ' Bytes)')
                }
            }
            $csync.Status = 'Update-Reste pruefen: ' + $uf.Tag
        }
        [void]$cats.Add(@{ Id = 'updates'; Label = ('Veraltete Android-Updates (Root/Download/MIUI: *.ota, *.bin, update*.zip)'); Size = $updSize; Count = $updCount; Paths = $updPaths })
        CLog ('Update-Reste: ' + $updCount + ' Datei(en) gefunden.')

        $csync.Cats = $cats
        $csync.Phase = 'Scanned'
        CLog 'Scan abgeschlossen.'
    } catch {
        $csync.Error = $_.Exception.Message
        $csync.Phase = 'Error'
        CLog ('FEHLER: ' + $_.Exception.Message)
    }
}

$cleanDeleteScript = {
    function CLog($m) { $csync.Log.Enqueue((Get-Date).ToString('HH:mm:ss') + '  ' + $m) }
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class ShellDel {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct SHFILEOPSTRUCT {
        public IntPtr hwnd;
        public uint wFunc;
        public string pFrom;
        public string pTo;
        public ushort fFlags;
        public int fAnyOperationsAborted;
        public IntPtr hNameMappings;
        public string lpszProgressTitle;
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, EntryPoint = "SHFileOperationW")]
    public static extern int SHFileOperation(ref SHFILEOPSTRUCT lpFileOp);
}
"@
    try {
        $csync.Phase = 'Delete'
        $paths = @($csync.DeletePaths | Where-Object { $_ })
        if ($paths.Count -eq 0) { throw 'Keine Loeschpfade uebergeben.' }
        CLog ('Uebergebe ' + $paths.Count + ' Elemente an die Loeschfunktion...')
        $pFrom = ($paths -join "`0") + "`0"
        $op = New-Object 'ShellDel+SHFILEOPSTRUCT'
        $op.wFunc = 3        # FO_DELETE
        $op.pFrom = $pFrom
        $op.fFlags = 0x10 -bor 0x4 -bor 0x400 -bor 0x200   # NOCONFIRMATION | SILENT | NOERRORUI | NOCONFIRMMKDIR
        $rc = [ShellDel]::SHFileOperation([ref]$op)
        CLog ('Loeschvorgang beendet, ReturnCode: ' + $rc)
        if ($rc -ne 0) { CLog 'Hinweis: ReturnCode ungleich 0 - evtl. waren einzelne Elemente gesperrt.' }
        $csync.Phase = 'Deleted'
    } catch {
        $csync.Error = $_.Exception.Message
        $csync.Phase = 'Error'
        CLog ('FEHLER: ' + $_.Exception.Message)
    }
}

function Find-Adb {
    $adb = $null
    $cand = @()
    if ($PSScriptRoot) { $cand += (Join-Path $PSScriptRoot 'adb.exe'); $cand += (Join-Path $PSScriptRoot 'platform-tools\adb.exe') }
    $cand += "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
    $cand += "$env:ProgramFiles\Android\platform-tools\adb.exe"
    $cand += "$env:USERPROFILE\platform-tools\adb.exe"
    foreach ($c in $cand) { if ($c -and (Test-Path -LiteralPath $c)) { $adb = $c; break } }
    if (-not $adb) { $cmd = Get-Command adb.exe -ErrorAction SilentlyContinue; if ($cmd) { $adb = $cmd.Source } }
    $adb
}

$cleanAdbScript = {
    function CLog($m) { $csync.Log.Enqueue((Get-Date).ToString('HH:mm:ss') + '  ' + $m) }
    try {
        $adb = $csync.Job.AdbPath
        CLog ('Starte adb: ' + $adb + '  (pm trim-caches 8G)')
        $outF = Join-Path $env:TEMP 'handykopie_adb_out.txt'
        $errF = Join-Path $env:TEMP 'handykopie_adb_err.txt'
        $p = Start-Process -FilePath $adb -ArgumentList 'shell', 'pm', 'trim-caches', '8G' -Wait -NoNewWindow -PassThru -RedirectStandardOutput $outF -RedirectStandardError $errF
        if (Test-Path -LiteralPath $outF) { $o = Get-Content -Raw -LiteralPath $outF; if ($o) { CLog ('adb Ausgabe: ' + $o.Trim()) } }
        if (Test-Path -LiteralPath $errF) { $er = Get-Content -Raw -LiteralPath $errF; if ($er) { CLog ('adb Meldung: ' + $er.Trim()) } }
        if ($p.ExitCode -eq 0) { CLog 'pm trim-caches abgeschlossen - App-Caches wurden systemseitig bereinigt.' }
        else { CLog ('adb beendet mit Code ' + $p.ExitCode + '. Bitte USB-Debugging und adb-Autorisierung am Handy pruefen.') }
        $csync.Phase = 'Idle'
    } catch {
        CLog ('FEHLER: ' + $_.Exception.Message)
        $csync.Phase = 'Idle'
    }
}

function Start-CleanWorker($sb) {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('csync', $csync)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($sb.ToString())
    [void]$ps.BeginInvoke()
}

# ======================= Apps verwalten (adb) =======================
$appForm = New-Object Windows.Forms.Form
$appForm.Text = 'Installierte Apps verwalten (sauber deinstallieren per adb)'
$appForm.Font = New-Object Drawing.Font('Segoe UI', 9)
$appForm.Size = New-Object Drawing.Size(720, 580)
$appForm.StartPosition = 'CenterParent'
$appForm.FormBorderStyle = 'FixedDialog'
$appForm.MaximizeBox = $false
$appForm.MinimizeBox = $false

$alp = New-Object Windows.Forms.TableLayoutPanel
$alp.Dock = 'Fill'; $alp.ColumnCount = 1; $alp.RowCount = 5
[void]$alp.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
[void]$alp.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))
[void]$alp.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
[void]$alp.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 26)))
[void]$alp.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 38)))
$appForm.Controls.Add($alp)

$lblAppHint = New-Object Windows.Forms.Label
$lblAppHint.Text = 'Liste laden zeigt alle vom BENUTZER installierten Apps (Dritt-Apps). ' +
    '"Sauber deinstallieren" entfernt die App UND loescht uebrig gebliebene Ordner ' +
    '(Android/data/<Paket> und Android/obb/<Paket>) vom Handy-Speicher. ' +
    'System-Apps werden nicht angezeigt und nicht angetastet. USB-Debugging erforderlich.'
$lblAppHint.AutoSize = $true
$lblAppHint.MaximumSize = New-Object Drawing.Size(690, 0)
$alp.Controls.Add($lblAppHint, 0, 0)

$lvApps = New-Object Windows.Forms.ListView
$lvApps.Dock = 'Fill'
$lvApps.View = 'Details'
$lvApps.FullRowSelect = $true
$lvApps.GridLines = $true
$lvApps.MultiSelect = $true
[void]$lvApps.Columns.Add('App (Paketname)', 430)
[void]$lvApps.Columns.Add('Version', 90)
$alp.Controls.Add($lvApps, 0, 1)

$abtnRow = New-Object Windows.Forms.FlowLayoutPanel
$abtnRow.Dock = 'Fill'
$abtnRow.AutoSize = $true
$btnAppLoad = New-Object Windows.Forms.Button
$btnAppLoad.Text = 'Liste laden'
$btnAppLoad.AutoSize = $true
$btnAppUninstall = New-Object Windows.Forms.Button
$btnAppUninstall.Text = 'Auswahl sauber deinstallieren'
$btnAppUninstall.AutoSize = $true
$btnAppUninstall.Enabled = $false
$btnAppClose = New-Object Windows.Forms.Button
$btnAppClose.Text = 'Schliessen'
$btnAppClose.AutoSize = $true
$abtnRow.Controls.Add($btnAppLoad)
$abtnRow.Controls.Add($btnAppUninstall)
$abtnRow.Controls.Add($btnAppClose)
$alp.Controls.Add($abtnRow, 0, 2)

$lblAppStatus = New-Object Windows.Forms.Label
$lblAppStatus.Text = 'Bereit. "Liste laden" klicken.'
$lblAppStatus.Dock = 'Fill'
$lblAppStatus.AutoEllipsis = $true
$alp.Controls.Add($lblAppStatus, 0, 3)

$txtAppLog = New-Object Windows.Forms.TextBox
$txtAppLog.Multiline = $true
$txtAppLog.ReadOnly = $true
$txtAppLog.ScrollBars = 'Vertical'
$txtAppLog.Dock = 'Fill'
$alp.Controls.Add($txtAppLog, 0, 4)

$async = [hashtable]::Synchronized(@{
    Phase  = 'Idle'
    Log    = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
    Status = ''
    Pkgs   = $null
    Error  = ''
    Job    = $null
})

$appListScript = {
    function ALog($m) { $async.Log.Enqueue((Get-Date).ToString('HH:mm:ss') + '  ' + $m) }
    try {
        $async.Phase = 'Load'
        $adb = $async.Job.Adb
        ALog 'Lade installierte Dritt-Apps (pm list packages -3)...'
        $outF = Join-Path $env:TEMP 'handykopie_apps.txt'
        $errF = Join-Path $env:TEMP 'handykopie_apps_err.txt'
        $p = Start-Process -FilePath $adb -ArgumentList 'shell', 'pm', 'list', 'packages', '-3', '--show-versioncode' -Wait -NoNewWindow -PassThru -RedirectStandardOutput $outF -RedirectStandardError $errF
        $lines = @()
        if (Test-Path -LiteralPath $outF) { $lines = @(Get-Content -LiteralPath $outF) }
        $pkgs = New-Object System.Collections.Generic.List[object]
        foreach ($ln in $lines) {
            if ($ln -match '^package:([A-Za-z0-9._-]+)\s+versionCode=(\d+)') {
                [void]$pkgs.Add(@{ Pkg = $Matches[1]; Ver = $Matches[2] })
            } elseif ($ln -match '^package:([A-Za-z0-9._-]+)') {
                [void]$pkgs.Add(@{ Pkg = $Matches[1]; Ver = '' })
            }
        }
        if ($pkgs.Count -eq 0) {
            $er = ''
            if (Test-Path -LiteralPath $errF) { $er = (Get-Content -Raw -LiteralPath $errF) }
            throw ('Keine Apps empfangen. adb-Ausgabe: ' + $er)
        }
        $async.Pkgs = $pkgs
        $async.Phase = 'Loaded'
        ALog ("$($pkgs.Count) Dritt-Apps gefunden.")
    } catch {
        $async.Error = $_.Exception.Message
        $async.Phase = 'Error'
        ALog ('FEHLER: ' + $_.Exception.Message)
    }
}

$appUninstallScript = {
    function ALog($m) { $async.Log.Enqueue((Get-Date).ToString('HH:mm:ss') + '  ' + $m) }
    function RunAdb($adb, $adbArgs) {
        $outF = Join-Path $env:TEMP 'handykopie_adbrun.txt'
        $errF = Join-Path $env:TEMP 'handykopie_adbrun_err.txt'
        $p = Start-Process -FilePath $adb -ArgumentList $adbArgs -Wait -NoNewWindow -PassThru -RedirectStandardOutput $outF -RedirectStandardError $errF
        $o = ''; $e = ''
        if (Test-Path -LiteralPath $outF) { $o = (Get-Content -Raw -LiteralPath $outF) }
        if (Test-Path -LiteralPath $errF) { $e = (Get-Content -Raw -LiteralPath $errF) }
        @{ Code = $p.ExitCode; Out = ($o + $e).Trim() }
    }
    try {
        $async.Phase = 'Uninstall'
        $adb = $async.Job.Adb
        foreach ($pkg in $async.Job.Pkgs) {
            if ($pkg -notmatch '^[A-Za-z0-9._-]+$') { ALog ('Ungueltiger Paketname uebersprungen: ' + $pkg); continue }
            $async.Status = $pkg
            ALog ('Deinstalliere ' + $pkg + ' ...')
            $r = RunAdb $adb @('shell', 'pm', 'uninstall', $pkg)
            if ($r.Out -match 'Success') {
                ALog ('  App entfernt: ' + $pkg)
            } else {
                ALog ('  HINWEIS pm uninstall: ' + $r.Out)
            }
            foreach ($d in @('/storage/emulated/0/Android/data/' + $pkg, '/storage/emulated/0/Android/obb/' + $pkg)) {
                $r2 = RunAdb $adb @('shell', 'rm', '-rf', $d)
                if ($r2.Code -eq 0) { ALog ('  Restordner geloescht: ' + $d) } else { ALog ('  Restordner nicht loeschbar: ' + $d + ' (' + $r2.Out + ')') }
            }
        }
        $async.Phase = 'Done'
        ALog 'Saeuberung abgeschlossen. "Liste laden" fuer den aktuellen Stand.'
    } catch {
        $async.Error = $_.Exception.Message
        $async.Phase = 'Error'
        ALog ('FEHLER: ' + $_.Exception.Message)
    }
}

function Start-AppWorker($sb) {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('async', $async)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($sb.ToString())
    [void]$ps.BeginInvoke()
}

$atimer = New-Object Windows.Forms.Timer
$atimer.Interval = 300
$atimer.Add_Tick({
    try {
        while ($async.Log.Count -gt 0) { $txtAppLog.AppendText($async.Log.Dequeue() + "`r`n") }
        switch ($async.Phase) {
            'Load' { $lblAppStatus.Text = 'Lade App-Liste vom Handy...' }
            'Uninstall' { $lblAppStatus.Text = 'Deinstalliere: ' + $async.Status }
            'Loaded' {
                $lvApps.BeginUpdate()
                $lvApps.Items.Clear()
                foreach ($p in $async.Pkgs) {
                    $li = $lvApps.Items.Add($p.Pkg)
                    [void]$li.SubItems.Add($p.Ver)
                }
                $lvApps.EndUpdate()
                $btnAppUninstall.Enabled = $true
                $lblAppStatus.Text = $async.Pkgs.Count.ToString() + ' Dritt-Apps geladen. Auswahl markieren, dann "sauber deinstallieren".'
                $async.Phase = 'Idle'
            }
            'Done' {
                $lblAppStatus.Text = 'Fertig. Fuer den aktuellen Stand erneut "Liste laden".'
                $async.Phase = 'Idle'
            }
            'Error' {
                $lblAppStatus.Text = 'Fehler: ' + $async.Error
                $async.Phase = 'Idle'
            }
        }
    } catch { }
})
$appForm.Add_FormClosed({ $atimer.Stop() })

$btnApps.Add_Click({
    $adb = Find-Adb
    if (-not $adb) {
        [Windows.Forms.MessageBox]::Show($form,
            ("adb.exe nicht gefunden. Bitte ALLE Dateien aus der ZIP (inkl. platform-tools) in EINEN Ordner entpacken.`r`n" +
             "Am Handy: USB-Debugging aktivieren (Entwickleroptionen) und diesem PC vertrauen."),
            'adb nicht gefunden', 'OK', 'Warning')
        return
    }
    $script:adbPath = $adb
    $txtAppLog.Clear()
    $lvApps.Items.Clear()
    $atimer.Start()
    [void]$appForm.ShowDialog($form)
})

$btnAppLoad.Add_Click({
    if (-not $script:adbPath) { $script:adbPath = Find-Adb }
    if (-not $script:adbPath) { return }
    $async.Job = @{ Adb = $script:adbPath }
    $async.Phase = 'Load'
    Start-AppWorker $appListScript
})

$btnAppUninstall.Add_Click({
    if ($async.Phase -in 'Load', 'Uninstall') { return }
    $pkgs = @()
    foreach ($it in $lvApps.SelectedItems) { $pkgs += $it.Text }
    if ($pkgs.Count -eq 0) {
        [Windows.Forms.MessageBox]::Show($appForm, 'Bitte zuerst in der Liste eine oder mehrere Apps markieren.', 'Hinweis', 'OK', 'Information')
        return
    }
    $msg = $pkgs.Count.ToString() + ' App(s) SAUBER deinstallieren?' + "`r`n`r`n"
    $msg += (($pkgs | Select-Object -First 8) -join "`r`n")
    if ($pkgs.Count -gt 8) { $msg += "`r`n..." }
    $msg += "`r`n`r`n" + 'Die Apps werden entfernt und ihre Restordner (data/obb) geloescht.' + "`r`n" + 'Das kann NICHT rueckgaengig gemacht werden.'
    $r = [Windows.Forms.MessageBox]::Show($appForm, $msg, 'Sauber deinstallieren', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    $async.Job = @{ Adb = $script:adbPath; Pkgs = $pkgs }
    $async.Phase = 'Uninstall'
    Start-AppWorker $appUninstallScript
})

$btnAppClose.Add_Click({ $appForm.Close() })

$clbFilter.Add_ItemCheck({
    param($s, $e)
    if ($script:inFilter) { return }
    $script:inFilter = $true
    try {
        if ($e.Index -eq 0 -and $e.NewValue -eq 'Checked') {
            for ($i = 1; $i -lt $clbFilter.Items.Count; $i++) { $clbFilter.SetItemChecked($i, $false) }
        } elseif ($e.Index -gt 0 -and $e.NewValue -eq 'Checked') {
            $clbFilter.SetItemChecked(0, $false)
        }
        $any = $false
        for ($i = 0; $i -lt $clbFilter.Items.Count; $i++) {
            $st = if ($i -eq $e.Index) { ($e.NewValue -eq 'Checked') } else { $clbFilter.GetItemChecked($i) }
            if ($st) { $any = $true }
        }
        if (-not $any) { $clbFilter.SetItemChecked(0, $true) }
        $newSet = Get-FilterExts $e.Index ($e.NewValue -eq 'Checked')
        $script:extSetUI = $newSet
        if ($newSet) {
            Start-Search $newSet
        } else {
            $lblSearchInfo.Text = ''
            $btnUp.Enabled = $true
            try { Show-Folder $script:navStack } catch { }
        }
    } finally { $script:inFilter = $false }
})

$txtFilterExtra.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq 'Enter') {
        $s2 = Get-FilterExts -1 $false
        if ($s2) { $script:extSetUI = $s2; Start-Search }
    }
})

$btnCleanOpen.Add_Click({
    if ($script:busy) { return }
    if ($script:volIndex -lt 0) {
        [Windows.Forms.MessageBox]::Show($form, 'Bitte zuerst das Telefon verbinden (Hauptfenster).', 'Hinweis', 'OK', 'Warning')
        return
    }
    $clb.Items.Clear()
    $txtCleanLog.Clear()
    $lblCleanStatus.Text = 'Bereit. Bitte "Scannen" klicken.'
    $btnClean.Enabled = $false
    $ctimer.Start()
    [void]$cleanForm.ShowDialog($form)
})

$cleanForm.Add_FormClosed({ $ctimer.Stop() })

$btnScan.Add_Click({
    if ($csync.Phase -eq 'Scan' -or $csync.Phase -eq 'Delete') { return }
    $csync.Error = ''
    $csync.Job = @{ PhoneMatch = $PhoneMatch; VolumeName = $script:volumes[$script:volIndex].Name }
    $btnClean.Enabled = $false
    Start-CleanWorker $cleanScanScript
})

$btnClean.Add_Click({
    if ($csync.Phase -eq 'Scan' -or $csync.Phase -eq 'Delete') { return }
    $paths = @()
    foreach ($i in $clb.CheckedIndices) { $paths += @($csync.Cats)[$i].Paths }
    $paths = @($paths | Where-Object { $_ })
    if ($paths.Count -eq 0) {
        [Windows.Forms.MessageBox]::Show($cleanForm, 'Bitte zuerst Kategorien anhaekeln und scannen.', 'Hinweis', 'OK', 'Warning')
        return
    }
    $r = [Windows.Forms.MessageBox]::Show($cleanForm,
        ('Sollen jetzt ' + $paths.Count + ' Cache-/Muellelemente endgueltig vom Telefon geloescht werden?' + "`r`n`r`n" + 'Eigene Dateien (Fotos, Dokumente, Musik) werden NICHT geloescht.'),
        'Loeschen bestaetigen', 'YesNo', 'Warning')
    if ($r -ne [Windows.Forms.DialogResult]::Yes) { return }
    $csync.DeletePaths = $paths
    Start-CleanWorker $cleanDeleteScript
})

$btnCleanClose.Add_Click({ $cleanForm.Close() })

$btnAdb.Add_Click({
    $adb = Find-Adb
    if (-not $adb) {
        [Windows.Forms.MessageBox]::Show($cleanForm,
            ("adb.exe wurde nicht gefunden.`r`n`r`n" +
             "adb liegt dem Programm eigentlich IM ORDNER 'platform-tools' bei.`r`n" +
             "Bitte ALLE Dateien aus der ZIP (inkl. platform-tools) in EINEN gemeinsamen Ordner entpacken.`r`n`r`n" +
             "Am Handy ausserdem USB-DEBUGGING aktivieren (Entwickleroptionen) und diesem PC vertrauen.`r`n" +
             "Details stehen in der ANLEITUNG.txt."),
            'adb nicht gefunden', 'OK', 'Information')
        return
    }
    $r = [Windows.Forms.MessageBox]::Show($cleanForm,
        ("App-Caches jetzt systemseitig per adb leeren?`r`n`r`nBefehl: adb shell pm trim-caches 8G`r`n`r`n" +
         "Das ist sicher: Android loescht nur App-Zwischendaten, keine eigenen Dateien.`r`n" +
         "Voraussetzung: USB-Debugging ist am Handy aktiviert."),
        'App-Cache leeren (adb)', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    $csync.Job = @{ AdbPath = $adb }
    $csync.Phase = 'Adb'
    Start-CleanWorker $cleanAdbScript
})

$ctimer = New-Object Windows.Forms.Timer
$ctimer.Interval = 300
$ctimer.Add_Tick({
    try {
        while ($csync.Log.Count -gt 0) { $txtCleanLog.AppendText($csync.Log.Dequeue() + "`r`n") }
        switch ($csync.Phase) {
            'Scan' { $lblCleanStatus.Text = 'Scanne... ' + $csync.Status }
            'Delete' { $lblCleanStatus.Text = 'Loesche ausgewaehlte Elemente...' }
            'Adb' { $lblCleanStatus.Text = 'adb laeuft (pm trim-caches) - bitte warten...' }
            'Scanned' {
                $clb.BeginUpdate()
                $clb.Items.Clear()
                foreach ($c in $csync.Cats) {
                    [void]$clb.Items.Add(($c.Label + '   [' + (Format-Size $c.Size) + ', ' + $c.Count + ' Datei(en)]'))
                }
                $clb.EndUpdate()
                $btnClean.Enabled = $true
                $lblCleanStatus.Text = 'Scan fertig. Kategorien anhaekeln und "Auswahl loeschen" klicken.'
                $csync.Phase = 'Idle'
            }
            'Deleted' {
                $lblCleanStatus.Text = 'Bereinigung abgeschlossen. Fuer aktuelle Groessen erneut "Scannen".'
                $csync.Phase = 'Idle'
            }
            'Error' {
                $lblCleanStatus.Text = 'Fehler: ' + $csync.Error
                $csync.Phase = 'Idle'
            }
        }
    } catch { }
})

# ======================= Events ========================
$tree.Add_BeforeExpand({
    param($s, $e)
    if ($null -eq $e.Node.Tag) { return }
    if (-not $e.Node.Tag.Loaded) {
        try {
            $e.Node.Nodes.Clear()
            Populate-Children $e.Node
            $e.Node.Tag.Loaded = $true
        } catch {
            Log ('Fehler beim Aufklappen: ' + $_.Exception.Message)
        }
    }
})

$tree.Add_AfterCheck({
    param($s, $e)
    if ($script:inCheck) { return }
    if ($null -eq $e.Node.Tag) { return }
    $script:inCheck = $true
    try { Cascade-Check $e.Node $e.Node.Checked }
    finally { $script:inCheck = $false }
})

$list.Add_DoubleClick({
    $it = $list.SelectedItems | Select-Object -First 1
    if ($null -eq $it -or $null -eq $it.Tag) { return }
    if ($script:viewMode -eq 'results') {
        if ($it.Tag.IsFolder) { Show-Drill $it.Tag.Rel }
        return
    }
    if ($script:viewMode -eq 'drill') {
        if ($it.Tag.IsFolder) { Show-Drill $it.Tag.Rel }
        else { Start-FileCopy @($it.Tag.Rel) }
        return
    }
    if ($it.Tag.IsFolder) { Show-Folder ($script:navStack + @($it.Tag.Name)) }
})

$list.Add_SelectedIndexChanged({ Update-ActionButtons })

# Klick auf einen Ordner LINKS im Baum = rechts sofort dessen Inhalt/Dateien zeigen
$tree.Add_AfterSelect({
    param($s, $e)
    if ($null -eq $e.Node.Tag) { return }
    try { Show-Folder $e.Node.Tag.Path } catch { }
})

$btnUp.Add_Click({
    if ($script:viewMode -eq 'drill') {
        if ($script:searchStack.Count -gt 1) { Show-Drill (@($script:searchStack[0..($script:searchStack.Count - 2)]) -join '\') }
        else { Show-SearchResults }
        return
    }
    if ($script:viewMode -eq 'results') { return }
    if ($script:navStack.Count -gt 1) {
        Show-Folder ($script:navStack[0..($script:navStack.Count - 2)])
    } elseif ($script:navStack.Count -eq 1) {
        Show-Folder @()
    }
})

$btnNavRefresh.Add_Click({
    if ($script:busy) { return }
    if ($script:extSetUI) { Start-Search; return }
    try { Show-Folder $script:navStack } catch { }
})

$btnView.Add_Click({
    $script:iconView = -not $script:iconView
    if ($script:iconView) {
        $btnView.Text = 'Ansicht: Liste'
        $list.View = 'LargeIcon'
    } else {
        $btnView.Text = 'Ansicht: Miniaturen'
        $list.View = 'Details'
    }
    if ($script:viewMode -eq 'results') { Show-SearchResults }
    elseif ($script:viewMode -eq 'drill' -and $script:searchStack.Count -gt 0) { Show-Drill ($script:searchStack -join '\') }
    else { try { Show-Folder $script:navStack } catch { } }
})

$btnSearchPhone.Add_Click({
    if ($script:busy -or $script:searching) { return }
    $s = Get-FilterExts -1 $false
    if (-not $s) {
        [Windows.Forms.MessageBox]::Show($form, 'Bitte zuerst mindestens eine Datei-Kategorie anhaekeln (z.B. Bilder, Videos oder APK) oder eigene Endungen eingeben.', 'Hinweis', 'OK', 'Information')
        return
    }
    $script:extSetUI = $s
    Start-Search $s
})

$chkSys.Add_CheckedChanged({
    $script:showSys = $chkSys.Checked
    if ($script:busy) { return }
    if ($script:extSetUI) { Start-Search }
    elseif ($script:viewMode -eq 'drill' -and $script:searchStack.Count -gt 0) { Show-Drill ($script:searchStack -join '\') }
    elseif ($script:viewMode -eq 'results') { Show-SearchResults }
    else { try { Show-Folder $script:navStack } catch { } }
})

$btnRefreshVol.Add_Click({ Refresh-All $false })

$rbInternal.Add_Click({
    if ($script:intVol) { Select-VolIndex ([array]::IndexOf($script:volumes, $script:intVol)) }
})
$rbExternal.Add_Click({
    if ($script:extVol) { Select-VolIndex ([array]::IndexOf($script:volumes, $script:extVol)) }
})

$btnBrowse.Add_Click({
    $dlg = New-Object Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Zielordner auswählen'
    if ($txtDest.Text -and (Test-Path -LiteralPath $txtDest.Text)) { $dlg.SelectedPath = $txtDest.Text }
    if ($dlg.ShowDialog($form) -eq 'OK') { $txtDest.Text = $dlg.SelectedPath }
})

$btnCancel.Add_Click({
    $sync.Cancel = $true
    $lblStatus.Text = 'Abbruch wird vorbereitet (laufende Teil-Kopie wird noch beendet)...'
    Log 'Abbruch angefordert.'
})

$btnStart.Add_Click({
    if ($script:busy) { return }
    if ($script:volIndex -lt 0) {
        [Windows.Forms.MessageBox]::Show($form, 'Bitte zuerst das Telefon verbinden und einen Speicher auswählen (oben links).', 'Hinweis', 'OK', 'Warning')
        return
    }
    $sel = Get-Selection
    if ($sel.Count -eq 0) {
        [Windows.Forms.MessageBox]::Show($form, 'Bitte links in der Baumansicht Häkchen bei den Ordnern setzen, die kopiert werden sollen.', 'Hinweis', 'OK', 'Warning')
        return
    }
    $dest = $txtDest.Text.Trim()
    if (-not $dest) {
        [Windows.Forms.MessageBox]::Show($form, 'Bitte einen Zielordner angeben.', 'Hinweis', 'OK', 'Warning')
        return
    }
    try {
        if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
    } catch {
        [Windows.Forms.MessageBox]::Show($form, ('Zielordner konnte nicht angelegt werden:' + "`r`n" + $_.Exception.Message), 'Fehler', 'OK', 'Error')
        return
    }
    Save-Config

    Start-CopyJob $sel $dest
})

# Gemeinsamer Start fuer Baum-Auswahl und 'Ordner komplett kopieren'
function Start-CopyJob($sel, [string]$dest, [bool]$wholeFolder = $false) {
    $dest = $dest.Trim()
    if (-not $dest) {
        [Windows.Forms.MessageBox]::Show($form, 'Bitte einen Zielordner angeben.', 'Hinweis', 'OK', 'Warning')
        return
    }
    try {
        if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
    } catch {
        [Windows.Forms.MessageBox]::Show($form, ('Zielordner konnte nicht angelegt werden:' + "`r`n" + $_.Exception.Message), 'Fehler', 'OK', 'Error')
        return
    }
    Save-Config
    # Zustand zuruecksetzen
    $sync.Phase = 'Scan'
    $sync.Cancel = $false
    $sync.ScanFiles = 0; $sync.ScanBytes = [long]0; $sync.ScanStatus = ''
    $sync.TotalFiles = 0; $sync.TotalBytes = [long]0
    $sync.DoneFiles = 0; $sync.DoneBytes = [long]0; $sync.SkippedFiles = 0
    $sync.CurrentFolder = ''; $sync.CurrentFile = ''
    $sync.ErrorMsg = ''
    $sync.ErrorFile = ''; $sync.ErrorCount = 0
    $sync.Question = $null; $sync.Answered = $true
    $sync.DupSamples.Clear()
    $pbOverall.Value = 0
    $pbOverall.Style = 'Marquee'
    $lblOverall.Text = ''
    $lblDetail.Text = ''
    $lblFile.Text = ''
    $script:notified = $false

    $filterExts = if ($wholeFolder) { $null } else { Get-FilterExts -1 $false }
    if ($filterExts) { Log ('Filter aktiv: ' + (($filterExts.Keys | Sort-Object) -join ', ')) }
    if ($wholeFolder) { Log 'Ganzer Ordner wird kopiert (Filter fuer diesen Lauf ignoriert).' }

    $sync.Job = @{
        PhoneMatch  = $PhoneMatch
        VolumeName  = $script:volumes[$script:volIndex].Name
        VolumeKind  = $script:volumes[$script:volIndex].Kind
        Dest        = $dest
        PhoneName   = $(if ($script:phoneName) { $script:phoneName } else { $PhoneMatch })
        Selections  = @($sel | ForEach-Object { $_ })
        FilterExts  = $filterExts
        Turbo       = ($chkTurbo.Checked -and $chkTurbo.Enabled)
        Incremental = $chkIncr.Checked
        ExifSort    = $chkExif.Checked
        AdbPath     = $script:adbPath
    }

    Start-Worker
    $script:busy = $true
    $script:searching = $false
    $btnStart.Enabled = $false
    $btnCancel.Enabled = $true
    $tree.Enabled = $false
    $rbInternal.Enabled = $false
    $rbExternal.Enabled = $false
    Update-ActionButtons
    Log ('Start: ' + $sel.Count + ' Ordner ausgewählt. Ziel: ' + $dest)
}

$btnCopySel.Add_Click({
    if ($script:busy) { return }
    $rels = @()
    foreach ($it in $list.SelectedItems) { if ($it.Tag -and -not $it.Tag.IsFolder) { $rels += $it.Tag.Rel } }
    if ($rels.Count -gt 0) { Start-FileCopy $rels }
})

$btnCopyFolder.Add_Click({
    if ($script:busy) { return }
    $pathArr = $null
    if ($script:viewMode -eq 'drill' -and $script:searchStack.Count -gt 0) { $pathArr = @($script:searchStack) }
    elseif ($script:viewMode -eq 'browser' -and $script:navStack.Count -gt 0) { $pathArr = @($script:navStack) }
    if (-not $pathArr -or $pathArr.Count -eq 0) { return }
    $holes = New-Object System.Collections.Generic.List[string]
    $sel = @(@{ Path = $pathArr; Name = $pathArr[$pathArr.Count - 1]; Holes = $holes })
    Start-CopyJob $sel $txtDest.Text.Trim() $true
})

$form.Add_FormClosing({
    param($s, $e)
    if ($script:busy) { $sync.Cancel = $true }
})

$form.Add_Load({
    try { $split.SplitterDistance = 330 } catch { }
    try { $split.Panel1MinSize = 280 } catch { }
    try {
        $w = $toolbar.ClientSize.Width
        if ($w -gt 250) {
            $btnNavRefresh.Location = New-Object Drawing.Point($w - 99, 6)
            $btnApps.Location = New-Object Drawing.Point($w - 99 - 6 - 130, 6)
            $lblPath.Size = New-Object Drawing.Size($w - 195 - 136, 20)
        }
    } catch { }
})

# ======================= Timer: UI aktualisiert sich aus $sync =======================
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 300
$timer.Add_Tick({
    try {
        while ($sync.Log.Count -gt 0) { $txtLog.AppendText($sync.Log.Dequeue() + "`r`n") }

        if ($script:iconView) {
            while ($tsync.Q.Count -gt 0) {
                $te = $tsync.Q.Dequeue()
                $tkey = 'th_' + $te.N
                try {
                    if (-not $imgThumbs.Images.ContainsKey($tkey)) { [void]$imgThumbs.Images.Add($tkey, $te.B) }
                    foreach ($li in $list.Items) { if ($li.Text -eq $te.N) { $li.ImageKey = $tkey; break } }
                } catch { }
            }
        }

        if ($script:searching) {
            if ($fsync.Phase -eq 'Done') {
                $script:searching = $false
                if ($script:extSetUI) {
                    $script:searchMap = $fsync.Map
                    $script:searchList = @($script:searchMap.Keys | Sort-Object)
                    $lblSearchInfo.Text = 'Suche fertig: ' + $fsync.Files + ' Datei(en) in ' + $fsync.Folders + ' Ordner(n). Doppelklick = Ordner oeffnen.'
                    Log ('Filter-Suche fertig: ' + $fsync.Files + ' Datei(en) in ' + $fsync.Folders + ' Ordner(n).')
                    Show-SearchResults
                } else {
                    $lblSearchInfo.Text = ''
                }
            } elseif ($fsync.Phase -eq 'Error') {
                $script:searching = $false
                $lblSearchInfo.Text = 'Suche-Fehler: ' + $fsync.Error
            } else {
                $lblSearchInfo.Text = 'Filter-Suche laeuft... ' + $fsync.Files + ' Datei(en) gefunden   ' + $fsync.Status
            }
        }

        switch ($sync.Phase) {
            'Scan' {
                $lblStatus.Text = 'Durchsuchen: ' + $sync.ScanStatus
                $lblDetail.Text = $sync.ScanFiles.ToString('N0') + ' Dateien gefunden (' + (Format-Size $sync.ScanBytes) + ')'
                $lblFile.Text = ''
            }
            'Ask' {
                $lblStatus.Text = 'Frage zu doppelten Dateien wird angezeigt...'
            }
            'Sort' {
                $lblStatus.Text = 'Sortiere Fotos nach Aufnahmedatum... ' + $sync.CurrentFile
            }
            'Copy' {
                $pbOverall.Style = 'Continuous'
                $lblStatus.Text = 'Kopiere: ' + $sync.CurrentFolder
                if ($sync.TotalBytes -gt 0) {
                    $pct = [int]([Math]::Min(100, ($sync.DoneBytes * 100.0 / $sync.TotalBytes)))
                    if ($pct -lt 0) { $pct = 0 }
                    $pbOverall.Value = $pct
                    $lblOverall.Text = $pct.ToString() + ' %   (' + (Format-Size $sync.DoneBytes) + ' von ' + (Format-Size $sync.TotalBytes) + ')'
                }
                $lblDetail.Text = $sync.DoneFiles.ToString('N0') + ' / ' + $sync.TotalFiles.ToString('N0') + ' Dateien kopiert   -   übersprungen (Duplikate): ' + $sync.SkippedFiles
                $lblFile.Text = if ($sync.CurrentFile) { 'Aktuell: ' + $sync.CurrentFile } else { '' }
            }
        }

        if ((-not $sync.Answered) -and $sync.Question) {
            $timer.Stop()
            $r = [Windows.Forms.MessageBox]::Show($form, $sync.Question, 'Doppelte Dateien gefunden', 'YesNo', 'Question')
            $sync.OverwriteAnswer = ($r -eq [Windows.Forms.DialogResult]::Yes)
            $sync.Answered = $true
            $sync.QuestionEvent.Set() | Out-Null
            $timer.Start()
        }

        if ($script:busy -and $sync.Phase -in 'Done','Error','Canceled' -and -not $script:notified) {
            $script:notified = $true
            $script:busy = $false
            $pbOverall.Style = 'Continuous'
            if ($sync.Phase -eq 'Done') { $pbOverall.Value = 100; $lblOverall.Text = '100 %' }
            $btnStart.Enabled = $true
            $btnCancel.Enabled = $false
            $tree.Enabled = $true
            if ($script:intVol) { $rbInternal.Enabled = $true }
            if ($script:extVol) { $rbExternal.Enabled = $true }
            if ($sync.Phase -eq 'Done') {
                $lblStatus.Text = 'Fertig.'
                $msg = 'Kopiervorgang abgeschlossen.' + "`r`n`r`n" +
                       'Kopiert:      ' + $sync.DoneFiles.ToString('N0') + ' Dateien (' + (Format-Size $sync.DoneBytes) + ')' + "`r`n" +
                       'Übersprungen: ' + $sync.SkippedFiles.ToString('N0') + ' doppelte Dateien'
                if ($sync.ErrorCount -gt 0) {
                    $msg += "`r`n" + 'Fehler:       ' + $sync.ErrorCount.ToString('N0') + ' (Protokoll wird geoeffnet)'
                }
                if ($sync.SortCount -gt 0) {
                    $msg += "`r`n" + 'Fotos sortiert (Aufnahmedatum): ' + $sync.SortCount.ToString('N0') + ' -> Fotos_sortiert\Jahr-Monat'
                }
                $zielTxt = $txtDest.Text.Trim()
                if ($script:phoneName) { $zielTxt = Join-Path $zielTxt (Sanitize-Seg $script:phoneName) }
                $msg += "`r`n`r`n" + 'Ziel: ' + $zielTxt
                [Windows.Forms.MessageBox]::Show($form, $msg, 'Fertig', 'OK', 'Information')
                if ($sync.ErrorCount -gt 0) {
                    try { Start-Process notepad.exe $sync.ErrorFile } catch { }
                }
            } elseif ($sync.Phase -eq 'Canceled') {
                $lblStatus.Text = 'Abgebrochen.'
            } else {
                $lblStatus.Text = 'Fehler: ' + $sync.ErrorMsg
                [Windows.Forms.MessageBox]::Show($form, ('Fehler beim Kopieren:' + "`r`n`r`n" + $sync.ErrorMsg), 'Fehler', 'OK', 'Error')
            }
        }
    } catch {
        try { $txtLog.AppendText('UI-Fehler: ' + $_.Exception.Message + "`r`n") } catch { }
    }
})
$timer.Start()

# ======================= Start =======================
Refresh-All $true
[void]$form.ShowDialog()

<#
  HandyKopieUI.ps1  -  Kopier-Tool mit grafischer Oberfläche
  ===========================================================
  - Baumansicht der Handy-Ordner (links) mit Kontrollkästchen zum Auswählen
  - Auswahl: Interner Speicher oder SD-Karte / externer Speicher
  - Rechte Seite: in den Ordnern navigieren (Doppelklick, "Hoch")
  - Zielordner frei wählbar
  - Live-Fortschrittsanzeige
  - Erkennt doppelte Dateien und fragt: trotzdem kopieren? Ja/Nein

  Start: powershell -STA -ExecutionPolicy Bypass -File HandyKopieUI.ps1
  (oder Doppelklick auf Start_HandyKopie_UI.bat)

  Hinweis: Duplikate werden anhand von Dateiname + Dateigröße erkannt.
#>
