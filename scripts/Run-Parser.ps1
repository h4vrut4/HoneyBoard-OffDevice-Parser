[CmdletBinding()]
param(
    [string]$HostApk = 'output/host/honeyboard-parser-host.apk',
    [string]$ModelDir = 'input/model',
    [string]$Serial,
    [string]$OutputLog,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Common.ps1')

$toolchain = Get-HbToolchain -ConfigPath $ConfigPath -RequireFrida
$repoRoot = $toolchain.RepoRoot
$hostPath = Resolve-HbUserPath -Path $HostApk
$modelPath = Resolve-HbUserPath -Path $ModelDir
$adb = $toolchain.Adb

function Push-HbFile {
    param(
        [Parameter(Mandatory = $true)][string]$LocalPath,
        [Parameter(Mandatory = $true)][string]$RemotePath
    )

    $savedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $pushOutput = @(& $adb -s $Serial push $LocalPath $RemotePath 2>&1)
        $pushExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    if ($pushExitCode -ne 0) {
        $pushOutput | Out-Host
        throw "Failed to push file to the emulator: $LocalPath"
    }
}

if (-not $Serial) {
    $emulators = @((& $adb devices) | ForEach-Object {
        $line = $_.ToString().Trim()
        if ($line -match '^(emulator-\d+)\s+device$') { $Matches[1] }
    })
    if ($emulators.Count -eq 0) {
        throw 'No running Android emulator found. Start one, or pass -Serial explicitly.'
    }
    if ($emulators.Count -gt 1) {
        throw "Multiple running Android emulators found: $($emulators -join ', '). Pass -Serial explicitly."
    }
    $Serial = $emulators[0]
}
if (-not $OutputLog) {
    $OutputLog = Join-Path $repoRoot ('output\logs\parse-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
} else {
    $OutputLog = Resolve-HbUserPath -Path $OutputLog
}

foreach ($path in @($hostPath, (Join-Path $modelPath 'dynamic.lm'), (Join-Path $modelPath 'learned.json'))) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required input not found: $path"
    }
}

$clientVersionOutput = & $toolchain.FridaClient --version 2>$null
$clientVersion = if ($null -eq $clientVersionOutput) { '' } else { (($clientVersionOutput -join '')).Trim() }
if (-not $clientVersion) { throw 'Unable to determine the Frida client version.' }

$qemuOutput = & $adb -s $Serial shell getprop ro.kernel.qemu 2>$null
$qemu = if ($null -eq $qemuOutput) { '' } else { (($qemuOutput -join '')).Trim() }
if ($qemu -ne '1') {
    throw "Refusing to run on non-emulator target '$Serial'. ro.kernel.qemu='$qemu'"
}

& $adb -s $Serial root | Out-Null
Start-Sleep -Seconds 2
& $adb -s $Serial wait-for-device
& $adb -s $Serial shell setenforce 0 2>$null

$remoteRoot = '/data/local/tmp/hb_offdevice'
$remoteModel = "$remoteRoot/model"
& $adb -s $Serial shell "mkdir -p $remoteModel"
Push-HbFile -LocalPath (Join-Path $modelPath 'dynamic.lm') -RemotePath "$remoteModel/dynamic.lm"
Push-HbFile -LocalPath (Join-Path $modelPath 'learned.json') -RemotePath "$remoteModel/learned.json"
& $adb -s $Serial shell "chmod 0444 $remoteModel/dynamic.lm $remoteModel/learned.json"
$beforeHashes = ((& $adb -s $Serial shell "sha256sum $remoteModel/dynamic.lm $remoteModel/learned.json") -join "`n").Trim()

$serverPidOutput = & $adb -s $Serial shell pidof frida-server 2>$null
$serverPid = if ($null -eq $serverPidOutput) { '' } else { (($serverPidOutput -join '')).Trim() }
if (-not $serverPid) {
    Push-HbFile -LocalPath $toolchain.FridaServer -RemotePath '/data/local/tmp/frida-server'
    & $adb -s $Serial shell chmod 0755 /data/local/tmp/frida-server
    & $adb -s $Serial shell 'nohup /data/local/tmp/frida-server >/data/local/tmp/frida-server.log 2>&1 &'
    Start-Sleep -Seconds 1
    $serverPidOutput = & $adb -s $Serial shell pidof frida-server 2>$null
    $serverPid = if ($null -eq $serverPidOutput) { '' } else { (($serverPidOutput -join '')).Trim() }
    if (-not $serverPid) { throw 'Frida server did not start.' }
}

$serverVersionOutput = & $adb -s $Serial shell /data/local/tmp/frida-server --version 2>$null
$serverVersion = if ($null -eq $serverVersionOutput) { '' } else { (($serverVersionOutput -join '')).Trim() }
if ($serverVersion -ne $clientVersion) {
    throw "Frida version mismatch: client=$clientVersion server=$serverVersion. Use matching client/server binaries."
}

& $adb -s $Serial shell am force-stop com.example.hbhost | Out-Null
$savedErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$installRaw = & $adb -s $Serial install -r $hostPath 2>&1
$installExitCode = $LASTEXITCODE
$installOutput = @($installRaw | ForEach-Object { $_.ToString() })
if ($installExitCode -ne 0 -and (($installOutput -join "`n") -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE')) {
    # The package is a disposable emulator-only host. A locally generated
    # debug key can differ when the repository is moved to another machine.
    & $adb -s $Serial uninstall com.example.hbhost | Out-Null
    $installRaw = & $adb -s $Serial install $hostPath 2>&1
    $installExitCode = $LASTEXITCODE
    $installOutput = @($installRaw | ForEach-Object { $_.ToString() })
}
$ErrorActionPreference = $savedErrorActionPreference
if ($installExitCode -ne 0) {
    $installOutput | Out-Host
    throw "adb install failed with exit code $installExitCode"
}
& $adb -s $Serial shell am start -n com.example.hbhost/.MainActivity | Out-Null
$hbHostPid = ''
for ($attempt = 0; $attempt -lt 30; $attempt++) {
    $hbHostPidOutput = & $adb -s $Serial shell pidof com.example.hbhost 2>$null
    $hbHostPid = if ($null -eq $hbHostPidOutput) { '' } else { (($hbHostPidOutput -join '')).Trim() }
    if ($hbHostPid) { break }
    Start-Sleep -Milliseconds 500
}
if (-not $hbHostPid) { throw 'Parser host process was not found.' }

$agent = Join-Path $repoRoot 'frida\parse_dynamic_lm.js'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
$output = & $toolchain.FridaClient -D $Serial -p $hbHostPid -q -l $agent 2>&1

$logDir = Split-Path -Parent $OutputLog
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$output | Tee-Object -FilePath $OutputLog | Out-Host

$completed = [bool]($output -match '\[HB-OFFDEVICE\] completed')
if (-not $completed) { throw "Parser did not complete. See: $OutputLog" }

$afterHashes = ((& $adb -s $Serial shell "sha256sum $remoteModel/dynamic.lm $remoteModel/learned.json") -join "`n").Trim()
if ($beforeHashes -ne $afterHashes) {
    throw 'Model hashes changed during parsing.'
}
