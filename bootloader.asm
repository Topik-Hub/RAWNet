BITS 16
ORG 0x7C00

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti

    mov si, loading_msg
    call print16

    xor ax, ax
    mov es, ax
    mov bx, 0x1000
    mov cx, 0x0002
    mov dx, 0x0000
    mov di, 64

.read_loop:
    push cx
    push dx
    mov ax, 0x0201
    int 0x13
    pop dx
    pop cx
    jc disk_error

    add bx, 512
    cmp bx, 0x9000
    jae .done_read

    inc cl
    cmp cl, 19
    jb .next

    mov cl, 1
    inc dh
    cmp dh, 2
    jb .next

    mov dh, 0
    inc ch
.next:
    dec di
    jnz .read_loop

.done_read:
    mov si, jump_msg
    call print16

    cli

    in al, 0x92
    or al, 2
    out 0x92, al

    lgdt [gdt_desc]
    mov eax, cr0
    or al, 1
    mov cr0, eax
    jmp 0x08:pmode

BITS 32
pmode:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov esp, 0x7C00

    jmp 0x08:0x1000

BITS 16
print16:
    lodsb
    test al, al
    jz .done
    mov ah, 0x0E
    int 0x10
    jmp print16
.done:
    ret

disk_error:
    mov si, error_msg
    call print16
    mov al, ah
    add al, '0'
    mov ah, 0x0E
    int 0x10
.halt:
    cli
    hlt
    jmp .halt

align 8
gdt:
    dq 0x0000000000000000
    dq 0x00CF9A000000FFFF
    dq 0x00CF92000000FFFF

gdt_desc:
    dw 23
    dd gdt

loading_msg: db "Loading kernel...", 13, 10, 0
jump_msg:    db "Jumping...", 13, 10, 0
error_msg:   db "ERR: ", 0

times 510 - ($ - $$) db 0
dw 0xAA55
