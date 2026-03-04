
[CmdletBinding()]
param(
  [switch]$Remediate,

  [string]$TaskXmlPath = "C:\Temp\HybridJoin.xml",
  [string]$XmlSourceUNC = "\\dlrgroup.com\data\Apps\Microsoft\Intune\HybridJoin.xml",
  [string]$CoMgmtLogPath = "C:\Windows\CCM\Logs\CoManagementHandler.log",
  [string]$OutLog = "C:\Temp\MDMHealthFix.log",
  [switch]$RestartCcmexecOnFix = $true
)

function Out-Line([string]$s){
  $s | Out-File -FilePath $OutLog -Append -Encoding utf8
  Write-Host $s
}

function Hdr([string]$title){
  Out-Line ""
  Out-Line ("=" * 78)
  Out-Line $title
  Out-Line ("=" * 78)
}

function Run-Cmd([string]$exe,[string]$args){
  Out-Line "  -> RUN: $exe $args"
  try{
    $p = Start-Process -FilePath $exe -ArgumentList $args -NoNewWindow -PassThru -Wait -ErrorAction Stop
    Out-Line "     ExitCode: $($p.ExitCode)"
    return $p.ExitCode
  } catch {
    Out-Line "     ERROR: $($_.Exception.Message)"
    return $null
  }
}

function Get-DsregStatus {
  $raw = & dsregcmd /status 2>$null
  if (-not $raw){ return $null }
  $text = ($raw -join "`n")

  function Get-Val($name){
    $m = [regex]::Match($text, "^\s*$name\s*:\s*(.+)\s*$", "Multiline")
    if ($m.Success){ $m.Groups[1].Value.Trim() } else { $null }
  }

  [pscustomobject]@{
    AzureAdJoined = Get-Val "AzureAdJoined"
    DomainJoined = Get-Val "DomainJoined"
    WorkplaceJoined = Get-Val "WorkplaceJoined"
    MdmUrl = Get-Val "MdmUrl"
  }
}

function Get-EnterpriseMgmtTaskCount {
    try {
        $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
            $_.TaskPath -like "\Microsoft\Windows\EnterpriseMgmt\*"
        }
        return $tasks.Count
    } catch {
        return 0
    }
}

function Ensure-HybridJoinXml {

    if (Test-Path $TaskXmlPath){
        Out-Line "  XML present: $TaskXmlPath"
        return $true
    }

    Out-Line "  XML missing locally. Attempting UNC copy..."

    if (!(Test-Path $XmlSourceUNC)){
        Out-Line "  ERROR: Cannot access $XmlSourceUNC"
        return $false
    }

    try{
        New-Item -ItemType Directory -Path (Split-Path $TaskXmlPath) -Force | Out-Null
        Copy-Item $XmlSourceUNC $TaskXmlPath -Force
        Out-Line "  XML copied from UNC."
        return $true
    } catch {
        Out-Line "  ERROR copying XML: $($_.Exception.Message)"
        return $false
    }
}

function Enable-JoinTask{
    Run-Cmd "schtasks.exe" "/Change /TN `"\Microsoft\Windows\Workplace Join\Automatic-Device-Join`" /ENABLE"
}

function Run-JoinTask{
    Run-Cmd "schtasks.exe" "/Run /TN `"\Microsoft\Windows\Workplace Join\Automatic-Device-Join`""
}

function Restart-CcmExec{
    $svc = Get-Service ccmexec -ErrorAction SilentlyContinue
    if ($svc){
        Out-Line "Restarting CCMExec service..."
        Restart-Service ccmexec -Force
    }
}

try{ New-Item -ItemType Directory -Path (Split-Path $OutLog) -Force | Out-Null } catch {}
Remove-Item $OutLog -ErrorAction SilentlyContinue

Hdr "MDM / Hybrid Join Health Check"

$ds = Get-DsregStatus

Out-Line "DomainJoined    : $($ds.DomainJoined)"
Out-Line "AzureAdJoined   : $($ds.AzureAdJoined)"
Out-Line "WorkplaceJoined : $($ds.WorkplaceJoined)"
Out-Line "MdmUrl          : $($ds.MdmUrl)"

$task = Get-ScheduledTask -TaskName "Automatic-Device-Join" -TaskPath "\Microsoft\Windows\Workplace Join\" -ErrorAction SilentlyContinue

$enterpriseCount = Get-EnterpriseMgmtTaskCount

Hdr "Environment Checks"

Out-Line "Join Task Exists : $($task -ne $null)"
Out-Line "EnterpriseMgmt Tasks : $enterpriseCount"

$issues = @()

if ($ds.DomainJoined -eq "YES" -and $ds.AzureAdJoined -ne "YES"){
    $issues += "Device is domain joined but NOT Azure AD joined."
}

if (!$task){
    $issues += "Automatic-Device-Join scheduled task is missing."
}

if ($ds.AzureAdJoined -eq "YES" -and $enterpriseCount -eq 0){
    $issues += "Azure AD joined but EnterpriseMgmt tasks missing (possible MDM enrollment issue)."
}

Hdr "Results"

if ($issues.Count -eq 0){

    Out-Line "No issues detected. Device appears healthy."

}
else{

    Out-Line "Issues detected:"
    $issues | ForEach-Object { Out-Line " - $_" }

    if (-not $Remediate){

        Write-Host ""
        Write-Host "Run repair now? (Y/N): " -NoNewline
        $answer = Read-Host

        if ($answer -match "^[Yy]"){
            $Remediate = $true
            Out-Line "User selected remediation."
        }
        else{
            Out-Line "Audit completed. No remediation chosen."
            return
        }
    }
}

if ($Remediate){

    Hdr "Remediation"

    if (!$task){

        Out-Line "Restoring Automatic-Device-Join task..."

        if (Ensure-HybridJoinXml){

            Run-Cmd "schtasks.exe" "/Create /TN `"\Microsoft\Windows\Workplace Join\Automatic-Device-Join`" /XML `"$TaskXmlPath`" /F"

        }
    }

    Enable-JoinTask
    Run-JoinTask

    Start-Sleep 20

    $ds2 = Get-DsregStatus
    Out-Line "AzureAdJoined after run: $($ds2.AzureAdJoined)"

    if ($RestartCcmexecOnFix){
        Restart-CcmExec
    }

}

Hdr "Complete"
Out-Line "Log File: $OutLog"
