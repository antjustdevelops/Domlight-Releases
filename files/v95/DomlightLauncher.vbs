Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
base = fso.GetParentFolderName(WScript.ScriptFullName)
flag = base & "\update_transition.flag"
If fso.FileExists(flag) Then
    On Error Resume Next
    fso.DeleteFile flag, True
    On Error GoTo 0
    WScript.Sleep 1500
End If
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & base & "\MENU_DOMLIGHT.ps1"""
shell.Run cmd, 0, False
