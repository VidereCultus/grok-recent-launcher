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

$script:AppVersion = '1.6.0'
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
$script:watchMemory = @{}
$script:watchCards = @{}
$script:activePage = 'dash'
$script:spinAngle = 0
$script:chartHover = -1
$script:lastUsage = $null
$script:chartGeom = $null
$script:recentPaths = @()
$script:dashTopPaths = @()
$script:rangeAutoPicked = $false
$script:recentRows = @()

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

function Format-PctShare {
    param($Part, $Whole)
    if ([double]$Whole -le 0) { return '0%' }
    return ('{0:N1}%' -f (100.0 * [double]$Part / [double]$Whole))
}

function Format-Wow {
    param($Current, $Previous)
    $c = [double]$Current
    $p = [double]$Previous
    if ($p -le 0) {
        if ($c -le 0) { return '' }
        return '较昨日 新出现'
    }
    $pct = 100.0 * ($c - $p) / $p
    return ('较昨日 {0:+#0;-#0}%' -f [int][Math]::Round($pct))
}

function Get-NiceCeiling {
    param($Value)
    $v = 0.0
    try { $v = [double]$Value } catch { $v = 0.0 }
    if ($v -le 0) { return 1.0 }
    $padded = $v * 1.12
    $exp = [Math]::Floor([Math]::Log10($padded))
    $base = [Math]::Pow(10, $exp)
    $n = $padded / $base
    $nice = 10.0
    foreach ($c in @(1.0, 1.2, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0)) {
        if ($n -le $c) { $nice = $c; break }
    }
    return $nice * $base
}

function Get-RangeCaption {
    param([string]$Range)
    switch ($Range) {
        'today' { return '今日总量' }
        '7d'    { return '近 7 天总量' }
        '30d'   { return '近 30 天总量' }
        default { return '累计 Token' }
    }
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
    $weights = @(0.42, 0.55, 0.38, 0.31, 0.48, 0.61, 8.63)
    $days = @()
    $total = [int64]0
    $inp = [int64]0
    $outp = [int64]0
    for ($i = 0; $i -lt 7; $i++) {
        $d = [datetime]::Today.AddDays(-6 + $i)
        $v = [int64]($weights[$i] * 1000000)
        if ($Range -eq 'today' -and $i -ne 6) { $v = [int64]0 }
        $vi = [int64]($v * 0.996)
        $vo = [int64]($v - $vi)
        $total += $v; $inp += $vi; $outp += $vo
        $days += [pscustomobject]@{ Date = $d; Total = $v; Input = $vi; Output = $vo }
    }
    if ($Range -eq 'today') { $days = @($days[-1]); $total = [int64]$days[0].Total; $inp = [int64]$days[0].Input; $outp = [int64]$days[0].Output }
    if ($Range -eq '30d') { $total = [int64]($total * 2.1); $inp = [int64]($inp * 2.1); $outp = [int64]($outp * 2.1) }
    if ($Range -eq 'all') { $total = [int64]($total * 4.8); $inp = [int64]($inp * 4.8); $outp = [int64]($outp * 4.8) }
    $top = @(
        [pscustomobject]@{ Label = 'shop-web'; Path = 'D:\Work\shop-web'; Tokens = [int64]($total * 0.44); Sessions = 12 }
        [pscustomobject]@{ Label = 'notes-app'; Path = 'D:\Work\notes-app'; Tokens = [int64]($total * 0.32); Sessions = 8 }
        [pscustomobject]@{ Label = 'wiki-site'; Path = 'D:\Work\wiki-site'; Tokens = [int64]($total * 0.14); Sessions = 5 }
        [pscustomobject]@{ Label = 'cli-tools'; Path = 'D:\Work\cli-tools'; Tokens = [int64]($total * 0.07); Sessions = 4 }
    )
    $today = $days[-1].Total
    return [pscustomobject]@{
        Range    = $Range
        Total    = $total
        Input    = $inp
        Output   = $outp
        Cached   = [int64]($total * 0.62)
        Today    = $today
        Sessions = 29
        Windows  = 4
        Days     = $days
        TopDirs  = $top
        Model    = 'grok-4.6'
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
                if (-not $dayMap.Contains($dayKey)) {
                    $dayMap[$dayKey] = @{ Total = [int64]0; Input = [int64]0; Output = [int64]0 }
                }
                $dayMap[$dayKey].Total = [int64]$dayMap[$dayKey].Total + $t
                $dayMap[$dayKey].Input = [int64]$dayMap[$dayKey].Input + $i
                $dayMap[$dayKey].Output = [int64]$dayMap[$dayKey].Output + $o
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
    $days = @()
    for ($d = $chartFrom; $d -le [datetime]::Today; $d = $d.AddDays(1)) {
        $k = $d.ToString('yyyy-MM-dd')
        $v = [int64]0; $vi = [int64]0; $vo = [int64]0
        if ($dayMap.Contains($k)) {
            $v = [int64]$dayMap[$k].Total
            $vi = [int64]$dayMap[$k].Input
            $vo = [int64]$dayMap[$k].Output
        }
        $days += [pscustomobject]@{ Date = $d; Total = $v; Input = $vi; Output = $vo }
    }
    $todayTot = [int64]0
    $todayKey = [datetime]::Today.ToString('yyyy-MM-dd')
    if ($dayMap.Contains($todayKey)) { $todayTot = [int64]$dayMap[$todayKey].Total }
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
        Today    = $todayTot
        Sessions = $sessCount
        Windows  = $win
        Days     = $days
        TopDirs  = $top
        Model    = $model
    }
}

function Get-RecentSessions {
    param([int]$Take = 8)
    if ($script:DemoMode) {
        $now = [datetimeoffset]::Now
        return @(
            [pscustomobject]@{ Title = 'Fix markdown preview scroll'; Label = 'notes-app'; Path = 'D:\Work\notes-app'; When = $now.AddMinutes(-18) }
            [pscustomobject]@{ Title = 'Empty state for the order list'; Label = 'shop-web'; Path = 'D:\Work\shop-web'; When = $now.AddHours(-2) }
            [pscustomobject]@{ Title = 'Heading anchor jump on docs'; Label = 'wiki-site'; Path = 'D:\Work\wiki-site'; When = $now.AddHours(-20) }
            [pscustomobject]@{ Title = 'Add a doctor command'; Label = 'cli-tools'; Path = 'D:\Work\cli-tools'; When = $now.AddDays(-3) }
            [pscustomobject]@{ Title = 'Dash animation timing'; Label = 'game-proto'; Path = 'D:\Work\game-proto'; When = $now.AddDays(-4) }
        )
    }
    $sessionsRoot = Join-Path $env:USERPROFILE '.grok\sessions'
    $list = @()
    if (-not (Test-Path -LiteralPath $sessionsRoot)) { return @() }
    foreach ($group in Get-ChildItem -LiteralPath $sessionsRoot -Directory -ErrorAction SilentlyContinue) {
        $cwd = Convert-SessionCwd -EncodedName $group.Name -GroupPath $group.FullName
        foreach ($sessionDir in Get-ChildItem -LiteralPath $group.FullName -Directory -ErrorAction SilentlyContinue) {
            $sumPath = Join-Path $sessionDir.FullName 'summary.json'
            if (-not (Test-Path -LiteralPath $sumPath)) { continue }
            $sum = Read-JsonFile $sumPath
            $when = $null
            if ($sum) {
                foreach ($field in @('last_active_at', 'updated_at')) {
                    if ($sum.PSObject.Properties.Name -contains $field) {
                        $when = Convert-GrokTime ([string]$sum.$field)
                        if ($when) { break }
                    }
                }
            }
            if (-not $when) { $when = [datetimeoffset](Get-Item -LiteralPath $sumPath).LastWriteTime }
            $title = $null
            if ($sum) {
                foreach ($field in @('generated_title', 'session_summary')) {
                    if ($sum.PSObject.Properties.Name -contains $field -and $sum.$field) {
                        $title = Sanitize-Title ([string]$sum.$field)
                        if ($title) { break }
                    }
                }
            }
            $leaf = if ($cwd) { Split-Path $cwd -Leaf } else { $sessionDir.Name }
            $list += [pscustomobject]@{
                Title = $(if ($title) { $title } else { $leaf })
                Label = $leaf
                Path  = $(if ($cwd) { $cwd } else { '' })
                When  = $when
            }
        }
    }
    return @($list | Sort-Object When -Descending | Select-Object -First $Take)
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
    if ($script:watchMemory -isnot [hashtable]) { $script:watchMemory = @{} }
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

    function New-TabButton {
        param([string]$Text, [int]$Width = 70)
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $Text
        $b.FlatStyle = 'Flat'
        $b.FlatAppearance.BorderSize = 0
        $b.FlatAppearance.MouseOverBackColor = $hover
        $b.BackColor = $bg
        $b.ForeColor = $muted
        $b.Width = $Width
        $b.Height = 28
        $b.Cursor = [System.Windows.Forms.Cursors]::Hand
        $b.Font = $uiFont
        $header.Controls.Add($b)
        return $b
    }
    $tabDash = New-TabButton '仪表盘' 76
    $tabProjects = New-TabButton '项目' 56
    $tabWatch = New-TabButton '监视' 56
    $btnAbout = New-TabButton '关于' 56
    $navLine = New-Object System.Windows.Forms.Panel
    $navLine.Height = 2
    $navLine.BackColor = $accent
    $header.Controls.Add($navLine)
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
    $pageDash.AutoScroll = $false
    $pageDash.Padding = New-Object System.Windows.Forms.Padding(16, 8, 16, 8)
    $pageDash.Visible = $false
    $form.Controls.Add($pageDash)

    $kpiTable = New-Object System.Windows.Forms.TableLayoutPanel
    $kpiTable.Dock = 'Top'
    $kpiTable.Height = 108
    $kpiTable.ColumnCount = 5
    $kpiTable.RowCount = 1
    $kpiTable.BackColor = $bg
    $kpiTable.Margin = New-Object System.Windows.Forms.Padding(0)
    $kpiTable.Padding = New-Object System.Windows.Forms.Padding(0)
    [void]$kpiTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 30)))
    [void]$kpiTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 16)))
    [void]$kpiTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 16)))
    [void]$kpiTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 16)))
    [void]$kpiTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 22)))
    [void]$kpiTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $pageDash.Controls.Add($kpiTable)

    $heroFont = New-Object System.Drawing.Font('Georgia', 22, [System.Drawing.FontStyle]::Bold)
    $midFont = New-Object System.Drawing.Font('Georgia', 14, [System.Drawing.FontStyle]::Bold)

    function New-KpiPanel {
        param([bool]$Hero = $false)
        $p = New-Object System.Windows.Forms.Panel
        $p.Dock = 'Fill'
        $p.BackColor = $panel
        $p.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
        $p.Padding = New-Object System.Windows.Forms.Padding(0)
        $cap = New-Object System.Windows.Forms.Label
        $cap.ForeColor = $muted
        $cap.Font = $smallFont
        $cap.AutoSize = $true
        $cap.Location = New-Object System.Drawing.Point(14, 10)
        $p.Controls.Add($cap)
        $val = New-Object System.Windows.Forms.Label
        $val.ForeColor = $(if ($Hero) { $accent } else { $text })
        $val.Font = $(if ($Hero) { $heroFont } else { $midFont })
        $val.AutoSize = $true
        $val.Location = New-Object System.Drawing.Point(12, 30)
        $p.Controls.Add($val)
        $sub = New-Object System.Windows.Forms.Label
        $sub.ForeColor = $muted
        $sub.Font = $smallFont
        $sub.AutoSize = $true
        $sub.Location = New-Object System.Drawing.Point(14, 76)
        $p.Controls.Add($sub)
        return @{ Panel = $p; Cap = $cap; Val = $val; Sub = $sub }
    }
    $kpiHero = New-KpiPanel $true
    $kpiToday = New-KpiPanel
    $kpiIn = New-KpiPanel
    $kpiOut = New-KpiPanel
    $kpiMeta = New-KpiPanel
    $kpiMeta.Panel.Margin = New-Object System.Windows.Forms.Padding(0)
    $kpiHero.Cap.Text = '近 7 天总量'
    $kpiToday.Cap.Text = '今日用量'
    $kpiIn.Cap.Text = '输入'
    $kpiOut.Cap.Text = '输出'
    $kpiMeta.Cap.Text = '规模'
    $kpiTable.Controls.Add($kpiHero.Panel, 0, 0)
    $kpiTable.Controls.Add($kpiToday.Panel, 1, 0)
    $kpiTable.Controls.Add($kpiIn.Panel, 2, 0)
    $kpiTable.Controls.Add($kpiOut.Panel, 3, 0)
    $kpiTable.Controls.Add($kpiMeta.Panel, 4, 0)

    $chartPanel = New-Object System.Windows.Forms.Panel
    $chartPanel.Dock = 'Top'
    $chartPanel.Height = 228
    $chartPanel.BackColor = $panel
    $chartPanel.Margin = New-Object System.Windows.Forms.Padding(0)
    $chartPanel.Padding = New-Object System.Windows.Forms.Padding(0)
    $pageDash.Controls.Add($chartPanel)

    $rangeHost = New-Object System.Windows.Forms.Panel
    $rangeHost.Dock = 'Top'
    $rangeHost.Height = 36
    $rangeHost.BackColor = $panel
    $chartPanel.Controls.Add($rangeHost)
    $rangeLabel = New-Object System.Windows.Forms.Label
    $rangeLabel.Text = 'Token 趋势'
    $rangeLabel.ForeColor = $muted
    $rangeLabel.Font = $smallFont
    $rangeLabel.AutoSize = $true
    $rangeLabel.Location = New-Object System.Drawing.Point(12, 10)
    $rangeHost.Controls.Add($rangeLabel)
    $chartLegend = New-Object System.Windows.Forms.Label
    $chartLegend.Text = '柱子是总量 · 悬停看输入 / 输出'
    $chartLegend.ForeColor = $muted
    $chartLegend.Font = $smallFont
    $chartLegend.AutoSize = $true
    $chartLegend.Location = New-Object System.Drawing.Point(430, 10)
    $rangeHost.Controls.Add($chartLegend)

    $script:rangeButtons = @{}
    $rx = 110
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
        $rb.FlatAppearance.BorderSize = 0
        $rb.BackColor = $panel
        $rb.ForeColor = $muted
        $rb.Width = 70
        $rb.Height = 24
        $rb.Left = $rx
        $rb.Top = 6
        $rb.Cursor = [System.Windows.Forms.Cursors]::Hand
        $rangeHost.Controls.Add($rb)
        $script:rangeButtons[$def.Key] = $rb
        $rx += 74
    }

    $chartBox = New-Object System.Windows.Forms.PictureBox
    $chartBox.Dock = 'Fill'
    $chartBox.BackColor = $panel
    $chartBox.SizeMode = 'Normal'
    $chartPanel.Controls.Add($chartBox)
    $chartBox.BringToFront()

    $split = New-Object System.Windows.Forms.TableLayoutPanel
    $split.Dock = 'Fill'
    $split.ColumnCount = 2
    $split.RowCount = 1
    $split.BackColor = $bg
    $split.Padding = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)
    [void]$split.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 56)))
    [void]$split.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 44)))
    $pageDash.Controls.Add($split)
    $rankPanel = New-Object System.Windows.Forms.Panel
    $rankPanel.Dock = 'Fill'
    $rankPanel.BackColor = $panel
    $rankPanel.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
    $rankHead = New-Object System.Windows.Forms.Label
    $rankHead.Text = '项目用量排行'
    $rankHead.Dock = 'Top'
    $rankHead.Height = 28
    $rankHead.ForeColor = $muted
    $rankHead.Font = $smallFont
    $rankHead.Padding = New-Object System.Windows.Forms.Padding(12, 8, 8, 0)
    $rankPanel.Controls.Add($rankHead)
    $rankBody = New-Object System.Windows.Forms.Panel
    $rankBody.Dock = 'Fill'
    $rankBody.BackColor = $panel
    $rankPanel.Controls.Add($rankBody)
    $rankBody.BringToFront()
    $script:rankRows = @()
    for ($ri = 0; $ri -lt 6; $ri++) {
        $row = New-Object System.Windows.Forms.Panel
        $row.Height = 36
        $row.BackColor = $panel
        $nm = New-Object System.Windows.Forms.Label
        $nm.ForeColor = $text
        $nm.Font = $smallFont
        $nm.AutoSize = $false
        $nm.SetBounds(12, 2, 160, 16)
        $row.Controls.Add($nm)
        $nums = New-Object System.Windows.Forms.Label
        $nums.ForeColor = $muted
        $nums.Font = $smallFont
        $nums.TextAlign = 'MiddleRight'
        $nums.SetBounds(180, 2, 140, 16)
        $row.Controls.Add($nums)
        $track = New-Object System.Windows.Forms.Panel
        $track.SetBounds(12, 20, 300, 6)
        $track.BackColor = [System.Drawing.Color]::FromArgb(40, 36, 30)
        $row.Controls.Add($track)
        $fill = New-Object System.Windows.Forms.Panel
        $fill.Height = 6
        $fill.Left = 0
        $fill.Top = 0
        $fill.BackColor = [System.Drawing.Color]::FromArgb(120, 108, 84)
        $track.Controls.Add($fill)
        $rankBody.Controls.Add($row)
        $script:rankRows += @{ Row = $row; Name = $nm; Nums = $nums; Track = $track; Fill = $fill; Path = '' }
    }

    $recentPanel = New-Object System.Windows.Forms.Panel
    $recentPanel.Dock = 'Fill'
    $recentPanel.BackColor = $panel
    $recentPanel.Margin = New-Object System.Windows.Forms.Padding(0)
    $recentHead = New-Object System.Windows.Forms.Panel
    $recentHead.Dock = 'Top'
    $recentHead.Height = 36
    $recentHead.BackColor = $panel
    $recentPanel.Controls.Add($recentHead)
    $recentTitle = New-Object System.Windows.Forms.Label
    $recentTitle.Text = '最近会话'
    $recentTitle.ForeColor = $muted
    $recentTitle.Font = $smallFont
    $recentTitle.AutoSize = $true
    $recentTitle.Location = New-Object System.Drawing.Point(12, 10)
    $recentHead.Controls.Add($recentTitle)
    $numQuick = New-Object System.Windows.Forms.NumericUpDown
    $numQuick.Minimum = 1
    $numQuick.Maximum = 12
    $numQuick.Value = [decimal]$script:config.quickLaunchCount
    $numQuick.Width = 44
    $numQuick.Height = 22
    $numQuick.BackColor = $bg
    $numQuick.ForeColor = $text
    $numQuick.BorderStyle = 'FixedSingle'
    $recentHead.Controls.Add($numQuick)
    $btnQuick = New-Object System.Windows.Forms.Button
    $btnQuick.FlatStyle = 'Flat'
    $btnQuick.FlatAppearance.BorderSize = 0
    $btnQuick.BackColor = $accent
    $btnQuick.ForeColor = $ink
    $btnQuick.Height = 24
    $btnQuick.Width = 148
    $btnQuick.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btnQuick.Text = ('恢复最近 {0} 个会话' -f [int]$numQuick.Value)
    $recentHead.Controls.Add($btnQuick)
    $recentBody = New-Object System.Windows.Forms.Panel
    $recentBody.Dock = 'Fill'
    $recentBody.BackColor = $panel
    $recentPanel.Controls.Add($recentBody)
    $recentBody.BringToFront()
    $script:recentRows = @()
    $hoverBg = $hover
    for ($si = 0; $si -lt 8; $si++) {
        $srow = New-Object System.Windows.Forms.Panel
        $srow.Height = 34
        $srow.BackColor = $panel
        $srow.Cursor = [System.Windows.Forms.Cursors]::Hand
        $sn = New-Object System.Windows.Forms.Label
        $sn.ForeColor = $text
        $sn.Font = $smallFont
        $sn.AutoSize = $false
        $sn.SetBounds(12, 8, 200, 18)
        $srow.Controls.Add($sn)
        $st = New-Object System.Windows.Forms.Label
        $st.ForeColor = $muted
        $st.Font = $smallFont
        $st.TextAlign = 'MiddleRight'
        $st.SetBounds(220, 8, 90, 18)
        $srow.Controls.Add($st)
        $recentBody.Controls.Add($srow)
        $script:recentRows += @{ Row = $srow; Name = $sn; Time = $st; Path = ''; Title = '' }
    }

    $split.Controls.Add($rankPanel, 0, 0)
    $split.Controls.Add($recentPanel, 1, 0)
    $pageDash.Controls.Remove($kpiTable)
    $pageDash.Controls.Remove($chartPanel)
    $pageDash.Controls.Remove($split)
    $dashRoot = New-Object System.Windows.Forms.TableLayoutPanel
    $dashRoot.Dock = 'Fill'
    $dashRoot.ColumnCount = 1
    $dashRoot.RowCount = 3
    $dashRoot.BackColor = $bg
    $dashRoot.Margin = New-Object System.Windows.Forms.Padding(0)
    $dashRoot.Padding = New-Object System.Windows.Forms.Padding(0)
    [void]$dashRoot.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$dashRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 108)))
    [void]$dashRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 228)))
    [void]$dashRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $kpiTable.Dock = 'Fill'
    $chartPanel.Dock = 'Fill'
    $split.Dock = 'Fill'
    $dashRoot.Controls.Add($kpiTable, 0, 0)
    $dashRoot.Controls.Add($chartPanel, 0, 1)
    $dashRoot.Controls.Add($split, 0, 2)
    $pageDash.Controls.Add($dashRoot)

    function Set-Nav {
        param([string]$Page)
        $tabDash.ForeColor = $muted
        $tabProjects.ForeColor = $muted
        $tabWatch.ForeColor = $muted
        $btnAbout.ForeColor = $muted
        $active = $tabDash
        switch ($Page) {
            'projects' { $active = $tabProjects }
            'watch' { $active = $tabWatch }
            default { $active = $tabDash }
        }
        $active.ForeColor = $accent
        $navLine.Width = $active.Width - 12
        $navLine.Left = $active.Left + 6
        $navLine.Top = $header.Height - 4
        $navLine.BringToFront()
    }

    function Layout-Dash {
        if (-not $pageDash.Visible) { return }
        if (-not $form.IsHandleCreated) { return }
        $n = [int]$numQuick.Value
        $btnQuick.Text = ('恢复最近 {0} 个会话' -f $n)
        $btnQuick.Width = 148
        $btnQuick.Left = [Math]::Max(160, $recentHead.ClientSize.Width - 162)
        $btnQuick.Top = 6
        $numQuick.Left = $btnQuick.Left - 50
        $numQuick.Top = 7
        $bw = [Math]::Max(80, $rankBody.ClientSize.Width)
        $rowH = 36
        for ($i = 0; $i -lt $script:rankRows.Count; $i++) {
            $r = $script:rankRows[$i]
            $r.Row.SetBounds(0, $i * $rowH, $bw, $rowH)
            $r.Name.Width = [Math]::Max(70, $bw - 168)
            $r.Nums.Left = $bw - 156
            $r.Nums.Width = 144
            $r.Track.Width = [Math]::Max(40, $bw - 24)
            $pct = 0
            if ($r.Contains('Pct')) { $pct = [double]$r.Pct }
            $r.Fill.Width = [int]($r.Track.Width * $pct / 100.0)
        }
        $rw = [Math]::Max(80, $recentBody.ClientSize.Width)
        for ($i = 0; $i -lt $script:recentRows.Count; $i++) {
            $r = $script:recentRows[$i]
            $r.Row.SetBounds(0, $i * 34, $rw, 34)
            $r.Name.SetBounds(12, 8, [Math]::Max(60, $rw - 120), 18)
            $r.Time.SetBounds($rw - 108, 8, 96, 18)
        }
        $rangeLabel.Left = 12
        $keys = @('today', '7d', '30d', 'all')
        $x = $rangeHost.ClientSize.Width - 8
        for ($i = $keys.Count - 1; $i -ge 0; $i--) {
            $b = $script:rangeButtons[$keys[$i]]
            $x -= $b.Width
            $b.Left = $x
            $x -= 4
        }
        $chartLegend.Left = $rangeLabel.Right + 16
    }

    function Layout-Buttons {
        if (-not $form.IsHandleCreated) { return }
        $btnAbout.Left = $header.ClientSize.Width - 70
        $btnAbout.Top = 22
        $tabWatch.Left = $btnAbout.Left - 60
        $tabWatch.Top = 22
        $tabProjects.Left = $tabWatch.Left - 60
        $tabProjects.Top = 22
        $tabDash.Left = $tabProjects.Left - 80
        $tabDash.Top = 22
        Set-Nav $script:activePage
        Layout-Dash
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
        $pageDash.Visible = $false
        Set-Nav 'projects'
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
        Set-Nav 'watch'
        $form.Height = [Math]::Max($form.Height, 560)
        Sync-WatchCards
        Layout-Buttons
    }

    function Draw-UsageChart {
        param($Snap)
        $w = [Math]::Max(220, $chartBox.ClientSize.Width)
        $h = [Math]::Max(100, $chartBox.ClientSize.Height)
        if ($w -lt 40 -or $h -lt 40) { return }
        $bmp = New-Object System.Drawing.Bitmap $w, $h
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = 'AntiAlias'
        $g.Clear($panel)
        $days = @($Snap.Days)
        $mutedBr = New-Object System.Drawing.SolidBrush $muted
        $barBr = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(120, 108, 84))
        $peakBr = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(168, 148, 108))
        $gridPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(48, 44, 38))
        $padL = 48; $padB = 24; $padT = 10; $padR = 16
        $plotW = $w - $padL - $padR
        $plotH = $h - $padT - $padB
        if ($days.Count -eq 0) {
            $g.DrawString('这段时间没有 usage.json 记录', $smallFont, $mutedBr, 20, 60)
        } else {
            $rawMax = ($days | Measure-Object -Property Total -Maximum).Maximum
            if ($rawMax -le 0) { $rawMax = 1 }
            $max = Get-NiceCeiling $rawMax
            $n = $days.Count
            $slot = $plotW / [double]$n
            $bw = [Math]::Max(10, [int]($slot - 10))
            $script:chartGeom = @{ PadL = $padL; Slot = $slot; N = $n; Days = $days }
            foreach ($tick in @(0.0, 0.5, 1.0)) {
                $ty = $padT + $plotH - [int]($plotH * $tick)
                $g.DrawLine($gridPen, $padL, $ty, $w - $padR, $ty)
                $lab = Format-TokenM ($max * $tick)
                $g.DrawString($lab, $smallFont, $mutedBr, 2, $ty - 8)
            }
            $peakI = 0; $peakV = [int64]0
            for ($i = 0; $i -lt $n; $i++) {
                if ([int64]$days[$i].Total -ge $peakV) { $peakV = [int64]$days[$i].Total; $peakI = $i }
            }
            for ($i = 0; $i -lt $n; $i++) {
                $day = $days[$i]
                $x = $padL + [int]($i * $slot) + 4
                $bh = [int]($plotH * ([double]$day.Total / $max))
                if ($bh -lt 2 -and $day.Total -gt 0) { $bh = 2 }
                $y = $padT + $plotH - $bh
                $useBr = $(if ($i -eq $peakI) { $peakBr } else { $barBr })
                $g.FillRectangle($useBr, $x, $y, $bw, $bh)
                $g.DrawString($day.Date.ToString('M/d'), $smallFont, $mutedBr, $x, $h - 20)
            }
            $hi = $script:chartHover
            if ($hi -ge 0 -and $hi -lt $n) {
                $day = $days[$hi]
                $prev = [int64]0
                if ($hi -gt 0) { $prev = [int64]$days[$hi - 1].Total }
                $wow = Format-Wow $day.Total $prev
                $boxW = 228; $boxH = 86
                $bx = [Math]::Min($w - $boxW - 8, $padL + [int]($hi * $slot) + 20)
                $by = 8
                $bgb = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(18, 17, 15))
                $g.FillRectangle($bgb, $bx, $by, $boxW, $boxH)
                $bgb.Dispose()
                $pen = New-Object System.Drawing.Pen $line
                $g.DrawRectangle($pen, $bx, $by, $boxW, $boxH)
                $pen.Dispose()
                $txtBr = New-Object System.Drawing.SolidBrush $text
                $line1 = $day.Date.ToString('M 月 d 日')
                $line2 = ('总量 {0}' -f (Format-TokenM $day.Total))
                $line3 = ('输入 {0} · {1}' -f (Format-TokenM $day.Input), (Format-PctShare $day.Input $day.Total))
                $line4 = ('输出 {0} · {1}' -f (Format-TokenM $day.Output), (Format-PctShare $day.Output $day.Total))
                $g.DrawString($line1, $smallFont, $txtBr, $bx + 8, $by + 4)
                $g.DrawString($line2, $smallFont, $txtBr, $bx + 8, $by + 22)
                $g.DrawString($line3, $smallFont, $mutedBr, $bx + 8, $by + 40)
                $g.DrawString($(if ($wow) { $line4 + '    ' + $wow } else { $line4 }), $smallFont, $mutedBr, $bx + 8, $by + 58)
                $txtBr.Dispose()
            }
        }
        $barBr.Dispose(); $peakBr.Dispose(); $mutedBr.Dispose(); $gridPen.Dispose(); $g.Dispose()
        $old = $chartBox.Image
        $chartBox.Image = $bmp
        if ($old) { $old.Dispose() }
    }

    function Refresh-Dash {
        try {
        $range = $script:config.usageRange
        if (@('today', '7d', '30d', 'all') -notcontains $range) { $range = '7d' }
        if (-not $script:rangeAutoPicked) {
            $probe = Get-UsageSnapshot -Range '7d'
            $nonzero = @($probe.Days | Where-Object { $_.Total -gt 0 }).Count
            if ($nonzero -lt 2) { $range = 'today' }
            elseif ($nonzero -ge 7) { $range = '7d' }
            $script:config.usageRange = $range
            $script:rangeAutoPicked = $true
        }
        $snap = Get-UsageSnapshot -Range $range
        $script:lastUsage = $snap
        $kpiHero.Cap.Text = Get-RangeCaption $range
        $kpiHero.Val.Text = Format-TokenM $snap.Total
        $kpiHero.Sub.Text = ''
        $kpiToday.Val.Text = Format-TokenM $snap.Today
        $kpiToday.Sub.Text = $(if ($snap.Today -gt 0) { '今天仍在进行' } else { '今天还没有用量' })
        $kpiIn.Val.Text = Format-TokenM $snap.Input
        $kpiIn.Sub.Text = Format-PctShare $snap.Input $snap.Total
        $kpiOut.Val.Text = Format-TokenM $snap.Output
        $kpiOut.Sub.Text = Format-PctShare $snap.Output $snap.Total
        $kpiMeta.Val.Text = ('{0}' -f $snap.Sessions)
        $kpiMeta.Sub.Text = ('{0} 个会话 · 分布于 {1} 个窗口' -f $snap.Sessions, $snap.Windows)
        $kpiMeta.Cap.Text = '会话'
        foreach ($key in @($script:rangeButtons.Keys)) {
            $b = $script:rangeButtons[$key]
            if ($key -eq $range) { $b.ForeColor = $accent } else { $b.ForeColor = $muted }
            $b.BackColor = $panel
        }
        Draw-UsageChart $snap
        $maxTok = 1.0
        if ($snap.TopDirs.Count -gt 0) { $maxTok = [Math]::Max(1.0, [double]$snap.TopDirs[0].Tokens) }
        for ($i = 0; $i -lt $script:rankRows.Count; $i++) {
            $r = $script:rankRows[$i]
            if ($i -lt @($snap.TopDirs).Count) {
                $d = @($snap.TopDirs)[$i]
                $pct = 100.0 * [double]$d.Tokens / [double]$snap.Total
                if ($snap.Total -le 0) { $pct = 0 }
                $barPct = 100.0 * [double]$d.Tokens / $maxTok
                $r.Row.Visible = $true
                $r.Name.Text = ('{0:d2}  {1}' -f ($i + 1), $d.Label)
                $r.Nums.Text = ('{0}  {1}' -f (Format-TokenM $d.Tokens), (Format-PctShare $d.Tokens $snap.Total))
                $r.Pct = $barPct
                $r.Path = $d.Path
                $r.Fill.BackColor = $(if ($i -eq 0) { [System.Drawing.Color]::FromArgb(148, 132, 100) } else { [System.Drawing.Color]::FromArgb(108, 98, 80) })
            } else {
                $r.Row.Visible = $false
                $r.Path = ''
                $r.Pct = 0
            }
        }
        $sessions = @(Get-RecentSessions -Take 8)
        $script:recentPaths = @()
        for ($i = 0; $i -lt $script:recentRows.Count; $i++) {
            $r = $script:recentRows[$i]
            if ($i -lt $sessions.Count) {
                $s = $sessions[$i]
                $r.Row.Visible = $true
                $r.Name.Text = $(if ($s.Label) { $s.Label } else { $s.Title })
                $r.Time.Text = Format-Ago $s.When
                $r.Path = $s.Path
                $script:recentPaths += $s.Path
            } else {
                $r.Row.Visible = $false
                $r.Path = ''
            }
        }
        $btnQuick.Text = ('恢复最近 {0} 个会话' -f [int]$numQuick.Value)
        Layout-Dash
        $model = $snap.Model
        if ([string]::IsNullOrWhiteSpace($model)) { $model = '—' }
        $status.Text = ('用量来自本机 usage.json · 单位 M · {0}' -f $model)
        } catch {
            $errPath = Join-Path $script:Root 'docs\last-ui-error.txt'
            try { [System.IO.File]::WriteAllText($errPath, $_.Exception.ToString()) } catch { }
            throw
        }
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
        $title.Text = '用量'
        $subtitle.Text = '先看总量，再看哪天暴增，再看哪个项目吃掉最多'
        Set-Nav 'dash'
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
            $btnQuick.Text = ('恢复最近 {0} 个会话' -f [int]$numQuick.Value)
            Layout-Dash
        })
    $btnQuick.Add_Click({
            $n = [int]$numQuick.Value
            if ($script:allProjects.Count -eq 0) { Reload-Projects }
            $sess = @(Get-RecentSessions -Take 24)
            $ready = @()
            $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($s in $sess) {
                if ([string]::IsNullOrWhiteSpace($s.Path)) { continue }
                if ($seen.Contains($s.Path)) { continue }
                [void]$seen.Add($s.Path)
                $proj = New-ProjectFromPath $s.Path
                if ($proj.Exists) { $ready += $proj }
                if ($ready.Count -ge $n) { break }
            }
            if ($ready.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show('没有可以打开的最近项目。', '用量') | Out-Null
                return
            }
            try {
                Open-GrokProjects -Projects $ready -Mode 'continue'
            } catch {
                [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '打开失败') | Out-Null
            }
        })
    foreach ($rr in $script:recentRows) {
        $rr.Row.Add_MouseEnter({ $this.BackColor = $hover })
        $rr.Row.Add_MouseLeave({ $this.BackColor = $panel })
        $rr.Name.Add_MouseEnter({ $this.Parent.BackColor = $hover })
        $rr.Name.Add_MouseLeave({ $this.Parent.BackColor = $panel })
        $rr.Time.Add_MouseEnter({ $this.Parent.BackColor = $hover })
        $rr.Time.Add_MouseLeave({ $this.Parent.BackColor = $panel })
        $handler = {
            $hit = $null
            foreach ($cand in $script:recentRows) {
                if ([object]::ReferenceEquals($cand.Row, $this) -or [object]::ReferenceEquals($cand.Row, $this.Parent)) { $hit = $cand; break }
            }
            if (-not $hit -or [string]::IsNullOrWhiteSpace($hit.Path)) { return }
            $proj = New-ProjectFromPath $hit.Path
            if (-not $proj.Exists) { return }
            try { Open-GrokProjects -Projects @($proj) -Mode 'continue' } catch {
                [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '打开失败') | Out-Null
            }
        }
        $rr.Row.Add_Click($handler)
        $rr.Name.Add_Click($handler)
        $rr.Time.Add_Click($handler)
    }
    $script:chartHover = -1
    $chartBox.Add_MouseMove({
            param($sender, $e)
            $ginfo = $script:chartGeom
            if (-not $ginfo) { return }
            $idx = [int][Math]::Floor(($e.X - [double]$ginfo.PadL) / [double]$ginfo.Slot)
            if ($idx -lt 0 -or $idx -ge [int]$ginfo.N) { $idx = -1 }
            if ($idx -ne $script:chartHover) {
                $script:chartHover = $idx
                if ($script:lastUsage) { Draw-UsageChart $script:lastUsage }
            }
        })
    $chartBox.Add_MouseLeave({
            $script:chartHover = -1
            if ($script:lastUsage) { Draw-UsageChart $script:lastUsage }
        })
    foreach ($rr in $script:rankRows) {
        $rr.Row.Cursor = [System.Windows.Forms.Cursors]::Hand
        $rr.Row.Add_Click({
                $hit = $null
                foreach ($cand in $script:rankRows) {
                    if ([object]::ReferenceEquals($cand.Row, $this)) { $hit = $cand; break }
                }
                if (-not $hit -or [string]::IsNullOrWhiteSpace($hit.Path)) { return }
                $proj = New-ProjectFromPath $hit.Path
                if (-not $proj.Exists) { return }
                try { Open-GrokProjects -Projects @($proj) -Mode 'continue' } catch {
                    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '打开失败') | Out-Null
                }
            })
    }

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
