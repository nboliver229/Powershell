param(
  [string]$Root = "C:\_build\GUIInstallProgress",
  [string]$ConfigJson = "C:\_build\GUIInstallProgress\Config\apps.json",
  [ValidateSet("Auto","Base","Prod","All")]
  [string]$Mode = "Auto",
  [int]$Port = 0,
  [int]$TimeoutSeconds = 7200,
  [switch]$TestMode,
  [switch]$NoLaunch,
  [switch]$ExitWhenBrowserClosed
)

Write-Host "Loading config JSON: $ConfigJson" -ForegroundColor Yellow

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function New-Folder([string]$p){ if(-not (Test-Path $p)){ New-Item -ItemType Directory -Path $p -Force | Out-Null } }

$WebDir = Join-Path $Root "Web"
$OutDir = Join-Path $Root "Output"
New-Folder $WebDir
New-Folder $OutDir

function Write-Log([string]$msg){
  $log = Join-Path $OutDir "GUIInstallProgress.log"
  $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  Add-Content -Path $log -Value "$ts  $msg"
}

function Get-FreeTcpPort {
  $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
  $l.Start()
  $p = $l.LocalEndpoint.Port
  $l.Stop()
  return $p
}

if(-not (Test-Path $ConfigJson)){ throw "Config JSON not found: $ConfigJson" }
$config = Get-Content -Path $ConfigJson -Raw | ConvertFrom-Json

$RefreshMs = [int]([int]$config.refreshSeconds * 1000)

# Log settings (defaults)
$LogEnabled = $false
$LogPath = ""
$LogTailLines = 400
$LogMaxBytes = 1048576
$LogRefreshMs = 1000
$CmtraceCandidates = @()

# StrictMode-safe: log config is optional
$logCfg = $null
if($config.PSObject.Properties.Name -contains 'log'){
  $logCfg = $config.log
}

if($null -ne $logCfg -and 
   ($logCfg.PSObject.Properties.Name -contains 'enabled') -and 
   $logCfg.enabled){

  $LogEnabled = $true
  $LogPath = [string]$logCfg.path

  if($logCfg.PSObject.Properties.Name -contains 'tailLines'){
    $LogTailLines = [int]$logCfg.tailLines
  }

  if($logCfg.PSObject.Properties.Name -contains 'maxBytes'){
    $LogMaxBytes = [int]$logCfg.maxBytes
  }

  if($logCfg.PSObject.Properties.Name -contains 'refreshSeconds'){
    $LogRefreshMs = [int]($logCfg.refreshSeconds * 1000)
  }

  if($logCfg.PSObject.Properties.Name -contains 'cmtraceCandidates'){
    $CmtraceCandidates = @(
      $logCfg.cmtraceCandidates | ForEach-Object { [string]$_ }
    )
  }
}

$AllGroups = @($config.groups)

function Get-DeploymentTypeFromRegistry {
  try {
    if(-not $config.modeDetection.enabled){ return $null }
    $rp = "$($config.modeDetection.registryPath)"
    $vn = "$($config.modeDetection.valueName)"
    if([string]::IsNullOrEmpty($rp) -or [string]::IsNullOrEmpty($vn)){ return $null }
    $p = Get-ItemProperty -Path $rp -Name $vn -ErrorAction SilentlyContinue
    if($null -eq $p){ return $null }
    return [string]$p.$vn
  } catch { return $null }
}

function Resolve-RunMode {
  if($Mode -eq "Base"){ return "Base" }
  if($Mode -eq "Prod"){ return "All" }
  if($Mode -eq "All"){ return "All" }

  $dt = Get-DeploymentTypeFromRegistry
  if([string]::IsNullOrEmpty($dt)){ return "All" }
  $v = $dt.Trim().ToLowerInvariant()
  if($v -eq "base"){ return "Base" }
  if($v -match "prod|production|engineer|full"){ return "All" }
  return "All"
}

$RunMode = Resolve-RunMode
$ActiveGroups = if($RunMode -eq "Base"){ $AllGroups | Where-Object { $_.id -eq "base" } } else { $AllGroups }
$ActiveGroupIds = @($ActiveGroups | ForEach-Object { "$($_.id)" })
$TotalTarget = ($ActiveGroups | ForEach-Object { [int]$_.targetCount } | Measure-Object -Sum).Sum

function Test-Check($c){
  $ok = $false
  $detail = ""
  $t = ("$($c.type)").ToLowerInvariant()
  try {
    switch ($t) {
      "file" { $ok = (Test-Path -LiteralPath $c.path); $detail = $c.path }
      "fileor" {
        foreach($p in @($c.paths)){ if(Test-Path -LiteralPath $p){ $ok=$true; break } }
        $detail = (@($c.paths) -join " OR ")
      }
      "regvalue" {
        $val = Get-ItemProperty -Path $c.path -Name $c.valueName -ErrorAction SilentlyContinue
        $ok = ($null -ne $val)
        $detail = "$($c.path)\$($c.valueName)"
      }
      default { $ok=$false; $detail = "Unknown type: $($c.type)" }
    }
  } catch {
    $ok=$false; $detail = "$detail (error: $($_.Exception.Message))"
  }
  [pscustomobject]@{ name=$c.name; ok=[bool]$ok; detail=$detail }
}

function Get-LogTail {
  if(-not $LogEnabled){
    return [pscustomobject]@{ enabled=$false; title="Log (disabled)"; sub=""; text="" }
  }
  if([string]::IsNullOrEmpty($LogPath)){
    return [pscustomobject]@{ enabled=$true; title="Log (live)"; sub=""; text="Log path not configured." }
  }
  if(-not (Test-Path -LiteralPath $LogPath)){
    return [pscustomobject]@{ enabled=$true; title="Log (live)"; sub=$LogPath; text="Log not found: $LogPath" }
  }

  try {
    $fi = Get-Item -LiteralPath $LogPath -ErrorAction Stop
    $fs = [System.IO.File]::Open($LogPath,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
    try{
      $len = $fs.Length
      $read = [Math]::Min($LogMaxBytes, $len)
      $null = $fs.Seek(-1 * $read, [System.IO.SeekOrigin]::End)
      $buf = New-Object byte[] $read
      [void]$fs.Read($buf,0,$read)
      # Heuristic: if there are lots of 0x00 bytes, it's likely UTF-16LE (common for Agent.log)
        $zeroCount = 0
        for($i=0; $i -lt [Math]::Min($buf.Length, 4096); $i++){
          if($buf[$i] -eq 0){ $zeroCount++ }
        }
        if($zeroCount -gt 200){
          $text = [System.Text.Encoding]::Unicode.GetString($buf)   # UTF-16LE
        } else {
          $text = [System.Text.Encoding]::UTF8.GetString($buf)
        }
      $text = $text -replace '^[^\r\n]*[\r\n]+',''  # drop partial line
      $lines = $text -split "\r?\n"
      if($lines.Count -gt $LogTailLines){
        $lines = $lines[($lines.Count-$LogTailLines)..($lines.Count-1)]
      }
      return [pscustomobject]@{
        enabled=$true
        title="Agent.log (live)"
        sub=("{0} • {1} bytes • {2}" -f $LogPath,$fi.Length,$fi.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss"))
        text=($lines -join "`n")
      }
    } finally { $fs.Close() }
  } catch {
    return [pscustomobject]@{ enabled=$true; title="Agent.log (live)"; sub=$LogPath; text="Error reading log: $($_.Exception.Message)" }
  }
}

function Find-CMTrace {
  $cands = @()
  if($CmtraceCandidates.Count -gt 0){ $cands += $CmtraceCandidates }
  $cands += @("C:\Windows\CCM\CMTrace.exe","C:\Windows\CCM\CMTrace_x64.exe")
  return ($cands | Where-Object { Test-Path $_ } | Select-Object -First 1)
}
function Open-LogInViewer {
  if(-not $LogEnabled){ return }
  if([string]::IsNullOrEmpty($LogPath)){ return }
  if(-not (Test-Path -LiteralPath $LogPath)){ return }
  $cm = Find-CMTrace
  try{
    if($cm){ Start-Process -FilePath $cm -ArgumentList "`"$LogPath`"" | Out-Null }
    else { Start-Process -FilePath "notepad.exe" -ArgumentList "`"$LogPath`"" | Out-Null }
  } catch {}
}

function Get-AppStatus {
  $groupResults = @()
  foreach($g in $ActiveGroups){
    $items = foreach($c in @($g.checks)){ Test-Check $c }
    $count = ($items | Where-Object { $_.ok }).Count
    $target = [int]$g.targetCount
    $groupResults += [pscustomobject]@{ id="$($g.id)"; name="$($g.name)"; target=$target; count=$count; done=($count -ge $target); items=$items }
  }
  $totalCount = ($groupResults | ForEach-Object { $_.count } | Measure-Object -Sum).Sum
  $suggested = if($RunMode -eq "Base"){ "base" } else { "all" }

  [pscustomobject]@{
    totalTarget=$TotalTarget
    totalCount=$totalCount
    done=($totalCount -ge $TotalTarget)
    now=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    refreshMs=$RefreshMs
    logRefreshMs=$LogRefreshMs
    mode=$RunMode
    suggestedFilter=$suggested
    activeGroupIds=$ActiveGroupIds
    groups=$groupResults
  }
}

function Send-Json($ctx, $obj){
  $json = $obj | ConvertTo-Json -Depth 8
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  $ctx.Response.ContentType = "application/json; charset=utf-8"
  $ctx.Response.ContentLength64 = $bytes.Length
  $ctx.Response.OutputStream.Write($bytes,0,$bytes.Length)
  $ctx.Response.OutputStream.Close()
}
function Send-File($ctx, $filePath){
  if(-not (Test-Path $filePath)){ $ctx.Response.StatusCode=404; $ctx.Response.OutputStream.Close(); return }
  $ext = [IO.Path]::GetExtension($filePath).ToLowerInvariant()
  switch($ext){
    ".html"{ $ctx.Response.ContentType="text/html; charset=utf-8" }
    ".js"  { $ctx.Response.ContentType="application/javascript; charset=utf-8" }
    ".css" { $ctx.Response.ContentType="text/css; charset=utf-8" }
    default{ $ctx.Response.ContentType="application/octet-stream" }
  }
  $bytes = [IO.File]::ReadAllBytes($filePath)
  $ctx.Response.ContentLength64 = $bytes.Length
  $ctx.Response.OutputStream.Write($bytes,0,$bytes.Length)
  $ctx.Response.OutputStream.Close()
}

if($Port -le 0){ $Port = Get-FreeTcpPort }
$prefix = "http://127.0.0.1:$Port/"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)
$listener.Start()

Write-Log "Started on $prefix | Mode=$Mode -> RunMode=$RunMode | ActiveGroups=$($ActiveGroupIds -join ',') | Target=$TotalTarget | LogEnabled=$LogEnabled"
Write-Host "GUIInstallProgress listening on $prefix" -ForegroundColor Cyan

$edgeProc = $null
if(-not $NoLaunch){
  $edge = @("$env:ProgramFiles(x86)\Microsoft\Edge\Application\msedge.exe","$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
  try{
    if($edge){ $edgeProc = Start-Process -FilePath $edge -ArgumentList "--app=$prefix","--window-size=1100,820","--no-first-run" -PassThru }
    else { $edgeProc = Start-Process -FilePath $prefix -PassThru }
    if($ExitWhenBrowserClosed){ Write-Log "ExitWhenBrowserClosed enabled." }
  } catch {
    Write-Log "Browser launch failed: $($_.Exception.Message)"
  }
}

$stopRequested=$false
$deadline=(Get-Date).AddSeconds($TimeoutSeconds)

try{
  while($listener.IsListening -and -not $stopRequested){
    if($ExitWhenBrowserClosed -and $edgeProc -and $edgeProc.HasExited){
      Write-Log "Browser process exited; stopping."
      break
    }
    if((Get-Date) -gt $deadline){ Write-Log "Timeout reached ($TimeoutSeconds seconds)."; break }

    $ar = $listener.BeginGetContext($null,$null)
    while(-not $ar.IsCompleted){
      Start-Sleep -Milliseconds 100
      if($ExitWhenBrowserClosed -and $edgeProc -and $edgeProc.HasExited){ break }
      if((Get-Date) -gt $deadline){ break }
    }
    if($ExitWhenBrowserClosed -and $edgeProc -and $edgeProc.HasExited){ break }
    if(-not $ar.IsCompleted){ break }

    $ctx = $listener.EndGetContext($ar)
    $req = $ctx.Request
    $path = $req.Url.AbsolutePath
    if([string]::IsNullOrEmpty($path)){ $path="/" }
    $path = $path.ToLowerInvariant()

    if($path -eq "/api/status"){
      $s = Get-AppStatus
      Send-Json $ctx $s
      if($s.done -and -not $TestMode){ Start-Sleep -Milliseconds 400; $stopRequested=$true }
      continue
    }
    if($path -eq "/api/log"){ Send-Json $ctx (Get-LogTail); continue }
    if($path -eq "/api/openlog" -and $req.HttpMethod -eq "POST"){ Open-LogInViewer; Send-Json $ctx ([pscustomobject]@{ok=$true}); continue }
    if($path -eq "/api/close" -and $req.HttpMethod -eq "POST"){ Send-Json $ctx ([pscustomobject]@{ok=$true}); $stopRequested=$true; continue }

    if($path -eq "/" -or $path -eq "/index.html"){ Send-File $ctx (Join-Path $WebDir "index.html"); continue }
    $local = Join-Path $WebDir ($path.TrimStart("/").Replace("/","\\"))
    Send-File $ctx $local
  }
} finally {
  try{ $listener.Stop() } catch {}
  try{ $listener.Close() } catch {}
  Write-Log "Stopped."
}

$final = Get-AppStatus
if($TestMode){ exit 0 }
if($final.done){ exit 0 } else { exit 1 }
