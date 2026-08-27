Option Explicit

Dim shell, fso, sourceDir, powershell, installer, configPath, keyPath, command, exitCode
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

sourceDir = fso.GetParentFolderName(WScript.ScriptFullName)
powershell = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
installer = sourceDir & "\install_snipeit_auto.ps1"
configPath = "\\AD-SERVER\snipeit_auto_secure$\snipeit_inventory.local.json"
keyPath = "\\AD-SERVER\snipeit_auto_secure$\snipeit_ldap_sync_ed25519"

command = """" & powershell & """ -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass" & _
          " -File """ & installer & """" & _
          " -ConfigSourcePath """ & configPath & """" & _
          " -SshKeySourcePath """ & keyPath & """"

' 0 keeps the GPO bootstrap fully invisible; True serializes one installer run.
exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode
