#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ps1 = Join-Path $root 'GrokRecent.ps1'

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ps1, [ref]$tokens, [ref]$errors)
if ($errors -and $errors.Count -gt 0) { $errors | ForEach-Object { Write-Host $_ }; exit 1 }
Write-Host 'GREEN: parses'

$want = @(
    'ConvertTo-ProcessArgumentString'
    'Build-WtNewTabArgumentString'
    'Test-SamePath'
    'Get-GrokExe'
    'Get-WtExe'
    'Ensure-ProcessCwdType'
    'Ensure-WtHostType'
    'Get-WtWindowList'
    'Get-RunningGrokForPath'
    'Focus-WtWindowForProject'
)
foreach ($fnAst in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    if ($want -contains $fnAst.Name) {
        Invoke-Expression $fnAst.Extent.Text
    }
}

$proj = [pscustomobject]@{ Label = 'shop-web'; Path = 'D:\Work\shop web' }
$s = Build-WtNewTabArgumentString -Projects @($proj) -Mode 'continue' -GrokExe 'C:\Users\Administrator\.grok\bin\grok.exe'
Write-Host ('ARGS: ' + $s)
if ($s -notmatch '(^|\s)-w 0(\s|$)') { throw 'missing -w 0 (current window per wt -h)' }
if ($s -notmatch 'new-tab') { throw 'missing new-tab' }
if ($s -match '--window last') { throw 'do not use --window last; this WT opens a named window' }
if ($s -match '-w new' -or $s -match '--window new') { throw 'must not force a new window' }
if ($s -notmatch ' -- ') { throw 'missing -- before grok.exe' }
if ($s -notmatch '-c') { throw 'continue should pass -c' }
if ($s -notmatch '--cwd') { throw 'missing --cwd' }
if ($s -notmatch '"D:\\Work\\shop web"') { throw 'path with space should be quoted' }
Write-Host 'GREEN: continue args reuse last window as a tab'

$s2 = Build-WtNewTabArgumentString -Projects @($proj) -Mode 'new' -GrokExe 'C:\g\grok.exe'
if ($s2 -match '(^|\s)-c(\s|$)') { throw 'new session should not pass -c' }
Write-Host 'GREEN: new session args have no -c'

$desk = Join-Path $env:USERPROFILE 'Desktop'
$live = Get-RunningGrokForPath $desk
if ($live) { throw 'desktop should not have a grok cwd' }
Write-Host 'GREEN: missing cwd is null'

Ensure-ProcessCwdType
$sampleCwd = $null
foreach ($p in Get-CimInstance Win32_Process -Filter "Name='grok.exe'" -ErrorAction SilentlyContinue) {
    $cwd = $null
    try { $cwd = [ProcessCwd]::Get([int]$p.ProcessId) } catch { }
    if ($cwd) { $sampleCwd = $cwd; break }
}
if ($sampleCwd) {
    $hit = Get-RunningGrokForPath $sampleCwd
    if (-not $hit) { throw ('expected live grok for {0}' -f $sampleCwd) }
    Write-Host ('GREEN: found live grok pid={0} cwd={1}' -f $hit.Pid, $hit.Cwd)
} else {
    Write-Host 'SKIP: no live grok cwd to resolve'
}

$wins = @(Get-WtWindowList)
Write-Host ('GREEN: WT windows listed={0}' -f $wins.Count)
if ($wins.Count -lt 1) { throw 'expected at least one Windows Terminal window' }

Write-Host 'PASS'
exit 0
