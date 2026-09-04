#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$vbs = Join-Path $root 'launch-silent.vbs'
$ps1 = Join-Path $root 'GrokRecent.ps1'

if (-not (Test-Path -LiteralPath $vbs)) { throw "缺少 launch-silent.vbs" }
if (-not (Test-Path -LiteralPath $ps1)) { throw "缺少 GrokRecent.ps1" }

$desktop = [Environment]::GetFolderPath('Desktop')
if (-not $desktop -or -not (Test-Path -LiteralPath $desktop)) {
    foreach ($candidate in @(
            (Join-Path $env:USERPROFILE 'Desktop'),
            (Join-Path $env:USERPROFILE 'OneDrive\Desktop')
        )) {
        if (Test-Path -LiteralPath $candidate) { $desktop = $candidate; break }
    }
}
if (-not $desktop) { throw '找不到桌面目录' }

$icon = Join-Path $env:USERPROFILE '.grok\bin\grok.exe'
if (-not (Test-Path -LiteralPath $icon)) {
    $cmd = Get-Command grok.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { $icon = $cmd.Source }
}

$lnkPath = Join-Path $desktop 'Grok 最近项目.lnk'
$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut($lnkPath)
$sc.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
$sc.Arguments = '//nologo "{0}"' -f $vbs
$sc.WorkingDirectory = $root
$sc.WindowStyle = 1
$sc.Description = '从 Grok 会话记录里找回最近用过的项目目录'
if (Test-Path -LiteralPath $icon) {
    $sc.IconLocation = '{0},0' -f $icon
}
$sc.Save()

if (-not (Test-Path -LiteralPath $lnkPath)) {
    throw "快捷方式写入失败: $lnkPath"
}

Write-Host "已创建桌面快捷方式:"
Write-Host $lnkPath
