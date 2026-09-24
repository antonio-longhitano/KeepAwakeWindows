Set objShell = CreateObject("WScript.Shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")

scriptPath = objFSO.GetParentFolderName(WScript.ScriptFullName)
ps1 = scriptPath & "\KeepAwake.ps1"

objShell.Run "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """", 0, False