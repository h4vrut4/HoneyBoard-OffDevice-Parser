[CmdletBinding()]
param(
    [string]$Apk = 'input/apk/HoneyBoard.apk',
    [string]$ModelDir = 'input/model',
    [string]$Serial,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Common.ps1')

$repoRoot = Get-HbRepoRoot
$hostApk = Join-Path $repoRoot 'output\host\honeyboard-parser-host.apk'
$logPath = Join-Path $repoRoot ('output\logs\parse-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')

$null = & (Join-Path $PSScriptRoot 'Build-Host.ps1') -Apk $Apk -OutputApk $hostApk -ConfigPath $ConfigPath
& (Join-Path $PSScriptRoot 'Run-Parser.ps1') -HostApk $hostApk -ModelDir $ModelDir -Serial $Serial -OutputLog $logPath -ConfigPath $ConfigPath
