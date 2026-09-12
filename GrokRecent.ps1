#requires -Version 5.1
# Grok 最近项目启动器：从 ~/.grok/sessions 找回用过的目录，勾选后用 Windows Terminal 打开。
[CmdletBinding()]
param(
    [switch]$ListOnly,
    [switch]$Version,
    [switch]$Demo,
    [switch]$Screenshot,
    [switch]$ScreenshotWatch,
    [switch]$ScreenshotDash,
    [switch]$WatchList,
    [int]$Limit = 50
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AppVersion = '1.4.0'
if ($Version) {
    Write-Output $script:AppVersion
    exit 0
}

# Screenshot always uses fictional rows so real project paths never land in docs/.
$script:DemoMode = [bool]($Demo -or $Screenshot -or $ScreenshotWatch -or $ScreenshotDash)
$script:ScreenshotMode = [bool]($Screenshot -or $ScreenshotWatch -or $ScreenshotDash)
$script:ScreenshotWatchMode = [bool]$ScreenshotWatch
$script:ScreenshotDashMode = [bool]$ScreenshotDash

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:DataDir = Join-Path $env:APPDATA 'GrokRecentLauncher'
if (-not (Test-Path -LiteralPath $script:DataDir)) {
    New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
}
$script:ConfigPath = Join-Path $script:DataDir 'config.json'
$script:ErrorLog = Join-Path $script:DataDir 'last-error.log'

$legacyConfig = Join-Path $script:Root 'config.json'
if (-not (Test-Path -LiteralPath $script:ConfigPath) -and (Test-Path -LiteralPath $legacyConfig)) {
    Copy-Item -LiteralPath $legacyConfig -Destination $script:ConfigPath -Force
}

function Convert-GrokTime {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $v = $Value.Trim()
    if ($v -match '^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})\.(\d+)(.*)$') {
        $frac = $Matches[2]
        if ($frac.Length -gt 7) { $frac = $frac.Substring(0, 7) }
        $v = '{0}.{1}{2}' -f $Matches[1], $frac, $Matches[3]
    }
    $dto = [datetimeoffset]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::RoundtripKind
    if ([datetimeoffset]::TryParse($v, [cultureinfo]::InvariantCulture, $styles, [ref]$dto)) {
        return $dto
    }
    return $null
}

function Convert-SessionCwd {
    param([string]$EncodedName, [string]$GroupPath)
    $cwdFile = Join-Path $GroupPath '.cwd'
    if (Test-Path -LiteralPath $cwdFile) {
        $text = [System.IO.File]::ReadAllText($cwdFile).Trim()
        if ($text) { return $text }
    }
    try {
        return [uri]::UnescapeDataString($EncodedName)
    } catch {
        return $EncodedName
    }
}

function Read-JsonFile {
    param([string]$Path)
    try {
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Get-GrokExe {
    $cmd = Get-Command grok.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    $guess = Join-Path $env:USERPROFILE '.grok\bin\grok.exe'
    if (Test-Path -LiteralPath $guess) { return $guess }
    return $null
}

function Get-WtExe {
    $cmd = Get-Command wt.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    $guess = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'
    if (Test-Path -LiteralPath $guess) { return $guess }
    return $null
}

function Test-SamePath {
    param([string]$A, [string]$B)
    if ([string]::IsNullOrWhiteSpace($A) -or [string]::IsNullOrWhiteSpace($B)) { return $false }
    $na = $A.TrimEnd('\', '/')
    $nb = $B.TrimEnd('\', '/')
    return [string]::Equals($na, $nb, [StringComparison]::OrdinalIgnoreCase)
}

function Test-TextMatch {
    param([string]$Haystack, [string]$Needle)
    if ([string]::IsNullOrWhiteSpace($Haystack) -or [string]::IsNullOrWhiteSpace($Needle)) { return $false }
    return $Haystack.IndexOf($Needle, [StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Sanitize-Title {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $t = ($Value -replace '[\u0000-\u001F]', ' ').Trim()
    if ($t.Length -gt 80) { $t = $t.Substring(0, 80) + [char]0x2026 }
    return $t
}

function Read-LauncherConfig {
    if ($script:DemoMode) {
        return [pscustomobject]@{
            pins             = @('D:\Work\shop-web')
            hideMissing      = $true
            quickLaunchCount = 5
            usageRange       = '7d'
        }
    }
    $cfg = [pscustomobject]@{
        pins             = @()
        hideMissing      = $true
        quickLaunchCount = 5
        usageRange       = '7d'
    }
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) { return $cfg }
    $json = Read-JsonFile $script:ConfigPath
    if (-not $json) { return $cfg }
    if ($json.PSObject.Properties.Name -contains 'pins' -and $json.pins) {
        $cfg.pins = @($json.pins | ForEach-Object { [string]$_ })
    }
    if ($json.PSObject.Properties.Name -contains 'hideMissing') {
        $cfg.hideMissing = [bool]$json.hideMissing
    }
    if ($json.PSObject.Properties.Name -contains 'quickLaunchCount') {
        try { $cfg.quickLaunchCount = [Math]::Max(1, [Math]::Min(12, [int]$json.quickLaunchCount)) } catch { }
    }
    if ($json.PSObject.Properties.Name -contains 'usageRange' -and $json.usageRange) {
        $cfg.usageRange = [string]$json.usageRange
    }
    return $cfg
}

function Save-LauncherConfig {
    param($Config)
    if ($script:DemoMode) { return }
    $payload = @{
        pins             = @($Config.pins)
        hideMissing      = [bool]$Config.hideMissing
        quickLaunchCount = [int]$Config.quickLaunchCount
        usageRange       = [string]$Config.usageRange
    } | ConvertTo-Json -Depth 4
    $utf8 = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($script:ConfigPath, $payload, $utf8)
}

function Get-GrokRecentProjects {
    $sessionsRoot = Join-Path $env:USERPROFILE '.grok\sessions'
    $map = @{}

    if (-not (Test-Path -LiteralPath $sessionsRoot)) {
        return @()
    }

    foreach ($group in Get-ChildItem -LiteralPath $sessionsRoot -Directory -ErrorAction SilentlyContinue) {
        $fallbackCwd = Convert-SessionCwd -EncodedName $group.Name -GroupPath $group.FullName

        foreach ($sessionDir in Get-ChildItem -LiteralPath $group.FullName -Directory -ErrorAction SilentlyContinue) {
            $sumPath = Join-Path $sessionDir.FullName 'summary.json'
            if (-not (Test-Path -LiteralPath $sumPath)) { continue }

            $sum = Read-JsonFile $sumPath
            $cwd = $fallbackCwd
            if ($sum -and $sum.PSObject.Properties.Name -contains 'info' -and $sum.info -and $sum.info.cwd) {
                $cwd = [string]$sum.info.cwd
            }
            if ([string]::IsNullOrWhiteSpace($cwd)) { continue }

            $title = $null
            if ($sum) {
                foreach ($field in @('generated_title', 'session_summary')) {
                    if ($sum.PSObject.Properties.Name -contains $field -and $sum.$field) {
                        $title = Sanitize-Title ([string]$sum.$field)
                        if ($title) { break }
                    }
                }
            }

            $when = $null
            if ($sum) {
                foreach ($field in @('last_active_at', 'updated_at', 'created_at')) {
                    if ($sum.PSObject.Properties.Name -contains $field) {
                        $when = Convert-GrokTime ([string]$sum.$field)
                        if ($when) { break }
                    }
                }
            }
            if (-not $when) {
                $when = [datetimeoffset](Get-Item -LiteralPath $sumPath).LastWriteTime
            }

            $key = $cwd.TrimEnd('\', '/').ToLowerInvariant()
            if (-not $map.ContainsKey($key)) {
                $map[$key] = [pscustomobject]@{
                    Path         = $cwd
                    Name         = Split-Path $cwd -Leaf
                    Parent       = Split-Path $cwd -Parent
                    LastActive   = $when
                    LastTitle    = $title
                    SessionCount = 0
                    Exists       = (Test-Path -LiteralPath $cwd)
                }
            }

            $row = $map[$key]
            $row.SessionCount += 1
            if ($when -gt $row.LastActive) {
                $row.LastActive = $when
                if ($title) { $row.LastTitle = $title }
            } elseif (-not $row.LastTitle -and $title) {
                $row.LastTitle = $title
            }
        }
    }

    $items = @($map.Values)
    $leafGroups = $items | Group-Object Name
    $dupes = @{}
    foreach ($g in $leafGroups) {
        if ($g.Count -gt 1) { $dupes[$g.Name] = $true }
    }
    foreach ($item in $items) {
        $parentLeaf = if ($item.Parent) { Split-Path $item.Parent -Leaf } else { '' }
        if ($dupes.ContainsKey($item.Name) -and $parentLeaf) {
            $item | Add-Member -NotePropertyName Label -NotePropertyValue ('{0} / {1}' -f $parentLeaf, $item.Name) -Force
        } else {
            $item | Add-Member -NotePropertyName Label -NotePropertyValue $item.Name -Force
        }
    }
    return $items
}

function Get-DemoProjects {
    $now = [datetimeoffset]::Now
    function New-DemoRow {
        param($Path, $Title, $HoursAgo, $Sessions, $Exists)
        $name = Split-Path $Path -Leaf
        return [pscustomobject]@{
            Path         = $Path
            Name         = $name
            Parent       = Split-Path $Path -Parent
            LastActive   = $now.AddHours(-1 * $HoursAgo)
            LastTitle    = $Title
            SessionCount = $Sessions
            Exists       = $Exists
            Label        = $name
        }
    }
    @(
        (New-DemoRow 'D:\Work\shop-web' 'Empty state for the order list' 2 5 $true)
        (New-DemoRow 'D:\Work\notes-app' 'Fix markdown preview scroll' 0.3 8 $true)
        (New-DemoRow 'D:\Work\wiki-site' 'Heading anchor jump on docs' 20 3 $true)
        (New-DemoRow 'D:\Work\cli-tools' 'Add a doctor command' 72 2 $true)
        (New-DemoRow 'D:\Work\game-proto' 'Dash animation timing' 96 4 $true)
    )
}

function Get-DemoLiveWindows {
    $now = [datetimeoffset]::Now
    @(
        [pscustomobject]@{
            Pid = 4101; Label = 'shop-web'; Path = 'D:\Work\shop-web'; Kind = 'working'
            Title = 'Empty state for the order list'; Progress = 62; AgeText = '跑了 4 分钟'; Detail = '正在改订单空状态'
        }
        [pscustomobject]@{
            Pid = 4102; Label = 'notes-app'; Path = 'D:\Work\notes-app'; Kind = 'created'
            Title = 'Fix markdown preview scroll'; Progress = 8; AgeText = '刚打开 12 秒'; Detail = '新窗口，等待第一条指令'
        }
        [pscustomobject]@{
            Pid = 4103; Label = 'wiki-site'; Path = 'D:\Work\wiki-site'; Kind = 'done'
            Title = 'Heading anchor jump on docs'; Progress = 44; AgeText = '跑了 18 分钟'; Detail = '这一轮已经写完'
        }
        [pscustomobject]@{
            Pid = 4104; Label = 'cli-tools'; Path = 'D:\Work\cli-tools'; Kind = 'idle'
            Title = 'Add a doctor command'; Progress = 21; AgeText = '跑了 1 小时'; Detail = '停在提示符，等你说话'
        }
    )
}

function Format-TokenM {
    param($Tokens)
    $n = 0.0
    try { $n = [double]$Tokens } catch { $n = 0.0 }
    return ('{0:N2} M' -f ($n / 1000000.0))
}

function Get-RangeStart {
    param([string]$Range)
    switch ($Range) {
        'today' { return [datetime]::Today }
        '7d'    { return [datetime]::Today.AddDays(-6) }
        '30d'   { return [datetime]::Today.AddDays(-29) }
        default { return [datetime]'2000-01-01' }
    }
}

function Get-DemoUsageSnapshot {
    param([string]$Range = '7d')
    $days = @()
    $total = 0L
    for ($i = 6; $i -ge 0; $i--) {
        $d = [datetime]::Today.AddDays(-1 * $i)
        $v = [int64]((0.35 + ($i % 3) * 0.22 + 0.08 * $i) * 1000000)
        if ($Range -eq 'today' -and $i -ne 0) { $v = [int64]0 }
        $total += $v
        $days += [pscustomobject]@{ Date = $d; Total = $v }
    }
    if ($Range -eq 'today') { $total = $days[-1].Total }
    if ($Range -eq '30d') { $total = [int64]($total * 3.4) }
    if ($Range -eq 'all') { $total = [int64]($total * 8.1) }
    $inp = [int64]($total * 0.78)
    $outp = [int64]($total * 0.04)
    $cache = [int64]($total * 0.62)
    $top = @(
        [pscustomobject]@{ Label = 'shop-web'; Path = 'D:\Work\shop-web'; Tokens = [int64]($total * 0.31); Sessions = 12 }
        [pscustomobject]@{ Label = 'notes-app'; Path = 'D:\Work\notes-app'; Tokens = [int64]($total * 0.24); Sessions = 8 }
        [pscustomobject]@{ Label = 'wiki-site'; Path = 'D:\Work\wiki-site'; Tokens = [int64]($total * 0.18); Sessions = 5 }
        [pscustomobject]@{ Label = 'cli-tools'; Path = 'D:\Work\cli-tools'; Tokens = [int64]($total * 0.11); Sessions = 4 }
    )
    return [pscustomobject]@{
        Range     = $Range
        Total     = $total
        Input     = $inp
        Output    = $outp
        Cached    = $cache
        Sessions  = 29
        Windows   = 4
        Days      = $days
        TopDirs   = $top
        Model     = 'grok-4.6'
    }
}

function Get-UsageSnapshot {
    param([string]$Range = '7d')
    if ($script:DemoMode) { return Get-DemoUsageSnapshot -Range $Range }
    $from = Get-RangeStart $Range
    $sessionsRoot = Join-Path $env:USERPROFILE '.grok\sessions'
    $total = [int64]0; $inp = [int64]0; $outp = [int64]0; $cache = [int64]0
    $sessCount = 0
    $dayMap = @{}
    $dirMap = @{}
    $model = ''
    if (Test-Path -LiteralPath $sessionsRoot) {
        foreach ($group in Get-ChildItem -LiteralPath $sessionsRoot -Directory -ErrorAction SilentlyContinue) {
            $cwd = Convert-SessionCwd -EncodedName $group.Name -GroupPath $group.FullName
            foreach ($sessionDir in Get-ChildItem -LiteralPath $group.FullName -Directory -ErrorAction SilentlyContinue) {
                $usagePath = Join-Path $sessionDir.FullName 'usage.json'
                if (-not (Test-Path -LiteralPath $usagePath)) { continue }
                $u = Read-JsonFile $usagePath
                if (-not $u) { continue }
                $when = $null
                if ($u.PSObject.Properties.Name -contains 'updatedAt') {
                    $when = Convert-GrokTime ([string]$u.updatedAt)
                }
                $localDay = $null
                if ($when) { $localDay = $when.ToLocalTime().DateTime.Date }
                else { $localDay = (Get-Item -LiteralPath $usagePath).LastWriteTime.Date }
                if ($localDay -lt $from) { continue }
                $sess = $null
                if ($u.PSObject.Properties.Name -contains 'session') { $sess = $u.session }
                if (-not $sess) { continue }
                $t = [int64]0; $i = [int64]0; $o = [int64]0; $c = [int64]0
                try { if ($sess.totalTokens) { $t = [int64]$sess.totalTokens } } catch { }
                try { if ($sess.inputTokens) { $i = [int64]$sess.inputTokens } } catch { }
                try { if ($sess.outputTokens) { $o = [int64]$sess.outputTokens } } catch { }
                try { if ($sess.cachedReadTokens) { $c = [int64]$sess.cachedReadTokens } } catch { }
                if ($t -le 0) { continue }
                $sessCount += 1
                $total += $t; $inp += $i; $outp += $o; $cache += $c
                $dayKey = $localDay.ToString('yyyy-MM-dd')
                if (-not $dayMap.Contains($dayKey)) { $dayMap[$dayKey] = [int64]0 }
                $dayMap[$dayKey] = [int64]$dayMap[$dayKey] + $t
                $dirKey = $cwd
                if ([string]::IsNullOrWhiteSpace($dirKey)) { $dirKey = '(unknown)' }
                if (-not $dirMap.Contains($dirKey)) {
                    $dirMap[$dirKey] = @{ Tokens = [int64]0; Sessions = 0 }
                }
                $dirMap[$dirKey].Tokens = [int64]$dirMap[$dirKey].Tokens + $t
                $dirMap[$dirKey].Sessions += 1
                if (-not $model -and $sess.PSObject.Properties.Name -contains 'primaryModelId' -and $sess.primaryModelId) {
                    $model = [string]$sess.primaryModelId
                }
            }
        }
    }
    $chartFrom = $from
    if ($Range -eq 'all' -or $Range -eq '30d') { $chartFrom = [datetime]::Today.AddDays(-13) }
    if ($Range -eq 'today') { $chartFrom = [datetime]::Today.AddDays(-6) }
    $days = @()
    for ($d = $chartFrom; $d -le [datetime]::Today; $d = $d.AddDays(1)) {
        $k = $d.ToString('yyyy-MM-dd')
        $v = [int64]0
        if ($dayMap.Contains($k)) { $v = [int64]$dayMap[$k] }
        $days += [pscustomobject]@{ Date = $d; Total = $v }
    }
    $top = @()
    foreach ($k in $dirMap.Keys) {
        $leaf = Split-Path $k -Leaf
        if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = $k }
        $top += [pscustomobject]@{
            Label    = $leaf
            Path     = $k
            Tokens   = [int64]$dirMap[$k].Tokens
            Sessions = [int]$dirMap[$k].Sessions
        }
    }
    $top = @($top | Sort-Object Tokens -Descending | Select-Object -First 6)
    $win = 0
    try {
        $win = @(Get-CimInstance Win32_Process -Filter "Name='grok.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -and $_.ExecutablePath -notmatch 'Grok Bot' }).Count
    } catch { $win = 0 }
    return [pscustomobject]@{
        Range    = $Range
        Total    = $total
        Input    = $inp
        Output   = $outp
        Cached   = $cache
        Sessions = $sessCount
        Windows  = $win
        Days     = $days
        TopDirs  = $top
        Model    = $model
    }
}

function Ensure-ProcessCwdType {
    if ('ProcessCwd' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class ProcessCwd {
  const uint ACCESS = 0x0410;
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint a, bool i, int pid);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, int size, out IntPtr read);
  [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int pic, ref PBI pbi, int len, out int ret);
  [StructLayout(LayoutKind.Sequential)]
  struct PBI {
    public IntPtr A; public IntPtr Peb; public IntPtr B; public IntPtr C; public IntPtr D; public IntPtr E;
  }
  public static string Get(int pid) {
    IntPtr h = OpenProcess(ACCESS, false, pid);
    if (h == IntPtr.Zero) return null;
    try {
      PBI pbi = new PBI();
      int n;
      if (NtQueryInformationProcess(h, 0, ref pbi, Marshal.SizeOf(pbi), out n) != 0) return null;
      byte[] ptr = new byte[8];
      IntPtr r;
      if (!ReadProcessMemory(h, pbi.Peb + 0x20, ptr, 8, out r)) return null;
      long pp = BitConverter.ToInt64(ptr, 0);
      if (pp == 0) return null;
      byte[] us = new byte[16];
      if (!ReadProcessMemory(h, new IntPtr(pp + 0x38), us, 16, out r)) return null;
      int len = BitConverter.ToUInt16(us, 0);
      long buf = BitConverter.ToInt64(us, 8);
      if (len <= 0 || buf == 0) return null;
      byte[] path = new byte[len];
      if (!ReadProcessMemory(h, new IntPtr(buf), path, len, out r)) return null;
      return Encoding.Unicode.GetString(path).Trim().TrimEnd('\\');
    } finally { CloseHandle(h); }
  }
}
'@
}

function Format-RunAge {
    param($Started)
    if (-not $Started) { return '' }
    $span = [datetime]::Now - $Started
    if ($span.TotalSeconds -lt 60) { return ('跑了 {0} 秒' -f [int]$span.TotalSeconds) }
    if ($span.TotalMinutes -lt 60) { return ('跑了 {0} 分钟' -f [int]$span.TotalMinutes) }
    return ('跑了 {0} 小时' -f [Math]::Round($span.TotalHours, 1))
}

function Find-LatestSessionForCwd {
    param([string]$Cwd)
    if ([string]::IsNullOrWhiteSpace($Cwd)) { return $null }
    $sessionsRoot = Join-Path $env:USERPROFILE '.grok\sessions'
    if (-not (Test-Path -LiteralPath $sessionsRoot)) { return $null }
    $encoded = [uri]::EscapeDataString($Cwd)
    $group = Join-Path $sessionsRoot $encoded
    if (-not (Test-Path -LiteralPath $group)) { return $null }
    $best = $null
    $bestTime = [datetimeoffset]::MinValue
    foreach ($sessionDir in Get-ChildItem -LiteralPath $group -Directory -ErrorAction SilentlyContinue) {
        $sumPath = Join-Path $sessionDir.FullName 'summary.json'
        $updPath = Join-Path $sessionDir.FullName 'updates.jsonl'
        $sigPath = Join-Path $sessionDir.FullName 'signals.json'
        $when = $null
        $sum = $null
        if (Test-Path -LiteralPath $sumPath) {
            $sum = Read-JsonFile $sumPath
            if ($sum) {
                foreach ($field in @('last_active_at', 'updated_at')) {
                    if ($sum.PSObject.Properties.Name -contains $field) {
                        $when = Convert-GrokTime ([string]$sum.$field)
                        if ($when) { break }
                    }
                }
            }
            if (-not $when) { $when = [datetimeoffset](Get-Item -LiteralPath $sumPath).LastWriteTime }
        }
        $updWrite = $null
        if (Test-Path -LiteralPath $updPath) { $updWrite = (Get-Item -LiteralPath $updPath).LastWriteTime }
        if ($updWrite -and ((-not $when) -or ([datetimeoffset]$updWrite -gt $when))) {
            $when = [datetimeoffset]$updWrite
        }
        if (-not $when) { continue }
        if ($when -gt $bestTime) {
            $bestTime = $when
            $progress = 0
            $sig = $null
            if (Test-Path -LiteralPath $sigPath) { $sig = Read-JsonFile $sigPath }
            if ($sig -and $sig.PSObject.Properties.Name -contains 'contextWindowUsage') {
                try { $progress = [int]$sig.contextWindowUsage } catch { $progress = 0 }
            }
            $title = $null
            if ($sum) {
                foreach ($field in @('generated_title', 'session_summary', 'last_turn_summary')) {
                    if ($sum.PSObject.Properties.Name -contains $field -and $sum.$field) {
                        $title = Sanitize-Title ([string]$sum.$field)
                        if ($title) { break }
                    }
                }
            }
            $detail = $null
            if ($sum -and $sum.PSObject.Properties.Name -contains 'last_turn_summary' -and $sum.last_turn_summary) {
                $detail = Sanitize-Title ([string]$sum.last_turn_summary)
            }
            $best = [pscustomobject]@{
                When     = $when
                UpdWrite = $updWrite
                Title    = $title
                Detail   = $detail
                Progress = $progress
            }
        }
    }
    return $best
}

function Get-LiveGrokWindows {
    Ensure-ProcessCwdType
    if ($null -eq $script:watchMemory) { $script:watchMemory = @{} }
    $now = [datetime]::Now
    $exe = Get-GrokExe
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $rows = @()

    foreach ($p in Get-CimInstance Win32_Process -Filter "Name='grok.exe'" -ErrorAction SilentlyContinue) {
        $path = [string]$p.ExecutablePath
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if ($path -match 'Grok Bot') { continue }
        if ($exe -and -not [string]::Equals($path, $exe, [StringComparison]::OrdinalIgnoreCase)) { continue }

        $procId = [int]$p.ProcessId
        $seen.Add([string]$procId) | Out-Null
        $cwd = $null
        try { $cwd = [ProcessCwd]::Get($procId) } catch { $cwd = $null }
        $started = $null
        try {
            if ($p.CreationDate) { $started = [System.Management.ManagementDateTimeConverter]::ToDateTime($p.CreationDate) }
        } catch { }

        $meta = $null
        if ($cwd) { $meta = Find-LatestSessionForCwd $cwd }
        $leaf = if ($cwd) { Split-Path $cwd -Leaf } else { ('PID {0}' -f $procId) }

        $fileAgeSec = 9999
        if ($meta -and $meta.UpdWrite) { $fileAgeSec = ([datetime]::Now - $meta.UpdWrite).TotalSeconds }
        $procAgeSec = 9999
        if ($started) { $procAgeSec = ([datetime]::Now - $started).TotalSeconds }

        $mem = $script:watchMemory[$procId]
        if (-not $mem) {
            $mem = @{ WasWorking = $false; FirstSeen = $now }
            $script:watchMemory[$procId] = $mem
        }
        $kind = 'idle'
        if ($procAgeSec -lt 25) {
            $kind = 'created'
        } elseif ($fileAgeSec -lt 14) {
            $kind = 'working'
            $mem.WasWorking = $true
        } elseif ($mem.WasWorking -and $fileAgeSec -lt 150) {
            $kind = 'done'
        } else {
            $kind = 'idle'
            if ($fileAgeSec -gt 180) { $mem.WasWorking = $false }
        }

        $detail = $null
        switch ($kind) {
            'created' { $detail = '新窗口刚打开' }
            'working' { $detail = '正在跑这一轮任务' }
            'done'    { $detail = '这一轮已经写完，窗口还在' }
            default   { $detail = '停在提示符，等你说话' }
        }
        if ($meta -and $meta.Detail -and $kind -ne 'created') { $detail = $meta.Detail }

        $rows += [pscustomobject]@{
            Pid      = $procId
            Label    = $leaf
            Path     = $(if ($cwd) { $cwd } else { '' })
            Kind     = $kind
            Title    = $(if ($meta -and $meta.Title) { $meta.Title } else { 'Grok 会话' })
            Progress = $(if ($meta) { [int]$meta.Progress } else { 0 })
            AgeText  = Format-RunAge $started
            Detail   = $detail
        }
    }

    $forget = @()
    foreach ($key in @($script:watchMemory.Keys)) {
        if (-not $seen.Contains([string]$key)) { $forget += $key }
    }
    foreach ($key in $forget) { $script:watchMemory.Remove($key) }
    return $rows
}

function Format-Ago {
    param($When)
    if (-not $When) { return '' }
    $local = $When.ToLocalTime().DateTime
    $span = [datetime]::Now - $local
    if ($span.TotalMinutes -lt 1) { return '刚刚' }
    if ($span.TotalMinutes -lt 60) { return ('{0} 分钟前' -f [int]$span.TotalMinutes) }
    if ($span.TotalHours -lt 24) { return ('{0} 小时前' -f [int]$span.TotalHours) }
    if ($span.TotalDays -lt 7) { return ('{0} 天前' -f [int]$span.TotalDays) }
    return $local.ToString('yyyy-MM-dd HH:mm')
}

function Sort-Projects {
    param($Projects, $Pins)
    $pinSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in @($Pins)) {
        if ($p) { [void]$pinSet.Add($p.TrimEnd('\', '/')) }
    }
    $Projects | Sort-Object `
        @{ Expression = {
                $path = $_.Path.TrimEnd('\', '/')
                if ($pinSet.Contains($path)) { 0 } else { 1 }
            } }, `
        @{ Expression = { if ($_.Exists) { 0 } else { 1 } } }, `
        @{ Expression = { $_.LastActive }; Descending = $true }
}

function New-ProjectFromPath {
    param([Parameter(Mandatory)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path.TrimEnd('\', '/'))
    $leaf = Split-Path $full -Leaf
    if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = $full }
    return [pscustomobject]@{
        Path         = $full
        Name         = $leaf
        Parent       = Split-Path $full -Parent
        LastActive   = [datetimeoffset]::Now
        LastTitle    = ''
        SessionCount = 0
        Exists       = (Test-Path -LiteralPath $full)
        Label        = $leaf
    }
}

function Open-GrokProjects {
    param(
        [Parameter(Mandatory)][object[]]$Projects,
        [ValidateSet('continue', 'new', 'terminal', 'folder')][string]$Mode
    )

    $existing = @($Projects | Where-Object { $_.Exists })
    if ($Mode -eq 'folder') {
        foreach ($p in $existing) {
            Invoke-Item -LiteralPath $p.Path
        }
        if ($existing.Count -eq 0) {
            throw '选中的目录已经不在磁盘上。'
        }
        return
    }

    if ($existing.Count -eq 0) {
        throw '选中的目录已经不在磁盘上。'
    }

    $wt = Get-WtExe
    $grok = Get-GrokExe
    if ($Mode -ne 'terminal' -and -not $grok) {
        throw '找不到 grok.exe。确认已安装 Grok，并且 ~/.grok/bin 在 PATH 里。'
    }

    # Windows Terminal treats a top-level ";" as a new command. Never put ";"
    # inside -Command, or WT will try to start "& '...\grok.exe'" as a file.
    if ($wt) {
        $wtArgs = New-Object System.Collections.Generic.List[string]
        [void]$wtArgs.Add('-w')
        [void]$wtArgs.Add('0')
        $first = $true
        foreach ($p in $existing) {
            if (-not $first) { [void]$wtArgs.Add(';') }
            [void]$wtArgs.Add('new-tab')
            [void]$wtArgs.Add('--title')
            [void]$wtArgs.Add(($p.Label -replace '[;"]', ' '))
            [void]$wtArgs.Add('-d')
            [void]$wtArgs.Add($p.Path)
            if ($Mode -eq 'terminal') {
                [void]$wtArgs.Add('powershell.exe')
            } else {
                [void]$wtArgs.Add($grok)
                if ($Mode -eq 'continue') { [void]$wtArgs.Add('-c') }
            }
            $first = $false
        }
        $argLine = (
            $wtArgs | ForEach-Object {
                if ($_ -eq ';') { ';' }
                else { '"{0}"' -f ($_ -replace '"', '\"') }
            }
        ) -join ' '
        Start-Process -FilePath $wt -ArgumentList $argLine | Out-Null
        return
    }

    foreach ($p in $existing) {
        if ($Mode -eq 'terminal') {
            Start-Process -FilePath 'powershell.exe' -WorkingDirectory $p.Path | Out-Null
            continue
        }
        $arg = @()
        if ($Mode -eq 'continue') { $arg += '-c' }
        Start-Process -FilePath $grok -ArgumentList $arg -WorkingDirectory $p.Path | Out-Null
    }
}

if ($WatchList) {
    if ($script:DemoMode) {
        Get-DemoLiveWindows | Format-Table Pid, Kind, Label, Progress, Detail -AutoSize
    } else {
        Get-LiveGrokWindows | Format-Table Pid, Kind, Label, Progress, Path -AutoSize
    }
    exit 0
}

if ($ListOnly) {
    $cfg = Read-LauncherConfig
    $rows = Sort-Projects -Projects (Get-GrokRecentProjects) -Pins $cfg.pins
    if ($Limit -gt 0) { $rows = @($rows | Select-Object -First $Limit) }
    $rows | ForEach-Object {
        $proj = $_
        $pinned = $false
        foreach ($pin in @($cfg.pins)) {
            if (Test-SamePath $pin $proj.Path) { $pinned = $true; break }
        }
        [pscustomobject]@{
            Pin      = $(if ($pinned) { '*' } else { '' })
            Label    = $proj.Label
            Ago      = Format-Ago $proj.LastActive
            Sessions = $proj.SessionCount
            Exists   = $proj.Exists
            Title    = $proj.LastTitle
            Path     = $proj.Path
        }
    } | Format-Table -AutoSize
    exit 0
}

if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $argList = New-Object System.Collections.Generic.List[string]
    [void]$argList.Add('-STA')
    [void]$argList.Add('-NoProfile')
    [void]$argList.Add('-ExecutionPolicy')
    [void]$argList.Add('Bypass')
    if (-not $script:ScreenshotMode) {
        [void]$argList.Add('-WindowStyle')
        [void]$argList.Add('Hidden')
    }
    [void]$argList.Add('-File')
    [void]$argList.Add($PSCommandPath)
    if ($Demo) { [void]$argList.Add('-Demo') }
    if ($Screenshot) { [void]$argList.Add('-Screenshot') }
    if ($ScreenshotWatch) { [void]$argList.Add('-ScreenshotWatch') }
    if ($ScreenshotDash) { [void]$argList.Add('-ScreenshotDash') }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList.ToArray() | Out-Null
    exit 0
}

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
    [System.Windows.Forms.Application]::add_ThreadException({
            param($sender, $e)
            try {
                [System.IO.File]::AppendAllText($script:ErrorLog, ("{0}`r`n{1}`r`n`r`n" -f (Get-Date), $e.Exception))
            } catch { }
            [System.Windows.Forms.MessageBox]::Show($e.Exception.Message, 'Grok 最近项目') | Out-Null
        })
    [AppDomain]::CurrentDomain.add_UnhandledException({
            param($sender, $e)
            try {
                [System.IO.File]::AppendAllText($script:ErrorLog, ("{0}`r`n{1}`r`n`r`n" -f (Get-Date), $e.ExceptionObject))
            } catch { }
        })
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class NativeDpi {
  [DllImport("user32.dll")]
  public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, string lParam);
}
'@
        [NativeDpi]::SetProcessDPIAware() | Out-Null
    } catch { }
    try {
        Add-Type -ReferencedAssemblies @('System.Windows.Forms.dll') -TypeDefinition @'
using System.Reflection;
using System.Windows.Forms;
public static class UiUtil {
  public static void EnableDoubleBuffer(Control c) {
    typeof(Control).InvokeMember("DoubleBuffered",
      BindingFlags.SetProperty | BindingFlags.Instance | BindingFlags.NonPublic,
      null, c, new object[] { true });
  }
}
'@
    } catch { }

    $script:config = Read-LauncherConfig
    $script:allProjects = @()

    $bg = [System.Drawing.Color]::FromArgb(14, 14, 12)
    $panel = [System.Drawing.Color]::FromArgb(26, 24, 21)
    $toolbarBg = [System.Drawing.Color]::FromArgb(20, 19, 17)
    $line = [System.Drawing.Color]::FromArgb(52, 46, 38)
    $text = [System.Drawing.Color]::FromArgb(240, 233, 220)
    $muted = [System.Drawing.Color]::FromArgb(138, 130, 116)
    $accent = [System.Drawing.Color]::FromArgb(212, 154, 64)
    $accentHover = [System.Drawing.Color]::FromArgb(228, 174, 86)
    $select = [System.Drawing.Color]::FromArgb(72, 52, 24)
    $hover = [System.Drawing.Color]::FromArgb(36, 32, 26)
    $danger = [System.Drawing.Color]::FromArgb(176, 96, 72)
    $ink = [System.Drawing.Color]::FromArgb(28, 22, 12)
    $uiFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    $titleFont = New-Object System.Drawing.Font('Georgia', 18, [System.Drawing.FontStyle]::Bold)
    $smallFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.25)
    $rowFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.75)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Grok 最近项目'
    $form.StartPosition = 'CenterScreen'
    $form.Size = New-Object System.Drawing.Size(1100, 680)
    $form.MinimumSize = New-Object System.Drawing.Size(920, 520)
    $form.BackColor = $bg
    $form.ForeColor = $text
    $form.Font = $uiFont
    $form.KeyPreview = $true
    $form.ShowInTaskbar = $true
    $form.TopMost = $true
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $form.Padding = New-Object System.Windows.Forms.Padding(0)
    try {
        $grokIco = Get-GrokExe
        if ($grokIco) { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($grokIco) }
    } catch { }

    $topStack = New-Object System.Windows.Forms.Panel
    $topStack.Dock = 'Top'
    $topStack.Height = 136
    $topStack.BackColor = $bg
    $form.Controls.Add($topStack)

    $header = New-Object System.Windows.Forms.Panel
    $header.SetBounds(0, 0, 1020, 78)
    $header.Anchor = 'Top,Left,Right'
    $header.BackColor = $bg
    $topStack.Controls.Add($header)

    $accentBar = New-Object System.Windows.Forms.Panel
    $accentBar.Height = 3
    $accentBar.Dock = 'Top'
    $accentBar.BackColor = $accent
    $header.Controls.Add($accentBar)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = '最近的 Grok 项目'
    $title.Font = $titleFont
    $title.ForeColor = $text
    $title.Location = New-Object System.Drawing.Point(22, 14)
    $title.AutoSize = $true
    $header.Controls.Add($title)

    $ver = New-Object System.Windows.Forms.Label
    $ver.Text = ('v{0}' -f $script:AppVersion)
    $ver.Font = $smallFont
    $ver.ForeColor = $muted
    $ver.Location = New-Object System.Drawing.Point(250, 24)
    $ver.AutoSize = $true
    $header.Controls.Add($ver)

    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = '从本机会话找回目录 · 多选后一次在 Windows Terminal 打开'
    $subtitle.Font = $smallFont
    $subtitle.ForeColor = $muted
    $subtitle.Location = New-Object System.Drawing.Point(24, 50)
    $subtitle.AutoSize = $true
    $header.Controls.Add($subtitle)

    $btnAbout = New-Object System.Windows.Forms.Button
    $btnAbout.Text = '关于'
    $btnAbout.FlatStyle = 'Flat'
    $btnAbout.FlatAppearance.BorderSize = 1
    $btnAbout.FlatAppearance.BorderColor = $line
    $btnAbout.FlatAppearance.MouseOverBackColor = $hover
    $btnAbout.BackColor = $panel
    $btnAbout.ForeColor = $muted
    $btnAbout.Width = 68
    $btnAbout.Height = 28
    $btnAbout.Anchor = 'Top,Right'
    $btnAbout.Cursor = [System.Windows.Forms.Cursors]::Hand
    $header.Controls.Add($btnAbout)

    function New-TabButton {
        param([string]$Text)
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $Text
        $b.FlatStyle = 'Flat'
        $b.FlatAppearance.BorderSize = 0
        $b.FlatAppearance.MouseOverBackColor = $hover
        $b.BackColor = $bg
        $b.ForeColor = $muted
        $b.Width = 70
        $b.Height = 28
        $b.Cursor = [System.Windows.Forms.Cursors]::Hand
        $b.Font = $uiFont
        $header.Controls.Add($b)
        return $b
    }
    $tabDash = New-TabButton '仪表盘'
    $tabDash.Width = 76
    $tabProjects = New-TabButton '项目'
    $tabWatch = New-TabButton '监视'
    $tabDash.ForeColor = $accent

    $toolbar = New-Object System.Windows.Forms.Panel
    $toolbar.SetBounds(0, 78, 1020, 58)
    $toolbar.Anchor = 'Top,Left,Right'
    $toolbar.BackColor = $toolbarBg
    $topStack.Controls.Add($toolbar)

    $searchHost = New-Object System.Windows.Forms.Panel
    $searchHost.Location = New-Object System.Drawing.Point(22, 12)
    $searchHost.Size = New-Object System.Drawing.Size(340, 34)
    $searchHost.BackColor = $panel
    $toolbar.Controls.Add($searchHost)

    $searchMark = New-Object System.Windows.Forms.Label
    $searchMark.Text = '⌕'
    $searchMark.Font = New-Object System.Drawing.Font('Segoe UI Symbol', 11)
    $searchMark.ForeColor = $muted
    $searchMark.Location = New-Object System.Drawing.Point(8, 6)
    $searchMark.AutoSize = $true
    $searchHost.Controls.Add($searchMark)

    $search = New-Object System.Windows.Forms.TextBox
    $search.BorderStyle = 'None'
    $search.BackColor = $panel
    $search.ForeColor = $text
    $search.Font = $rowFont
    $search.Location = New-Object System.Drawing.Point(30, 8)
    $search.Width = 300
    $searchHost.Controls.Add($search)
    $script:search = $search
    $search.Add_HandleCreated({
            [void][NativeDpi]::SendMessage($search.Handle, 0x1501, [IntPtr]1, '搜索项目、路径或摘要')
        })

    $hideMissing = New-Object System.Windows.Forms.CheckBox
    $hideMissing.Text = '隐藏失效'
    $hideMissing.ForeColor = $muted
    $hideMissing.AutoSize = $true
    $hideMissing.Location = New-Object System.Drawing.Point(376, 18)
    $hideMissing.Checked = [bool]$script:config.hideMissing
    $hideMissing.FlatStyle = 'Flat'
    $toolbar.Controls.Add($hideMissing)

    function New-BarButton {
        param(
            [string]$Text,
            [System.Drawing.Color]$Back,
            [System.Drawing.Color]$Fore,
            [int]$Width = 78,
            [System.Drawing.Color]$HoverBack
        )
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $Text
        $b.FlatStyle = 'Flat'
        $b.FlatAppearance.BorderSize = 0
        $b.FlatAppearance.MouseOverBackColor = $HoverBack
        $b.BackColor = $Back
        $b.ForeColor = $Fore
        $b.Width = $Width
        $b.Height = 34
        $b.Font = $uiFont
        $b.Cursor = [System.Windows.Forms.Cursors]::Hand
        $toolbar.Controls.Add($b)
        return $b
    }

    $btnContinue = New-BarButton '续上' $accent $ink 86 $accentHover
    $btnNew = New-BarButton '新开' $panel $text 72 $hover
    $btnTerm = New-BarButton '终端' $panel $text 72 $hover
    $btnFolder = New-BarButton '文件夹' $panel $text 80 $hover
    $btnRefresh = New-BarButton '刷新' $panel $muted 72 $hover
    foreach ($b in @($btnNew, $btnTerm, $btnFolder, $btnRefresh)) {
        $b.FlatAppearance.BorderSize = 1
        $b.FlatAppearance.BorderColor = $line
    }
    $tip = New-Object System.Windows.Forms.ToolTip
    $tip.SetToolTip($btnNew, '在列表选中的目录新开 Grok 会话')
    $tip.SetToolTip($btnContinue, '继续该目录最近一次会话')
    $tip.SetToolTip($btnFolder, '选择任意目录，在那里新开 Grok（不是只打开资源管理器）')
    $tip.SetToolTip($btnTerm, '只打开终端，停在选中目录')

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = 'Fill'
    $grid.BackgroundColor = $bg
    $grid.ForeColor = $text
    $grid.GridColor = [System.Drawing.Color]::FromArgb(40, 36, 30)
    $grid.BorderStyle = 'None'
    $grid.CellBorderStyle = 'SingleHorizontal'
    $grid.ColumnHeadersBorderStyle = 'None'
    $grid.RowHeadersVisible = $false
    $grid.EnableHeadersVisualStyles = $false
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.ReadOnly = $true
    $grid.MultiSelect = $true
    $grid.SelectionMode = 'FullRowSelect'
    $grid.AutoSizeColumnsMode = 'Fill'
    $grid.RowTemplate.Height = 38
    $grid.ColumnHeadersHeight = 34
    $grid.ColumnHeadersHeightSizeMode = 'DisableResizing'
    $grid.ShowCellToolTips = $true
    $pad = New-Object System.Windows.Forms.Padding(10, 6, 10, 6)
    $grid.DefaultCellStyle.BackColor = $panel
    $grid.DefaultCellStyle.ForeColor = $text
    $grid.DefaultCellStyle.SelectionBackColor = $select
    $grid.DefaultCellStyle.SelectionForeColor = $text
    $grid.DefaultCellStyle.Font = $rowFont
    $grid.DefaultCellStyle.Padding = $pad
    $grid.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(22, 21, 18)
    $grid.AlternatingRowsDefaultCellStyle.ForeColor = $text
    $grid.AlternatingRowsDefaultCellStyle.SelectionBackColor = $select
    $grid.AlternatingRowsDefaultCellStyle.SelectionForeColor = $text
    $grid.ColumnHeadersDefaultCellStyle.BackColor = $toolbarBg
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = $muted
    $grid.ColumnHeadersDefaultCellStyle.Font = $smallFont
    $grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = $toolbarBg
    $grid.ColumnHeadersDefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(10, 0, 8, 0)
    $grid.ColumnHeadersDefaultCellStyle.WrapMode = [System.Windows.Forms.DataGridViewTriState]::False
    $form.Controls.Add($grid)
    $script:grid = $grid
    try { [UiUtil]::EnableDoubleBuffer($grid) } catch { }
    try { [UiUtil]::EnableDoubleBuffer($form) } catch { }

    $statusHost = New-Object System.Windows.Forms.Panel
    $statusHost.Dock = 'Bottom'
    $statusHost.Height = 34
    $statusHost.BackColor = $toolbarBg
    $form.Controls.Add($statusHost)
    $statusLine = New-Object System.Windows.Forms.Panel
    $statusLine.Dock = 'Top'
    $statusLine.Height = 1
    $statusLine.BackColor = $line
    $statusHost.Controls.Add($statusLine)
    $status = New-Object System.Windows.Forms.Label
    $status.Dock = 'Fill'
    $status.ForeColor = $muted
    $status.Font = $smallFont
    $status.TextAlign = 'MiddleLeft'
    $status.Padding = New-Object System.Windows.Forms.Padding(20, 0, 8, 0)
    $status.Text = '双击续上  ·  Enter 打开  ·  Ctrl+A 全选  ·  Esc 关闭  ·  点 ★ 置顶'
    $statusHost.Controls.Add($status)

    $empty = New-Object System.Windows.Forms.Label
    $empty.Text = "还没有会话记录`r`n在某个项目目录运行过 grok 之后，就会出现在这里"
    $empty.TextAlign = 'MiddleCenter'
    $empty.ForeColor = $muted
    $empty.BackColor = $bg
    $empty.Font = $uiFont
    $empty.Visible = $false
    $form.Controls.Add($empty)

    $pageWatch = New-Object System.Windows.Forms.Panel
    $pageWatch.Dock = 'Fill'
    $pageWatch.BackColor = $bg
    $pageWatch.Visible = $false
    $form.Controls.Add($pageWatch)

    $watchHint = New-Object System.Windows.Forms.Label
    $watchHint.Dock = 'Top'
    $watchHint.Height = 28
    $watchHint.ForeColor = $muted
    $watchHint.Font = $smallFont
    $watchHint.Padding = New-Object System.Windows.Forms.Padding(22, 6, 8, 0)
    $watchHint.Text = '正在跑的窗口会列在这里。任务开始转圈，写完打勾。'
    $pageWatch.Controls.Add($watchHint)

    $watchFlow = New-Object System.Windows.Forms.FlowLayoutPanel
    $watchFlow.Dock = 'Fill'
    $watchFlow.AutoScroll = $true
    $watchFlow.WrapContents = $false
    $watchFlow.FlowDirection = 'TopDown'
    $watchFlow.BackColor = $bg
    $watchFlow.Padding = New-Object System.Windows.Forms.Padding(16, 4, 8, 8)
    $pageWatch.Controls.Add($watchFlow)

    $watchEmpty = New-Object System.Windows.Forms.Label
    $watchEmpty.Text = "现在没有正在运行的 Grok 窗口`r`n用「新开」或「文件夹」打开之后，会出现在这里"
    $watchEmpty.TextAlign = 'MiddleCenter'
    $watchEmpty.ForeColor = $muted
    $watchEmpty.BackColor = $bg
    $watchEmpty.Dock = 'Fill'
    $watchEmpty.Visible = $false
    $pageWatch.Controls.Add($watchEmpty)

    $pageDash = New-Object System.Windows.Forms.Panel
    $pageDash.Dock = 'Fill'
    $pageDash.BackColor = $bg
    $pageDash.AutoScroll = $true
    $pageDash.Visible = $false
    $form.Controls.Add($pageDash)

    $dashInner = New-Object System.Windows.Forms.Panel
    $dashInner.Location = New-Object System.Drawing.Point(0, 0)
    $dashInner.Size = New-Object System.Drawing.Size(1080, 820)
    $dashInner.BackColor = $bg
    $pageDash.Controls.Add($dashInner)

    $rangeHost = New-Object System.Windows.Forms.Panel
    $rangeHost.SetBounds(20, 10, 1040, 36)
    $rangeHost.BackColor = $bg
    $dashInner.Controls.Add($rangeHost)
    $rangeLabel = New-Object System.Windows.Forms.Label
    $rangeLabel.Text = '用量时间'
    $rangeLabel.ForeColor = $muted
    $rangeLabel.Font = $smallFont
    $rangeLabel.AutoSize = $true
    $rangeLabel.Location = New-Object System.Drawing.Point(0, 8)
    $rangeHost.Controls.Add($rangeLabel)

    $script:rangeButtons = @{}
    $rx = 70
    $rangeDefs = @(
        [pscustomobject]@{ Key = 'today'; Text = '今天' }
        [pscustomobject]@{ Key = '7d'; Text = '近 7 天' }
        [pscustomobject]@{ Key = '30d'; Text = '近 30 天' }
        [pscustomobject]@{ Key = 'all'; Text = '全部' }
    )
    foreach ($def in $rangeDefs) {
        $rb = New-Object System.Windows.Forms.Button
        $rb.Text = $def.Text
        $rb.Tag = $def.Key
        $rb.FlatStyle = 'Flat'
        $rb.FlatAppearance.BorderSize = 1
        $rb.FlatAppearance.BorderColor = $line
        $rb.BackColor = $panel
        $rb.ForeColor = $text
        $rb.Width = 78
        $rb.Height = 28
        $rb.Left = $rx
        $rb.Top = 2
        $rb.Cursor = [System.Windows.Forms.Cursors]::Hand
        $rangeHost.Controls.Add($rb)
        $script:rangeButtons[$def.Key] = $rb
        $rx += 86
    }

    function New-StatCard {
        param([int]$X, [string]$Caption)
        $card = New-Object System.Windows.Forms.Panel
        $card.SetBounds($X, 54, 250, 92)
        $card.BackColor = $panel
        $dashInner.Controls.Add($card)
        $cap = New-Object System.Windows.Forms.Label
        $cap.Text = $Caption
        $cap.ForeColor = $muted
        $cap.Font = $smallFont
        $cap.Location = New-Object System.Drawing.Point(16, 12)
        $cap.AutoSize = $true
        $card.Controls.Add($cap)
        $val = New-Object System.Windows.Forms.Label
        $val.Text = '0.00 M'
        $val.ForeColor = $accent
        $val.Font = $titleFont
        $val.Location = New-Object System.Drawing.Point(14, 36)
        $val.AutoSize = $true
        $card.Controls.Add($val)
        return $val
    }
    $valTotal = New-StatCard 20 'Token 总量'
    $valIn = New-StatCard 284 '输入'
    $valOut = New-StatCard 548 '输出'
    $valSess = New-StatCard 812 '会话 / 窗口'

    $chartBox = New-Object System.Windows.Forms.PictureBox
    $chartBox.SetBounds(20, 156, 1044, 118)
    $chartBox.BackColor = $panel
    $chartBox.SizeMode = 'Normal'
    $dashInner.Controls.Add($chartBox)

    $quickHost = New-Object System.Windows.Forms.Panel
    $quickHost.SetBounds(20, 286, 1044, 72)
    $quickHost.BackColor = $panel
    $dashInner.Controls.Add($quickHost)
    $quickTitle = New-Object System.Windows.Forms.Label
    $quickTitle.Text = '一键打开最近常用目录'
    $quickTitle.ForeColor = $text
    $quickTitle.Font = $rowFont
    $quickTitle.Location = New-Object System.Drawing.Point(16, 12)
    $quickTitle.AutoSize = $true
    $quickHost.Controls.Add($quickTitle)
    $quickHint = New-Object System.Windows.Forms.Label
    $quickHint.Text = '数量'
    $quickHint.ForeColor = $muted
    $quickHint.Font = $smallFont
    $quickHint.Location = New-Object System.Drawing.Point(16, 40)
    $quickHint.AutoSize = $true
    $quickHost.Controls.Add($quickHint)
    $numQuick = New-Object System.Windows.Forms.NumericUpDown
    $numQuick.Minimum = 1
    $numQuick.Maximum = 12
    $numQuick.Value = [decimal]$script:config.quickLaunchCount
    $numQuick.Width = 56
    $numQuick.Location = New-Object System.Drawing.Point(52, 36)
    $numQuick.BackColor = $bg
    $numQuick.ForeColor = $text
    $numQuick.BorderStyle = 'FixedSingle'
    $quickHost.Controls.Add($numQuick)
    $btnQuick = New-Object System.Windows.Forms.Button
    $btnQuick.Text = '一键续上'
    $btnQuick.FlatStyle = 'Flat'
    $btnQuick.FlatAppearance.BorderSize = 0
    $btnQuick.BackColor = $accent
    $btnQuick.ForeColor = $ink
    $btnQuick.Width = 110
    $btnQuick.Height = 32
    $btnQuick.Location = New-Object System.Drawing.Point(122, 32)
    $btnQuick.Cursor = [System.Windows.Forms.Cursors]::Hand
    $quickHost.Controls.Add($btnQuick)
    $quickNote = New-Object System.Windows.Forms.Label
    $quickNote.ForeColor = $muted
    $quickNote.Font = $smallFont
    $quickNote.Location = New-Object System.Drawing.Point(250, 38)
    $quickNote.AutoSize = $true
    $quickNote.Text = '按最近活动顺序打开，并继续上次会话'
    $quickHost.Controls.Add($quickNote)

    $topTitle = New-Object System.Windows.Forms.Label
    $topTitle.Text = '用量最高的目录'
    $topTitle.ForeColor = $muted
    $topTitle.Font = $smallFont
    $topTitle.Location = New-Object System.Drawing.Point(22, 368)
    $topTitle.AutoSize = $true
    $dashInner.Controls.Add($topTitle)
    $topList = New-Object System.Windows.Forms.ListBox
    $topList.SetBounds(20, 390, 1044, 140)
    $topList.BackColor = $panel
    $topList.ForeColor = $text
    $topList.BorderStyle = 'None'
    $topList.Font = $rowFont
    $topList.IntegralHeight = $false
    $dashInner.Controls.Add($topList)

    function Layout-Buttons {
        $btnAbout.Left = $header.ClientSize.Width - 90
        $btnAbout.Top = 22
        $tabWatch.Left = $btnAbout.Left - 76
        $tabWatch.Top = 22
        $tabProjects.Left = $tabWatch.Left - 70
        $tabProjects.Top = 22
        $tabDash.Left = $tabProjects.Left - 82
        $tabDash.Top = 22
        $right = $toolbar.ClientSize.Width - 18
        foreach ($b in @($btnRefresh, $btnFolder, $btnTerm, $btnNew, $btnContinue)) {
            $right -= $b.Width
            $b.Left = $right
            $b.Top = 12
            $b.Anchor = 'Top,Right'
            $right -= 8
        }
        $hideMissing.Left = [Math]::Min(376, [Math]::Max(220, $right - 100))
        $searchHost.Width = [Math]::Max(180, $hideMissing.Left - 36)
        $search.Width = [Math]::Max(120, $searchHost.Width - 40)
        $empty.Bounds = $grid.Bounds
        $ver.Left = $title.Right + 10
        $header.Width = $topStack.ClientSize.Width
        $toolbar.Width = $topStack.ClientSize.Width
        $toolbar.Top = $header.Height
    }

    function Fit-FormHeight {
        if ($script:activePage -ne 'projects') { return }
        $visibleCount = $grid.Rows.Count
        $show = [Math]::Max(4, [Math]::Min(8, $visibleCount))
        if ($visibleCount -eq 0) { $show = 5 }
        $needed = $topStack.Height + $grid.ColumnHeadersHeight + ($show * $grid.RowTemplate.Height) + $statusHost.Height + 8
        if ($needed -lt $form.MinimumSize.Height) { $needed = $form.MinimumSize.Height }
        if ([Math]::Abs($form.Height - $needed) -gt 8) {
            $form.Height = $needed
        }
    }

    $form.Add_Resize({ Layout-Buttons })
    Layout-Buttons

    $script:hoverRow = -1
    $grid.Add_CellFormatting({
            param($sender, $e)
            if ($e.RowIndex -lt 0 -or $e.ColumnIndex -lt 0) { return }
            $col = $grid.Columns[$e.ColumnIndex].Name
            if ($col -eq 'Pin') {
                if ([string]$e.Value -eq '★') { $e.CellStyle.ForeColor = $accent; $e.CellStyle.SelectionForeColor = $accent }
                else { $e.CellStyle.ForeColor = $muted; $e.CellStyle.SelectionForeColor = $muted }
            } elseif ($col -eq 'Path' -or $col -eq 'Ago') {
                $e.CellStyle.ForeColor = $muted
                $e.CellStyle.SelectionForeColor = $text
            }
        })
    $grid.Add_CellPainting({
            param($sender, $e)
            if ($e.RowIndex -lt 0 -or $e.ColumnIndex -ne 0) { return }
            if (-not $grid.Rows[$e.RowIndex].Selected) { return }
            $e.PaintBackground($e.CellBounds, $true)
            $e.PaintContent($e.ClipBounds)
            $br = New-Object System.Drawing.SolidBrush $accent
            $e.Graphics.FillRectangle($br, $e.CellBounds.X, $e.CellBounds.Y, 3, $e.CellBounds.Height)
            $br.Dispose()
            $e.Handled = $true
        })
    $grid.Add_CellMouseEnter({
            param($sender, $e)
            if ($e.RowIndex -lt 0) { return }
            if ($script:hoverRow -ge 0 -and $script:hoverRow -ne $e.RowIndex -and $script:hoverRow -lt $grid.Rows.Count) {
                $grid.Rows[$script:hoverRow].DefaultCellStyle.BackColor = [System.Drawing.Color]::Empty
            }
            $script:hoverRow = $e.RowIndex
            if (-not $grid.Rows[$e.RowIndex].Selected) {
                $grid.Rows[$e.RowIndex].DefaultCellStyle.BackColor = $hover
            }
        })
    $grid.Add_MouseLeave({
            if ($script:hoverRow -ge 0 -and $script:hoverRow -lt $grid.Rows.Count) {
                $grid.Rows[$script:hoverRow].DefaultCellStyle.BackColor = [System.Drawing.Color]::Empty
            }
            $script:hoverRow = -1
        })

    function Get-VisibleProjects {
        $q = $search.Text.Trim()
        $list = @($script:allProjects)
        if ($hideMissing.Checked) {
            $list = @($list | Where-Object { $_.Exists })
        }
        if ($q) {
            $list = @($list | Where-Object {
                    (Test-TextMatch $_.Label $q) -or
                    (Test-TextMatch $_.Path $q) -or
                    (Test-TextMatch $_.LastTitle $q)
                })
        }
        return @(Sort-Projects -Projects $list -Pins $script:config.pins)
    }

    function Test-IsPinned {
        param([string]$Path)
        foreach ($p in @($script:config.pins)) {
            if (Test-SamePath $p $Path) { return $true }
        }
        return $false
    }

    function Show-Rows {
        $selected = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($row in $grid.SelectedRows) {
            if ($row.Tag -and $row.Tag.Path) { [void]$selected.Add($row.Tag.Path) }
        }

        $grid.Rows.Clear()
        if ($grid.Columns.Count -eq 0) {
            $cPin = $grid.Columns.Add('Pin', '')
            $cName = $grid.Columns.Add('Name', '项目')
            $cAgo = $grid.Columns.Add('Ago', '上次')
            $cCount = $grid.Columns.Add('Sessions', '会话')
            $cTitle = $grid.Columns.Add('Title', '摘要')
            $cPath = $grid.Columns.Add('Path', '路径')
            $grid.Columns[$cPin].FillWeight = 6
            $grid.Columns[$cName].FillWeight = 18
            $grid.Columns[$cAgo].FillWeight = 11
            $grid.Columns[$cCount].FillWeight = 7
            $grid.Columns[$cTitle].FillWeight = 32
            $grid.Columns[$cPath].FillWeight = 26
            $grid.Columns[$cPin].MinimumWidth = 40
            $grid.Columns[$cCount].AutoSizeMode = 'None'
            $grid.Columns[$cCount].Width = 72
            $grid.Columns[$cCount].MinimumWidth = 72
            $grid.Columns[$cAgo].MinimumWidth = 88
            $grid.Columns[$cPin].DefaultCellStyle.Alignment = 'MiddleCenter'
            $grid.Columns[$cCount].DefaultCellStyle.Alignment = 'MiddleCenter'
            $grid.Columns[$cAgo].DefaultCellStyle.Alignment = 'MiddleLeft'
            $grid.Columns[$cPath].DefaultCellStyle.ForeColor = $muted
            $grid.Columns[$cAgo].DefaultCellStyle.ForeColor = $muted
        }

        $visible = Get-VisibleProjects
        foreach ($proj in $visible) {
            $pinMark = if (Test-IsPinned $proj.Path) { '★' } else { '☆' }
            $titleText = if ($proj.LastTitle) { $proj.LastTitle } else { '' }
            $idx = $grid.Rows.Add($pinMark, $proj.Label, (Format-Ago $proj.LastActive), $proj.SessionCount, $titleText, $proj.Path)
            $grid.Rows[$idx].Tag = $proj
            if (-not $proj.Exists) {
                $grid.Rows[$idx].DefaultCellStyle.ForeColor = $danger
            }
            if ($selected.Contains($proj.Path)) {
                $grid.Rows[$idx].Selected = $true
            }
        }

        if ($grid.SelectedRows.Count -eq 0 -and $grid.Rows.Count -gt 0) {
            $grid.Rows[0].Selected = $true
        }

        $empty.Visible = ($grid.Rows.Count -eq 0)
        if ($empty.Visible) { $empty.BringToFront() } else { $grid.BringToFront() }

        $pinCount = @($script:config.pins).Count
        $status.Text = ('{0} 个项目    已选 {1}    置顶 {2}      双击续上 · Enter 打开 · Ctrl+A 全选 · Esc 关闭 · ★ 置顶' -f `
                $visible.Count, $grid.SelectedRows.Count, $pinCount)
        Fit-FormHeight
        Layout-Buttons
    }

    function Reload-Projects {
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            if ($script:DemoMode) {
                $script:allProjects = @(Get-DemoProjects)
            } else {
                $script:allProjects = @(Get-GrokRecentProjects)
            }
            Show-Rows
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    }

    function Get-SelectedProjects {
        $rows = @($grid.SelectedRows | Sort-Object Index)
        $list = @()
        foreach ($row in $rows) {
            if ($row.Tag) { $list += $row.Tag }
        }
        return $list
    }

    function Invoke-Open {
        param([string]$Mode)
        $picked = @(Get-SelectedProjects)
        if ($picked.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('先选一个或几个项目。', 'Grok 最近项目') | Out-Null
            return
        }
        try {
            Open-GrokProjects -Projects $picked -Mode $Mode
        } catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '打开失败') | Out-Null
        }
    }

    function Invoke-PickDirectoryAndNew {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = '选择目录，然后在这里新开 Grok'
        $dlg.ShowNewFolderButton = $true
        $picked = @(Get-SelectedProjects)
        if ($picked.Count -gt 0 -and $picked[0].Exists) {
            $dlg.SelectedPath = $picked[0].Path
        }
        $wasTop = $form.TopMost
        $form.TopMost = $false
        try {
            $result = $dlg.ShowDialog($form)
        } finally {
            $form.TopMost = $wasTop
        }
        if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return }
        if ([string]::IsNullOrWhiteSpace($dlg.SelectedPath)) { return }
        $proj = New-ProjectFromPath $dlg.SelectedPath
        if (-not $proj.Exists) {
            [System.Windows.Forms.MessageBox]::Show('这个目录不存在。', 'Grok 最近项目') | Out-Null
            return
        }
        try {
            Open-GrokProjects -Projects @($proj) -Mode 'new'
        } catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '打开失败') | Out-Null
        }
    }

    $script:watchCards = @{}
    $script:spinAngle = 0
    $script:activePage = 'projects'
    $kindLabel = @{
        created = '刚创建'
        working = '进行中'
        done    = '刚完成'
        idle    = '空闲'
    }
    $kindColor = @{
        created = $accent
        working = $accent
        done    = [System.Drawing.Color]::FromArgb(92, 168, 112)
        idle    = $muted
    }

    function New-StatusIcon {
        param([string]$Kind, [int]$Angle = 0, [int]$Size = 42)
        $bmp = New-Object System.Drawing.Bitmap $Size, $Size
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = 'AntiAlias'
        $g.Clear([System.Drawing.Color]::FromArgb(26, 24, 21))
        $rect = New-Object System.Drawing.Rectangle 4, 4, ($Size - 9), ($Size - 9)
        $cx = [int]($Size / 2)
        $cy = [int]($Size / 2)
        switch ($Kind) {
            'created' {
                $pen = New-Object System.Drawing.Pen($accent, 2.2)
                $g.DrawEllipse($pen, $rect)
                $pen.Dispose()
                $br = New-Object System.Drawing.SolidBrush $accent
                $g.FillRectangle($br, $cx - 2, 12, 4, $Size - 24)
                $g.FillRectangle($br, 12, $cy - 2, $Size - 24, 4)
                $br.Dispose()
            }
            'working' {
                $track = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(60, 52, 40), 3)
                $g.DrawEllipse($track, $rect)
                $track.Dispose()
                $pen = New-Object System.Drawing.Pen($accent, 3)
                $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
                $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
                $g.DrawArc($pen, $rect, $Angle, 110)
                $pen.Dispose()
            }
            'done' {
                $br = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(72, 148, 96))
                $g.FillEllipse($br, $rect)
                $br.Dispose()
                $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(18, 28, 16), 2.8)
                $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
                $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
                $g.DrawLine($pen, [int]($Size * 0.28), [int]($Size * 0.52), [int]($Size * 0.44), [int]($Size * 0.70))
                $g.DrawLine($pen, [int]($Size * 0.44), [int]($Size * 0.70), [int]($Size * 0.74), [int]($Size * 0.32))
                $pen.Dispose()
            }
            default {
                $pen = New-Object System.Drawing.Pen($muted, 2.2)
                $g.DrawEllipse($pen, $rect)
                $pen.Dispose()
                $br = New-Object System.Drawing.SolidBrush $muted
                $g.FillEllipse($br, $cx - 3, $cy - 3, 6, 6)
                $br.Dispose()
            }
        }
        $g.Dispose()
        return $bmp
    }

    function Set-CardIcon {
        param($Pic, [string]$Kind)
        $old = $Pic.Image
        $Pic.Image = New-StatusIcon -Kind $Kind -Angle $script:spinAngle
        if ($old) { $old.Dispose() }
    }

    function New-WatchCard {
        param($Row)
        $card = New-Object System.Windows.Forms.Panel
        $card.Height = 78
        $card.Width = 920
        $card.BackColor = $panel
        $card.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
        $card.Tag = $Row.Pid

        $pic = New-Object System.Windows.Forms.PictureBox
        $pic.SetBounds(12, 18, 42, 42)
        $pic.SizeMode = 'StretchImage'
        $card.Controls.Add($pic)
        Set-CardIcon $pic $Row.Kind

        $name = New-Object System.Windows.Forms.Label
        $name.Font = $rowFont
        $name.ForeColor = $text
        $name.AutoSize = $true
        $name.Location = New-Object System.Drawing.Point(66, 10)
        $card.Controls.Add($name)

        $badge = New-Object System.Windows.Forms.Label
        $badge.Font = $smallFont
        $badge.AutoSize = $true
        $badge.Location = New-Object System.Drawing.Point(220, 12)
        $card.Controls.Add($badge)

        $sub = New-Object System.Windows.Forms.Label
        $sub.Font = $smallFont
        $sub.ForeColor = $muted
        $sub.AutoSize = $true
        $sub.Location = New-Object System.Drawing.Point(66, 34)
        $card.Controls.Add($sub)

        $barBack = New-Object System.Windows.Forms.Panel
        $barBack.SetBounds(66, 58, 620, 5)
        $barBack.BackColor = [System.Drawing.Color]::FromArgb(40, 36, 30)
        $card.Controls.Add($barBack)
        $barFill = New-Object System.Windows.Forms.Panel
        $barFill.Height = 5
        $barFill.Top = 0
        $barFill.Left = 0
        $barFill.BackColor = $accent
        $barBack.Controls.Add($barFill)

        $watchFlow.Controls.Add($card)
        $info = @{
            Panel = $card; Pic = $pic; Name = $name; Badge = $badge
            Sub = $sub; Bar = $barFill; BarBack = $barBack; Kind = $Row.Kind
        }
        $script:watchCards[$Row.Pid] = $info
        Update-WatchCard $Row
        return $info
    }

    function Update-WatchCard {
        param($Row)
        $info = $script:watchCards[$Row.Pid]
        if (-not $info) { return }
        $info.Name.Text = $Row.Label
        $info.Badge.Text = $kindLabel[$Row.Kind]
        $info.Badge.ForeColor = $kindColor[$Row.Kind]
        $info.Badge.Left = $info.Name.Right + 12
        $line2 = @($Row.AgeText, ('PID {0}' -f $Row.Pid), $Row.Detail) | Where-Object { $_ }
        $info.Sub.Text = ($line2 -join '  ·  ')
        $pct = [Math]::Max(0, [Math]::Min(100, [int]$Row.Progress))
        $info.Bar.Width = [int](($info.BarBack.Width * $pct) / 100)
        $info.Bar.BackColor = $(if ($Row.Kind -eq 'done') { $kindColor.done } else { $accent })
        if ($info.Kind -ne $Row.Kind -or $Row.Kind -eq 'working') {
            Set-CardIcon $info.Pic $Row.Kind
            $info.Kind = $Row.Kind
        }
        $w = [Math]::Max(640, $watchFlow.ClientSize.Width - 28)
        $info.Panel.Width = $w
        $info.BarBack.Width = [Math]::Max(200, $w - 90)
        $info.Bar.Width = [int](($info.BarBack.Width * $pct) / 100)
    }

    function Sync-WatchCards {
        $rows = if ($script:DemoMode) { @(Get-DemoLiveWindows) } else { @(Get-LiveGrokWindows) }
        $live = New-Object 'System.Collections.Generic.HashSet[int]'
        foreach ($row in $rows) {
            [void]$live.Add([int]$row.Pid)
            if (-not $script:watchCards.Contains($row.Pid)) {
                New-WatchCard $row | Out-Null
            } else {
                Update-WatchCard $row
            }
        }
        $dead = @()
        foreach ($cardId in @($script:watchCards.Keys)) {
            if (-not $live.Contains([int]$cardId)) { $dead += $cardId }
        }
        foreach ($cardId in $dead) {
            $info = $script:watchCards[$cardId]
            if ($info.Pic.Image) { $info.Pic.Image.Dispose() }
            $watchFlow.Controls.Remove($info.Panel)
            $info.Panel.Dispose()
            $script:watchCards.Remove($cardId)
        }
        $n = $rows.Count
        $working = @($rows | Where-Object { $_.Kind -eq 'working' }).Count
        $done = @($rows | Where-Object { $_.Kind -eq 'done' }).Count
        $created = @($rows | Where-Object { $_.Kind -eq 'created' }).Count
        $watchHint.Text = ('{0} 个窗口在跑    进行中 {1}    刚完成 {2}    刚创建 {3}      任务一开始转圈，写完变成勾' -f $n, $working, $done, $created)
        $watchEmpty.Visible = ($n -eq 0)
        if ($watchEmpty.Visible) { $watchEmpty.BringToFront() } else { $watchFlow.BringToFront() }
        $status.Text = $watchHint.Text
    }

    function Show-ProjectsPage {
        $script:activePage = 'projects'
        $pageWatch.Visible = $false
        $grid.Visible = $true
        $toolbar.Visible = $true
        $topStack.Height = 136
        $title.Text = '最近的 Grok 项目'
        $subtitle.Text = '从本机会话找回目录 · 多选后一次在 Windows Terminal 打开'
        $tabDash.ForeColor = $muted
        $tabProjects.ForeColor = $accent
        $tabWatch.ForeColor = $muted
        $pageDash.Visible = $false
        Show-Rows
        $status.Text = '双击续上  ·  Enter 打开  ·  文件夹 = 选路径后新开 Grok'
    }

    function Show-WatchPage {
        $script:activePage = 'watch'
        $grid.Visible = $false
        $empty.Visible = $false
        $toolbar.Visible = $false
        $pageDash.Visible = $false
        $topStack.Height = 78
        $pageWatch.Visible = $true
        $pageWatch.BringToFront()
        $title.Text = '监视 Grok 窗口'
        $subtitle.Text = '多开窗口会列在这里 · 任务开始和结束会换图标'
        $tabDash.ForeColor = $muted
        $tabProjects.ForeColor = $muted
        $tabWatch.ForeColor = $accent
        $form.Height = [Math]::Max($form.Height, 560)
        Sync-WatchCards
        Layout-Buttons
    }

    function Draw-UsageChart {
        param($Snap)
        $w = [Math]::Max(200, $chartBox.Width)
        $h = [Math]::Max(80, $chartBox.Height)
        $bmp = New-Object System.Drawing.Bitmap $w, $h
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = 'AntiAlias'
        $g.Clear($panel)
        $days = @($Snap.Days)
        $mutedBr = New-Object System.Drawing.SolidBrush $muted
        $br = New-Object System.Drawing.SolidBrush $accent
        if ($days.Count -eq 0) {
            $g.DrawString('这段时间没有 usage.json 记录', $smallFont, $mutedBr, 20, 60)
        } else {
            $max = ($days | Measure-Object -Property Total -Maximum).Maximum
            if ($max -le 0) { $max = 1 }
            $padL = 18; $padB = 26; $padT = 28; $padR = 12
            $plotW = $w - $padL - $padR
            $plotH = $h - $padT - $padB
            $n = $days.Count
            $slot = $plotW / [double]$n
            $bw = [Math]::Max(6, [int]($slot - 6))
            $g.DrawString('每天 Token（百万）', $smallFont, $mutedBr, $padL, 6)
            $idx = 0
            foreach ($day in $days) {
                $x = $padL + [int]($idx * $slot) + 2
                $bh = [int]($plotH * ([double]$day.Total / $max))
                if ($bh -lt 2 -and $day.Total -gt 0) { $bh = 2 }
                $y = $padT + $plotH - $bh
                $g.FillRectangle($br, $x, $y, $bw, $bh)
                if ($n -le 16 -or ($idx % 2 -eq 0)) {
                    $g.DrawString($day.Date.ToString('M/d'), $smallFont, $mutedBr, $x, $h - 22)
                }
                $idx++
            }
        }
        $br.Dispose(); $mutedBr.Dispose(); $g.Dispose()
        $old = $chartBox.Image
        $chartBox.Image = $bmp
        if ($old) { $old.Dispose() }
    }

    function Refresh-Dash {
        $range = $script:config.usageRange
        if (@('today', '7d', '30d', 'all') -notcontains $range) { $range = '7d' }
        $snap = Get-UsageSnapshot -Range $range
        $script:lastUsage = $snap
        $valTotal.Text = Format-TokenM $snap.Total
        $valIn.Text = Format-TokenM $snap.Input
        $valOut.Text = Format-TokenM $snap.Output
        $valSess.Text = ('{0} / {1}' -f $snap.Sessions, $snap.Windows)
        foreach ($key in @($script:rangeButtons.Keys)) {
            $b = $script:rangeButtons[$key]
            if ($key -eq $range) {
                $b.BackColor = $accent
                $b.ForeColor = $ink
            } else {
                $b.BackColor = $panel
                $b.ForeColor = $text
            }
        }
        Draw-UsageChart $snap
        $topList.Items.Clear()
        $script:dashTopPaths = @()
        foreach ($d in @($snap.TopDirs)) {
            $line = '{0}    {1} 会话    {2}' -f $d.Label, $d.Sessions, (Format-TokenM $d.Tokens)
            [void]$topList.Items.Add($line)
            $script:dashTopPaths += $d.Path
        }
        $n = [int]$numQuick.Value
        $quickNote.Text = ('将按最近活动打开 {0} 个目录，并继续上次会话' -f $n)
        $model = $snap.Model
        if ([string]::IsNullOrWhiteSpace($model)) { $model = '—' }
        $status.Text = ('用量来自本机 usage.json · 单位 M（百万 Token） · 模型 {0}' -f $model)
    }

    function Show-DashPage {
        $script:activePage = 'dash'
        $grid.Visible = $false
        $empty.Visible = $false
        $toolbar.Visible = $false
        $pageWatch.Visible = $false
        $topStack.Height = 78
        $pageDash.Visible = $true
        $pageDash.BringToFront()
        $title.Text = '仪表盘'
        $subtitle.Text = '用量以百万 Token 计 · 一键打开最近常用目录'
        $tabDash.ForeColor = $accent
        $tabProjects.ForeColor = $muted
        $tabWatch.ForeColor = $muted
        $form.Height = 720
        if ($script:allProjects.Count -eq 0) { Reload-Projects }
        Refresh-Dash
        Layout-Buttons
    }

    function Toggle-Pin {
        param([string]$Path)
        $kept = @()
        $found = $false
        foreach ($p in @($script:config.pins)) {
            if (Test-SamePath $p $Path) { $found = $true; continue }
            $kept += $p
        }
        if (-not $found) { $kept += $Path }
        $script:config.pins = @($kept)
        Save-LauncherConfig $script:config
    }

    $search.Add_TextChanged({ Show-Rows })

    $hideMissing.Add_CheckedChanged({
            $script:config.hideMissing = $hideMissing.Checked
            Save-LauncherConfig $script:config
            Show-Rows
        })

    $btnAbout.Add_Click({
            $msg = @(
                ('Grok 最近项目启动器  v{0}' -f $script:AppVersion)
                ''
                '只在本机读取 ~/.grok/sessions 下各会话的 summary.json'
                '（工作目录、标题、时间），用来列出项目。'
                '不会联网，不会上传会话内容、密钥或源码。'
                ''
                '置顶等偏好保存在：'
                $script:DataDir
            ) -join [Environment]::NewLine
            [System.Windows.Forms.MessageBox]::Show($msg, '关于') | Out-Null
        })

    $btnContinue.Add_Click({ Invoke-Open 'continue' })
    $btnNew.Add_Click({ Invoke-Open 'new' })
    $btnTerm.Add_Click({ Invoke-Open 'terminal' })
    $btnFolder.Add_Click({ Invoke-PickDirectoryAndNew })
    $btnRefresh.Add_Click({ Reload-Projects })
    $tabDash.Add_Click({ Show-DashPage })
    $tabProjects.Add_Click({ Show-ProjectsPage })
    $tabWatch.Add_Click({ Show-WatchPage })
    foreach ($rb in @($script:rangeButtons.Values)) {
        $rb.Add_Click({
                $script:config.usageRange = [string]$this.Tag
                Save-LauncherConfig $script:config
                Refresh-Dash
            })
    }
    $numQuick.Add_ValueChanged({
            $script:config.quickLaunchCount = [int]$numQuick.Value
            Save-LauncherConfig $script:config
            $quickNote.Text = ('将按最近活动打开 {0} 个目录，并继续上次会话' -f [int]$numQuick.Value)
        })
    $btnQuick.Add_Click({
            $n = [int]$numQuick.Value
            if ($script:allProjects.Count -eq 0) { Reload-Projects }
            $ready = @(Sort-Projects -Projects ($script:allProjects | Where-Object { $_.Exists }) -Pins $script:config.pins | Select-Object -First $n)
            if ($ready.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show('没有可以打开的目录。', '仪表盘') | Out-Null
                return
            }
            try {
                Open-GrokProjects -Projects $ready -Mode 'continue'
            } catch {
                [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '打开失败') | Out-Null
            }
        })
    $topList.Add_DoubleClick({
            $i = $topList.SelectedIndex
            if ($i -lt 0) { return }
            if ($null -eq $script:dashTopPaths -or $i -ge $script:dashTopPaths.Count) { return }
            $path = [string]$script:dashTopPaths[$i]
            $proj = New-ProjectFromPath $path
            if (-not $proj.Exists) { return }
            try { Open-GrokProjects -Projects @($proj) -Mode 'continue' } catch {
                [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '打开失败') | Out-Null
            }
        })

    $grid.Add_CellDoubleClick({
            param($sender, $e)
            if ($e.RowIndex -lt 0) { return }
            if ($grid.Columns[$e.ColumnIndex].Name -eq 'Pin') { return }
            Invoke-Open 'continue'
        })

    $grid.Add_CellClick({
            param($sender, $e)
            if ($e.RowIndex -lt 0) { return }
            if ($grid.Columns[$e.ColumnIndex].Name -ne 'Pin') { return }
            $proj = $grid.Rows[$e.RowIndex].Tag
            if (-not $proj) { return }
            Toggle-Pin $proj.Path
            Show-Rows
        })

    $grid.Add_SelectionChanged({
            $visibleCount = $grid.Rows.Count
            $status.Text = ('{0} 个项目    已选 {1}    置顶 {2}      双击续上 · Enter 打开 · Ctrl+A 全选 · Esc 关闭 · ★ 置顶' -f `
                    $visibleCount, $grid.SelectedRows.Count, @($script:config.pins).Count)
        })

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $mContinue = $menu.Items.Add('续上上次会话')
    $mNew = $menu.Items.Add('新开会话')
    $mPick = $menu.Items.Add('选择目录新开...')
    $mTerm = $menu.Items.Add('只开终端')
    $mFolder = $menu.Items.Add('打开文件夹')
    [void]$menu.Items.Add('-')
    $mCopy = $menu.Items.Add('复制路径')
    $mPin = $menu.Items.Add('置顶 / 取消置顶')
    $mContinue.Add_Click({ Invoke-Open 'continue' })
    $mNew.Add_Click({ Invoke-Open 'new' })
    $mPick.Add_Click({ Invoke-PickDirectoryAndNew })
    $mTerm.Add_Click({ Invoke-Open 'terminal' })
    $mFolder.Add_Click({ Invoke-Open 'folder' })
    $mCopy.Add_Click({
            $picked = @(Get-SelectedProjects)
            if ($picked.Count -eq 0) { return }
            $textToCopy = ($picked | ForEach-Object { $_.Path }) -join [Environment]::NewLine
            [System.Windows.Forms.Clipboard]::SetText($textToCopy)
        })
    $mPin.Add_Click({
            $picked = @(Get-SelectedProjects)
            foreach ($p in $picked) { Toggle-Pin $p.Path }
            Show-Rows
        })
    $grid.ContextMenuStrip = $menu

    $form.Add_KeyDown({
            param($sender, $e)
            if ($e.KeyCode -eq 'Escape') { $form.Close(); return }
            if ($e.KeyCode -eq 'F5') { Reload-Projects; return }
            if ($e.Control -and $e.KeyCode -eq 'F') {
                $search.Focus()
                $e.SuppressKeyPress = $true
                return
            }
            if ($search.Focused) { return }
            if ($e.KeyCode -eq 'Enter') {
                Invoke-Open 'continue'
                $e.SuppressKeyPress = $true
                return
            }
            if ($e.Control -and $e.KeyCode -eq 'A') {
                $grid.SelectAll()
                $e.SuppressKeyPress = $true
            }
        })

    $scanTimer = New-Object System.Windows.Forms.Timer
    $scanTimer.Interval = 1500
    $scanTimer.Add_Tick({
            if ($script:activePage -eq 'watch') { Sync-WatchCards }
        })
    $scanTimer.Start()
    $spinTimer = New-Object System.Windows.Forms.Timer
    $spinTimer.Interval = 90
    $spinTimer.Add_Tick({
            if ($script:activePage -ne 'watch') { return }
            $script:spinAngle = ($script:spinAngle + 24) % 360
            foreach ($info in @($script:watchCards.Values)) {
                if ($info.Kind -eq 'working') { Set-CardIcon $info.Pic 'working' }
            }
        })
    $spinTimer.Start()
    $form.Add_FormClosing({
            $scanTimer.Stop(); $spinTimer.Stop()
            foreach ($info in @($script:watchCards.Values)) {
                if ($info.Pic.Image) { $info.Pic.Image.Dispose() }
            }
        })

    $form.Add_Shown({
            try {
                $form.Activate()
                Reload-Projects
                if ($script:ScreenshotWatchMode) { Show-WatchPage }
                elseif ($script:ScreenshotDashMode) { Show-DashPage }
                elseif ($script:ScreenshotMode) { Show-ProjectsPage }
                else { Show-DashPage }
            } catch {
                try {
                    $errPath = Join-Path $script:Root 'docs\last-ui-error.txt'
                    [System.IO.File]::WriteAllText($errPath, $_.Exception.ToString())
                } catch { }
                if (-not $script:ScreenshotMode) {
                    [System.Windows.Forms.MessageBox]::Show($_.Exception.ToString(), '加载项目列表失败') | Out-Null
                }
            } finally {
                if (-not $script:ScreenshotMode) { $form.TopMost = $false }
            }

            if ($script:ScreenshotMode) {
                $form.Refresh()
                [System.Windows.Forms.Application]::DoEvents()
                $outDir = Join-Path $script:Root 'docs'
                if (-not (Test-Path -LiteralPath $outDir)) {
                    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
                }
                $name = 'screenshot.png'
                if ($script:ScreenshotWatchMode) { $name = 'watch.png' }
                elseif ($script:ScreenshotDashMode) { $name = 'dashboard.png' }
                $outPath = Join-Path $outDir $name
                $bmp = New-Object System.Drawing.Bitmap $form.ClientSize.Width, $form.ClientSize.Height
                $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle 0, 0, $form.ClientSize.Width, $form.ClientSize.Height))
                $bmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
                $bmp.Dispose()
                $form.Close()
            }
        })

    [void][System.Windows.Forms.Application]::Run($form)
} catch {
    try {
        Add-Type -AssemblyName System.Windows.Forms | Out-Null
        [System.Windows.Forms.MessageBox]::Show($_.Exception.ToString(), 'Grok 最近项目启动失败') | Out-Null
    } catch {
        throw
    }
    exit 1
}
