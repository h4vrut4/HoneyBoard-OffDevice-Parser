[CmdletBinding()]
param(
    [string]$Apk = 'input/apk/HoneyBoard.apk',
    [string]$OutputApk = 'output/host/honeyboard-parser-host.apk',
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Common.ps1')

$toolchain = Get-HbToolchain -ConfigPath $ConfigPath
$repoRoot = $toolchain.RepoRoot
$sourceApk = Resolve-HbUserPath -Path $Apk
$destinationApk = Resolve-HbUserPath -Path $OutputApk

if (-not (Test-Path -LiteralPath $sourceApk -PathType Leaf)) {
    throw "APK not found: $sourceApk"
}

$sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourceApk).Hash.ToLowerInvariant()
$buildId = $sourceHash.Substring(0, 16)
$workRoot = Join-Path $repoRoot ('.work\build-' + $buildId)
$expectedWorkPrefix = [IO.Path]::GetFullPath((Join-Path $repoRoot '.work')) + [IO.Path]::DirectorySeparatorChar

if (Test-Path -LiteralPath $workRoot) {
    $resolvedWork = [IO.Path]::GetFullPath($workRoot)
    if (-not $resolvedWork.StartsWith($expectedWorkPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean path outside .work: $resolvedWork"
    }
    Remove-Item -LiteralPath $resolvedWork -Recurse -Force
}

$extractDir = Join-Path $workRoot 'parser'
$compileDir = Join-Path $workRoot 'compile'
$classDir = Join-Path $compileDir 'classes'
$dexDir = Join-Path $compileDir 'dex'
$stageDir = Join-Path $workRoot 'stage'
$nativeDir = Join-Path $stageDir 'lib\arm64-v8a'
New-Item -ItemType Directory -Force -Path $extractDir, $classDir, $dexDir, $nativeDir | Out-Null

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($sourceApk)
try {
    $dexEntries = @($zip.Entries | Where-Object { $_.FullName -match '^classes\d*\.dex$' } | Sort-Object {
        if ($_.Name -eq 'classes.dex') { 1 } else { [int]([regex]::Match($_.Name, '\d+').Value) }
    })
    if ($dexEntries.Count -eq 0) {
        throw 'No classes*.dex entries found in APK.'
    }

    $soEntry = $zip.GetEntry('lib/arm64-v8a/libfluency-java.so')
    if ($null -eq $soEntry) {
        throw 'APK does not contain lib/arm64-v8a/libfluency-java.so.'
    }

    foreach ($entry in $dexEntries) {
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $extractDir $entry.Name), $true)
    }
    [IO.Compression.ZipFileExtensions]::ExtractToFile($soEntry, (Join-Path $extractDir 'libfluency-java.so'), $true)
} finally {
    $zip.Dispose()
}

$manifest = Join-Path $repoRoot 'host\AndroidManifest.xml'
$activitySource = Join-Path $repoRoot 'host\src\com\example\hbhost\MainActivity.java'
$resourceApk = Join-Path $compileDir 'host-resources.apk'

& $toolchain.Aapt2 link -o $resourceApk -I $toolchain.AndroidJar --manifest $manifest --min-sdk-version 33 --target-sdk-version 34
if ($LASTEXITCODE -ne 0) { throw "aapt2 failed with exit code $LASTEXITCODE" }

& $toolchain.Javac -source 8 -target 8 -bootclasspath $toolchain.AndroidJar -d $classDir $activitySource
if ($LASTEXITCODE -ne 0) { throw "javac failed with exit code $LASTEXITCODE" }

$activityClass = Join-Path $classDir 'com\example\hbhost\MainActivity.class'
& $toolchain.D8 --min-api 33 --output $dexDir $activityClass
if ($LASTEXITCODE -ne 0) { throw "d8 failed with exit code $LASTEXITCODE" }

Copy-Item -LiteralPath (Join-Path $dexDir 'classes.dex') -Destination (Join-Path $stageDir 'classes.dex')
$stageEntries = @('classes.dex')
$outputIndex = 2
foreach ($entry in $dexEntries) {
    $outputName = "classes$outputIndex.dex"
    Copy-Item -LiteralPath (Join-Path $extractDir $entry.Name) -Destination (Join-Path $stageDir $outputName)
    $stageEntries += $outputName
    $outputIndex++
}
Copy-Item -LiteralPath (Join-Path $extractDir 'libfluency-java.so') -Destination (Join-Path $nativeDir 'libfluency-java.so')
$stageEntries += 'lib/arm64-v8a/libfluency-java.so'

$unsigned = Join-Path $workRoot 'host-unsigned.apk'
$aligned = Join-Path $workRoot 'host-aligned.apk'
$signed = Join-Path $workRoot 'host-signed.apk'
Copy-Item -LiteralPath $resourceApk -Destination $unsigned

Push-Location $stageDir
try {
    & $toolchain.Jar uf $unsigned @stageEntries
} finally {
    Pop-Location
}
if ($LASTEXITCODE -ne 0) { throw "jar failed with exit code $LASTEXITCODE" }

& $toolchain.Zipalign -f -p 4 $unsigned $aligned
if ($LASTEXITCODE -ne 0) { throw "zipalign failed with exit code $LASTEXITCODE" }

$keystore = Join-Path $repoRoot '.work\debug.keystore'
if (-not (Test-Path -LiteralPath $keystore -PathType Leaf)) {
    & $toolchain.Keytool -genkeypair -keystore $keystore -storepass android -alias androiddebugkey -keypass android -dname 'CN=Android Debug,O=Android,C=US' -keyalg RSA -keysize 2048 -validity 10000
    if ($LASTEXITCODE -ne 0) { throw "keytool failed with exit code $LASTEXITCODE" }
}

& $toolchain.Apksigner sign --ks $keystore --ks-key-alias androiddebugkey --ks-pass pass:android --key-pass pass:android --out $signed $aligned
if ($LASTEXITCODE -ne 0) { throw "apksigner failed with exit code $LASTEXITCODE" }
& $toolchain.Apksigner verify $signed
if ($LASTEXITCODE -ne 0) { throw "APK signature verification failed with exit code $LASTEXITCODE" }

$destinationDir = Split-Path -Parent $destinationApk
New-Item -ItemType Directory -Force -Path $destinationDir | Out-Null
Copy-Item -LiteralPath $signed -Destination $destinationApk -Force

$dexMetadata = @($dexEntries | ForEach-Object {
    $path = Join-Path $extractDir $_.Name
    [ordered]@{
        name = $_.Name
        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
        bytes = (Get-Item -LiteralPath $path).Length
    }
})
$metadata = [ordered]@{
    sourceApk = Split-Path $sourceApk -Leaf
    sourceApkSha256 = $sourceHash
    parserDex = $dexMetadata
    fluencySoSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $extractDir 'libfluency-java.so')).Hash.ToLowerInvariant()
    outputApk = Split-Path $destinationApk -Leaf
    outputApkSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $destinationApk).Hash.ToLowerInvariant()
}
$metadataPath = [IO.Path]::ChangeExtension($destinationApk, '.json')
$metadata | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $metadataPath -Encoding UTF8

[pscustomobject]@{
    SourceApkSha256 = $sourceHash
    ParserDexCount = $dexEntries.Count
    FluencySoSha256 = $metadata.fluencySoSha256
    HostApk = $destinationApk
    HostApkSha256 = $metadata.outputApkSha256
    Metadata = $metadataPath
}
