CC = x86_64-w64-mingw32-gcc
LD = /usr/bin/ld.bfd.exe
NASM = nasm
OBJCOPY = objcopy
DD = dd

CFLAGS = -m32 -Os -ffreestanding -nostdlib -nostdinc -fno-pie -w
LDFLAGS = -m i386pe --oformat pe-i386 --section-start=.text=0x1000 --section-start=.bss=0x3000

all: floppy.img

bootloader.bin: bootloader.asm
	$(NASM) -f bin -o $@ $<

kernel.bin: entry.o kernel.o
	$(LD) $(LDFLAGS) -o kernel.pe $^
	$(OBJCOPY) -O binary kernel.pe $@
	@ls -la $@

entry.o: entry.asm
	$(NASM) -f win32 -o $@ $<

kernel.o: kernel.c
	$(CC) $(CFLAGS) -c -o $@ $<

floppy.img: bootloader.bin kernel.bin
	$(DD) if=/dev/zero of=$@ bs=512 count=2880 2>/dev/null
	$(DD) if=bootloader.bin of=$@ bs=512 count=1 conv=notrunc 2>/dev/null
	$(DD) if=kernel.bin of=$@ bs=512 seek=1 conv=notrunc 2>/dev/null
	@echo "BUILD OK"

run: floppy.img
	qemu-system-i386 -drive file=$<,format=raw,if=floppy -boot a -nographic -no-reboot -m 32 -debugcon stdio -nic user,model=rtl8139

clean:
	rm -f *.o *.bin *.elf *.pe floppy.img
