# Windows: resolve the phone/tablet IPv4 address.
# The device is the DHCP server *and* the default gateway of its hotspot, so the
# WLAN adapter's IPv4 default gateway is the device. Each candidate is verified
# by a TCP connect to the ssh port, so a home router is never mistaken for it.
#
# Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File phone-ip.ps1 [-SshPort 8022] [-Adapter "WLAN"]
# Output: the address alone on stdout; exit 0 on success, 1 when nothing answered.
[CmdletBinding()]
param(
  [string]$Adapter = '',
  [string]$Mac = '',
  [int]$SshPort = 8022,
  [int]$ProbeTimeoutMs = 900
)

$ErrorActionPreference = 'SilentlyContinue'

function Test-TcpPort {
  param([string]$Address, [int]$Port, [int]$TimeoutMs)
  $client = [System.Net.Sockets.TcpClient]::new()
  try {
    $task = $client.ConnectAsync($Address, $Port)
    if (-not $task.Wait($TimeoutMs)) { return $false }
    return $client.Connected
  } catch {
    return $false
  } finally {
    $client.Dispose()
  }
}

# 1) the connected WLAN adapter that owns a default gateway
$cfg = Get-NetIPConfiguration | Where-Object {
  if (-not $_.IPv4DefaultGateway) { return $false }
  if ($_.NetAdapter.Status -ne 'Up') { return $false }
  if ($Adapter) { return $_.InterfaceAlias -eq $Adapter }
  return $_.InterfaceDescription -match 'Wi-Fi|Wireless|WLAN|802\.11'
} | Select-Object -First 1

$candidates = New-Object System.Collections.Generic.List[object]

if ($cfg) {
  foreach ($nextHop in $cfg.IPv4DefaultGateway.NextHop) {
    $candidates.Add([pscustomobject]@{ Ip = $nextHop; Source = 'wlan-gateway' })
  }
  $nic = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "InterfaceIndex=$($cfg.InterfaceIndex)"
  if ($nic -and $nic.DHCPServer) {
    $candidates.Add([pscustomobject]@{ Ip = $nic.DHCPServer; Source = 'dhcp-server' })
  }
}

# 2) optional: reverse-lookup by MAC (only useful when the hotspot MAC is stable)
if ($Mac) {
  $wanted = ($Mac -replace '[:-]', '-').ToUpper()
  Get-NetNeighbor -AddressFamily IPv4 |
    Where-Object { $_.LinkLayerAddress -eq $wanted } |
    ForEach-Object { $candidates.Add([pscustomobject]@{ Ip = $_.IPAddress; Source = 'mac' }) }
}

# 3) first candidate that actually answers on the ssh port wins
foreach ($candidate in $candidates) {
  if (Test-TcpPort -Address $candidate.Ip -Port $SshPort -TimeoutMs $ProbeTimeoutMs) {
    if ($env:PHONE_IP_VERBOSE) {
      [Console]::Error.WriteLine("phone-ip: $($candidate.Ip) via $($candidate.Source)")
    }
    Write-Output $candidate.Ip
    exit 0
  }
  if ($env:PHONE_IP_VERBOSE) {
    [Console]::Error.WriteLine("phone-ip: skip $($candidate.Ip) ($($candidate.Source)) - port $SshPort closed")
  }
}

exit 1
