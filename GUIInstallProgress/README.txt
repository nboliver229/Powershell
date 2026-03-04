GUIInstallProgress (Live Log)
- Log panel is always BELOW the app list.
- Log refresh defaults to 1 second.
- Reads up to the last 1,048,576 bytes (1MB) of Agent.log to match your rotation size.

No console window:
- Run Start-GUIInstallProgress.vbs (recommended), or
- powershell.exe -WindowStyle Hidden -File Start-GUIInstallProgress.ps1 -ExitWhenBrowserClosed
