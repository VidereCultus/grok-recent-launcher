#requires -Version 5.1
# Click a folder in the system folder dialog and confirm that folder is returned,
# not the directory currently open in the breadcrumb.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $argList = @(
        '-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath
    )
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Wait -PassThru -NoNewWindow
    exit $proc.ExitCode
}

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -ReferencedAssemblies @('UIAutomationClient', 'UIAutomationTypes', 'WindowsBase') -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Windows.Automation;
using System.Runtime.InteropServices;

public static class PickUiDriver {
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    const uint WM_CLOSE = 0x0010;

    public static string Result;
    public static string ButtonName = "Select Folder";

    static void Log(string path, string line) {
        try { File.AppendAllText(path, line + Environment.NewLine); } catch { }
    }

    static IntPtr FindHwnd(string title) {
        IntPtr found = IntPtr.Zero;
        EnumProc proc = (h, l) => {
            var sb = new StringBuilder(512);
            GetWindowText(h, sb, sb.Capacity);
            if (sb.ToString() == title) { found = h; return false; }
            return true;
        };
        EnumWindows(proc, IntPtr.Zero);
        GC.KeepAlive(proc);
        return found;
    }

    static AutomationElement WindowFromTitle(string title) {
        IntPtr hwnd = FindHwnd(title);
        if (hwnd == IntPtr.Zero) return null;
        return AutomationElement.FromHandle(hwnd);
    }

    static void Click(System.Windows.Rect rect) {
        int x = (int)(rect.Left + rect.Width / 2.0);
        int y = (int)(rect.Top + rect.Height / 2.0);
        SetCursorPos(x, y);
        Thread.Sleep(40);
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        Thread.Sleep(30);
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
    }

    static AutomationElement FindNamed(AutomationElement root, string name) {
        AutomationElement exact = null;
        var all = root.FindAll(TreeScope.Descendants, Condition.TrueCondition);
        for (int i = 0; i < all.Count; i++) {
            string n = "";
            try { n = all[i].Current.Name; } catch { continue; }
            if (n == name) {
                exact = all[i];
                try {
                    if (all[i].Current.ControlType == ControlType.ListItem) return all[i];
                } catch { }
            }
        }
        return exact;
    }

    static void Dump(AutomationElement win, string log) {
        try {
            var all = win.FindAll(TreeScope.Descendants, Condition.TrueCondition);
            int n = all.Count < 80 ? all.Count : 80;
            for (int i = 0; i < n; i++) {
                try {
                    Log(log, all[i].Current.ControlType.ProgrammaticName + " | " + all[i].Current.Name);
                } catch { }
            }
        } catch (Exception ex) {
            Log(log, "dump " + ex.Message);
        }
    }

    public static void Start(string title, string itemName, string log) {
        Result = null;
        var t = new Thread(() => { Result = Drive(title, itemName, log); });
        t.SetApartmentState(ApartmentState.MTA);
        t.IsBackground = true;
        t.Start();
    }

    static string Drive(string title, string itemName, string log) {
        AutomationElement win = null;
        for (int i = 0; i < 50; i++) {
            win = WindowFromTitle(title);
            if (win != null) break;
            Thread.Sleep(100);
        }
        if (win == null) return "window not found";
        Log(log, "window found");
        IntPtr hwnd = new IntPtr(win.Current.NativeWindowHandle);
        try { SetForegroundWindow(hwnd); } catch { }
        Thread.Sleep(250);
        if (!string.IsNullOrEmpty(itemName)) {
            AutomationElement item = null;
            for (int n = 0; n < 40; n++) {
                win = WindowFromTitle(title);
                if (win == null) return "closed before item";
                item = FindNamed(win, itemName);
                if (item != null) break;
                Thread.Sleep(100);
            }
            if (item == null) {
                Dump(win, log);
                try { SendMessage(hwnd, WM_CLOSE, IntPtr.Zero, IntPtr.Zero); } catch { }
                return "item not found: " + itemName;
            }
            var rect = item.Current.BoundingRectangle;
            Log(log, "item rect " + rect.Left + "," + rect.Top + " " + rect.Width + "x" + rect.Height);
            try {
                var sel = item.GetCurrentPattern(SelectionItemPattern.Pattern) as SelectionItemPattern;
                if (sel != null) sel.Select();
            } catch (Exception ex) {
                Log(log, "select " + ex.Message);
            }
            if (rect.Width > 2 && rect.Height > 2) Click(rect);
            Thread.Sleep(800);
        } else {
            Thread.Sleep(400);
        }
        int clicks = 0;
        for (int attempt = 0; attempt < 2; attempt++) {
            win = WindowFromTitle(title);
            if (win == null) return "closed after " + clicks;
            hwnd = new IntPtr(win.Current.NativeWindowHandle);
            var btn = win.FindFirst(TreeScope.Descendants, new AndCondition(
                new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button),
                new PropertyCondition(AutomationElement.NameProperty, ButtonName)));
            if (btn == null) {
                Dump(win, log);
                try { SendMessage(hwnd, WM_CLOSE, IntPtr.Zero, IntPtr.Zero); } catch { }
                return "button not found";
            }
            clicks++;
            Log(log, "click button " + clicks);
            try {
                var invoke = btn.GetCurrentPattern(InvokePattern.Pattern) as InvokePattern;
                if (invoke != null) invoke.Invoke();
                else Click(btn.Current.BoundingRectangle);
            } catch (Exception ex) {
                Log(log, "invoke " + ex.Message);
                try { Click(btn.Current.BoundingRectangle); } catch { }
            }
            Thread.Sleep(800);
            if (WindowFromTitle(title) == null) return "closed after " + clicks;
        }
        try { SendMessage(hwnd, WM_CLOSE, IntPtr.Zero, IntPtr.Zero); } catch { }
        return "still open after " + clicks;
    }
}
'@

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ps1 = Join-Path $root 'GrokRecent.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ps1, [ref]$tokens, [ref]$errors)
if ($errors -and $errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Host $_ }
    exit 1
}
foreach ($name in @('Ensure-GrokFolderPickerType', 'Select-GrokFolderPath')) {
    $fnAst = $ast.FindAll({
        $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq $name
    }, $false) | Select-Object -First 1
    if (-not $fnAst) { throw "missing function $name" }
    Invoke-Expression $fnAst.Extent.Text
}

$base = Join-Path $env:TEMP 'grok-folder-picker-test'
if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
$parent = Join-Path $base 'Parent'
$child = Join-Path $parent 'DSHPlugin'
$other = Join-Path $parent 'OtherFolder'
$inner = Join-Path $child 'Inner'
New-Item -ItemType Directory -Force -Path $other, $inner | Out-Null

$logDir = Join-Path $env:TEMP 'grok-folder-picker-logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$pickerLog = Join-Path $logDir 'picker.log'
$uiLog = Join-Path $logDir 'ui.log'
Remove-Item -LiteralPath $pickerLog, $uiLog -ErrorAction SilentlyContinue

function Show-Logs {
    foreach ($file in @($pickerLog, $uiLog)) {
        Write-Host "---- $file"
        if (Test-Path -LiteralPath $file) { Get-Content -LiteralPath $file | ForEach-Object { Write-Host $_ } }
    }
}

[PickUiDriver]::ButtonName = -join @(
    [char]0x9009, [char]0x62E9, [char]0x6587, [char]0x4EF6, [char]0x5939
)
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles() | Out-Null
$owner = New-Object System.Windows.Forms.Form
$owner.ShowInTaskbar = $false
$owner.FormBorderStyle = 'FixedToolWindow'
$owner.StartPosition = 'Manual'
$owner.SetBounds(80, 80, 220, 80)
$owner.Text = 'picker-test-owner'
$script:picked = $null
$script:picked2 = $null
$script:uiResult = $null
$script:uiResult2 = $null
$script:pickErr = $null
$owner.Add_Shown({
    try {
        [PickUiDriver]::Start('GrokPickTest', 'DSHPlugin', $uiLog)
        $script:picked = Select-GrokFolderPath -Owner $owner -StartPath $parent -Title 'GrokPickTest' -DebugLog $pickerLog
        for ($i = 0; $i -lt 20 -and -not $script:uiResult; $i++) {
            $script:uiResult = [PickUiDriver]::Result
            if (-not $script:uiResult) { Start-Sleep -Milliseconds 100 }
        }
        [PickUiDriver]::Start('GrokPickTest', '', $uiLog)
        $script:picked2 = Select-GrokFolderPath -Owner $owner -StartPath $child -Title 'GrokPickTest' -DebugLog $pickerLog
        for ($i = 0; $i -lt 20 -and -not $script:uiResult2; $i++) {
            $script:uiResult2 = [PickUiDriver]::Result
            if (-not $script:uiResult2) { Start-Sleep -Milliseconds 100 }
        }
    } catch {
        $script:pickErr = $_
    }
    $owner.Close()
})
Ensure-GrokFolderPickerType
[System.Windows.Forms.Application]::Run($owner)
if ($script:pickErr) {
    Show-Logs
    throw $script:pickErr
}
$picked = $script:picked
$picked2 = $script:picked2
$uiResult = $script:uiResult
$uiResult2 = $script:uiResult2
if ($uiResult -ne 'closed after 1') {
    Show-Logs
    throw ("highlight click should close on the first button press, ui=$uiResult picked=$picked")
}
$expect = [System.IO.Path]::GetFullPath($child)
if ($picked -ne $expect) {
    Show-Logs
    throw ("highlighted folder was not returned. expect=$expect got=$picked")
}
$expect2 = [System.IO.Path]::GetFullPath($child)
if ($picked2 -ne $expect2) {
    Show-Logs
    throw ("open folder with nothing clicked should stay $expect2, ui=$uiResult2 got=$picked2")
}

Remove-Item -LiteralPath $base -Recurse -Force
Write-Host ("GREEN highlight=$picked current=$picked2 ui=$uiResult/$uiResult2")
Write-Host 'PASS'
exit 0
