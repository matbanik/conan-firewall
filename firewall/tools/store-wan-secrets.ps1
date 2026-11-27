<#
.SYNOPSIS
  Stores the DDNS settings for wan-event on the firewall. Run it yourself; it prompts for every value.

.DESCRIPTION
  Writes root-only (0600) files in /etc/wan-event/ over SSH stdin. Nothing is saved on this PC, nothing goes on a
  command line, and nothing is printed back. Each part is optional; press Enter at the first prompt to skip it.
    ddns.curl, ddns.name   provider update URL (it carries the token) and the host name to check

  Afterwards it runs "wan-event TEST" on the box, which queues a test email and logs the result
  (read it with: ssh ... journalctl -t wan-ip-watch -n 5).

  The email login is separate: store-mail-secret.ps1.

.EXAMPLE
  .\store-wan-secrets.ps1                      # firewall at 192.168.50.1 (after cutover)
  .\store-wan-secrets.ps1 -Target 192.168.50.108
#>
param(
    [string]$Target = '192.168.50.1',
    [string]$User = 'fwadmin',
    [string]$Key = (Join-Path $HOME '.ssh\firewall_ed25519')
)
$ErrorActionPreference = 'Stop'

function Read-Plain([string]$Prompt) { (Read-Host $Prompt).Trim() }
function Read-Secret([string]$Prompt) {
    $s = Read-Host $Prompt -AsSecureString
    [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
}
# curl config values are double-quoted; escape backslash and quote.
function Q([string]$v) { '"' + ($v -replace '\\', '\\' -replace '"', '\"') + '"' }

function Send-File([string]$Name, [string]$Content) {
    # The ignore line keeps the secrets out of etckeeper's /etc history.
    $remote = "sudo install -d -m 700 /etc/wan-event && sudo sh -c 'grep -qx wan-event/ /etc/.gitignore || echo wan-event/ >>/etc/.gitignore; umask 077; sed s/[[:cntrl:]]*`$// >/etc/wan-event/$Name.tmp && mv /etc/wan-event/$Name.tmp /etc/wan-event/$Name'"
    $Content | & ssh -i $Key -o BatchMode=yes "$User@$Target" $remote
    if ($LASTEXITCODE -ne 0) { throw "writing /etc/wan-event/$Name failed (ssh exit $LASTEXITCODE)" }
    Write-Host "  stored /etc/wan-event/$Name"
}

Write-Host "DDNS (examples: deSEC https://update.dedyn.io/?hostname=NAME&myipv4=preferred with the token as password,"
Write-Host "      dynv6 https://ipv4.dynv6.com/api/update?zone=NAME.dynv6.net&token=TOKEN&ipv4=auto,"
Write-Host "      DuckDNS https://www.duckdns.org/update?domains=NAME&token=TOKEN). Most providers take the source IP."
$ddnsName = Read-Plain 'DDNS host name to check (Enter to skip DDNS)'
if ($ddnsName) {
    $url = Read-Secret 'Provider update URL (hidden; it may contain the token)'
    $ddnsUser = Read-Plain 'Provider login, if it uses one (Enter for none)'
    $lines = @("url = $(Q $url)")
    if ($ddnsUser) { $lines += "user = $(Q ($ddnsUser + ':' + (Read-Secret 'Provider password or token (hidden)')))" }
    Send-File 'ddns.curl' (($lines -join "`n") + "`n")
    Send-File 'ddns.name' ($ddnsName + "`n")
    $url = $null; $lines = $null
}

Write-Host ''
Write-Host 'Running wan-event TEST on the firewall (queues a test email)...'
& ssh -i $Key -o BatchMode=yes "$User@$Target" 'if [ -x /usr/local/sbin/wan-event ]; then sudo /usr/local/sbin/wan-event TEST; sudo journalctl -t wan-ip-watch -n 4 --no-pager -o cat; else echo "wan-event is not installed yet (no deploy so far). The settings are stored; the test runs after deploy.sh."; fi'
