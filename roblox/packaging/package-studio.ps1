# Builds roblox/studio (everything Roblox Studio needs) and roblox/RoPOS-Studio.zip to send.
#   powershell -ExecutionPolicy Bypass -File packaging/package-studio.ps1
# Needs Rojo on PATH (run `rokit install` in roblox/), or pass -Rojo C:\path\to\rojo.exe

param([string]$Rojo = "rojo")

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot          # roblox/
$out = Join-Path $root "studio"
$zip = Join-Path $root "RoPOS-Studio.zip"

if (Test-Path $out) { Remove-Item -Recurse -Force $out }
New-Item -ItemType Directory -Force (Join-Path $out "Models") | Out-Null

function Build($project, $target) {
    & $Rojo build (Join-Path $root $project) -o (Join-Path $out $target) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "rojo build $project failed" }
}

# 1. The complete demo place
Build "default.project.json" "RoPOS.rbxlx"

# 2. One model per Studio location, for Insert from File in an existing game
Build "packaging/shared.project.json" "Models/POS.rbxmx"
Build "packaging/server.project.json" "Models/POSServer.rbxmx"
Build "packaging/client.project.json" "Models/POSClient.rbxmx"

# 3. The scripts as plain files, laid out like Studio's Explorer
$scripts = Join-Path $out "Scripts"
$layout = @(
    @{ From = "src/shared"; To = "ReplicatedStorage/POS" },
    @{ From = "src/server"; To = "ServerScriptService/POSServer" },
    @{ From = "src/client"; To = "StarterPlayer/StarterPlayerScripts/POSClient" }
)
foreach ($entry in $layout) {
    $dest = Join-Path $scripts $entry.To
    New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
    Copy-Item -Recurse (Join-Path $root $entry.From) $dest
    # init.server.luau / init.client.luau is the Script itself: name it after the script.
    $name = Split-Path -Leaf $dest
    Get-ChildItem $dest -Filter "init.*.luau" | ForEach-Object {
        Rename-Item $_.FullName ($_.Name -replace "^init", $name)
    }
}

Copy-Item (Join-Path $PSScriptRoot "READ ME FIRST.txt") $out

if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path (Join-Path $out "*") -DestinationPath $zip
Write-Host "Built $out"
Write-Host "Zipped $zip ($([math]::Round((Get-Item $zip).Length / 1KB)) KB)"
