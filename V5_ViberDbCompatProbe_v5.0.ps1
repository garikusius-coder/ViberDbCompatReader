# Viber AI Manager v5.0 CLEAN
# Module: V5_ViberDbCompatProbe
# Version: 5.0.0
# Task: V5-040 Fix 1
# Mode: PROBE_ONLY_READ_ONLY_RUNTIME_KEY_CODEC
# Purpose: bounded Windows-only READ-ONLY runtime-key discovery from the already-running Viber process,
#          followed by exactly one isolated Qt codec PROBE. DIRECT_CHAT is intentionally not invoked here.
# Safety: PROCESS_QUERY_INFORMATION + PROCESS_VM_READ only; no process write/injection/debug attach,
#         no Viber restart/terminate, no DB write/copy/rekey/decrypt-to-disk, no send/AUTO/ViberSend.
# Privacy: the runtime key is never printed, logged, hashed, persisted, put in argv, or put in env.
#          It exists only transiently in this process and the isolated reader stdin/memory.
# Frozen ViberOpen/ViberChatId/ViberSend/ViberReceive are not invoked or modified.

[CmdletBinding()]
param(
    [string]$DbPath,
    [string]$ReaderExePath,
    [string]$ViberExePath,
    [int]$MaxScanMiB = 512,
    [int]$MaxDurationMs = 8000,
    [switch]$NoReport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Program = 'V5_ViberDbCompatProbe_v5.0.ps1'
$script:Version = '5.0.0'
$script:Task = 'V5-040-FIX1'
$script:ReportPath = $null
$script:Start = Get-Date

function Resolve-V5DbPath {
    param([string]$Requested)
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        $full = [System.IO.Path]::GetFullPath($Requested)
        if (-not [System.IO.File]::Exists($full)) { throw 'DB_NOT_FOUND' }
        return $full
    }
    $root = Join-Path $env:APPDATA 'ViberPC'
    if (-not [System.IO.Directory]::Exists($root)) { throw 'VIBERPC_NOT_FOUND' }
    $matches = @(Get-ChildItem -LiteralPath $root -Filter 'viber.db' -File -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($matches.Count -eq 0) { throw 'DB_NOT_FOUND' }
    return [string]$matches[0].FullName
}

function Resolve-V5ViberExe {
    param([string]$Requested)
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        $full = [System.IO.Path]::GetFullPath($Requested)
        if (-not [System.IO.File]::Exists($full)) { throw 'VIBER_EXE_NOT_FOUND' }
        return $full
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

function Resolve-V5ReaderExe {
    param([string]$Requested)
    $candidate = $Requested
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $root = [string]$PSScriptRoot
        if ([string]::IsNullOrWhiteSpace($root)) { $root = (Get-Location).Path }
        $candidate = Join-Path $root 'V5_ViberDbCompatQtReader_v5.0.exe'
    }
    $full = [System.IO.Path]::GetFullPath($candidate)
    if (-not [System.IO.File]::Exists($full)) { throw 'QT_READER_EXE_NOT_FOUND' }
    return $full
}

function Resolve-V5QtRuntime {
    param([Parameter(Mandatory=$true)][string]$ViberExe)
    $installDir = Split-Path -Parent $ViberExe
    $qsqlite = @(Get-ChildItem -LiteralPath $installDir -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(?i)qsqlite.*\.dll$' } | Select-Object -First 4)
    if ($qsqlite.Count -ne 1) { throw $(if($qsqlite.Count -eq 0){'QSQLITE_PLUGIN_NOT_FOUND'}else{'QSQLITE_PLUGIN_AMBIGUOUS'}) }
    $sqldrivers = Split-Path -Parent ([string]$qsqlite[0].FullName)
    $pluginRoot = Split-Path -Parent $sqldrivers
    if ([string]::IsNullOrWhiteSpace($pluginRoot) -or -not [System.IO.Directory]::Exists($pluginRoot)) { throw 'QT_PLUGIN_ROOT_NOT_FOUND' }
    if (-not [System.IO.File]::Exists((Join-Path $installDir 'Qt6Core.dll'))) { throw 'QT6CORE_NOT_FOUND' }
    if (-not [System.IO.File]::Exists((Join-Path $installDir 'Qt6Sql.dll'))) { throw 'QT6SQL_NOT_FOUND' }
    return [pscustomobject]@{ InstallDir=$installDir; PluginRoot=$pluginRoot }
}

function Get-V5TargetViberProcesses {
    param([Parameter(Mandatory=$true)][string]$ExpectedExe)
    $currentSession = (Get-Process -Id $PID).SessionId
    $expected = [System.IO.Path]::GetFullPath($ExpectedExe)
    $result = New-Object 'System.Collections.Generic.List[System.Diagnostics.Process]'
    foreach ($proc in @(Get-Process -Name 'Viber' -ErrorAction SilentlyContinue)) {
        if ($proc.SessionId -ne $currentSession) { continue }
        try {
            $path = [System.IO.Path]::GetFullPath([string]$proc.Path)
            if ([string]::Equals($path,$expected,[System.StringComparison]::OrdinalIgnoreCase)) { [void]$result.Add($proc) }
        } catch {}
        if ($result.Count -ge 4) { break }
    }
    if ($result.Count -eq 0) { throw 'VIBER_NOT_RUNNING_OR_PATH_MISMATCH' }
    return @($result.ToArray())
}

function New-V5SafeReport {
    param([hashtable]$Data)
    $keys = @(
        'program','version','task','mode','result','keyDiscoveryMethod','processCountScanned','memoryMiBScanned',
        'scanBudgetHit','uniqueKeyCandidateCount','qtReaderInvoked','codecReadPass','schemaReadable','requiredTableCount',
        'directChatInvoked','keyPrinted','keyLogged','keyPersisted','keyInArgv','keyInEnvironment','dbWriteAttempted',
        'plaintextHistoryDumpCreated','runtimeSend','viberSendInvoked','autoEnabled','frozenModulesInvoked','safeErrorCode'
    )
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
        $script:ReportPath=Join-Path $dir ('V5_ViberDbCompatProbe_v5.0_'+$script:Start.ToString('yyyy-MM-dd_HHmmss')+'.txt')
        [System.IO.File]::WriteAllLines($script:ReportPath,$Lines,(New-Object System.Text.UTF8Encoding($true)))
        return $true
    } catch { return $false }
}

if (-not ('V5ViberReadOnlyKeyScanner' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

public sealed class V5KeyScanResult
{
    public List<string> Keys { get; set; }
    public long BytesScanned { get; set; }
    public int ChunksRead { get; set; }
    public bool BudgetHit { get; set; }
}

public static class V5ViberReadOnlyKeyScanner
{
    private const uint PROCESS_VM_READ = 0x0010;
    private const uint PROCESS_QUERY_INFORMATION = 0x0400;
    private const uint MEM_COMMIT = 0x1000;
    private const uint MEM_PRIVATE = 0x20000;
    private const uint MEM_MAPPED = 0x40000;
    private const uint PAGE_NOACCESS = 0x01;
    private const uint PAGE_GUARD = 0x100;
    private const int CHUNK_BYTES = 1024 * 1024;
    private const int OVERLAP_BYTES = 256;

    [StructLayout(LayoutKind.Sequential)]
    private struct MEMORY_BASIC_INFORMATION
    {
        public IntPtr BaseAddress;
        public IntPtr AllocationBase;
        public uint AllocationProtect;
        public UIntPtr RegionSize;
        public uint State;
        public uint Protect;
        public uint Type;
    }

    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern IntPtr OpenProcess(uint access, bool inheritHandle, int processId);

    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool ReadProcessMemory(IntPtr process, IntPtr address, byte[] buffer, UIntPtr size, out UIntPtr bytesRead);

    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern UIntPtr VirtualQueryEx(IntPtr process, IntPtr address, out MEMORY_BASIC_INFORMATION buffer, UIntPtr length);

    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool CloseHandle(IntPtr handle);

    private static readonly Regex KeyRegex = new Regex(
        @"(?i)(?:PRAGMA\s+)?hexkey\s*=\s*['""]([0-9a-f]{64})['""]",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static bool IsReadable(MEMORY_BASIC_INFORMATION mbi)
    {
        if (mbi.State != MEM_COMMIT) return false;
        if (mbi.Type != MEM_PRIVATE && mbi.Type != MEM_MAPPED) return false;
        if ((mbi.Protect & PAGE_GUARD) != 0) return false;
        if ((mbi.Protect & PAGE_NOACCESS) != 0) return false;
        return true;
    }

    private static void AddMatches(string text, HashSet<string> keys)
    {
        if (String.IsNullOrEmpty(text)) return;
        MatchCollection matches = KeyRegex.Matches(text);
        foreach (Match m in matches)
        {
            if (m.Success && m.Groups.Count > 1)
            {
                string k = m.Groups[1].Value;
                if (k != null && k.Length == 64) keys.Add(k);
            }
        }
    }

    private static void ScanBuffer(byte[] data, int length, HashSet<string> keys)
    {
        if (data == null || length <= 0) return;
        AddMatches(Encoding.ASCII.GetString(data, 0, length), keys);
        int even0 = length - (length % 2);
        if (even0 >= 2) AddMatches(Encoding.Unicode.GetString(data, 0, even0), keys);
        if (length >= 3)
        {
            int even1 = (length - 1) - ((length - 1) % 2);
            if (even1 >= 2) AddMatches(Encoding.Unicode.GetString(data, 1, even1), keys);
        }
    }

    public static V5KeyScanResult Scan(int processId, long maxBytes, int maxDurationMs)
    {
        if (maxBytes <= 0 || maxDurationMs <= 0) throw new ArgumentOutOfRangeException();
        V5KeyScanResult result = new V5KeyScanResult {
            Keys = new List<string>(), BytesScanned = 0, ChunksRead = 0, BudgetHit = false
        };
        HashSet<string> keys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        IntPtr handle = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, false, processId);
        if (handle == IntPtr.Zero) throw new InvalidOperationException("OPEN_PROCESS_READ_FAILED");
        Stopwatch watch = Stopwatch.StartNew();
        long cursor = 0;
        int mbiSize = Marshal.SizeOf(typeof(MEMORY_BASIC_INFORMATION));

        try
        {
            while (true)
            {
                if (watch.ElapsedMilliseconds >= maxDurationMs || result.BytesScanned >= maxBytes)
                {
                    result.BudgetHit = true;
                    break;
                }
                MEMORY_BASIC_INFORMATION mbi;
                UIntPtr got = VirtualQueryEx(handle, new IntPtr(cursor), out mbi, new UIntPtr((uint)mbiSize));
                if (got == UIntPtr.Zero) break;
                long baseAddress = mbi.BaseAddress.ToInt64();
                ulong regionSizeU = mbi.RegionSize.ToUInt64();
                if (regionSizeU == 0 || regionSizeU > Int64.MaxValue) break;
                long regionSize = (long)regionSizeU;
                long next = baseAddress + regionSize;
                if (next <= cursor) break;

                if (IsReadable(mbi))
                {
                    long offset = 0;
                    byte[] tail = new byte[0];
                    while (offset < regionSize)
                    {
                        if (watch.ElapsedMilliseconds >= maxDurationMs || result.BytesScanned >= maxBytes)
                        {
                            result.BudgetHit = true;
                            break;
                        }
                        long remainingBudget = maxBytes - result.BytesScanned;
                        int ask = (int)Math.Min((long)CHUNK_BYTES, Math.Min(regionSize - offset, remainingBudget));
                        if (ask <= 0) { result.BudgetHit = true; break; }
                        byte[] buffer = new byte[ask];
                        UIntPtr bytesRead;
                        bool ok = ReadProcessMemory(handle, new IntPtr(baseAddress + offset), buffer, new UIntPtr((uint)ask), out bytesRead);
                        int read = ok ? (int)Math.Min((ulong)ask, bytesRead.ToUInt64()) : 0;
                        if (read > 0)
                        {
                            result.BytesScanned += read;
                            result.ChunksRead++;
                            int combinedLength = tail.Length + read;
                            byte[] combined = new byte[combinedLength];
                            if (tail.Length > 0) Buffer.BlockCopy(tail, 0, combined, 0, tail.Length);
                            Buffer.BlockCopy(buffer, 0, combined, tail.Length, read);
                            ScanBuffer(combined, combinedLength, keys);
                            int keep = Math.Min(OVERLAP_BYTES, combinedLength);
                            tail = new byte[keep];
                            Buffer.BlockCopy(combined, combinedLength - keep, tail, 0, keep);
                            Array.Clear(combined, 0, combined.Length);
                            Array.Clear(buffer, 0, buffer.Length);
                        }
                        offset += ask;
                    }
                }
                cursor = next;
            }
        }
        finally
        {
            CloseHandle(handle);
        }

        foreach (string k in keys) result.Keys.Add(k);
        return result;
    }
}
'@
}

function Invoke-V5QtProbe {
    param(
        [Parameter(Mandatory=$true)][string]$ReaderExe,
        [Parameter(Mandatory=$true)][string]$DatabasePath,
        [Parameter(Mandatory=$true)][string]$PluginRoot,
        [Parameter(Mandatory=$true)][string]$InstallDir,
        [Parameter(Mandatory=$true)][string]$RuntimeKey
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ReaderExe
    $psi.Arguments = ''
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = (Split-Path -Parent $ReaderExe)
    $psi.EnvironmentVariables['PATH'] = $InstallDir + ';' + [string]$psi.EnvironmentVariables['PATH']
    $psi.EnvironmentVariables['QT_PLUGIN_PATH'] = $PluginRoot
    $psi.EnvironmentVariables.Remove('VIBER_HEXKEY')

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    if (-not $process.Start()) { throw 'QT_READER_START_FAILED' }

    $payload = $null
    try {
        $payload = ([ordered]@{ mode='PROBE'; dbPath=$DatabasePath; pluginRoot=$PluginRoot; hexkey=$RuntimeKey } | ConvertTo-Json -Compress)
        $process.StandardInput.WriteLine($payload)
        $process.StandardInput.Close()
        $payload = $null

        if (-not $process.WaitForExit(5000)) {
            try { $process.Kill() } catch {}
            throw 'QT_READER_TIMEOUT'
        }
        $stdout = $process.StandardOutput.ReadToEnd()
        [void]$process.StandardError.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($stdout)) { throw 'QT_READER_EMPTY_RESPONSE' }
        try { $response = $stdout | ConvertFrom-Json -ErrorAction Stop } catch { throw 'QT_READER_INVALID_RESPONSE' }
        if ($null -eq $response) { throw 'QT_READER_INVALID_RESPONSE' }
        return $response
    }
    finally {
        $payload = $null
        $process.Dispose()
    }
}

$data=@{
    program=$script:Program; version=$script:Version; task=$script:Task; mode='PROBE_ONLY_READ_ONLY_RUNTIME_KEY_CODEC'; result='FAIL';
    keyDiscoveryMethod='PROCESS_VM_READ_PRAGMA_HEXKEY'; processCountScanned='0'; memoryMiBScanned='0'; scanBudgetHit='FALSE';
    uniqueKeyCandidateCount='0'; qtReaderInvoked='FALSE'; codecReadPass='FALSE'; schemaReadable='FALSE'; requiredTableCount='0';
    directChatInvoked='FALSE'; keyPrinted='FALSE'; keyLogged='FALSE'; keyPersisted='FALSE'; keyInArgv='FALSE'; keyInEnvironment='FALSE';
    dbWriteAttempted='FALSE'; plaintextHistoryDumpCreated='FALSE'; runtimeSend='NOT_RUN'; viberSendInvoked='FALSE'; autoEnabled='FALSE';
    frozenModulesInvoked='FALSE'; safeErrorCode=''
}

$runtimeKey = $null
try {
    if ($MaxScanMiB -lt 16 -or $MaxScanMiB -gt 1024) { throw 'MAX_SCAN_MIB_OUT_OF_RANGE' }
    if ($MaxDurationMs -lt 1000 -or $MaxDurationMs -gt 30000) { throw 'MAX_DURATION_MS_OUT_OF_RANGE' }

    $db = Resolve-V5DbPath -Requested $DbPath
    $viberExe = Resolve-V5ViberExe -Requested $ViberExePath
    $reader = Resolve-V5ReaderExe -Requested $ReaderExePath
    $qt = Resolve-V5QtRuntime -ViberExe $viberExe
    $targets = @(Get-V5TargetViberProcesses -ExpectedExe $viberExe)
    $data.processCountScanned = [string]$targets.Count

    $allKeys = New-Object 'System.Collections.Generic.HashSet[System.String]' ([System.StringComparer]::OrdinalIgnoreCase)
    [long]$bytesScanned = 0
    $budgetHit = $false
    [long]$maxBytes = [long]$MaxScanMiB * 1MB
    $remainingMs = $MaxDurationMs
    $scanStart = [System.Diagnostics.Stopwatch]::StartNew()

    foreach ($target in $targets) {
        $remainingBytes = $maxBytes - $bytesScanned
        $remainingMs = $MaxDurationMs - [int]$scanStart.ElapsedMilliseconds
        if ($remainingBytes -le 0 -or $remainingMs -le 0) { $budgetHit=$true; break }
        $scan = [V5ViberReadOnlyKeyScanner]::Scan([int]$target.Id,[long]$remainingBytes,[int]$remainingMs)
        $bytesScanned += [long]$scan.BytesScanned
        if ($scan.BudgetHit) { $budgetHit=$true }
        foreach ($candidate in @($scan.Keys)) { [void]$allKeys.Add([string]$candidate) }
        if ($allKeys.Count -gt 1) { break }
    }

    $data.memoryMiBScanned = [string][Math]::Round(($bytesScanned / 1MB),2)
    $data.scanBudgetHit = $(if($budgetHit){'TRUE'}else{'FALSE'})
    $data.uniqueKeyCandidateCount = [string]$allKeys.Count

    if ($allKeys.Count -eq 0) { throw $(if($budgetHit){'RUNTIME_KEY_NOT_FOUND_WITHIN_BOUNDS'}else{'RUNTIME_KEY_NOT_FOUND'}) }
    if ($allKeys.Count -ne 1) { throw 'RUNTIME_KEY_AMBIGUOUS' }

    $runtimeKey = [string](@($allKeys)[0])
    if ($runtimeKey -notmatch '^[0-9A-Fa-f]{64}$') { throw 'RUNTIME_KEY_FORMAT_INVALID' }

    $data.qtReaderInvoked='TRUE'
    $response = Invoke-V5QtProbe -ReaderExe $reader -DatabasePath $db -PluginRoot $qt.PluginRoot -InstallDir $qt.InstallDir -RuntimeKey $runtimeKey
    $runtimeKey = $null
    $allKeys.Clear()

    if ([string]$response.result -ne 'CODEC_READ_PASS') { throw 'CODEC_READ_NOT_CONFIRMED' }
    if ($response.schemaReadable -ne $true) { throw 'SCHEMA_NOT_READABLE' }
    if ([int]$response.requiredTableCount -ne 5) { throw 'SCHEMA_SIGNATURE_MISMATCH' }
    if ($response.dbWriteAttempted -ne $false -or $response.directChatInvoked -ne $false -or $response.keyLogged -ne $false) { throw 'READER_SAFETY_CONTRACT_FAILED' }

    $data.codecReadPass='TRUE'
    $data.schemaReadable='TRUE'
    $data.requiredTableCount='5'
    $data.result='CODEC_READ_PASS'
}
catch {
    $runtimeKey = $null
    $code = [string]$_.Exception.Message
    $allowed = @(
        'DB_NOT_FOUND','VIBERPC_NOT_FOUND','VIBER_EXE_NOT_FOUND','QT_READER_EXE_NOT_FOUND','QSQLITE_PLUGIN_NOT_FOUND',
        'QSQLITE_PLUGIN_AMBIGUOUS','QT_PLUGIN_ROOT_NOT_FOUND','QT6CORE_NOT_FOUND','QT6SQL_NOT_FOUND',
        'VIBER_NOT_RUNNING_OR_PATH_MISMATCH','MAX_SCAN_MIB_OUT_OF_RANGE','MAX_DURATION_MS_OUT_OF_RANGE',
        'RUNTIME_KEY_NOT_FOUND_WITHIN_BOUNDS','RUNTIME_KEY_NOT_FOUND','RUNTIME_KEY_AMBIGUOUS','RUNTIME_KEY_FORMAT_INVALID',
        'QT_READER_START_FAILED','QT_READER_TIMEOUT','QT_READER_EMPTY_RESPONSE','QT_READER_INVALID_RESPONSE',
        'CODEC_READ_NOT_CONFIRMED','SCHEMA_NOT_READABLE','SCHEMA_SIGNATURE_MISMATCH','READER_SAFETY_CONTRACT_FAILED'
    )
    if ($allowed -contains $code) { $data.safeErrorCode=$code } else { $data.safeErrorCode='PROBE_EXCEPTION' }
}
finally {
    $runtimeKey = $null
}

$lines = New-V5SafeReport -Data $data
$saved = Save-V5SafeReport -Lines $lines
foreach ($line in $lines) { Write-Output $line }
Write-Output ('reportSaved='+$(if($saved){'TRUE'}else{'FALSE'}))
if ($data.result -eq 'CODEC_READ_PASS') { exit 0 }
exit 1
