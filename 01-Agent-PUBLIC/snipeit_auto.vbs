Option Explicit

Dim shell, fso, scriptDir, command, exitCode, i, extraArgs
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
extraArgs = ""
For i = 0 To WScript.Arguments.Count - 1
    extraArgs = extraArgs & " " & Chr(34) & _
                Replace(WScript.Arguments(i), Chr(34), Chr(34) & Chr(34)) & Chr(34)
Next

command = "powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File " & _
          """" & scriptDir & "\snipeit_inventory.ps1" & """ -GpoMode" & extraArgs

' 0 = hidden window, True = wait for the inventory agent to finish.
exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode
