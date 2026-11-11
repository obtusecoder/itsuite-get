# IT Scripts launcher. Opens IT Scripts on any Windows 10/11 PC:
#
#     irm https://<your link> | iex
#
# Downloads the latest release from github.com/obtusecoder/itsuite-get, unlocks it with your launcher
# password, saves it to a new folder C:\ITScripts\run-xxxx and starts it (IT Scripts asks for admin itself,
# then locks that folder so only administrators can open it). When IT Scripts closes it offers to copy
# anything the tools saved (logs, reports) to the desktop, then deletes the folder (and C:\ITScripts once
# it's empty).
#
# This file is public. The download it fetches is locked with the password (AES-256-CBC + HMAC-SHA256,
# keys from PBKDF2-SHA256), so the link alone gets nobody anything.
# Master copy: launcher\get.ps1 in the private itsuite repo.

& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'   # Windows PowerShell's progress bar makes downloads crawl
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $repo  = 'obtusecoder/itsuite-get'
    $asset = 'ITScripts-launch.bin'
    $root  = if ($env:ITSCRIPTS_LAUNCH_DIR) { $env:ITSCRIPTS_LAUNCH_DIR } else { Join-Path $env:SystemDrive 'ITScripts' }

    function Stop-Launch([string]$Message) { Write-Host "  $Message" -ForegroundColor Red }

    # IT Scripts asks for admin itself (its manifest requires it), so this window never needs to be elevated
    function Start-ITScripts {
        Write-Host '  Starting IT Scripts - approve the admin prompt.'
        try { Start-Process $exe -WorkingDirectory $dir }
        catch {
            if ($_.Exception.NativeErrorCode -eq 1223 -or $_.Exception.Message -match 'cancel') { Stop-Launch "The admin prompt was cancelled, so IT Scripts didn't start. Run the command again to retry." }
            else { Stop-Launch "IT Scripts couldn't start: $($_.Exception.Message)" }
        }
    }

    function Get-Plain([Security.SecureString]$s) {
        $p = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
        try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($p) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p) }
    }


    # Returns the unlocked exe bytes, or $null if the password is wrong. Throws if the file isn't a launcher download.
    function Unlock-ITScripts([byte[]]$Data, [string]$Password) {
        if ($Data.Length -lt 73 -or [Text.Encoding]::ASCII.GetString($Data, 0, 4) -ne 'ITSW' -or $Data[4] -ne 1) {
            throw "The download isn't in the expected format."
        }
        $iterations = [BitConverter]::ToInt32($Data, 5)
        $salt = New-Object byte[] 16; [Array]::Copy($Data, 9, $salt, 0, 16)
        $iv   = New-Object byte[] 16; [Array]::Copy($Data, 25, $iv, 0, 16)
        $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes ([Text.Encoding]::UTF8.GetBytes($Password)), $salt, $iterations, ([Security.Cryptography.HashAlgorithmName]::SHA256)
        $keys = $kdf.GetBytes(64); $kdf.Dispose()
        $encKey = New-Object byte[] 32; [Array]::Copy($keys, 0, $encKey, 0, 32)
        $macKey = New-Object byte[] 32; [Array]::Copy($keys, 32, $macKey, 0, 32)

        $hmac = New-Object Security.Cryptography.HMACSHA256 (, $macKey)
        $mac = $hmac.ComputeHash($Data, 0, $Data.Length - 32); $hmac.Dispose()
        $diff = 0
        for ($i = 0; $i -lt 32; $i++) { $diff = $diff -bor ($mac[$i] -bxor $Data[$Data.Length - 32 + $i]) }
        if ($diff) { return $null }   # wrong password (or a damaged download)

        $aes = [Security.Cryptography.Aes]::Create()
        $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'; $aes.Key = $encKey; $aes.IV = $iv
        try { , $aes.CreateDecryptor().TransformFinalBlock($Data, 41, $Data.Length - 41 - 32) } finally { $aes.Dispose() }
    }

    Write-Host ''
    Write-Host '  IT Scripts' -ForegroundColor Cyan
    Write-Host ''

    $release = $null
    if ($env:ITSCRIPTS_LAUNCH_SOURCE) {
        $release = [pscustomobject]@{ tag_name = $env:ITSCRIPTS_LAUNCH_VERSION; assets = @([pscustomobject]@{ name = $asset; browser_download_url = $env:ITSCRIPTS_LAUNCH_SOURCE; size = (Get-Item $env:ITSCRIPTS_LAUNCH_SOURCE).Length }) }
    } else {
        try { $release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'ITScripts-Launcher' } -TimeoutSec 20 }
        catch { Write-Host "  Couldn't reach GitHub: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    if (-not $release) { Stop-Launch 'Try again when this PC is online.'; return }
    $file = @($release.assets | Where-Object { $_.name -eq $asset })[0]
    if (-not $file) { Stop-Launch "The latest release ($($release.tag_name)) can't be opened from the command line. Use the USB stick."; return }

    Write-Host ("  Downloading IT Scripts {0} ({1:N0} MB)..." -f $release.tag_name.TrimStart('v'), ($file.size / 1MB))
    if ($env:ITSCRIPTS_LAUNCH_SOURCE) { $data = [IO.File]::ReadAllBytes($env:ITSCRIPTS_LAUNCH_SOURCE) }
    else {
        $web = New-Object Net.WebClient
        $web.Headers['User-Agent'] = 'ITScripts-Launcher'
        try { $data = $web.DownloadData($file.browser_download_url) } finally { $web.Dispose() }
    }

    $plain = $null
    for ($try = 1; $try -le 3 -and -not $plain; $try++) {
        $password = if ($env:ITSCRIPTS_LAUNCH_PASSWORD) { $env:ITSCRIPTS_LAUNCH_PASSWORD } else { Get-Plain (Read-Host '  Password' -AsSecureString) }
        $plain = Unlock-ITScripts $data $password
        $password = $null
        if (-not $plain) {
            Write-Host '  Wrong password.' -ForegroundColor Yellow
            if ($env:ITSCRIPTS_LAUNCH_PASSWORD) { break }
        }
    }
    if (-not $plain) { Stop-Launch 'Giving up after 3 tries.'; return }
    if ($plain.Length -lt 1000000 -or $plain[0] -ne 0x4D -or $plain[1] -ne 0x5A) { Stop-Launch "The download isn't a valid ITScripts.exe."; return }

    # A new folder each time, so a folder left by an earlier run (locked to admins) never gets in the way.
    # If C:\ITScripts itself can't be written to (left locked by an older version), use this user's AppData.
    $run = 'run-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $dir = Join-Path $root $run
    try { New-Item -ItemType Directory -Force $dir -ErrorAction Stop | Out-Null }
    catch {
        $root = Join-Path $env:LOCALAPPDATA 'ITScripts'
        $dir = Join-Path $root $run
    }
    $exe = Join-Path $dir 'ITScripts.exe'
    try {
        New-Item -ItemType Directory -Force $dir | Out-Null
        [IO.File]::WriteAllBytes($exe, $plain)
        # Tells IT Scripts it was opened from the link: it locks this folder to administrators while it
        # runs and removes it when it closes
        Set-Content (Join-Path $dir '.opened-from-link') 'Created by the IT Scripts launcher. IT Scripts deletes this folder when it closes.'
    } catch {
        Stop-Launch "Couldn't save IT Scripts to $dir. ($($_.Exception.Message))"
        return
    }
    Start-ITScripts
}
