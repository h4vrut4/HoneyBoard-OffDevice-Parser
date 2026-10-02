[CmdletBinding()]
param(
    [string]$AvdName = 'HoneyboardParserApi34',
    [ValidateRange(5554, 5682)]
    [ValidateScript({ ($_ % 2) -eq 0 })]
    [int]$Port = 5554,
    [string]$ConfigPath,
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Common.ps1')

function Find-HbSdkCommand {
    param(
        [Parameter(Mandatory = $true)][string]$SdkRoot,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $preferred = @(
        (Join-Path $SdkRoot ('cmdline-tools\latest\bin\' + $Name)),
        (Join-Path $SdkRoot ('cmdline-tools\bin\' + $Name)),
        (Join-Path $SdkRoot ('tools\bin\' + $Name))
    )

    foreach ($candidate in $preferred) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }

    $cmdlineRoot = Join-Path $SdkRoot 'cmdline-tools'
    if (Test-Path -LiteralPath $cmdlineRoot -PathType Container) {
        $matches = @(Get-ChildItem -LiteralPath $cmdlineRoot -Filter $Name -File -Recurse |
            Sort-Object -Property FullName -Descending)
        if ($matches.Count -gt 0) {
            return $matches[0].FullName
        }
    }

    throw "Android SDK Command-line Tools not found: $Name under $SdkRoot"
}

function Get-HbAvdHome {
    if ($env:ANDROID_AVD_HOME) {
        return [IO.Path]::GetFullPath($env:ANDROID_AVD_HOME)
    }
    if ($env:ANDROID_USER_HOME) {
        return [IO.Path]::GetFullPath((Join-Path $env:ANDROID_USER_HOME 'avd'))
    }
    return [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.android\avd'))
}

function Get-HbAvdConfigPath {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$AvdHome
    )

    $iniPath = Join-Path $AvdHome ($Name + '.ini')
    if (Test-Path -LiteralPath $iniPath -PathType Leaf) {
        $pathLine = Get-Content -LiteralPath $iniPath | Where-Object { $_ -like 'path=*' } | Select-Object -First 1
        if ($pathLine) {
            return Join-Path $pathLine.Substring(5) 'config.ini'
        }
    }

    return Join-Path (Join-Path $AvdHome ($Name + '.avd')) 'config.ini'
}

function Set-HbIniValue {
    param(
        [Parameter(Mandatory = $true)][System.Collections.Generic.List[string]]$Lines,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $replacement = $Key + '=' + $Value
    $keyPattern = '^\s*' + [Regex]::Escape($Key) + '\s*='
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match $keyPattern) {
            $Lines[$index] = $replacement
            return
        }
    }
    $Lines.Add($replacement)
}

function Get-HbRunningAvdSerial {
    param(
        [Parameter(Mandatory = $true)][string]$Adb,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $deviceLines = @(& $Adb devices 2>$null)
    foreach ($line in $deviceLines) {
        if ($line -notmatch '^(emulator-\d+)\s+device(?:\s|$)') {
            continue
        }

        $candidateSerial = $Matches[1]
        $reportedName = @(& $Adb -s $candidateSerial emu avd name 2>$null) |
            Where-Object { $_ -and $_ -ne 'OK' } |
            Select-Object -First 1
        if ($reportedName -and $reportedName.Trim() -eq $Name) {
            return $candidateSerial
        }
    }

    return $null
}

function Get-HbFreeEmulatorPort {
    param(
        [Parameter(Mandatory = $true)][string]$Adb,
        [Parameter(Mandatory = $true)][int]$PreferredPort
    )

    $usedSerials = @(& $Adb devices 2>$null | ForEach-Object {
        if ($_ -match '^(emulator-(\d+))\s+') { [int]$Matches[2] }
    })
    $listeners = @([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() |
        ForEach-Object { $_.Port })

    $ports = @($PreferredPort) + @(5554..5682 | Where-Object { ($_ % 2) -eq 0 -and $_ -ne $PreferredPort })
    foreach ($candidate in $ports) {
        if (($usedSerials -notcontains $candidate) -and
            ($listeners -notcontains $candidate) -and
            ($listeners -notcontains ($candidate + 1))) {
            return $candidate
        }
    }

    throw 'No free Android emulator console port was found between 5554 and 5682.'
}

function Wait-HbAdbDevice {
    param(
        [Parameter(Mandatory = $true)][string]$Adb,
        [Parameter(Mandatory = $true)][string]$Serial,
        [Parameter(Mandatory = $true)][datetime]$Deadline
    )

    do {
        $stateOutput = $null
        $savedErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $stateOutput = & $Adb -s $Serial get-state 2>$null
        } finally {
            $ErrorActionPreference = $savedErrorActionPreference
        }
        $state = [Convert]::ToString($stateOutput)
        if ($state.Trim() -eq 'device') {
            return
        }
        if ((Get-Date) -gt $Deadline) {
            throw "Timed out waiting for adb device: $Serial"
        }
        Start-Sleep -Seconds 1
    } while ($true)
}

$repoRoot = Get-HbRepoRoot
$config = Get-HbConfiguration -ConfigPath $ConfigPath
$sdkSetting = if ($env:HB_ANDROID_SDK) { $env:HB_ANDROID_SDK } else { [string]$config.AndroidSdk }
$javaSetting = if ($env:HB_JAVA_HOME) { $env:HB_JAVA_HOME } else { [string]$config.JavaHome }
$sdkRoot = Resolve-HbPath -Path $sdkSetting -RepoRoot $repoRoot
$javaCandidate = Resolve-HbPath -Path $javaSetting -RepoRoot $repoRoot
$javaHome = Resolve-HbJavaHome -Candidate $javaCandidate

if (-not (Test-Path -LiteralPath $sdkRoot -PathType Container)) {
    throw "Android SDK root not found: $sdkRoot"
}

$sdkManager = Find-HbSdkCommand -SdkRoot $sdkRoot -Name 'sdkmanager.bat'
$avdManager = Find-HbSdkCommand -SdkRoot $sdkRoot -Name 'avdmanager.bat'
$emulator = Join-Path $sdkRoot 'emulator\emulator.exe'
$adb = Join-Path $sdkRoot 'platform-tools\adb.exe'
$systemImage = 'system-images;android-34;google_apis;x86_64'
$packages = @(
    'platform-tools',
    'emulator',
    'platforms;android-34',
    'build-tools;34.0.0',
    $systemImage
)

$env:JAVA_HOME = $javaHome
$env:ANDROID_SDK_ROOT = $sdkRoot
$env:ANDROID_HOME = $sdkRoot

Write-Host '[*] Checking Android SDK licenses (answer y if prompted)...'
& $sdkManager ("--sdk_root=$sdkRoot") --licenses
if ($LASTEXITCODE -ne 0) {
    throw "Android SDK license check failed with exit code $LASTEXITCODE"
}

Write-Host '[*] Installing required Android SDK packages...'
& $sdkManager ("--sdk_root=$sdkRoot") @packages
if ($LASTEXITCODE -ne 0) {
    throw "Android SDK package installation failed with exit code $LASTEXITCODE"
}

foreach ($requiredPath in @($emulator, $adb)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required Android SDK executable not found after installation: $requiredPath"
    }
}

$avdHome = Get-HbAvdHome
$env:ANDROID_AVD_HOME = $avdHome
if (-not (Test-Path -LiteralPath $avdHome -PathType Container)) {
    $null = New-Item -ItemType Directory -Path $avdHome -Force
}

$installedAvds = @(& $emulator -list-avds | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($installedAvds -notcontains $AvdName) {
    Write-Host "[*] Creating AVD $AvdName..."
    $createOutput = @()
    $createExitCode = 0
    $savedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $createOutput = @('no' | & $avdManager create avd --force --name $AvdName --package $systemImage --device 'pixel_6' 2>&1)
        $createExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    if ($createExitCode -ne 0) {
        $createOutput | Out-Host
        throw "AVD creation failed with exit code $createExitCode"
    }
    $createOutput | Where-Object { $_ -notmatch '^Error: .*devices\.xml\s*$' } | Out-Host
} else {
    Write-Host "[*] Reusing existing AVD $AvdName."
}

$avdConfigPath = Get-HbAvdConfigPath -Name $AvdName -AvdHome $avdHome
if (-not (Test-Path -LiteralPath $avdConfigPath -PathType Leaf)) {
    throw "AVD config not found: $avdConfigPath"
}

$configText = Get-Content -LiteralPath $avdConfigPath -Raw
if ($configText -notmatch '(?m)^\s*image\.sysdir\.1\s*=.*android-34.*google_apis.*x86_64') {
    throw "Existing AVD '$AvdName' does not use $systemImage. Choose a different -AvdName."
}

$configLines = [System.Collections.Generic.List[string]]::new()
Get-Content -LiteralPath $avdConfigPath | ForEach-Object { $configLines.Add($_) }
Set-HbIniValue -Lines $configLines -Key 'hw.ramSize' -Value '2048'
Set-HbIniValue -Lines $configLines -Key 'hw.cpu.ncore' -Value '4'
Set-HbIniValue -Lines $configLines -Key 'disk.dataPartition.size' -Value '4G'
Set-HbIniValue -Lines $configLines -Key 'PlayStore.enabled' -Value 'no'
Set-HbIniValue -Lines $configLines -Key 'fastboot.forceColdBoot' -Value 'yes'
Set-HbIniValue -Lines $configLines -Key 'fastboot.forceFastBoot' -Value 'no'
[IO.File]::WriteAllLines($avdConfigPath, $configLines, [Text.UTF8Encoding]::new($false))

Write-Host "[+] AVD ready: $AvdName"
Write-Host "[+] AVD home: $avdHome"
if ($NoStart) {
    Write-Host '[+] Setup complete. Start the AVD manually or run this script again without -NoStart.'
    return
}

$serial = Get-HbRunningAvdSerial -Adb $adb -Name $AvdName
if (-not $serial) {
    $selectedPort = Get-HbFreeEmulatorPort -Adb $adb -PreferredPort $Port
    $serial = 'emulator-' + $selectedPort
    Write-Host "[*] Starting $AvdName as $serial..."
    $null = Start-Process -FilePath $emulator -ArgumentList @(
        '-avd', $AvdName,
        '-port', [string]$selectedPort,
        '-gpu', 'swiftshader_indirect',
        '-no-snapshot-load',
        '-no-snapshot-save',
        '-no-boot-anim'
    )
} else {
    Write-Host "[*] AVD is already running as $serial."
}

$deadline = (Get-Date).AddMinutes(5)
Wait-HbAdbDevice -Adb $adb -Serial $serial -Deadline $deadline
do {
    if ((Get-Date) -gt $deadline) {
        throw "Timed out waiting for Android to boot: $serial"
    }
    Start-Sleep -Seconds 2
    $bootCompleted = [string](& $adb -s $serial shell getprop sys.boot_completed 2>$null)
} until ($bootCompleted -eq '1')

& $adb -s $serial root | Out-Host
Wait-HbAdbDevice -Adb $adb -Serial $serial -Deadline ((Get-Date).AddSeconds(30))
$identity = ([string](& $adb -s $serial shell id 2>$null)).Trim()
if ($identity -notmatch 'uid=0\(root\)') {
    throw "The emulator does not provide adb root: $identity"
}

$nativeBridge = ([string](& $adb -s $serial shell getprop ro.dalvik.vm.native.bridge 2>$null)).Trim()
if ($nativeBridge -ne 'libndk_translation.so') {
    throw "ARM64 native translation is unavailable (ro.dalvik.vm.native.bridge='$nativeBridge')."
}

Write-Host "[+] AVD name: $AvdName"
Write-Host "[+] ADB serial: $serial"
Write-Host "[+] adb root: $identity"
Write-Host "[+] ARM64 bridge: $nativeBridge"
Write-Host '[+] Emulator setup complete.'
Write-Host ("    .\scripts\Extract.ps1 -Serial '" + $serial + "'")
