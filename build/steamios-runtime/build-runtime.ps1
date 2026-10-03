param(
    [string]$OutputDir = "$PSScriptRoot\out"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$setupUrl = "https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe"
$steamRoot = Join-Path $env:RUNNER_TEMP "SteamIOS-Steam"
$setupExe = Join-Path $env:RUNNER_TEMP "SteamSetup.exe"
$stage = Join-Path $env:RUNNER_TEMP "SteamIOS-RuntimeStage"

Remove-Item -Recurse -Force $steamRoot,$stage,$OutputDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $steamRoot,$stage,$OutputDir | Out-Null

Invoke-WebRequest -UseBasicParsing -Uri $setupUrl -OutFile $setupExe
if ((Get-Item $setupExe).Length -lt 1000000) { throw "SteamSetup.exe download is unexpectedly small" }

$p = Start-Process -FilePath $setupExe -ArgumentList @("/S", "/D=$steamRoot") -PassThru -Wait
if ($p.ExitCode -ne 0) { throw "Steam installer exited with $($p.ExitCode)" }

$steamExe = Join-Path $steamRoot "steam.exe"
if (-not (Test-Path $steamExe)) { throw "Steam installer did not create steam.exe" }

Start-Process -FilePath $steamExe -ArgumentList @("-silent","-nochatui","-nofriendsui") | Out-Null

$required = @(
  "steam.exe",
  "steamclient.dll",
  "steamclient64.dll",
  "steamui.dll",
  "bin\cef\cef.win7x64\steamwebhelper.exe"
)
$manifests = @(
  "package\steam_client_win64.installed",
  "package\steam_client_win32.installed"
)

$deadline = (Get-Date).AddMinutes(12)
$last = ""
$stable = 0
$manifest = $null
while ((Get-Date) -lt $deadline) {
    $ok = $true
    foreach ($rel in $required) {
        if (-not (Test-Path (Join-Path $steamRoot $rel))) { $ok = $false; break }
    }
    $manifest = $null
    foreach ($rel in $manifests) {
        $candidate = Join-Path $steamRoot $rel
        if (Test-Path $candidate) { $manifest = $candidate; break }
    }
    if ($ok -and $manifest) {
        $hash = (Get-FileHash -Algorithm SHA256 $manifest).Hash.ToLowerInvariant()
        if ($hash -eq $last) { $stable++ } else { $last = $hash; $stable = 0 }
        if ($stable -ge 3) { break }
    }
    Start-Sleep -Seconds 10
}
if ($stable -lt 3) { throw "Steam client did not reach a stable updated state" }

Get-CimInstance Win32_Process | Where-Object {
    $_.ExecutablePath -and $_.ExecutablePath.StartsWith($steamRoot,[System.StringComparison]::OrdinalIgnoreCase)
} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2

Remove-Item -Recurse -Force (Join-Path $steamRoot "logs"),(Join-Path $steamRoot "dumps"),(Join-Path $steamRoot "userdata") -ErrorAction SilentlyContinue
Remove-Item -Force (Join-Path $steamRoot "config\loginusers.vdf") -ErrorAction SilentlyContinue
Set-Content -Encoding ascii -Path (Join-Path $steamRoot ".steamios-runtime") -Value "Valve Steam client runtime"

$runtimeSteam = Join-Path $stage "prefix\drive_c\Program Files (x86)\Steam"
New-Item -ItemType Directory -Force (Split-Path $runtimeSteam -Parent) | Out-Null
Copy-Item -Recurse -Force $steamRoot $runtimeSteam

$archive = Join-Path $OutputDir "SteamRuntime.tar.gz"
Push-Location $stage
try {
    & tar.exe -czf $archive prefix
    if ($LASTEXITCODE -ne 0) { throw "tar failed" }
} finally { Pop-Location }

$sha = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant()
$expandedBytes = (Get-ChildItem -Recurse -File $steamRoot | Measure-Object Length -Sum).Sum
$fileCount = (Get-ChildItem -Recurse -File $steamRoot).Count
@{
    source = $setupUrl
    payload_sha256 = $sha
    payload_bytes = (Get-Item $archive).Length
    expanded_bytes = $expandedBytes
    expanded_files = $fileCount
    generated_utc = (Get-Date).ToUniversalTime().ToString("o")
} | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $OutputDir "SteamRuntime.json")

Write-Host "STEAMIOS_RUNTIME_OK sha256=$sha files=$fileCount expanded_bytes=$expandedBytes archive_bytes=$((Get-Item $archive).Length)"
