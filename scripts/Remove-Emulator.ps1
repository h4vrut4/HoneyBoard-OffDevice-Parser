[CmdletBinding()]
param(
    [string]$AvdName = 'HoneyboardParserApi34',
    [string]$ConfigPath
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

function Invoke-HbAdb {
    param(
        [Parameter(Mandatory = $true)][string]$Adb,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $output = @()
    $exitCode = 0
    $savedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $Adb @Arguments 2>$null)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    return [pscustomobject]@{ Output = $output; ExitCode = $exitCode }
}

$repoRoot = Get-HbRepoRoot
$config = Get-HbConfiguration -ConfigPath $ConfigPath
$sdkSetting = if ($env:HB_ANDROID_SDK) { $env:HB_ANDROID_SDK } else { [string]$config.AndroidSdk }
$javaSetting = if ($env:HB_JAVA_HOME) { $env:HB_JAVA_HOME } else { [string]$config.JavaHome }
$sdkRoot = Resolve-HbPath -Path $sdkSetting -RepoRoot $repoRoot
$javaCandidate = Resolve-HbPath -Path $javaSetting -RepoRoot $repoRoot
$javaHome = Resolve-HbJavaHome -Candidate $javaCandidate
$avdManager = Find-HbSdkCommand -SdkRoot $sdkRoot -Name 'avdmanager.bat'
$emulator = Join-Path $sdkRoot 'emulator\emulator.exe'
$adb = Join-Path $sdkRoot 'platform-tools\adb.exe'

foreach ($requiredPath in @($emulator, $adb)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required Android SDK executable not found: $requiredPath"
    }
}

$env:JAVA_HOME = $javaHome
$env:ANDROID_SDK_ROOT = $sdkRoot
$env:ANDROID_HOME = $sdkRoot

$installedAvds = @(& $emulator -list-avds | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($installedAvds -notcontains $AvdName) {
    Write-Host "[+] AVD is already absent: $AvdName"
    return
}

$deviceResult = Invoke-HbAdb -Adb $adb -Arguments @('devices')
foreach ($line in $deviceResult.Output) {
    if ($line -notmatch '^(emulator-\d+)\s+device(?:\s|$)') {
        continue
    }

    $serial = $Matches[1]
    $nameResult = Invoke-HbAdb -Adb $adb -Arguments @('-s', $serial, 'emu', 'avd', 'name')
    $runningName = $nameResult.Output | Where-Object { $_ -and $_ -ne 'OK' } | Select-Object -First 1
    if (-not $runningName -or $runningName.Trim() -ne $AvdName) {
        continue
    }

    Write-Host "[*] Stopping $AvdName ($serial)..."
    $stopResult = Invoke-HbAdb -Adb $adb -Arguments @('-s', $serial, 'emu', 'kill')
    if ($stopResult.ExitCode -ne 0) {
        throw "Failed to stop $AvdName ($serial). Close the emulator and retry."
    }

    $deadline = (Get-Date).AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 500
        $stillListed = (Invoke-HbAdb -Adb $adb -Arguments @('devices')).Output -match ('^' + [Regex]::Escape($serial) + '\s')
    } while ($stillListed -and (Get-Date) -lt $deadline)
    if ($stillListed) {
        throw "Timed out waiting for $serial to stop."
    }
}

Write-Host "[*] Deleting AVD $AvdName..."
& $avdManager delete avd --name $AvdName
$deleteExitCode = $LASTEXITCODE
Write-Host
if ($deleteExitCode -ne 0) {
    throw "AVD deletion failed with exit code $deleteExitCode"
}

$remainingAvds = @(& $emulator -list-avds | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($remainingAvds -contains $AvdName) {
    throw "AVD still exists after deletion: $AvdName"
}

Write-Host "[+] Removed AVD: $AvdName"
Write-Host '[+] Shared Android SDK packages were kept.'
Write-Host '[+] Recreate it with: .\scripts\Setup-Emulator.ps1'
