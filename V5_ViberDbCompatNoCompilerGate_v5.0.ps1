# Viber AI Manager v5.0 CLEAN
# Module: V5_ViberDbCompatNoCompilerGate
# Version: 5.0.0
# Task: V5-040 Fix 2
# Mode: STATIC_LOCAL_PREREQUISITE_GATE
# Purpose: no-compiler readiness check only. It does NOT read viber.db, inspect Viber process memory,
#          execute the Qt reader, open chats, send messages, enable AUTO, or invoke frozen modules.
# Single prerequisite when blocked: one prebuilt Windows x64 V5_ViberDbCompatQtReader_v5.0.exe.

[CmdletBinding()]
param(
    [string]$ReaderExePath,
    [string]$ViberExePath,
    [switch]$NoReport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Program = 'V5_ViberDbCompatNoCompilerGate_v5.0.ps1'
$script:Version = '5.0.0'
$script:Task = 'V5-040-FIX2'
$script:Start = Get-Date
$script:ReportPath = $null

function Resolve-V5ReaderExe {
    param([string]$Requested)
    $candidate = $Requested
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $root = [string]$PSScriptRoot
        if ([string]::IsNullOrWhiteSpace($root)) { $root = (Get-Location).Path }
        $candidate = Join-Path $root 'V5_ViberDbCompatQtReader_v5.0.exe'
    }
    return [System.IO.Path]::GetFullPath($candidate)
}

function Resolve-V5ViberExe {
    param([string]$Requested)
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        $full = [System.IO.Path]::GetFullPath($Requested)
        if ([System.IO.File]::Exists($full)) { return $full }
        throw 'VIBER_EXE_NOT_FOUND'
    }
    try {
        $p = @(Get-Process -Name 'Viber' -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Path) } | Select-Object -First 1)
        if ($p.Count -gt 0 -and [System.IO.File]::Exists([string]$p[0].Path)) { return [string]$p[0].Path }
    } catch {}
    $candidates = @()
    if ($env:LOCALAPPDATA) {
        $candidates += (Join-Path $env:LOCALAPPDATA 'Viber\Viber.exe')
        $candidates += (Join-Path $env:LOCALAPPDATA 'Programs\Viber\Viber.exe')
    }
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'Viber\Viber.exe') }
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Viber\Viber.exe') }
    foreach ($candidate in $candidates) { if ([System.IO.File]::Exists($candidate)) { return [string]$candidate } }
    throw 'VIBER_EXE_NOT_FOUND'
}

function Test-V5PeAmd64 {
    param([Parameter(Mandatory=$true)][string]$Path)
    $fs = $null
    try {
        $fs = New-Object System.IO.FileStream($Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::Read)
        if ($fs.Length -lt 256) { return $false }
        $br = New-Object System.IO.BinaryReader($fs)
        if ($br.ReadUInt16() -ne 0x5A4D) { return $false }
        $fs.Position = 0x3C
        $pe = $br.ReadInt32()
        if ($pe -lt 0 -or ($pe + 6) -gt $fs.Length) { return $false }
        $fs.Position = $pe
        if ($br.ReadUInt32() -ne 0x00004550) { return $false }
        return ($br.ReadUInt16() -eq 0x8664)
    } catch { return $false }
    finally { if ($null -ne $fs) { $fs.Dispose() } }
}

function Get-V5RuntimeInventory {
    param([Parameter(Mandatory=$true)][string]$ViberExe)
    $installDir = Split-Path -Parent $ViberExe
    $core = [System.IO.File]::Exists((Join-Path $installDir 'Qt6Core.dll'))
    $sql = [System.IO.File]::Exists((Join-Path $installDir 'Qt6Sql.dll'))
    $qsqlite = @(Get-ChildItem -LiteralPath $installDir -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(?i)qsqlite.*\.dll$' } | Select-Object -First 3)
    return [pscustomobject]@{ Qt6Core=$core; Qt6Sql=$sql; QsqliteCount=$qsqlite.Count }
}

function New-V5SafeLines {
    param([hashtable]$Data)
    $keys = @('program','version','task','mode','result','readerPresent','readerPeAmd64','qt6CoreFound','qt6SqlFound','qsqliteCount','compilerRequiredOnTarget','runtimeProbeInvoked','directChatInvoked','viberSendInvoked','autoEnabled','frozenModulesInvoked','safeErrorCode','singlePrerequisite')
    $lines = New-Object 'System.Collections.Generic.List[System.String]'
    foreach ($key in $keys) {
        $value=''; if ($Data.ContainsKey($key) -and $null -ne $Data[$key]) { $value=[string]$Data[$key] }
        [void]$lines.Add($key+'='+$value)
    }
    return [string[]]$lines.ToArray()
}

function Save-V5SafeReport {
    param([string[]]$Lines)
    if ($NoReport) { return $false }
    try {
        $root=[string]$PSScriptRoot; if ([string]::IsNullOrWhiteSpace($root)) { $root=(Get-Location).Path }
        $dir=Join-Path $root 'RUN_REPORTS'; if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
        $script:ReportPath=Join-Path $dir ('V5_ViberDbCompatNoCompilerGate_v5.0_'+$script:Start.ToString('yyyy-MM-dd_HHmmss')+'.txt')
        [System.IO.File]::WriteAllLines($script:ReportPath,$Lines,(New-Object System.Text.UTF8Encoding($true)))
        return $true
    } catch { return $false }
}

$data=@{
    program=$script:Program; version=$script:Version; task=$script:Task; mode='STATIC_LOCAL_PREREQUISITE_GATE'; result='BLOCKED';
    readerPresent='FALSE'; readerPeAmd64='FALSE'; qt6CoreFound='FALSE'; qt6SqlFound='FALSE'; qsqliteCount='0'; compilerRequiredOnTarget='FALSE';
    runtimeProbeInvoked='FALSE'; directChatInvoked='FALSE'; viberSendInvoked='FALSE'; autoEnabled='FALSE'; frozenModulesInvoked='FALSE'; safeErrorCode='';
    singlePrerequisite='PREBUILT_WINDOWS_X64_QT_READER_EXE'
}

try {
    $reader = Resolve-V5ReaderExe -Requested $ReaderExePath
    if (-not [System.IO.File]::Exists($reader)) { throw 'PREBUILT_READER_EXE_MISSING' }
    $data.readerPresent='TRUE'
    if (-not (Test-V5PeAmd64 -Path $reader)) { throw 'PREBUILT_READER_NOT_WINDOWS_X64_PE' }
    $data.readerPeAmd64='TRUE'

    $viberExe = Resolve-V5ViberExe -Requested $ViberExePath
    $inv = Get-V5RuntimeInventory -ViberExe $viberExe
    $data.qt6CoreFound=$(if($inv.Qt6Core){'TRUE'}else{'FALSE'})
    $data.qt6SqlFound=$(if($inv.Qt6Sql){'TRUE'}else{'FALSE'})
    $data.qsqliteCount=[string]$inv.QsqliteCount
    if (-not $inv.Qt6Core) { throw 'QT6CORE_NOT_FOUND' }
    if (-not $inv.Qt6Sql) { throw 'QT6SQL_NOT_FOUND' }
    if ($inv.QsqliteCount -ne 1) { throw $(if($inv.QsqliteCount -eq 0){'QSQLITE_PLUGIN_NOT_FOUND'}else{'QSQLITE_PLUGIN_AMBIGUOUS'}) }

    $data.result='READY_FOR_PROBE'
    $data.singlePrerequisite='NONE'
} catch {
    $code=[string]$_.Exception.Message
    if ($code -notmatch '^[A-Z0-9_]+$') { $code='GATE_FAILED' }
    $data.safeErrorCode=$code
}

$lines=New-V5SafeLines -Data $data
$saved=Save-V5SafeReport -Lines $lines
foreach($line in $lines){Write-Output $line}
Write-Output ('reportSaved='+$(if($saved){'TRUE'}else{'FALSE'}))
if($data.result -eq 'READY_FOR_PROBE'){exit 0}else{exit 2}
