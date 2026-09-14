#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ps1 = Join-Path $root 'GrokRecent.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ps1, [ref]$tokens, [ref]$errors)
if ($errors -and $errors.Count -gt 0) { $errors | ForEach-Object { Write-Host $_ }; exit 1 }
foreach ($fnAst in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    if ($fnAst.Name -eq 'Select-LatestPerPath') { Invoke-Expression $fnAst.Extent.Text }
}

$now = [datetimeoffset]::Now
$folder = 'GrokWorkspace'
$items = @(
    [pscustomobject]@{ Title = 'a1'; Label = $folder; Path = 'D:\Project\GrokWorkspace'; When = $now }
    [pscustomobject]@{ Title = 'a2'; Label = $folder; Path = 'D:\Project\GrokWorkspace'; When = $now.AddMinutes(-1) }
    [pscustomobject]@{ Title = 'a3'; Label = $folder; Path = 'D:\Project\GrokWorkspace'; When = $now.AddMinutes(-2) }
    [pscustomobject]@{ Title = 'a4'; Label = $folder; Path = 'D:\Project\GrokWorkspace'; When = $now.AddMinutes(-2) }
    [pscustomobject]@{ Title = 'a5'; Label = $folder; Path = 'D:\Project\GrokWorkspace'; When = $now.AddMinutes(-2) }
    [pscustomobject]@{ Title = 'desk'; Label = 'desk-app'; Path = 'D:\Project\GrokWorkspace\open\desk-app'; When = $now.AddMinutes(-3) }
    [pscustomobject]@{ Title = 'mon'; Label = 'monitor'; Path = 'D:\Project\GrokWorkspace\intel\monitor'; When = $now.AddMinutes(-4) }
    [pscustomobject]@{ Title = 'other'; Label = $folder; Path = 'C:\Users\Administrator\GrokWorkspace'; When = $now.AddMinutes(-5) }
)
$got = @(Select-LatestPerPath -Items $items -Take 5)
if ($got.Count -ne 4) { throw ('expected 4 unique paths, got {0}' -f $got.Count) }
if ($got[0].Title -ne 'a1') { throw 'should keep the newest session for the duplicated folder' }
$paths = @($got | ForEach-Object { $_.Path })
if (($paths | Select-Object -Unique).Count -ne $got.Count) { throw 'paths still duplicated' }
$sameLeaf = @($got | Where-Object { $_.Label -like '*GrokWorkspace' })
if ($sameLeaf.Count -ne 2) { throw ('expected 2 disambiguated workspace rows, got {0} ({1})' -f $sameLeaf.Count, (($got | ForEach-Object { $_.Label }) -join ', ')) }
$distinct = @($sameLeaf | ForEach-Object { $_.Label } | Select-Object -Unique)
if ($distinct.Count -ne 2) { throw ('leaf names not disambiguated: {0}' -f ($sameLeaf.Label -join ', ')) }
Write-Host ('GREEN: {0} rows {1}' -f $got.Count, (($got | ForEach-Object { $_.Label }) -join ' ; '))
Write-Host 'PASS'
exit 0
