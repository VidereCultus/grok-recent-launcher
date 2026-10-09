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
    [switch]$LayoutCheck,
    [switch]$WatchList,
    [int]$Limit = 50
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AppVersion = '1.9.27'
$script:LastProxyAutoSwitch = $null
if ($Version) {
    Write-Output $script:AppVersion
    exit 0
}

# Screenshot always uses fictional rows so real project paths never land in docs/.
$script:DemoMode = [bool]($Demo -or $Screenshot -or $ScreenshotWatch -or $ScreenshotDash -or $LayoutCheck)
$script:ScreenshotMode = [bool]($Screenshot -or $ScreenshotWatch -or $ScreenshotDash)
$script:ScreenshotWatchMode = [bool]$ScreenshotWatch
$script:ScreenshotDashMode = [bool]$ScreenshotDash
$script:LayoutCheckMode = [bool]$LayoutCheck
$script:layoutCheckFailed = $false

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:DataDir = Join-Path $env:APPDATA 'GrokRecentLauncher'
if (-not (Test-Path -LiteralPath $script:DataDir)) {
    New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
}
$script:ConfigPath = Join-Path $script:DataDir 'config.json'
$script:ErrorLog = Join-Path $script:DataDir 'last-error.log'
$script:QuotaCachePath = Join-Path $script:DataDir 'quota-cache.json'
$script:quotaJob = $null
$script:quotaBusy = $false
$script:quotaView = $null
$script:quotaPs = $null
$script:quotaHandle = $null
$script:quotaRunspace = $null
$script:quotaEmail = ''
$script:restartRequested = $false
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
$script:watchExpanded = @{}
$script:watchKick = $null
$script:activityCache = @{}

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

function ConvertTo-GrokProxyEndpoint {
    param([string]$Raw)
    $text = ([string]$Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        $text = 'http://127.0.0.1:7890'
    }
    $scheme = 'http'
    if ($text -match '^(?<scheme>https?|socks5h?|socks4a?)://(?<rest>.*)$') {
        $scheme = $Matches.scheme.ToLowerInvariant()
        if ($scheme -eq 'https') { $scheme = 'http' }
        $text = [string]$Matches.rest
    }
    $text = $text.Split([char[]]@('/', '?'))[0]
    $hostName = '127.0.0.1'
    $port = 7890
    if ($text -match '^\[(?<h>[^\]]+)\]:(?<p>\d+)$') {
        $hostName = [string]$Matches.h
        $port = [int]$Matches.p
    } elseif ($text -match '^(?<h>[^:]+):(?<p>\d+)$') {
        $hostName = [string]$Matches.h
        $port = [int]$Matches.p
    } elseif ($text -match '^\d+$') {
        $port = [int]$text
    } elseif (-not [string]::IsNullOrWhiteSpace($text)) {
        $hostName = $text
    }
    if ($port -lt 1 -or $port -gt 65535) {
        throw '代理端口无效，请填写 1 到 65535 之间的数字。'
    }
    if ($hostName -match '[;\s"]') {
        throw '代理地址不能包含空格、引号或分号。'
    }
    $url = '{0}://{1}:{2}' -f $scheme, $hostName, $port
    return [pscustomobject]@{
        Host    = $hostName
        Port    = $port
        Url     = $url
        Scheme  = $scheme
        Display = ('{0}:{1}' -f $hostName, $port)
    }
}

function Get-LauncherConfigObject {
    $var = Get-Variable -Name config -Scope Script -ErrorAction SilentlyContinue
    if ($var -and $null -ne $var.Value) { return $var.Value }
    return $null
}

function Get-GrokProxyEndpoint {
    $raw = 'http://127.0.0.1:7890'
    $cfg = Get-LauncherConfigObject
    if ($cfg -and $cfg.PSObject.Properties.Name -contains 'proxyUrl' -and $cfg.proxyUrl) {
        $raw = [string]$cfg.proxyUrl
    }
    try {
        return (ConvertTo-GrokProxyEndpoint $raw)
    } catch {
        return (ConvertTo-GrokProxyEndpoint 'http://127.0.0.1:7890')
    }
}

function ConvertFrom-SystemProxyServer {
    param([string]$Server)
    $s = ([string]$Server).Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    if ($s -match '(?:https?=)?(?<h>127\.0\.0\.1|localhost):(?<p>\d+)') {
        return (ConvertTo-GrokProxyEndpoint ('http://{0}:{1}' -f $Matches.h, $Matches.p))
    }
    try { return (ConvertTo-GrokProxyEndpoint $s) } catch { return $null }
}

function Get-SystemProxyEndpoint {
    $reg = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if (-not $reg -or [int]$reg.ProxyEnable -ne 1) { return $null }
    return (ConvertFrom-SystemProxyServer ([string]$reg.ProxyServer))
}

function ConvertFrom-ClashMixedPortText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    foreach ($line in ($Text -split '\r?\n')) {
        if ($line -match '^\s*mixed-port:\s*(?<p>\d+)') {
            $port = [int]$Matches.p
            if ($port -ge 1 -and $port -le 65535) {
                return (ConvertTo-GrokProxyEndpoint ('http://127.0.0.1:{0}' -f $port))
            }
        }
    }
    return $null
}

function Get-FlClashMixedPortEndpoint {
    $cfg = Join-Path $env:APPDATA 'com.follow\clash\config.yaml'
    if (-not (Test-Path -LiteralPath $cfg)) { return $null }
    try {
        $lines = Get-Content -LiteralPath $cfg -TotalCount 40 -ErrorAction Stop
        return (ConvertFrom-ClashMixedPortText ($lines -join "`n"))
    } catch {
        return $null
    }
}

function Find-GrokProxyCandidates {
    $seen = @{}
    $rows = New-Object System.Collections.Generic.List[object]
    $add = {
        param($ep, $src, $rank)
        if (-not $ep) { return }
        $key = [string]$ep.Url
        if ($seen.ContainsKey($key)) { return }
        if (-not (Test-GrokProxyPort -HostName $ep.Host -Port $ep.Port -TimeoutMs 280)) { return }
        $seen[$key] = $true
        $rows.Add([pscustomobject]@{
                Endpoint = $ep
                Source   = $src
                Rank     = [int]$rank
            })
    }
    & $add (Get-SystemProxyEndpoint) '系统代理' 1
    & $add (Get-FlClashMixedPortEndpoint) 'FlClash' 2
    foreach ($port in @(7890, 7891, 7897, 10808, 10809, 1080, 20171, 20170, 6152, 8888, 2080, 7892, 1087)) {
        & $add (ConvertTo-GrokProxyEndpoint ('http://127.0.0.1:{0}' -f $port)) ('本机 ' + $port) 10
    }
    return @($rows | Sort-Object Rank, { $_.Endpoint.Port })
}

function Find-BestGrokProxyCandidate {
    $all = @(Find-GrokProxyCandidates)
    if ($all.Count -eq 0) { return $null }
    return $all[0]
}

function Get-GrokProxyEnabled {
    $cfg = Get-LauncherConfigObject
    if ($cfg -and $cfg.PSObject.Properties.Name -contains 'proxyGrokSessions') {
        return [bool]$cfg.proxyGrokSessions
    }
    return $true
}

function Get-GrokProxyWrapperPath {
    if ($script:Root) {
        $wrapper = Join-Path $script:Root 'grok-with-proxy.cmd'
        if (Test-Path -LiteralPath $wrapper) { return $wrapper }
    }
    $homeWrapper = Join-Path $env:USERPROFILE '.grok\bin\grok-with-proxy.cmd'
    if (Test-Path -LiteralPath $homeWrapper) { return $homeWrapper }
    return $null
}

function Test-GrokProxyPort {
    param(
        [string]$HostName = '127.0.0.1',
        [int]$Port = 7890,
        [int]$TimeoutMs = 800
    )
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            return $false
        }
        $client.EndConnect($iar)
        return [bool]$client.Connected
    } catch {
        return $false
    } finally {
        if ($client) { try { $client.Close() } catch { } }
    }
}

function Assert-GrokProxyReady {
    param(
        [string]$HostName,
        [int]$Port = 0
    )
    $script:LastProxyAutoSwitch = $null
    if (-not (Get-GrokProxyEnabled)) { return }
    $ep = Get-GrokProxyEndpoint
    $overridden = -not [string]::IsNullOrWhiteSpace($HostName) -or $Port -gt 0
    if ($HostName) { $ep.Host = $HostName }
    if ($Port -gt 0) { $ep.Port = $Port }
    $ep.Display = '{0}:{1}' -f $ep.Host, $ep.Port
    $exe = Get-GrokExe
    if (-not $exe -or -not (Test-Path -LiteralPath $exe)) {
        throw '找不到 grok.exe。确认已安装 Grok CLI，并且 ~/.grok/bin 在 PATH 里。'
    }
    if (Test-GrokProxyPort -HostName $ep.Host -Port $ep.Port) { return }
    if (-not $overridden) {
        $best = Find-BestGrokProxyCandidate
        if ($best) {
            $cfg = Get-LauncherConfigObject
            if ($cfg) {
                $cfg.proxyUrl = [string]$best.Endpoint.Url
                Save-LauncherConfig $cfg
            }
            $script:LastProxyAutoSwitch = ('原来的 {0} 连不上，已改成 {1}（{2}）再启动。已开着的旧窗口还是旧地址，需要关掉后从启动器重开。' -f $ep.Display, $best.Endpoint.Url, $best.Source)
            return
        }
    }
    throw ('已开启走代理，但 {0} 没有响应，也没有检测到其它可用的本机代理。请先打开 FlClash，或点「检测」。若要直连启动，先关掉「启动会话走代理」。' -f $ep.Display)
}

function Get-GrokLaunchCommand {
    return (Get-GrokExe)
}

function Build-GrokProxyInnerCommand {
    param(
        [Parameter(Mandatory)][string]$GrokExe,
        [Parameter(Mandatory)][string]$Cwd,
        [switch]$Continue
    )
    $ep = Get-GrokProxyEndpoint
    $exe = $GrokExe.Trim().Trim('"')
    $dir = $Cwd.Trim().Trim('"').Replace('"', '')
    $grokArgs = '--cwd "' + $dir + '"'
    if ($Continue) { $grokArgs += ' -c' }
    # WT treats ";" as a new tab command. Use && only.
    return ('set HTTP_PROXY={0}&&set HTTPS_PROXY={0}&&set ALL_PROXY={0}&&set NO_PROXY=localhost,127.0.0.1&&"{1}" {2}' -f $ep.Url, $exe, $grokArgs)
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
            pins              = @('D:\Work\shop-web')
            hideMissing       = $true
            quickLaunchCount  = 5
            usageRange        = '7d'
            proxyGrokSessions = $true
            proxyUrl          = 'http://127.0.0.1:7890'
            theme             = 'light'
            closeToTray       = ''
        }
    }
    $cfg = [pscustomobject]@{
        pins              = @()
        hideMissing       = $true
        quickLaunchCount  = 5
        usageRange        = '7d'
        proxyGrokSessions = $true
        proxyUrl          = 'http://127.0.0.1:7890'
        theme             = 'light'
        closeToTray       = ''
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
    if ($json.PSObject.Properties.Name -contains 'proxyGrokSessions') {
        $cfg.proxyGrokSessions = [bool]$json.proxyGrokSessions
    }
    if ($json.PSObject.Properties.Name -contains 'proxyUrl' -and $json.proxyUrl) {
        try { $cfg.proxyUrl = [string](ConvertTo-GrokProxyEndpoint ([string]$json.proxyUrl)).Url } catch { }
    }
    if ($json.PSObject.Properties.Name -contains 'theme' -and $json.theme) {
        $themeName = [string]$json.theme
        if ($themeName -eq 'dark' -or $themeName -eq 'light') { $cfg.theme = $themeName }
    }
    if ($json.PSObject.Properties.Name -contains 'closeToTray' -and $json.closeToTray) {
        $closeMode = [string]$json.closeToTray
        if ($closeMode -eq 'tray' -or $closeMode -eq 'quit') { $cfg.closeToTray = $closeMode }
    }
    return $cfg
}

function Save-LauncherConfig {
    param($Config)
    if ($script:DemoMode) { return }
    $payload = @{
        pins             = @($Config.pins)
        hideMissing       = [bool]$Config.hideMissing
        quickLaunchCount  = [int]$Config.quickLaunchCount
        usageRange        = [string]$Config.usageRange
        proxyGrokSessions = [bool]$Config.proxyGrokSessions
        proxyUrl          = [string](ConvertTo-GrokProxyEndpoint ([string]$Config.proxyUrl)).Url
        theme             = $(if ($Config.PSObject.Properties.Name -contains 'theme' -and $Config.theme) { [string]$Config.theme } else { 'light' })
        closeToTray       = $(if ($Config.PSObject.Properties.Name -contains 'closeToTray' -and $Config.closeToTray) { [string]$Config.closeToTray } else { '' })
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
            Title = 'Empty state for the order list'; Progress = 62; AgeText = '已运行 4 分钟'; LastAgo = '刚刚'; Detail = '正在改订单空状态'
            CurrentTool = 'search_replace'; RecentTools = @('read_file · success','grep · success','run_terminal_command · success'); TokenM = '1.24 M'; Model = 'grok-4.6'; ToolCount = 18; TurnCount = 4; SessionId = 'demo-4101'; TaskLine = '正在执行 search_replace'
        }
        [pscustomobject]@{
            Pid = 4102; Label = 'notes-app'; Path = 'D:\Work\notes-app'; Kind = 'created'
            Title = 'Fix markdown preview scroll'; Progress = 8; AgeText = '已运行 12 秒'; LastAgo = '刚刚'; Detail = '新窗口'
            CurrentTool = $null; RecentTools = @(); TokenM = '0.02 M'; Model = 'grok-4.6'; ToolCount = 0; TurnCount = 1; SessionId = 'demo-4102'; TaskLine = '新窗口，等待第一条指令'
        }
        [pscustomobject]@{
            Pid = 4103; Label = 'wiki-site'; Path = 'D:\Work\wiki-site'; Kind = 'idle'
            Title = 'Heading anchor jump on docs'; Progress = 44; AgeText = '已运行 18 分钟'; LastAgo = '3 分钟前'; Detail = '这一轮已经写完'
            CurrentTool = $null; RecentTools = @('write · success','search_replace · success'); TokenM = '0.86 M'; Model = 'grok-4.6'; ToolCount = 11; TurnCount = 3; SessionId = 'demo-4103'; TaskLine = '上一轮：这一轮已经写完'
        }
        [pscustomobject]@{
            Pid = 4104; Label = 'cli-tools'; Path = 'D:\Work\cli-tools'; Kind = 'idle'
            Title = 'Add a doctor command'; Progress = 21; AgeText = '已运行 1 小时'; LastAgo = '20 分钟前'; Detail = '停在提示符'
            CurrentTool = $null; RecentTools = @('read_file · success'); TokenM = '0.41 M'; Model = 'grok-4.6'; ToolCount = 4; TurnCount = 2; SessionId = 'demo-4104'; TaskLine = '停在提示符，等你说话'
        }
    )
}

function Format-TokenM {
    param($Tokens)
    $n = 0.0
    try { $n = [double]$Tokens } catch { $n = 0.0 }
    if ([Math]::Abs($n) -ge 1000000000.0) { return ('{0:N2} B' -f ($n / 1000000000.0)) }
    return ('{0:N2} M' -f ($n / 1000000.0))
}

function Format-TokenShort {
    param($Tokens)
    $n = 0.0
    try { $n = [double]$Tokens } catch { $n = 0.0 }
    if ([Math]::Abs($n) -ge 1000000000.0) { return ('{0:N2}B' -f ($n / 1000000000.0)) }
    if ([Math]::Abs($n) -ge 1000000.0) { return ('{0:N1}M' -f ($n / 1000000.0)) }
    if ([Math]::Abs($n) -ge 1000.0) { return ('{0:N1}K' -f ($n / 1000.0)) }
    return ('{0:N0}' -f $n)
}

function Convert-UsdTicks {
    param($Ticks)
    if ($null -eq $Ticks) { return $null }
    try { return [double]$Ticks / 10000000000.0 } catch { return $null }
}

function Get-UsageCounts {
    param($Obj)
    $zero = [pscustomobject]@{
        Total    = [int64]0
        Input    = [int64]0
        Output   = [int64]0
        Cached   = [int64]0
        Billable = [int64]0
        UsdTicks = [int64]0
    }
    if (-not $Obj) { return $zero }
    $t = [int64]0; $i = [int64]0; $o = [int64]0; $c = [int64]0; $k = [int64]0
    try {
        $v = Get-PsProp $Obj 'totalTokens'
        if ($null -ne $v) { $t = [int64]$v }
    } catch { }
    try {
        $v = Get-PsProp $Obj 'inputTokens'
        if ($null -ne $v) { $i = [int64]$v }
    } catch { }
    try {
        $v = Get-PsProp $Obj 'outputTokens'
        if ($null -ne $v) { $o = [int64]$v }
    } catch { }
    try {
        $v = Get-PsProp $Obj 'cachedReadTokens'
        if ($null -ne $v) { $c = [int64]$v }
    } catch { }
    try {
        $v = Get-PsProp $Obj 'costUsdTicks'
        if ($null -ne $v) { $k = [int64]$v }
    } catch { }
    $b = $t - $c
    if ($b -lt 0) { $b = [int64]0 }
    if ($b -eq 0 -and $t -gt 0) { $b = $t }
    return [pscustomobject]@{
        Total    = $t
        Input    = $i
        Output   = $o
        Cached   = $c
        Billable = [int64]$b
        UsdTicks = $k
    }
}

function Format-Usd {
    param($N)
    if ($null -eq $N) { return '' }
    $v = 0.0
    try { $v = [double]$N } catch { return '' }
    if ($v -lt 0) { $v = 0 }
    if ($v -lt 10) { return ('${0:N2}' -f $v) }
    return ('${0:N1}' -f $v)
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

function New-ThemeColor {
    param([int]$R, [int]$G, [int]$B)
    return [System.Drawing.Color]::FromArgb($R, $G, $B)
}

function Get-LauncherPalette {
    param([string]$Name = 'light')
    $dark = ($Name -eq 'dark')
    if ($dark) {
        return @{
            Name        = 'dark'
            Bg          = (New-ThemeColor 28 25 22)
            Panel       = (New-ThemeColor 40 36 31)
            Toolbar     = (New-ThemeColor 34 30 26)
            Line        = (New-ThemeColor 68 60 52)
            Text        = (New-ThemeColor 244 238 228)
            Muted       = (New-ThemeColor 168 156 140)
            Accent      = (New-ThemeColor 224 168 92)
            AccentHover = (New-ThemeColor 236 190 122)
            AccentPress = (New-ThemeColor 184 128 58)
            Ink         = (New-ThemeColor 28 25 22)
            Select      = (New-ThemeColor 68 56 40)
            Hover       = (New-ThemeColor 54 48 40)
            Danger      = (New-ThemeColor 212 112 96)
            Working     = (New-ThemeColor 138 154 91)
            Created     = (New-ThemeColor 224 168 92)
            Idle        = (New-ThemeColor 140 130 118)
            PanelPress  = (New-ThemeColor 24 21 18)
            ChartBar    = (New-ThemeColor 120 98 70)
            ChartGrid   = (New-ThemeColor 68 60 52)
            Tip         = (New-ThemeColor 48 42 36)
            Alt         = (New-ThemeColor 34 30 26)
            Track       = (New-ThemeColor 58 52 44)
            Olive       = (New-ThemeColor 138 154 91)
            Copper      = (New-ThemeColor 196 149 106)
            Stone       = (New-ThemeColor 140 130 118)
            Deep        = (New-ThemeColor 180 120 40)
        }
    }
    return @{
        Name        = 'light'
        Bg          = (New-ThemeColor 246 242 234)
        Panel       = (New-ThemeColor 255 252 247)
        Toolbar     = (New-ThemeColor 250 246 238)
        Line        = (New-ThemeColor 226 219 206)
        Text        = (New-ThemeColor 42 37 32)
        Muted       = (New-ThemeColor 110 101 90)
        Accent      = (New-ThemeColor 166 112 42)
        Deep        = (New-ThemeColor 122 86 48)
        AccentHover = (New-ThemeColor 186 134 58)
        AccentPress = (New-ThemeColor 132 86 28)
        Ink         = (New-ThemeColor 42 37 32)
        Select      = (New-ThemeColor 236 226 204)
        Hover       = (New-ThemeColor 236 230 218)
        Danger      = (New-ThemeColor 166 72 60)
        Working     = (New-ThemeColor 90 122 72)
        Created     = (New-ThemeColor 166 112 42)
        Idle        = (New-ThemeColor 140 130 118)
        PanelPress  = (New-ThemeColor 226 216 198)
        ChartBar    = (New-ThemeColor 214 186 142)
        ChartGrid   = (New-ThemeColor 226 219 206)
        Tip         = (New-ThemeColor 255 252 247)
        Alt         = (New-ThemeColor 248 244 236)
        Track       = (New-ThemeColor 232 224 210)
        Olive       = (New-ThemeColor 106 128 78)
        Copper      = (New-ThemeColor 176 122 78)
        Stone       = (New-ThemeColor 150 140 128)
    }
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
    if ($Range -eq 'today') {
        $hours = @()
        $ht = [int64]0; $hi = [int64]0; $ho = [int64]0
        for ($h = 0; $h -le 23; $h++) {
            $v = [int64]0
            if ($h -ge 9 -and $h -le 21) { $v = [int64]((0.15 + (($h - 9) % 5) * 0.12) * 1000000) }
            if ($h -eq 15) { $v = [int64](2.8 * 1000000) }
            $vi = [int64]($v * 0.996)
            $vo = [int64]($v - $vi)
            $ht += $v; $hi += $vi; $ho += $vo
            $hours += [pscustomobject]@{ Date = [datetime]::Today.AddHours($h); Hour = $h; Total = $v; Input = $vi; Output = $vo }
        }
        $days = $hours
        $total = $ht; $inp = $hi; $outp = $ho
    }
    if ($Range -eq '30d') { $total = [int64]($total * 2.1); $inp = [int64]($inp * 2.1); $outp = [int64]($outp * 2.1) }
    if ($Range -eq 'all') { $total = [int64]($total * 4.8); $inp = [int64]($inp * 4.8); $outp = [int64]($outp * 4.8) }
    $top = @(
        [pscustomobject]@{ Label = 'shop-web'; Path = 'D:\Work\shop-web'; Tokens = [int64]($total * 0.44); Sessions = 12 }
        [pscustomobject]@{ Label = 'notes-app'; Path = 'D:\Work\notes-app'; Tokens = [int64]($total * 0.32); Sessions = 8 }
        [pscustomobject]@{ Label = 'wiki-site'; Path = 'D:\Work\wiki-site'; Tokens = [int64]($total * 0.14); Sessions = 5 }
        [pscustomobject]@{ Label = 'cli-tools'; Path = 'D:\Work\cli-tools'; Tokens = [int64]($total * 0.07); Sessions = 4 }
    )
    $todayVal = $total
    if ($Range -ne 'today') {
        $hit = @($days | Where-Object { $_.Date.Date -eq [datetime]::Today })
        if ($hit.Count -gt 0) { $todayVal = [int64]$hit[0].Total }
    }
    return [pscustomobject]@{
        Range    = $Range
        Total    = $total
        Input    = $inp
        Output   = $outp
        Cached   = [int64]($total * 0.62)
        Today    = $todayVal
        Sessions = 29
        Windows  = 4
        Active   = 4
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
    $hourMap = @{}
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
                $sess = Get-PsProp $u 'session'
                if ($sess -and -not $model) {
                    $mid = Get-PsProp $sess 'primaryModelId'
                    if ($mid) { $model = [string]$mid }
                }
                $dirKey = $cwd
                if ([string]::IsNullOrWhiteSpace($dirKey)) { $dirKey = '(unknown)' }
                $turnList = Get-PsProp $u 'turns'
                $hit = $false
                foreach ($tr in @($turnList)) {
                    if (-not $tr) { continue }
                    $th = Convert-GrokTime ([string](Get-PsProp $tr 'endedAt'))
                    if (-not $th) { continue }
                    $local = $th.ToLocalTime().DateTime
                    if ($local.Date -lt $from) { continue }
                    $uc = Get-UsageCounts $tr
                    if ($uc.Total -le 0) { continue }
                    $hit = $true
                    $total += [int64]$uc.Total
                    $inp += [int64]$uc.Input
                    $outp += [int64]$uc.Output
                    $cache += [int64]$uc.Cached
                    $dayKey = $local.Date.ToString('yyyy-MM-dd')
                    if (-not $dayMap.Contains($dayKey)) {
                        $dayMap[$dayKey] = @{ Total = [int64]0; Input = [int64]0; Output = [int64]0 }
                    }
                    $dayMap[$dayKey].Total = [int64]$dayMap[$dayKey].Total + $uc.Total
                    $dayMap[$dayKey].Input = [int64]$dayMap[$dayKey].Input + $uc.Input
                    $dayMap[$dayKey].Output = [int64]$dayMap[$dayKey].Output + $uc.Output
                    if (-not $dirMap.Contains($dirKey)) {
                        $dirMap[$dirKey] = @{ Tokens = [int64]0; Sessions = 0 }
                    }
                    $dirMap[$dirKey].Tokens = [int64]$dirMap[$dirKey].Tokens + $uc.Total
                    if ($Range -eq 'today' -and $local.Date -eq [datetime]::Today) {
                        $hk = [string]$local.Hour
                        if (-not $hourMap.Contains($hk)) { $hourMap[$hk] = @{ Total = [int64]0; Input = [int64]0; Output = [int64]0 } }
                        $hourMap[$hk].Total = [int64]$hourMap[$hk].Total + $uc.Total
                        $hourMap[$hk].Input = [int64]$hourMap[$hk].Input + $uc.Input
                        $hourMap[$hk].Output = [int64]$hourMap[$hk].Output + $uc.Output
                    }
                }
                if ($hit) {
                    $sessCount += 1
                    if (-not $dirMap.Contains($dirKey)) {
                        $dirMap[$dirKey] = @{ Tokens = [int64]0; Sessions = 0 }
                    }
                    $dirMap[$dirKey].Sessions += 1
                }
            }
        }
    }
    $chartFrom = $from
    if ($Range -eq 'all' -or $Range -eq '30d') { $chartFrom = [datetime]::Today.AddDays(-13) }
    $days = @()
    if ($Range -eq 'today') {
        for ($hh = 0; $hh -le 23; $hh++) {
            $hk = [string]$hh
            $v = [int64]0; $vi = [int64]0; $vo = [int64]0
            if ($hourMap.Contains($hk)) {
                $v = [int64]$hourMap[$hk].Total
                $vi = [int64]$hourMap[$hk].Input
                $vo = [int64]$hourMap[$hk].Output
            }
            $days += [pscustomobject]@{ Date = [datetime]::Today.AddHours($hh); Hour = $hh; Total = $v; Input = $vi; Output = $vo }
        }
    } else {
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
        Active   = @($dirMap.Keys).Count
        Days     = $days
        TopDirs  = $top
        Model    = $model
    }
}

function Get-UsageLedger {
    param([string]$Range = '7d', [string]$Model = '')
    $from = Get-RangeStart $Range
    $want = ''
    if ($Model) { $want = $Model.Trim() }
    $rows = New-Object System.Collections.Generic.List[object]
    $modelTokens = @{}

    if ($script:DemoMode) {
        $now = [datetime]::Now
        $demo = @(
            @{ Min = -18; Project = 'shop-web'; Path = 'D:\Work\shop-web'; Model = 'grok-4.6'; In = 1820000; Out = 410000; Reason = 86000; Cache = 640000; Create = 12000; Calls = 4; Cost = 0.48 }
            @{ Min = -70; Project = 'notes-app'; Path = 'D:\Work\notes-app'; Model = 'grok-4.6'; In = 420000; Out = 90000; Reason = 22000; Cache = 180000; Create = 0; Calls = 2; Cost = 0.11 }
            @{ Min = -240; Project = 'wiki-site'; Path = 'D:\Work\wiki-site'; Model = 'grok-4'; In = 960000; Out = 210000; Reason = 40000; Cache = 120000; Create = 8000; Calls = 3; Cost = 0.22 }
            @{ Min = -900; Project = 'cli-tools'; Path = 'D:\Work\cli-tools'; Model = 'grok-4'; In = 210000; Out = 54000; Reason = 6000; Cache = 40000; Create = 0; Calls = 1; Cost = 0.04 }
            @{ Min = -1800; Project = 'shop-web'; Path = 'D:\Work\shop-web'; Model = 'grok-4.6'; In = 3100000; Out = 720000; Reason = 150000; Cache = 980000; Create = 30000; Calls = 6; Cost = 0.81 }
        )
        foreach ($d in $demo) {
            $when = $now.AddMinutes([int]$d.Min)
            if ($when -lt $from) { continue }
            $mid = [string]$d.Model
            $tot = [int64]$d.In + [int64]$d.Out
            $row = [pscustomobject]@{
                When        = $when
                Project     = [string]$d.Project
                Path        = [string]$d.Path
                Model       = $mid
                Input       = [int64]$d.In
                Output      = [int64]$d.Out
                Reasoning   = [int64]$d.Reason
                Cached      = [int64]$d.Cache
                CacheCreate = [int64]$d.Create
                Total       = $tot
                Calls       = [int]$d.Calls
                CostUsd     = [double]$d.Cost
            }
            if (-not $modelTokens.ContainsKey($mid)) { $modelTokens[$mid] = [int64]0 }
            $modelTokens[$mid] = [int64]$modelTokens[$mid] + $tot
            [void]$rows.Add($row)
        }
    } else {
        $sessionsRoot = Join-Path $env:USERPROFILE '.grok\sessions'
        if (Test-Path -LiteralPath $sessionsRoot) {
            foreach ($group in Get-ChildItem -LiteralPath $sessionsRoot -Directory -ErrorAction SilentlyContinue) {
                $cwd = Convert-SessionCwd -EncodedName $group.Name -GroupPath $group.FullName
                $leaf = if ($cwd) { Split-Path $cwd -Leaf } else { $group.Name }
                if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = $group.Name }
                foreach ($sessionDir in Get-ChildItem -LiteralPath $group.FullName -Directory -ErrorAction SilentlyContinue) {
                    $usagePath = Join-Path $sessionDir.FullName 'usage.json'
                    if (-not (Test-Path -LiteralPath $usagePath)) { continue }
                    $u = Read-JsonFile $usagePath
                    if (-not $u) { continue }
                    foreach ($tr in @(Get-PsProp $u 'turns')) {
                        if (-not $tr) { continue }
                        $th = Convert-GrokTime ([string](Get-PsProp $tr 'endedAt'))
                        if (-not $th) { continue }
                        $local = $th.ToLocalTime().DateTime
                        if ($local -lt $from) { continue }
                        $uc = Get-UsageCounts $tr
                        $reason = [int64]0
                        $create = [int64]0
                        $calls = 0
                        try {
                            $rv = Get-PsProp $tr 'reasoningTokens'
                            if ($null -ne $rv) { $reason = [int64]$rv }
                        } catch { }
                        try {
                            $cv = Get-PsProp $tr 'cacheCreationTokens'
                            if ($null -ne $cv) { $create = [int64]$cv }
                        } catch { }
                        try {
                            $mv = Get-PsProp $tr 'modelCalls'
                            if ($null -ne $mv) { $calls = [int]$mv }
                        } catch { }
                        if ($uc.Total -le 0 -and $uc.UsdTicks -le 0 -and $reason -le 0) { continue }
                        $mid = [string](Get-PsProp $tr 'primaryModelId')
                        if ([string]::IsNullOrWhiteSpace($mid)) { $mid = '—' }
                        $cost = 0.0
                        $usd = Convert-UsdTicks $uc.UsdTicks
                        if ($null -ne $usd) { $cost = [double]$usd }
                        $row = [pscustomobject]@{
                            When        = $local
                            Project     = $leaf
                            Path        = $(if ($cwd) { $cwd } else { '' })
                            Model       = $mid
                            Input       = [int64]$uc.Input
                            Output      = [int64]$uc.Output
                            Reasoning   = $reason
                            Cached      = [int64]$uc.Cached
                            CacheCreate = $create
                            Total       = [int64]$uc.Total
                            Calls       = $calls
                            CostUsd     = $cost
                        }
                        if (-not $modelTokens.ContainsKey($mid)) { $modelTokens[$mid] = [int64]0 }
                        $modelTokens[$mid] = [int64]$modelTokens[$mid] + [int64]$uc.Total
                        [void]$rows.Add($row)
                    }
                }
            }
        }
    }

    $models = @()
    foreach ($pair in @($modelTokens.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5)) {
        if ($pair.Key) { $models += [string]$pair.Key }
    }
    $filtered = New-Object System.Collections.Generic.List[object]
    foreach ($row in $rows) {
        if ($want -and $row.Model -ne $want) { continue }
        [void]$filtered.Add($row)
    }
    $turns = 0
    $calls = 0
    $total = [int64]0
    $inp = [int64]0
    $outp = [int64]0
    $cached = [int64]0
    $createSum = [int64]0
    $reasonSum = [int64]0
    $costSum = 0.0
    foreach ($row in $filtered) {
        $turns += 1
        $calls += [int]$row.Calls
        $total += [int64]$row.Total
        $inp += [int64]$row.Input
        $outp += [int64]$row.Output
        $cached += [int64]$row.Cached
        $createSum += [int64]$row.CacheCreate
        $reasonSum += [int64]$row.Reasoning
        $costSum += [double]$row.CostUsd
    }
    $shown = @($filtered | Sort-Object When -Descending | Select-Object -First 120)
    return [pscustomobject]@{
        Range       = $Range
        Model       = $want
        Models      = @($models)
        Turns       = $turns
        Calls       = $calls
        Total       = $total
        Input       = $inp
        Output      = $outp
        Cached      = $cached
        CacheCreate = $createSum
        Reasoning   = $reasonSum
        CostUsd     = $costSum
        Records     = $shown
    }
}

function Select-LatestPerPath {
    param($Items, [int]$Take = 8)
    $sorted = @($Items | Sort-Object When -Descending)
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $out = @()
    foreach ($item in $sorted) {
        $key = [string]$item.Path
        if ([string]::IsNullOrWhiteSpace($key)) { $key = [string]$item.Label }
        if (-not [string]::IsNullOrWhiteSpace($key)) { $key = $key.TrimEnd('\', '/') }
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        if ($seen.Contains($key)) { continue }
        [void]$seen.Add($key)
        $out += $item
        if ($out.Count -ge $Take) { break }
    }
    $leafGroups = @($out | Group-Object Label)
    $dupLeaves = @{}
    foreach ($g in $leafGroups) {
        if ($g.Count -gt 1) { $dupLeaves[$g.Name] = $true }
    }
    foreach ($item in $out) {
        if ($dupLeaves.Contains($item.Label) -and $item.Path) {
            $parent = Split-Path $item.Path -Parent
            $parentLeaf = if ($parent) { Split-Path $parent -Leaf } else { '' }
            if ($parentLeaf) {
                $item.Label = ('{0} / {1}' -f $parentLeaf, $item.Label)
            }
        }
    }
    return @($out)
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
    return @(Select-LatestPerPath -Items $list -Take $Take)
}

function Get-PsProp {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    try {
        if (@($Obj.PSObject.Properties.Name) -contains $Name) { return $Obj.$Name }
    } catch { }
    return $null
}

function Get-QuotaView {
    if (-not (Get-Variable -Name quotaView -Scope Script -ErrorAction SilentlyContinue)) {
        $script:quotaView = $null
        return $null
    }
    try { return $script:quotaView } catch { return $null }
}

function Get-MoneyVal {
    param($V)
    if ($null -eq $V) { return $null }
    if ($V -is [ValueType]) {
        try { return [double]$V } catch { return $null }
    }
    $inner = Get-PsProp $V 'val'
    if ($null -ne $inner) {
        try { return [double]$inner } catch { return $null }
    }
    return $null
}

function Mask-GrokEmail {
    param([string]$Email)
    if ([string]::IsNullOrWhiteSpace($Email)) { return '' }
    if ($Email -match '^(.{1,2}).*(@.+)$') { return ($Matches[1] + '***' + $Matches[2]) }
    if ($Email.Length -le 4) { return '***' }
    return ($Email.Substring(0, 2) + '***')
}

function Ensure-Tls12 {
    $flags = [Net.SecurityProtocolType]::Tls12
    try { $flags = $flags -bor [Net.SecurityProtocolType]::Tls13 } catch { }
    [Net.ServicePointManager]::SecurityProtocol = $flags
    [Net.ServicePointManager]::Expect100Continue = $false
}

function Format-QuotaNetError {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return '网络失败' }
    if ($Message -match 'Bearer|eyJ') { return '网络失败' }
    if ($Message -match '基础连接|GetResponse|closed|unexpected error|SSL|TLS|被强制关闭') {
        return '连接被重置，请再点刷新'
    }
    if ($Message -match 'HTTP\s+(\d+)') { return ('HTTP {0}' -f $Matches[1]) }
    if ($Message.Length -gt 42) { return $Message.Substring(0, 42) }
    return $Message
}

function Invoke-GrokBillingRaw {
    param([Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$Url)
    Ensure-Tls12
    $headers = @{
        Authorization           = ('Bearer {0}' -f $Token)
        'x-xai-token-auth'      = 'xai-grok-cli'
        'x-grok-client-version' = '0.2.93'
        Accept                  = '*/*'
    }
    try {
        $resp = Invoke-WebRequest -Uri $Url -Headers $headers -UseBasicParsing -TimeoutSec 15
        return [string]$resp.Content
    } catch {
        throw (Format-QuotaNetError ([string]$_.Exception.Message))
    }
}

function Get-GrokCliAuthInfo {
    $authPath = Join-Path $env:USERPROFILE '.grok\auth.json'
    if (-not (Test-Path -LiteralPath $authPath)) { return $null }
    $raw = ''
    try {
        $raw = [System.IO.File]::ReadAllText($authPath, [System.Text.UTF8Encoding]::new($false))
    } catch { return $null }
    $obj = $null
    try { $obj = $raw | ConvertFrom-Json } catch { return $null }
    if (-not $obj) { return $null }
    $best = $null
    $bestExp = [datetimeoffset]::MinValue
    $bestRefresh = $false
    foreach ($prop in @($obj.PSObject.Properties)) {
        $e = $prop.Value
        if (-not $e) { continue }
        $key = [string](Get-PsProp $e 'key')
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        $hasRefresh = -not [string]::IsNullOrWhiteSpace([string](Get-PsProp $e 'refresh_token'))
        $exp = [datetimeoffset]::Now.AddHours(1)
        $expRaw = Get-PsProp $e 'expires_at'
        if ($expRaw) {
            try { $exp = [datetimeoffset]::Parse([string]$expRaw) } catch { }
        }
        $pick = $false
        if (-not $best) { $pick = $true }
        elseif ($hasRefresh -and -not $bestRefresh) { $pick = $true }
        elseif ($hasRefresh -eq $bestRefresh -and $exp -gt $bestExp) { $pick = $true }
        if ($pick) {
            $email = [string](Get-PsProp $e 'email')
            $best = @{
                Token = $key
                Email = $email
            }
            $bestExp = $exp
            $bestRefresh = $hasRefresh
        }
    }
    if (-not $best) { return $null }
    return [pscustomobject]$best
}

function Format-QuotaReset {
    param($Iso)
    if (-not $Iso) { return '' }
    try {
        $dto = [datetimeoffset]::Parse([string]$Iso)
        return $dto.ToLocalTime().ToString('M月d日 HH:mm')
    } catch { return '' }
}

function Format-QuotaWindow {
    param($Start, $End)
    $a = Convert-GrokTime ([string]$Start)
    $b = Convert-GrokTime ([string]$End)
    if (-not $a) { return '' }
    $al = $a.ToLocalTime()
    if (-not $b) { return ($al.ToString('M/d HH:mm') + ' 起') }
    $bl = $b.ToLocalTime()
    return ('{0}–{1}' -f $al.ToString('M/d HH:mm'), $bl.ToString('M/d HH:mm'))
}

function Convert-GrokBillingToQuota {
    param($Weekly, $Monthly, [string]$Email)
    $wcfg = $Weekly
    if ($Weekly) {
        $c = Get-PsProp $Weekly 'config'
        if ($c) { $wcfg = $c }
        if ($wcfg -is [string]) {
            try { $wcfg = $wcfg | ConvertFrom-Json } catch { $wcfg = $Weekly }
        }
    }
    $mcfg = $Monthly
    if ($Monthly) {
        $c2 = Get-PsProp $Monthly 'config'
        if ($c2) { $mcfg = $c2 }
        if ($mcfg -is [string]) {
            try { $mcfg = $mcfg | ConvertFrom-Json } catch { $mcfg = $Monthly }
        }
    }

    $usedPct = $null
    $period = 'unknown'
    $periodStart = $null
    $periodEnd = $null
    $products = @()

    if ($wcfg) {
        $cup = Get-PsProp $wcfg 'creditUsagePercent'
        if ($null -eq $cup) { $cup = Get-PsProp $wcfg 'credit_usage_percent' }
        if ($null -ne $cup) {
            try { $usedPct = [double]$cup } catch { }
        }
        $cp = Get-PsProp $wcfg 'currentPeriod'
        if (-not $cp) { $cp = Get-PsProp $wcfg 'current_period' }
        $ptype = [string](Get-PsProp $cp 'type')
        if ($ptype -match 'WEEKLY|weekly') { $period = 'weekly' }
        elseif ($ptype -match 'MONTHLY|monthly') { $period = 'monthly' }
        $periodStart = Get-PsProp $cp 'start'
        if (-not $periodStart) { $periodStart = Get-PsProp $wcfg 'billingPeriodStart' }
        if (-not $periodStart) { $periodStart = Get-PsProp $wcfg 'billing_period_start' }
        $periodEnd = Get-PsProp $cp 'end'
        if (-not $periodEnd) { $periodEnd = Get-PsProp $wcfg 'billingPeriodEnd' }
        if (-not $periodEnd) { $periodEnd = Get-PsProp $wcfg 'billing_period_end' }
        $praw = Get-PsProp $wcfg 'productUsage'
        if (-not $praw) { $praw = Get-PsProp $wcfg 'product_usage' }
        foreach ($it in @($praw)) {
            if (-not $it) { continue }
            $pn = [string](Get-PsProp $it 'product')
            if ([string]::IsNullOrWhiteSpace($pn)) { continue }
            $up = Get-PsProp $it 'usagePercent'
            if ($null -eq $up) { $up = Get-PsProp $it 'usage_percent' }
            $upn = $null
            if ($null -ne $up) { try { $upn = [double]$up } catch { } }
            $products += [pscustomobject]@{ Name = $pn; UsedPct = $upn }
        }
        if ($period -eq 'unknown' -and $null -ne $usedPct) { $period = 'weekly' }
    }

    $prepaidUsd = $null
    $odCapUsd = $null
    $odUsedUsd = $null
    if ($wcfg) {
        $pb = Get-MoneyVal (Get-PsProp $wcfg 'prepaidBalance')
        if ($null -eq $pb) { $pb = Get-MoneyVal (Get-PsProp $wcfg 'prepaid_balance') }
        if ($null -ne $pb) { $prepaidUsd = [double]$pb / 100.0 }
        $odc = Get-MoneyVal (Get-PsProp $wcfg 'onDemandCap')
        if ($null -eq $odc) { $odc = Get-MoneyVal (Get-PsProp $wcfg 'on_demand_cap') }
        $odu = Get-MoneyVal (Get-PsProp $wcfg 'onDemandUsed')
        if ($null -eq $odu) { $odu = Get-MoneyVal (Get-PsProp $wcfg 'on_demand_used') }
        if ($null -ne $odc) { $odCapUsd = [double]$odc / 100.0 }
        if ($null -ne $odu) { $odUsedUsd = [double]$odu / 100.0 }
    }

    $monthlyLimit = $null
    $monthlyUsed = $null
    if ($mcfg) {
        $monthlyLimit = Get-MoneyVal (Get-PsProp $mcfg 'monthlyLimit')
        if ($null -eq $monthlyLimit) { $monthlyLimit = Get-MoneyVal (Get-PsProp $mcfg 'monthly_limit') }
        $monthlyUsed = Get-MoneyVal (Get-PsProp $mcfg 'used')
        if (-not $periodEnd) {
            $periodEnd = Get-PsProp $mcfg 'billingPeriodEnd'
            if (-not $periodEnd) { $periodEnd = Get-PsProp $mcfg 'billing_period_end' }
        }
        if ($period -eq 'unknown' -and $null -ne $monthlyLimit -and $monthlyLimit -gt 0) { $period = 'monthly' }
        if ($null -eq $usedPct -and $monthlyLimit -gt 0 -and $null -ne $monthlyUsed) {
            $usedPct = [Math]::Max(0, [Math]::Min(100, 100.0 * $monthlyUsed / $monthlyLimit))
        }
    }

    $unified = $false
    if ($wcfg) {
        $uflag = Get-PsProp $wcfg 'isUnifiedBillingUser'
        if ($null -eq $uflag) { $uflag = Get-PsProp $wcfg 'is_unified_billing_user' }
        if ($uflag) { $unified = [bool]$uflag }
    }
    $plan = '账号额度'
    if ($unified -or $period -eq 'weekly') { $plan = 'SuperGrok 周限额' }
    elseif ($monthlyLimit -eq 15000) { $plan = 'SuperGrok' }
    elseif ($monthlyLimit -eq 150000) { $plan = 'SuperGrok Heavy' }
    elseif ($period -eq 'monthly') { $plan = '月限额' }

    if ($null -eq $usedPct) { $usedPct = 0.0 }
    $usedPct = [Math]::Max(0, [Math]::Min(100, $usedPct))
    $remainPct = [Math]::Max(0, [Math]::Min(100, 100.0 - $usedPct))
    $bits = @()
    foreach ($p in $products) {
        if ($null -eq $p.UsedPct) { continue }
        $bits += ('{0} {1:N0}%' -f $p.Name, $p.UsedPct)
    }
    $monthLine = ''
    if ($null -ne $monthlyLimit -and $monthlyLimit -gt 0) {
        $left = $monthlyLimit
        if ($null -ne $monthlyUsed) { $left = [Math]::Max(0, $monthlyLimit - $monthlyUsed) }
        $monthLine = ('本月 ${0:N0} / ${1:N0}' -f ($left / 100.0), ($monthlyLimit / 100.0))
    }

    $remainUsdOfficial = $null
    if ($null -ne $monthlyLimit -and $monthlyLimit -gt 0 -and $null -ne $monthlyUsed) {
        $remainUsdOfficial = [Math]::Max(0, ($monthlyLimit - $monthlyUsed) / 100.0)
    }

    return [pscustomobject]@{
        Ok                = $true
        UsedPct           = $usedPct
        RemainPct         = $remainPct
        Period            = $period
        PeriodStart       = $(if ($periodStart) { [string]$periodStart } else { '' })
        PeriodEnd         = $(if ($periodEnd) { [string]$periodEnd } else { '' })
        PlanLabel         = $plan
        ResetLabel        = Format-QuotaReset $periodEnd
        ProductLine       = ($bits -join '  ·  ')
        MonthLine         = $monthLine
        EmailMask         = Mask-GrokEmail $Email
        UsedTokens        = $null
        UsedUsd           = $null
        RemainTokens      = $null
        RemainUsd         = $null
        RemainUsdOfficial = $remainUsdOfficial
        PrepaidUsd        = $prepaidUsd
        OnDemandCapUsd    = $odCapUsd
        OnDemandUsedUsd   = $odUsedUsd
        EstimateNote      = ''
        FetchedAt         = [datetime]::Now
        Error             = ''
    }
}

function Get-LocalUsageBetween {
    param($From, $To)
    $empty = [pscustomobject]@{ Tokens = [int64]0; Usd = 0.0; Turns = 0 }
    if ($script:DemoMode) {
        return [pscustomobject]@{ Tokens = [int64]4200000; Usd = 1.80; Turns = 14 }
    }
    if (-not $From) { return $empty }
    $fromDto = $null
    if ($From -is [datetimeoffset]) { $fromDto = $From }
    else { $fromDto = Convert-GrokTime ([string]$From) }
    if (-not $fromDto) { return $empty }
    $toDto = [datetimeoffset]::Now
    if ($To) {
        if ($To -is [datetimeoffset]) { $toDto = $To }
        else {
            $parsedTo = Convert-GrokTime ([string]$To)
            if ($parsedTo) { $toDto = $parsedTo }
        }
    }
    $sessionsRoot = Join-Path $env:USERPROFILE '.grok\sessions'
    if (-not (Test-Path -LiteralPath $sessionsRoot)) { return $empty }
    $tokens = [int64]0
    $ticks = [int64]0
    $turns = 0
    $fromLocal = $fromDto.ToLocalTime().DateTime
    foreach ($group in Get-ChildItem -LiteralPath $sessionsRoot -Directory -ErrorAction SilentlyContinue) {
        foreach ($sessionDir in Get-ChildItem -LiteralPath $group.FullName -Directory -ErrorAction SilentlyContinue) {
            $usagePath = Join-Path $sessionDir.FullName 'usage.json'
            if (-not (Test-Path -LiteralPath $usagePath)) { continue }
            try {
                if ((Get-Item -LiteralPath $usagePath).LastWriteTime -lt $fromLocal.AddDays(-1)) { continue }
            } catch { }
            $u = Read-JsonFile $usagePath
            if (-not $u) { continue }
            $turnList = Get-PsProp $u 'turns'
            if (-not $turnList) { continue }
            foreach ($tr in @($turnList)) {
                if (-not $tr) { continue }
                $ended = Get-PsProp $tr 'endedAt'
                if (-not $ended) { continue }
                $th = Convert-GrokTime ([string]$ended)
                if (-not $th) { continue }
                if ($th -lt $fromDto -or $th -gt $toDto) { continue }
                $uc = Get-UsageCounts $tr
                if ($uc.Total -le 0 -and $uc.UsdTicks -le 0) { continue }
                $tokens += [int64]$uc.Total
                $ticks += [int64]$uc.UsdTicks
                $turns += 1
            }
        }
    }
    $usd = 0.0
    if ($ticks -gt 0) { $usd = [double]$ticks / 10000000000.0 }
    return [pscustomobject]@{ Tokens = $tokens; Usd = $usd; Turns = $turns }
}

function Add-QuotaEstimates {
    param($View, $LocalTokens, $LocalUsd)
    if (-not $View) { return $View }
    $tok = $LocalTokens
    $usd = $LocalUsd
    if ($null -eq $tok -or $null -eq $usd) {
        $local = Get-LocalUsageBetween -From (Get-PsProp $View 'PeriodStart') -To (Get-PsProp $View 'PeriodEnd')
        $tok = [int64]$local.Tokens
        $usd = [double]$local.Usd
    }
    # Official SuperGrok weekly pool is a percent, not tokens or dollars.
    # Do not invert local spend against creditUsagePercent — GitHub grok-build
    # billing.rs and OpenUsage keep local session cost separate from the pool.
    $remainTok = $null
    $remainUsd = $null
    $note = '周池为官方百分比；本机 Token/$ 是 CLI 消耗，不是剩余额度'
    $official = Get-PsProp $View 'RemainUsdOfficial'
    if ($null -ne $official -and [double]$official -gt 0) {
        $remainUsd = [double]$official
        $note = '月额度剩余来自官方 billing'
    }
    $prepaid = Get-PsProp $View 'PrepaidUsd'
    if ($null -ne $prepaid -and [double]$prepaid -gt 0) {
        $remainUsd = [double]$prepaid
        $note = '加购额度来自 prepaidBalance'
    }
    $View | Add-Member -NotePropertyName UsedTokens -NotePropertyValue $tok -Force
    $View | Add-Member -NotePropertyName UsedUsd -NotePropertyValue $usd -Force
    $View | Add-Member -NotePropertyName RemainTokens -NotePropertyValue $remainTok -Force
    $View | Add-Member -NotePropertyName RemainUsd -NotePropertyValue $remainUsd -Force
    $View | Add-Member -NotePropertyName EstimateNote -NotePropertyValue $note -Force
    return $View
}

function Get-DemoQuotaView {
    $view = [pscustomobject]@{
        Ok                = $true
        UsedPct           = 38.0
        RemainPct         = 62.0
        Period            = 'weekly'
        PeriodStart       = [datetimeoffset]::Now.AddDays(-3).ToString('o')
        PeriodEnd         = [datetimeoffset]::Now.AddDays(4).ToString('o')
        PlanLabel         = '周限额'
        ResetLabel        = [datetime]::Now.AddDays(4).ToString('M月d日 HH:mm')
        ProductLine       = 'GrokBuild 36%  ·  GrokTasks 8%'
        MonthLine         = ''
        EmailMask         = ''
        UsedTokens        = $null
        UsedUsd           = $null
        RemainTokens      = $null
        RemainUsd         = $null
        RemainUsdOfficial = $null
        PrepaidUsd        = 0
        OnDemandCapUsd    = 0
        OnDemandUsedUsd   = 0
        EstimateNote      = ''
        FetchedAt         = [datetime]::Now
        Error             = ''
    }
    return Add-QuotaEstimates -View $view -LocalTokens 4200000 -LocalUsd 1.80
}

function Read-QuotaCache {
    if (-not (Test-Path -LiteralPath $script:QuotaCachePath)) { return $null }
    try {
        $j = Read-JsonFile $script:QuotaCachePath
        if (-not $j) { return $null }
        $when = $null
        $fa = Get-PsProp $j 'FetchedAt'
        if ($fa) { try { $when = [datetime]::Parse([string]$fa) } catch { } }
        $view = [pscustomobject]@{
            Ok                = $true
            UsedPct           = [double](Get-PsProp $j 'UsedPct')
            RemainPct         = [double](Get-PsProp $j 'RemainPct')
            Period            = [string](Get-PsProp $j 'Period')
            PeriodStart       = [string](Get-PsProp $j 'PeriodStart')
            PeriodEnd         = [string](Get-PsProp $j 'PeriodEnd')
            PlanLabel         = [string](Get-PsProp $j 'PlanLabel')
            ResetLabel        = [string](Get-PsProp $j 'ResetLabel')
            ProductLine       = [string](Get-PsProp $j 'ProductLine')
            MonthLine         = [string](Get-PsProp $j 'MonthLine')
            EmailMask         = [string](Get-PsProp $j 'EmailMask')
            UsedTokens        = $null
            UsedUsd           = $null
            RemainTokens      = $null
            RemainUsd         = $null
            RemainUsdOfficial = (Get-PsProp $j 'RemainUsdOfficial')
            PrepaidUsd        = (Get-PsProp $j 'PrepaidUsd')
            OnDemandCapUsd    = (Get-PsProp $j 'OnDemandCapUsd')
            OnDemandUsedUsd   = (Get-PsProp $j 'OnDemandUsedUsd')
            EstimateNote      = ''
            FetchedAt         = $(if ($when) { $when } else { [datetime]::MinValue })
            Error             = ''
        }
        return Add-QuotaEstimates $view
    } catch { return $null }
}

function Save-QuotaCache {
    param($View)
    if ($script:DemoMode) { return }
    if (-not $View -or -not $View.Ok) { return }
    try {
        $payload = @{
            UsedPct           = [double]$View.UsedPct
            RemainPct         = [double]$View.RemainPct
            Period            = [string]$View.Period
            PeriodStart       = [string](Get-PsProp $View 'PeriodStart')
            PeriodEnd         = [string](Get-PsProp $View 'PeriodEnd')
            PlanLabel         = [string]$View.PlanLabel
            ResetLabel        = [string]$View.ResetLabel
            ProductLine       = [string]$View.ProductLine
            MonthLine         = [string]$View.MonthLine
            EmailMask         = [string]$View.EmailMask
            RemainUsdOfficial = (Get-PsProp $View 'RemainUsdOfficial')
            PrepaidUsd        = (Get-PsProp $View 'PrepaidUsd')
            OnDemandCapUsd    = (Get-PsProp $View 'OnDemandCapUsd')
            OnDemandUsedUsd   = (Get-PsProp $View 'OnDemandUsedUsd')
            FetchedAt         = $View.FetchedAt.ToString('o')
        } | ConvertTo-Json -Compress
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($script:QuotaCachePath, $payload, $utf8)
    } catch { }
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

function Get-FileTailText {
    param([string]$Path, [int]$MaxBytes = 65536)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $len = [int][Math]::Min($MaxBytes, $fs.Length)
        if ($len -le 0) { return '' }
        [void]$fs.Seek(-1 * $len, [System.IO.SeekOrigin]::End)
        $buf = New-Object byte[] $len
        [void]$fs.Read($buf, 0, $len)
        return [System.Text.Encoding]::UTF8.GetString($buf)
    } catch {
        return ''
    } finally {
        if ($fs) { $fs.Close() }
    }
}

function Get-SessionActivity {
    param([string]$SessionDir)
    if (-not $script:activityCache -or $script:activityCache -isnot [hashtable]) { $script:activityCache = @{} }
    $evtPath = Join-Path $SessionDir 'events.jsonl'
    $stamp = 0L
    if (Test-Path -LiteralPath $evtPath) {
        try { $stamp = (Get-Item -LiteralPath $evtPath).LastWriteTimeUtc.Ticks } catch { $stamp = 0L }
    }
    $hit = $script:activityCache[$SessionDir]
    if ($hit -and $hit.Stamp -eq $stamp -and $hit.At -and (((Get-Date) - $hit.At).TotalSeconds -lt 8)) {
        return $hit.Value
    }
    $recent = New-Object System.Collections.Generic.List[string]
    $open = New-Object System.Collections.Generic.List[string]
    $evt = Join-Path $SessionDir 'events.jsonl'
    if (Test-Path -LiteralPath $evt) {
        $raw = Get-FileTailText $evt 65536
        foreach ($ln in ($raw -split "`r?`n")) {
            if ($null -eq $ln) { continue }
            $t = ([string]$ln).Trim()
            if (-not $t.StartsWith('{')) { continue }
            $o = $null
            try { $o = $t | ConvertFrom-Json } catch { continue }
            if (-not $o) { continue }
            $names = @()
            try { $names = @($o.PSObject.Properties.Name) } catch { continue }
            $typ = ''
            $nm = ''
            if ($names -contains 'type') { $typ = [string]$o.type }
            if ($names -contains 'tool_name') { $nm = [string]$o.tool_name }
            if ([string]::IsNullOrWhiteSpace($nm)) { continue }
            if ($typ -eq 'tool_started') {
                $open.Add($nm)
            } elseif ($typ -eq 'tool_completed') {
                if ($open.Count -gt 0) { $open.RemoveAt($open.Count - 1) }
                $outc = ''
                if ($names -contains 'outcome') { $outc = [string]$o.outcome }
                if ($outc) { $recent.Add("$nm · $outc") } else { $recent.Add($nm) }
            }
        }
    }
    $arr = @($recent)
    if ($arr.Count -gt 8) { $arr = $arr[($arr.Count - 8)..($arr.Count - 1)] }
    $current = $null
    if ($open.Count -gt 0) { $current = $open[$open.Count - 1] }
    $tokenM = ''
    $model = ''
    $toolCount = 0
    $turnCount = 0
    $usagePath = Join-Path $SessionDir 'usage.json'
    if (Test-Path -LiteralPath $usagePath) {
        $u = Read-JsonFile $usagePath
        $sess = $null
        if ($u -and $u.PSObject.Properties.Name -contains 'session') { $sess = $u.session }
        if ($sess) {
            try { if ($sess.PSObject.Properties.Name -contains 'totalTokens' -and $sess.totalTokens) { $tokenM = Format-TokenM $sess.totalTokens } } catch { }
            try { if ($sess.PSObject.Properties.Name -contains 'primaryModelId' -and $sess.primaryModelId) { $model = [string]$sess.primaryModelId } } catch { }
            try { if ($sess.PSObject.Properties.Name -contains 'modelCalls' -and $sess.modelCalls) { $toolCount = [int]$sess.modelCalls } } catch { }
        }
    }
    $result = @{
        CurrentTool = $current
        Recent      = $arr
        TokenM      = $tokenM
        Model       = $model
        ModelCalls  = $toolCount
    }
    $script:activityCache[$SessionDir] = @{ Stamp = $stamp; At = (Get-Date); Value = $result }
    return $result
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
            $act = $null
            try { $act = Get-SessionActivity $sessionDir.FullName } catch {
                $act = @{ CurrentTool = $null; Recent = @(); TokenM = ''; Model = ''; ModelCalls = 0 }
            }
            $sid = $sessionDir.Name
            $model = [string]$act.Model
            if (-not $model -and $sig -and $sig.PSObject.Properties.Name -contains 'primaryModelId' -and $sig.primaryModelId) {
                $model = [string]$sig.primaryModelId
            }
            $toolN = 0
            if ($sig -and $sig.PSObject.Properties.Name -contains 'toolCallCount') {
                try { $toolN = [int]$sig.toolCallCount } catch { $toolN = 0 }
            }
            $turnN = 0
            if ($sig -and $sig.PSObject.Properties.Name -contains 'turnCount') {
                try { $turnN = [int]$sig.turnCount } catch { $turnN = 0 }
            }
            $best = [pscustomobject]@{
                When        = $when
                UpdWrite    = $updWrite
                Title       = $title
                Detail      = $detail
                Progress    = $progress
                SessionId   = $sid
                SessionDir  = $sessionDir.FullName
                CurrentTool = $act.CurrentTool
                RecentTools = @($act.Recent)
                TokenM      = [string]$act.TokenM
                Model       = $model
                ToolCount   = $toolN
                TurnCount   = $turnN
                ModelCalls  = [int]$act.ModelCalls
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
        $currentTool = $null
        $recentTools = @()
        $tokenM = ''
        $model = ''
        $toolCount = 0
        $turnCount = 0
        $sessionId = ''
        if ($meta) {
            $currentTool = $meta.CurrentTool
            if ($meta.PSObject.Properties.Name -contains 'RecentTools' -and $meta.RecentTools) {
                $recentTools = @($meta.RecentTools)
            }
            $tokenM = [string]$meta.TokenM
            $model = [string]$meta.Model
            try { $toolCount = [int]$meta.ToolCount } catch { $toolCount = 0 }
            try { $turnCount = [int]$meta.TurnCount } catch { $turnCount = 0 }
            $sessionId = [string]$meta.SessionId
        }
        $taskLine = ''
        if ($kind -eq 'working' -and $currentTool) {
            $taskLine = ('正在执行 {0}' -f $currentTool)
        } elseif ($kind -eq 'working') {
            $taskLine = '正在跑这一轮任务'
        } elseif ($detail) {
            $taskLine = ('上一轮：{0}' -f $detail)
        }

        $rows += [pscustomobject]@{
            Pid          = $procId
            Label        = $leaf
            Path         = $(if ($cwd) { $cwd } else { '' })
            Kind         = $kind
            Title        = $(if ($meta -and $meta.Title) { $meta.Title } else { 'Grok 会话' })
            Progress     = $(if ($meta) { [int]$meta.Progress } else { 0 })
            AgeText      = Format-RunAge $started
            LastAgo      = $(if ($meta -and $meta.When) { Format-Ago $meta.When } else { '' })
            Detail       = $detail
            CurrentTool  = $currentTool
            RecentTools  = $recentTools
            TokenM       = $tokenM
            Model        = $model
            ToolCount    = $toolCount
            TurnCount    = $turnCount
            SessionId    = $sessionId
            TaskLine     = $taskLine
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
    $local = $null
    try {
        if ($When -is [datetimeoffset]) {
            $local = $When.ToLocalTime().DateTime
        } elseif ($When -is [datetime]) {
            $local = $When.ToLocalTime()
        } else {
            $local = ([datetimeoffset]$When).ToLocalTime().DateTime
        }
    } catch {
        return ''
    }
    if (-not $local) { return '' }
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

function Ensure-GrokFolderPickerType {
    if ('GrokFolderPicker' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;

[ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")]
public class GrokFileOpenDialogRCW { }

[ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IGrokShellItem {
    [PreserveSig] int BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
    [PreserveSig] int GetParent(out IGrokShellItem ppsi);
    [PreserveSig] int GetDisplayName(uint sigdnName, out IntPtr ppszName);
    [PreserveSig] int GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
    [PreserveSig] int Compare(IGrokShellItem psi, uint hint, out int piOrder);
}

[ComImport, Guid("D57C7288-D4AD-4768-BE02-9D969532D960"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IGrokFileDialog {
    [PreserveSig] int Show(IntPtr parent);
    [PreserveSig] int SetFileTypes(uint cFileTypes, IntPtr rgFilterSpec);
    [PreserveSig] int SetFileTypeIndex(uint iFileType);
    [PreserveSig] int GetFileTypeIndex(out uint piFileType);
    [PreserveSig] int Advise(IntPtr pfde, out uint pdwCookie);
    [PreserveSig] int Unadvise(uint dwCookie);
    [PreserveSig] int SetOptions(uint fos);
    [PreserveSig] int GetOptions(out uint fos);
    [PreserveSig] int SetDefaultFolder(IGrokShellItem psi);
    [PreserveSig] int SetFolder(IGrokShellItem psi);
    [PreserveSig] int GetFolder(out IGrokShellItem ppsi);
    [PreserveSig] int GetCurrentSelection(out IGrokShellItem ppsi);
    [PreserveSig] int SetFileName([MarshalAs(UnmanagedType.LPWStr)] string pszName);
    [PreserveSig] int GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string pszName);
    [PreserveSig] int SetTitle([MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
    [PreserveSig] int SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string pszText);
    [PreserveSig] int SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string pszLabel);
    [PreserveSig] int GetResult(out IGrokShellItem ppsi);
    [PreserveSig] int AddPlace(IGrokShellItem psi, int fdap);
    [PreserveSig] int SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string pszDefaultExtension);
    [PreserveSig] int Close(int hr);
    [PreserveSig] int SetClientGuid(ref Guid guid);
    [PreserveSig] int ClearClientData();
    [PreserveSig] int SetFilter(IntPtr pFilter);
}

public class GrokFolderPicker {
    const uint SIGDN_FILESYSPATH = 0x80058000;
    public static string DebugLogFile;
    public string InitialPath;
    public string Title;
    public string OkButtonLabel;
    public string SelectedPath { get; private set; }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    static extern int SHCreateItemFromParsingName(
        [MarshalAs(UnmanagedType.LPWStr)] string pszPath,
        IntPtr pbc,
        ref Guid riid,
        out IGrokShellItem ppv);

    static string ItemPath(IGrokShellItem item) {
        if (item == null) return null;
        IntPtr psz = IntPtr.Zero;
        try {
            if (item.GetDisplayName(SIGDN_FILESYSPATH, out psz) != 0 || psz == IntPtr.Zero) return null;
            return Marshal.PtrToStringUni(psz);
        } catch {
            return null;
        } finally {
            if (psz != IntPtr.Zero) Marshal.FreeCoTaskMem(psz);
        }
    }

    static void Log(string line) {
        try {
            if (string.IsNullOrEmpty(DebugLogFile)) return;
            File.AppendAllText(DebugLogFile, line + Environment.NewLine);
        } catch { }
    }

    public bool Show(IntPtr owner) {
        var dialog = (IGrokFileDialog)new GrokFileOpenDialogRCW();
        uint options;
        if (dialog.GetOptions(out options) != 0) options = 0;
        options |= 0x20 | 0x40 | 0x800;
        options &= ~0x1000u;
        int hr = dialog.SetOptions(options);
        Log("SetOptions " + hr);
        if (hr != 0) Marshal.ThrowExceptionForHR(hr);
        Guid client = new Guid("6f1c2a80-9b3e-4d1a-8c55-7e2a4b0d91f3");
        dialog.SetClientGuid(ref client);
        if (!string.IsNullOrEmpty(Title)) dialog.SetTitle(Title);
        if (!string.IsNullOrEmpty(OkButtonLabel)) dialog.SetOkButtonLabel(OkButtonLabel);
        if (!string.IsNullOrEmpty(InitialPath) && Directory.Exists(InitialPath)) {
            Guid iid = typeof(IGrokShellItem).GUID;
            IGrokShellItem start;
            if (SHCreateItemFromParsingName(InitialPath, IntPtr.Zero, ref iid, out start) == 0 && start != null)
                dialog.SetFolder(start);
        }
        hr = dialog.Show(owner);
        Log("Show hr=" + hr);
        if (hr == unchecked((int)0x800704C7)) return false;
        if (hr < 0) Marshal.ThrowExceptionForHR(hr);
        IGrokShellItem result;
        if (dialog.GetResult(out result) != 0) return false;
        string path = ItemPath(result);
        Log("result=" + path);
        if (string.IsNullOrWhiteSpace(path) || !Directory.Exists(path)) return false;
        SelectedPath = Path.GetFullPath(path);
        return true;
    }
}
'@
}

function Select-GrokFolderPath {
    param(
        $Owner,
        [string]$StartPath,
        [string]$Title = '选择文件夹',
        [string]$DebugLog
    )
    Ensure-GrokFolderPickerType
    if ($DebugLog) { [GrokFolderPicker]::DebugLogFile = $DebugLog }
    $picker = New-Object GrokFolderPicker
    $picker.Title = $(if ($Title) { $Title } else { '选择文件夹' })
    $picker.OkButtonLabel = '选择文件夹'
    if ($StartPath -and (Test-Path -LiteralPath $StartPath)) {
        $picker.InitialPath = [System.IO.Path]::GetFullPath($StartPath)
    } elseif (Test-Path -LiteralPath 'D:\Project') {
        $picker.InitialPath = 'D:\Project'
    }
    $hwnd = [IntPtr]::Zero
    if ($Owner) {
        try { $hwnd = $Owner.Handle } catch { $hwnd = [IntPtr]::Zero }
    }
    if (-not $picker.Show($hwnd)) { return $null }
    $chosen = [string]$picker.SelectedPath
    if ([string]::IsNullOrWhiteSpace($chosen)) { return $null }
    if (-not (Test-Path -LiteralPath $chosen -PathType Container)) { return $null }
    return [System.IO.Path]::GetFullPath($chosen)
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

function ConvertTo-ProcessArgumentString {
    param([AllowEmptyCollection()][string[]]$Parts)
    if (-not $Parts -or $Parts.Count -eq 0) { return '' }
    return (
        $Parts | ForEach-Object {
            if ($_ -eq ';') { ';' }
            elseif ($_ -match '[\s"]') { '"{0}"' -f ($_ -replace '"', '\"') }
            else { $_ }
        }
    ) -join ' '
}

function Build-WtNewTabArgumentString {
    param(
        [Parameter(Mandatory)][object[]]$Projects,
        [ValidateSet('continue', 'new', 'terminal')][string]$Mode,
        [string]$GrokExe,
        [switch]$UseProxy
    )
    $chunks = New-Object System.Collections.Generic.List[string]
    # wt -h: -w 0 always means the current/most recent window.
    # Do not pass --window last: this WT treats an unknown name as a new window.
    [void]$chunks.Add('-w')
    [void]$chunks.Add('0')
    $first = $true
    foreach ($p in $Projects) {
        if (-not $first) { [void]$chunks.Add(';') }
        [void]$chunks.Add('new-tab')
        [void]$chunks.Add('--title')
        [void]$chunks.Add((([string]$p.Label) -replace '[;"]', ' ').Trim())
        [void]$chunks.Add('-d')
        [void]$chunks.Add([string]$p.Path)
        [void]$chunks.Add('--')
        if ($Mode -eq 'terminal') {
            [void]$chunks.Add('powershell.exe')
        } elseif ($UseProxy) {
            # Launch grok.exe via cmd /c so proxy env stays in-process.
            # Do not exec a .cmd file here: WT + grok's -c breaks batch parsing.
            [void]$chunks.Add('cmd.exe')
            [void]$chunks.Add('/d')
            [void]$chunks.Add('/s')
            [void]$chunks.Add('/c')
            [void]$chunks.Add((Build-GrokProxyInnerCommand -GrokExe $GrokExe -Cwd ([string]$p.Path) -Continue:($Mode -eq 'continue')))
        } else {
            [void]$chunks.Add($GrokExe)
            [void]$chunks.Add('--cwd')
            [void]$chunks.Add([string]$p.Path)
            if ($Mode -eq 'continue') { [void]$chunks.Add('-c') }
        }
        $first = $false
    }
    return ConvertTo-ProcessArgumentString $chunks.ToArray()
}

function Ensure-WtHostType {
    if ('WtHost' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class WtHost {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc lpEnumFunc, IntPtr lParam);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hWnd);
  public static string ListCascadia() {
    var sb = new StringBuilder();
    EnumWindows((h, l) => {
      if (!IsWindowVisible(h) && !IsIconic(h)) return true;
      var cls = new StringBuilder(256);
      GetClassName(h, cls, cls.Capacity);
      if (cls.ToString() != "CASCADIA_HOSTING_WINDOW_CLASS") return true;
      var title = new StringBuilder(512);
      GetWindowText(h, title, title.Capacity);
      sb.Append(h.ToInt64());
      sb.Append('\t');
      sb.Append(title);
      sb.Append('\n');
      return true;
    }, IntPtr.Zero);
    return sb.ToString();
  }
  public static void Focus(IntPtr hWnd) {
    if (hWnd == IntPtr.Zero) return;
    ShowWindow(hWnd, IsIconic(hWnd) ? 9 : 5);
    SetForegroundWindow(hWnd);
  }
}
'@
}

function Get-WtWindowList {
    Ensure-WtHostType
    $rows = @()
    foreach ($ln in ([WtHost]::ListCascadia() -split "`n")) {
        $t = $ln.Trim()
        if (-not $t) { continue }
        $tab = $t.IndexOf("`t")
        if ($tab -lt 1) { continue }
        $hwnd = [IntPtr][int64]$t.Substring(0, $tab)
        $title = $t.Substring($tab + 1)
        $rows += [pscustomobject]@{ Hwnd = $hwnd; Title = $title }
    }
    return $rows
}

function Get-RunningGrokForPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    Ensure-ProcessCwdType
    foreach ($p in Get-CimInstance Win32_Process -Filter "Name='grok.exe'" -ErrorAction SilentlyContinue) {
        $exe = [string]$p.ExecutablePath
        if ($exe -and $exe -match 'Grok Bot') { continue }
        $cwd = $null
        try { $cwd = [ProcessCwd]::Get([int]$p.ProcessId) } catch { $cwd = $null }
        if (-not $cwd) {
            $cl = [string]$p.CommandLine
            if ($cl -match '--cwd\s+"([^"]+)"') { $cwd = $Matches[1] }
            elseif ($cl -match '--cwd\s+(\S+)') { $cwd = $Matches[1] }
        }
        if ($cwd -and (Test-SamePath $cwd $Path)) {
            return [pscustomobject]@{
                Pid  = [int]$p.ProcessId
                Cwd  = $cwd
            }
        }
    }
    return $null
}

function Focus-WtWindowForProject {
    param([string]$Path, [string]$Title)
    $wins = @(Get-WtWindowList)
    if ($wins.Count -eq 0) { return $false }
    $hints = @()
    if ($Title) { $hints += [string]$Title }
    if ($Path) {
        $leaf = Split-Path $Path -Leaf
        if ($leaf) { $hints += $leaf }
    }
    foreach ($hint in $hints) {
        $h = $hint.Trim()
        if ([string]::IsNullOrWhiteSpace($h) -or $h.Length -lt 2) { continue }
        foreach ($w in $wins) {
            if (-not $w.Title) { continue }
            if ($w.Title.IndexOf($h, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                [WtHost]::Focus($w.Hwnd)
                return $true
            }
        }
    }
    if ($wins.Count -eq 1) {
        [WtHost]::Focus($wins[0].Hwnd)
        return $true
    }
    return $false
}

function Invoke-Wt {
    param([Parameter(Mandatory)][string]$ArgumentString)
    $wt = Get-WtExe
    if (-not $wt) { return $false }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $wt
    $psi.Arguments = $ArgumentString
    $psi.UseShellExecute = $true
    [void][System.Diagnostics.Process]::Start($psi)
    return $true
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
        return [pscustomobject]@{ Focused = 0; Launched = 0 }
    }

    if ($existing.Count -eq 0) {
        throw '选中的目录已经不在磁盘上。'
    }

    $wt = Get-WtExe
    if ($Mode -eq 'continue' -or $Mode -eq 'new') {
        Assert-GrokProxyReady
    }
    $grok = Get-GrokExe
    $useProxy = ($Mode -ne 'terminal' -and (Get-GrokProxyEnabled))
    if ($Mode -ne 'terminal' -and -not $grok) {
        throw '找不到 grok.exe。确认已安装 Grok，并且 ~/.grok/bin 在 PATH 里。'
    }

    $focused = 0
    $toLaunch = @()
    foreach ($p in $existing) {
        if ($Mode -eq 'continue') {
            $live = Get-RunningGrokForPath $p.Path
            if ($live) {
                $hint = ''
                if ($p.PSObject.Properties.Name -contains 'LastTitle' -and $p.LastTitle) { $hint = [string]$p.LastTitle }
                elseif ($p.PSObject.Properties.Name -contains 'Title' -and $p.Title) { $hint = [string]$p.Title }
                [void](Focus-WtWindowForProject -Path $p.Path -Title $hint)
                $focused += 1
                continue
            }
        }
        $toLaunch += $p
    }

    if ($toLaunch.Count -eq 0) {
        return [pscustomobject]@{ Focused = $focused; Launched = 0 }
    }

    # Windows Terminal treats a top-level ";" as a new command. Never put ";"
    # inside a powershell -Command, or WT will try to start "& '...\grok.exe'" as a file.
    if ($wt) {
        $argStr = Build-WtNewTabArgumentString -Projects $toLaunch -Mode $Mode -GrokExe $grok -UseProxy:$useProxy
        [void](Invoke-Wt $argStr)
        Start-Sleep -Milliseconds 250
        $hint = ''
        if ($toLaunch[0].PSObject.Properties.Name -contains 'LastTitle') { $hint = [string]$toLaunch[0].LastTitle }
        [void](Focus-WtWindowForProject -Path $toLaunch[0].Path -Title $hint)
        return [pscustomobject]@{ Focused = $focused; Launched = $toLaunch.Count }
    }

    foreach ($p in $toLaunch) {
        if ($Mode -eq 'terminal') {
            Start-Process -FilePath 'powershell.exe' -WorkingDirectory $p.Path | Out-Null
            continue
        }
        if ($useProxy) {
            $inner = Build-GrokProxyInnerCommand -GrokExe $grok -Cwd $p.Path -Continue:($Mode -eq 'continue')
            Start-Process -FilePath 'cmd.exe' -ArgumentList @('/d', '/s', '/c', $inner) -WorkingDirectory $p.Path | Out-Null
        } else {
            $arg = @('--cwd', $p.Path)
            if ($Mode -eq 'continue') { $arg += '-c' }
            Start-Process -FilePath $grok -ArgumentList $arg -WorkingDirectory $p.Path | Out-Null
        }
    }
    return [pscustomobject]@{ Focused = $focused; Launched = $toLaunch.Count }
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
    [void]$argList.Add('-File')
    [void]$argList.Add($PSCommandPath)
    if ($Demo) { [void]$argList.Add('-Demo') }
    if ($Screenshot) { [void]$argList.Add('-Screenshot') }
    if ($ScreenshotWatch) { [void]$argList.Add('-ScreenshotWatch') }
    if ($ScreenshotDash) { [void]$argList.Add('-ScreenshotDash') }
    if ($LayoutCheck) { [void]$argList.Add('-LayoutCheck') }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList.ToArray() | Out-Null
    exit 0
}

function Show-ExistingLauncherWindow {
    if (-not ('NativeWnd' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class NativeWnd {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
  [DllImport("user32.dll")]
  public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")]
  public static extern bool SetForegroundWindow(IntPtr hWnd);
}
'@
    }
    $hwnd = [IntPtr]::Zero
    for ($i = 0; $i -lt 25; $i++) {
        $hwnd = [NativeWnd]::FindWindow($null, 'Grok 最近项目')
        if ($hwnd -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 200
    }
    if ($hwnd -eq [IntPtr]::Zero) { return $false }
    try {
        $showEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, 'Local\GrokRecentLauncher.show')
        [void]$showEvent.Set()
        $showEvent.Dispose()
    } catch { }
    [void][NativeWnd]::ShowWindow($hwnd, 9)
    [void][NativeWnd]::SetForegroundWindow($hwnd)
    return $true
}

$script:instanceMutex = $null
if (-not $script:ScreenshotMode -and -not $script:LayoutCheckMode) {
    $createdNew = $false
    $script:instanceMutex = New-Object System.Threading.Mutex($true, 'Local\GrokRecentLauncher.single', [ref]$createdNew)
    if (-not $createdNew) {
        try { $script:instanceMutex.Dispose() } catch { }
        $script:instanceMutex = $null
        [void](Show-ExistingLauncherWindow)
        exit 0
    }
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
  [DllImport("kernel32.dll")]
  public static extern IntPtr GetConsoleWindow();
  [DllImport("kernel32.dll")]
  public static extern uint GetConsoleProcessList(uint[] list, uint count);
  [DllImport("user32.dll")]
  public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")]
  public static extern bool SetForegroundWindow(IntPtr hWnd);
}
'@
        [NativeDpi]::SetProcessDPIAware() | Out-Null
        $con = [NativeDpi]::GetConsoleWindow()
        $plist = New-Object uint[] 8
        $ncon = [NativeDpi]::GetConsoleProcessList($plist, 8)
        if ($con -ne [IntPtr]::Zero -and $ncon -le 1) {
            [void][NativeDpi]::ShowWindow($con, 0)
        }
    } catch { }
    try {
        Add-Type -ReferencedAssemblies @('System.Windows.Forms.dll', 'System.Drawing.dll') -TypeDefinition @'
using System;
using System.Reflection;
using System.Windows.Forms;
using System.Drawing;
public static class UiUtil {
  public static void EnableDoubleBuffer(Control c) {
    if (c == null) return;
    typeof(Control).InvokeMember("DoubleBuffered",
      BindingFlags.SetProperty | BindingFlags.Instance | BindingFlags.NonPublic,
      null, c, new object[] { true });
    try {
      var setStyle = typeof(Control).GetMethod("SetStyle",
        System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic);
      if (setStyle != null) {
        var styles = ControlStyles.OptimizedDoubleBuffer
          | ControlStyles.AllPaintingInWmPaint
          | ControlStyles.ResizeRedraw;
        setStyle.Invoke(c, new object[] { styles, true });
      }
    } catch { }
  }
  public static void BufferTree(Control root) {
    if (root == null) return;
    EnableDoubleBuffer(root);
    foreach (Control child in root.Controls) BufferTree(child);
  }
}
public class QuietButton : Button {
  public QuietButton() {
    TabStop = false;
    FlatStyle = FlatStyle.Flat;
    UseVisualStyleBackColor = false;
    FlatAppearance.BorderSize = 0;
  }
  protected override bool ShowFocusCues { get { return false; } }
  protected override bool ShowKeyboardCues { get { return false; } }
  protected override void OnGotFocus(EventArgs e) {
    base.OnGotFocus(e);
    NotifyDefault(false);
  }
  protected override void WndProc(ref Message m) {
    if (m.Msg == 0x0127 || m.Msg == 0x0128) return;
    base.WndProc(ref m);
  }
}
'@
    } catch { }

    $script:config = Read-LauncherConfig
    $script:allProjects = @()
    $script:themeName = 'light'
    if ($script:config.PSObject.Properties.Name -contains 'theme' -and $script:config.theme -eq 'dark') {
        $script:themeName = 'dark'
    }
    $script:palette = Get-LauncherPalette $script:themeName
    $pal = $script:palette

    $bg = $pal.Bg
    $panel = $pal.Panel
    $toolbarBg = $pal.Toolbar
    $line = $pal.Line
    $text = $pal.Text
    $muted = $pal.Muted
    $accent = $pal.Accent
    $accentHover = $pal.AccentHover
    $select = $pal.Select
    $hover = $pal.Hover
    $danger = $pal.Danger
    $ink = $pal.Ink
    $working = $pal.Working
    $createdC = $pal.Created
    $idleC = $pal.Idle
    $uiFont = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $titleFont = New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)
    $smallFont = New-Object System.Drawing.Font('Segoe UI', 8.25)
    $rowFont = New-Object System.Drawing.Font('Segoe UI', 9.75)
    $monoFont = New-Object System.Drawing.Font('Consolas', 9)
    $heroFont = New-Object System.Drawing.Font('Consolas', 22, [System.Drawing.FontStyle]::Bold)
    $midFont = New-Object System.Drawing.Font('Consolas', 14, [System.Drawing.FontStyle]::Bold)
    $script:defaultStatusText = ''
    $script:watchFilter = 'all'
    $script:toastTimer = $null
    $script:noticeTimer = $null
    $accentPress = $pal.AccentPress
    $panelPress = $pal.PanelPress

    function New-QuietButton {
        if ('QuietButton' -as [type]) { return New-Object QuietButton }
        return New-Object System.Windows.Forms.Button
    }

    function Add-Tactile {
        param($Btn, $PressBack)
        if ($PressBack) {
            $Btn.FlatAppearance.MouseDownBackColor = $PressBack
        }
        $Btn.TabStop = $false
        $Btn.UseVisualStyleBackColor = $false
        $Btn.FlatAppearance.BorderSize = 0
        try { $Btn.NotifyDefault($false) } catch { }
        $Btn.Add_GotFocus({
                try { $this.NotifyDefault($false) } catch { }
                try { if ($this.Parent) { $this.Parent.Invalidate($this.Bounds, $true) } } catch { }
            })
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Grok 最近项目'
    $form.StartPosition = 'CenterScreen'
    $form.Size = New-Object System.Drawing.Size(1280, 880)
    $form.MinimumSize = New-Object System.Drawing.Size(1080, 780)
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

    function Hide-HostConsole {
        try {
            if (-not ('NativeDpi' -as [type])) { return }
            $c = [NativeDpi]::GetConsoleWindow()
            if ($c -eq [IntPtr]::Zero) { return }
            if ($form.IsHandleCreated -and $c -eq $form.Handle) { return }
            $plist = New-Object uint[] 8
            $ncon = [NativeDpi]::GetConsoleProcessList($plist, 8)
            if ($ncon -gt 1) { return }
            [void][NativeDpi]::ShowWindow($c, 0)
        } catch { }
    }

    function Show-FormNow {
        try { $form.Visible = $true } catch { }
        try { $form.WindowState = 'Normal' } catch { }
        try { $form.ShowInTaskbar = $true } catch { }
        try {
            if (('NativeDpi' -as [type]) -and $form.IsHandleCreated) {
                [void][NativeDpi]::ShowWindow($form.Handle, 9)
                [void][NativeDpi]::SetForegroundWindow($form.Handle)
            }
        } catch { }
        try { $form.Activate() } catch { }
    }

    $side = New-Object System.Windows.Forms.Panel
    $side.Dock = 'Left'
    $side.Width = 188
    $side.BackColor = $toolbarBg
    $content = New-Object System.Windows.Forms.Panel
    $content.Dock = 'Fill'
    $content.BackColor = $bg
    $script:content = $content
    $form.Controls.Add($content)
    $form.Controls.Add($side)

    $sideBrand = New-Object System.Windows.Forms.Label
    $sideBrand.Text = 'Grok'
    $sideBrand.Font = $titleFont
    $sideBrand.ForeColor = $text
    $sideBrand.BackColor = $toolbarBg
    $sideBrand.AutoSize = $false
    $sideBrand.SetBounds(18, 18, 150, 32)
    $side.Controls.Add($sideBrand)
    $sideHint = New-Object System.Windows.Forms.Label
    $sideHint.Text = '最近项目'
    $sideHint.Font = $smallFont
    $sideHint.ForeColor = $muted
    $sideHint.BackColor = $toolbarBg
    $sideHint.AutoSize = $false
    $sideHint.SetBounds(18, 48, 150, 18)
    $side.Controls.Add($sideHint)

    $topStack = New-Object System.Windows.Forms.Panel
    $topStack.Dock = 'Top'
    $topStack.Height = 176
    $topStack.BackColor = $bg
    $content.Controls.Add($topStack)
    $script:dashStamp = $null
    $script:ledgerStamp = $null
    $script:ledgerKey = ''
    $script:lastLedger = $null
    $script:lastUsage = $null

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
    $title.Text = '用量'
    $title.Font = $titleFont
    $title.ForeColor = $text
    $title.BackColor = $bg
    $title.Location = New-Object System.Drawing.Point(22, 14)
    $title.AutoSize = $true
    $title.UseMnemonic = $false
    $header.Controls.Add($title)

    $ver = New-Object System.Windows.Forms.Label
    $ver.Text = ('v{0}' -f $script:AppVersion)
    $ver.Font = $smallFont
    $ver.ForeColor = $muted
    $ver.BackColor = $bg
    $ver.Location = New-Object System.Drawing.Point(250, 24)
    $ver.AutoSize = $true
    $header.Controls.Add($ver)

    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = '先看总量，再看今天，再看哪个项目吃得最多'
    $subtitle.Font = $smallFont
    $subtitle.ForeColor = $muted
    $subtitle.BackColor = $bg
    $subtitle.Location = New-Object System.Drawing.Point(24, 50)
    $subtitle.AutoSize = $false
    $subtitle.Height = 20
    $subtitle.Width = 420
    $subtitle.AutoEllipsis = $true
    $header.Controls.Add($subtitle)

    $navHost = $side
    function New-TabButton {
        param([string]$Text, [int]$Top)
        $b = New-QuietButton
        $b.Text = $Text
        $b.TextAlign = 'MiddleLeft'
        $b.Padding = New-Object System.Windows.Forms.Padding(16, 0, 8, 0)
        $b.FlatStyle = 'Flat'
        $b.FlatAppearance.BorderSize = 0
        $b.FlatAppearance.MouseOverBackColor = $hover
        $b.BackColor = $toolbarBg
        $b.ForeColor = $muted
        $b.SetBounds(8, $Top, 172, 36)
        $b.Cursor = [System.Windows.Forms.Cursors]::Hand
        $b.Font = $uiFont
        $b.FlatAppearance.MouseDownBackColor = $panelPress
        Add-Tactile $b $panelPress
        $side.Controls.Add($b)
        return $b
    }
    $tabDash = New-TabButton '仪表盘' 84
    $tabProjects = New-TabButton '项目' 124
    $tabWatch = New-TabButton '监视' 164
    $tabLedger = New-TabButton '使用记录' 204
    $btnAbout = New-QuietButton
    $btnAbout.Text = '关于'
    $btnAbout.TextAlign = 'MiddleLeft'
    $btnAbout.Padding = New-Object System.Windows.Forms.Padding(16, 0, 8, 0)
    $btnAbout.FlatStyle = 'Flat'
    $btnAbout.FlatAppearance.BorderSize = 0
    $btnAbout.FlatAppearance.MouseOverBackColor = $hover
    $btnAbout.BackColor = $toolbarBg
    $btnAbout.ForeColor = $muted
    $btnAbout.SetBounds(8, 760, 172, 34)
    $btnAbout.Anchor = 'Bottom,Left'
    $btnAbout.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btnAbout.Font = $uiFont
    Add-Tactile $btnAbout $panelPress
    $side.Controls.Add($btnAbout)
    $btnTheme = New-QuietButton
    $btnTheme.Text = $(if ($script:themeName -eq 'light') { '深色' } else { '浅色' })
    $btnTheme.FlatStyle = 'Flat'
    $btnTheme.FlatAppearance.BorderSize = 1
    $btnTheme.FlatAppearance.BorderColor = $line
    $btnTheme.BackColor = $panel
    $btnTheme.ForeColor = $muted
    $btnTheme.SetBounds(18, 720, 72, 28)
    $btnTheme.Anchor = 'Bottom,Left'
    $btnTheme.Font = $smallFont
    $btnTheme.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btnTheme.FlatAppearance.MouseOverBackColor = $hover
    $btnTheme.FlatAppearance.MouseDownBackColor = $panelPress
    Add-Tactile $btnTheme $panelPress
    $side.Controls.Add($btnTheme)
    $navLine = New-Object System.Windows.Forms.Panel
    $navLine.Width = 3
    $navLine.Height = 36
    $navLine.BackColor = $accent
    $side.Controls.Add($navLine)
    $tabDash.ForeColor = $accent
    $tabDash.BackColor = $hover

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

    $searchMark = New-Object System.Windows.Forms.Panel
    $searchMark.SetBounds(8, 8, 16, 16)
    $searchMark.BackColor = $panel
    $searchHost.Controls.Add($searchMark)
    $searchMark.Add_Paint({
            param($s, $e)
            $g = $e.Graphics
            $g.SmoothingMode = 'AntiAlias'
            $pen = New-Object System.Drawing.Pen($muted, 1.4)
            $g.DrawEllipse($pen, 1, 1, 9, 9)
            $g.DrawLine($pen, 9, 9, 14, 14)
            $pen.Dispose()
        })
    $searchKbd = New-Object System.Windows.Forms.Label
    $searchKbd.Text = 'Ctrl+F'
    $searchKbd.Font = $smallFont
    $searchKbd.ForeColor = $muted
    $searchKbd.AutoSize = $true
    $searchKbd.Location = New-Object System.Drawing.Point(278, 8)
    $searchHost.Controls.Add($searchKbd)

    $search = New-Object System.Windows.Forms.TextBox
    $search.BorderStyle = 'None'
    $search.BackColor = $panel
    $search.ForeColor = $text
    $search.Font = $rowFont
    $search.Location = New-Object System.Drawing.Point(28, 8)
    $search.Width = 240
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
        $b = New-QuietButton
        $b.Text = $Text
        $b.FlatStyle = 'Flat'
        $b.FlatAppearance.BorderSize = 0
        $b.FlatAppearance.MouseOverBackColor = $HoverBack
        $pressC = $panelPress
        if ($Back.R -gt 200) { $pressC = $accentPress }
        $b.FlatAppearance.MouseDownBackColor = $pressC
        $b.BackColor = $Back
        $b.ForeColor = $Fore
        $b.Width = $Width
        $b.Height = 34
        $b.Font = $uiFont
        $b.Cursor = [System.Windows.Forms.Cursors]::Hand
        Add-Tactile $b $pressC
        $toolbar.Controls.Add($b)
        return $b
    }

    $selLabel = New-Object System.Windows.Forms.Label
    $selLabel.ForeColor = $muted
    $selLabel.Font = $smallFont
    $selLabel.AutoSize = $false
    $selLabel.AutoEllipsis = $true
    $selLabel.UseMnemonic = $false
    $selLabel.TextAlign = 'MiddleLeft'
    $selLabel.SetBounds(400, 16, 120, 22)
    $selLabel.Text = '未选择'
    $toolbar.Controls.Add($selLabel)

    $btnContinue = New-BarButton '继续最近会话' $accent $ink 118 $accentHover
    $btnNew = New-BarButton '新建会话' $panel $text 86 $hover
    $btnPick = New-BarButton '指定文件夹' $panel $text 96 $hover
    $btnTerm = New-BarButton '打开终端' $panel $text 86 $hover
    $btnFolder = New-BarButton '资源管理器' $panel $text 96 $hover
    $btnRefresh = New-BarButton '刷新' $panel $muted 56 $hover
    $btnRestart = New-BarButton '重启' $panel $muted 56 $hover
    foreach ($b in @($btnNew, $btnPick, $btnTerm, $btnFolder, $btnRefresh, $btnRestart)) {
        $b.FlatAppearance.BorderSize = 1
        $b.FlatAppearance.BorderColor = $line
    }
    $tip = New-Object System.Windows.Forms.ToolTip
    $tip.SetToolTip($btnNew, '只作用于黄色选中的那一行，在该目录新开 Grok')
    $tip.SetToolTip($btnContinue, '只作用于黄色选中的那一行，继续该目录最近一次会话')
    $tip.SetToolTip($btnPick, '弹出文件夹窗口。点一下目标文件夹，再点「选择文件夹」，Grok 就在那里打开')
    $tip.SetToolTip($btnFolder, '用资源管理器打开黄色选中行的目录')
    $tip.SetToolTip($btnTerm, '在黄色选中行的目录打开终端')
    $tip.SetToolTip($btnRefresh, '刷新当前页：项目列表、用量和账号额度')
    $tip.SetToolTip($btnRestart, '关闭并重新启动，加载最新脚本')

    function Set-SelectionCaption {
        $picked = @(Get-SelectedProjects)
        if ($picked.Count -eq 1) {
            $selLabel.Text = ('已选 1 · {0}' -f $picked[0].Label)
            try { $tip.SetToolTip($selLabel, [string]$picked[0].Path) } catch { }
        } elseif ($picked.Count -gt 1) {
            $selLabel.Text = ('已选 {0} 个项目' -f $picked.Count)
            try { $tip.SetToolTip($selLabel, '') } catch { }
        } else {
            $selLabel.Text = '未选择'
            try { $tip.SetToolTip($selLabel, '') } catch { }
        }
    }

    $proxyBar = New-Object System.Windows.Forms.Panel
    $proxyBar.SetBounds(0, 136, 1020, 40)
    $proxyBar.Anchor = 'Top,Left,Right'
    $proxyBar.BackColor = $toolbarBg
    $topStack.Controls.Add($proxyBar)
    $proxyBarLine = New-Object System.Windows.Forms.Panel
    $proxyBarLine.Dock = 'Top'
    $proxyBarLine.Height = 1
    $proxyBarLine.BackColor = $line
    $proxyBar.Controls.Add($proxyBarLine)

    $proxyGrok = New-Object System.Windows.Forms.CheckBox
    $proxyGrok.Text = '启动会话走代理'
    $proxyGrok.ForeColor = $text
    $proxyGrok.AutoSize = $true
    $proxyGrok.Location = New-Object System.Drawing.Point(22, 11)
    $proxyGrok.Checked = [bool]$script:config.proxyGrokSessions
    $proxyGrok.FlatStyle = 'Flat'
    $proxyBar.Controls.Add($proxyGrok)

    $proxyBoxHost = New-Object System.Windows.Forms.Panel
    $proxyBoxHost.Location = New-Object System.Drawing.Point(160, 6)
    $proxyBoxHost.Size = New-Object System.Drawing.Size(220, 28)
    $proxyBoxHost.BackColor = $panel
    $proxyBar.Controls.Add($proxyBoxHost)
    $proxyBox = New-Object System.Windows.Forms.TextBox
    $proxyBox.BorderStyle = 'None'
    $proxyBox.BackColor = $panel
    $proxyBox.ForeColor = $text
    $proxyBox.Font = $rowFont
    $proxyBox.Location = New-Object System.Drawing.Point(10, 6)
    $proxyBox.Width = 200
    $proxyBox.Text = [string](Get-GrokProxyEndpoint).Url
    $proxyBoxHost.Controls.Add($proxyBox)

    $proxyPill = New-Object System.Windows.Forms.Label
    $proxyPill.AutoSize = $true
    $proxyPill.Font = $smallFont
    $proxyPill.Location = New-Object System.Drawing.Point(392, 12)
    $proxyPill.ForeColor = $muted
    $proxyPill.Text = '检测中'
    $proxyBar.Controls.Add($proxyPill)

    $btnDetectProxy = New-BarButton '检测' $panel $text 56 $hover
    $toolbar.Controls.Remove($btnDetectProxy)
    $proxyBar.Controls.Add($btnDetectProxy)
    $btnDetectProxy.Width = 56
    $btnDetectProxy.Height = 28
    $btnDetectProxy.FlatAppearance.BorderSize = 1
    $btnDetectProxy.FlatAppearance.BorderColor = $line
    $tip.SetToolTip($proxyGrok, '开启后，继续/新建会话会带上右侧代理地址。不写系统环境变量。')
    $tip.SetToolTip($proxyBox, '例如 http://127.0.0.1:7890 。端口变了就点「检测」。')
    $tip.SetToolTip($btnDetectProxy, '读取系统代理和 FlClash 端口，探测本机常见端口，自动填上正在用的那个')

    $notice = New-Object System.Windows.Forms.Panel
    $notice.Visible = $false
    $notice.Height = 46
    $notice.Anchor = 'Top,Left,Right'
    $notice.BackColor = [System.Drawing.Color]::FromArgb(60, 24, 24)
    $content.Controls.Add($notice)
    $noticeBar = New-Object System.Windows.Forms.Panel
    $noticeBar.Width = 4
    $noticeBar.Dock = 'Left'
    $noticeBar.BackColor = [System.Drawing.Color]::FromArgb(239, 68, 68)
    $notice.Controls.Add($noticeBar)
    $noticeClose = New-QuietButton
    $noticeClose.Text = '知道了'
    $noticeClose.Width = 72
    $noticeClose.Height = 28
    $noticeClose.FlatStyle = 'Flat'
    $noticeClose.FlatAppearance.BorderSize = 0
    $noticeClose.ForeColor = $text
    $noticeClose.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
    $noticeClose.Cursor = [System.Windows.Forms.Cursors]::Hand
    $notice.Controls.Add($noticeClose)
    $noticeLabel = New-Object System.Windows.Forms.Label
    $noticeLabel.ForeColor = $text
    $noticeLabel.Font = $uiFont
    $noticeLabel.TextAlign = 'MiddleLeft'
    $notice.Controls.Add($noticeLabel)
    $noticeLabel.BringToFront()

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
    $grid.AlternatingRowsDefaultCellStyle.BackColor = $panel
    $grid.AlternatingRowsDefaultCellStyle.ForeColor = $text
    $grid.AlternatingRowsDefaultCellStyle.SelectionBackColor = $select
    $grid.AlternatingRowsDefaultCellStyle.SelectionForeColor = $text
    $grid.GridColor = $line
    $grid.ColumnHeadersDefaultCellStyle.BackColor = $toolbarBg
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = $muted
    $grid.ColumnHeadersDefaultCellStyle.Font = $smallFont
    $grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = $toolbarBg
    $grid.ColumnHeadersDefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(10, 0, 8, 0)
    $grid.ColumnHeadersDefaultCellStyle.WrapMode = [System.Windows.Forms.DataGridViewTriState]::False
    $content.Controls.Add($grid)
    $script:grid = $grid
    try { [UiUtil]::EnableDoubleBuffer($grid) } catch { }
    try { [UiUtil]::EnableDoubleBuffer($form) } catch { }
    try { [UiUtil]::BufferTree($form) } catch { }

    $statusHost = New-Object System.Windows.Forms.Panel
    $statusHost.Dock = 'Bottom'
    $statusHost.Height = 34
    $statusHost.BackColor = $toolbarBg
    $content.Controls.Add($statusHost)
    $statusLine = New-Object System.Windows.Forms.Panel
    $statusLine.Dock = 'Top'
    $statusLine.Height = 1
    $statusLine.BackColor = $line
    $statusHost.Controls.Add($statusLine)
    $status = New-Object System.Windows.Forms.Label
    $status.Dock = 'Fill'
    $status.ForeColor = $muted
    $status.BackColor = $toolbarBg
    $status.Font = $smallFont
    $status.TextAlign = 'MiddleLeft'
    $status.Padding = New-Object System.Windows.Forms.Padding(20, 0, 8, 0)
    $status.Text = '双击续上  ·  Enter 打开  ·  Ctrl+A 全选  ·  Esc 关闭'
    $statusHost.Controls.Add($status)
    $script:defaultStatusText = $status.Text

    $toast = New-Object System.Windows.Forms.Panel
    $toast.Height = 36
    $toast.Visible = $false
    $toast.BackColor = $panel
    $toast.Anchor = 'Bottom,Left,Right'
    $content.Controls.Add($toast)
    $toastBar = New-Object System.Windows.Forms.Panel
    $toastBar.Width = 3
    $toastBar.Dock = 'Left'
    $toastBar.BackColor = $accent
    $toast.Controls.Add($toastBar)
    $toastLabel = New-Object System.Windows.Forms.Label
    $toastLabel.Dock = 'Fill'
    $toastLabel.ForeColor = $text
    $toastLabel.Font = $smallFont
    $toastLabel.TextAlign = 'MiddleLeft'
    $toastLabel.Padding = New-Object System.Windows.Forms.Padding(12, 0, 8, 0)
    $toast.Controls.Add($toastLabel)
    $toastLabel.BringToFront()

    function Layout-Toast {
        $toast.Left = 12
        $toast.Width = [Math]::Max(200, $content.ClientSize.Width - 24)
        $toast.Top = [Math]::Max(0, $statusHost.Top - 44)
        $toast.BringToFront()
    }

    function Layout-Notice {
        $top = $topStack.Bottom + 8
        if (-not $toolbar.Visible) { $top = $header.Bottom + 8 }
        $notice.Left = 16
        $notice.Width = [Math]::Max(240, $content.ClientSize.Width - 32)
        $notice.Top = $top
        $noticeClose.Left = $notice.Width - 84
        $noticeClose.Top = 9
        $noticeLabel.SetBounds(16, 0, [Math]::Max(80, $noticeClose.Left - 24), 46)
        if ($notice.Visible) { $notice.BringToFront() }
    }

    function Hide-AppNotice {
        $notice.Visible = $false
        if ($script:noticeTimer) {
            try { $script:noticeTimer.Stop(); $script:noticeTimer.Dispose() } catch { }
            $script:noticeTimer = $null
        }
    }

    function Show-AppNotice {
        param(
            [string]$Msg,
            [ValidateSet('ok', 'warn', 'error')][string]$Kind = 'ok'
        )
        $palette = @{
            ok    = @{ Bg = [System.Drawing.Color]::FromArgb(18, 42, 32); Bar = [System.Drawing.Color]::FromArgb(52, 211, 153); Hold = 4200 }
            warn  = @{ Bg = [System.Drawing.Color]::FromArgb(52, 36, 12); Bar = $accent; Hold = 7000 }
            error = @{ Bg = [System.Drawing.Color]::FromArgb(58, 22, 22); Bar = [System.Drawing.Color]::FromArgb(248, 113, 113); Hold = 0 }
        }
        $look = $palette[$Kind]
        $notice.BackColor = $look.Bg
        $noticeBar.BackColor = $look.Bar
        $noticeLabel.Text = $Msg
        $notice.Visible = $true
        Layout-Notice
        $status.ForeColor = $look.Bar
        $status.Text = $Msg
        if ($script:noticeTimer) {
            try { $script:noticeTimer.Stop(); $script:noticeTimer.Dispose() } catch { }
            $script:noticeTimer = $null
        }
        if ([int]$look.Hold -gt 0) {
            $t = New-Object System.Windows.Forms.Timer
            $t.Interval = [int]$look.Hold
            $t.Add_Tick({
                    Hide-AppNotice
                    $status.ForeColor = $muted
                    if ($script:activePage -ne 'watch') { $status.Text = $script:defaultStatusText }
                    $this.Stop(); $this.Dispose()
                    $script:noticeTimer = $null
                })
            $script:noticeTimer = $t
            $t.Start()
        }
    }

    function Apply-DetectedProxy {
        param($Candidate, [string]$Why)
        $ep = $Candidate.Endpoint
        $script:config.proxyUrl = [string]$ep.Url
        Save-LauncherConfig $script:config
        if (-not $proxyBox.Focused) { $proxyBox.Text = $ep.Url }
        $proxyPill.ForeColor = [System.Drawing.Color]::FromArgb(52, 211, 153)
        $proxyPill.Text = ('已连通  {0}' -f $ep.Display)
        Show-AppNotice $Why -Kind warn
        Layout-Buttons
    }

    function Invoke-DetectProxy {
        param([switch]$SilentIfUnchanged)
        $current = Get-GrokProxyEndpoint
        $currentUp = Test-GrokProxyPort -HostName $current.Host -Port $current.Port -TimeoutMs 280
        if ($currentUp) {
            Sync-ProxyPill
            if (-not $SilentIfUnchanged) {
                Show-AppNotice ('当前代理 {0} 仍可用，没有改。' -f $current.Url) -Kind ok
            }
            return
        }
        $best = Find-BestGrokProxyCandidate
        if ($best) {
            Apply-DetectedProxy $best ('当前 {0} 连不上，已自动改为 {1}（{2}）。请关掉旧的 Grok 窗口再从启动器打开。' -f $current.Display, $best.Endpoint.Url, $best.Source)
            Sync-ProxyPill
            return
        }
        Sync-ProxyPill
        Show-AppNotice '没有检测到可用的本机代理。请先打开 FlClash，或手动填写地址。' -Kind error
    }

    function Sync-ProxyPill {
        $ep = Get-GrokProxyEndpoint
        if (-not $proxyBox.Focused) { $proxyBox.Text = $ep.Url }
        if (-not $proxyGrok.Checked) {
            $proxyPill.ForeColor = $muted
            $proxyPill.Text = '直连 · 国内通常连不上 Grok'
            return
        }
        if (Test-GrokProxyPort -HostName $ep.Host -Port $ep.Port) {
            $proxyPill.ForeColor = [System.Drawing.Color]::FromArgb(52, 211, 153)
            $proxyPill.Text = ('已连通  {0}' -f $ep.Display)
        } else {
            $proxyPill.ForeColor = [System.Drawing.Color]::FromArgb(248, 113, 113)
            $proxyPill.Text = ('连不上  {0}' -f $ep.Display)
        }
        Layout-Buttons
    }

    function Save-ProxyAddressFromBox {
        try {
            $ep = ConvertTo-GrokProxyEndpoint $proxyBox.Text
            $script:config.proxyUrl = $ep.Url
            Save-LauncherConfig $script:config
            $proxyBox.Text = $ep.Url
            Sync-ProxyPill
            if ($proxyGrok.Checked -and -not (Test-GrokProxyPort -HostName $ep.Host -Port $ep.Port)) {
                Show-AppNotice ('代理地址已保存，但 {0} 现在连不上。请确认 FlClash 已开，或换一个端口。' -f $ep.Display) -Kind warn
            } else {
                Show-AppNotice ('代理地址已设为 {0}' -f $ep.Url) -Kind ok
            }
        } catch {
            Show-AppNotice $_.Exception.Message -Kind error
            $proxyBox.Text = [string](Get-GrokProxyEndpoint).Url
        }
    }

    function Show-StatusFeedback {
        param([string]$Msg)
        Show-AppNotice $Msg -Kind ok
    }

    $empty = New-Object System.Windows.Forms.Label
    $empty.Text = "还没有会话记录`r`n在某个项目目录运行过 grok 之后，就会出现在这里"
    $empty.TextAlign = 'MiddleCenter'
    $empty.ForeColor = $muted
    $empty.BackColor = $bg
    $empty.Font = $uiFont
    $empty.Visible = $false
    $content.Controls.Add($empty)

    $pageWatch = New-Object System.Windows.Forms.Panel
    $pageWatch.Dock = 'Fill'
    $pageWatch.BackColor = $bg
    $pageWatch.Visible = $false
    $content.Controls.Add($pageWatch)

    $watchHint = New-Object System.Windows.Forms.Label
    $watchHint.Visible = $false
    $watchStrip = New-Object System.Windows.Forms.Panel
    $watchStrip.Dock = 'Top'
    $watchStrip.Height = 40
    $watchStrip.BackColor = $bg
    $pageWatch.Controls.Add($watchStrip)
    $script:watchFilterBtns = @{}
    $fx = 16
    $watchFilters = @(
        [pscustomobject]@{ Key = 'all'; Text = '全部' }
        [pscustomobject]@{ Key = 'working'; Text = '工作中' }
        [pscustomobject]@{ Key = 'idle'; Text = '空闲' }
        [pscustomobject]@{ Key = 'created'; Text = '刚创建' }
    )
    foreach ($wf in $watchFilters) {
        $fb = New-QuietButton
        $fb.Text = $wf.Text
        $fb.Tag = $wf.Key
        $fb.FlatStyle = 'Flat'
        $fb.FlatAppearance.BorderSize = 0
        $fb.BackColor = $panel
        $fb.ForeColor = $muted
        $fb.Height = 26
        $fb.Width = 78
        $fb.Left = $fx
        $fb.Top = 7
        $fb.Cursor = [System.Windows.Forms.Cursors]::Hand
        $fb.Font = $smallFont
        $watchStrip.Controls.Add($fb)
        $script:watchFilterBtns[$wf.Key] = $fb
        $fx += 84
        $fb.FlatAppearance.MouseOverBackColor = $hover
        $fb.FlatAppearance.MouseDownBackColor = $panelPress
        Add-Tactile $fb $panelPress
        $fb.Add_Click({
                $script:watchFilter = [string]$this.Tag
                Sync-WatchCards
            })
    }

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
    $content.Controls.Add($pageDash)

    $quotaPanel = New-Object System.Windows.Forms.Panel
    $quotaPanel.Dock = 'Fill'
    $quotaPanel.BackColor = $panel
    $quotaPanel.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
    $qCap = New-Object System.Windows.Forms.Label
    $qCap.Text = '账号额度'
    $qCap.ForeColor = $muted
    $qCap.Font = $smallFont
    $qCap.AutoSize = $false
    $qCap.SetBounds(16, 10, 72, 18)
    $quotaPanel.Controls.Add($qCap)
    $qPlan = New-Object System.Windows.Forms.Label
    $qPlan.ForeColor = $text
    $qPlan.Font = $smallFont
    $qPlan.AutoSize = $false
    $qPlan.SetBounds(90, 10, 280, 18)
    $quotaPanel.Controls.Add($qPlan)
    $qVal = New-Object System.Windows.Forms.Label
    $qVal.ForeColor = $accent
    $qVal.Font = $heroFont
    $qVal.AutoSize = $false
    $qVal.SetBounds(16, 32, 140, 36)
    $qVal.Text = '—'
    $quotaPanel.Controls.Add($qVal)
    $qHint = New-Object System.Windows.Forms.Label
    $qHint.Text = '剩余'
    $qHint.ForeColor = $muted
    $qHint.Font = $smallFont
    $qHint.AutoSize = $false
    $qHint.SetBounds(158, 46, 40, 18)
    $quotaPanel.Controls.Add($qHint)
    $qTrack = New-Object System.Windows.Forms.Panel
    $qTrack.Height = 10
    $qTrack.BackColor = $pal.Track
    $quotaPanel.Controls.Add($qTrack)
    $qFill = New-Object System.Windows.Forms.Panel
    $qFill.Height = 10
    $qFill.Left = 0
    $qFill.Top = 0
    $qFill.Width = 0
    $qFill.BackColor = $accent
    $qTrack.Controls.Add($qFill)
    $qUsed = New-Object System.Windows.Forms.Label
    $qUsed.ForeColor = $muted
    $qUsed.Font = $smallFont
    $qUsed.AutoSize = $false
    $qUsed.Height = 18
    $qUsed.Location = New-Object System.Drawing.Point(16, 78)
    $quotaPanel.Controls.Add($qUsed)
    $qEst = New-Object System.Windows.Forms.Label
    $qEst.ForeColor = $accent
    $qEst.Font = $smallFont
    $qEst.AutoSize = $false
    $qEst.Height = 18
    $qEst.Location = New-Object System.Drawing.Point(300, 78)
    $quotaPanel.Controls.Add($qEst)
    $qProducts = New-Object System.Windows.Forms.Label
    $qProducts.ForeColor = $muted
    $qProducts.Font = $smallFont
    $qProducts.AutoSize = $false
    $qProducts.Height = 18
    $qProducts.Location = New-Object System.Drawing.Point(200, 78)
    $quotaPanel.Controls.Add($qProducts)
    $qReset = New-Object System.Windows.Forms.Label
    $qReset.ForeColor = $muted
    $qReset.Font = $smallFont
    $qReset.AutoSize = $true
    $qReset.TextAlign = 'MiddleRight'
    $quotaPanel.Controls.Add($qReset)
    $qState = New-Object System.Windows.Forms.Label
    $qState.ForeColor = $muted
    $qState.Font = $smallFont
    $qState.AutoSize = $false
    $qState.AutoEllipsis = $true
    $qState.TextAlign = 'MiddleRight'
    $quotaPanel.Controls.Add($qState)
    $qRefresh = New-QuietButton
    $qRestart = New-QuietButton
    $qRestart.Text = '重启'
    $qRestart.FlatStyle = 'Flat'
    $qRestart.FlatAppearance.BorderSize = 1
    $qRestart.FlatAppearance.BorderColor = $line
    $qRestart.BackColor = $bg
    $qRestart.ForeColor = $text
    $qRestart.Size = New-Object System.Drawing.Size(52, 24)
    $qRestart.Font = $smallFont
    $qRestart.Cursor = [System.Windows.Forms.Cursors]::Hand
    $qRestart.FlatAppearance.MouseOverBackColor = $hover
    $qRestart.FlatAppearance.MouseDownBackColor = $panelPress
    Add-Tactile $qRestart $panelPress
    $quotaPanel.Controls.Add($qRestart)
    $qRefresh.Text = '刷新额度'
    $qRefresh.FlatStyle = 'Flat'
    $qRefresh.FlatAppearance.BorderSize = 1
    $qRefresh.FlatAppearance.BorderColor = $line
    $qRefresh.BackColor = $bg
    $qRefresh.ForeColor = $text
    $qRefresh.Size = New-Object System.Drawing.Size(76, 24)
    $qRefresh.Font = $smallFont
    $qRefresh.Cursor = [System.Windows.Forms.Cursors]::Hand
    $qRefresh.FlatAppearance.MouseOverBackColor = $hover
    $qRefresh.FlatAppearance.MouseDownBackColor = $panelPress
    Add-Tactile $qRefresh $panelPress
    $quotaPanel.Controls.Add($qRefresh)

    $kpiTable = New-Object System.Windows.Forms.TableLayoutPanel
    $kpiTable.Dock = 'Top'
    $kpiTable.Height = 112
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

    # heroFont / midFont already created from design tokens

    function New-KpiPanel {
        param([bool]$Hero = $false)
        $p = New-Object System.Windows.Forms.Panel
        $p.Dock = 'Fill'
        $p.BackColor = $panel
        $p.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
        $p.Padding = New-Object System.Windows.Forms.Padding(0)
        $cap = New-Object System.Windows.Forms.Label
        $cap.ForeColor = $muted
        $cap.BackColor = $panel
        $cap.Font = $smallFont
        $cap.AutoSize = $true
        $cap.Location = New-Object System.Drawing.Point(14, 10)
        $p.Controls.Add($cap)
        $val = New-Object System.Windows.Forms.Label
        $val.ForeColor = $(if ($Hero) { $accent } else { $text })
        $val.BackColor = $panel
        $val.Font = $(if ($Hero) { $heroFont } else { $midFont })
        $val.AutoSize = $true
        $val.Location = New-Object System.Drawing.Point(12, 30)
        $p.Controls.Add($val)
        $sub = New-Object System.Windows.Forms.Label
        $sub.ForeColor = $muted
        $sub.BackColor = $panel
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

    $chartPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $chartPanel.Dock = 'Top'
    $chartPanel.Height = 252
    $chartPanel.ColumnCount = 1
    $chartPanel.RowCount = 2
    $chartPanel.BackColor = $panel
    $chartPanel.Margin = New-Object System.Windows.Forms.Padding(0)
    $chartPanel.Padding = New-Object System.Windows.Forms.Padding(0)
    [void]$chartPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$chartPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 36)))
    [void]$chartPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $pageDash.Controls.Add($chartPanel)

    $rangeHost = New-Object System.Windows.Forms.Panel
    $rangeHost.Dock = 'Fill'
    $rangeHost.BackColor = $panel
    $chartPanel.Controls.Add($rangeHost, 0, 0)
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
        $rb = New-QuietButton
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
        $rb.FlatAppearance.MouseOverBackColor = $hover
        $rb.FlatAppearance.MouseDownBackColor = $panelPress
        Add-Tactile $rb $panelPress
        $rx += 74
    }

    $chartBox = New-Object System.Windows.Forms.PictureBox
    $chartBox.Dock = 'Fill'
    $chartBox.BackColor = $panel
    $chartBox.SizeMode = 'Normal'
    $chartPanel.Controls.Add($chartBox, 0, 1)

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
        $track.BackColor = $pal.Track
        $row.Controls.Add($track)
        $fill = New-Object System.Windows.Forms.Panel
        $fill.Height = 6
        $fill.Left = 0
        $fill.Top = 0
        $fill.BackColor = $accent
        $track.Controls.Add($fill)
        $row.Visible = $false
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
    $recentActions = New-Object System.Windows.Forms.FlowLayoutPanel
    $recentActions.Dock = 'Right'
    $recentActions.WrapContents = $false
    $recentActions.AutoSize = $true
    $recentActions.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $recentActions.FlowDirection = 'LeftToRight'
    $recentActions.BackColor = $panel
    $recentActions.Padding = New-Object System.Windows.Forms.Padding(0, 6, 10, 0)
    $recentActions.Margin = New-Object System.Windows.Forms.Padding(0)
    $recentHead.Controls.Add($recentActions)
    $numQuick = New-Object System.Windows.Forms.NumericUpDown
    $numQuick.Minimum = 1
    $numQuick.Maximum = 12
    $numQuick.Value = [decimal]$script:config.quickLaunchCount
    $numQuick.Visible = $false
    $recentHead.Controls.Add($numQuick)
    $btnMinus = New-QuietButton
    $btnMinus.Text = '-'
    $btnMinus.FlatStyle = 'Flat'
    $btnMinus.FlatAppearance.BorderSize = 1
    $btnMinus.FlatAppearance.BorderColor = $line
    $btnMinus.BackColor = $bg
    $btnMinus.ForeColor = $text
    $btnMinus.Size = New-Object System.Drawing.Size(22, 22)
    $btnMinus.Margin = New-Object System.Windows.Forms.Padding(0, 0, 4, 0)
    $btnMinus.Cursor = [System.Windows.Forms.Cursors]::Hand
    $recentActions.Controls.Add($btnMinus)
    $lblQuickCount = New-Object System.Windows.Forms.Label
    $lblQuickCount.Text = ('{0}' -f [int]$numQuick.Value)
    $lblQuickCount.ForeColor = $text
    $lblQuickCount.Font = $monoFont
    $lblQuickCount.TextAlign = 'MiddleCenter'
    $lblQuickCount.Size = New-Object System.Drawing.Size(22, 22)
    $lblQuickCount.Margin = New-Object System.Windows.Forms.Padding(0, 0, 4, 0)
    $recentActions.Controls.Add($lblQuickCount)
    $btnPlus = New-QuietButton
    $btnPlus.Text = '+'
    $btnPlus.FlatStyle = 'Flat'
    $btnPlus.FlatAppearance.BorderSize = 1
    $btnPlus.FlatAppearance.BorderColor = $line
    $btnPlus.BackColor = $bg
    $btnPlus.ForeColor = $text
    $btnPlus.Size = New-Object System.Drawing.Size(22, 22)
    $btnPlus.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
    $btnPlus.Cursor = [System.Windows.Forms.Cursors]::Hand
    $recentActions.Controls.Add($btnPlus)
    $btnMinus.Add_Click({
            if ($numQuick.Value -gt $numQuick.Minimum) { $numQuick.Value = $numQuick.Value - 1 }
        })
    $btnPlus.Add_Click({
            if ($numQuick.Value -lt $numQuick.Maximum) { $numQuick.Value = $numQuick.Value + 1 }
        })
    $btnMinus.FlatAppearance.MouseOverBackColor = $hover
    $btnMinus.FlatAppearance.MouseDownBackColor = $panelPress
    $btnPlus.FlatAppearance.MouseOverBackColor = $hover
    $btnPlus.FlatAppearance.MouseDownBackColor = $panelPress
    Add-Tactile $btnMinus $panelPress
    Add-Tactile $btnPlus $panelPress
    $btnQuick = New-QuietButton
    $btnQuick.FlatStyle = 'Flat'
    $btnQuick.FlatAppearance.BorderSize = 0
    $btnQuick.BackColor = $accent
    $btnQuick.ForeColor = $ink
    $btnQuick.Height = 24
    $btnQuick.Width = 148
    $btnQuick.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btnQuick.Text = ('恢复最近 {0} 个会话' -f [int]$numQuick.Value)
    $btnQuick.Margin = New-Object System.Windows.Forms.Padding(0)
    $btnQuick.FlatAppearance.MouseOverBackColor = $accentHover
    $btnQuick.FlatAppearance.MouseDownBackColor = $accentPress
    Add-Tactile $btnQuick $accentPress
    $recentActions.Controls.Add($btnQuick)
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
        $srow.Visible = $false
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
    $dashRoot.RowCount = 4
    $dashRoot.BackColor = $bg
    $dashRoot.Margin = New-Object System.Windows.Forms.Padding(0)
    $dashRoot.Padding = New-Object System.Windows.Forms.Padding(0)
    [void]$dashRoot.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$dashRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 132)))
    [void]$dashRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 112)))
    [void]$dashRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 252)))
    [void]$dashRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $quotaPanel.Dock = 'Fill'
    $kpiTable.Dock = 'Fill'
    $chartPanel.Dock = 'Fill'
    $split.Dock = 'Fill'
    $dashRoot.Controls.Add($quotaPanel, 0, 0)
    $dashRoot.Controls.Add($kpiTable, 0, 1)
    $dashRoot.Controls.Add($chartPanel, 0, 2)
    $dashRoot.Controls.Add($split, 0, 3)
    $pageDash.Controls.Add($dashRoot)
    try { [UiUtil]::BufferTree($form) } catch { }

    function Apply-OpaqueLabels {
        param($Root)
        if (-not $Root) { return }
        if ($Root -is [System.Windows.Forms.Label] -and $Root.Parent) {
            $Root.BackColor = $Root.Parent.BackColor
        }
        foreach ($child in @($Root.Controls)) { Apply-OpaqueLabels $child }
    }
    Apply-OpaqueLabels $form

    $script:ledgerRange = '7d'
    $script:ledgerModel = ''
    $ledgerCard = $panel
    $ledgerOlive = $pal.Olive
    $ledgerCopper = $pal.Copper
    $ledgerStone = $pal.Stone
    $ledgerDeep = $pal.Deep
    $ledgerNumFont = New-Object System.Drawing.Font('Consolas', 18, [System.Drawing.FontStyle]::Bold)

    $pageLedger = New-Object System.Windows.Forms.Panel
    $pageLedger.Dock = 'Fill'
    $pageLedger.BackColor = $bg
    $pageLedger.Visible = $false
    $pageLedger.Padding = New-Object System.Windows.Forms.Padding(16, 8, 16, 10)
    $content.Controls.Add($pageLedger)

    $ledgerRoot = New-Object System.Windows.Forms.TableLayoutPanel
    $ledgerRoot.Dock = 'Fill'
    $ledgerRoot.ColumnCount = 1
    $ledgerRoot.RowCount = 4
    $ledgerRoot.BackColor = $bg
    $ledgerRoot.Margin = New-Object System.Windows.Forms.Padding(0)
    [void]$ledgerRoot.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$ledgerRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 56)))
    [void]$ledgerRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 128)))
    [void]$ledgerRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 58)))
    [void]$ledgerRoot.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 42)))
    $pageLedger.Controls.Add($ledgerRoot)

    $ledgerFilters = New-Object System.Windows.Forms.Panel
    $ledgerFilters.Dock = 'Fill'
    $ledgerFilters.BackColor = $bg
    $ledgerFilters.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
    $ledgerRoot.Controls.Add($ledgerFilters, 0, 0)
    $ledgerRangeLabel = New-Object System.Windows.Forms.Label
    $ledgerRangeLabel.Text = '时间'
    $ledgerRangeLabel.ForeColor = $muted
    $ledgerRangeLabel.Font = $smallFont
    $ledgerRangeLabel.AutoSize = $true
    $ledgerRangeLabel.Location = New-Object System.Drawing.Point(2, 12)
    $ledgerFilters.Controls.Add($ledgerRangeLabel)
    $script:ledgerRangeButtons = @{}
    $rx = 44
    foreach ($def in @(
            @{ Key = 'today'; Text = '今天' }
            @{ Key = '7d'; Text = '近 7 天' }
            @{ Key = '30d'; Text = '近 30 天' }
            @{ Key = 'all'; Text = '全部' }
        )) {
        $rb = New-QuietButton
        $rb.Text = $def.Text
        $rb.Tag = $def.Key
        $rb.FlatStyle = 'Flat'
        $rb.FlatAppearance.BorderSize = 1
        $rb.FlatAppearance.BorderColor = $line
        $rb.BackColor = $ledgerCard
        $rb.ForeColor = $muted
        $rb.Height = 28
        $rb.Width = 78
        $rb.Location = New-Object System.Drawing.Point($rx, 6)
        $rb.Cursor = [System.Windows.Forms.Cursors]::Hand
        $rb.Font = $smallFont
        $rb.FlatAppearance.MouseOverBackColor = $hover
        $rb.FlatAppearance.MouseDownBackColor = $panelPress
        Add-Tactile $rb $panelPress
        $ledgerFilters.Controls.Add($rb)
        $script:ledgerRangeButtons[$def.Key] = $rb
        $rx += 84
        $rb.Add_Click({
                $script:ledgerRange = [string]$this.Tag
                Refresh-Ledger
            })
    }
    $ledgerModelLabel = New-Object System.Windows.Forms.Label
    $ledgerModelLabel.Text = '模型'
    $ledgerModelLabel.ForeColor = $muted
    $ledgerModelLabel.Font = $smallFont
    $ledgerModelLabel.AutoSize = $true
    $ledgerModelLabel.Location = New-Object System.Drawing.Point(($rx + 8), 12)
    $ledgerFilters.Controls.Add($ledgerModelLabel)
    $script:ledgerModelButtons = @()
    $mx = $ledgerModelLabel.Left + 40
    for ($mi = 0; $mi -lt 6; $mi++) {
        $mb = New-QuietButton
        $mb.Text = $(if ($mi -eq 0) { '全部模型' } else { '' })
        $mb.Tag = ''
        $mb.FlatStyle = 'Flat'
        $mb.FlatAppearance.BorderSize = 1
        $mb.FlatAppearance.BorderColor = $line
        $mb.BackColor = $ledgerCard
        $mb.ForeColor = $muted
        $mb.Height = 28
        $mb.Width = $(if ($mi -eq 0) { 84 } else { 96 })
        $mb.Location = New-Object System.Drawing.Point($mx, 6)
        $mb.Visible = ($mi -eq 0)
        $mb.Cursor = [System.Windows.Forms.Cursors]::Hand
        $mb.Font = $smallFont
        $mb.FlatAppearance.MouseOverBackColor = $hover
        $mb.FlatAppearance.MouseDownBackColor = $panelPress
        Add-Tactile $mb $panelPress
        $ledgerFilters.Controls.Add($mb)
        $script:ledgerModelButtons += $mb
        $mx += $mb.Width + 6
        $mb.Add_Click({
                $script:ledgerModel = [string]$this.Tag
                Refresh-Ledger
            })
    }

    $ledgerTabs = New-Object System.Windows.Forms.Panel
    $ledgerTabs.Dock = 'Top'
    $ledgerTabs.Height = 52
    $ledgerTabs.BackColor = $bg
    $pageLedger.Controls.Add($ledgerTabs)
    $ledgerTabHost = New-Object System.Windows.Forms.Panel
    $ledgerTabHost.SetBounds(0, 8, 460, 36)
    $ledgerTabHost.BackColor = $panel
    $ledgerTabs.Controls.Add($ledgerTabHost)
    $script:ledgerSection = 'overview'
    $script:ledgerSectionButtons = @()
    $secX = 4
    foreach ($sec in @(
            @{ Key = 'overview'; Text = '总览'; Width = 72 }
            @{ Key = 'analysis'; Text = '分析'; Width = 72 }
            @{ Key = 'detail'; Text = '请求明细'; Width = 96 }
            @{ Key = 'cost'; Text = '价格统计'; Width = 96 }
        )) {
        $sb = New-QuietButton
        $sb.Text = $sec.Text
        $sb.Tag = $sec.Key
        $sb.FlatStyle = 'Flat'
        $sb.FlatAppearance.BorderSize = 0
        $sb.BackColor = $panel
        $sb.ForeColor = $muted
        $sb.Font = $uiFont
        $sb.TextAlign = 'MiddleCenter'
        $sb.SetBounds($secX, 4, [int]$sec.Width, 28)
        $sb.Cursor = [System.Windows.Forms.Cursors]::Hand
        $sb.FlatAppearance.MouseOverBackColor = $hover
        Add-Tactile $sb $panelPress
        $ledgerTabHost.Controls.Add($sb)
        $script:ledgerSectionButtons += $sb
        $secX += [int]$sec.Width + 2
        $sb.Add_Click({
                $script:ledgerSection = [string]$this.Tag
                if ($script:lastLedger) { Refresh-Ledger -Reuse }
                else { Show-LedgerView $script:ledgerSection }
            })
    }
    $ledgerTabHost.Width = $secX + 4

    $ledgerKpi = New-Object System.Windows.Forms.TableLayoutPanel
    $ledgerKpi.Dock = 'Fill'
    $ledgerKpi.ColumnCount = 6
    $ledgerKpi.RowCount = 1
    $ledgerKpi.BackColor = $bg
    $ledgerKpi.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
    for ($ki = 0; $ki -lt 6; $ki++) {
        [void]$ledgerKpi.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 16.66)))
    }
    [void]$ledgerKpi.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $ledgerRoot.Controls.Add($ledgerKpi, 0, 1)
    $script:ledgerKpis = @{}
    $kpiDefs = @(
        @{ Key = 'turns'; Cap = '轮次' }
        @{ Key = 'total'; Cap = 'Token 总量' }
        @{ Key = 'cache'; Cap = '缓存命中' }
        @{ Key = 'reason'; Cap = '思考' }
        @{ Key = 'calls'; Cap = '模型调用' }
        @{ Key = 'cost'; Cap = '预估花费' }
    )
    for ($ki = 0; $ki -lt $kpiDefs.Count; $ki++) {
        $def = $kpiDefs[$ki]
        $card = New-Object System.Windows.Forms.Panel
        $card.Dock = 'Fill'
        $card.BackColor = $ledgerCard
        $card.Margin = New-Object System.Windows.Forms.Padding($(if ($ki -eq 0) { 0 } else { 8 }), 0, 0, 0)
        $card.Padding = New-Object System.Windows.Forms.Padding(12, 10, 10, 8)
        $cap = New-Object System.Windows.Forms.Label
        $cap.Text = $def.Cap
        $cap.ForeColor = $muted
        $cap.Font = $smallFont
        $cap.AutoSize = $false
        $cap.AutoEllipsis = $true
        $cap.SetBounds(16, 16, 150, 16)
        $card.Controls.Add($cap)
        $val = New-Object System.Windows.Forms.Label
        $val.Text = '—'
        $val.ForeColor = $text
        $val.Font = $ledgerNumFont
        $val.AutoSize = $false
        $val.AutoEllipsis = $true
        $val.SetBounds(14, 38, 160, 36)
        $card.Controls.Add($val)
        $sub = New-Object System.Windows.Forms.Label
        $sub.Text = ''
        $sub.ForeColor = $muted
        $sub.Font = $smallFont
        $sub.AutoSize = $false
        $sub.AutoEllipsis = $true
        $sub.SetBounds(16, 80, 150, 18)
        $card.Controls.Add($sub)
        if ($def.Key -eq 'total') { $val.ForeColor = $accent }
        $ledgerKpi.Controls.Add($card, $ki, 0)
        $script:ledgerKpis[$def.Key] = @{ Cap = $cap; Val = $val; Sub = $sub; Card = $card }
    }

    $ledgerSplit = New-Object System.Windows.Forms.TableLayoutPanel
    $ledgerSplit.Dock = 'Fill'
    $ledgerSplit.ColumnCount = 2
    $ledgerSplit.RowCount = 1
    $ledgerSplit.BackColor = $bg
    $ledgerSplit.Margin = New-Object System.Windows.Forms.Padding(0)
    [void]$ledgerSplit.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 64)))
    [void]$ledgerSplit.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 36)))
    [void]$ledgerSplit.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $ledgerRoot.Controls.Add($ledgerSplit, 0, 2)

    $ledgerChartCard = New-Object System.Windows.Forms.Panel
    $ledgerChartCard.Dock = 'Fill'
    $ledgerChartCard.BackColor = $ledgerCard
    $ledgerChartCard.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
    $ledgerSplit.Controls.Add($ledgerChartCard, 0, 0)
    $ledgerChartHead = New-Object System.Windows.Forms.Label
    $ledgerChartHead.Text = 'Token 趋势'
    $ledgerChartHead.ForeColor = $text
    $ledgerChartHead.Font = $uiFont
    $ledgerChartHead.Dock = 'Top'
    $ledgerChartHead.Height = 36
    $ledgerChartHead.Padding = New-Object System.Windows.Forms.Padding(16, 10, 0, 0)
    $ledgerChartCard.Controls.Add($ledgerChartHead)
    $ledgerChart = New-Object System.Windows.Forms.PictureBox
    $ledgerChart.Dock = 'Fill'
    $ledgerChart.BackColor = $ledgerCard
    $ledgerChart.SizeMode = 'Normal'
    $ledgerChartCard.Controls.Add($ledgerChart)
    $ledgerChart.BringToFront()

    $ledgerListCard = New-Object System.Windows.Forms.Panel
    $ledgerListCard.Dock = 'Fill'
    $ledgerListCard.BackColor = $ledgerCard
    $ledgerListCard.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
    $ledgerRoot.Controls.Add($ledgerListCard, 0, 3)
    $ledgerListHead = New-Object System.Windows.Forms.Label
    $ledgerListHead.Text = '最近轮次'
    $ledgerListHead.ForeColor = $text
    $ledgerListHead.Font = $uiFont
    $ledgerListHead.Dock = 'Top'
    $ledgerListHead.Height = 36
    $ledgerListHead.Padding = New-Object System.Windows.Forms.Padding(14, 8, 0, 0)
    $ledgerListCard.Controls.Add($ledgerListHead)
    $ledgerGrid = New-Object System.Windows.Forms.DataGridView
    $ledgerGrid.Dock = 'Fill'
    $ledgerGrid.BackgroundColor = $ledgerCard
    $ledgerGrid.BorderStyle = 'None'
    $ledgerGrid.CellBorderStyle = 'SingleHorizontal'
    $ledgerGrid.GridColor = $line
    $ledgerGrid.RowHeadersVisible = $false
    $ledgerGrid.AllowUserToAddRows = $false
    $ledgerGrid.AllowUserToDeleteRows = $false
    $ledgerGrid.AllowUserToResizeRows = $false
    $ledgerGrid.ReadOnly = $true
    $ledgerGrid.SelectionMode = 'FullRowSelect'
    $ledgerGrid.MultiSelect = $false
    $ledgerGrid.EnableHeadersVisualStyles = $false
    $ledgerGrid.ColumnHeadersHeight = 32
    $ledgerGrid.ColumnHeadersHeightSizeMode = 'DisableResizing'
    $ledgerGrid.RowTemplate.Height = 34
    $ledgerGrid.Font = $smallFont
    $ledgerGrid.DefaultCellStyle.BackColor = $ledgerCard
    $ledgerGrid.DefaultCellStyle.ForeColor = $text
    $ledgerGrid.DefaultCellStyle.SelectionBackColor = $select
    $ledgerGrid.DefaultCellStyle.SelectionForeColor = $text
    $ledgerGrid.ColumnHeadersDefaultCellStyle.BackColor = $ledgerCard
    $ledgerGrid.ColumnHeadersDefaultCellStyle.ForeColor = $muted
    $ledgerGrid.ColumnHeadersDefaultCellStyle.Font = $smallFont
    $ledgerGrid.ColumnHeadersDefaultCellStyle.SelectionBackColor = $ledgerCard
    $ledgerGrid.AlternatingRowsDefaultCellStyle.BackColor = $pal.Alt
    $ledgerGrid.AlternatingRowsDefaultCellStyle.ForeColor = $text
    $ledgerGrid.AlternatingRowsDefaultCellStyle.SelectionBackColor = $select
    $ledgerGrid.AlternatingRowsDefaultCellStyle.SelectionForeColor = $text
    $ledgerListCard.Controls.Add($ledgerGrid)
    $ledgerGrid.BringToFront()
    $ledgerEmpty = New-Object System.Windows.Forms.Label
    $ledgerEmpty.Text = "这段时间没有 usage.json 轮次`r`n在项目里用过 Grok 之后，会按时间出现在这里"
    $ledgerEmpty.ForeColor = $muted
    $ledgerEmpty.Font = $uiFont
    $ledgerEmpty.TextAlign = 'MiddleCenter'
    $ledgerEmpty.Dock = 'Fill'
    $ledgerEmpty.Visible = $false
    $ledgerEmpty.BackColor = $ledgerCard
    $ledgerListCard.Controls.Add($ledgerEmpty)
    function Add-LedgerColumn {
        param([string]$Name, [string]$Header, [int]$Width, [switch]$Fill, [string]$Align = 'Left')
        $idx = $ledgerGrid.Columns.Add($Name, $Header)
        $col = $ledgerGrid.Columns[$idx]
        $col.SortMode = 'NotSortable'
        $col.MinimumWidth = 56
        if ($Fill) { $col.AutoSizeMode = 'Fill' } else { $col.AutoSizeMode = 'None'; $col.Width = $Width }
        if ($Align -eq 'Right') { $col.DefaultCellStyle.Alignment = 'MiddleRight' }
        $col.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(8, 0, 8, 0)
    }
    Add-LedgerColumn 'When' '时间' 108
    Add-LedgerColumn 'Project' '项目' 120 -Fill
    Add-LedgerColumn 'Model' '模型' 110
    Add-LedgerColumn 'Input' '输入' 68 -Align Right
    Add-LedgerColumn 'Output' '输出' 68 -Align Right
    Add-LedgerColumn 'Reason' '思考' 68 -Align Right
    Add-LedgerColumn 'Cache' '缓存' 68 -Align Right
    Add-LedgerColumn 'Total' '总量' 72 -Align Right
    Add-LedgerColumn 'Cost' '花费' 72 -Align Right
    $ledgerGrid.Add_CellDoubleClick({
            param($sender, $e)
            if ($e.RowIndex -lt 0) { return }
            $rec = $ledgerGrid.Rows[$e.RowIndex].Tag
            if (-not $rec -or [string]::IsNullOrWhiteSpace([string]$rec.Path)) { return }
            if (-not (Test-Path -LiteralPath ([string]$rec.Path))) {
                [System.Windows.Forms.MessageBox]::Show(('这个目录不存在：{0}' -f $rec.Path), '使用记录') | Out-Null
                return
            }
            try {
                $proj = New-ProjectFromPath ([string]$rec.Path)
                Open-GrokProjects -Projects @($proj) -Mode 'continue'
                Show-StatusFeedback ('已续上：{0}' -f $rec.Project)
            } catch {
                [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '打开失败') | Out-Null
            }
        })

    $ledgerMixCard = New-Object System.Windows.Forms.Panel
    $ledgerMixCard.Dock = 'Fill'
    $ledgerMixCard.BackColor = $ledgerCard
    $ledgerMixCard.Margin = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
    $ledgerSplit.Controls.Add($ledgerMixCard, 1, 0)
    $ledgerMixHead = New-Object System.Windows.Forms.Label
    $ledgerMixHead.Text = 'Token 构成'
    $ledgerMixHead.ForeColor = $text
    $ledgerMixHead.Font = $uiFont
    $ledgerMixHead.AutoEllipsis = $true
    $ledgerMixHead.SetBounds(14, 12, 240, 20)
    $ledgerMixCard.Controls.Add($ledgerMixHead)
    $ledgerMixSub = New-Object System.Windows.Forms.Label
    $ledgerMixSub.Text = '输入、输出、思考、缓存读取、缓存创建'
    $ledgerMixSub.ForeColor = $muted
    $ledgerMixSub.Font = $smallFont
    $ledgerMixSub.AutoEllipsis = $true
    $ledgerMixSub.SetBounds(14, 34, 280, 18)
    $ledgerMixCard.Controls.Add($ledgerMixSub)
    $ledgerMixBody = New-Object System.Windows.Forms.Panel
    $ledgerMixBody.BackColor = $ledgerCard
    $ledgerMixBody.SetBounds(14, 60, 300, 220)
    $ledgerMixCard.Controls.Add($ledgerMixBody)
    $script:ledgerMix = @()
    $mixDefs = @(
        @{ Key = 'in'; Name = '输入'; Color = $accent }
        @{ Key = 'out'; Name = '输出'; Color = $ledgerCopper }
        @{ Key = 'reason'; Name = '思考'; Color = $ledgerOlive }
        @{ Key = 'cache'; Name = '缓存读取'; Color = $ledgerDeep }
        @{ Key = 'create'; Name = '缓存创建'; Color = $ledgerStone }
    )
    for ($zi = 0; $zi -lt $mixDefs.Count; $zi++) {
        $def = $mixDefs[$zi]
        $row = New-Object System.Windows.Forms.Panel
        $row.Height = 36
        $row.BackColor = $ledgerCard
        $row.Anchor = 'Top,Left,Right'
        $nm = New-Object System.Windows.Forms.Label
        $nm.Text = $def.Name
        $nm.ForeColor = $text
        $nm.Font = $smallFont
        $nm.AutoEllipsis = $true
        $nm.SetBounds(0, 2, 160, 16)
        $row.Controls.Add($nm)
        $track = New-Object System.Windows.Forms.Panel
        $track.BackColor = $pal.Track
        $track.SetBounds(0, 20, 160, 6)
        $row.Controls.Add($track)
        $fill = New-Object System.Windows.Forms.Panel
        $fill.BackColor = $def.Color
        $fill.SetBounds(0, 0, 0, 6)
        $track.Controls.Add($fill)
        $nums = New-Object System.Windows.Forms.Label
        $nums.ForeColor = $muted
        $nums.Font = $smallFont
        $nums.TextAlign = 'MiddleRight'
        $nums.SetBounds(168, 14, 110, 16)
        $row.Controls.Add($nums)
        $ledgerMixBody.Controls.Add($row)
        $script:ledgerMix += @{ Key = $def.Key; Name = $nm; Base = $def.Name; Row = $row; Track = $track; Fill = $fill; Nums = $nums; Pct = 0.0 }
    }

    function Layout-Ledger {
        if (-not $pageLedger.Visible) { return }
        foreach ($key in @($script:ledgerKpis.Keys)) {
            $info = $script:ledgerKpis[$key]
            $inner = [Math]::Max(80, $info.Card.ClientSize.Width - 28)
            $info.Cap.Width = $inner
            $info.Val.Width = $inner
            $info.Sub.Width = $inner
        }
        if (-not $ledgerMixCard.IsHandleCreated) { return }
        $cw = [Math]::Max(180, $ledgerMixCard.ClientSize.Width)
        $ch = [Math]::Max(120, $ledgerMixCard.ClientSize.Height)
        $ledgerMixHead.Width = $cw - 28
        $ledgerMixSub.Width = $cw - 28
        $ledgerMixBody.SetBounds(14, 58, $cw - 28, [Math]::Max(40, $ch - 70))
        $bw = [Math]::Max(160, $ledgerMixBody.ClientSize.Width)
        for ($i = 0; $i -lt $script:ledgerMix.Count; $i++) {
            $r = $script:ledgerMix[$i]
            $r.Row.SetBounds(0, $i * 44, $bw, 40)
            $trackW = [Math]::Max(48, $bw - 132)
            $r.Track.SetBounds(0, 22, $trackW, 6)
            $r.Nums.SetBounds($trackW + 8, 8, [Math]::Max(80, $bw - $trackW - 8), 18)
            $pct = 0.0
            if ($null -ne $r.Pct) { $pct = [double]$r.Pct }
            if ($pct -lt 0) { $pct = 0 }
            if ($pct -gt 100) { $pct = 100 }
            $fillW = [int]($r.Track.Width * $pct / 100.0)
            if ($pct -gt 0 -and $fillW -lt 2) { $fillW = 2 }
            $r.Fill.SetBounds(0, 0, $fillW, 6)
        }
    }

    function Show-LedgerView {
        param([string]$Name)
        if ([string]::IsNullOrWhiteSpace($Name)) { $Name = 'overview' }
        $script:ledgerSection = $Name
        foreach ($b in @($script:ledgerSectionButtons)) {
            if ([string]$b.Tag -eq $Name) { $b.ForeColor = $accent; $b.BackColor = $hover }
            else { $b.ForeColor = $muted; $b.BackColor = $bg }
        }
        $chartRow = $ledgerRoot.RowStyles[2]
        $listRow = $ledgerRoot.RowStyles[3]
        if ($Name -eq 'detail') {
            $ledgerSplit.Visible = $false
            $ledgerListCard.Visible = $true
            $chartRow.SizeType = 'Absolute'
            $chartRow.Height = 0
            $listRow.SizeType = 'Percent'
            $listRow.Height = 100
        } elseif ($Name -eq 'analysis') {
            $ledgerSplit.Visible = $true
            $ledgerChartCard.Visible = $true
            $ledgerMixCard.Visible = $true
            $ledgerListCard.Visible = $true
            $chartRow.SizeType = 'Percent'
            $chartRow.Height = 52
            $listRow.SizeType = 'Percent'
            $listRow.Height = 48
            $ledgerMixHead.Text = '按模型'
            $ledgerMixSub.Text = '这一段时间里，每个模型占了多少 Token'
            $ledgerListHead.Text = '按项目'
        } elseif ($Name -eq 'cost') {
            $ledgerSplit.Visible = $true
            $ledgerChartCard.Visible = $false
            $ledgerMixCard.Visible = $true
            $ledgerListCard.Visible = $true
            $chartRow.SizeType = 'Percent'
            $chartRow.Height = 46
            $listRow.SizeType = 'Percent'
            $listRow.Height = 54
            $ledgerMixHead.Text = '项目花费'
            $ledgerMixSub.Text = '按项目汇总估算花费'
        } else {
            $ledgerSplit.Visible = $true
            $ledgerChartCard.Visible = $true
            $ledgerMixCard.Visible = $true
            $ledgerListCard.Visible = $true
            $chartRow.SizeType = 'Percent'
            $chartRow.Height = 58
            $listRow.SizeType = 'Percent'
            $listRow.Height = 42
            $ledgerMixHead.Text = 'Token 构成'
            $ledgerMixSub.Text = '输入、输出、思考、缓存读取、缓存创建'
            $ledgerListHead.Text = '最近轮次'
        }
        try { Layout-Ledger } catch { }
    }

    function Refresh-Ledger {
        param([switch]$Reuse)
        if (-not $Reuse) { $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor }
        try {
            if ($Reuse -and $script:lastLedger) {
                $led = $script:lastLedger
            } else {
                $led = Get-UsageLedger -Range $script:ledgerRange -Model $script:ledgerModel
            }
            $known = @($led.Models)
            if ($script:ledgerModel -and ($known -notcontains $script:ledgerModel)) {
                $script:ledgerModel = ''
                $led = Get-UsageLedger -Range $script:ledgerRange -Model ''
                $known = @($led.Models)
            }
            foreach ($key in @($script:ledgerRangeButtons.Keys)) {
                $b = $script:ledgerRangeButtons[$key]
                if ($key -eq $script:ledgerRange) { $b.ForeColor = $accent; $b.BackColor = $hover }
                else { $b.ForeColor = $muted; $b.BackColor = $ledgerCard }
            }
            $allBtn = $script:ledgerModelButtons[0]
            $allBtn.Tag = ''
            $allBtn.Text = '全部模型'
            if (-not $script:ledgerModel) { $allBtn.ForeColor = $accent; $allBtn.BackColor = $hover }
            else { $allBtn.ForeColor = $muted; $allBtn.BackColor = $ledgerCard }
            $mx = $allBtn.Right + 6
            for ($i = 0; $i -lt 5; $i++) {
                $b = $script:ledgerModelButtons[$i + 1]
                if ($i -lt $known.Count) {
                    $b.Visible = $true
                    $b.Text = [string]$known[$i]
                    $b.Tag = [string]$known[$i]
                    $sz = [System.Windows.Forms.TextRenderer]::MeasureText($b.Text, $b.Font)
                    $b.Width = [Math]::Min(168, [Math]::Max(72, $sz.Width + 18))
                    $b.Left = $mx
                    $mx = $b.Right + 6
                    if ($b.Tag -eq $script:ledgerModel) { $b.ForeColor = $accent; $b.BackColor = $hover }
                    else { $b.ForeColor = $muted; $b.BackColor = $ledgerCard }
                } else {
                    $b.Visible = $false
                    $b.Tag = ''
                }
            }
            $cacheBase = [double]$led.Input + [double]$led.Cached
            $script:ledgerKpis['turns'].Val.Text = ('{0:N0}' -f $led.Turns)
            $script:ledgerKpis['turns'].Sub.Text = '每一轮一条'
            $script:ledgerKpis['total'].Val.Text = Format-TokenM $led.Total
            $script:ledgerKpis['total'].Sub.Text = ('输入 {0} · 输出 {1}' -f (Format-PctShare $led.Input $led.Total), (Format-PctShare $led.Output $led.Total))
            $script:ledgerKpis['cache'].Val.Text = Format-PctShare $led.Cached $cacheBase
            $script:ledgerKpis['cache'].Sub.Text = ('读取 {0}' -f (Format-TokenShort $led.Cached))
            $script:ledgerKpis['reason'].Val.Text = Format-PctShare $led.Reasoning $led.Total
            $script:ledgerKpis['reason'].Sub.Text = ('思考 {0}' -f (Format-TokenShort $led.Reasoning))
            $script:ledgerKpis['calls'].Val.Text = ('{0:N0}' -f $led.Calls)
            $script:ledgerKpis['calls'].Sub.Text = $(if ($known.Count -gt 0) { ('{0} 个模型' -f $known.Count) } else { '没有模型记录' })
            $script:ledgerKpis['cost'].Val.Text = $(if ($led.CostUsd -gt 0) { Format-Usd $led.CostUsd } else { '—' })
            $script:ledgerKpis['cost'].Sub.Text = 'usage.json 估算'
            $mixSum = [double]$led.Input + [double]$led.Output + [double]$led.Reasoning + [double]$led.Cached + [double]$led.CacheCreate
            if ($mixSum -lt 1) { $mixSum = 1 }
            $mixVals = @{
                in     = [double]$led.Input
                out    = [double]$led.Output
                reason = [double]$led.Reasoning
                cache  = [double]$led.Cached
                create = [double]$led.CacheCreate
            }
            foreach ($r in @($script:ledgerMix)) {
                $r.Row.Visible = $true
                if ($r.Contains('Base') -and $r.Base) { $r.Name.Text = [string]$r.Base }
                $part = [double]$mixVals[$r.Key]
                $pct = 100.0 * $part / $mixSum
                $r.Pct = $pct
                $r.Nums.Text = ('{0}   {1}' -f (Format-TokenShort $part), (Format-PctShare $part $mixSum))
            }
            if ($script:ledgerSection -eq 'analysis') {
                $byModel = @{}
                foreach ($rec in @($led.Records)) {
                    $mk = [string]$rec.Model
                    if ([string]::IsNullOrWhiteSpace($mk)) { $mk = '—' }
                    if (-not $byModel.Contains($mk)) { $byModel[$mk] = [int64]0 }
                    $byModel[$mk] = [int64]$byModel[$mk] + [int64]$rec.Total
                }
                $topModel = @($byModel.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5)
                $modelSum = [int64]0
                foreach ($p in $topModel) { $modelSum += [int64]$p.Value }
                if ($modelSum -lt 1) { $modelSum = 1 }
                for ($ci = 0; $ci -lt $script:ledgerMix.Count; $ci++) {
                    $r = $script:ledgerMix[$ci]
                    if ($ci -lt @($topModel).Count) {
                        $r.Row.Visible = $true
                        $r.Name.Text = [string]$topModel[$ci].Key
                        $pct = 100.0 * [double]$topModel[$ci].Value / [double]$modelSum
                        $r.Pct = $pct
                        $r.Nums.Text = ('{0}   {1}' -f (Format-TokenShort $topModel[$ci].Value), (Format-PctShare $topModel[$ci].Value $modelSum))
                    } else {
                        $r.Row.Visible = $false
                        $r.Pct = 0
                    }
                }
            } elseif ($script:ledgerSection -eq 'cost') {
                $byCost = @{}
                foreach ($rec in @($led.Records)) {
                    $ck = [string]$rec.Project
                    if ([string]::IsNullOrWhiteSpace($ck)) { $ck = '—' }
                    if (-not $byCost.Contains($ck)) { $byCost[$ck] = 0.0 }
                    $byCost[$ck] = [double]$byCost[$ck] + [double]$rec.CostUsd
                }
                $topCost = @($byCost.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5)
                $costSum = 0.0
                foreach ($p in $topCost) { $costSum += [double]$p.Value }
                if ($costSum -lt 0.0001) { $costSum = 1 }
                for ($ci = 0; $ci -lt $script:ledgerMix.Count; $ci++) {
                    $r = $script:ledgerMix[$ci]
                    if ($ci -lt @($topCost).Count) {
                        $r.Row.Visible = $true
                        $r.Name.Text = [string]$topCost[$ci].Key
                        $pct = 100.0 * [double]$topCost[$ci].Value / $costSum
                        $r.Pct = $pct
                        $r.Nums.Text = ('{0}   {1}' -f (Format-Usd $topCost[$ci].Value), (Format-PctShare $topCost[$ci].Value $costSum))
                    } else {
                        $r.Row.Visible = $false
                        $r.Pct = 0
                    }
                }
            }
            $ledgerGrid.Rows.Clear()
            foreach ($rec in @($led.Records)) {
                $whenText = ''
                try { $whenText = $rec.When.ToString('M/d HH:mm') } catch { $whenText = '' }
                $idx = $ledgerGrid.Rows.Add(
                    $whenText,
                    [string]$rec.Project,
                    [string]$rec.Model,
                    (Format-TokenShort $rec.Input),
                    (Format-TokenShort $rec.Output),
                    (Format-TokenShort $rec.Reasoning),
                    (Format-TokenShort $rec.Cached),
                    (Format-TokenShort $rec.Total),
                    $(if ($rec.CostUsd -gt 0) { Format-Usd $rec.CostUsd } else { '—' })
                )
                $ledgerGrid.Rows[$idx].Tag = $rec
            }
            $ledgerEmpty.Visible = ($ledgerGrid.Rows.Count -eq 0)
            if ($ledgerEmpty.Visible) { $ledgerEmpty.BringToFront() } else { $ledgerGrid.BringToFront() }
            $rangeName = switch ($script:ledgerRange) {
                'today' { '今天' }
                '30d' { '近 30 天' }
                'all' { '全部' }
                default { '近 7 天' }
            }
            $ledgerListHead.Text = ('最近轮次 · {0}' -f $led.Turns)
            $status.Text = ('{0} · {1} 轮 · Token {2} · 花费 {3}      双击一行可续上该项目' -f $rangeName, $led.Turns, (Format-TokenM $led.Total), $(if ($led.CostUsd -gt 0) { Format-Usd $led.CostUsd } else { '—' }))
            try {
                $trend = Get-UsageSnapshot -Range $script:ledgerRange
                Draw-UsageChart $trend $ledgerChart
            } catch { }
            $script:lastLedger = $led
            $script:ledgerStamp = Get-Date
            $script:ledgerKey = ($script:ledgerRange + '|' + [string]$script:ledgerModel)
            Show-LedgerView $script:ledgerSection
            Layout-Ledger
        } catch {
            try {
                $errPath = Join-Path $script:Root 'docs\last-ui-error.txt'
                [System.IO.File]::WriteAllText($errPath, $_.Exception.ToString())
            } catch { }
            $status.Text = '使用记录读取失败'
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    }

    function Show-LedgerPage {
        Begin-UiLayout
        try {
            $script:activePage = 'ledger'
            $grid.Visible = $false
            $empty.Visible = $false
            $toolbar.Visible = $false
            $proxyBar.Visible = $false
            $pageDash.Visible = $false
            $pageWatch.Visible = $false
            $topStack.Height = 78
            $pageLedger.Visible = $true
            $pageLedger.BringToFront()
            $title.Text = '使用记录'
            $subtitle.Text = '本机每一轮的 Token、缓存和花费 · 不读对话全文'
            Set-Nav 'ledger'
            if ($form.Height -lt 880) { $form.Height = 880 }
        } finally { End-UiLayout }
        $key = ($script:ledgerRange + '|' + [string]$script:ledgerModel)
        $fresh = $script:ledgerStamp -and ($script:ledgerKey -eq $key) -and (((Get-Date) - $script:ledgerStamp).TotalSeconds -lt 45)
        if (-not $fresh) { Refresh-Ledger } else { Show-LedgerView $script:ledgerSection }
    }
    try { [UiUtil]::BufferTree($pageLedger) } catch { }
    Apply-OpaqueLabels $pageLedger

    function Set-Nav {
        param([string]$Page)
        foreach ($b in @($tabDash, $tabProjects, $tabWatch, $tabLedger, $btnAbout)) {
            $b.ForeColor = $muted
            $b.BackColor = $toolbarBg
        }
        $active = $tabDash
        switch ($Page) {
            'projects' { $active = $tabProjects }
            'watch' { $active = $tabWatch }
            'ledger' { $active = $tabLedger }
            default { $active = $tabDash }
        }
        $active.ForeColor = $accent
        $active.BackColor = $hover
        $navLine.SetBounds(0, $active.Top, 3, $active.Height)
        $navLine.BringToFront()
    }

    function Layout-Quota {
        if (-not $quotaPanel.IsHandleCreated) { return }
        $w = [Math]::Max(480, $quotaPanel.ClientSize.Width)
        $qRefresh.SetBounds($w - 92, 10, 76, 24)
        $qRestart.SetBounds($w - 152, 10, 52, 24)
        $stateRight = $qRestart.Left - 12
        $stateLeft = 300
        $qState.AutoSize = $false
        $qState.AutoEllipsis = $true
        $qState.SetBounds($stateLeft, 12, [Math]::Max(60, $stateRight - $stateLeft), 20)
        $qState.TextAlign = 'MiddleRight'
        $qRestart.BringToFront()
        $qRefresh.BringToFront()
        $barLeft = 210
        $barWidth = [Math]::Max(160, $w - $barLeft - 24)
        $qTrack.SetBounds($barLeft, 48, $barWidth, 12)
        $pct = 0
        $qv = Get-QuotaView
        if ($qv) {
            $used = Get-PsProp $qv 'UsedPct'
            if ($null -ne $used) {
                try { $pct = [double]$used } catch { $pct = 0 }
            }
        }
        $qFill.SetBounds(0, 0, [int]($barWidth * [Math]::Max(0, [Math]::Min(100, $pct)) / 100.0), 12)
        $qUsed.SetBounds(16, 78, 280, 18)
        $qEst.SetBounds(300, 78, [Math]::Max(80, $w - 540), 18)
        $qProducts.SetBounds(210, 96, [Math]::Max(80, $w - 430), 18)
        $qReset.SetBounds($w - 220, 78, 204, 18)
        $qReset.TextAlign = 'MiddleRight'
        $qVal.BringToFront()
    }

    function Apply-QuotaView {
        param($View, [string]$StateText)
        $script:quotaView = $View
        if (-not $View) {
            $qVal.Text = '—'
            $qVal.ForeColor = $muted
            $qPlan.Text = ''
            $qUsed.Text = ''
            $qEst.Text = ''
            $qProducts.Text = ''
            $qReset.Text = ''
            $qState.Text = $(if ($StateText) { $StateText } else { '尚未拉取' })
            $qFill.Width = 0
            Layout-Quota
            return
        }
        $remain = $null
        try { $remain = [double]$View.RemainPct } catch { }
        if ($null -ne $remain) {
            $qVal.Text = ('{0:N0}%' -f $remain)
            if ($remain -lt 12) { $qVal.ForeColor = $danger; $qFill.BackColor = $danger }
            elseif ($remain -lt 35) { $qVal.ForeColor = $accent; $qFill.BackColor = $accent }
            else { $qVal.ForeColor = $accent; $qFill.BackColor = $accent }
        } else {
            $qVal.Text = '—'
            $qVal.ForeColor = $muted
            $qFill.BackColor = $accent
        }
        $planBits = @()
        if ($View.PlanLabel) { $planBits += [string]$View.PlanLabel }
        if ($View.EmailMask) { $planBits += [string]$View.EmailMask }
        $qPlan.Text = ($planBits -join '  ·  ')
        $window = Format-QuotaWindow $View.PeriodStart $View.PeriodEnd
        $usedName = '账单周期已用'
        if ($View.Period -eq 'weekly') { $usedName = '账单周已用' }
        elseif ($View.Period -eq 'monthly') { $usedName = '账单月已用' }
        if ($null -ne $View.UsedPct) { $qUsed.Text = ('{0} {1:N0}%' -f $usedName, [double]$View.UsedPct) }
        else { $qUsed.Text = '用量未知' }
        $estBits = @()
        $ut = Get-PsProp $View 'UsedTokens'
        $uu = Get-PsProp $View 'UsedUsd'
        if (($null -ne $ut -and [double]$ut -gt 0) -or ($null -ne $uu -and [double]$uu -gt 0)) {
            if ($window) { $estBits += ('账单周期 ' + $window) }
            else { $estBits += '账单周期本机' }
            if ($null -ne $ut -and [double]$ut -gt 0) { $estBits += (Format-TokenM $ut) }
            if ($null -ne $uu -and [double]$uu -gt 0) { $estBits += (Format-Usd $uu) }
        }
        $ru = Get-PsProp $View 'RemainUsd'
        if ($null -ne $ru -and [double]$ru -gt 0) { $estBits += ('官方剩余 {0}' -f (Format-Usd $ru)) }
        $qEst.Text = ($estBits -join '  ·  ')
        $qEst.ForeColor = $muted
        try { $tip.SetToolTip($qEst, '只统计上面这个账单周期里的本机 Token 和花费，不跟下面的「今天 / 近 7 天」走。') } catch { }
        $extra = @()
        if ($View.ProductLine) { $extra += [string]$View.ProductLine }
        $prepaid = Get-PsProp $View 'PrepaidUsd'
        $odCap = Get-PsProp $View 'OnDemandCapUsd'
        $odUsed = Get-PsProp $View 'OnDemandUsedUsd'
        if ($null -ne $prepaid -and [double]$prepaid -gt 0) { $extra += ('加购 {0}' -f (Format-Usd $prepaid)) }
        if ($null -ne $odCap -and [double]$odCap -gt 0) {
            $odLeft = [double]$odCap
            if ($null -ne $odUsed) { $odLeft = [Math]::Max(0, [double]$odCap - [double]$odUsed) }
            $extra += ('按量 {0} / {1}' -f (Format-Usd $odLeft), (Format-Usd $odCap))
        }
        $qProducts.Text = ($extra -join '  ·  ')
        $qReset.Text = $(if ($View.ResetLabel) { ($View.ResetLabel + ' 重置') } else { '' })
        if ($View.MonthLine) {
            if ($qProducts.Text) { $qProducts.Text = $View.MonthLine + '  ·  ' + $qProducts.Text }
            else { $qProducts.Text = [string]$View.MonthLine }
        }
        if ($StateText) { $qState.Text = $StateText }
        elseif ($View.Error) { $qState.Text = [string]$View.Error }
        elseif ($View.FetchedAt -and $View.FetchedAt -gt [datetime]::MinValue) { $qState.Text = (Format-Ago $View.FetchedAt) }
        else { $qState.Text = '' }
        Layout-Quota
    }

    $quotaPoll = New-Object System.Windows.Forms.Timer
    $quotaPoll.Interval = 200
    $quotaPoll.Add_Tick({
            if (-not $script:quotaHandle) { try { $quotaPoll.Stop() } catch { }; return }
            if (-not $script:quotaHandle.IsCompleted) { return }
            try { $quotaPoll.Stop() } catch { }
            Complete-QuotaJob
        })

    function Stop-QuotaJob {
        try { $quotaPoll.Stop() } catch { }
        if ($script:quotaPs) {
            try { $script:quotaPs.Stop() } catch { }
            try { $script:quotaPs.Dispose() } catch { }
            $script:quotaPs = $null
        }
        $script:quotaHandle = $null
        if ($script:quotaRunspace) {
            try { $script:quotaRunspace.Close() } catch { }
            try { $script:quotaRunspace.Dispose() } catch { }
            $script:quotaRunspace = $null
        }
        $script:quotaJob = $null
        $script:quotaBusy = $false
        try { $qRefresh.Enabled = $true } catch { }
    }

    function Complete-QuotaJob {
        $ps = $script:quotaPs
        $handle = $script:quotaHandle
        $cached = Read-QuotaCache
        $weeklyText = ''
        $monthlyText = ''
        $err = ''
        try {
            if ($ps -and $handle) {
                $outs = @($ps.EndInvoke($handle))
                if ($outs.Count -gt 0 -and $outs[0]) {
                    $out = $outs[0]
                    if ($out -is [System.Collections.IDictionary]) {
                        $weeklyText = [string]$out['Weekly']
                        $monthlyText = [string]$out['Monthly']
                        $err = [string]$out['Error']
                    } else {
                        $weeklyText = [string](Get-PsProp $out 'Weekly')
                        $monthlyText = [string](Get-PsProp $out 'Monthly')
                        $err = [string](Get-PsProp $out 'Error')
                    }
                }
                if ($ps.HadErrors) {
                    $jobErr = ($ps.Streams.Error | ForEach-Object { [string]$_ }) -join '; '
                    if (-not $weeklyText -and -not $monthlyText -and $jobErr) { $err = $jobErr }
                }
            }
        } catch {
            if (-not $err) { $err = [string]$_.Exception.Message }
        } finally {
            Stop-QuotaJob
        }
        $weekly = $null
        $monthly = $null
        try { if ($weeklyText) { $weekly = $weeklyText | ConvertFrom-Json } } catch { }
        try { if ($monthlyText) { $monthly = $monthlyText | ConvertFrom-Json } } catch { }
        if (-not $weekly -and -not $monthly) {
            $msg = '额度拉取失败'
            if ($err) { $msg = ('额度拉取失败 · {0}' -f (Format-QuotaNetError $err)) }
            if ($cached) { Apply-QuotaView $cached $msg }
            else { Apply-QuotaView $null $msg }
            return
        }
        try {
            $view = Convert-GrokBillingToQuota -Weekly $weekly -Monthly $monthly -Email ([string]$script:quotaEmail)
            Apply-QuotaView $view '正在读取本机消耗…'
            $view = Add-QuotaEstimates $view
            Save-QuotaCache $view
            Apply-QuotaView $view '刚刚同步'
        } catch {
            $msg = ('额度拉取失败 · {0}' -f (Format-QuotaNetError ([string]$_.Exception.Message)))
            if ($cached) { Apply-QuotaView $cached $msg }
            else { Apply-QuotaView $null $msg }
        }
    }

    function Start-QuotaRefresh {
        param([switch]$Force)
        if ($script:DemoMode) {
            Apply-QuotaView (Get-DemoQuotaView) '演示数据'
            return
        }
        if ($script:quotaBusy -and -not $Force) { return }
        $cached = Read-QuotaCache
        if ($cached -and -not $Force) {
            Apply-QuotaView $cached
            $age = ([datetime]::Now - $cached.FetchedAt).TotalMinutes
            if ($age -ge 0 -and $age -lt 8) { return }
        }
        $auth = Get-GrokCliAuthInfo
        if (-not $auth -or -not $auth.Token) {
            if (-not $cached) { Apply-QuotaView $null '未登录 Grok CLI' }
            else { Apply-QuotaView $cached '登录态缺失，显示缓存' }
            return
        }
        if ($cached) { Apply-QuotaView $cached '刷新中…' }
        else { Apply-QuotaView $null '正在拉取账号额度…' }
        Stop-QuotaJob
        $script:quotaBusy = $true
        $qRefresh.Enabled = $false
        $script:quotaEmail = [string]$auth.Email
        try {
            $rs = [runspacefactory]::CreateRunspace()
            $rs.ApartmentState = 'MTA'
            $rs.Open()
            $ps = [powershell]::Create()
            $ps.Runspace = $rs
            $fetch = @'
param($Token, $WeeklyUrl, $MonthlyUrl)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$headers = @{
    Authorization           = ('Bearer {0}' -f $Token)
    'x-xai-token-auth'      = 'xai-grok-cli'
    'x-grok-client-version' = '0.2.93'
    Accept                  = '*/*'
}
$out = @{ Weekly = ''; Monthly = ''; Error = '' }
try {
    $out.Weekly = [string](Invoke-WebRequest -Uri $WeeklyUrl -Headers $headers -UseBasicParsing -TimeoutSec 15).Content
} catch {
    $out.Error = [string]$_.Exception.Message
}
try {
    $out.Monthly = [string](Invoke-WebRequest -Uri $MonthlyUrl -Headers $headers -UseBasicParsing -TimeoutSec 15).Content
} catch {
    if (-not $out.Weekly) { $out.Error = [string]$_.Exception.Message }
}
$out
'@
            [void]$ps.AddScript($fetch).AddArgument([string]$auth.Token).AddArgument('https://cli-chat-proxy.grok.com/v1/billing?format=credits').AddArgument('https://cli-chat-proxy.grok.com/v1/billing')
            $script:quotaRunspace = $rs
            $script:quotaPs = $ps
            $script:quotaHandle = $ps.BeginInvoke()
            $script:quotaJob = $ps
            $quotaPoll.Start()
        } catch {
            Stop-QuotaJob
            $msg = '额度刷新未能启动'
            if ($cached) { Apply-QuotaView $cached $msg }
            else { Apply-QuotaView $null $msg }
        }
    }

    function Layout-Dash {
        if (-not $pageDash.Visible) { return }
        if (-not $form.IsHandleCreated) { return }
        try {
        Layout-Quota
        $n = [int]$numQuick.Value
        $btnQuick.Text = ('恢复最近 {0} 个会话' -f $n)
        $lblQuickCount.Text = ('{0}' -f $n)
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
            if ($r -is [hashtable]) {
                if ($r.ContainsKey('Pct') -and $null -ne $r['Pct']) { $pct = [double]$r['Pct'] }
            } elseif ($r.PSObject.Properties.Name -contains 'Pct' -and $null -ne $r.Pct) {
                $pct = [double]$r.Pct
            }
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
        $x = $rangeLabel.Right + 10
        foreach ($key in $keys) {
            $b = $script:rangeButtons[$key]
            $b.Left = $x
            $b.Top = 6
            $x += $b.Width + 4
        }
        $chartLegend.Left = [Math]::Max($x + 12, $rangeHost.ClientSize.Width - 228)
        } catch { }
    }

    function Sync-UsageChart {
        if (-not $pageDash.Visible) { return }
        if (-not $script:lastUsage) { return }
        if (-not $chartBox.IsHandleCreated) { return }
        $w = $chartBox.ClientSize.Width
        $h = $chartBox.ClientSize.Height
        if ($w -lt 40 -or $h -lt 40) { return }
        $img = $chartBox.Image
        if ($img -and $img.Width -eq $w -and $img.Height -eq $h) { return }
        Draw-UsageChart $script:lastUsage
    }

    function Begin-UiLayout {
        try { $form.SuspendLayout() } catch { }
        try { $topStack.SuspendLayout() } catch { }
        try { $header.SuspendLayout() } catch { }
        try { $pageDash.SuspendLayout() } catch { }
    }

    function End-UiLayout {
        try { $header.ResumeLayout($false) } catch { }
        try { $topStack.ResumeLayout($false) } catch { }
        try { $pageDash.ResumeLayout($false) } catch { }
        try { $form.ResumeLayout($true) } catch { }
        try { Layout-Buttons } catch { }
        if ($pageDash.Visible) { try { Sync-UsageChart } catch { } }
    }

    function Layout-Buttons {
        if (-not $form.IsHandleCreated) { return }
        $header.Width = $topStack.ClientSize.Width
        $toolbar.Width = $topStack.ClientSize.Width
        $toolbar.Top = $header.Height
        Set-Nav $script:activePage
        if ($pageDash.Visible) {
            Layout-Dash
            try { Sync-UsageChart } catch { }
        }
        $right = $toolbar.ClientSize.Width - 18
        foreach ($b in @($btnRestart, $btnRefresh, $btnFolder, $btnTerm, $btnPick, $btnNew, $btnContinue)) {
            $right -= $b.Width
            $b.Left = $right
            $b.Top = 12
            $b.Anchor = 'Top,Right'
            $right -= 8
        }
        $hideMissing.Left = [Math]::Min(376, [Math]::Max(160, $right - 220))
        $hideMissing.Top = 18
        $searchHost.Width = [Math]::Max(160, $hideMissing.Left - 36)
        $search.Width = [Math]::Max(100, $searchHost.Width - 40)
        $gapLeft = $hideMissing.Right + 10
        $gapRight = $btnContinue.Left - 10
        $gap = $gapRight - $gapLeft
        if ($gap -lt 72) {
            $selLabel.Visible = $false
        } else {
            $selLabel.Visible = $true
            $selLabel.SetBounds($gapLeft, 16, $gap, 22)
        }
        foreach ($b in @($btnContinue, $btnNew, $btnPick, $btnTerm, $btnFolder, $btnRefresh, $btnRestart)) {
            $b.BringToFront()
        }
        if ($pageLedger.Visible) { try { Layout-Ledger } catch { } }
        $proxyBar.SetBounds(0, $toolbar.Bottom, $topStack.ClientSize.Width, 40)
        $proxyGrok.Left = 22
        $proxyGrok.Top = 11
        $proxyBoxHost.Left = $proxyGrok.Right + 14
        $proxyBoxHost.Top = 6
        $btnDetectProxy.Left = $proxyBoxHost.Right + 10
        $btnDetectProxy.Top = 6
        $proxyPill.Left = $btnDetectProxy.Right + 14
        $proxyPill.Top = 12
        Layout-Notice
        $empty.Bounds = $grid.Bounds
        $subtitle.Width = [Math]::Max(160, $header.ClientSize.Width - $subtitle.Left - 24)
        try {
            $g = $header.CreateGraphics()
            $sz = $g.MeasureString($title.Text, $title.Font)
            $g.Dispose()
            $ver.Left = $title.Left + [int]$sz.Width + 8
        } catch {
            $ver.Left = $title.Left + 80
        }
        $ver.Top = 22
        Layout-Toast
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

    $form.Add_Resize({
            try { Layout-Buttons } catch { }
        })
    $form.Add_Load({
            try { Layout-Buttons } catch { }
            try { Sync-ProxyPill } catch { }
            try { Invoke-DetectProxy -SilentIfUnchanged } catch { }
        })
    $chartSyncTimer = New-Object System.Windows.Forms.Timer
    $chartSyncTimer.Interval = 40
    $chartSyncTimer.Add_Tick({
            $chartSyncTimer.Stop()
            try { Sync-UsageChart } catch { }
        })
    $chartBox.Add_Resize({
            $chartSyncTimer.Stop()
            $chartSyncTimer.Start()
        })
    Layout-Buttons

    $script:hoverRow = -1
    $grid.Add_CellFormatting({
            param($sender, $e)
            if ($e.RowIndex -lt 0 -or $e.ColumnIndex -lt 0) { return }
            $col = $grid.Columns[$e.ColumnIndex].Name
            if ($col -eq 'Pin') {
                if ([string]$e.Value -eq '★') { $e.CellStyle.ForeColor = $accent; $e.CellStyle.SelectionForeColor = $accent }
                else { $e.CellStyle.ForeColor = $muted; $e.CellStyle.SelectionForeColor = $muted }
            } elseif ($col -eq 'Path' -or $col -eq 'Ago' -or $col -eq 'Title') {
                $e.CellStyle.ForeColor = $muted
                $e.CellStyle.SelectionForeColor = $muted
            } elseif ($col -eq 'Name') {
                $e.CellStyle.ForeColor = $text
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
            $grid.Columns[$cName].FillWeight = 24
            $grid.Columns[$cAgo].FillWeight = 10
            $grid.Columns[$cCount].FillWeight = 7
            $grid.Columns[$cTitle].FillWeight = 44
            $grid.Columns[$cPath].FillWeight = 8
            $grid.Columns[$cName].DefaultCellStyle.ForeColor = $text
            $grid.Columns[$cTitle].DefaultCellStyle.ForeColor = $muted
            $grid.Columns[$cTitle].DefaultCellStyle.Font = $smallFont
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
        Set-SelectionCaption
        $status.Text = ('{0} 个项目    已选 {1}    置顶 {2}      继续最近会话作用于黄色选中行' -f `
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
            if ($script:activePage -eq 'projects') { Show-Rows }
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    }

    function Refresh-CurrentPage {
        Reload-Projects
        switch ($script:activePage) {
            'dash' {
                Refresh-Dash
                Start-QuotaRefresh -Force
            }
            'watch' {
                try { Sync-WatchCards } catch { }
            }
            'ledger' {
                Refresh-Ledger
            }
            default {
                Show-Rows
            }
        }
        Show-StatusFeedback '已刷新'
    }

    function Request-AppRestart {
        $script:restartRequested = $true
        $script:allowExit = $true
        $form.Close()
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
            $result = Open-GrokProjects -Projects $picked -Mode $Mode
            if ($script:LastProxyAutoSwitch) {
                try { Sync-ProxyPill } catch { }
                Show-AppNotice $script:LastProxyAutoSwitch -Kind warn
                return
            }
            if ($Mode -eq 'folder') { Show-StatusFeedback '已打开文件夹'; return }
            if ($result -and $result.Launched -eq 0 -and $result.Focused -gt 0) {
                Show-StatusFeedback '该项目已在运行，已切到现有终端'
            } elseif ($result -and $result.Focused -gt 0) {
                Show-StatusFeedback '已切到现有会话，其余在当前终端打开新标签'
            } else {
                Show-StatusFeedback '已在现有终端打开新标签'
            }
        } catch {
            Show-AppNotice $_.Exception.Message -Kind error
        }
    }

    function Invoke-PickDirectoryAndNew {
        $start = $null
        $picked = @(Get-SelectedProjects)
        if ($picked.Count -gt 0 -and $picked[0].Exists) { $start = $picked[0].Path }
        $wasTop = $form.TopMost
        $form.TopMost = $false
        try {
            $chosen = Select-GrokFolderPath -Owner $form -StartPath $start
        } finally {
            $form.TopMost = $wasTop
        }
        if ([string]::IsNullOrWhiteSpace($chosen)) { return }
        $proj = New-ProjectFromPath $chosen
        if (-not $proj.Exists) {
            [System.Windows.Forms.MessageBox]::Show(('这个目录不存在：{0}' -f $chosen), 'Grok 最近项目') | Out-Null
            return
        }
        $status.Text = ('正在打开：{0}' -f $proj.Path)
        try {
            Open-GrokProjects -Projects @($proj) -Mode 'new'
            if ($script:LastProxyAutoSwitch) {
                try { Sync-ProxyPill } catch { }
                Show-AppNotice $script:LastProxyAutoSwitch -Kind warn
            } else {
                Show-StatusFeedback ('已在现有终端打开：{0}' -f $proj.Path)
            }
        } catch {
            Show-AppNotice $_.Exception.Message -Kind error
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
        created = $createdC
        working = $working
        done    = $working
        idle    = $idleC
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

    function New-MiniBtn {
        param([string]$Caption, [int]$W)
        $b = New-QuietButton
        $b.Text = $Caption
        $b.FlatStyle = 'Flat'
        $b.FlatAppearance.BorderSize = 1
        $b.FlatAppearance.BorderColor = $line
        $b.BackColor = $panel
        $b.ForeColor = $text
        $b.Width = [Math]::Max(76, $W)
        $b.Height = 26
        $b.Font = $smallFont
        $b.TextAlign = 'MiddleCenter'
        $b.Padding = New-Object System.Windows.Forms.Padding(0)
        $b.Cursor = [System.Windows.Forms.Cursors]::Hand
        $b.FlatAppearance.MouseOverBackColor = $hover
        $b.FlatAppearance.MouseDownBackColor = $panelPress
        Add-Tactile $b $panelPress
        return $b
    }

    function New-WatchCard {
        param($Row)
        $card = New-Object System.Windows.Forms.Panel
        $card.Height = 56
        $card.Width = 920
        $card.BackColor = $panel
        $card.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
        $card.Tag = $Row.Pid
        $ctxLed = New-Object System.Windows.Forms.Panel
        $ctxLed.SetBounds(46, 214, 80, 12)
        $ctxLed.BackColor = $bg
        $ctxLed.Visible = $false
        $card.Controls.Add($ctxLed)
        $ctxLed.Add_Paint({
                param($s, $e)
                try {
                    $g = $e.Graphics
                    $ratio = 0.0
                    $hostCard = $s.Parent
                    if ($hostCard -and $script:watchCards -is [hashtable] -and $script:watchCards.Contains($hostCard.Tag)) {
                        $lr = $script:watchCards[$hostCard.Tag]['LastRow']
                        if ($lr) {
                            $pctLed = 0
                            try { $pctLed = [double]$lr.Progress } catch { $pctLed = 0 }
                            $ratio = [Math]::Max(0, [Math]::Min(1, $pctLed / 100.0))
                        }
                    }
                    $filled = [int][Math]::Round($ratio * 10)
                    for ($i = 0; $i -lt 10; $i++) {
                        $x = $i * 8
                        $c = [System.Drawing.Color]::FromArgb(28, 34, 46)
                        if ($i -lt $filled) {
                            if ($i -lt 3) { $c = [System.Drawing.Color]::FromArgb(16, 185, 129) }
                            elseif ($i -lt 7) { $c = [System.Drawing.Color]::FromArgb(245, 158, 11) }
                            else { $c = [System.Drawing.Color]::FromArgb(244, 63, 94) }
                        }
                        $b = New-Object System.Drawing.SolidBrush($c)
                        $g.FillRectangle($b, $x, 3, 6, 6)
                        $b.Dispose()
                    }
                } catch { }
            })

        $dot = New-Object System.Windows.Forms.Label
        $dot.Text = [char]0x25CF
        $dot.Font = New-Object System.Drawing.Font('Segoe UI', 9)
        $dot.AutoSize = $true
        $dot.Location = New-Object System.Drawing.Point(12, 10)
        $card.Controls.Add($dot)

        $chev = New-Object System.Windows.Forms.Label
        $chev.Text = [char]0x25B8
        $chev.Font = $rowFont
        $chev.ForeColor = $muted
        $chev.AutoSize = $true
        $chev.Location = New-Object System.Drawing.Point(28, 8)
        $chev.Cursor = [System.Windows.Forms.Cursors]::Hand
        $card.Controls.Add($chev)

        $name = New-Object System.Windows.Forms.Label
        $name.Font = $rowFont
        $name.ForeColor = $text
        $name.AutoSize = $false
        $name.AutoEllipsis = $true
        $name.SetBounds(46, 8, 280, 20)
        $name.Cursor = [System.Windows.Forms.Cursors]::Hand
        $card.Controls.Add($name)

        $badge = New-Object System.Windows.Forms.Label
        $badge.Font = $smallFont
        $badge.AutoSize = $true
        $badge.Location = New-Object System.Drawing.Point(160, 10)
        $card.Controls.Add($badge)

        $sub = New-Object System.Windows.Forms.Label
        $sub.Font = $smallFont
        $sub.ForeColor = $muted
        $sub.AutoSize = $false
        $sub.Height = 18
        $sub.Location = New-Object System.Drawing.Point(46, 30)
        $card.Controls.Add($sub)

        $detailBox = New-Object System.Windows.Forms.TextBox
        $detailBox.Multiline = $true
        $detailBox.ReadOnly = $true
        $detailBox.BorderStyle = 'None'
        $detailBox.BackColor = $bg
        $detailBox.ForeColor = $muted
        $detailBox.Font = $smallFont
        $detailBox.ScrollBars = 'Vertical'
        $detailBox.Visible = $false
        $detailBox.Location = New-Object System.Drawing.Point(46, 54)
        $card.Controls.Add($detailBox)

        $btnOpen = New-MiniBtn '打开' 64
        $btnTermW = New-MiniBtn '终端' 64
        $btnKill = New-MiniBtn '结束' 64
        $btnKill.ForeColor = $danger
        $card.Controls.Add($btnOpen)
        $card.Controls.Add($btnTermW)
        $card.Controls.Add($btnKill)
        $pidCopy = $Row.Pid
        $pathCopy = $Row.Path
        $btnOpen.Add_Click({
                if ([string]::IsNullOrWhiteSpace($pathCopy)) { return }
                $proj = New-ProjectFromPath $pathCopy
                if ($proj.Exists) { Open-GrokProjects -Projects @($proj) -Mode 'continue' }
            }.GetNewClosure())
        $btnTermW.Add_Click({
                if ([string]::IsNullOrWhiteSpace($pathCopy)) { return }
                $proj = New-ProjectFromPath $pathCopy
                if ($proj.Exists) { Open-GrokProjects -Projects @($proj) -Mode 'terminal' }
            }.GetNewClosure())
        $btnKill.Add_Click({
                $r = [System.Windows.Forms.MessageBox]::Show(('结束 PID {0} 的 Grok 进程？' -f $pidCopy), '结束窗口', 'YesNo')
                if ($r -ne 'Yes') { return }
                try { Stop-Process -Id $pidCopy -Force -ErrorAction Stop } catch {
                    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '结束失败') | Out-Null
                }
                Sync-WatchCards
            }.GetNewClosure())

        $watchFlow.Controls.Add($card)
        $info = @{
            Panel = $card; Dot = $dot; Chev = $chev; Name = $name; Badge = $badge
            Sub = $sub; DetailBox = $detailBox; Kind = $Row.Kind
            BtnOpen = $btnOpen; BtnTerm = $btnTermW; BtnKill = $btnKill
            LastRow = $Row; CtxLed = $ctxLed
        }
        $script:watchCards[$Row.Pid] = $info
        # Do not use GetNewClosure here: it rebinds $script: to an empty
        # module, so $script:watchExpanded.Contains() throws
        # "不能对 Null 值表达式调用方法" on label click.
        $expandClick = {
            try {
                $watchPid = $null
                try { $watchPid = [int]$this.Tag } catch { return }
                if ($watchPid -le 0) { return }
                if ($null -eq $script:watchExpanded -or $script:watchExpanded -isnot [hashtable]) { $script:watchExpanded = @{} }
                if ($null -eq $script:watchCards -or $script:watchCards -isnot [hashtable]) { $script:watchCards = @{} }
                if (-not $script:watchExpanded.Contains($watchPid)) { $script:watchExpanded[$watchPid] = $false }
                $script:watchExpanded[$watchPid] = -not [bool]$script:watchExpanded[$watchPid]
                if ($script:watchCards.Contains($watchPid) -and $script:watchCards[$watchPid] -and $script:watchCards[$watchPid]['LastRow']) {
                    Update-WatchCard $script:watchCards[$watchPid]['LastRow']
                }
            } catch {
                try { [System.IO.File]::AppendAllText($script:ErrorLog, ("{0}`r`n{1}`r`n`r`n" -f (Get-Date), $_.Exception)) } catch { }
            }
        }
        foreach ($ctl in @($card, $chev, $name, $sub, $dot)) {
            $ctl.Tag = $Row.Pid
            $ctl.Add_Click($expandClick)
        }
        Update-WatchCard $Row
        try { [UiUtil]::BufferTree($card) } catch { }
        return $info
    }

    function Update-WatchCard {
        param($Row)
        try {
            if (-not $Row) { return }
            if ($null -eq $script:watchCards -or $script:watchCards -isnot [hashtable]) { $script:watchCards = @{} }
            if ($null -eq $script:watchExpanded -or $script:watchExpanded -isnot [hashtable]) { $script:watchExpanded = @{} }
            $info = $script:watchCards[$Row.Pid]
            if (-not $info) { return }
            $kind = [string]$Row.Kind
            $kc = $kindColor[$kind]
            if (-not $kc) { $kc = $idleC }
            $kl = $kindLabel[$kind]
            if (-not $kl) { $kl = $kind }
            if ($info.Name) { $info.Name.Text = [string]$Row.Label }
            if ($info.Badge) {
                $info.Badge.Text = $kl
                $info.Badge.ForeColor = $kc
                if ($info.Name) { $info.Badge.Left = $info.Name.Right + 10 }
            }
            if ($info.Dot) { $info.Dot.ForeColor = $kc }
            $info.Kind = $kind
            $info.LastRow = $Row
            $bits = @()
            if ($Row.TaskLine) { $bits += [string]$Row.TaskLine }
            $bits += ('PID {0}' -f $Row.Pid)
            if ($Row.LastAgo) { $bits += ('最后活动 {0}' -f $Row.LastAgo) }
            if ($Row.AgeText) { $bits += [string]$Row.AgeText }
            $pct = 0
            try { $pct = [Math]::Max(0, [Math]::Min(100, [int]$Row.Progress)) } catch { $pct = 0 }
            if ($pct -gt 0) { $bits += ('Context {0}%' -f $pct) }
            if ($info.Sub) { $info.Sub.Text = ($bits -join '  ·  ') }
            $exp = $false
            if ($script:watchExpanded.Contains($Row.Pid)) { $exp = [bool]$script:watchExpanded[$Row.Pid] }
            if ($info.Chev) { $info.Chev.Text = $(if ($exp) { [char]0x25BE } else { [char]0x25B8 }) }
            $w = [Math]::Max(640, $watchFlow.ClientSize.Width - 28)
            if ($info.Panel) {
                $info.Panel.Width = $w
                $info.Panel.Height = $(if ($exp) { 236 } else { 56 })
            }
            if ($info.Sub) { $info.Sub.Width = [Math]::Max(200, $w - 220) }
            if ($info.BtnKill) { $info.BtnKill.Left = $w - 84; $info.BtnKill.Top = 12 }
            if ($info.BtnTerm) { $info.BtnTerm.Left = $w - 166; $info.BtnTerm.Top = 12 }
            if ($info.BtnOpen) {
                $info.BtnOpen.Left = $w - 248
                $info.BtnOpen.Top = 12
                $info.BtnOpen.BackColor = $panel
                $info.BtnOpen.ForeColor = $text
                $info.BtnOpen.FlatAppearance.BorderSize = 1
                $info.BtnOpen.FlatAppearance.BorderColor = $line
            }
            if ($info.Name) { $info.Name.Width = [Math]::Max(80, $info.BtnOpen.Left - $info.Name.Left - 12) }
            $dlines = New-Object System.Collections.Generic.List[string]
            if ($Row.TaskLine) { [void]$dlines.Add([string]$Row.TaskLine) }
            if ($Row.Title) { [void]$dlines.Add(('标题：{0}' -f $Row.Title)) }
            if ($Row.Detail) { [void]$dlines.Add(('摘要：{0}' -f $Row.Detail)) }
            if ($Row.CurrentTool) { [void]$dlines.Add(('正在执行：{0}' -f $Row.CurrentTool)) }
            $rt = @()
            try {
                if ($Row.PSObject.Properties.Name -contains 'RecentTools' -and $Row.RecentTools) {
                    $rt = @($Row.RecentTools)
                }
            } catch { $rt = @() }
            if ($rt.Count -gt 0) {
                [void]$dlines.Add('最近工具：')
                foreach ($t in $rt) { [void]$dlines.Add(('  {0}' -f $t)) }
            }
            $toolN = 0; $turnN = 0
            try { $toolN = [int]$Row.ToolCount } catch { }
            try { $turnN = [int]$Row.TurnCount } catch { }
            [void]$dlines.Add(('模型 {0} · 工具 {1} · 回合 {2} · Token {3} · Context {4}%' -f `
                        $(if ($Row.Model) { $Row.Model } else { '—' }),
                        $toolN, $turnN,
                        $(if ($Row.TokenM) { $Row.TokenM } else { '—' }),
                        $pct))
            if ($Row.Path) { [void]$dlines.Add(('目录：{0}' -f $Row.Path)) }
            if ($Row.SessionId) { [void]$dlines.Add(('会话：{0}' -f $Row.SessionId)) }
            if ($info.DetailBox) {
                $info.DetailBox.Text = ($dlines -join [Environment]::NewLine)
                $info.DetailBox.Visible = $exp
                $info.DetailBox.SetBounds(46, 54, [Math]::Max(200, $w - 70), 150)
            }
            if ($info.CtxLed) {
                $info.CtxLed.Visible = $exp
                $info.CtxLed.SetBounds(46, 210, 90, 14)
                $info.CtxLed.Invalidate()
            }
        } catch {
            try { [System.IO.File]::AppendAllText($script:ErrorLog, ("{0}`r`n{1}`r`n`r`n" -f (Get-Date), $_.Exception)) } catch { }
        }
    }

    function Sync-WatchCards {
        try {
            if ($null -eq $script:watchCards -or $script:watchCards -isnot [hashtable]) { $script:watchCards = @{} }
            if ($null -eq $script:watchExpanded -or $script:watchExpanded -isnot [hashtable]) { $script:watchExpanded = @{} }
            if ($null -eq $script:watchFilterBtns -or $script:watchFilterBtns -isnot [hashtable]) { $script:watchFilterBtns = @{} }
            $rows = if ($script:DemoMode) { @(Get-DemoLiveWindows) } else { @(Get-LiveGrokWindows) }
            $live = New-Object 'System.Collections.Generic.HashSet[int]'
            foreach ($row in $rows) {
                [void]$live.Add([int]$row.Pid)
                if (-not $script:watchCards.Contains($row.Pid)) {
                    New-WatchCard $row | Out-Null
                } else {
                    Update-WatchCard $row
                }
                $show = ($script:watchFilter -eq 'all' -or $row.Kind -eq $script:watchFilter)
                if ($script:watchCards.Contains($row.Pid) -and $script:watchCards[$row.Pid] -and $script:watchCards[$row.Pid].Panel) {
                    $script:watchCards[$row.Pid].Panel.Visible = $show
                }
            }
            $dead = @()
            foreach ($cardId in @($script:watchCards.Keys)) {
                if (-not $live.Contains([int]$cardId)) { $dead += $cardId }
            }
            foreach ($cardId in $dead) {
                $info = $script:watchCards[$cardId]
                if ($info -and $info.Contains('Pic') -and $info.Pic -and $info.Pic.Image) { $info.Pic.Image.Dispose() }
                if ($info -and $info.Panel) {
                    $watchFlow.Controls.Remove($info.Panel)
                    $info.Panel.Dispose()
                }
                $script:watchCards.Remove($cardId)
            }
            $n = $rows.Count
            $working = @($rows | Where-Object { $_.Kind -eq 'working' }).Count
            $idleN = @($rows | Where-Object { $_.Kind -eq 'idle' }).Count
            $createdN = @($rows | Where-Object { $_.Kind -eq 'created' }).Count
            if ($script:watchFilterBtns.Contains('all') -and $script:watchFilterBtns['all']) { $script:watchFilterBtns['all'].Text = ('全部 {0}' -f $n) }
            if ($script:watchFilterBtns.Contains('working') -and $script:watchFilterBtns['working']) { $script:watchFilterBtns['working'].Text = ('工作中 {0}' -f $working) }
            if ($script:watchFilterBtns.Contains('idle') -and $script:watchFilterBtns['idle']) { $script:watchFilterBtns['idle'].Text = ('空闲 {0}' -f $idleN) }
            if ($script:watchFilterBtns.Contains('created') -and $script:watchFilterBtns['created']) { $script:watchFilterBtns['created'].Text = ('刚创建 {0}' -f $createdN) }
            foreach ($fk in @($script:watchFilterBtns.Keys)) {
                $fb = $script:watchFilterBtns[$fk]
                if (-not $fb) { continue }
                if ($fk -eq $script:watchFilter) { $fb.ForeColor = $accent; $fb.BackColor = $hover }
                else { $fb.ForeColor = $muted; $fb.BackColor = $panel }
            }
            $watchEmpty.Visible = ($n -eq 0)
            if ($watchEmpty.Visible) { $watchEmpty.BringToFront() } else { $watchFlow.BringToFront() }
            $status.Text = ('{0} 个窗口 · 工作中 {1} · 空闲 {2}      点开一行看正在执行的工具' -f $n, $working, $idleN)
        } catch {
            try { [System.IO.File]::AppendAllText($script:ErrorLog, ("{0}`r`n{1}`r`n`r`n" -f (Get-Date), $_.Exception)) } catch { }
        }
    }

    function Show-ProjectsPage {
        Begin-UiLayout
        try {
            $script:activePage = 'projects'
            $pageWatch.Visible = $false
            $pageDash.Visible = $false
            $pageLedger.Visible = $false
            $empty.Visible = $false
            $toolbar.Visible = $true
            $proxyBar.Visible = $true
            $topStack.Height = 176
            $title.Text = '最近的 Grok 项目'
            $subtitle.Text = '从本机会话找回目录 · 多选后一次在 Windows Terminal 打开'
            $grid.Visible = $true
            $grid.BringToFront()
            Set-Nav 'projects'
        } finally { End-UiLayout }
        Show-Rows
        $status.Text = '双击续上  ·  Enter 打开  ·  文件夹 = 选路径后新开 Grok'
    }

    function Show-WatchPage {
        Begin-UiLayout
        try {
            $script:activePage = 'watch'
            $grid.Visible = $false
            $empty.Visible = $false
            $toolbar.Visible = $false
            $proxyBar.Visible = $false
            $pageDash.Visible = $false
            $pageLedger.Visible = $false
            $topStack.Height = 78
            $pageWatch.Visible = $true
            $pageWatch.BringToFront()
            $title.Text = '监视 Grok 窗口'
            $subtitle.Text = '点开一行展开正在执行的工具和最近动作'
            Set-Nav 'watch'
            if ($form.Height -lt 560) { $form.Height = 560 }
            $status.Text = '正在读取窗口…'
        } finally { End-UiLayout }
        if ($script:ScreenshotWatchMode -or $script:LayoutCheckMode) {
            Sync-WatchCards
        } else {
            if (-not $script:watchKick) {
                $script:watchKick = New-Object System.Windows.Forms.Timer
                $script:watchKick.Interval = 1
                $script:watchKick.Add_Tick({
                        $script:watchKick.Stop()
                        if ($script:activePage -eq 'watch') { Sync-WatchCards }
                    })
            }
            $script:watchKick.Stop()
            $script:watchKick.Start()
        }
        if ($script:ScreenshotWatchMode) {
            foreach ($k in @($script:watchCards.Keys)) {
                $lr = $script:watchCards[$k].LastRow
                if ($lr -and $lr.Kind -eq 'working') {
                    $script:watchExpanded[$k] = $true
                    Update-WatchCard $lr
                    break
                }
            }
        }
        Layout-Buttons
    }

    function Draw-UsageChart {
        param($Snap, $Box)
        if (-not $Box) { $Box = $chartBox }
        if (-not $Box.IsHandleCreated) { return }
        $w = $Box.ClientSize.Width
        $h = $Box.ClientSize.Height
        if ($w -lt 80 -or $h -lt 60) { return }
        $hoverNow = -1
        if ($Box.Tag -and $Box.Tag.ContainsKey('Hover')) { $hoverNow = [int]$Box.Tag.Hover }
        $bmp = New-Object System.Drawing.Bitmap $w, $h
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = 'AntiAlias'
        $g.Clear($panel)
        $days = @($Snap.Days)
        $mutedBr = New-Object System.Drawing.SolidBrush $muted
        $barBr = New-Object System.Drawing.SolidBrush $script:palette.ChartBar
        $peakBr = New-Object System.Drawing.SolidBrush $accent
        $gridPen = New-Object System.Drawing.Pen $script:palette.ChartGrid
        $padL = 52; $padB = 28; $padT = 16; $padR = 18
        $plotW = $w - $padL - $padR
        $plotH = $h - $padT - $padB
        $geom = $null
        if ($days.Count -eq 0) {
            $g.DrawString('这段时间没有 usage.json 记录', $smallFont, $mutedBr, 20, 60)
        } else {
            $rawMax = ($days | Measure-Object -Property Total -Maximum).Maximum
            if ($rawMax -le 0) { $rawMax = 1 }
            $max = Get-NiceCeiling ($rawMax * 1.35)
            $n = $days.Count
            $slot = $plotW / [double]$n
            $bw = [int][Math]::Round($slot * 0.34)
            if ($bw -gt 16) { $bw = 16 }
            if ($bw -lt 3) { $bw = 3 }
            $geom = @{ PadL = $padL; Slot = $slot; N = $n; Days = $days }
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
                $x = $padL + [int]($i * $slot) + [int](($slot - $bw) / 2)
                $bh = [int]($plotH * ([double]$day.Total / $max))
                if ($bh -lt 2 -and $day.Total -gt 0) { $bh = 2 }
                $y = $padT + $plotH - $bh
                $useBr = $(if ($i -eq $peakI) { $peakBr } else { $barBr })
                $g.FillRectangle($useBr, $x, $y, $bw, $bh)
                $xLabel = $x
                if ($day.PSObject.Properties.Name -contains 'Hour') {
                    if (($day.Hour % 3) -eq 0) {
                        $g.DrawString(('{0:00}' -f $day.Hour), $smallFont, $mutedBr, $xLabel, $h - 20)
                    }
                } else {
                    $g.DrawString($day.Date.ToString('M/d'), $smallFont, $mutedBr, $xLabel, $h - 20)
                }
            }
            $hi = $hoverNow
            if ($script:ScreenshotMode) { $hi = -1 }
            if ($hi -ge 0 -and $hi -lt $n) {
                $day = $days[$hi]
                $prev = [int64]0
                if ($hi -gt 0) { $prev = [int64]$days[$hi - 1].Total }
                $wow = Format-Wow $day.Total $prev
                $boxW = 228; $boxH = 86
                $bx = [Math]::Min($w - $boxW - 8, $padL + [int]($hi * $slot) + 20)
                $by = 8
                $bgb = New-Object System.Drawing.SolidBrush $script:palette.Tip
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
        $old = $Box.Image
        $Box.Image = $bmp
        if ($old) { $old.Dispose() }
        $Box.Tag = @{ Hover = $hoverNow; Geom = $geom; Snap = $Snap }
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
        $kpiHero.Sub.Text = '只跟这里选的时间走，不是上面的账单周'
        $kpiIn.Val.Text = Format-TokenM $snap.Input
        $kpiIn.Sub.Text = Format-PctShare $snap.Input $snap.Total
        $kpiOut.Val.Text = Format-TokenM $snap.Output
        $kpiOut.Sub.Text = Format-PctShare $snap.Output $snap.Total
        $activeN = 0
        if ($snap.PSObject.Properties.Name -contains 'Active') { $activeN = [int]$snap.Active }
        if ($range -eq 'today') {
            $kpiToday.Cap.Text = '今日会话'
            $kpiToday.Val.Text = ('{0}' -f $snap.Sessions)
            $kpiToday.Sub.Text = ''
            $kpiMeta.Cap.Text = '活跃项目'
            $kpiMeta.Val.Text = ('{0}' -f $activeN)
            $kpiMeta.Sub.Text = ('{0} 个窗口' -f $snap.Windows)
        } else {
            $kpiToday.Cap.Text = '今日用量'
            $kpiToday.Val.Text = Format-TokenM $snap.Today
            $kpiToday.Sub.Text = $(if ($snap.Today -gt 0) { '今天仍在进行' } else { '今天还没有用量' })
            $kpiMeta.Cap.Text = '会话'
            $kpiMeta.Val.Text = ('{0}' -f $snap.Sessions)
            $kpiMeta.Sub.Text = ('{0} 个会话 · {1} 个窗口' -f $snap.Sessions, $snap.Windows)
        }
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
                $r.Fill.BackColor = $accent
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
        $model = $snap.Model
        if ([string]::IsNullOrWhiteSpace($model)) { $model = '—' }
        $status.Text = ('用量来自本机 usage.json · 单位 M · {0}' -f $model)
        $script:dashStamp = Get-Date
        try { Layout-Dash } catch { }
        try { Sync-UsageChart } catch { }
        } catch {
            $errPath = Join-Path $script:Root 'docs\last-ui-error.txt'
            try { [System.IO.File]::WriteAllText($errPath, $_.Exception.ToString()) } catch { }
        }
    }

    function Show-DashPage {
        Begin-UiLayout
        try {
            $script:activePage = 'dash'
            $grid.Visible = $false
            $empty.Visible = $false
            $toolbar.Visible = $false
            $proxyBar.Visible = $false
            $pageWatch.Visible = $false
            $pageLedger.Visible = $false
            $topStack.Height = 78
            $pageDash.Visible = $true
            $pageDash.BringToFront()
            $title.Text = '用量'
            $subtitle.Text = '先看账号额度，再看本机 Token，再看哪个项目吃得最多'
            Set-Nav 'dash'
            if ($form.Height -lt 880) { $form.Height = 880 }
        } finally { End-UiLayout }
        if ($script:allProjects.Count -eq 0) { Reload-Projects }
        $fresh = $script:lastUsage -and $script:dashStamp -and (((Get-Date) - $script:dashStamp).TotalSeconds -lt 45)
        if (-not $fresh) { Refresh-Dash } else { try { Draw-UsageChart $script:lastUsage $chartBox } catch { } }
        Start-QuotaRefresh
        try { Sync-UsageChart } catch { }
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

    $btnDetectProxy.Add_Click({
            try { Invoke-DetectProxy } catch {
                Show-AppNotice $_.Exception.Message -Kind error
            }
        })

    $proxyGrok.Add_CheckedChanged({
            $script:config.proxyGrokSessions = $proxyGrok.Checked
            Save-LauncherConfig $script:config
            Sync-ProxyPill
            $ep = Get-GrokProxyEndpoint
            if ($proxyGrok.Checked) {
                if (Test-GrokProxyPort -HostName $ep.Host -Port $ep.Port) {
                    Show-AppNotice ('已开启：继续/新建会话走 {0}' -f $ep.Url) -Kind ok
                } else {
                    Show-AppNotice ('已开启走代理，但 {0} 现在连不上。先开 FlClash，或改右边的地址。现在启动会话会被拦住。' -f $ep.Display) -Kind error
                }
            } else {
                Show-AppNotice '已关闭走代理：启动会话将直连，国内通常连不上 Grok。' -Kind warn
            }
        })

    $proxyBox.Add_KeyDown({
            param($sender, $e)
            if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
                $e.SuppressKeyPress = $true
                Save-ProxyAddressFromBox
            }
        })
    $proxyBox.Add_Leave({ Save-ProxyAddressFromBox })
    $noticeClose.Add_Click({
            Hide-AppNotice
            $status.ForeColor = $muted
            if ($script:activePage -ne 'watch') { $status.Text = $script:defaultStatusText }
        })

    $btnAbout.Add_Click({
            $msg = @(
                ('Grok 最近项目启动器  v{0}' -f $script:AppVersion)
                ''
                '项目列表只读 ~/.grok/sessions 的 summary.json。'
                '使用记录只读 usage.json 的计数和花费，不读对话全文。'
                '首页额度用本机已登录的 Grok CLI 向 xAI billing 查询，'
                '凭证不写进仓库、不出现在日志。'
                ''
                '「启动会话走代理」只影响本启动器拉起的会话，'
                '地址可改，不写系统环境变量。'
                ''
                '置顶等偏好保存在：'
                $script:DataDir
            ) -join [Environment]::NewLine
            [System.Windows.Forms.MessageBox]::Show($msg, '关于') | Out-Null
        })

    $btnContinue.Add_Click({ Invoke-Open 'continue' })
    $btnNew.Add_Click({ Invoke-Open 'new' })
    $btnPick.Add_Click({ Invoke-PickDirectoryAndNew })
    $btnTerm.Add_Click({ Invoke-Open 'terminal' })
    $btnFolder.Add_Click({ Invoke-Open 'folder' })
    $btnRefresh.Add_Click({ Refresh-CurrentPage })
    $btnRestart.Add_Click({ Request-AppRestart })
    $qRestart.Add_Click({ Request-AppRestart })
    $tabDash.Add_Click({ Show-DashPage })
    $tabProjects.Add_Click({ Show-ProjectsPage })
    $tabWatch.Add_Click({ Show-WatchPage })
    $tabLedger.Add_Click({ Show-LedgerPage })
    foreach ($rb in @($script:rangeButtons.Values)) {
        $rb.Add_Click({
                $script:config.usageRange = [string]$this.Tag
                Save-LauncherConfig $script:config
                Refresh-Dash
            })
    }
    $qRefresh.Add_Click({ Start-QuotaRefresh -Force })
    $tip.SetToolTip($qRefresh, '重新向 xAI 拉取账号额度')
    $tip.SetToolTip($qRestart, '关闭并重新启动，加载最新脚本')
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
                Show-StatusFeedback ('已恢复 {0} 个会话' -f $ready.Count)
            } catch {
                Show-AppNotice $_.Exception.Message -Kind error
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
                Show-AppNotice $_.Exception.Message -Kind error
            }
        }
        $rr.Row.Add_Click($handler)
        $rr.Name.Add_Click($handler)
        $rr.Time.Add_Click($handler)
    }
    function Register-ChartHover {
        param($Box)
        $Box.Add_MouseMove({
                param($sender, $e)
                $state = $sender.Tag
                if (-not $state -or -not $state.Geom) { return }
                $ginfo = $state.Geom
                $idx = [int][Math]::Floor(($e.X - [double]$ginfo.PadL) / [double]$ginfo.Slot)
                if ($idx -lt 0 -or $idx -ge [int]$ginfo.N) { $idx = -1 }
                if ($idx -eq [int]$state.Hover) { return }
                $state.Hover = $idx
                $sender.Tag = $state
                if ($state.Snap) { Draw-UsageChart $state.Snap $sender }
            })
        $Box.Add_MouseLeave({
                param($sender, $e)
                $state = $sender.Tag
                if (-not $state) { return }
                if ([int]$state.Hover -eq -1) { return }
                $state.Hover = -1
                $sender.Tag = $state
                if ($state.Snap) { Draw-UsageChart $state.Snap $sender }
            })
    }
    Register-ChartHover $chartBox
    Register-ChartHover $ledgerChart
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
                    Show-AppNotice $_.Exception.Message -Kind error
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
            if ($script:activePage -ne 'projects') { return }
            Set-SelectionCaption
        })

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $mContinue = $menu.Items.Add('继续最近会话')
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
            if ($e.KeyCode -eq 'F5') {
                Refresh-CurrentPage
                return
            }
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
    $scanTimer.Interval = 4000
    $scanTimer.Add_Tick({
            try {
                if ($script:activePage -eq 'watch') { Sync-WatchCards }
            } catch {
                try { [System.IO.File]::AppendAllText($script:ErrorLog, ("{0}`r`n{1}`r`n`r`n" -f (Get-Date), $_.Exception)) } catch { }
            }
        })
    $scanTimer.Start()
    $spinTimer = New-Object System.Windows.Forms.Timer
    $spinTimer.Interval = 90
    $spinTimer.Add_Tick({
            try {
                if ($script:activePage -ne 'watch') { return }
                $script:spinAngle = ($script:spinAngle + 24) % 360
                if ($script:watchCards -isnot [hashtable]) { return }
                foreach ($info in @($script:watchCards.Values)) {
                    if (-not $info) { continue }
                    if ($info.Contains('Dot') -and $info.Dot) {
                        $kc = $kindColor[$info.Kind]
                        if ($kc) { $info.Dot.ForeColor = $kc }
                    }
                }
            } catch { }
        })
    $spinTimer.Start()

    function Convert-ThemeColor {
        param($Current, $OldPal, $NewPal, [switch]$Foreground)
        if ($null -eq $Current -or $null -eq $OldPal -or $null -eq $NewPal) { return $Current }
        $order = if ($Foreground) {
            @('Text', 'Muted', 'Accent', 'Ink', 'Danger', 'Working', 'Created', 'Idle', 'AccentHover', 'Olive', 'Copper', 'Stone', 'Deep')
        } else {
            @('Bg', 'Panel', 'Toolbar', 'Line', 'Select', 'Hover', 'Accent', 'PanelPress', 'AccentPress', 'ChartBar', 'Track', 'Tip', 'Alt')
        }
        foreach ($key in $order) {
            if (-not $OldPal.Contains($key)) { continue }
            $oldC = $OldPal[$key]
            if ($oldC -isnot [System.Drawing.Color]) { continue }
            if ($Current.ToArgb() -eq $oldC.ToArgb()) { return $NewPal[$key] }
        }
        return $Current
    }

    function Update-ThemedTree {
        param($Control, $OldPal, $NewPal)
        if (-not $Control) { return }
        try { $Control.BackColor = Convert-ThemeColor $Control.BackColor $OldPal $NewPal } catch { }
        try { $Control.ForeColor = Convert-ThemeColor $Control.ForeColor $OldPal $NewPal -Foreground } catch { }
        if ($Control -is [System.Windows.Forms.Button]) {
            try {
                $Control.FlatAppearance.BorderColor = Convert-ThemeColor $Control.FlatAppearance.BorderColor $OldPal $NewPal
                $Control.FlatAppearance.MouseOverBackColor = Convert-ThemeColor $Control.FlatAppearance.MouseOverBackColor $OldPal $NewPal
                $Control.FlatAppearance.MouseDownBackColor = Convert-ThemeColor $Control.FlatAppearance.MouseDownBackColor $OldPal $NewPal
            } catch { }
        }
        if ($Control -is [System.Windows.Forms.DataGridView]) {
            $Control.BackgroundColor = Convert-ThemeColor $Control.BackgroundColor $OldPal $NewPal
            $Control.GridColor = Convert-ThemeColor $Control.GridColor $OldPal $NewPal
            foreach ($style in @($Control.DefaultCellStyle, $Control.AlternatingRowsDefaultCellStyle, $Control.ColumnHeadersDefaultCellStyle)) {
                $style.BackColor = Convert-ThemeColor $style.BackColor $OldPal $NewPal
                $style.ForeColor = Convert-ThemeColor $style.ForeColor $OldPal $NewPal -Foreground
                $style.SelectionBackColor = Convert-ThemeColor $style.SelectionBackColor $OldPal $NewPal
                $style.SelectionForeColor = Convert-ThemeColor $style.SelectionForeColor $OldPal $NewPal -Foreground
            }
        }
        foreach ($child in @($Control.Controls)) { Update-ThemedTree $child $OldPal $NewPal }
    }

    function Apply-LauncherTheme {
        param([string]$Name)
        $old = $script:palette
        $script:themeName = $(if ($Name -eq 'dark') { 'dark' } else { 'light' })
        $script:palette = Get-LauncherPalette $script:themeName
        $new = $script:palette
        foreach ($pair in @(
                @('bg', 'Bg'), @('panel', 'Panel'), @('toolbarBg', 'Toolbar'), @('line', 'Line'),
                @('text', 'Text'), @('muted', 'Muted'), @('accent', 'Accent'), @('accentHover', 'AccentHover'),
                @('select', 'Select'), @('hover', 'Hover'), @('danger', 'Danger'), @('ink', 'Ink'),
                @('working', 'Working'), @('createdC', 'Created'), @('idleC', 'Idle'),
                @('accentPress', 'AccentPress'), @('panelPress', 'PanelPress'), @('ledgerCard', 'Panel'),
                @('ledgerOlive', 'Olive'), @('ledgerCopper', 'Copper'), @('ledgerStone', 'Stone'), @('ledgerDeep', 'Deep')
            )) {
            Set-Variable -Name $pair[0] -Value $new[$pair[1]] -Scope Script
        }
        Update-ThemedTree $form $old $new
        $form.BackColor = $new.Bg
        $btnTheme.Text = $(if ($script:themeName -eq 'light') { '深色' } else { '浅色' })
        $btnTheme.BackColor = $new.Panel
        $btnTheme.ForeColor = $new.Muted
        $btnTheme.FlatAppearance.BorderColor = $new.Line
        if ($script:ledgerMix) {
            $mixColors = @{ in = $new.Accent; out = $new.Copper; reason = $new.Olive; cache = $new.Deep; create = $new.Stone }
            foreach ($r in @($script:ledgerMix)) {
                if ($mixColors.Contains($r.Key)) { $r.Fill.BackColor = $mixColors[$r.Key] }
                $r.Track.BackColor = $new.Track
            }
        }
        $script:config.theme = $script:themeName
        Save-LauncherConfig $script:config
        try { if ($script:lastUsage) { Draw-UsageChart $script:lastUsage $chartBox } } catch { }
        try { if ($ledgerChart -and $ledgerChart.Tag -and $ledgerChart.Tag.Snap) { Draw-UsageChart $ledgerChart.Tag.Snap $ledgerChart } } catch { }
        foreach ($b in @($tabDash, $tabProjects, $tabWatch, $tabLedger, $btnAbout)) {
            $b.BackColor = $new.Toolbar
            $b.ForeColor = $new.Muted
        }
        Set-Nav $script:activePage
        $side.BackColor = $new.Toolbar
        $sideBrand.BackColor = $new.Toolbar
        $sideBrand.ForeColor = $new.Text
        $sideHint.BackColor = $new.Toolbar
        $sideHint.ForeColor = $new.Muted
        $form.Invalidate($true)
    }

    $btnTheme.Add_Click({
            $next = $(if ($script:themeName -eq 'light') { 'dark' } else { 'light' })
            Apply-LauncherTheme $next
        })

    function Show-FromTray {
        $form.ShowInTaskbar = $true
        $form.Show()
        $form.WindowState = 'Normal'
        try { $form.Activate() } catch { }
        if ($script:tray) { $script:tray.Visible = $false }
    }

    function Hide-ToTray {
        $form.ShowInTaskbar = $false
        $form.Hide()
        if ($script:tray) {
            $script:tray.Visible = $true
            try { $script:tray.ShowBalloonTip(1200, 'Grok 最近项目', '已缩到后台。双击图标可以打开。', [System.Windows.Forms.ToolTipIcon]::Info) } catch { }
        }
    }

    function Ask-CloseChoice {
        $dlg = New-Object System.Windows.Forms.Form
        $dlg.Text = '关闭'
        $dlg.FormBorderStyle = 'FixedDialog'
        $dlg.StartPosition = 'CenterParent'
        $dlg.MaximizeBox = $false
        $dlg.MinimizeBox = $false
        $dlg.ClientSize = New-Object System.Drawing.Size(420, 188)
        $dlg.BackColor = $script:palette.Bg
        $dlg.ForeColor = $script:palette.Text
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = '要退出，还是缩到后台继续留着？'
        $lbl.SetBounds(20, 16, 380, 22)
        $lbl.ForeColor = $script:palette.Text
        $r1 = New-Object System.Windows.Forms.RadioButton
        $r1.Text = '缩小到后台'
        $r1.Checked = $true
        $r1.SetBounds(24, 48, 360, 24)
        $r1.ForeColor = $script:palette.Text
        $r2 = New-Object System.Windows.Forms.RadioButton
        $r2.Text = '退出程序'
        $r2.SetBounds(24, 76, 360, 24)
        $r2.ForeColor = $script:palette.Text
        $ck = New-Object System.Windows.Forms.CheckBox
        $ck.Text = '记住这个选择'
        $ck.SetBounds(24, 108, 220, 24)
        $ck.ForeColor = $script:palette.Muted
        $ok = New-Object System.Windows.Forms.Button
        $ok.Text = '确定'
        $ok.SetBounds(230, 146, 80, 28)
        $ok.DialogResult = 'OK'
        $cancel = New-Object System.Windows.Forms.Button
        $cancel.Text = '取消'
        $cancel.SetBounds(318, 146, 80, 28)
        $cancel.DialogResult = 'Cancel'
        $dlg.Controls.AddRange(@($lbl, $r1, $r2, $ck, $ok, $cancel))
        $dlg.AcceptButton = $ok
        $dlg.CancelButton = $cancel
        $result = $dlg.ShowDialog($form)
        $dlg.Dispose()
        if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
        $mode = $(if ($r1.Checked) { 'tray' } else { 'quit' })
        if ($ck.Checked) {
            $script:config.closeToTray = $mode
            Save-LauncherConfig $script:config
        }
        return $mode
    }

    $script:allowExit = $false
    $script:showEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, 'Local\GrokRecentLauncher.show')
    $script:tray = New-Object System.Windows.Forms.NotifyIcon
    $script:tray.Text = 'Grok 最近项目'
    try { if ($form.Icon) { $script:tray.Icon = $form.Icon } } catch { }
    if (-not $script:tray.Icon) { $script:tray.Icon = [System.Drawing.SystemIcons]::Application }
    $trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $miOpen = $trayMenu.Items.Add('打开')
    $miAsk = $trayMenu.Items.Add('下次关闭时再问我')
    $miQuit = $trayMenu.Items.Add('退出')
    $miOpen.Add_Click({ Show-FromTray })
    $miAsk.Add_Click({
            $script:config.closeToTray = ''
            Save-LauncherConfig $script:config
        })
    $miQuit.Add_Click({
            $script:allowExit = $true
            $form.Close()
        })
    $script:tray.ContextMenuStrip = $trayMenu
    $script:tray.Add_DoubleClick({ Show-FromTray })
    $showTimer = New-Object System.Windows.Forms.Timer
    $showTimer.Interval = 300
    $showTimer.Add_Tick({
            try { if ($script:showEvent.WaitOne(0)) { Show-FromTray } } catch { }
        })
    $showTimer.Start()

    $form.Add_FormClosing({
            param($sender, $e)
            $quitNow = $script:allowExit -or $script:restartRequested -or $script:LayoutCheckMode -or $script:ScreenshotMode
            if (-not $quitNow) {
                $e.Cancel = $true
                $mode = ''
                if ($script:config.PSObject.Properties.Name -contains 'closeToTray') { $mode = [string]$script:config.closeToTray }
                if ($mode -ne 'tray' -and $mode -ne 'quit') { $mode = Ask-CloseChoice }
                if (-not $mode) { return }
                if ($mode -eq 'tray') { Hide-ToTray; return }
                $script:allowExit = $true
                $form.BeginInvoke([Action]{ $form.Close() }) | Out-Null
                return
            }
            try { $showTimer.Stop() } catch { }
            if ($script:tray) { $script:tray.Visible = $false; try { $script:tray.Dispose() } catch { } }
            $scanTimer.Stop(); $spinTimer.Stop()
            try { $chartSyncTimer.Stop() } catch { }
            try { $bootTimer.Stop() } catch { }
            try { Stop-QuotaJob } catch { }
            foreach ($info in @($script:watchCards.Values)) {
                if ($info.Contains('Pic') -and $info.Pic -and $info.Pic.Image) { $info.Pic.Image.Dispose() }
            }
            if ($script:instanceMutex) {
                try { $script:instanceMutex.ReleaseMutex() } catch { }
                try { $script:instanceMutex.Dispose() } catch { }
                $script:instanceMutex = $null
            }
        })

    function Get-LayoutSnapshot {
        param([string]$Page)
        $imgW = 0
        $imgH = 0
        if ($chartBox.Image) {
            $imgW = [int]$chartBox.Image.Width
            $imgH = [int]$chartBox.Image.Height
        }
        return [pscustomobject]@{
            Page             = $Page
            HeaderW          = [int]$header.ClientSize.Width
            TitleLeft        = [int]$title.Left
            TitleWidth       = [int]$title.Width
            TitleRight       = [int]($title.Left + $title.Width)
            NavHostLeft      = [int]$side.Left
            TabDashLeft      = [int]$tabDash.Left
            TabScreenLeft    = [int]($side.Left + $tabDash.Left)
            SideW            = [int]$side.Width
            ChartClientW     = [int]$chartBox.ClientSize.Width
            ChartClientH     = [int]$chartBox.ClientSize.Height
            ChartImgW        = $imgW
            ChartImgH        = $imgH
            DashVisible      = [bool]$pageDash.Visible
            GridVisible      = [bool]$grid.Visible
            WatchVisible     = [bool]$pageWatch.Visible
            LedgerVisible    = [bool]$pageLedger.Visible
            SelVisible       = [bool]$selLabel.Visible
            SelRight         = [int]$selLabel.Right
            ContinueLeft     = [int]$btnContinue.Left
            TabType          = $tabWatch.GetType().Name
            TabStop          = [bool]$tabWatch.TabStop
        }
    }

    function Invoke-LayoutCheck {
        $rows = @()
        Show-DashPage
        [void][System.Windows.Forms.Application]::DoEvents()
        $form.Refresh()
        [void][System.Windows.Forms.Application]::DoEvents()
        $rows += Get-LayoutSnapshot 'dash'
        Show-ProjectsPage
        [void][System.Windows.Forms.Application]::DoEvents()
        $form.Refresh()
        $rows += Get-LayoutSnapshot 'projects'
        Show-WatchPage
        [void][System.Windows.Forms.Application]::DoEvents()
        $form.Refresh()
        $rows += Get-LayoutSnapshot 'watch'
        Show-DashPage
        [void][System.Windows.Forms.Application]::DoEvents()
        try { Sync-UsageChart } catch { }
        $form.Refresh()
        [void][System.Windows.Forms.Application]::DoEvents()
        $rows += Get-LayoutSnapshot 'dash-again'

        $problems = New-Object System.Collections.Generic.List[string]
        foreach ($s in $rows) {
            if ([int]$s.SideW -lt 160) {
                [void]$problems.Add(('{0}: sidebar missing width={1}' -f $s.Page, $s.SideW))
            }
            if ($s.Page -like 'dash*' -and $s.ChartClientW -gt 80 -and $s.ChartClientH -gt 60) {
                if ($s.ChartImgW -lt ($s.ChartClientW - 4) -or $s.ChartImgH -lt ($s.ChartClientH - 4)) {
                    [void]$problems.Add(('{0}: chart bitmap {1}x{2} box {3}x{4}' -f $s.Page, $s.ChartImgW, $s.ChartImgH, $s.ChartClientW, $s.ChartClientH))
                }
            }
            if ($s.TabType -ne 'QuietButton') {
                [void]$problems.Add(('{0}: nav tab type is {1}, expected QuietButton' -f $s.Page, $s.TabType))
            }
            if ($s.TabStop) {
                [void]$problems.Add(('{0}: nav tab still takes focus' -f $s.Page))
            }
            if ($s.Page -eq 'projects' -and $s.SelVisible -and ($s.SelRight -gt ($s.ContinueLeft - 4))) {
                [void]$problems.Add(('{0}: selection label overlaps continue button selRight={1} continueLeft={2}' -f $s.Page, $s.SelRight, $s.ContinueLeft))
            }
        }
        Show-LedgerPage
        [void][System.Windows.Forms.Application]::DoEvents()
        $form.Refresh()
        if (-not $pageLedger.Visible) {
            [void]$problems.Add('ledger: page did not show')
        }
        if ($status.Text -eq '使用记录读取失败') {
            [void]$problems.Add('ledger: refresh failed')
        }
        if ($ledgerGrid.Columns.Count -lt 9) {
            [void]$problems.Add('ledger: missing columns')
        }
        $payload = [pscustomobject]@{
            Ok       = ($problems.Count -eq 0)
            Problems = @($problems)
            Pages    = $rows
        }
        $outDir = Join-Path $script:Root 'docs'
        if (-not (Test-Path -LiteralPath $outDir)) {
            New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        }
        $outPath = Join-Path $outDir 'layout-check.json'
        $json = $payload | ConvertTo-Json -Depth 6
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($outPath, $json, $utf8)
        $script:layoutCheckFailed = -not $payload.Ok
        if ($problems.Count -gt 0) {
            Write-Host ($problems -join [Environment]::NewLine)
        } else {
            Write-Host 'GREEN: layout-check'
        }
    }

    $bootTimer = New-Object System.Windows.Forms.Timer
    $bootTimer.Interval = 80
    $bootTimer.Add_Tick({
            $bootTimer.Stop()
            try {
                Reload-Projects
                if ($script:LayoutCheckMode) { Invoke-LayoutCheck }
                elseif ($script:ScreenshotWatchMode) { Show-WatchPage }
                elseif ($script:ScreenshotDashMode) { Show-DashPage }
                elseif ($script:ScreenshotMode) { Show-ProjectsPage }
                else { Show-DashPage }
            } catch {
                try {
                    $errPath = Join-Path $script:Root 'docs\last-ui-error.txt'
                    [System.IO.File]::WriteAllText($errPath, $_.Exception.ToString())
                } catch { }
                if (-not $script:ScreenshotMode -and -not $script:LayoutCheckMode) {
                    [System.Windows.Forms.MessageBox]::Show($_.Exception.ToString(), '加载项目列表失败') | Out-Null
                }
                if ($script:LayoutCheckMode) { $script:layoutCheckFailed = $true }
            } finally {
                if (-not $script:ScreenshotMode) { $form.TopMost = $false }
            }
        })

    $form.Add_Shown({
            try {
                Hide-HostConsole
                Show-FormNow
                try { $form.Refresh() } catch { }
                try { [System.Windows.Forms.Application]::DoEvents() } catch { }
                try {
                    if (-not ('DwmUtil' -as [type])) {
                        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DwmUtil {
  [DllImport("dwmapi.dll")]
  public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
}
'@
                    }
                    $darkMode = 1
                    [void][DwmUtil]::DwmSetWindowAttribute($form.Handle, 20, [ref]$darkMode, 4)
                } catch { }
                if ($script:LayoutCheckMode -or $script:ScreenshotMode) {
                    Reload-Projects
                    if ($script:LayoutCheckMode) { Invoke-LayoutCheck }
                    elseif ($script:ScreenshotWatchMode) { Show-WatchPage }
                    elseif ($script:ScreenshotDashMode) { Show-DashPage }
                    else { Show-ProjectsPage }
                } else {
                    $bootTimer.Start()
                }
            } catch {
                try {
                    $errPath = Join-Path $script:Root 'docs\last-ui-error.txt'
                    [System.IO.File]::WriteAllText($errPath, $_.Exception.ToString())
                } catch { }
                if (-not $script:ScreenshotMode -and -not $script:LayoutCheckMode) {
                    [System.Windows.Forms.MessageBox]::Show($_.Exception.ToString(), '加载项目列表失败') | Out-Null
                }
                if ($script:LayoutCheckMode) { $script:layoutCheckFailed = $true }
            } finally {
                if ($script:ScreenshotMode -or $script:LayoutCheckMode) { $form.TopMost = $false }
            }

            if ($script:LayoutCheckMode) {
                $form.Close()
            } elseif ($script:ScreenshotMode) {
                $script:chartHover = -1
                if ($script:ScreenshotDashMode -and $script:lastUsage) {
                    try { Draw-UsageChart $script:lastUsage } catch { }
                }
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
    if ($script:restartRequested) {
        $ps1 = Join-Path $script:Root 'GrokRecent.ps1'
        $vbs = Join-Path $script:Root 'launch-silent.vbs'
        if (Test-Path -LiteralPath $vbs) {
            Start-Process -FilePath 'wscript.exe' -ArgumentList ('"{0}"' -f $vbs) | Out-Null
        } else {
            Start-Process -FilePath 'powershell.exe' -ArgumentList @(
                '-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ps1
            ) | Out-Null
        }
    }
    if ($script:LayoutCheckMode) {
        if ($script:layoutCheckFailed) { exit 1 }
        exit 0
    }
} catch {
    try {
        Add-Type -AssemblyName System.Windows.Forms | Out-Null
        [System.Windows.Forms.MessageBox]::Show($_.Exception.ToString(), 'Grok 最近项目启动失败') | Out-Null
    } catch {
        throw
    }
    exit 1
}
