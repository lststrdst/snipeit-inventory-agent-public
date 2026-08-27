Option Explicit

Dim shell, fso, scriptDir, command, exitCode
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
command = "powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File " & _
          """" & scriptDir & "\snipeit_inventory.ps1" & """ -GpoMode"

' 0 = hidden window, True = wait for the inventory agent to finish.
exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode
