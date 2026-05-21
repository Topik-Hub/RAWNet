$env:PATH = "C:\msys64\mingw64\bin;C:\msys64\usr\bin;$env:PATH"
$tmp = [System.IO.Path]::GetTempPath()
$logf = Join-Path $tmp "qemu_debug.log"
Remove-Item $logf -ErrorAction SilentlyContinue

$qemu = Start-Process -NoNewWindow -FilePath "qemu-system-i386" `
  -ArgumentList "-fda C:\PY\Internet\kernel\floppy.img -boot a -no-reboot -m 32 -debugcon file:$logf -nic user,model=rtl8139,hostfwd=udp::23000-:5353 -vga std -serial none -parallel none -monitor null" `
  -PassThru
Start-Sleep -Seconds 7

if ($qemu.HasExited) {
  Write-Output "QEMU exited early"
  if (Test-Path $logf) { Get-Content $logf -Raw }
  exit
}

Write-Output "Sending DNS query..."
$udp = New-Object System.Net.Sockets.UdpClient
$ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Loopback, 23000)
$q = [byte[]]@(0x12,0x34,0x01,0x00,0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x07,0x65,0x78,0x61,0x6d,0x70,0x6c,0x65,0x03,0x63,0x6f,0x6d,0x00,0x00,0x01,0x00,0x01)
$sent = $udp.Send($q, $q.Length, $ep)
Write-Output "Sent $sent bytes"

Start-Sleep -Seconds 2
try {
  $ar = $udp.BeginReceive($null, $null)
  if ($ar.AsyncWaitHandle.WaitOne(2000)) {
    $rem = $null
    $resp = $udp.EndReceive($ar, [ref]$rem)
    Write-Output "Received $($resp.Length) bytes"
    $hex = ($resp | ForEach-Object { $_.ToString("X2") }) -join " "
    Write-Output "HEX: $hex"
    $id = ($resp[0] -shl 8) -bor $resp[1]
    $fl = ($resp[2] -shl 8) -bor $resp[3]
    Write-Output "DNS ID=0x$('{0:X4}' -f $id) Flags=0x$('{0:X4}' -f $fl)"
    $anc = ($resp[6] -shl 8) -bor $resp[7]
    Write-Output "ANCOUNT=$anc"
    if ($anc -eq 1) {
      Write-Output "DNS response OK!"
    }
  } else {
    Write-Output "No response (timeout)"
  }
} catch {
  Write-Output "Error: $_"
}
$udp.Close()
$qemu.Kill()
Start-Sleep -Seconds 1
if (Test-Path $logf) {
  $c = Get-Content $logf -Raw
  if ($c.Length -gt 0) {
    Write-Output "===DEBUGCON==="
    Write-Output $c
  }
}
