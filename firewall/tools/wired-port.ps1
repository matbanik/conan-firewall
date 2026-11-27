<#
.SYNOPSIS
  Sets ADMINPC's wired port and Wi-Fi for the cutover. Run it elevated.

.DESCRIPTION
  During the cutover ADMINPC gets internet from the phone hotspot on Wi-Fi. The wired port reaches the house
  network with no gateway, so the hotspot keeps the default route.

  -Mode Lan    Wired port on the house LAN (switch or ASUS LAN port). Static 192.168.50.5/24, no gateway,
               no DNS. Plex, SMB and RustDesk stay on .5 for the LAN. Wi-Fi HomeNet is set to manual connect,
               so Windows does not join it again and make a second .5.
               One host route: the RustDesk remote ($RustDeskRemote) goes via 192.168.50.1 on the cable. The
               router forwards the remote's connections to .5, so the replies must go back the same way, not
               out through the hotspot.
  -Mode Mgmt   Wired port on the firewall mgmt0 port. DHCP gives 10.255.255.2, no gateway.
  -Mode Off    Back to the normal state: wired port to DHCP, then disabled. Wi-Fi HomeNet connects
               automatically again. Join HomeNet after this.

.EXAMPLE
  Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File C:\src\conan-firewall\firewall\tools\wired-port.ps1 -Mode Lan'
#>
param(
    [Parameter(Mandatory)][ValidateSet('Lan', 'Mgmt', 'Off')][string]$Mode,
    [string]$Adapter = 'Ethernet',
    [string]$WifiProfile = 'HomeNet',
    [string]$RustDeskRemote = '203.0.113.45'   # RUSTDESK_REMOTE in profiles/prod/etc/nftables.d/profile.nft
)
$ErrorActionPreference = 'Stop'
$log = Join-Path $env:TEMP 'wired-port.log'
Start-Transcript -Path $log -Append | Out-Null

$dev = Get-PnpDevice -FriendlyName 'Realtek PCIe 5GbE*' -ErrorAction SilentlyContinue | Select-Object -First 1

function Reset-Dhcp {
    Set-NetIPInterface -InterfaceAlias $Adapter -AddressFamily IPv4 -Dhcp Enabled
    Get-NetIPAddress -InterfaceAlias $Adapter -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object PrefixOrigin -eq 'Manual' | Remove-NetIPAddress -Confirm:$false
    foreach ($p in '0.0.0.0/0', "$RustDeskRemote/32") {
        Get-NetRoute -InterfaceAlias $Adapter -DestinationPrefix $p -ErrorAction SilentlyContinue |
            Remove-NetRoute -Confirm:$false
    }
    Set-DnsClientServerAddress -InterfaceAlias $Adapter -ResetServerAddresses
}

switch ($Mode) {
    'Lan' {
        if ($dev -and $dev.Status -ne 'OK') { Enable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false; Start-Sleep 5 }
        & netsh wlan set profileparameter name="$WifiProfile" connectionmode=manual | Out-Null
        Reset-Dhcp
        Set-NetIPInterface -InterfaceAlias $Adapter -AddressFamily IPv4 -Dhcp Disabled
        New-NetIPAddress -InterfaceAlias $Adapter -IPAddress 192.168.50.5 -PrefixLength 24 | Out-Null
        Set-DnsClientServerAddress -InterfaceAlias $Adapter -ServerAddresses @()
        # ActiveStore: a reboot drops it. Run -Mode Lan again after a reboot.
        New-NetRoute -InterfaceAlias $Adapter -DestinationPrefix "$RustDeskRemote/32" -NextHop 192.168.50.1 `
            -RouteMetric 1 -PolicyStore ActiveStore | Out-Null
    }
    'Mgmt' {
        if ($dev -and $dev.Status -ne 'OK') { Enable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false; Start-Sleep 5 }
        & netsh wlan set profileparameter name="$WifiProfile" connectionmode=manual | Out-Null
        Reset-Dhcp
        & ipconfig /renew $Adapter | Out-Null
    }
    'Off' {
        Reset-Dhcp
        if ($dev -and $dev.Status -eq 'OK') { Disable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false }
        & netsh wlan set profileparameter name="$WifiProfile" connectionmode=auto | Out-Null
    }
}

Get-NetIPConfiguration -InterfaceAlias $Adapter, 'Wi-Fi' -ErrorAction SilentlyContinue |
    Format-Table InterfaceAlias, @{n = 'IPv4'; e = { $_.IPv4Address.IPAddress } }, @{n = 'Gateway'; e = { $_.IPv4DefaultGateway.NextHop } } -AutoSize
# The path Windows picks for the RustDesk remote: Ethernet via 192.168.50.1 in -Mode Lan, the Wi-Fi gateway otherwise.
Find-NetRoute -RemoteIPAddress $RustDeskRemote -ErrorAction SilentlyContinue | Select-Object -Last 1 |
    Format-Table @{n = 'RustDesk remote'; e = { $RustDeskRemote } }, InterfaceAlias, NextHop -AutoSize
Stop-Transcript | Out-Null
