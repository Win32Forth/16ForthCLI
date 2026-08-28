// ----------------------------------------------------------------------------
// Embedded pure Forth source (the real high-level system)
// ----------------------------------------------------------------------------
.section __TEXT,__cstring,cstring_literals
.align 3
forth_source:
    .incbin "kernel.s"
forth_source_end:

.align 3
banner:
    .ascii "64Forth minimal kernel ready\n"
.equ banner_len, . - banner




.text
.align 4
_set_source:        // x0 = addr, x1 = len
    adrp x2, source_addr@page
    add  x2, x2, source_addr@pageoff
    str  x0, [x2]
    adrp x2, source_len@page
    add  x2, x2, source_len@pageoff
    str  x1, [x2]
    adrp x2, to_in@page
    add  x2, x2, to_in@pageoff
    str  xzr, [x2]
    ret



    // interpret the embedded Forth source
    adrp x0, forth_source@page
    add  x0, x0, forth_source@pageoff
    mov  x1, x0
    // length is known at link time (or compute)
    adrp x2, forth_source_end@page
    add  x2, x2, forth_source_end@pageoff
    sub  x1, x2, x0
    bl   _set_source
    b    _interpret_loop


    .ascii "\\ Minimal high-level Forth\n"

