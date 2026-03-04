Set objShell = CreateObject("Wscript.Shell")
ps = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""C:\_build\GUIInstallProgress\Start-GUIInstallProgress.ps1"" -ExitWhenBrowserClosed"
objShell.Run ps, 0, False
