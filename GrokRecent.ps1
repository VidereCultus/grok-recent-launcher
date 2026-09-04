#requires -Version 5.1
# Grok 最近项目启动器：从 ~/.grok/sessions 找回用过的目录，勾选后用 Windows Terminal 打开。
[CmdletBinding()]
param(
    [switch]$ListOnly,
    [switch]$Version,
    [switch]$Demo,
    [switch]$Screenshot,
    [int]$Limit = 50
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AppVersion = '1.0.0'
if ($Version) {
    Write-Output $script:AppVersion
    exit 0
}

# Screenshot always uses fictional rows so real project paths never land in docs/.
$script:DemoMode = [bool]($Demo -or $Screenshot)
$script:ScreenshotMode = [bool]$Screenshot

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
            pins        = @('D:\Work\shop-web')
            hideMissing = $true
        }
    }
    $cfg = [pscustomobject]@{
        pins        = @()
        hideMissing = $true
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
    return $cfg
}

function Save-LauncherConfig {
    param($Config)
    if ($script:DemoMode) { return }
    $payload = @{
        pins        = @($Config.pins)
        hideMissing = [bool]$Config.hideMissing
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

    if ($wt) {
        $wtArgs = New-Object System.Collections.Generic.List[string]
        [void]$wtArgs.Add('-w')
        [void]$wtArgs.Add('0')
        $first = $true
        foreach ($p in $existing) {
            if (-not $first) { [void]$wtArgs.Add(';') }
            [void]$wtArgs.Add('new-tab')
            [void]$wtArgs.Add('--title')
            [void]$wtArgs.Add($p.Label)
            [void]$wtArgs.Add('-d')
            [void]$wtArgs.Add($p.Path)
            if ($Mode -eq 'terminal') {
                [void]$wtArgs.Add('powershell.exe')
            } else {
                [void]$wtArgs.Add($grok)
                [void]$wtArgs.Add('--cwd')
                [void]$wtArgs.Add($p.Path)
                if ($Mode -eq 'continue') { [void]$wtArgs.Add('-c') }
            }
            $first = $false
        }
        $argLine = (
            $wtArgs | ForEach-Object {
                if ($_ -eq ';') { ';' }
                elseif ($_ -match '[\s"]') { '"{0}"' -f ($_ -replace '"', '\"') }
                else { $_ }
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
        $arg = @('--cwd', $p.Path)
        if ($Mode -eq 'continue') { $arg += '-c' }
        Start-Process -FilePath $grok -ArgumentList $arg -WorkingDirectory $p.Path | Out-Null
    }
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

    $script:config = Read-LauncherConfig
    $script:allProjects = @()

    $bg = [System.Drawing.Color]::FromArgb(16, 16, 14)
    $panel = [System.Drawing.Color]::FromArgb(24, 23, 20)
    $line = [System.Drawing.Color]::FromArgb(46, 42, 36)
    $text = [System.Drawing.Color]::FromArgb(236, 230, 218)
    $muted = [System.Drawing.Color]::FromArgb(132, 126, 114)
    $accent = [System.Drawing.Color]::FromArgb(201, 148, 62)
    $select = [System.Drawing.Color]::FromArgb(64, 48, 24)
    $danger = [System.Drawing.Color]::FromArgb(168, 92, 72)
    $uiFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    $titleFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Bold)
    $smallFont = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = ('Grok 最近项目  v{0}' -f $script:AppVersion)
    $form.StartPosition = 'CenterScreen'
    $form.Size = New-Object System.Drawing.Size(980, 620)
    $form.MinimumSize = New-Object System.Drawing.Size(780, 460)
    $form.BackColor = $bg
    $form.ForeColor = $text
    $form.Font = $uiFont
    $form.KeyPreview = $true
    $form.ShowInTaskbar = $true
    $form.TopMost = $true
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = 'Top'
    $header.Height = 86
    $header.BackColor = $bg
    $form.Controls.Add($header)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = '最近的 Grok 项目'
    $title.Font = $titleFont
    $title.ForeColor = $text
    $title.Location = New-Object System.Drawing.Point(20, 12)
    $title.AutoSize = $true
    $header.Controls.Add($title)

    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = '从会话记录找回目录。勾选多个后点「续上」，会在 Windows Terminal 里一次开出对应标签。'
    $subtitle.Font = $smallFont
    $subtitle.ForeColor = $muted
    $subtitle.Location = New-Object System.Drawing.Point(22, 44)
    $subtitle.AutoSize = $true
    $header.Controls.Add($subtitle)

    $btnAbout = New-Object System.Windows.Forms.Button
    $btnAbout.Text = '关于'
    $btnAbout.FlatStyle = 'Flat'
    $btnAbout.FlatAppearance.BorderSize = 1
    $btnAbout.FlatAppearance.BorderColor = $line
    $btnAbout.BackColor = $panel
    $btnAbout.ForeColor = $muted
    $btnAbout.Width = 64
    $btnAbout.Height = 26
    $btnAbout.Anchor = 'Top,Right'
    $btnAbout.Cursor = [System.Windows.Forms.Cursors]::Hand
    $header.Controls.Add($btnAbout)

    $search = New-Object System.Windows.Forms.TextBox
    $search.BorderStyle = 'FixedSingle'
    $search.BackColor = $panel
    $search.ForeColor = $text
    $search.Location = New-Object System.Drawing.Point(24, 98)
    $search.Width = 360
    $search.Height = 28
    $form.Controls.Add($search)
    $script:search = $search
    $search.Add_HandleCreated({
            [void][NativeDpi]::SendMessage($search.Handle, 0x1501, [IntPtr]1, '搜项目名、路径、摘要')
        })

    $hideMissing = New-Object System.Windows.Forms.CheckBox
    $hideMissing.Text = '隐藏失效目录'
    $hideMissing.ForeColor = $muted
    $hideMissing.AutoSize = $true
    $hideMissing.Location = New-Object System.Drawing.Point(400, 102)
    $hideMissing.Checked = [bool]$script:config.hideMissing
    $form.Controls.Add($hideMissing)

    function New-BarButton {
        param([string]$Text, [int]$X, [System.Drawing.Color]$Back, [System.Drawing.Color]$Fore)
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $Text
        $b.FlatStyle = 'Flat'
        $b.FlatAppearance.BorderSize = 0
        $b.BackColor = $Back
        $b.ForeColor = $Fore
        $b.Width = 76
        $b.Height = 30
        $b.Location = New-Object System.Drawing.Point($X, 96)
        $b.Cursor = [System.Windows.Forms.Cursors]::Hand
        $form.Controls.Add($b)
        return $b
    }

    $btnContinue = New-BarButton '续上' 0 $accent ([System.Drawing.Color]::FromArgb(28, 22, 12))
    $btnNew = New-BarButton '新开' 0 $panel $text
    $btnTerm = New-BarButton '终端' 0 $panel $text
    $btnFolder = New-BarButton '文件夹' 0 $panel $text
    $btnRefresh = New-BarButton '刷新' 0 $panel $muted

    foreach ($b in @($btnNew, $btnTerm, $btnFolder, $btnRefresh)) {
        $b.FlatAppearance.BorderSize = 1
        $b.FlatAppearance.BorderColor = $line
    }

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(20, 140)
    $grid.Anchor = 'Top,Bottom,Left,Right'
    $grid.BackgroundColor = $panel
    $grid.ForeColor = $text
    $grid.GridColor = $line
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
    $grid.RowTemplate.Height = 30
    $grid.ColumnHeadersHeight = 32
    $grid.ColumnHeadersHeightSizeMode = 'DisableResizing'
    $grid.DefaultCellStyle.BackColor = $panel
    $grid.DefaultCellStyle.ForeColor = $text
    $grid.DefaultCellStyle.SelectionBackColor = $select
    $grid.DefaultCellStyle.SelectionForeColor = $text
    $grid.DefaultCellStyle.Font = $uiFont
    $grid.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(20, 19, 17)
    $grid.AlternatingRowsDefaultCellStyle.ForeColor = $text
    $grid.AlternatingRowsDefaultCellStyle.SelectionBackColor = $select
    $grid.AlternatingRowsDefaultCellStyle.SelectionForeColor = $text
    $grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(28, 27, 24)
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = $muted
    $grid.ColumnHeadersDefaultCellStyle.Font = $smallFont
    $grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(28, 27, 24)
    $form.Controls.Add($grid)
    $script:grid = $grid

    $empty = New-Object System.Windows.Forms.Label
    $empty.Text = "还没有会话记录。`r`n在某个项目目录里运行过 grok 之后，就会出现在这里。`r`n本工具只读本机会话摘要，不会联网。"
    $empty.TextAlign = 'MiddleCenter'
    $empty.ForeColor = $muted
    $empty.BackColor = $panel
    $empty.Font = $uiFont
    $empty.Visible = $false
    $form.Controls.Add($empty)
    $empty.BringToFront()

    $status = New-Object System.Windows.Forms.Label
    $status.Dock = 'Bottom'
    $status.Height = 28
    $status.ForeColor = $muted
    $status.Font = $smallFont
    $status.Padding = New-Object System.Windows.Forms.Padding(20, 6, 8, 0)
    $status.Text = '双击续上 · Enter 打开 · Ctrl+A 全选 · Esc 关闭 · 点 ★ 置顶'
    $form.Controls.Add($status)

    function Layout-Buttons {
        $btnAbout.Left = $header.ClientSize.Width - 84
        $btnAbout.Top = 14
        $right = $form.ClientSize.Width - 20
        foreach ($b in @($btnRefresh, $btnFolder, $btnTerm, $btnNew, $btnContinue)) {
            $right -= $b.Width
            $b.Left = $right
            $b.Anchor = 'Top,Right'
            $right -= 8
        }
        $search.Width = [Math]::Max(220, $right - $search.Left - 160)
        $hideMissing.Left = $search.Right + 12
        $grid.Width = $form.ClientSize.Width - 40
        $grid.Height = $form.ClientSize.Height - $grid.Top - $status.Height - 8
        $empty.Location = $grid.Location
        $empty.Size = $grid.Size
    }

    $form.Add_Resize({ Layout-Buttons })
    Layout-Buttons

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
            $grid.Columns[$cPin].FillWeight = 8
            $grid.Columns[$cName].FillWeight = 22
            $grid.Columns[$cAgo].FillWeight = 12
            $grid.Columns[$cCount].FillWeight = 8
            $grid.Columns[$cTitle].FillWeight = 28
            $grid.Columns[$cPath].FillWeight = 22
            $grid.Columns[$cPin].MinimumWidth = 36
            $grid.Columns[$cCount].MinimumWidth = 48
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
        if ($empty.Visible) { $empty.BringToFront() }

        $pinCount = @($script:config.pins).Count
        $status.Text = ('{0} 个项目 · 已选 {1} · 置顶 {2} · 双击续上 · Enter 打开 · Ctrl+A 全选 · Esc 关闭' -f `
                $visible.Count, $grid.SelectedRows.Count, $pinCount)
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
    $btnFolder.Add_Click({ Invoke-Open 'folder' })
    $btnRefresh.Add_Click({ Reload-Projects })

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
            $status.Text = ('{0} 个项目 · 已选 {1} · 置顶 {2} · 双击续上 · Enter 打开 · Ctrl+A 全选 · Esc 关闭' -f `
                    $visibleCount, $grid.SelectedRows.Count, @($script:config.pins).Count)
        })

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $mContinue = $menu.Items.Add('续上上次会话')
    $mNew = $menu.Items.Add('新开会话')
    $mTerm = $menu.Items.Add('只开终端')
    $mFolder = $menu.Items.Add('打开文件夹')
    [void]$menu.Items.Add('-')
    $mCopy = $menu.Items.Add('复制路径')
    $mPin = $menu.Items.Add('置顶 / 取消置顶')
    $mContinue.Add_Click({ Invoke-Open 'continue' })
    $mNew.Add_Click({ Invoke-Open 'new' })
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

    $form.Add_Shown({
            try {
                $form.Activate()
                Reload-Projects
                if (-not $script:ScreenshotMode) { $search.Focus() }
            } catch {
                [System.Windows.Forms.MessageBox]::Show($_.Exception.ToString(), '加载项目列表失败') | Out-Null
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
                $outPath = Join-Path $outDir 'screenshot.png'
                # Draw the form itself — never CopyFromScreen (that could leak the real desktop).
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
