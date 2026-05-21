BITS 32

extern _kernel_main

section .text
global _start
_start:
    mov esp, stack_top
    call _kernel_main
    cli
    hlt

section .bss
align 4
stack_bot: resb 4096
stack_top:
