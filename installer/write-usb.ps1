<#
Writes the firewall installer ISO to a USB drive, then reads it back to verify.
ERASES THE WHOLE TARGET DISK.

A person runs this, not an agent. Find the stick's number first with Get-Disk (BusType USB), then run elevated,
with the full path of this script:
  Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File <full path>\write-usb.ps1 -DiskNumber N'

It writes the image that build-iso.sh left next to this script; -IsoPath names another one.
Guards: disk must be USB, not boot/system, smaller than 256 GB, larger than the ISO,
and you must type the disk number again at the prompt. Log: write-usb.log next to this script.
#>
param(
  [Parameter(Mandatory = $true)][int]$DiskNumber,
  [string]$IsoPath
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $IsoPath) { $IsoPath = Join-Path $here 'debian-13.7.0-amd64-firewall.iso' }
Start-Transcript -Path (Join-Path $here 'write-usb.log') -Force | Out-Null
try {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script elevated (Administrator).'
  }

  $iso = Get-Item -LiteralPath $IsoPath
  $disk = Get-Disk -Number $DiskNumber
  Write-Host ("Target: disk {0}  '{1}'  {2:N1} GB  bus={3}  serial={4}" -f $disk.Number, $disk.FriendlyName, ($disk.Size / 1GB), $disk.BusType, $disk.SerialNumber)
  Write-Host ("Image : {0}  {1:N0} bytes" -f $iso.FullName, $iso.Length)

  if ($disk.BusType -ne 'USB') { throw "Disk $DiskNumber is $($disk.BusType), not USB. Refusing." }
  if ($disk.IsBoot -or $disk.IsSystem) { throw "Disk $DiskNumber is a boot/system disk. Refusing." }
  if ($disk.Size -ge 256GB) { throw "Disk $DiskNumber is 256 GB or larger. Refusing (too big for a USB stick)." }
  if ($disk.Size -lt $iso.Length) { throw "Disk $DiskNumber is smaller than the ISO." }

  $vols = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue | Where-Object DriveLetter
  if ($vols) { Write-Host ("Drive letters on it now: " + (($vols | ForEach-Object { "$($_.DriveLetter):" }) -join ' ')) }

  $answer = Read-Host "Everything on disk $DiskNumber will be erased. Type the disk number again to continue"
  if ($answer -ne "$DiskNumber") { throw 'Not confirmed. Nothing was changed.' }

  Write-Host 'Clearing partition table...'
  if ($disk.PartitionStyle -ne 'RAW') {
    Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false
  }
  # Offline stops Windows from mounting the new partitions mid-write (not supported on some sticks)
  $wentOffline = $false
  try { Set-Disk -Number $DiskNumber -IsOffline $true; $wentOffline = $true } catch { Write-Host 'Note: could not set disk offline; continuing.' }

  Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class RawDisk {
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
  public static FileStream Open(int n, bool write) {
    uint access = write ? 0xC0000000u : 0x80000000u;          // GENERIC_READ|GENERIC_WRITE
    uint flags = write ? 0x80000000u : 0u;                     // FILE_FLAG_WRITE_THROUGH
    SafeFileHandle h = CreateFile(@"\\.\PhysicalDrive" + n, access, 3u, IntPtr.Zero, 3u, flags, IntPtr.Zero);
    if (h.IsInvalid) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    return new FileStream(h, write ? FileAccess.ReadWrite : FileAccess.Read, 1);   // 1 = no buffering
  }
}
'@

  $chunk = 4MB
  $buf = New-Object byte[] $chunk
  $isoHash = (Get-FileHash -LiteralPath $iso.FullName -Algorithm SHA256).Hash

  Write-Host 'Writing...'
  $src = [IO.File]::OpenRead($iso.FullName)
  $dst = [RawDisk]::Open($DiskNumber, $true)
  try {
    $done = 0L
    while (($n = $src.Read($buf, 0, $chunk)) -gt 0) {
      $len = [int]([Math]::Ceiling($n / 512) * 512)              # whole sectors only
      if ($len -ne $n) { [Array]::Clear($buf, $n, $len - $n) }
      $dst.Write($buf, 0, $len)
      $done += $n
      Write-Progress -Activity 'Writing ISO' -PercentComplete ([int](100 * $done / $iso.Length))
    }
    $dst.Flush()
  } finally { $dst.Dispose(); $src.Dispose() }
  Write-Progress -Activity 'Writing ISO' -Completed

  Write-Host 'Verifying (reading back)...'
  $sha = [Security.Cryptography.SHA256]::Create()
  $rd = [RawDisk]::Open($DiskNumber, $false)
  try {
    $left = $iso.Length
    while ($left -gt 0) {
      $want = [int][Math]::Min($chunk, [Math]::Ceiling($left / 512) * 512)
      $got = 0
      while ($got -lt $want) { $r = $rd.Read($buf, $got, $want - $got); if ($r -le 0) { throw 'Short read from USB.' }; $got += $r }
      $use = [int][Math]::Min($got, $left)
      [void]$sha.TransformBlock($buf, 0, $use, $null, 0)
      $left -= $use
    }
    [void]$sha.TransformFinalBlock($buf, 0, 0)
  } finally { $rd.Dispose() }
  $usbHash = -join ($sha.Hash | ForEach-Object { $_.ToString('X2') })

  if ($wentOffline) { Set-Disk -Number $DiskNumber -IsOffline $false }
  Update-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
  Write-Host "ISO SHA256: $isoHash"
  Write-Host "USB SHA256: $usbHash"
  if ($usbHash -ne $isoHash) { throw 'VERIFY FAILED: USB contents do not match the ISO.' }
  Write-Host 'RESULT: OK - USB written and verified.' -ForegroundColor Green
}
catch {
  Write-Host "RESULT: FAILED - $($_.Exception.Message)" -ForegroundColor Red
}
finally {
  if ($wentOffline) { try { Set-Disk -Number $DiskNumber -IsOffline $false } catch {} }
  Stop-Transcript | Out-Null
  Read-Host 'Press Enter to close'
}
