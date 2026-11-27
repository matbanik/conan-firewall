<#
.SYNOPSIS
  Backup of the firewall configuration and the database reports on ADMINPC. ADMINPC pulls it over SSH. Nothing is pushed from the firewall.

.DESCRIPTION
  The firewall user fwbackup has one SSH key with a forced command: sudo -n /usr/local/sbin/fw-backup-export.
  That key can only produce the export tar and the weekly archives. It cannot open a shell or forward ports. It works only from
  the addresses in -From: this PC's LAN address (192.168.50.5), or 10.255.255.2 on mgmt0. Give -From at -Setup when this PC
  has another address.

  -Setup     Once, after deploy.sh created the fwbackup user. Makes the key ~/.ssh/fwbackup_ed25519 (no
             passphrase, so the task can run unattended) and installs it on the firewall through your
             fwadmin key. Then makes one pull to test it.
  -Register  Adds the daily task \ConanFirewall\Pull-Backup (06:30, after the 05:30 database report and the daily brief). Runs as
             you, not elevated, so it runs when you are signed in.
  -Register also adds the task \ConanFirewall\Weekly-Archive (Tuesday 07:00).
  -Weekly    Into $ArchiveDest, kept for ever: the config and reports (folder config) and every weekly archive of the
             database that is not there yet (folder database). A missed week is taken the next time. Nothing there is
             ever removed or overwritten. Both are differential and compressed: config is one full copy a year and then
             only what changed since it (fw-diff.py); each database archive holds only its own week's rows.
             fw-diff.py needs Python 3: -Python is the path of python.exe.
             Restore: python fw-diff.py restore D:\backup\conan-firewall\config\diff-STAMP.tar.xz OUTDIR
  (none)     Pulls one backup, checks it, and removes old copies.

  The copies hold no passwords, private keys or logins, and not the database. They do hold the house's network map and
  what its devices do, so the folder is readable only by you, SYSTEM and Administrators.
  After each pull, the newest reports are also unpacked into the folder "reports" next to the tar files.

.EXAMPLE
  & C:\src\conan-firewall\firewall\tools\pull-fw-backup.ps1 -Setup
  & C:\src\conan-firewall\firewall\tools\pull-fw-backup.ps1 -Register
#>
param(
    [string]$Target = '192.168.50.1',
    [string]$Dest = (Join-Path $env:LOCALAPPDATA 'conan-firewall\backups'),
    [string]$ArchiveDest = 'D:\backup\conan-firewall',
    [string]$From = '192.168.50.5,10.255.255.2',
    [string]$Python = 'C:\ProgramData\miniconda3\python.exe',
    [switch]$Weekly,
    [switch]$Setup,
    [switch]$Register,
    [int]$KeepDaily = 14,
    [int]$KeepMonthly = 12
)
$ErrorActionPreference = 'Stop'
$key = Join-Path $HOME '.ssh\fwbackup_ed25519'
# Windows' own bsdtar. Git's GNU tar can come first in PATH, and it reads 'C:' in a path as a remote host.
$tarExe = Join-Path $env:SystemRoot 'System32\tar.exe'
$adminKey = Join-Path $HOME '.ssh\firewall_ed25519'

function Write-Log([string]$m) {
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $m
    Write-Host $line
    Add-Content -Path (Join-Path $Dest 'pull.log') -Value $line
}

if ($Weekly) { $Dest = $ArchiveDest }

function Initialize-Dest {
    if (-not (Test-Path $Dest)) { New-Item -ItemType Directory -Path $Dest | Out-Null }
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & icacls $Dest /inheritance:r /grant:r "*${me}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed on $Dest" }
}

# Checks one export tar. Returns meta.txt as one line; throws on any problem.
function Test-Export([string]$Tar) {
    $required = 'etc.tar', 'usr-local.tar', 'reports.tar', 'packages.tsv', 'apt-manual.txt', 'ruleset.nft', 'units-enabled.txt', 'meta.txt'
    $chk = Join-Path $env:TEMP ('fw-backup-check-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $chk | Out-Null
    try {
        & $tarExe -xf $Tar -C $chk
        if ($LASTEXITCODE -ne 0) { throw 'tar could not read the export' }
        $sumsFile = Join-Path $chk 'SHA256SUMS'
        if (-not (Test-Path $sumsFile)) { throw 'SHA256SUMS is missing' }
        $listed = @{}
        foreach ($l in (Get-Content $sumsFile)) {
            $hash, $name = $l -split '\s+\*?', 2
            $file = Join-Path $chk $name
            if (-not (Test-Path $file)) { throw "listed but missing: $name" }
            $got = (Get-FileHash -Algorithm SHA256 $file).Hash.ToLower()
            if ($got -ne $hash) { throw "checksum mismatch: $name" }
            $listed[$name] = 1
        }
        foreach ($n in $required) { if (-not $listed.ContainsKey($n)) { throw "not in the export: $n" } }
        foreach ($n in 'etc.tar', 'usr-local.tar', 'reports.tar') {
            $names = & $tarExe -tf (Join-Path $chk $n)
            if ($LASTEXITCODE -ne 0) { throw "$n is not readable" }
            if ($names -match 'etc/(shadow|gshadow|security/opasswd|ssh/ssh_host_|wan-event/|credstore)') { throw "$n holds a secret file" }
        }
        return (Get-Content (Join-Path $chk 'meta.txt')) -join ' '
    } finally {
        Remove-Item $chk -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Pull([string]$Folder = $Dest, [switch]$NoReports) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $part = Join-Path $Folder "fw-$stamp.tar.part"
    # cmd redirection keeps the bytes as they are; Windows PowerShell 5.1 redirection would change them.
    & cmd.exe /c "ssh -i `"$key`" -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=15 fwbackup@$Target > `"$part`""
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $part) -or (Get-Item $part).Length -lt 1024) {
        Remove-Item $part -ErrorAction SilentlyContinue
        throw "pull from $Target failed (ssh exit $LASTEXITCODE)"
    }
    try {
        $meta = Test-Export $part
    } catch {
        Remove-Item $part -ErrorAction SilentlyContinue
        throw
    }
    $final = $part -replace '\.part$', ''
    Move-Item $part $final
    if ($NoReports) {
        Write-Log ("ok {0} ({1:N0} KB) {2}" -f (Split-Path $final -Leaf), ((Get-Item $final).Length / 1KB), $meta)
        return
    }
    $rep = Join-Path $Dest 'reports'
    New-Item -ItemType Directory -Path $rep -Force | Out-Null
    $tmpTar = Join-Path $env:TEMP ('fw-reports-' + [guid]::NewGuid().ToString('N') + '.tar')
    try {
        & cmd.exe /c "`"$tarExe`" -xOf `"$final`" reports.tar > `"$tmpTar`""
        & $tarExe -xf $tmpTar -C $rep --strip-components 2
        if ($LASTEXITCODE -ne 0) { Write-Log 'the reports could not be unpacked' }
    } finally { Remove-Item $tmpTar -ErrorAction SilentlyContinue }
    Write-Log ("ok {0} ({1:N0} KB) {2}" -f (Split-Path $final -Leaf), ((Get-Item $final).Length / 1KB), $meta)
}

# The weekly copy of the config: one full export, kept as a full copy (once a year) or as the difference from it.
function Invoke-ConfigDiff([string]$Folder) {
    if (-not (Test-Path $python)) { throw "$python is missing" }
    $work = Join-Path $Dest 'work'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        Invoke-Pull -Folder $work -NoReports
        foreach ($f in (Get-ChildItem $work -Filter 'fw-*.tar' | Sort-Object Name)) {
            $ErrorActionPreference = 'Continue'   # a line on stderr must not stop Windows PowerShell 5.1 before the exit code is read
            $out = & $python -I (Join-Path $PSScriptRoot 'fw-diff.py') add $f.FullName $Folder 2>&1
            $code = $LASTEXITCODE
            $ErrorActionPreference = 'Stop'
            foreach ($l in $out) { Write-Log "$l" }
            if ($code -ne 0) { throw "fw-diff failed (exit $code)" }
        }
    } finally {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# The weekly archives of the database that are not here yet.
function Invoke-Archive([string]$Folder) {
    $sshArgs = '-i', $key, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=15', "fwbackup@$Target"
    $list = @(& ssh @sshArgs 'archive-list')
    if ($LASTEXITCODE -ne 0) { throw "archive-list failed (ssh exit $LASTEXITCODE)" }
    $bad = 0
    foreach ($l in $list) {
        if ($l -notmatch '^([0-9a-f]{64})  (fwdb-[A-Za-z0-9-]+\.tar)$') { throw "unexpected line in the archive list" }
        $hash, $name = $Matches[1], $Matches[2]
        $final = Join-Path $Folder $name
        if (Test-Path $final) {
            if ((Get-FileHash -Algorithm SHA256 $final).Hash.ToLower() -ne $hash) { Write-Log "DIFFERENT, left as it is: $name"; $bad++ }
            continue
        }
        $part = "$final.part"
        & cmd.exe /c "ssh -i `"$key`" -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=15 fwbackup@$Target `"archive $name`" > `"$part`""
        if ($LASTEXITCODE -ne 0 -or (Get-FileHash -Algorithm SHA256 $part).Hash.ToLower() -ne $hash) {
            Remove-Item $part -ErrorAction SilentlyContinue
            Write-Log "FAIL $name was not received complete"; $bad++
            continue
        }
        Move-Item $part $final
        Write-Log ("ok {0} ({1:N0} KB)" -f $name, ((Get-Item $final).Length / 1KB))
    }
    if ($bad) { throw "$bad archive(s) with a problem" }
    Write-Log "archive: $($list.Count) on the firewall, $(@(Get-ChildItem $Folder -Filter 'fwdb-*.tar').Count) here"
}

function Remove-Old {
    $all = Get-ChildItem $Dest -Filter 'fw-*.tar' | Sort-Object Name -Descending
    $keep = @{}
    $all | Select-Object -First $KeepDaily | ForEach-Object { $keep[$_.Name] = 1 }
    $all | Group-Object { $_.Name.Substring(3, 6) } | Select-Object -First $KeepMonthly |
        ForEach-Object { $keep[$_.Group[0].Name] = 1 }
    $all | Where-Object { -not $keep.ContainsKey($_.Name) } | ForEach-Object {
        Remove-Item $_.FullName
        Write-Log "removed $($_.Name)"
    }
}

Initialize-Dest

if ($Setup) {
    if (-not (Test-Path $key)) {
        # An empty passphrase: Windows PowerShell 5.1 drops a bare '' argument, PowerShell 7 passes it.
        $empty = if ($PSVersionTable.PSVersion.Major -ge 7) { '' } else { '""' }
        & ssh-keygen -q -t ed25519 -N $empty -C 'fwbackup@ADMINPC' -f $key
        if ($LASTEXITCODE -ne 0) { throw 'ssh-keygen failed' }
    }
    $pub = (Get-Content "$key.pub" -Raw).Trim()
    if ($From -notmatch '^[0-9A-Fa-f.:,/*?!]+$') { throw "-From must be a list of addresses with commas, not '$From'" }
    $line = 'restrict,from="' + $From + '",command="sudo -n /usr/local/sbin/fw-backup-export \"$SSH_ORIGINAL_COMMAND\"" ' + $pub
    $remote = "getent passwd fwbackup >/dev/null || { echo 'no fwbackup user: run deploy.sh first' >&2; exit 1; }; " +
        "sudo install -d -m 700 -o fwbackup -g fwbackup /var/lib/fwbackup/.ssh && " +
        "sudo sh -c 'umask 077; tr -d [:cntrl:] >/var/lib/fwbackup/.ssh/authorized_keys && chown fwbackup:fwbackup /var/lib/fwbackup/.ssh/authorized_keys'"
    $line | & ssh -i $adminKey -o BatchMode=yes "fwadmin@$Target" $remote
    if ($LASTEXITCODE -ne 0) { throw 'could not install the key on the firewall' }
    Write-Log "key installed on $Target"
}

if ($Register) {
    $taskArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Target $Target"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArgs
    $trigger = New-ScheduledTaskTrigger -Daily -At '06:30'
    $principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
    Register-ScheduledTask -TaskPath '\ConanFirewall\' -TaskName 'Pull-Backup' -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
    Write-Log "task \ConanFirewall\Pull-Backup registered (daily 06:30, target $Target)"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "$taskArgs -Weekly -ArchiveDest `"$ArchiveDest`" -Python `"$Python`""
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Tuesday -At '07:00'
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 4)
    Register-ScheduledTask -TaskPath '\ConanFirewall\' -TaskName 'Weekly-Archive' -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
    Write-Log "task \ConanFirewall\Weekly-Archive registered (Tuesday 07:00, to $ArchiveDest)"
    if (-not $Setup) { return }
}

try {
    if ($Weekly) {
        $free = (Get-PSDrive (Split-Path $Dest -Qualifier).TrimEnd(':')).Free
        if ($free -lt 20GB) { throw ("only {0:N0} GB free on {1}" -f ($free / 1GB), $Dest) }
        $config, $database = (Join-Path $Dest 'config'), (Join-Path $Dest 'database')
        New-Item -ItemType Directory -Path $config, $database -Force | Out-Null
        Invoke-ConfigDiff $config
        Invoke-Archive $database
    } else {
        Invoke-Pull
        Remove-Old
    }
} catch {
    Write-Log "FAIL $($_.Exception.Message)"
    exit 1
}
