/* Linux ZGhost Kernel Linker Script */
/* Based on standard Linux kernel linker script */

ENTRY(_start)

SECTIONS
{
    /* Kernel is loaded at 1MB by bootloader */
    . = 0x100000;
    
    .text : {
        *(.text)
        *(.text.*)
    }
    
    .rodata : {
        *(.rodata)
        *(.rodata.*)
    }
    
    .data : {
        *(.data)
        *(.data.*)
    }
    
    .bss : {
        *(.bss)
        *(.bss.*)
    }
    
    /* Kernel end marker */
    _kernel_end = .;
}