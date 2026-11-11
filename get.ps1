# IT Scripts launcher. Opens IT Scripts on any Windows 10/11 PC:
#
#     irm https://<your link> | iex
#
# Downloads the latest release from github.com/obtusecoder/itsuite-get, unlocks it with your launcher
# password and starts it from C:\ITScripts (logs collect in C:\ITScripts\Logs). If that copy is already
# up to date it just starts it, with no download and no password.
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
    $dir   = if ($env:ITSCRIPTS_LAUNCH_DIR) { $env:ITSCRIPTS_LAUNCH_DIR } else { Join-Path $env:SystemDrive 'ITScripts' }
    $exe   = Join-Path $dir 'ITScripts.exe'

    function Get-Plain([Security.SecureString]$s) {
        $p = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
        try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($p) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p) }
    }

    function Normalise([version]$v) { New-Object Version $v.Major, $v.Minor, ([math]::Max($v.Build, 0)), ([math]::Max($v.Revision, 0)) }

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
    $latest = if ($release) { Normalise ([version]($release.tag_name.TrimStart('v'))) } else { $null }
    $have = $null
    if (Test-Path $exe) { try { $have = Normalise ([version](Get-Item $exe).VersionInfo.FileVersion) } catch { } }

    if ($have -and (-not $latest -or $have -ge $latest)) {
        Write-Host "  Starting IT Scripts $($have.Major).$($have.Minor) from $dir"
        Start-Process $exe
        return
    }
    if (-not $release) { Write-Host '  Try again when this PC is online.' -ForegroundColor Red; return }
    $file = @($release.assets | Where-Object { $_.name -eq $asset })[0]
    if (-not $file) { Write-Host "  The latest release ($($release.tag_name)) can't be opened from the command line. Use the USB stick." -ForegroundColor Red; return }

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
    if (-not $plain) { Write-Host '  Giving up after 3 tries.' -ForegroundColor Red; return }
    if ($plain.Length -lt 1000000 -or $plain[0] -ne 0x4D -or $plain[1] -ne 0x5A) { Write-Host "  The download isn't a valid ITScripts.exe." -ForegroundColor Red; return }

    New-Item -ItemType Directory -Force $dir | Out-Null
    try { [IO.File]::WriteAllBytes($exe, $plain) }
    catch { Write-Host "  Couldn't save $exe - close IT Scripts if it's open, then run this again. ($($_.Exception.Message))" -ForegroundColor Red; return }
    Write-Host "  Saved to $dir. Starting IT Scripts..."
    Start-Process $exe
}
