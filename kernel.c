// I/O
static void outb(unsigned short port, unsigned char val) {
    __asm__ volatile("outb %0, %1" : : "a"(val), "d"(port));
}
static unsigned char inb(unsigned short port) {
    unsigned char val;
    __asm__ volatile("inb %1, %0" : "=a"(val) : "d"(port));
    return val;
}
static void outw(unsigned short port, unsigned short val) {
    __asm__ volatile("outw %0, %1" : : "a"(val), "d"(port));
}
static unsigned short inw(unsigned short port) {
    unsigned short val;
    __asm__ volatile("inw %1, %0" : "=a"(val) : "d"(port));
    return val;
}
static void outl(unsigned short port, unsigned int val) {
    __asm__ volatile("outl %0, %1" : : "a"(val), "d"(port));
}
static unsigned int inl(unsigned short port) {
    unsigned int val;
    __asm__ volatile("inl %1, %0" : "=a"(val) : "d"(port));
    return val;
}

// Debug output (bochs/qemu -debugcon)
static void dbg(char c) { outb(0xE9, c); }
static void dbgs(const char *s) { while (*s) dbg(*s++); }
static void dbgx(unsigned int v) {
    int i;
    for (i = 7; i >= 0; i--) {
        unsigned char n = v >> (i * 4) & 0xF;
        dbg(n < 10 ? '0' + n : 'A' + n - 10);
    }
}

#define PCI_ADDR 0xCF8
#define PCI_DATA 0xCFC

static unsigned int pci_read(unsigned char bus, unsigned char dev, unsigned char reg) {
    outl(PCI_ADDR, 0x80000000 | (bus << 16) | (dev << 11) | reg);
    return inl(PCI_DATA);
}
static void pci_write(unsigned char bus, unsigned char dev, unsigned char reg, unsigned int val) {
    outl(PCI_ADDR, 0x80000000 | (bus << 16) | (dev << 11) | reg);
    outl(PCI_DATA, val);
}

static unsigned short io;
static unsigned char mac[6];
static unsigned char *rx_ring = (unsigned char*)0x100000;
static unsigned char *tx_buf0 = (unsigned char*)0x102000;
static unsigned char *tx_buf1 = (unsigned char*)0x102800;
static unsigned short rx_ptr = 0;

#define rx_phys 0x100000
#define tx0_phys 0x102000
#define tx1_phys 0x102800

#define RTL_IDR0  0x00
#define RTL_MAR0  0x08
#define RTL_TXSTAT0 0x10
#define RTL_TXADDR0 0x20
#define RTL_TXSTAT1 0x14
#define RTL_TXADDR1 0x24
#define RTL_RBSTART 0x30
#define RTL_CMD   0x37
#define RTL_CAPR  0x38
#define RTL_CBR   0x3A
#define RTL_IMR   0x3C
#define RTL_ISR   0x3E
#define RTL_TCR   0x40
#define RTL_RCR   0x44
#define RTL_CONFIG1 0x52
#define RTL_MSR   0x58
#define RTL_CFG9346 0x50

#define RX_BUF_LEN 8208 // 8192+16
#define TX_RETRY 5000

#define IBWE 0x40

static int rtl_init(void) {
    outb(io + RTL_CMD, 0x10);
    int w = 0;
    while ((inb(io + RTL_CMD) & 0x10) && w < 10000) w++;

    outb(io + RTL_CFG9346, 0xC0);
    outb(io + RTL_CONFIG1, inb(io + RTL_CONFIG1) | IBWE);
    outb(io + RTL_CFG9346, 0x00);

    unsigned int *p = (unsigned int*)rx_ring;
    for (int i = 0; i < RX_BUF_LEN / 4; i++) p[i] = 0;

    outl(io + RTL_RBSTART, rx_phys);
    outw(io + RTL_CAPR, 0);
    outl(io + RTL_RCR, 0x0000000F);
    outb(io + RTL_CMD, 0x0C);
    outw(io + RTL_IMR, 0x0005);

    for (int i = 0; i < 6; i++)
        mac[i] = inb(io + RTL_IDR0 + i);

    rx_ptr = 0;
    return 0;
}

static int rtl_send(void *data, int len) {
    unsigned char *src = (unsigned char*)data;
    unsigned char *dst = tx_buf0;
    for (int i = 0; i < len; i++)
        dst[i] = src[i];

    outl(io + RTL_TXADDR0, tx0_phys);
    outl(io + RTL_TXSTAT0, (len < 0x3FF ? len : 0x3FF) | 0x100);

    int w = 0;
    while (w < 100000) {
        if (inw(io + RTL_ISR) & 0x0004) {
            outw(io + RTL_ISR, 0x0004);
            return 0;
        }
        w++;
    }
    return -1;
}

static int rtl_poll(unsigned char *buf) {
    unsigned short cbr = inw(io + RTL_CBR);
    int avail = cbr - rx_ptr;
    if (avail < 0) avail += RX_BUF_LEN;
    if (avail < 4) return -1;

    unsigned int *desc = (unsigned int*)(rx_ring + rx_ptr);
    unsigned int status = *desc;
    if (!(status & 0x01)) return -1;

    unsigned short frame_len = status >> 16;
    unsigned short data_len = frame_len - 4; // minus CRC

    unsigned char *pkt_data = rx_ring + rx_ptr + 4;
    int copy_len = data_len < 1516 ? data_len : 1516;
    for (int i = 0; i < copy_len; i++)
        buf[i] = pkt_data[i];

    rx_ptr += frame_len + 4;
    if (rx_ptr >= RX_BUF_LEN) rx_ptr -= RX_BUF_LEN;

    return copy_len;
}

static void dump_status(void) {
    dbgs("CMD="); dbgx(inb(io + RTL_CMD));
    dbgs(" ISR="); dbgx(inw(io + RTL_ISR));
    dbgs(" CAPR="); dbgx(inw(io + RTL_CAPR));
    dbgs(" CBR="); dbgx(inw(io + RTL_CBR));
    dbgs(" TXSTAT0="); dbgx(inl(io + RTL_TXSTAT0));
    dbgs(" MSR="); dbgx(inb(io + RTL_MSR));
    dbg('\n');
}

// Build a simple ARP packet
static void make_arp(unsigned char *buf, unsigned char *src_mac, unsigned int src_ip,
                     unsigned int dst_ip) {
    // Ethernet header (14 bytes)
    for (int i = 0; i < 6; i++) buf[i] = 0xFF; // dst MAC = broadcast
    for (int i = 0; i < 6; i++) buf[6+i] = src_mac[i]; // src MAC
    buf[12] = 0x08; buf[13] = 0x06; // EtherType = ARP

    // ARP header (28 bytes)
    buf[14] = 0x00; buf[15] = 0x01; // HTYPE = Ethernet
    buf[16] = 0x08; buf[17] = 0x00; // PTYPE = IPv4
    buf[18] = 6; buf[19] = 4; // HLEN=6, PLEN=4
    buf[20] = 0x00; buf[21] = 0x01; // OPER = Request

    for (int i = 0; i < 6; i++) buf[22+i] = src_mac[i]; // SHA
    buf[28] = src_ip >> 24; buf[29] = src_ip >> 16;
    buf[30] = src_ip >> 8; buf[31] = src_ip;
    for (int i = 0; i < 6; i++) buf[32+i] = 0; // THA = 0
    buf[38] = dst_ip >> 24; buf[39] = dst_ip >> 16;
    buf[40] = dst_ip >> 8; buf[41] = dst_ip;
}

void kernel_main(void) {
    // Memory test
    dbg('Z');

    // Find RTL8139
    for (int i = 0; i < 256; i++) {
        unsigned int vd = pci_read(i >> 5, i & 31, 0);
        if (vd == 0xFFFFFFFF) continue;
        if ((vd & 0xFFFF) != 0x10EC) continue;
        if ((vd >> 16) != 0x8139) continue;

        // Enable bus master
        unsigned int cmd = pci_read(i >> 5, i & 31, 4);
        pci_write(i >> 5, i & 31, 4, cmd | 4);

        io = (unsigned short)(pci_read(i >> 5, i & 31, 0x10) & 0xFFFFFFF0);
        dbgs("IO="); dbgx(io); dbg('\n');
        break;
    }
    if (!io) { dbgs("NoRTL\n"); for(;;); }

    // Debug: check I/O
    dbgs("IDR0="); dbgx(inb(io + RTL_IDR0));
    dbgs(" CMD="); dbgx(inb(io + RTL_CMD));
    dbgs(" CBR="); dbgx(inw(io + RTL_CBR));
    dbg('\n');

    if (rtl_init()) { dbgs("InitFail\n"); for(;;); }

    // Show MAC
    dbgs("MAC ");
    for (int i = 0; i < 6; i++) {
        dbgx(mac[i]); if (i < 5) dbg(':');
    }
    dbg('\n');

    dump_status();

    // Build and send ARP request to gateway
    unsigned char pkt[64];
    make_arp(pkt, mac, 0x0A00020F, 0x0A000202); // 10.0.2.15 -> 10.0.2.2

    dbgs("TX-ARP\n");
    if (rtl_send(pkt, 42) < 0) {
        dbgs("TXfail\n");
    } else {
        dbgs("TXok\n");
    }

    dump_status();

    // Poll for RX
    unsigned char rxb[1516];
    int poll;
    for (poll = 0; poll < 50000; poll++) {
        int len = rtl_poll(rxb);
        if (len > 0) {
            dbgs("RX len="); dbgx(len); dbg('\n');
            break;
        }
    }
    if (poll >= 50000) {
        dbgs("NoRX\n");
        dump_status();
    }

    dbgs("END\n");
    for (;;);
}
