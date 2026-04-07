<#
.SYNOPSIS
Autodesk ODIS Uninstaller Script

.DESCRIPTION
Gathers Autodesk ODIS metadata from:
C:\ProgramData\Autodesk\ODIS\metadata

Reads bundleManifest.xml files to identify installed Autodesk products and
allows targeted uninstall using the Autodesk ODIS installer.

Supports:
- Listing all detected products
- Matching products by name
- Interactive selection
- Silent uninstall using ODIS
- Optional force mode for remote execution

.NOTES
Version: 1.0.4
Author: Nick Oliver

.PARAMETER MetadataRoot
Root folder containing Autodesk ODIS metadata folders.

.PARAMETER InstallerPath
Path to the Autodesk ODIS installer executable.

.PARAMETER LogRoot
Folder used for script log output.

.PARAMETER MatchName
Filters detected products by partial product name. Example: "AutoCAD 2025"

.PARAMETER ListOnly
Displays all detected ODIS products and exits.

.PARAMETER Commit
Executes uninstall for matched or selected items.

.PARAMETER Interactive
Allows selection of products by number.

.PARAMETER CaseSensitive
Enables case-sensitive matching for product names.

.PARAMETER Force
Skips the additional YES confirmation prompt when -Commit is used.

.PARAMETER Help
Displays script examples by default for quick admin use.

.PARAMETER HelpMode
Controls the type of help shown when -Help is used.
Valid values: Examples, Basic, Full

.EXAMPLE
.\Invoke-AutodeskODISUninstallByName-Force-Help.ps1 -ListOnly

Lists all detected Autodesk ODIS products.

.EXAMPLE
.\Invoke-AutodeskODISUninstallByName-Force-Help.ps1 -MatchName "AutoCAD 2025"

Previews matching AutoCAD 2025 entries.

.EXAMPLE
.\Invoke-AutodeskODISUninstallByName-Force-Help.ps1 -MatchName "AutoCAD 2025" -Commit

Prompts for YES and then uninstalls matching AutoCAD 2025 entries.

.EXAMPLE
.\Invoke-AutodeskODISUninstallByName-Force-Help.ps1 -MatchName "AutoCAD 2025" -Commit -Force

Uninstalls matching AutoCAD 2025 entries without the extra YES prompt.

.EXAMPLE
.\Invoke-AutodeskODISUninstallByName-Force-Help.ps1 -Interactive -Commit -Force

Lets an admin select entries by number and then uninstalls them without the extra YES prompt.

.EXAMPLE
.\Invoke-AutodeskODISUninstallByName-ExamplesDefault.ps1 -Help

Displays examples only for quick reference.

.EXAMPLE
.\Invoke-AutodeskODISUninstallByName-ExamplesDefault.ps1 -Help -HelpMode Basic

Displays basic help.

.EXAMPLE
.\Invoke-AutodeskODISUninstallByName-ExamplesDefault.ps1 -Help -HelpMode Full

Displays full help for the script.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$MetadataRoot = "C:\ProgramData\Autodesk\ODIS\metadata",
    [string]$InstallerPath = "C:\Program Files\Autodesk\AdODIS\V1\Installer.exe",
    [string]$LogRoot = "C:\Autodesk\ODIS\Logs",
    [string]$MatchName,
    [switch]$ListOnly,
    [switch]$Commit,
    [switch]$Interactive,
    [switch]$CaseSensitive,
    [switch]$Force,
    [switch]$Help,
    [ValidateSet('Examples','Basic','Full')]
    [string]$HelpMode = 'Examples'
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($Help) {
    switch ($HelpMode) {
        'Examples' { Get-Help $MyInvocation.MyCommand.Path -Examples }
        'Basic'    { Get-Help $MyInvocation.MyCommand.Path }
        'Full'     { Get-Help $MyInvocation.MyCommand.Path -Full }
    }
    return
}

function New-Folder {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','ACTION')][string]$Level = 'INFO'
    )
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    $line | Tee-Object -FilePath $script:LogPath -Append
}

function Get-YearFromText {
    param([string]$Text)
    if ($Text -match '\b(20\d{2})\b') { return [int]$matches[1] }
    return $null
}

function Get-ProductHintFromManifest {
    param([Parameter(Mandatory)][string]$ManifestPath)

    $raw = Get-Content -LiteralPath $ManifestPath -Raw -ErrorAction Stop

    $patterns = @(
        '(?i)\bAutodesk AutoCAD(?:\s+[A-Za-z0-9&\-\(\)]+){0,8}\s+20\d{2}\b',
        '(?i)\bAutoCAD LT\s+20\d{2}\b',
        '(?i)\bAutoCAD(?:\s+[A-Za-z0-9&\-\(\)]+){0,8}\s+20\d{2}\b',
        '(?i)\bAutodesk Revit(?:\s+[A-Za-z0-9&\-\(\)]+){0,8}\s+20\d{2}\b',
        '(?i)\bRevit(?:\s+[A-Za-z0-9&\-\(\)]+){0,8}\s+20\d{2}\b',
        '(?i)\bCivil 3D\s+20\d{2}\b',
        '(?i)\bInventor(?:\s+[A-Za-z0-9&\-\(\)]+){0,8}\s+20\d{2}\b',
        '(?i)\bNavisworks(?:\s+[A-Za-z0-9&\-\(\)]+){0,8}\s+20\d{2}\b',
        '(?i)\bDWG TrueView\s+20\d{2}\b'
    )

    $hits = foreach ($pattern in $patterns) {
        [regex]::Matches($raw, $pattern) | ForEach-Object { $_.Value.Trim() }
    }

    $hits = $hits | Select-Object -Unique
    if ($hits) {
        return ($hits | Sort-Object Length -Descending | Select-Object -First 1)
    }

    try {
        [xml]$xml = $raw
        $nameNodes = $xml.SelectNodes("//*[local-name()='DisplayName' or local-name()='ProductName' or local-name()='Name' or local-name()='Title']")
        $nameText = foreach ($node in $nameNodes) {
            $value = [string]$node.InnerText
            if (-not [string]::IsNullOrWhiteSpace($value)) { $value.Trim() }
        }
        $nameText = $nameText | Select-Object -Unique
        if ($nameText) {
            return ($nameText | Sort-Object Length -Descending | Select-Object -First 1)
        }
    }
    catch {}

    return $null
}

function Get-ODISInventory {
    if (-not (Test-Path -LiteralPath $MetadataRoot)) {
        throw "Metadata root not found: $MetadataRoot"
    }

    Get-ChildItem -LiteralPath $MetadataRoot -Directory -ErrorAction Stop | ForEach-Object {
        $folder = $_
        $manifest = Join-Path $folder.FullName "bundleManifest.xml"
        if (-not (Test-Path -LiteralPath $manifest)) { return }

        $hint = $null
        try {
            $hint = Get-ProductHintFromManifest -ManifestPath $manifest
        }
        catch {
            Write-Log "Failed reading manifest $manifest :: $($_.Exception.Message)" "WARN"
        }

        [PSCustomObject]@{
            ProductHint    = $hint
            Year           = Get-YearFromText -Text $hint
            MetadataFolder = $folder.Name
            ManifestPath   = $manifest
            UninstallCmd   = '"{0}" -i uninstall -q -m "{1}"' -f $InstallerPath, $manifest
        }
    } | Sort-Object ProductHint, MetadataFolder
}

function Test-NameMatch {
    param(
        [string]$Text,
        [string]$Pattern
    )

    if ([string]::IsNullOrWhiteSpace($Pattern)) { return $true }
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }

    if ($CaseSensitive) {
        return $Text -like "*$Pattern*"
    }
    else {
        return $Text.ToLower().Contains($Pattern.ToLower())
    }
}

function Show-Inventory {
    param([Parameter(Mandatory)][object[]]$Items)

    Write-Host ""
    Write-Host "ODIS product inventory:" -ForegroundColor Green
    Write-Host ""
    $i = 1
    foreach ($item in $Items) {
        Write-Host ("[{0}] {1}" -f $i, $(if($item.ProductHint){$item.ProductHint}else{"<Unknown Product>"})) -ForegroundColor Cyan
        Write-Host ("     Year          : {0}" -f $item.Year)
        Write-Host ("     MetadataFolder: {0}" -f $item.MetadataFolder)
        Write-Host ("     ManifestPath  : {0}" -f $item.ManifestPath)
        Write-Host ""
        $i++
    }
}

function Read-Selection {
    param([Parameter(Mandatory)][object[]]$Items)

    while ($true) {
        $value = Read-Host "Enter item numbers (example: 1,3 or 2-4 or all or q)"
        if ([string]::IsNullOrWhiteSpace($value)) { continue }

        if ($value -match '^(?i)q$') { return @() }
        if ($value -match '^(?i)all$') { return @($Items) }

        $indexes = New-Object System.Collections.Generic.List[int]
        $ok = $true

        foreach ($part in ($value -split ',')) {
            $piece = $part.Trim()

            if ($piece -match '^\d+$') {
                $n = [int]$piece
                if ($n -lt 1 -or $n -gt $Items.Count) { $ok = $false; break }
                $indexes.Add($n)
                continue
            }

            if ($piece -match '^(\d+)\s*-\s*(\d+)$') {
                $start = [int]$matches[1]
                $end = [int]$matches[2]
                if ($start -gt $end) {
                    $tmp = $start
                    $start = $end
                    $end = $tmp
                }
                if ($start -lt 1 -or $end -gt $Items.Count) { $ok = $false; break }
                foreach ($n in $start..$end) { $indexes.Add($n) }
                continue
            }

            $ok = $false
            break
        }

        if (-not $ok) {
            Write-Host "Invalid selection. Try again." -ForegroundColor Yellow
            continue
        }

        return @(foreach ($idx in ($indexes | Select-Object -Unique | Sort-Object)) { $Items[$idx - 1] })
    }
}

New-Folder -Path $LogRoot
$script:LogPath = Join-Path $LogRoot ("Invoke-AutodeskODISUninstallByName_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

if (-not (Test-Path -LiteralPath $InstallerPath)) {
    throw "Installer path not found: $InstallerPath"
}

Write-Log "Starting ODIS scan. MatchName=$MatchName ListOnly=$ListOnly Commit=$Commit Interactive=$Interactive Force=$Force"

$inventory = @(Get-ODISInventory)

if (-not $inventory -or $inventory.Count -eq 0) {
    Write-Log "No ODIS metadata entries found." "WARN"
    Write-Host "No ODIS metadata entries found." -ForegroundColor Yellow
    Write-Host "Log file: $script:LogPath" -ForegroundColor Cyan
    return
}

foreach ($item in $inventory) {
    Write-Log ("Found: {0} | Year={1} | Folder={2}" -f $(if($item.ProductHint){$item.ProductHint}else{"<Unknown Product>"}), $item.Year, $item.MetadataFolder)
}

if ($ListOnly -or (-not $MatchName -and -not $Interactive -and -not $Commit)) {
    Show-Inventory -Items $inventory
    Write-Host "Log file: $script:LogPath" -ForegroundColor Cyan
    return
}

$targets = @()

if ($Interactive) {
    Show-Inventory -Items $inventory
    $targets = @(Read-Selection -Items $inventory)
}
else {
    $targets = @($inventory | Where-Object { Test-NameMatch -Text $_.ProductHint -Pattern $MatchName })
}

if (-not $targets -or $targets.Count -eq 0) {
    Write-Log "No entries matched the requested selection." "WARN"
    Write-Host "No entries matched the requested selection." -ForegroundColor Yellow
    Write-Host "Log file: $script:LogPath" -ForegroundColor Cyan
    return
}

Write-Host ""
Write-Host "Matched uninstall targets:" -ForegroundColor Green
$targets | Format-Table ProductHint, Year, MetadataFolder -AutoSize

foreach ($target in $targets) {
    Write-Log ("TARGET: {0} | Folder={1}" -f $target.ProductHint, $target.MetadataFolder)
    Write-Log ("COMMAND: {0}" -f $target.UninstallCmd) "ACTION"
}

if (-not $Commit) {
    Write-Host ""
    Write-Host "Preview only. Re-run with -Commit to uninstall the matched items." -ForegroundColor Yellow
    Write-Host "Log file: $script:LogPath" -ForegroundColor Cyan
    return
}

if (-not $Force) {
    $answer = Read-Host "Type YES to commit uninstall"
    if ($answer -cne 'YES') {
        Write-Log "Commit cancelled by user."
        Write-Host "Cancelled." -ForegroundColor Yellow
        Write-Host "Log file: $script:LogPath" -ForegroundColor Cyan
        return
    }
}
else {
    Write-Log "Force switch detected. Skipping interactive YES confirmation." "WARN"
}

foreach ($target in $targets) {
    if ($PSCmdlet.ShouldProcess($target.ProductHint, "ODIS uninstall")) {
        try {
            Write-Log ("Executing uninstall for {0}" -f $target.ProductHint) "ACTION"
            $proc = Start-Process -FilePath $InstallerPath -ArgumentList @('-i','uninstall','-q','-m', $target.ManifestPath) -Wait -PassThru -WindowStyle Hidden
            Write-Log ("Exit code: {0}" -f $proc.ExitCode)

            if ($proc.ExitCode -notin 0,1605,1614,1641,3010) {
                Write-Log ("Unexpected exit code for {0}: {1}" -f $target.ProductHint, $proc.ExitCode) "WARN"
            }
        }
        catch {
            Write-Log ("Failed uninstall for {0}: {1}" -f $target.ProductHint, $_.Exception.Message) "ERROR"
        }
    }
}

Write-Host ""
Write-Host "Finished. Log file: $script:LogPath" -ForegroundColor Green
