#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:watchExpanded = @{}
$script:watchCards = @{}

function New-FakeWatchCard {
    param($ProcId)
    $pidToggle = $ProcId
    return {
        if (-not $script:watchExpanded.Contains($pidToggle)) { $script:watchExpanded[$pidToggle] = $false }
        $script:watchExpanded[$pidToggle] = -not [bool]$script:watchExpanded[$pidToggle]
        'bad-ok pid=' + $pidToggle + ' expanded=' + $script:watchExpanded[$pidToggle]
    }.GetNewClosure()
}

$bad = New-FakeWatchCard 40196

function New-FixedWatchToggle {
    return {
        $watchPid = 40196
        if ($null -eq $script:watchExpanded -or $script:watchExpanded -isnot [hashtable]) {
            $script:watchExpanded = @{}
        }
        if (-not $script:watchExpanded.Contains($watchPid)) { $script:watchExpanded[$watchPid] = $false }
        $script:watchExpanded[$watchPid] = -not [bool]$script:watchExpanded[$watchPid]
        'good-ok expanded=' + $script:watchExpanded[$watchPid]
    }
}

$good = New-FixedWatchToggle

Write-Host '--- GetNewClosure $script: Contains (expected RED) ---'
try {
    & $bad
    Write-Host 'UNEXPECTED PASS'
    exit 2
} catch {
    Write-Host ('RED: ' + $_.Exception.Message)
}

Write-Host '--- Direct script-scope toggle (expected GREEN) ---'
try {
    $r = & $good
    Write-Host ('GREEN: ' + $r)
    if ($script:watchExpanded[40196] -ne $true) { throw 'expand flag not set in script scope' }
} catch {
    Write-Host ('UNEXPECTED FAIL: ' + $_.Exception.Message)
    exit 3
}

Write-Host '--- Format-Ago DateTime vs DateTimeOffset ---'
function Format-Ago-Old {
    param($When)
    if (-not $When) { return '' }
    $local = $When.ToLocalTime().DateTime
    return $local.ToString('yyyy-MM-dd HH:mm')
}
function Format-Ago-New {
    param($When)
    if (-not $When) { return '' }
    $local = $null
    if ($When -is [datetimeoffset]) {
        $local = $When.ToLocalTime().DateTime
    } elseif ($When -is [datetime]) {
        $local = $When.ToLocalTime()
    } else {
        try { $local = ([datetimeoffset]$When).ToLocalTime().DateTime } catch { return '' }
    }
    if (-not $local) { return '' }
    return $local.ToString('yyyy-MM-dd HH:mm')
}
$dto = [datetimeoffset]::Now.AddHours(-4)
$dt = [datetime]::Now.AddHours(-4)
try {
    $a = Format-Ago-Old $dto
    Write-Host ('old DateTimeOffset GREEN: ' + $a)
} catch { Write-Host ('old DateTimeOffset RED: ' + $_.Exception.Message) }
try {
    $b = Format-Ago-Old $dt
    Write-Host ('old DateTime UNEXPECTED PASS: ' + $b)
} catch { Write-Host ('old DateTime RED (expected): ' + $_.Exception.Message) }
try {
    $c = Format-Ago-New $dto
    $d = Format-Ago-New $dt
    Write-Host ('new DateTimeOffset GREEN: ' + $c)
    Write-Host ('new DateTime GREEN: ' + $d)
} catch {
    Write-Host ('new Format-Ago FAIL: ' + $_.Exception.Message)
    exit 4
}

Write-Host '--- WinForms label click uses $this.Tag not GetNewClosure ---'
try {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $script:watchExpanded.Remove(40196)
    $form = New-Object System.Windows.Forms.Form
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Tag = 40196
    $lbl.Text = 'row'
    $lbl.Add_Click({
            $watchPid = [int]$this.Tag
            if ($null -eq $script:watchExpanded -or $script:watchExpanded -isnot [hashtable]) { $script:watchExpanded = @{} }
            if (-not $script:watchExpanded.Contains($watchPid)) { $script:watchExpanded[$watchPid] = $false }
            $script:watchExpanded[$watchPid] = -not [bool]$script:watchExpanded[$watchPid]
        })
    $form.Controls.Add($lbl)
    [void]$form.Handle
    $onClick = [System.Windows.Forms.Control].GetMethod('OnClick', [System.Reflection.BindingFlags]'Instance,NonPublic')
    [void]$onClick.Invoke($lbl, @([EventArgs]::Empty))
    $form.Dispose()
    if ($script:watchExpanded[40196] -ne $true) { throw 'PerformClick did not toggle script-scope hashtable' }
    Write-Host 'GREEN: label click toggled $script:watchExpanded'
} catch {
    Write-Host ('WinForms click FAIL: ' + $_.Exception.Message)
    exit 5
}

Write-Host 'PASS: repro matches click crash; replacement toggle is safe'
exit 0
