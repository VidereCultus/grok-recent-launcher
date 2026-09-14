#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ps1 = Join-Path $root 'GrokRecent.ps1'
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($ps1, [ref]$tokens, [ref]$errors)
if ($errors -and $errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Host ('PARSE: ' + $_.ToString()) }
    exit 1
}
Write-Host 'GREEN: GrokRecent.ps1 parses'
exit 0
