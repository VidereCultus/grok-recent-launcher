Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = root & "\GrokRecent.ps1"
cmd = "powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """"
' 1 = normal. Do not use 0 (SW_HIDE): it hides the WinForms window too.
CreateObject("Wscript.Shell").Run cmd, 1, False
