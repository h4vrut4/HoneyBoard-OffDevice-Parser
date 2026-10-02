Set-StrictMode -Version Latest

function Get-HbRepoRoot {
    return [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
}

function Resolve-HbPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RepoRoot
    )

    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }

    return [IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
}

function Get-HbConfiguration {
    param([string]$ConfigPath)

    $repoRoot = Get-HbRepoRoot
    if (-not $ConfigPath) {
        $localConfig = Join-Path $repoRoot 'config.psd1'
        $ConfigPath = if (Test-Path -LiteralPath $localConfig) {
            $localConfig
        } else {
            Join-Path $repoRoot 'config.example.psd1'
        }
    } else {
        $ConfigPath = Resolve-HbPath -Path $ConfigPath -RepoRoot $repoRoot
    }

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Configuration file not found: $ConfigPath"
    }

    return Import-PowerShellDataFile -LiteralPath $ConfigPath
}

function Resolve-HbJavaHome {
    param([Parameter(Mandatory = $true)][string]$Candidate)

    if (Test-Path -LiteralPath (Join-Path $Candidate 'bin\java.exe') -PathType Leaf) {
        return [IO.Path]::GetFullPath($Candidate)
    }

    if (Test-Path -LiteralPath $Candidate -PathType Container) {
        $matches = @(Get-ChildItem -LiteralPath $Candidate -Directory | Where-Object {
            Test-Path -LiteralPath (Join-Path $_.FullName 'bin\java.exe') -PathType Leaf
        })
        if ($matches.Count -eq 1) {
            return $matches[0].FullName
        }
    }

    throw "JDK not found under: $Candidate"
}

function Get-HbToolchain {
    param(
        [string]$ConfigPath,
        [switch]$RequireFrida
    )

    $repoRoot = Get-HbRepoRoot
    $config = Get-HbConfiguration -ConfigPath $ConfigPath

    $sdkSetting = if ($env:HB_ANDROID_SDK) { $env:HB_ANDROID_SDK } else { [string]$config.AndroidSdk }
    $javaSetting = if ($env:HB_JAVA_HOME) { $env:HB_JAVA_HOME } else { [string]$config.JavaHome }
    $fridaClientSetting = if ($env:HB_FRIDA_CLIENT) { $env:HB_FRIDA_CLIENT } else { [string]$config.FridaClient }
    $fridaServerSetting = if ($env:HB_FRIDA_SERVER) { $env:HB_FRIDA_SERVER } else { [string]$config.FridaServer }

    $sdk = Resolve-HbPath -Path $sdkSetting -RepoRoot $repoRoot
    $javaCandidate = Resolve-HbPath -Path $javaSetting -RepoRoot $repoRoot
    $javaHome = Resolve-HbJavaHome -Candidate $javaCandidate
    $fridaClient = Resolve-HbPath -Path $fridaClientSetting -RepoRoot $repoRoot
    $fridaServer = Resolve-HbPath -Path $fridaServerSetting -RepoRoot $repoRoot

    $buildTools = Join-Path $sdk ('build-tools\' + [string]$config.BuildToolsVersion)
    $platform = Join-Path $sdk ('platforms\' + [string]$config.PlatformVersion)

    $tools = [ordered]@{
        RepoRoot      = $repoRoot
        AndroidSdk    = $sdk
        JavaHome      = $javaHome
        Java          = Join-Path $javaHome 'bin\java.exe'
        Javac         = Join-Path $javaHome 'bin\javac.exe'
        Jar           = Join-Path $javaHome 'bin\jar.exe'
        Keytool       = Join-Path $javaHome 'bin\keytool.exe'
        Adb           = Join-Path $sdk 'platform-tools\adb.exe'
        Aapt2         = Join-Path $buildTools 'aapt2.exe'
        D8            = Join-Path $buildTools 'd8.bat'
        Zipalign      = Join-Path $buildTools 'zipalign.exe'
        Apksigner     = Join-Path $buildTools 'apksigner.bat'
        AndroidJar    = Join-Path $platform 'android.jar'
        FridaClient   = $fridaClient
        FridaServer   = $fridaServer
    }

    foreach ($name in @('Java', 'Javac', 'Jar', 'Keytool', 'Adb', 'Aapt2', 'D8', 'Zipalign', 'Apksigner', 'AndroidJar')) {
        if (-not (Test-Path -LiteralPath $tools[$name] -PathType Leaf)) {
            throw "Required tool '$name' not found: $($tools[$name])"
        }
    }

    if ($RequireFrida) {
        foreach ($name in @('FridaClient', 'FridaServer')) {
            if (-not (Test-Path -LiteralPath $tools[$name] -PathType Leaf)) {
                throw "Required tool '$name' not found: $($tools[$name])"
            }
        }
    }

    $env:JAVA_HOME = $javaHome
    return [pscustomobject]$tools
}

function Resolve-HbUserPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $repoRoot = Get-HbRepoRoot
    return Resolve-HbPath -Path $Path -RepoRoot $repoRoot
}
