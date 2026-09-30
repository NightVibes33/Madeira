param(
    [Parameter(Mandatory = $true)]
    [string]$OutputDir,
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$setupUrl = "https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe"
$steamRoot = Join-Path $env:RUNNER_TEMP "Steam"
$setupExe = Join-Path $env:RUNNER_TEMP "SteamSetup.exe"

Remove-Item -Recurse -Force $steamRoot -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $steamRoot | Out-Null
New-Item -ItemType Directory -Force $OutputDir | Out-Null

Invoke-WebRequest -UseBasicParsing -Uri $setupUrl -OutFile $setupExe
$setupBytes = (Get-Item $setupExe).Length
if ($setupBytes -lt 1000000) { throw "SteamSetup.exe is unexpectedly small: $setupBytes bytes" }

$installer = Start-Process -FilePath $setupExe -ArgumentList @("/S", "/D=$steamRoot") -PassThru -Wait
if ($installer.ExitCode -ne 0) { throw "SteamSetup.exe exited with $($installer.ExitCode)" }

$steamExe = Join-Path $steamRoot "steam.exe"
if (-not (Test-Path $steamExe)) { throw "Valve installer did not produce steam.exe" }

if (-not (Get-Process steam -ErrorAction SilentlyContinue)) {
    Start-Process -FilePath $steamExe -ArgumentList @("-silent", "-nochatui", "-nofriendsui") | Out-Null
}

$required = @(
    "steam.exe",
    "steamclient.dll",
    "steamclient64.dll",
    "steamui.dll",
    "bin\cef\cef.win7x64\steamwebhelper.exe"
)
$installedManifestCandidates = @(
    "package\steam_client_win64.installed",
    "package\steam_client_win32.installed"
)

$deadline = (Get-Date).AddMinutes(12)
$lastManifestHash = ""
$stableSamples = 0
while ((Get-Date) -lt $deadline) {
    $allPresent = $true
    foreach ($relative in $required) {
        if (-not (Test-Path (Join-Path $steamRoot $relative))) { $allPresent = $false; break }
    }
    $installedManifest = $null
    foreach ($candidate in $installedManifestCandidates) {
        $p = Join-Path $steamRoot $candidate
        if (Test-Path $p) { $installedManifest = $p; break }
    }
    if ($allPresent -and $installedManifest) {
        $hash = (Get-FileHash -Algorithm SHA256 $installedManifest).Hash.ToLowerInvariant()
        if ($hash -eq $lastManifestHash) { $stableSamples++ } else { $lastManifestHash = $hash; $stableSamples = 0 }
        if ($stableSamples -ge 3) { break }
    }
    Start-Sleep -Seconds 10
}

foreach ($relative in $required) {
    if (-not (Test-Path (Join-Path $steamRoot $relative))) { throw "Full Steam staging incomplete; missing $relative" }
}
$installedManifest = $null
foreach ($candidate in $installedManifestCandidates) {
    $p = Join-Path $steamRoot $candidate
    if (Test-Path $p) { $installedManifest = $p; break }
}
if (-not $installedManifest) { throw "Full Steam staging incomplete; installed client manifest missing" }
if ($stableSamples -lt 3) { throw "Steam client did not reach a stable fully-updated state before timeout" }

Get-CimInstance Win32_Process | Where-Object {
    $_.ExecutablePath -and $_.ExecutablePath.StartsWith($steamRoot, [System.StringComparison]::OrdinalIgnoreCase)
} | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 2

Remove-Item -Recurse -Force (Join-Path $steamRoot "logs") -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force (Join-Path $steamRoot "dumps") -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force (Join-Path $steamRoot "userdata") -ErrorAction SilentlyContinue
Remove-Item -Force (Join-Path $steamRoot "config\loginusers.vdf") -ErrorAction SilentlyContinue

$payload = Join-Path $OutputDir "SteamPayload.tar.gz"
$metadata = Join-Path $OutputDir "SteamPayload.json"
Remove-Item -Force $payload, $metadata -ErrorAction SilentlyContinue

$parent = Split-Path $steamRoot -Parent
$leaf = Split-Path $steamRoot -Leaf
& tar.exe -czf $payload -C $parent $leaf
if ($LASTEXITCODE -ne 0) { throw "tar failed while packaging the preinstalled Steam client" }

$payloadBytes = (Get-Item $payload).Length
if ($payloadBytes -lt 50000000) { throw "Preinstalled Steam payload is unexpectedly small: $payloadBytes bytes" }

$manifestSha = (Get-FileHash -Algorithm SHA256 $ManifestPath).Hash.ToLowerInvariant()
$payloadSha = (Get-FileHash -Algorithm SHA256 $payload).Hash.ToLowerInvariant()
$fileCount = (Get-ChildItem -Recurse -File $steamRoot).Count
$totalBytes = (Get-ChildItem -Recurse -File $steamRoot | Measure-Object -Property Length -Sum).Sum

@{
    source_manifest = "https://client-update.akamai.steamstatic.com/steam_client_win64"
    source_manifest_sha256 = $manifestSha
    installer = $setupUrl
    payload_sha256 = $payloadSha
    payload_bytes = $payloadBytes
    expanded_files = $fileCount
    expanded_bytes = $totalBytes
    generated_utc = (Get-Date).ToUniversalTime().ToString("o")
} | ConvertTo-Json | Set-Content -Encoding UTF8 $metadata

Write-Host "STEAMIOS_FULL_STEAM_PAYLOAD_OK sha256=$payloadSha archive_bytes=$payloadBytes expanded_files=$fileCount expanded_bytes=$totalBytes"
