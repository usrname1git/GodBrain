' Double-click door helper. No console. Not Heal.
' Win11 default terminal is Windows Terminal. start pwsh -WindowStyle Hidden
' from a .cmd opens an empty WT window. Wscript.Shell Run 0 does not.
Option Explicit
Dim fso, sh, kit, gui, pwsh, pf, windir, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("Wscript.Shell")
kit = fso.GetParentFolderName(Wscript.ScriptFullName)
gui = kit & "\ps1\Reclaim11.ps1"
If Not fso.FileExists(gui) Then
  sh.Popup "Reclaim11: missing ps1\Reclaim11.ps1", 8, "Reclaim11", 16
  Wscript.Quit 1
End If
pf = sh.ExpandEnvironmentStrings("%ProgramFiles%")
windir = sh.ExpandEnvironmentStrings("%SystemRoot%")
pwsh = ""
If fso.FileExists("C:\pwsh\pwsh.exe") Then pwsh = "C:\pwsh\pwsh.exe"
If pwsh = "" Then
  If fso.FileExists(pf & "\PowerShell\7\pwsh.exe") Then pwsh = pf & "\PowerShell\7\pwsh.exe"
End If
If pwsh = "" Then
  If fso.FileExists(pf & "\PowerShell\pwsh.exe") Then pwsh = pf & "\PowerShell\pwsh.exe"
End If
If pwsh = "" Then pwsh = windir & "\System32\WindowsPowerShell\v1.0\powershell.exe"
If InStr(1, pwsh, "WindowsApps", vbTextCompare) > 0 Then
  sh.Popup "Reclaim11: refusing WindowsApps PowerShell stub", 8, "Reclaim11", 16
  Wscript.Quit 1
End If
If Not fso.FileExists(pwsh) Then
  sh.Popup "Reclaim11: no PowerShell found", 8, "Reclaim11", 16
  Wscript.Quit 1
End If
cmd = """" & pwsh & """ -STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & gui & """"
sh.Run cmd, 0, False
