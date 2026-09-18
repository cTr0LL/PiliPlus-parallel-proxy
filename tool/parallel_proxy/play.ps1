# Starts the proxy, waits for its local URL, plays it in mpv, and shuts the
# proxy down afterwards. Saves juggling two terminals and a pasted URL.
#
# Windows blocks .ps1 files by default, so invoke it like this:
#
#   powershell -ExecutionPolicy Bypass -File .\tool\play.ps1
#   powershell -ExecutionPolicy Bypass -File .\tool\play.ps1 -Seek
#   powershell -ExecutionPolicy Bypass -File .\tool\play.ps1 -Decode
#   powershell -ExecutionPolicy Bypass -File .\tool\play.ps1 -Check
#
#   -Seek    headless repeated-seek stress test
#   -Decode  headless full decode, errors only
#   -Check   resolve mpv + print the URL, then exit without playing
#
# (Or run Set-ExecutionPolicy -Scope CurrentUser RemoteSigned once, after which
# .\tool\play.ps1 works directly. No admin needed either way.)
#
# Run from the PiliPlus repo root, the way tool/jnigen.dart is run. mpv is
# located by full path because the shinchiro winget build does not add itself
# to PATH.
param(
    [switch]$Seek,
    [switch]$Decode,
    [switch]$Check,
    [string]$MpvPath = ""
)

$ErrorActionPreference = "Stop"

function Resolve-Mpv {
    param([string]$Explicit)
    if ($Explicit -ne "") {
        if (Test-Path $Explicit) { return $Explicit }
        throw "mpv not found at $Explicit"
    }
    $onPath = Get-Command mpv -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    $candidates = @(
        "C:\Program Files\MPV Player\mpv.exe",
        "C:\Program Files\mpv\mpv.exe",
        "$env:LOCALAPPDATA\Programs\mpv\mpv.exe",
        "$env:LOCALAPPDATA\Microsoft\WinGet\Links\mpv.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    throw "Could not find mpv.exe. Pass -MpvPath 'C:\path\to\mpv.exe'."
}

# Runs mpv with its streams captured to files and waits for it to finish.
#
# Deliberately not the call operator: invoked as `& mpv ...`, mpv inherits the
# caller's stdin, and in any environment where stdin is closed or redirected
# (CI, a tool harness, a piped shell) it sees EOF on the terminal input it
# watches for keypresses and exits immediately - producing no output and no
# error, which is indistinguishable from a playback failure. Start-Process
# gives it a clean stdio setup.
# Exit code comes back here rather than as a return value: everything a
# PowerShell function writes to the pipeline is part of its return value, so
# returning the code as well would glue it onto mpv's log lines.
$script:MpvExit = $null

function Invoke-MpvHeadless {
    param([string]$Exe, [string[]]$MpvArgs)

    $o = [System.IO.Path]::GetTempFileName()
    $e = [System.IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath $Exe -ArgumentList $MpvArgs `
            -RedirectStandardOutput $o -RedirectStandardError $e `
            -NoNewWindow -Wait -PassThru
        Get-Content $o -ErrorAction SilentlyContinue
        Get-Content $e -ErrorAction SilentlyContinue
        $script:MpvExit = $p.ExitCode
    } finally {
        Remove-Item $o -ErrorAction SilentlyContinue
        Remove-Item $e -ErrorAction SilentlyContinue
    }
}

if (-not (Test-Path "tool/parallel_proxy/dev_server.dart")) {
    throw "Run this from the PiliPlus repo root, not from tool/parallel_proxy."
}
if (-not (Test-Path "tool/parallel_proxy/urls.txt")) {
    throw "tool/parallel_proxy/urls.txt not found. Grab fresh URLs from the browser first."
}

$mpv = Resolve-Mpv -Explicit $MpvPath
Write-Output "mpv: $mpv"

$dart = Get-Command dart -ErrorAction SilentlyContinue
$dartExe = if ($dart) { $dart.Source } else { "C:\src\flutter\bin\dart.bat" }

# Unique per run. A fixed filename can still be locked by a proxy left over from
# an earlier run; the redirect then fails silently and we read STALE urls
# pointing at a dead server, which looks like mpv failing for no reason.
$stamp = [guid]::NewGuid().ToString('N').Substring(0, 8)
$log = Join-Path $env:TEMP "parallel_proxy_$stamp.log"
$err = Join-Path $env:TEMP "parallel_proxy_$stamp.err"

$proc = Start-Process -FilePath $dartExe `
    -ArgumentList "run", "tool/parallel_proxy/dev_server.dart" `
    -RedirectStandardOutput $log -RedirectStandardError $err `
    -WindowStyle Hidden -PassThru
Write-Output "proxy pid: $($proc.Id)"

try {
    $url = $null
    $audioUrl = $null
    for ($i = 0; $i -lt 60; $i++) {
        # Start-Process creates the log immediately but dart takes a few seconds
        # to compile and print. -Raw returns $null for an existing-but-empty
        # file, and [regex]::Match throws on null input, so guard before using it.
        $text = $null
        if (Test-Path $log) {
            $text = Get-Content $log -Raw -ErrorAction SilentlyContinue
        }
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $v = [regex]::Match($text, 'video:\s*(http://127\.0\.0\.1:\d+/v/\w+)')
            $a = [regex]::Match($text, 'audio:\s*(http://127\.0\.0\.1:\d+/v/\w+)')
            if ($v.Success) {
                $url = $v.Groups[1].Value
                if ($a.Success) { $audioUrl = $a.Groups[1].Value }
                break
            }
        }
        Start-Sleep -Milliseconds 500
    }
    if (-not $url) {
        Write-Output "proxy never printed a URL:"
        Get-Content $log, $err -ErrorAction SilentlyContinue
        return
    }
    Write-Output "video: $url"
    if ($audioUrl) {
        Write-Output "audio: $audioUrl"
    } else {
        Write-Output "audio: NONE - playback will be silent."
        Write-Output "       bilibili serves audio as a separate DASH file."
        Write-Output "       Re-copy urls.txt with an [audio] section."
    }
    Write-Output ""

    # mpv takes the audio track as an external file; DASH keeps them apart.
    $extra = @()
    if ($audioUrl) { $extra += "--audio-file=$audioUrl" }

    if ($Check) { Write-Output "-Check: not launching mpv."; return }

    # --frames / --length would cut mpv off mid-packet and print bogus
    # "Invalid NAL unit size" errors, so the headless modes never use them.
    $base = @("--no-config", "--no-input-terminal", "--vo=null", "--ao=null")

    if ($Seek) {
        $seekScript = (Resolve-Path "tool/parallel_proxy/seek_stress.lua").Path
        Invoke-MpvHeadless -Exe $mpv -MpvArgs (
            $base + $extra + @("--script=$seekScript",
                "--msg-level=all=error,seek_stress=info", $url))
        Write-Output "mpv exit: $($script:MpvExit)"
    } elseif ($Decode) {
        Invoke-MpvHeadless -Exe $mpv -MpvArgs (
            $base + @("--untimed") + $extra + @("--msg-level=all=error", $url))
        if ($script:MpvExit -eq 0) {
            Write-Output "full decode finished with no errors"
        } else {
            Write-Output "mpv exit: $($script:MpvExit)"
        }
    } else {
        # Windowed: let mpv own the console so keyboard controls work.
        & $mpv @extra $url
    }
} finally {
    # taskkill /T, not Stop-Process: dart.bat is a cmd wrapper that spawns
    # dart.exe as a CHILD. Killing the wrapper alone orphans the real proxy,
    # which keeps running and holding its port - they pile up fast.
    & taskkill.exe /T /F /PID $proc.Id 2>&1 | Out-Null
    if (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $log -ErrorAction SilentlyContinue
    Remove-Item $err -ErrorAction SilentlyContinue
    Write-Output "proxy stopped."
}
