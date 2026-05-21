# RAWNet — Raw Architecture Network

**32-bit RTL8139 driver from scratch in assembly: Ethernet/IP/UDP/DNS on bare metal (no OS).**

## What

A complete network stack in 1536 bytes of x86 assembly (`boot.s`), running directly in 32-bit protected mode inside QEMU:

```
bootloader (512B) → boot.s (1.5KB) → RTL8139 NIC → ARP + ICMP + IP + UDP + DNS
```

The stack independently (no kernel, no libc) initializes a PCI RTL8139 NIC, sends/receives raw Ethernet frames, resolves ARP, parses IP, handles UDP, and runs a full DNS server responding to external queries on port 5353.

## Why

- See exactly what happens between `socket.send()` and the wire — every port write, every bit field
- Understand network protocols at the hardware level (MAC, IP, UDP, DNS checksums, endianness)
- Build a foundation for bare-metal drivers, embedded networking, bootloaders, and hypervisor work
- Reproduce in 1.5KB of asm what modern OSes do in millions of lines of C

## How it works (6 packets, 500 bytes)

```
Host sends UDP to :23000  ──hostfwd──▶  Guest :5353  ──DNS parse──▶  Build response
                                            │
Host ◀──slirp NAT── Guest RTL8139 TX ◀──────┘
```

| # | Size | Protocol | Description |
|---|------|----------|-------------|
| 1 | 42B | ICMP Echo | 10.0.2.15 → 10.0.2.2, initializes slirp NAT |
| 2 | 60B | ARP Req | Who has 10.0.2.15? |
| 3 | 60B | ARP Reply | I do: 52:54:00:12:34:56 |
| 4 | 60B | ICMP Reply | 10.0.2.2 → 10.0.2.15 |
| 5 | 71B | DNS Query | example.com A via :5353 |
| 6 | 87B | DNS Resp | ID=0x1234, flag=0x8180, answer=10.0.2.15 |

## Quick start

```powershell
# Prerequisites: nasm, dd, QEMU
cd kernel
make
qemu-system-i386 -fda floppy.img -boot a -no-reboot -m 32 `
  -debugcon stdio `
  -netdev user,id=mynet,hostfwd=udp::23000-:5353 `
  -device rtl8139,netdev=mynet `
  -object filter-dump,id=dump0,netdev=mynet,file=traffic.pcap
```

Then in another terminal:

```powershell
$udp = New-Object System.Net.Sockets.UdpClient
$ep = [Net.IPEndPoint]::new([Net.IPAddress]::Loopback, 23000)
$q = [byte[]]@(0x12,0x34,0x01,0x00,0x00,0x01,0x00,0x00,0x00,0x00,
               0x00,0x00,0x07,0x65,0x78,0x61,0x6d,0x70,0x6c,0x65,
               0x03,0x63,0x6f,0x6d,0x00,0x00,0x01,0x00,0x01)
$udp.Send($q, $q.Length, $ep)
$rcv = $udp.Receive([ref]$ep)
# → DNS response with A=10.0.2.15
```

## Repo structure

```
kernel/
├── bootloader.asm    # 512B MBR: CHS read, A20, GDT, pmode jump
├── boot.s            # 1536B driver: RTL8139 + ARP + ICMP + IP + UDP + DNS
├── kernel.c          # C-version driver (WIP, bigger, easier to extend)
├── entry.asm         # C kernel entry point (stack setup)
├── Makefile          # Build both floppy variants
├── test_dns.ps1      # PowerShell test client
└── floppy.img        # Generated 1.44MB bootable image
```

## License

MIT — do whatever you want.
