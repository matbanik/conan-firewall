<#
.SYNOPSIS
  Stores the Gmail app password for the firewall's emails (daily brief, WAN alerts). Run it yourself; it prompts.

.DESCRIPTION
  The app password goes over SSH stdin straight into an encrypted systemd credential, /etc/credstore.encrypted/fw-mail.
  Nothing is saved on this PC, nothing goes on a command line, and nothing is printed back.

  - The credential is encrypted with the box's TPM chip and a root-only key. A copy of the disk, the backup or the
    /etc history cannot open it.
  - Only fw-mail.service can read it, and only while it sends. The analysis agent cannot: it can only put a message
    in the spool, and the recipient is fixed in the credential.
  - Root on the firewall can decrypt it. To end its use, delete the app password in the Google account.

  Make the app password in the sender's Google account: Security, 2-Step Verification, App passwords. Give it the
  name "firewall" and use it for nothing else. Run this script again to replace it.

.EXAMPLE
  & C:\src\conan-firewall\firewall\tools\store-mail-secret.ps1
#>
param(
    [string]$Target = '192.168.50.1',
    [string]$User = 'fwadmin',
    [string]$Key = (Join-Path $HOME '.ssh\firewall_ed25519')
)
$ErrorActionPreference = 'Stop'

$from = (Read-Host 'Sender Gmail address').Trim()
$to = (Read-Host 'Recipient address').Trim()
if ($from -notmatch '^\S+@\S+$' -or $to -notmatch '^\S+@\S+$') { throw 'Not an email address. Nothing was stored.' }
$sec = Read-Host 'App password (16 letters, hidden; spaces are removed)' -AsSecureString
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
try {
    $pw = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) -replace '\s', ''
    if ($pw -notmatch '^[a-z]{16}$') { throw 'A Gmail app password is 16 letters. Nothing was stored.' }
    $json = @{ user = $from; password = $pw; from = $from; to = $to } | ConvertTo-Json -Compress
    $OutputEncoding = New-Object System.Text.ASCIIEncoding
    $json | & ssh -i $Key -o BatchMode=yes "$User@$Target" 'sudo -n /usr/local/sbin/fw-mail-setup'
    if ($LASTEXITCODE -ne 0) { throw "not stored (exit $LASTEXITCODE)" }
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    $pw = $null; $json = $null
}

Write-Host 'Sending a test email (and any message that was waiting)...'
& ssh -i $Key -o BatchMode=yes "$User@$Target" 'echo "Test from store-mail-secret.ps1. The firewall can send email." | sudo -n /usr/local/sbin/fw-mail queue "Test email"; sudo -n systemctl start fw-mail.service; sudo -n journalctl -u fw-mail.service -n 4 --no-pager -o cat'
