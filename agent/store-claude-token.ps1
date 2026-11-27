<#
Issue a long-lived Claude sign-in token on this machine and store it on the firewall for the fleet user.
The HUMAN runs this, in a real terminal on the admin PC, from the repository folder. The token is never written
to disk here and never printed by this script; it goes over SSH stdin into a mode-600 file owned by "fleet" on
the box.

  powershell -NoProfile -ExecutionPolicy Bypass -File agent\store-claude-token.ps1 -Address <box address>

Steps it runs:
  1. claude setup-token  (opens the browser here; you approve; it shows the token in this window)
  2. asks you to paste the token (hidden input), then clears the screen
  3. ssh fwadmin@<box>: writes ~fleet/.agent/fleet/credentials/claude-oauth-token (umask 077, atomic rename)
  4. ssh fwadmin@<box>: one-turn claude -p test as "fleet"; expect OK
Use -SkipIssue to paste a token you already issued.
#>
param(
  [Parameter(Mandatory = $true)][string]$Address,
  [string]$User = 'fwadmin',
  [string]$KeyPath = (Join-Path $HOME '.ssh\firewall_ed25519'),
  [switch]$SkipIssue,
  [switch]$SkipTest
)
$ErrorActionPreference = 'Stop'
$ssh = (Get-Command ssh.exe).Source
if (-not (Test-Path -LiteralPath $KeyPath)) { throw "SSH key not found: $KeyPath" }

function Invoke-Ssh([string]$RemoteCommand, [byte[]]$InputBytes) {
  # Remote commands here hold no double quotes, so they survive Windows argument quoting.
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $ssh
  $psi.Arguments = "-i `"$KeyPath`" -o BatchMode=yes -o ConnectTimeout=15 $User@$Address `"$RemoteCommand`""
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true
  $p = [Diagnostics.Process]::Start($psi)
  try {
    if ($InputBytes) { $p.StandardInput.BaseStream.Write($InputBytes, 0, $InputBytes.Length) }
    $p.StandardInput.Close()
    $p.WaitForExit()
    return $p.ExitCode
  } finally { if ($InputBytes) { [Array]::Clear($InputBytes, 0, $InputBytes.Length) } }
}

# Reachability first, so a token is not issued for nothing
if ((Invoke-Ssh 'id -un fleet >/dev/null && sudo -n true' $null) -ne 0) {
  throw "Cannot reach $User@$Address with the key, or the fleet user / sudo is missing. Connect once with ssh first to accept the host key."
}

if (-not $SkipIssue) {
  Write-Host 'Running claude setup-token. Approve in the browser, then copy the token it shows.' -ForegroundColor Cyan
  & claude setup-token
  if ($LASTEXITCODE) { throw "claude setup-token exited $LASTEXITCODE" }
}

$secure = Read-Host 'Paste the token (input is hidden)' -AsSecureString
Clear-Host
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
  $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr).Trim()
  # The prefix is written in two parts so that a scan for token formats does not stop on this file.
  if ($plain -notmatch ('^sk-' + 'ant-[A-Za-z0-9_\-]{20,}$')) { throw 'That does not look like a Claude token. Nothing was stored.' }
  $bytes = [Text.Encoding]::ASCII.GetBytes($plain + "`n")
} finally {
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  $plain = $null
}

$dir = '/home/fleet/.agent/fleet/credentials'
$store = "sudo -H -u fleet sh -c 'umask 077 && mkdir -p $dir && cat > $dir/claude-oauth-token.new && mv -f $dir/claude-oauth-token.new $dir/claude-oauth-token'"
if ((Invoke-Ssh $store $bytes) -ne 0) { throw 'Storing the token on the box failed.' }
Write-Host 'Token stored for user fleet on the box.' -ForegroundColor Green

if (-not $SkipTest) {
  # The test script is sent on stdin with LF endings; it reads the file into a shell variable, never prints it.
  $test = @'
set -e
cd /var/lib/fw-analysis
t=$(cat "$HOME/.agent/fleet/credentials/claude-oauth-token")
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
CLAUDE_CODE_OAUTH_TOKEN=$t CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 claude -p --max-turns 1 --strict-mcp-config --setting-sources user 'Reply with the single word OK' </dev/null
'@ -replace "`r`n", "`n"
  Write-Host 'Testing claude -p as fleet on the box...'
  $code = Invoke-Ssh 'sudo -H -u fleet sh -s' ([Text.Encoding]::ASCII.GetBytes($test))
  if ($code -ne 0) { throw "Test failed (exit $code). The token is stored. Run this script again with -SkipIssue to test once more; see agent/README.md." }
  Write-Host 'RESULT: OK' -ForegroundColor Green
}
