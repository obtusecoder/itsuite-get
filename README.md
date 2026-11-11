# IT Scripts - releases

Release channel for the IT Scripts app.

- Each release holds two encrypted copies of the app:
  - `ITScripts.bin` is for the app's own updates. Only IT Scripts can open it.
  - `ITScripts-launch.bin` is for `get.ps1`. It opens only with the launcher password.
- `get.ps1` opens IT Scripts on a PC from PowerShell. It asks for admin, downloads the latest release, asks for the password and starts the app from `C:\ITScripts` (only admins can open it, and it's deleted when the app closes):

  ```powershell
  irm https://raw.githubusercontent.com/obtusecoder/itsuite-get/main/get.ps1 | iex
  ```
