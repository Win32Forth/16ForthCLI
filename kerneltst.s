// Minimal working Forth kernel skeleton for ARM64 / Xcode

.equ CELL, 8

.macro NEXT
    ldr  x21, [x19], #8
    ldr  x1,  [x21]
    br   x1
.endm

.macro DPUSH
    str  x20, [x22, #-8]!
    mov  x20, x0
.endm

.macro DPOP
    mov  x0,  x20
    ldr  x20, [x22], #8
.endm

// ------------------------------------------------------------------
// Code
// ------------------------------------------------------------------
.text
.align 4

// 16 primitives
XEXIT:     ldr x19, [x23], #8 ; NEXT
XLIT:      ldr x0, [x19], #8 ; DPUSH ; NEXT
XBRANCH:   ldr x0, [x19] ; add x19, x19, x0 ; NEXT
X0BRANCH:  DPOP ; cbz x0, 1f ; add x19, x19, #8 ; NEXT
1:         ldr x0, [x19] ; add x19, x19, x0 ; NEXT
XEXECUTE:  DPOP ; mov x21, x0 ; ldr x1, [x21] ; br x1
XFETCH:    ldr x0, [x20] ; mov x20, x0 ; NEXT
XSTORE:    DPOP ; mov x1, x0 ; DPOP ; str x0, [x1] ; NEXT
XPLUS:     DPOP ; add x20, x20, x0 ; NEXT
XMINUS:    DPOP ; sub x20, x20, x0 ; NEXT
XMUL:      DPOP ; mul x20, x20, x0 ; NEXT
XDIV:      DPOP ; sdiv x20, x20, x0 ; NEXT
XDUP:      mov x0, x20 ; DPUSH ; NEXT
XDROP:     DPOP ; NEXT
XSWAP:     ldr x0, [x22] ; str x20, [x22] ; mov x20, x0 ; NEXT
XOVER:     ldr x0, [x22] ; DPUSH ; NEXT
XEMIT:     DPOP ; strb w0, [sp, #-16]! ; mov x0, #1 ; mov x1, sp ; mov x2, #1 ; mov x16, #4 ; svc #0x80 ; add sp, sp, #16 ; NEXT

// Safe stop routine (must be in .text)
stop_code:
1:  b 1b

// ------------------------------------------------------------------
// Data
// ------------------------------------------------------------------
.section __DATA,__data
.align 4

data_stack:     .skip 4096
.align 3
return_stack:   .skip 2048
.align 3
user_dict:      .skip 64*1024
.align 3

here_ptr:       .quad user_dict
latest_var:     .quad 0

.align 3
XEMIT_cfa:
    .quad XEMIT

.align 3
stop_cfa:
    .quad stop_code

.align 3
test_thread:
    .quad XEMIT_cfa
    .quad XEMIT_cfa
    .quad XEMIT_cfa
    .quad stop_cfa

.align 3
one_emit:
    .quad XEMIT_cfa
    .quad stop_cfa

.section __TEXT,__cstring,cstring_literals
.align 3
hello_msg:
    .ascii "Hi\n"
after_msg:
    .ascii "AFTER\n"
    
// ------------------------------------------------------------------
// Cold start + main
// ------------------------------------------------------------------
.text
.align 4

.globl _kernel_cold_start
_kernel_cold_start:
    // stacks
    adrp x22, data_stack@page
    add  x22, x22, data_stack@pageoff
    add  x22, x22, #4096

    adrp x23, return_stack@page
    add  x23, x23, return_stack@pageoff
    add  x23, x23, #2048

    mov  x20, #0

    // 1. Direct "Hi\n"
    mov  x0, #1
    adrp x1, hello_msg@page
    add  x1, x1, hello_msg@pageoff
    mov  x2, #3
    mov  x16, #4
    svc  #0x80

    // 2. Put one character on the Forth stack
    mov  x0, #'!'
    DPUSH

    // 3. Threaded EMIT
    adrp x19, one_emit@page
    add  x19, x19, one_emit@pageoff
    NEXT

    // 4. If we ever get here, print a marker
    mov  x0, #1
    adrp x1, after_msg@page
    add  x1, x1, after_msg@pageoff
    mov  x2, #6
    mov  x16, #4
    svc  #0x80

1:  b 1b

.globl _main
_main:
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    bl   _kernel_cold_start
    mov  x0, #0
    ldp  x29, x30, [sp], #16
    ret
