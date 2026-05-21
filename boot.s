BITS 32
ORG 0x1000

%define RTL_TSD0  0x10
%define RTL_TSAD0 0x20
%define RTL_RBSTART 0x30
%define RTL_CMD   0x37
%define RTL_CAPR  0x38
%define RTL_CBR   0x3A
%define RTL_IMR   0x3C
%define RTL_ISR   0x3E
%define RTL_TCR   0x40
%define RTL_RCR   0x44
%define RTL_CFG9346 0x50
%define RTL_CONFIG1 0x52
%define RTL_MSR   0x58

%define RX_RING     0x4000
%define TX_BUF1     0x5000
%define TX_BUF2     0x5800
%define STACK_TOP   0x8000
%define VARS_BASE   0x6000
%define PKT_BUF     0x7000
%define IO_BASE     VARS_BASE
%define PKT_LEN     (VARS_BASE+4)
%define PKT_SIZE    (VARS_BASE+8)
%define RX_PTR      (VARS_BASE+12)

dbg_port equ 0xE9

_start:
    cli
    mov esp, STACK_TOP
    cld
    xor eax, eax
    mov edi, 0
    mov ecx, 0x400 / 4
    rep stosd
    mov edi, RX_RING
    mov ecx, 0x3000 / 4
    rep stosd
    call pci_find
    test eax, eax
    jz .halt
    mov [IO_BASE], eax
    call rtl_init
    mov al, 'R'
    call dbg_c

    xor eax, eax
    mov [RX_PTR], eax

    ; Send ICMP Echo to establish MAC mapping with slirp
    mov edi, TX_BUF2
    call build_icmp_echo
    mov [PKT_LEN], eax
    call rtl_tx0

.main_loop:
    call rtl_wait_rx
.next:
    call read_rx
    mov ax, [PKT_SIZE]
    test ax, ax
    jz .main_loop
    call dispatch_pkt
    jmp .next

.halt:
    mov al, 'H'
    call dbg_c
    cli
    hlt

; Read one packet from RX ring using CBR (hardware write pointer)
; Returns PKT_SIZE=0 when no more packets
read_rx:
    mov edx, [IO_BASE]
    add edx, RTL_CBR
    in ax, dx
    movzx eax, ax
    sub eax, [RX_PTR]
    jz .none
    cmp eax, 4
    jb .none
    mov esi, RX_RING
    add esi, [RX_PTR]
    lodsd
    test al, 1
    jz .none
    shr eax, 16
    mov WORD [PKT_SIZE], ax
    movzx ecx, ax
    mov esi, RX_RING
    add esi, [RX_PTR]
    add esi, 4
    mov edi, PKT_BUF
    rep movsb
    movzx eax, word [PKT_SIZE]
    add eax, 4
    add [RX_PTR], eax
    ret
.none:
    mov WORD [PKT_SIZE], 0
    ret

; Dispatch packet by ethertype
dispatch_pkt:
    mov ax, WORD [PKT_BUF + 12]
    cmp ax, 0x0608
    je handle_arp
    cmp ax, 0x0008
    je .ipv4
    ret
.ipv4:
    mov al, BYTE [PKT_BUF + 23]
    cmp al, 17
    je handle_udp
    ret

handle_arp:
    mov ax, WORD [PKT_BUF + 20]
    cmp ax, 0x0100
    jne .done
    mov eax, DWORD [PKT_BUF + 38]
    cmp eax, 0x0F02000A
    jne .done
    call build_arp_reply
    mov [PKT_LEN], eax
    call rtl_tx1
.done:
    ret

handle_udp:
    mov ax, WORD [PKT_BUF + 36]
    xchg al, ah
    cmp ax, 5353
    jne .other
    call build_dns_response
    mov [PKT_LEN], eax
    mov al, 'S'
    call dbg_c
    call rtl_tx2
    mov al, 'D'
    call dbg_c
    ret
.other:
    ret

; Build ARP reply in TX_BUF2
build_arp_reply:
    mov edi, TX_BUF2
    mov esi, PKT_BUF + 6
    movsd
    movsw
    mov eax, 0x12005452
    stosd
    mov ax, 0x5634
    stosw
    mov ax, 0x0608
    stosw
    mov ax, 0x0100
    stosw
    mov ax, 0x0008
    stosw
    mov al, 6
    stosb
    mov al, 4
    stosb
    mov ax, 0x0200
    stosw
    mov eax, 0x12005452
    stosd
    mov ax, 0x5634
    stosw
    mov eax, 0x0F02000A
    stosd
    mov esi, PKT_BUF + 6
    movsd
    movsw
    mov eax, 0x0202000A
    stosd
    mov ecx, 18
    xor al, al
    rep stosb
    mov eax, edi
    sub eax, TX_BUF2
    ret

; Build DNS response in TX_BUF2 from PKT_BUF
build_dns_response:
    mov edi, TX_BUF2
    ; Ethernet: dst = pkt src
    mov esi, PKT_BUF + 6
    movsd
    movsw
    ; Ethernet: src = our MAC
    mov eax, 0x12005452
    stosd
    mov ax, 0x5634
    stosw
    mov ax, 0x0008
    stosw
    ; IP header
    mov ax, 0x0045
    stosw
    xor eax, eax
    stosw
    stosw
    stosw
    mov ax, 0x1140
    stosw
    xor eax, eax
    stosw
    mov eax, 0x0F02000A
    stosd
    mov eax, [PKT_BUF + 26]
    stosd
    ; UDP header
    mov ax, [PKT_BUF + 36]
    stosw
    mov ax, [PKT_BUF + 34]
    stosw
    xor eax, eax
    stosw
    stosw
    ; edi now points to DNS section
    mov ecx, edi
    ; ID from request
    mov ax, [PKT_BUF + 42]
    stosw
    ; flags = 0x8180
    mov ax, 0x8081
    stosw
    ; QDCOUNT = 1, ANCOUNT = 1, NS = 0, AR = 0
    mov ax, [PKT_BUF + 46]
    stosw
    mov ax, 0x0100
    stosw
    xor ax, ax
    stosw
    stosw
    ; copy question (QNAME + QTYPE + QCLASS)
    mov esi, PKT_BUF + 54
.qcpy:
    lodsb
    stosb
    test al, al
    jnz .qcpy
    movsd
    ; answer: name ptr 0xC00C
    mov ax, 0x0CC0
    stosw
    mov ax, 0x0100
    stosw
    mov ax, 0x0100
    stosw
    xor ax, ax
    stosw
    mov ax, 0x2C01
    stosw
    mov ax, 0x0400
    stosw
    mov eax, 0x0F02000A
    stosd
    ; compute lengths
    mov eax, edi
    sub eax, ecx
    add eax, 8
    mov ebx, eax
    add ebx, 20
    xchg bh, bl
    mov [TX_BUF2 + 16], bx
    xchg ah, al
    mov [TX_BUF2 + 38], ax
    ; IP checksum
    mov esi, TX_BUF2 + 14
    mov ecx, 10
    xor edx, edx
.csum:
    lodsw
    add dx, ax
    dec ecx
    jnz .csum
    mov eax, edx
    shr eax, 16
    add ax, dx
    adc ax, 0
    not ax
    mov [TX_BUF2 + 24], ax
    ; return total length
    mov eax, edi
    sub eax, TX_BUF2
    ret

; Shared TX: write TSAD+TSD, jump to rtl_tx_wait
rtl_tx0:
    pushad
    mov edx, [IO_BASE]
    add edx, 0x20
    mov eax, TX_BUF2
    out dx, eax
    mov edx, [IO_BASE]
    add edx, 0x10
    jmp rtl_tx_wait

rtl_tx1:
    pushad
    mov edx, [IO_BASE]
    add edx, 0x24
    mov eax, TX_BUF2
    out dx, eax
    mov edx, [IO_BASE]
    add edx, 0x14
    jmp rtl_tx_wait

rtl_tx2:
    pushad
    mov edx, [IO_BASE]
    add edx, 0x28
    mov eax, TX_BUF2
    out dx, eax
    mov edx, [IO_BASE]
    add edx, 0x18
    jmp rtl_tx_wait

rtl_tx_wait:
    mov eax, [PKT_LEN]
    out dx, eax
    mov edx, [IO_BASE]
    add edx, RTL_ISR
    mov ecx, 0x100000
.xx:in al, dx
    test al, 4
    jnz .ok
    dec ecx
    jnz .xx
    popad
    ret
.ok:
    mov al, 4
    out dx, al
    popad
    ret

; Wait for ROK with delay loop
rtl_wait_rx:
    pushad
    mov edx, [IO_BASE]
    add edx, RTL_ISR
    mov ecx, 100000
.l:
    in ax, dx
    test ax, 1
    jnz .g
    dec ecx
    jnz .l
    popad
    ret
.g:
    mov ax, 1
    out dx, ax
    popad
    ret

; Build ICMP Echo (edi=buffer) - Total Length fixed to 0x1C (28 bytes)
build_icmp_echo:
    push ebp
    mov ebp, edi
    mov al, 0x52
    stosb
    mov al, 0x55
    stosb
    mov al, 0x0A
    stosb
    mov al, 0x00
    stosb
    mov al, 0x02
    stosb
    mov al, 0x02
    stosb
    mov eax, 0x12005452
    stosd
    mov ax, 0x5634
    stosw
    mov ax, 0x0008
    stosw
    mov ax, 0x0045
    stosw
    mov ax, 0x1C00
    stosw
    mov ax, 0x0100
    stosw
    mov ax, 0x0000
    stosw
    mov ax, 0x0140
    stosw
    xor eax, eax
    stosw
    mov eax, 0x0F02000A
    stosd
    mov eax, 0x0202000A
    stosd
    mov ax, 0x0008
    stosw
    xor eax, eax
    stosw
    mov ax, 0x0100
    stosw
    mov ax, 0x0100
    stosw
    mov esi, ebp
    add esi, 14
    mov ecx, 10
    xor edx, edx
.iph_csum:
    movzx eax, word [esi]
    add edx, eax
    add esi, 2
    dec ecx
    jnz .iph_csum
    mov eax, edx
    shr eax, 16
    add ax, dx
    adc ax, 0
    not ax
    mov [ebp + 24], ax
    mov esi, ebp
    add esi, 34
    mov ecx, 6
    xor edx, edx
.icmp_csum:
    movzx eax, word [esi]
    add edx, eax
    add esi, 2
    dec ecx
    jnz .icmp_csum
    mov eax, edx
    shr eax, 16
    add ax, dx
    adc ax, 0
    not ax
    mov [ebp + 36], ax
    mov eax, edi
    sub eax, ebp
    pop ebp
    ret

dbg_c:
    push edx
    mov dx, dbg_port
    out dx, al
    pop edx
    ret

pci_find:
    xor esi, esi
.l: mov eax, esi
    and eax, 31
    shl eax, 11
    mov ebx, esi
    shr ebx, 5
    shl ebx, 16
    or eax, ebx
    or eax, 0x80000000
    mov ecx, eax
    mov dx, 0xCF8
    out dx, eax
    mov dx, 0xCFC
    in eax, dx
    cmp eax, -1
    je .n
    movzx edx, ax
    cmp edx, 0x10EC
    jne .n
    shr eax, 16
    cmp ax, 0x8139
    jne .n
    mov eax, ecx
    or eax, 4
    mov dx, 0xCF8
    out dx, eax
    mov dx, 0xCFC
    in eax, dx
    or eax, 4
    out dx, eax
    mov eax, ecx
    or eax, 0x10
    mov dx, 0xCF8
    out dx, eax
    mov dx, 0xCFC
    in eax, dx
    and eax, -16
    ret
.n: inc esi
    cmp esi, 256
    jb .l
    xor eax, eax
    ret

rtl_init:
    pushad
    mov edx, [IO_BASE]
    add edx, RTL_CMD
    mov al, 0x10
    out dx, al
    mov ecx, 2000
.r: in al, dx
    test al, 0x10
    jz .rd
    dec ecx
    jnz .r
.rd:
    mov edx, [IO_BASE]
    add edx, RTL_CFG9346
    mov al, 0xC0
    out dx, al
    mov edx, [IO_BASE]
    add edx, RTL_CONFIG1
    in al, dx
    or al, 0x40
    out dx, al
    mov edx, [IO_BASE]
    add edx, RTL_CFG9346
    xor al, al
    out dx, al
    mov edx, [IO_BASE]
    add edx, RTL_RBSTART
    mov eax, RX_RING
    out dx, eax
    mov edx, [IO_BASE]
    add edx, RTL_CAPR
    xor ax, ax
    out dx, ax
    mov edx, [IO_BASE]
    add edx, RTL_RCR
    mov eax, 0x0000000F
    out dx, eax
    mov edx, [IO_BASE]
    add edx, RTL_IMR
    mov ax, 5
    out dx, ax
    mov edx, [IO_BASE]
    add edx, RTL_CMD
    mov al, 0x0C
    out dx, al
    popad
    ret

; Print AL as two hex chars
times 1536 - ($ - $$) db 0
