param(
  [string]$Dest = (Join-Path $HOME '.dsh\skills')
)

$ErrorActionPreference = 'Stop'
$target = Join-Path $Dest 'phone-vscode-server'

New-Item -ItemType Directory -Force -Path $target | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'SKILL.md') $target -Force
Copy-Item (Join-Path $PSScriptRoot 'scripts') $target -Recurse -Force
Remove-Item (Join-Path $target 'scripts\.run') -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "installed -> $target"
Write-Host "scripts : $target\scripts"
Write-Host "next    : open a new dsh session; the 'phone-vscode-server' skill appears in the catalog"
Write-Host "          run scripts\phone-code.cmd to open the tunnel"
