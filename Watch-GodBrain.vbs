' Windowless Watch launcher. pwsh -WindowStyle Hidden still flashes a
' Windows Terminal tab on this host. wscript Run 0 does not.
Option Explicit
Dim sh, repo, watch, pwsh, cmd
Set sh = CreateObject("WScript.Shell")
repo = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
watch = repo & "\Watch-GodBrain.ps1"
pwsh = "C:\pwsh\pwsh.exe"
If CreateObject("Scripting.FileSystemObject").FileExists(pwsh) = False Then
    pwsh = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
End If
cmd = """" & pwsh & """ -NoProfile -WindowStyle Hidden -File """ & watch & """ -RepoRoot """ & repo & """"
sh.Run cmd, 0, False
