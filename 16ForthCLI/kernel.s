//
//  kernel.s
//  16ForthCLI
//
//  Minimal 64Forth-derived kernel — memory data stack (no TOS-in-register)
//
//  ARM64 (Apple Silicon) — clang / Xcode
//
//  Registers:
//    x19 = IP
//    x21 = W
//    x22 = DSP  (points AT TOS cell in memory; empty stack = &data_stack[DSTACK_SIZE])
//    x23 = RSP
//    x24 = &latest
//    x20 = scratch only — NOT TOS
//
//  Dictionary header (grows up from HERE):
//    HFA: counted HELP + pad 8
//    NFA: counted NAME (uppercase) + pad 8
//    LFA: previous CFA              @ CFA-16
//    FFA: flags                     @ CFA-8
//         bits 0-15  NFA_OFF, 16-31 HFA_OFF, bit 63 IMMEDIATE
//    CFA: code pointer (xt)
//    BODY @ CFA+8   (CREATE: does_ip @ CFA+8, PFA @ CFA+16)
//
// ============================================================================
// DATA STACK RULE
// ============================================================================
// The data stack lives entirely in memory.
//   DPUSH xn    stores xn and pre-decrements x22
//   DPOP  xn    loads xn and post-increments x22
// Peeking TOS is:  ldr xn, [x22]
// There is no hidden DUP. Every consume is an explicit DPOP.
// ============================================================================

.equ CELL, 8
.equ DSTACK_SIZE, 8192
.equ RSTACK_SIZE, 4096
.equ FL_IMM,     1
.equ FL_INLINE,  2
.equ FFA_INLINE, 62              // FFA bit 62

// NEXT — inner interpreter dispatch
// Typical M-series, L1 I/D hit, predicted indirect branch:
//   ~7–11 cycles wall, 3 issued memory ops + 1 indirect branch
//
.macro NEXT
    ldr  x21, [x19], #8     // 1  load xt from threaded list (IP), writeback IP
                            //    AGU + L1: often 4-cycle load-to-use for x21
                            //    post-index +8 is free on the load
    ldr  x1,  [x21]         // 2  load code address from CFA
                            //    cannot start until x21 ready → ~4 cycle stall
                            //    after 1 if back-to-back, L1 hit ~4 more
    br   x1                 // 3  indirect jump to primitive
                            //    predicted: ~1–3 cycles after x1 ready
                            //    mispredict: ~10–20+ cycles (pipeline flush)
.endm

.macro DPUSH reg
    str  \reg, [x22, #-8]!  // 1  store TOS-to-be at [DSP-8], DSP -= 8
                            //    pre-index writeback is free on the store
                            //    L1 store: typically 1 issued cycle;
                            //    store-to-load forward later ~4c if next DPOP
                            //    same address soon
.endm                       // ~1c issue; not on NEXT's load chain

.macro DPOP reg
    ldr  \reg, [x22], #8    // 1  load from [DSP], DSP += 8
                            //    post-index writeback is free on the load
                            //    L1 hit: ~4c load-to-use for \reg
                            //    miss: tens of cycles
.endm                       // ~4c to first use of \reg (L1 hit)

.macro RPUSH
    str  x19, [x23, #-8]!
.endm

.macro RPOP
    ldr  x19, [x23], #8
.endm

// Preserve AAPCS64 callee-saved regs — Forth uses x19–x24 as VM state.
.macro SAVE_C_CALLEE
    stp  x29, x30, [sp, #-96]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    stp  x25, x26, [sp, #64]
    stp  x27, x28, [sp, #80]
.endm

.macro RESTORE_C_CALLEE
    ldp  x27, x28, [sp, #80]
    ldp  x25, x26, [sp, #64]
    ldp  x23, x24, [sp, #48]
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #96
.endm

.macro BOOT_WORD name, help, imm, code
    .pushsection __DATA,__bootword,regular
    .quad .Lname_\@, .Lhelp_\@, \imm, \code
    .popsection
    .pushsection __TEXT,__cstring,cstring_literals
.Lname_\@:  .asciz "\name"
.Lhelp_\@:  .asciz "\help"
    .popsection
.endm

// ============================================================================
// Data
// ============================================================================
.section __DATA,__data
.align 3
data_stack:     .skip DSTACK_SIZE
return_stack:   .skip RSTACK_SIZE
user_dict:      .skip 1024*1024
input_buffer:   .skip 2048
name_buf:       .skip 256

.align 3
here_ptr:       .quad user_dict
latest_var:     .quad 0
state_var:      .quad 0
base_var:       .quad 10
last_cfa:       .quad 0
source_addr:    .quad 0
source_len:     .quad 0
to_in:          .quad 0
word_addr:      .quad 0
cfa_lit:        .quad 0
cfa_exit:       .quad 0
cfa_comma:      .quad 0
cfa_does_rt:    .quad 0
cfa_slit:       .quad 0
cfa_branch:     .quad 0
cfa_0branch:    .quad 0
cfa_paren_inline: .quad 0
quit_ready:     .quad 0
interp_lr:      .quad 0
in_interpret:   .quad 0          // 1 while _interpret_run is active
embed_mode:     .quad 0          // 1 = GUI/host eval (QUIT/ABORT return to C, no readline)
embed_c_sp:     .quad 0          // C SP after SAVE_C_CALLEE in kernel_eval (abort unwind)
file_o1:        .quad 0
file_o2:        .quad 0
inline_var:         .quad 0      // 0 = threaded :,  -1 = native/inline :
compiling_native:   .quad 0
inline_region:      .quad 0      // -1 = mid-colon [INLINE]...[THREAD] fragment
dcolon_flag:        .quad 0      // -1 = ;/ABORT should restore INLINE? from dcolon_saved
dcolon_saved:       .quad 0      // INLINE? value saved by D:
emit_hook:          .quad 0      // void (*)(int c)
emit_buf_hook:      .quad 0      // void (*)(const char *buf, size_t n)
vm_dsp:             .quad 0      // saved DSP across C returns (embed host)
vm_rsp:             .quad 0      // saved RSP across C returns
code_here:      .quad 0          // next free byte in the JIT buffer

.align 3
restart_cfa:    .quad XRESTART
restart_cell:   .quad restart_cfa
// Trampoline IP for returning from ITC word called from JIT (_native_exec_xt).
native_ret_xt:  .quad XNATIVE_RET
native_ret_ip:  .quad native_ret_xt

.section __DATA,__bootword,regular
.align 3
boot_word_table:

// ============================================================================
// 16 inner CODE primitives
// ============================================================================
.text
.align 4

BOOT_WORD "EXIT", "EXIT ( -- ) return from colon definition", 0, XEXIT
XEXIT:
    RPOP
    NEXT

BOOT_WORD "LIT", "LIT ( -- n ) push inline literal", 0, XLIT
XLIT:
    ldr  x0, [x19], #8
    DPUSH x0
    NEXT

BOOT_WORD "BRANCH", "BRANCH ( -- ) jump to absolute dest", 0, XBRANCH
XBRANCH:
    ldr  x19, [x19]
    NEXT

BOOT_WORD "0BRANCH", "0BRANCH ( f -- ) jump if TOS false", 0, X0BRANCH
X0BRANCH:
    DPOP x0
    cbz  x0, 1f
    add  x19, x19, #8
    NEXT
1:  ldr  x19, [x19]
    NEXT

BOOT_WORD "EXECUTE", "EXECUTE ( xt -- ) run xt", 0, XEXECUTE
XEXECUTE:
    DPOP x0
    mov  x21, x0
    ldr  x1, [x21]
    br   x1

BOOT_WORD "@", "@ ( a -- n )", FL_INLINE, XFETCH
XFETCH:
    ldr  x0, [x22]
    ldr  x0, [x0]
    str  x0, [x22]
XFETCH_END:
    NEXT

BOOT_WORD "!", "! ( n a -- )", FL_INLINE, XSTORE
XSTORE:
    DPOP x1                     // a
    DPOP x0                     // n
    str  x0, [x1]
XSTORE_END:
    NEXT

BOOT_WORD "+", "+ ( n1 n2 -- n3 )", FL_INLINE, XPLUS
XPLUS:
    DPOP x0                     // n2
    ldr  x1, [x22]              // n1
    add  x1, x1, x0
    str  x1, [x22]
XPLUS_END:
    NEXT

BOOT_WORD "-", "- ( n1 n2 -- n3 )", FL_INLINE, XMINUS
XMINUS:
    DPOP x0                     // n2
    ldr  x1, [x22]              // n1
    sub  x1, x1, x0
    str  x1, [x22]
XMINUS_END:
    NEXT

BOOT_WORD "*", "* ( n1 n2 -- n3 )", FL_INLINE, XMUL
XMUL:
    DPOP x0
    ldr  x1, [x22]
    mul  x1, x1, x0
    str  x1, [x22]
XMUL_END:
    NEXT

BOOT_WORD "/", "/ ( n1 n2 -- n3 )", FL_INLINE, XDIV
XDIV:
    DPOP x0
    ldr  x1, [x22]
    sdiv x1, x1, x0
    str  x1, [x22]
XDIV_END:
    NEXT

BOOT_WORD "DUP", "DUP ( n -- n n )", FL_INLINE, XDUP
XDUP:
    ldr  x0, [x22]
    DPUSH x0
XDUP_END:
    NEXT

BOOT_WORD "DROP", "DROP ( n -- )", FL_INLINE, XDROP
XDROP:
    DPOP x0
XDROP_END:
    NEXT

BOOT_WORD "SWAP", "SWAP ( n1 n2 -- n2 n1 )", FL_INLINE, XSWAP
XSWAP:
    ldr  x0, [x22]
    ldr  x1, [x22, #8]
    str  x1, [x22]
    str  x0, [x22, #8]
XSWAP_END:
    NEXT

BOOT_WORD "OVER", "OVER ( n1 n2 -- n1 n2 n1 )", FL_INLINE, XOVER
XOVER:
    ldr  x0, [x22, #8]
    DPUSH x0
XOVER_END:
    NEXT

BOOT_WORD "EMIT", "EMIT ( c -- )", 0, XEMIT
XEMIT:
    DPOP x0
    stp  x19, x21, [sp, #-32]!
    stp  x22, x23, [sp, #16]
    bl   _putchar
    ldp  x22, x23, [sp, #16]
    ldp  x19, x21, [sp], #32
    NEXT

BOOT_WORD "ABORT", "ABORT ( i*x -- ) empty stacks, then QUIT", 0, XABORT
XABORT:
    b    _abort

BOOT_WORD "QUIT", "QUIT ( -- ) empty return stack, interpret; embed returns to host", 0, XQUIT
XQUIT:
    b    _do_quit

// ============================================================================
// Bootstrap compiler / dictionary words
// ============================================================================

BOOT_WORD "HERE", "HERE ( -- addr ) next dictionary byte", 0, XHERE
XHERE:
    adrp x0, here_ptr@page
    add  x0, x0, here_ptr@pageoff
    ldr  x0, [x0]
    DPUSH x0
    NEXT

BOOT_WORD ",", ", ( n -- ) compile cell", 0, XCOMMA
XCOMMA:
    DPOP x0
    bl   _compile_cell
    NEXT

BOOT_WORD "ALLOT", "ALLOT ( n -- ) advance HERE", 0, XALLOT
XALLOT:
    DPOP x0
    adrp x1, here_ptr@page
    add  x1, x1, here_ptr@pageoff
    ldr  x2, [x1]
    add  x2, x2, x0
    str  x2, [x1]
    NEXT

BOOT_WORD "STATE", "STATE ( -- addr ) compile-state variable", 0, XSTATE
XSTATE:
    adrp x0, state_var@page
    add  x0, x0, state_var@pageoff
    DPUSH x0
    NEXT

BOOT_WORD "LATEST", "LATEST ( -- addr ) latest CFA variable", 0, XLATEST
XLATEST:
    adrp x0, latest_var@page
    add  x0, x0, latest_var@pageoff
    DPUSH x0
    NEXT

BOOT_WORD "IMMEDIATE", "IMMEDIATE ( -- ) mark latest immediate", 0, XIMMEDIATE
XIMMEDIATE:
    adrp x0, latest_var@page
    add  x0, x0, latest_var@pageoff
    ldr  x0, [x0]
    ldr  x1, [x0, #-8]
    mov  x2, #1
    lsl  x2, x2, #63
    orr  x1, x1, x2
    str  x1, [x0, #-8]
    NEXT

BOOT_WORD ":", ": ( \"name\" -- ) start colon definition", 0, XCOLON
XCOLON:
    mov  x20, #0                     // not I:
    b    _colon_common

BOOT_WORD "I:", "I: ( \"name\" -- ) colon marked INLINE (macro)", 0, XICOLON
XICOLON:
    mov  x20, #1                     // set FL_INLINE on header
    b    _colon_common

// D: — define with INLINE temporarily off (threaded/debuggable), restore on ; / ABORT.
BOOT_WORD "D:", "D: ( \"name\" -- ) colon with INLINE off until ;", 0, XDCOLON
XDCOLON:
    adrp x0, dcolon_flag@page
    add  x0, x0, dcolon_flag@pageoff
    ldr  x1, [x0]
    cbnz x1, 1f                      // already in D: — just start colon
    adrp x1, inline_var@page
    add  x1, x1, inline_var@pageoff
    ldr  x2, [x1]
    adrp x3, dcolon_saved@page
    add  x3, x3, dcolon_saved@pageoff
    str  x2, [x3]
    str  xzr, [x1]                   // INLINE-OFF for this definition
    mov  x2, #-1
    str  x2, [x0]                    // pending restore
1:  mov  x20, #0                     // not I: (plain DOCOL, SEE-friendly)
    b    _colon_common

_colon_common:
    bl   _word
    cbz  x0, _colon_fail
    bl   _counted_to_cstr
    adrp x1, empty_help@page
    add  x1, x1, empty_help@pageoff
    mov  x2, xzr
    cbz  x20, 1f
    mov  x2, #FL_INLINE              // I: → FFA inline bit (macro)
1:  adrp x3, DOCOL@page
    add  x3, x3, DOCOL@pageoff
    bl   _header_build

    adrp x0, inline_var@page
    add  x0, x0, inline_var@pageoff
    ldr  x0, [x0]
    cbz  x0, 1f

    // native colon: CFA points at JIT buffer, not user_dict
    adrp x1, last_cfa@page
    add  x1, x1, last_cfa@pageoff
    ldr  x1, [x1]                    // address of CFA cell
    adrp x2, code_here@page
    add  x2, x2, code_here@pageoff
    ldr  x3, [x2]                    // next free JIT byte
    cbz  x3, _die                    // mmap failed
    str  x3, [x1]                    // [CFA] = JIT code address

    adrp x0, native_pro@page
    add  x0, x0, native_pro@pageoff
    adrp x1, native_pro_end@page
    add  x1, x1, native_pro_end@pageoff
    sub  x1, x1, x0
    bl   _emit_bytes                 // copies prologue at code_here

    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    mov  x1, #-1
    str  x1, [x0]
    adrp x0, inline_region@page
    add  x0, x0, inline_region@pageoff
    str  xzr, [x0]                  // whole-word native, not a region
    b    2f

1:  adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    str  xzr, [x0]
    adrp x0, inline_region@page
    add  x0, x0, inline_region@pageoff
    str  xzr, [x0]

2:  adrp x0, state_var@page
    add  x0, x0, state_var@pageoff
    mov  x1, #-1
    str  x1, [x0]
    NEXT

BOOT_WORD ";", "; ( -- ) end colon definition", FL_IMM, XSEMI
XSEMI:
    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    ldr  x1, [x0]
    str  xzr, [x0]
    cbz  x1, 1f
    adrp x0, native_epi@page
    add  x0, x0, native_epi@pageoff
    adrp x1, native_epi_end@page
    add  x1, x1, native_epi_end@pageoff
    sub  x1, x1, x0
    bl   _emit_bytes
    // Mid-colon region: also compile EXIT into the threaded wrapper.
    adrp x0, inline_region@page
    add  x0, x0, inline_region@pageoff
    ldr  x1, [x0]
    str  xzr, [x0]
    cbnz x1, 1f
    b    2f
1:  // compile EXIT xt
    adrp x0, cfa_exit@page
    add  x0, x0, cfa_exit@pageoff
    ldr  x0, [x0]
    bl   _compile_cell

2:  // STATE = 0
    adrp x0, state_var@page
    add  x0, x0, state_var@pageoff
    str  xzr, [x0]
    // D: restore previous INLINE?
    adrp x0, dcolon_flag@page
    add  x0, x0, dcolon_flag@pageoff
    ldr  x1, [x0]
    cbz  x1, 3f
    str  xzr, [x0]
    adrp x0, dcolon_saved@page
    add  x0, x0, dcolon_saved@pageoff
    ldr  x1, [x0]
    adrp x0, inline_var@page
    add  x0, x0, inline_var@pageoff
    str  x1, [x0]
3:  NEXT

// INLINE? lives in asm; expose it:
// add CODE words or:
// If you only have the asm variable, add:

BOOT_WORD "INLINE?", "INLINE? ( -- addr )", 0, XINLINEQ
XINLINEQ:
    adrp x0, inline_var@page
    add  x0, x0, inline_var@pageoff
    DPUSH x0
    NEXT

BOOT_WORD "IF", "IF ( f -- )", FL_IMM, XIF
XIF:
    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    ldr  x0, [x0]
    cbz  x0, 1f
    // native: DPOP x0 ; cbz x0, hole
    movz x0, #0x86C0
    movk x0, #0xF840, lsl #16       // ldr x0,[x22],#8
    bl   _emit_u32
    adrp x1, code_here@page
    add  x1, x1, code_here@pageoff
    ldr  x0, [x1]                   // addr of forthcoming cbz
    movz x2, #0x0000
    movk x2, #0xB400, lsl #16       // cbz x0, .+0
    stp  x0, xzr, [sp, #-16]!
    mov  x0, x2
    bl   _emit_u32
    ldr  x0, [sp], #16
    DPUSH x0                        // orig for THEN
    NEXT
1:  // threaded
    adrp x0, cfa_0branch@page
    add  x0, x0, cfa_0branch@pageoff
    ldr  x0, [x0]
    bl   _compile_cell
    adrp x1, here_ptr@page
    add  x1, x1, here_ptr@pageoff
    ldr  x0, [x1]
    DPUSH x0
    mov  x0, #0
    bl   _compile_cell
    NEXT

BOOT_WORD "THEN", "THEN ( addr -- )", FL_IMM, XTHEN
XTHEN:
    DPOP x1                         // hole
    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    ldr  x0, [x0]
    cbz  x0, 1f
    adrp x0, code_here@page
    add  x0, x0, code_here@pageoff
    ldr  x0, [x0]
    bl   _patch_rel
    NEXT
1:  adrp x0, here_ptr@page
    add  x0, x0, here_ptr@pageoff
    ldr  x0, [x0]
    str  x0, [x1]
    NEXT

BOOT_WORD "ELSE", "ELSE ( addr -- addr )", FL_IMM, XELSE
XELSE:
    adrp x3, compiling_native@page
    add  x3, x3, compiling_native@pageoff
    ldr  x3, [x3]
    cbz  x3, 1f

    // ---- native ----
    adrp x2, code_here@page
    add  x2, x2, code_here@pageoff
    ldr  x0, [x2]
    DPUSH x0                        // &B before emit
    movz x0, #0x0000
    movk x0, #0x1400, lsl #16       // b .+0
    bl   _emit_u32
    DPOP x4                         // &B
    DPOP x1                         // IF’s cbz
    str  x4, [sp, #-16]!
    adrp x0, code_here@page
    add  x0, x0, code_here@pageoff
    ldr  x0, [x0]                   // dest = after B
    bl   _patch_rel
    ldr  x0, [sp], #16
    DPUSH x0                        // &B for THEN
    NEXT

1:  // ---- threaded ----
    adrp x0, cfa_branch@page
    add  x0, x0, cfa_branch@pageoff
    ldr  x0, [x0]
    bl   _compile_cell
    adrp x1, here_ptr@page
    add  x1, x1, here_ptr@pageoff
    ldr  x0, [x1]
    DPUSH x0                        // new hole
    mov  x0, #0
    bl   _compile_cell
    DPOP x0                         // new
    DPOP x1                         // old IF hole
    adrp x2, here_ptr@page
    add  x2, x2, here_ptr@pageoff
    ldr  x2, [x2]
    str  x2, [x1]                   // patch IF dest
    DPUSH x0                        // leave ELSE hole for THEN
    NEXT
    
BOOT_WORD "BEGIN", "BEGIN ( -- addr )", FL_IMM, XBEGIN
XBEGIN:
    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    ldr  x0, [x0]
    cbz  x0, 1f
    adrp x0, code_here@page
    add  x0, x0, code_here@pageoff
    ldr  x0, [x0]
    DPUSH x0
    NEXT
1:  adrp x0, here_ptr@page
    add  x0, x0, here_ptr@pageoff
    ldr  x0, [x0]
    DPUSH x0
    NEXT

BOOT_WORD "AGAIN", "AGAIN ( addr -- )", FL_IMM, XAGAIN
XAGAIN:
    DPOP x1                         // dest
    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    ldr  x0, [x0]
    cbz  x0, 1f
    adrp x0, code_here@page
    add  x0, x0, code_here@pageoff
    ldr  x0, [x0]                   // addr of forthcoming B
    str  x1, [sp, #-16]!
    movz x2, #0x0000
    movk x2, #0x1400, lsl #16
    str  x0, [sp, #-16]!
    mov  x0, x2
    bl   _emit_u32
    ldr  x1, [sp], #16              // instr
    ldr  x0, [sp], #16              // dest
    bl   _patch_rel
    NEXT
1:  adrp x0, cfa_branch@page
    add  x0, x0, cfa_branch@pageoff
    ldr  x0, [x0]
    bl   _compile_cell
    DPOP x0
    bl   _compile_cell
    NEXT

BOOT_WORD "UNTIL", "UNTIL ( addr -- )", FL_IMM, XUNTIL
XUNTIL:
    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    ldr  x0, [x0]
    cbz  x0, 1f

    movz x0, #0x86C0
    movk x0, #0xF840, lsl #16       // ldr x0, [x22], #8
    bl   _emit_u32

    adrp x2, code_here@page
    add  x2, x2, code_here@pageoff
    ldr  x0, [x2]                   // x0 = &cbz (not yet emitted)
    DPOP x1                         // x1 = BEGIN dest
    stp  x0, x1, [sp, #-16]!        // save &cbz, dest

    movz x0, #0x0000
    movk x0, #0xB400, lsl #16       // cbz x0, .+0
    bl   _emit_u32

    ldp  x1, x0, [sp], #16          // x1 = &cbz, x0 = dest
    bl   _patch_rel
    NEXT

1:  adrp x0, cfa_0branch@page
    add  x0, x0, cfa_0branch@pageoff
    ldr  x0, [x0]
    bl   _compile_cell
    DPOP x0
    bl   _compile_cell
    NEXT

BOOT_WORD "WHILE", "WHILE ( orig -- orig hole ) leave if false", FL_IMM, XWHILE
XWHILE:
    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    ldr  x0, [x0]
    cbz  x0, 1f
    // native: same as IF, then SWAP with BEGIN dest → (hole dest)
    movz x0, #0x86C0
    movk x0, #0xF840, lsl #16       // ldr x0,[x22],#8
    bl   _emit_u32
    adrp x1, code_here@page
    add  x1, x1, code_here@pageoff
    ldr  x0, [x1]                   // &cbz
    movz x2, #0x0000
    movk x2, #0xB400, lsl #16       // cbz x0, .+0
    stp  x0, xzr, [sp, #-16]!
    mov  x0, x2
    bl   _emit_u32
    ldr  x0, [sp], #16              // hole
    DPUSH x0
    ldr  x0, [x22]
    ldr  x1, [x22, #8]
    str  x1, [x22]
    str  x0, [x22, #8]
    NEXT
1:  // threaded: IF then SWAP
    adrp x0, cfa_0branch@page
    add  x0, x0, cfa_0branch@pageoff
    ldr  x0, [x0]
    bl   _compile_cell
    adrp x1, here_ptr@page
    add  x1, x1, here_ptr@pageoff
    ldr  x0, [x1]
    DPUSH x0
    mov  x0, #0
    bl   _compile_cell
    ldr  x0, [x22]
    ldr  x1, [x22, #8]
    str  x1, [x22]
    str  x0, [x22, #8]
    NEXT

BOOT_WORD "REPEAT", "REPEAT ( hole dest -- )", FL_IMM, XREPEAT
XREPEAT:
    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    ldr  x0, [x0]
    cbz  x0, 1f
    // native: B to BEGIN (AGAIN), then patch WHILE cbz to here (THEN)
    DPOP x1                         // dest = BEGIN
    adrp x0, code_here@page
    add  x0, x0, code_here@pageoff
    ldr  x0, [x0]                   // &B
    str  x1, [sp, #-16]!
    movz x2, #0x0000
    movk x2, #0x1400, lsl #16       // b .+0
    str  x0, [sp, #-16]!
    mov  x0, x2
    bl   _emit_u32
    ldr  x1, [sp], #16              // instr
    ldr  x0, [sp], #16              // dest
    bl   _patch_rel
    DPOP x1                         // WHILE hole
    adrp x0, code_here@page
    add  x0, x0, code_here@pageoff
    ldr  x0, [x0]
    bl   _patch_rel
    NEXT
1:  // threaded: AGAIN then THEN
    adrp x0, cfa_branch@page
    add  x0, x0, cfa_branch@pageoff
    ldr  x0, [x0]
    bl   _compile_cell
    DPOP x0
    bl   _compile_cell
    DPOP x1
    adrp x0, here_ptr@page
    add  x0, x0, here_ptr@pageoff
    ldr  x0, [x0]
    str  x0, [x1]
    NEXT

BOOT_WORD "CREATE", "CREATE ( \"name\" -- ) header + DOVAR", 0, XCREATE
XCREATE:
    bl   _word
    cbz  x0, _colon_fail
    bl   _counted_to_cstr
    adrp x1, empty_help@page
    add  x1, x1, empty_help@pageoff
    mov  x2, #0
    adrp x3, DOVAR@page
    add  x3, x3, DOVAR@pageoff
    bl   _header_build
    adrp x0, here_ptr@page
    add  x0, x0, here_ptr@pageoff
    ldr  x1, [x0]
    str  xzr, [x1], #8
    str  x1, [x0]
    NEXT

BOOT_WORD "DOES>", "DOES> ( -- ) compile (DOES>)", FL_IMM, XDOES
XDOES:
    adrp x0, cfa_does_rt@page
    add  x0, x0, cfa_does_rt@pageoff
    ldr  x0, [x0]
    bl   _compile_cell
    NEXT

BOOT_WORD "(DOES>)", "(DOES>) ( -- ) patch latest with DODOES", 0, XDOES_RT
XDOES_RT:
    adrp x0, latest_var@page
    add  x0, x0, latest_var@pageoff
    ldr  x0, [x0]
    adrp x1, DODOES@page
    add  x1, x1, DODOES@pageoff
    str  x1, [x0]
    str  x19, [x0, #8]
    RPOP
    NEXT

BOOT_WORD "POSTPONE", "POSTPONE ( \"name\" -- ) ANS postpone", FL_IMM, XPOSTPONE
XPOSTPONE:
    bl   _word
    cbz  x0, _undef_current
    bl   _find
    cbz  x0, _undef_current
    str  x0, [sp, #-16]!
    cmp  x1, #1
    b.eq 1f
    adrp x0, cfa_lit@page
    add  x0, x0, cfa_lit@pageoff
    ldr  x0, [x0]
    bl   _compile_cell
    ldr  x0, [sp]
    bl   _compile_cell
    adrp x0, cfa_comma@page
    add  x0, x0, cfa_comma@pageoff
    ldr  x0, [x0]
    bl   _compile_cell
    add  sp, sp, #16
    NEXT
1:  ldr  x0, [sp], #16
    bl   _compile_cell
    NEXT

BOOT_WORD "'", "' ( \"name\" -- xt )", 0, XTICK
XTICK:
    bl   _word
    cbz  x0, _undef_current
    bl   _find
    cbz  x0, _undef_current
    DPUSH x0
    NEXT

BOOT_WORD "\\", "\\ ( -- ) line comment", FL_IMM, XBS
XBS:
    adrp x1, source_addr@page
    add  x1, x1, source_addr@pageoff
    ldr  x1, [x1]
    adrp x2, source_len@page
    add  x2, x2, source_len@pageoff
    ldr  x2, [x2]
    adrp x3, to_in@page
    add  x3, x3, to_in@pageoff
    ldr  x4, [x3]
1:  cmp  x4, x2
    b.hs 2f
    ldrb w5, [x1, x4]
    add  x4, x4, #1
    cmp  w5, #10
    b.ne 1b
2:  str  x4, [x3]
    NEXT

BOOT_WORD "(", "( -- ) parenthesis comment", FL_IMM, XPAREN
XPAREN:
    adrp x1, source_addr@page
    add  x1, x1, source_addr@pageoff
    ldr  x1, [x1]
    adrp x2, source_len@page
    add  x2, x2, source_len@pageoff
    ldr  x2, [x2]
    adrp x3, to_in@page
    add  x3, x3, to_in@pageoff
    ldr  x4, [x3]
1:  cmp  x4, x2
    b.hs 2f
    ldrb w5, [x1, x4]
    add  x4, x4, #1
    cmp  w5, #')'
    b.ne 1b
2:  str  x4, [x3]
    NEXT

BOOT_WORD "C@", "C@ ( a -- c )", FL_INLINE, XCFETCH
XCFETCH:
    ldr  x0, [x22]
    ldrb w0, [x0]
    str  x0, [x22]
XCFETCH_END:
    NEXT

BOOT_WORD "C!", "C! ( c a -- )", FL_INLINE, XCSTORE
XCSTORE:
    DPOP x1                     // a
    DPOP x0                     // c
    strb w0, [x1]
XCSTORE_END:
    NEXT

BOOT_WORD "AND", "AND ( n1 n2 -- n3 )", FL_INLINE, XAND
XAND:
    DPOP x0
    ldr  x1, [x22]
    and  x1, x1, x0
    str  x1, [x22]
XAND_END:
    NEXT

BOOT_WORD "OR", "OR ( n1 n2 -- n3 )", FL_INLINE, XORR
XORR:
    DPOP x0
    ldr  x1, [x22]
    orr  x1, x1, x0
    str  x1, [x22]
XORR_END:
    NEXT

BOOT_WORD "XOR", "XOR ( n1 n2 -- n3 )", FL_INLINE, XXOR
XXOR:
    DPOP x0
    ldr  x1, [x22]
    eor  x1, x1, x0
    str  x1, [x22]
XXOR_END:
    NEXT

BOOT_WORD "INVERT", "INVERT ( n -- n' )", FL_INLINE, XINVERT
XINVERT:
    ldr  x0, [x22]
    mvn  x0, x0
    str  x0, [x22]
XINVERT_END:
    NEXT

BOOT_WORD "0=", "0= ( n -- f )", FL_INLINE, XZEQ
XZEQ:
    ldr  x0, [x22]
    cmp  x0, #0
    csetm x0, eq
    str  x0, [x22]
XZEQ_END:
    NEXT

BOOT_WORD "0<", "0< ( n -- f )", FL_INLINE, XZLT
XZLT:
    ldr  x0, [x22]
    cmp  x0, #0
    csetm x0, lt
    str  x0, [x22]
XZLT_END:
    NEXT

BOOT_WORD "<", "< ( n1 n2 -- f )", FL_INLINE, XLT
XLT:
    DPOP x0                     // n2
    ldr  x1, [x22]              // n1
    cmp  x1, x0
    csetm x1, lt
    str  x1, [x22]
XLT_END:
    NEXT

BOOT_WORD ">R", ">R ( n -- )", FL_INLINE, XTOR
XTOR:
    DPOP x0
    str  x0, [x23, #-8]!
XTOR_END:
    NEXT

BOOT_WORD "R>", "R> ( -- n )", FL_INLINE, XRFROM
XRFROM:
    ldr  x0, [x23], #8
    DPUSH x0
XRFROM_END:
    NEXT

BOOT_WORD "R@", "R@ ( -- n )", FL_INLINE, XRAT
XRAT:
    ldr  x0, [x23]
    DPUSH x0
XRAT_END:
    NEXT

BOOT_WORD "DEPTH", "DEPTH ( -- n )", 0, XDEPTH
XDEPTH:
    adrp x0, data_stack@page
    add  x0, x0, data_stack@pageoff
    add  x0, x0, #DSTACK_SIZE
    sub  x0, x0, x22
    lsr  x0, x0, #3
    DPUSH x0
    NEXT

BOOT_WORD "WORD", "WORD ( char -- c-addr ) counted token at HERE", 0, XWORD
XWORD:
    DPOP x0                     // drop delimiter
    bl   _word
    DPUSH x0
    NEXT

BOOT_WORD "(S\")", "(S\") ( -- c-addr u ) runtime for S\"", 0, XSLIT
XSLIT:
    ldr  x0, [x19], #8          // u
    mov  x1, x19                // c-addr
    add  x19, x19, x0
    add  x19, x19, #7
    and  x19, x19, #-8
    DPUSH x1
    DPUSH x0
    NEXT

BOOT_WORD "S\"", "S\" ( -- c-addr u ) parse quoted string", FL_IMM, XSQUOTE
XSQUOTE:
    bl   _parse_quote           // x0=addr, x1=len
    adrp x2, state_var@page
    add  x2, x2, state_var@pageoff
    ldr  x2, [x2]
    cbnz x2, 1f
    DPUSH x0
    DPUSH x1
    NEXT
1:  stp  x0, x1, [sp, #-16]!
    adrp x0, cfa_slit@page
    add  x0, x0, cfa_slit@pageoff
    ldr  x0, [x0]
    bl   _compile_cell
    ldr  x0, [sp, #8]
    bl   _compile_cell
    ldp  x0, x1, [sp], #16
    adrp x2, here_ptr@page
    add  x2, x2, here_ptr@pageoff
    ldr  x3, [x2]
    cbz  x1, 3f
2:  ldrb w4, [x0], #1
    strb w4, [x3], #1
    subs x1, x1, #1
    b.ne 2b
3:  add  x3, x3, #7
    and  x3, x3, #-8
    str  x3, [x2]
    NEXT

// (INLINE) — threaded runtime for a mid-colon native fragment.
// Body layout: (INLINE) xt, abs-addr of JIT fragment (no native_pro; we RPUSH).
BOOT_WORD "(INLINE)", "(INLINE) ( -- ) run following native fragment", 0, XPARENINLINE
XPARENINLINE:
    ldr  x0, [x19], #8
    RPUSH
    br   x0

BOOT_WORD "[INLINE]", "[INLINE] ( -- ) native compile", FL_IMM, XBRACKETINLINE
XBRACKETINLINE:
    adrp x0, state_var@page
    add  x0, x0, state_var@pageoff
    ldr  x0, [x0]
    cbz  x0, 1f
    // Compiling: start a native fragment inside a threaded colon.
    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    ldr  x0, [x0]
    cbnz x0, 2f                     // already native — no-op
    adrp x0, cfa_paren_inline@page
    add  x0, x0, cfa_paren_inline@pageoff
    ldr  x0, [x0]
    bl   _compile_cell
    adrp x1, code_here@page
    add  x1, x1, code_here@pageoff
    ldr  x0, [x1]
    cbz  x0, _die
    bl   _compile_cell              // absolute JIT entry address
    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    mov  x1, #-1
    str  x1, [x0]
    adrp x0, inline_region@page
    add  x0, x0, inline_region@pageoff
    str  x1, [x0]
    NEXT
1:  // Interpret: next : is a whole-word native colon.
    adrp x0, inline_var@page
    add  x0, x0, inline_var@pageoff
    mov  x1, #-1
    str  x1, [x0]
    NEXT
2:  NEXT

BOOT_WORD "[THREAD]", "[THREAD] ( -- ) threaded compile", FL_IMM, XBRACKETTHREAD
XBRACKETTHREAD:
    adrp x0, state_var@page
    add  x0, x0, state_var@pageoff
    ldr  x0, [x0]
    cbz  x0, 1f
    // Compiling: close mid-colon native fragment.
    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    ldr  x1, [x0]
    cbz  x1, 2f
    adrp x2, inline_region@page
    add  x2, x2, inline_region@pageoff
    ldr  x3, [x2]
    cbz  x3, 2f                     // whole-word native: ignore mid-body [THREAD]
    str  xzr, [x0]                  // compiling_native = 0
    str  xzr, [x2]                  // inline_region = 0
    adrp x0, native_epi@page
    add  x0, x0, native_epi@pageoff
    adrp x1, native_epi_end@page
    add  x1, x1, native_epi_end@pageoff
    sub  x1, x1, x0
    bl   _emit_bytes
    NEXT
1:  // Interpret: next : is threaded.
    adrp x0, inline_var@page
    add  x0, x0, inline_var@pageoff
    str  xzr, [x0]
    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    str  xzr, [x0]
    adrp x0, inline_region@page
    add  x0, x0, inline_region@pageoff
    str  xzr, [x0]
    NEXT
2:  NEXT

BOOT_WORD "BYE", "BYE ( -- ) exit process", 0, XBYE
XBYE:
    mov  x0, #0
    mov  x16, #1
    svc  #0x80

_colon_fail:
    adrp x1, str_colon_fail@page
    add  x1, x1, str_colon_fail@pageoff
    mov  x2, #16
    bl   _sys_write
    b    _die

// ----------------------------------------------------------------------------
// File-Access
// ----------------------------------------------------------------------------

BOOT_WORD "FILE-O1", "FILE-O1 ( -- n )", 0, XFO1
XFO1:
    adrp x0, file_o1@page
    add  x0, x0, file_o1@pageoff
    ldr  x0, [x0]
    DPUSH x0
    NEXT

BOOT_WORD "FILE-O2", "FILE-O2 ( -- n )", 0, XFO2
XFO2:
    adrp x0, file_o2@page
    add  x0, x0, file_o2@pageoff
    ldr  x0, [x0]
    DPUSH x0
    NEXT

BOOT_WORD "(CREATE-FILE)", "(CREATE-FILE) ( fam ptr -- fileid ior )", 0, XCREATEFILE2
XCREATEFILE2:
    DPOP x4                     // ptr
    DPOP x1                     // fam
    mov  x0, #2
    mov  x2, #0
    mov  x3, #0

    adrp x5, file_o1@page
    add  x5, x5, file_o1@pageoff
    adrp x6, file_o2@page
    add  x6, x6, file_o2@pageoff

    stp  x29, x30, [sp, #-16]!
    bl   _host_file_op
    ldp  x29, x30, [sp], #16

    mov  x1, x0                 // ior
    adrp x0, file_o1@page
    add  x0, x0, file_o1@pageoff
    ldr  x0, [x0]
    DPUSH x0                    // fileid
    DPUSH x1                    // ior
    NEXT

BOOT_WORD "(OPEN-FILE)", "(OPEN-FILE) ( fam ptr -- fileid ior )", 0, XOPENFILE
XOPENFILE:
    DPOP x4                     // ptr
    DPOP x1                     // fam
    mov  x0, #1
    mov  x2, #0
    mov  x3, #0

    adrp x5, file_o1@page
    add  x5, x5, file_o1@pageoff
    adrp x6, file_o2@page
    add  x6, x6, file_o2@pageoff

    stp  x29, x30, [sp, #-16]!
    bl   _host_file_op
    ldp  x29, x30, [sp], #16

    mov  x1, x0
    adrp x0, file_o1@page
    add  x0, x0, file_o1@pageoff
    ldr  x0, [x0]
    DPUSH x0
    DPUSH x1
    NEXT

BOOT_WORD "(CLOSE-FILE)", "(CLOSE-FILE) ( fileid -- ior )", 0, XCLOSEFILE
XCLOSEFILE:
    DPOP x1                     // fileid
    mov  x0, #3
    mov  x2, #0
    mov  x3, #0
    mov  x4, #0

    adrp x5, file_o1@page
    add  x5, x5, file_o1@pageoff
    adrp x6, file_o2@page
    add  x6, x6, file_o2@pageoff

    stp  x29, x30, [sp, #-16]!
    bl   _host_file_op
    ldp  x29, x30, [sp], #16

    DPUSH x0
    NEXT

BOOT_WORD "(READ-FILE)", "(READ-FILE) ( c-addr u fileid -- u2 ior )", 0, XREADFILE
XREADFILE:
    DPOP x1                     // fileid
    DPOP x2                     // u
    DPOP x4                     // c-addr
    mov  x0, #4
    mov  x3, #0

    adrp x5, file_o1@page
    add  x5, x5, file_o1@pageoff
    adrp x6, file_o2@page
    add  x6, x6, file_o2@pageoff

    stp  x29, x30, [sp, #-16]!
    bl   _host_file_op
    ldp  x29, x30, [sp], #16

    mov  x1, x0
    adrp x0, file_o1@page
    add  x0, x0, file_o1@pageoff
    ldr  x0, [x0]
    DPUSH x0                    // u2
    DPUSH x1                    // ior
    NEXT

BOOT_WORD "(WRITE-FILE)", "(WRITE-FILE) ( c-addr u fileid -- ior )", 0, XWRITEFILE
XWRITEFILE:
    DPOP x1                     // fileid
    DPOP x2                     // u
    DPOP x4                     // c-addr
    mov  x0, #5
    mov  x3, #0

    adrp x5, file_o1@page
    add  x5, x5, file_o1@pageoff
    adrp x6, file_o2@page
    add  x6, x6, file_o2@pageoff

    stp  x29, x30, [sp, #-16]!
    bl   _host_file_op
    ldp  x29, x30, [sp], #16

    DPUSH x0
    NEXT

BOOT_WORD "(READ-LINE)", "(READ-LINE) ( c-addr u1 fileid -- u2 flag ior )", 0, XREADLINE
XREADLINE:
    DPOP x1                     // fileid
    DPOP x2                     // u1
    DPOP x4                     // c-addr
    mov  x0, #6
    mov  x3, #0

    adrp x5, file_o1@page
    add  x5, x5, file_o1@pageoff
    adrp x6, file_o2@page
    add  x6, x6, file_o2@pageoff

    stp  x29, x30, [sp, #-16]!
    bl   _host_file_op
    ldp  x29, x30, [sp], #16

    mov  x3, x0                 // ior
    adrp x0, file_o1@page
    add  x0, x0, file_o1@pageoff
    ldr  x0, [x0]
    DPUSH x0                    // u2
    adrp x0, file_o2@page
    add  x0, x0, file_o2@pageoff
    ldr  x0, [x0]
    DPUSH x0                    // flag
    DPUSH x3                    // ior
    NEXT

BOOT_WORD "(WRITE-LINE)", "(WRITE-LINE) ( c-addr u fileid -- ior )", 0, XWRITELINE
XWRITELINE:
    DPOP x1                     // fileid
    DPOP x2                     // u
    DPOP x4                     // c-addr
    mov  x0, #7
    mov  x3, #0

    adrp x5, file_o1@page
    add  x5, x5, file_o1@pageoff
    adrp x6, file_o2@page
    add  x6, x6, file_o2@pageoff

    stp  x29, x30, [sp, #-16]!
    bl   _host_file_op
    ldp  x29, x30, [sp], #16

    DPUSH x0
    NEXT

BOOT_WORD "(REPOSITION-FILE)", "(REPOSITION-FILE) ( lo hi fileid -- ior )", 0, XREPOSFILE
XREPOSFILE:
    DPOP x1                     // fileid → a
    DPOP x3                     // hi    → c (ignored by C for now)
    DPOP x2                     // lo    → b
    mov  x0, #10                // op = FOP_REPOSITION
    mov  x4, #0                 // ptr unused

    adrp x5, file_o1@page
    add  x5, x5, file_o1@pageoff
    adrp x6, file_o2@page
    add  x6, x6, file_o2@pageoff

    stp  x29, x30, [sp, #-16]!
    bl   _host_file_op
    ldp  x29, x30, [sp], #16

    DPUSH x0                    // ior
    NEXT

BOOT_WORD "(FILE-SIZE)", "(FILE-SIZE) ( fileid -- ud ior )", 0, XFILESIZE
XFILESIZE:
    DPOP x1                     // a = fileid
    mov  x0, #8                 // FOP_FILE_SIZE
    mov  x2, #0
    mov  x3, #0
    mov  x4, #0

    adrp x5, file_o1@page
    add  x5, x5, file_o1@pageoff
    adrp x6, file_o2@page
    add  x6, x6, file_o2@pageoff

    stp  x29, x30, [sp, #-16]!
    bl   _host_file_op
    ldp  x29, x30, [sp], #16

    mov  x3, x0                 // ior
    adrp x0, file_o1@page
    add  x0, x0, file_o1@pageoff
    ldr  x0, [x0]
    DPUSH x0                    // size lo (or full size in o1)
    adrp x0, file_o2@page
    add  x0, x0, file_o2@pageoff
    ldr  x0, [x0]
    DPUSH x0                    // size hi (0 if unused)
    DPUSH x3                    // ior
    NEXT

BOOT_WORD "(FILE-POSITION)", "(FILE-POSITION) ( fileid -- ud ior )", 0, XFILEPOS
XFILEPOS:
    DPOP x1                     // a = fileid
    mov  x0, #9                 // FOP_FILE_POS
    mov  x2, #0
    mov  x3, #0
    mov  x4, #0

    adrp x5, file_o1@page
    add  x5, x5, file_o1@pageoff
    adrp x6, file_o2@page
    add  x6, x6, file_o2@pageoff

    stp  x29, x30, [sp, #-16]!
    bl   _host_file_op
    ldp  x29, x30, [sp], #16

    mov  x3, x0
    adrp x0, file_o1@page
    add  x0, x0, file_o1@pageoff
    ldr  x0, [x0]
    DPUSH x0                    // pos lo
    adrp x0, file_o2@page
    add  x0, x0, file_o2@pageoff
    ldr  x0, [x0]
    DPUSH x0                    // pos hi
    DPUSH x3                    // ior
    NEXT

BOOT_WORD "(DELETE-FILE)", "(DELETE-FILE) ( c-addr -- ior )", 0, XDELETEFILE
XDELETEFILE:
    DPOP x4                     // ptr = NUL-terminated name
    mov  x0, #11                // FOP_DELETE
    mov  x1, #0
    mov  x2, #0
    mov  x3, #0

    adrp x5, file_o1@page
    add  x5, x5, file_o1@pageoff
    adrp x6, file_o2@page
    add  x6, x6, file_o2@pageoff

    stp  x29, x30, [sp, #-16]!
    bl   _host_file_op
    ldp  x29, x30, [sp], #16

    DPUSH x0                    // ior
    NEXT

BOOT_WORD "PICK", "PICK ( xu ... x0 u -- xu ... x0 xu )", 0, XPICK
XPICK:
    DPOP x0                     // u
    lsl  x0, x0, #3             // byte offset
    ldr  x0, [x22, x0]          // load xu
    DPUSH x0
    NEXT

.section __DATA,__bootword,regular
.quad 0, 0, 0, 0

// After all primitives are defined:
.section __DATA,__data
.align 3
inline_len_tab:
    .quad XDUP,   XDUP_END
    .quad XDROP,  XDROP_END
    .quad XSWAP,  XSWAP_END
    .quad XOVER,  XOVER_END
    .quad XPLUS,  XPLUS_END
    .quad XMINUS, XMINUS_END
    .quad XMUL,   XMUL_END
    .quad XDIV,   XDIV_END
    .quad XFETCH, XFETCH_END
    .quad XSTORE, XSTORE_END
    .quad XCFETCH,XCFETCH_END
    .quad XCSTORE,XCSTORE_END
    .quad XAND,   XAND_END
    .quad XORR,   XORR_END
    .quad XXOR,   XXOR_END
    .quad XINVERT,XINVERT_END
    .quad XZEQ,   XZEQ_END
    .quad XZLT,   XZLT_END
    .quad XLT,    XLT_END
    .quad XTOR,   XTOR_END
    .quad XRFROM, XRFROM_END
    .quad XRAT,   XRAT_END
    .quad 0, 0

// ============================================================================
// Inner interpreter runtimes
// ============================================================================
.text
.align 4

DOCOL:
    RPUSH
    add  x19, x21, #8
    NEXT

DOVAR:
    add  x0, x21, #16
    DPUSH x0
    NEXT

DODOES:
    RPUSH
    ldr  x19, [x21, #8]
    add  x0, x21, #16
    DPUSH x0
    NEXT

XRESTART:
    b    _interpret_loop

// ============================================================================
// Helpers
// ============================================================================

// void kernel_set_emit(void (*fn)(int c))
.globl _kernel_set_emit
_kernel_set_emit:
    adrp x1, emit_hook@page
    add  x1, x1, emit_hook@pageoff
    str  x0, [x1]
    ret

// void kernel_set_emit_buf(void (*fn)(const char *buf, size_t n))
.globl _kernel_set_emit_buf
_kernel_set_emit_buf:
    adrp x1, emit_buf_hook@page
    add  x1, x1, emit_buf_hook@pageoff
    str  x0, [x1]
    ret

// _putchar: w0 = character. Prefer emit_hook; else write(1).
_putchar:
    stp  x29, x30, [sp, #-16]!
    adrp x1, emit_hook@page
    add  x1, x1, emit_hook@pageoff
    ldr  x1, [x1]
    cbz  x1, 1f
    blr  x1
    ldp  x29, x30, [sp], #16
    ret
1:
    sub  sp, sp, #16
    strb w0, [sp]
    mov  x0, #1
    mov  x1, sp
    mov  x2, #1
    mov  x16, #4
    svc  #0x80
    add  sp, sp, #16
    ldp  x29, x30, [sp], #16
    ret

// _sys_write: x1 = buf, x2 = len. Prefer emit_buf_hook, else per-byte emit_hook, else write(1).
_sys_write:
    stp  x29, x30, [sp, #-48]!
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    mov  x19, x1                   // buf
    mov  x20, x2                   // len
    adrp x0, emit_buf_hook@page
    add  x0, x0, emit_buf_hook@pageoff
    ldr  x0, [x0]
    cbz  x0, 1f
    cbz  x20, 3f
    mov  x1, x20
    mov  x2, x0
    mov  x0, x19
    blr  x2
    b    3f
1:
    cbz  x20, 3f
0:
    adrp x0, emit_hook@page
    add  x0, x0, emit_hook@pageoff
    ldr  x0, [x0]
    cbz  x0, 2f
    ldrb w1, [x19], #1
    mov  x21, x0
    mov  w0, w1
    blr  x21
    sub  x20, x20, #1
    cbnz x20, 0b
    b    3f
2:
    cbz  x20, 3f
    mov  x0, #1
    mov  x1, x19
    mov  x2, x20
    mov  x16, #4
    svc  #0x80
3:
    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #48
    ret

// Save / restore DSP+RSP for embed hosts that return to C between evals.
_vm_save_stacks:
    adrp x0, vm_dsp@page
    add  x0, x0, vm_dsp@pageoff
    str  x22, [x0]
    adrp x0, vm_rsp@page
    add  x0, x0, vm_rsp@pageoff
    str  x23, [x0]
    ret

_vm_restore_stacks:
    adrp x0, vm_dsp@page
    add  x0, x0, vm_dsp@pageoff
    ldr  x22, [x0]
    adrp x0, vm_rsp@page
    add  x0, x0, vm_rsp@pageoff
    ldr  x23, [x0]
    // Rebuild &latest (x24) — address is stable
    adrp x24, latest_var@page
    add  x24, x24, latest_var@pageoff
    ret

_compile_cell:
    adrp x1, here_ptr@page
    add  x1, x1, here_ptr@pageoff
    ldr  x2, [x1]
    str  x0, [x2], #8
    str  x2, [x1]
    ret

_cstrlen:
    mov  x1, x0
0:  ldrb w2, [x1], #1
    cbnz w2, 0b
    sub  x0, x1, x0
    sub  x0, x0, #1
    ret

_counted_to_cstr:
    ldrb w1, [x0], #1
    adrp x2, name_buf@page
    add  x2, x2, name_buf@pageoff
    mov  x3, x2
    cbz  w1, 1f
0:  ldrb w4, [x0], #1
    strb w4, [x3], #1
    subs w1, w1, #1
    b.ne 0b
1:  strb wzr, [x3]
    mov  x0, x2
    ret

_header_build:
    stp  x29, x30, [sp, #-48]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]

    mov  x19, x0
    mov  x20, x1
    mov  x21, x2
    mov  x22, x3

    adrp x4, here_ptr@page
    add  x4, x4, here_ptr@pageoff
    ldr  x5, [x4]

    mov  x6, x5
    mov  x0, x20
    bl   _cstrlen
    mov  x1, x0
    strb w1, [x5], #1
    cbz  x1, 1f
    mov  x2, x20
0:  ldrb w3, [x2], #1
    strb w3, [x5], #1
    subs x1, x1, #1
    b.ne 0b
1:  add  x5, x5, #7
    and  x5, x5, #-8

    mov  x7, x5
    mov  x0, x19
    bl   _cstrlen
    mov  x1, x0
    strb w1, [x5], #1
    cbz  x1, 2f
    mov  x2, x19
0:  ldrb w3, [x2], #1
    cmp  w3, #'a'
    b.lo 1f
    cmp  w3, #'z'
    b.hi 1f
    sub  w3, w3, #'a' - 'A'
1:  strb w3, [x5], #1
    subs x1, x1, #1
    b.ne 0b
2:  add  x5, x5, #7
    and  x5, x5, #-8

    mov  x9, x5
    add  x5, x5, #24
    add  x10, x9, #16

    adrp x11, latest_var@page
    add  x11, x11, latest_var@pageoff
    ldr  x12, [x11]
    str  x12, [x9]

    sub  x13, x10, x7
    and  x13, x13, #0xFFFF
    sub  x14, x10, x6
    and  x14, x14, #0xFFFF
    lsl  x14, x14, #16
    orr  x13, x13, x14
    tst  x21, #FL_IMM           // testing for immediate
    b.eq _in
    orr  x13, x13, #(1 << 63)
_in: tst  x21, #FL_INLINE       // Testing for inlinable
    b.eq 3f
    orr  x13, x13, #(1 << 62)
3:  str  x13, [x9, #8]
    str  x22, [x10]

    adrp x4, here_ptr@page
    add  x4, x4, here_ptr@pageoff
    str  x5, [x4]
    str  x10, [x11]

    adrp x4, last_cfa@page
    add  x4, x4, last_cfa@pageoff
    str  x10, [x4]

    ldp  x21, x22, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #48
    ret

_set_source:
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

_word:
    adrp x1, source_addr@page
    add  x1, x1, source_addr@pageoff
    ldr  x1, [x1]
    adrp x2, source_len@page
    add  x2, x2, source_len@pageoff
    ldr  x2, [x2]
    adrp x3, to_in@page
    add  x3, x3, to_in@pageoff
    ldr  x4, [x3]

skip_ws:
    cmp  x4, x2
    b.hs end_of_source
    ldrb w5, [x1, x4]
    cmp  w5, #' '
    b.hi token_start
    add  x4, x4, #1
    b    skip_ws

token_start:
    mov  x6, x4
scan:
    cmp  x4, x2
    b.hs token_end
    ldrb w5, [x1, x4]
    cmp  w5, #' '
    b.ls token_end
    add  x4, x4, #1
    b    scan

token_end:
    sub  x7, x4, x6
    str  x4, [x3]
    adrp x8, here_ptr@page
    add  x8, x8, here_ptr@pageoff
    ldr  x9, [x8]
    strb w7, [x9]
    cbz  x7, empty_token
    add  x10, x1, x6
    add  x11, x9, #1
copy:
    ldrb w12, [x10], #1
    cmp  w12, #'a'
    b.lo 2f
    cmp  w12, #'z'
    b.hi 2f
    sub  w12, w12, #32
2:  strb w12, [x11], #1
    subs x7, x7, #1
    b.ne copy
empty_token:
    mov  x0, x9
    ret
end_of_source:
    str  x4, [x3]
    mov  x0, #0
    ret

_find:
    adrp x2, latest_var@page
    add  x2, x2, latest_var@pageoff
    ldr  x2, [x2]
1:  cbz  x2, 9f
    ldr  x3, [x2, #-8]
    and  x4, x3, #0xFFFF
    sub  x5, x2, x4
    ldrb w6, [x0]
    ldrb w7, [x5]
    cmp  w6, w7
    b.ne 2f
    add  x8, x0, #1
    add  x9, x5, #1
0:  cbz  w6, 3f
    ldrb w10, [x8], #1
    ldrb w11, [x9], #1
    cmp  w10, w11
    b.ne 2f
    sub  w6, w6, #1
    b    0b
3:  tst  x3, #(1 << 63)
    mov  x1, #-1
    b.eq 4f
    mov  x1, #1
4:  mov  x0, x2
    ret
2:  ldr  x2, [x2, #-16]
    b    1b
9:  mov  x0, #0
    mov  x1, #0
    ret

_number:
    ldrb w1, [x0]
    cbz  w1, 9f
    add  x2, x0, #1
    mov  x3, #0
    mov  x4, #1
    ldrb w5, [x2]
    cmp  w5, #'-'
    b.ne 1f
    mov  x4, #-1
    add  x2, x2, #1
    sub  w1, w1, #1
1:  cbz  w1, 9f
0:  ldrb w5, [x2], #1
    sub  w5, w5, #'0'
    cmp  w5, #9
    b.hi 9f
    mov  x6, #10
    mul  x3, x3, x6
    add  x3, x3, x5
    subs w1, w1, #1
    b.ne 0b
    mul  x0, x3, x4
    mov  x1, #1
    ret
9:  mov  x1, #0
    ret

_parse_quote:
    adrp x2, source_addr@page
    add  x2, x2, source_addr@pageoff
    ldr  x2, [x2]
    adrp x3, source_len@page
    add  x3, x3, source_len@pageoff
    ldr  x3, [x3]
    adrp x4, to_in@page
    add  x4, x4, to_in@pageoff
    ldr  x5, [x4]
    cmp  x5, x3
    b.hs 2f
    ldrb w6, [x2, x5]
    cmp  w6, #' '
    b.ne 1f
    add  x5, x5, #1
1:  mov  x0, x5
3:  cmp  x5, x3
    b.hs 4f
    ldrb w6, [x2, x5]
    cmp  w6, #'"'
    b.eq 4f
    add  x5, x5, #1
    b    3b
4:  sub  x1, x5, x0
    add  x0, x2, x0
    cmp  x5, x3
    b.hs 5f
    add  x5, x5, #1
5:  str  x5, [x4]
    ret
2:  mov  x0, x2
    mov  x1, #0
    ret

_boot_kernel:
    stp  x29, x30, [sp, #-16]!
    adrp x9, boot_word_table@page
    add  x9, x9, boot_word_table@pageoff
1:  ldr  x0, [x9]
    cbz  x0, 2f
    ldr  x1, [x9, #8]
    ldr  x2, [x9, #16]
    ldr  x3, [x9, #24]
    stp  x9, xzr, [sp, #-16]!
    bl   _header_build
    ldp  x9, xzr, [sp], #16
    add  x9, x9, #32
    b    1b
2:  ldp  x29, x30, [sp], #16
    ret

_cache_one:
    stp  x1, x30, [sp, #-16]!
    bl   _find
    ldp  x1, x30, [sp], #16
    cbz  x0, _cache_fail
    str  x0, [x1]
    ret
_cache_fail:
    adrp x1, str_cache_fail@page
    add  x1, x1, str_cache_fail@pageoff
    mov  x2, #18
    bl   _sys_write
    b    _die

_boot_cache:
    stp  x29, x30, [sp, #-16]!
    adrp x0, cnt_lit@page
    add  x0, x0, cnt_lit@pageoff
    adrp x1, cfa_lit@page
    add  x1, x1, cfa_lit@pageoff
    bl   _cache_one
    
    adrp x0, cnt_exit@page
    add  x0, x0, cnt_exit@pageoff
    adrp x1, cfa_exit@page
    add  x1, x1, cfa_exit@pageoff
    bl   _cache_one
    
    adrp x0, cnt_comma@page
    add  x0, x0, cnt_comma@pageoff
    adrp x1, cfa_comma@page
    add  x1, x1, cfa_comma@pageoff
    bl   _cache_one
    
    adrp x0, cnt_does@page
    add  x0, x0, cnt_does@pageoff
    adrp x1, cfa_does_rt@page
    add  x1, x1, cfa_does_rt@pageoff
    bl   _cache_one
    
    adrp x0, cnt_slit@page
    add  x0, x0, cnt_slit@pageoff
    adrp x1, cfa_slit@page
    add  x1, x1, cfa_slit@pageoff
    bl   _cache_one

    adrp x0, cnt_branch@page
    add  x0, x0, cnt_branch@pageoff
    adrp x1, cfa_branch@page
    add  x1, x1, cfa_branch@pageoff
    bl   _cache_one

    adrp x0, cnt_0branch@page
    add  x0, x0, cnt_0branch@pageoff
    adrp x1, cfa_0branch@page
    add  x1, x1, cfa_0branch@pageoff
    bl   _cache_one

    adrp x0, cnt_paren_inline@page
    add  x0, x0, cnt_paren_inline@pageoff
    adrp x1, cfa_paren_inline@page
    add  x1, x1, cfa_paren_inline@pageoff
    bl   _cache_one

    ldp  x29, x30, [sp], #16
    ret

// ============================================================================
// Outer interpreter
// ============================================================================
_interpret_run:
    adrp x1, interp_lr@page
    add  x1, x1, interp_lr@pageoff
    str  x30, [x1]
    adrp x1, in_interpret@page
    add  x1, x1, in_interpret@pageoff
    mov  x0, #1
    str  x0, [x1]
    b    _interpret_loop

_interpret_loop:
    bl   _check_data_stack
    cbnz x0, _abort
    bl   _word
    cbz  x0, _interpret_done
    ldrb w1, [x0]
    cbz  w1, _interpret_loop

    adrp x1, word_addr@page
    add  x1, x1, word_addr@pageoff
    str  x0, [x1]

    bl   _find
    cbz  x0, _try_num

    adrp x2, state_var@page
    add  x2, x2, state_var@pageoff
    ldr  x2, [x2]
    cbz  x2, _exec
    cmp  x1, #1
    b.eq _exec
    bl   _compile_word
    b    _interpret_loop

_exec:
    adrp x19, restart_cell@page
    add  x19, x19, restart_cell@pageoff
    mov  x21, x0
    ldr  x1, [x21]
    br   x1

_try_num:
    adrp x0, word_addr@page
    add  x0, x0, word_addr@pageoff
    ldr  x0, [x0]
    bl   _number
    cbz  x1, _undef_current
    adrp x2, state_var@page
    add  x2, x2, state_var@pageoff
    ldr  x2, [x2]
    cbnz x2, _compile_num
    DPUSH x0
    b    _interpret_loop

_compile_num:
    adrp x2, compiling_native@page
    add  x2, x2, compiling_native@pageoff
    ldr  x2, [x2]
    cbnz x2, 1f

    str  x0, [sp, #-16]!
    adrp x0, cfa_lit@page
    add  x0, x0, cfa_lit@pageoff
    ldr  x0, [x0]
    bl   _compile_cell
    ldr  x0, [sp], #16
    bl   _compile_cell
    b    _interpret_loop

1:  bl   _emit_native_lit          // x0 = value
    b    _interpret_loop
    
_undef_current:
    adrp x1, str_undef@page
    add  x1, x1, str_undef@pageoff
    mov  x2, #11
    bl   _sys_write
    adrp x0, word_addr@page
    add  x0, x0, word_addr@pageoff
    ldr  x0, [x0]
    cbz  x0, 1f
    ldrb w2, [x0]
    add  x1, x0, #1
    bl   _sys_write
1:  adrp x1, str_nl@page
    add  x1, x1, str_nl@pageoff
    mov  x2, #1
    bl   _sys_write
    b    _abort
    
_interpret_done:
    adrp x1, in_interpret@page
    add  x1, x1, in_interpret@pageoff
    str  xzr, [x1]
    adrp x1, interp_lr@page
    add  x1, x1, interp_lr@pageoff
    ldr  x30, [x1]
    ret

_die:
    mov  x0, #1
    mov  x16, #1
    svc  #0x80

// Returns: NZ = bad stack, EQ = ok.  Does not change x22 unless you want reset in abort.
_check_data_stack:
    adrp x0, data_stack@page
    add  x0, x0, data_stack@pageoff          // base
    mov  x1, x0
    add  x1, x1, #DSTACK_SIZE               // empty
    cmp  x22, x1
    b.hi _stack_underflow                   // x22 > empty
    cmp  x22, x0
    b.lo _stack_overflow                    // x22 < base
    mov  x0, #0
    ret
    
_stack_underflow:
    adrp x1, str_under@page
    add  x1, x1, str_under@pageoff
    ldr  x2, [x1], #8
    bl   _sys_write
    b    _abort

_stack_overflow:
    adrp x1, str_over@page
    add  x1, x1, str_over@pageoff
    ldr  x2, [x1], #8
    bl   _sys_write
    b    _abort

// ABORT: empty data + return stacks, leave compile state, then QUIT.
_abort:
    // If we were compiling, unlink the incomplete definition (LFA @ CFA-16).
    adrp x0, state_var@page
    add  x0, x0, state_var@pageoff
    ldr  x1, [x0]
    cbz  x1, 1f
    adrp x2, latest_var@page
    add  x2, x2, latest_var@pageoff
    ldr  x3, [x2]
    cbz  x3, 1f
    ldr  x3, [x3, #-16]
    str  x3, [x2]
1:  str  xzr, [x0]                  // STATE = 0
    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    str  xzr, [x0]
    adrp x0, inline_region@page
    add  x0, x0, inline_region@pageoff
    str  xzr, [x0]
    // If D: was open, restore prior INLINE?; else leave INLINE? alone.
    adrp x0, dcolon_flag@page
    add  x0, x0, dcolon_flag@pageoff
    ldr  x1, [x0]
    cbz  x1, 2f
    str  xzr, [x0]
    adrp x0, dcolon_saved@page
    add  x0, x0, dcolon_saved@pageoff
    ldr  x1, [x0]
    adrp x0, inline_var@page
    add  x0, x0, inline_var@pageoff
    str  x1, [x0]
2:  adrp x22, data_stack@page
    add  x22, x22, data_stack@pageoff
    add  x22, x22, #DSTACK_SIZE
    adrp x23, return_stack@page
    add  x23, x23, return_stack@pageoff
    add  x23, x23, #RSTACK_SIZE
    b    _do_quit

// QUIT: empty return stack, interpret state. ANS does not empty the data stack.
// Like 64Forth: under embed_mode return to the host; else enter the CLI loop.
// Does not clear INLINE? — user INLINE-ON survives errors / QUIT.
_do_quit:
    adrp x0, state_var@page
    add  x0, x0, state_var@pageoff
    str  xzr, [x0]
    adrp x0, compiling_native@page
    add  x0, x0, compiling_native@pageoff
    str  xzr, [x0]
    adrp x0, inline_region@page
    add  x0, x0, inline_region@pageoff
    str  xzr, [x0]
    adrp x0, dcolon_flag@page
    add  x0, x0, dcolon_flag@pageoff
    ldr  x1, [x0]
    cbz  x1, 1f
    str  xzr, [x0]
    adrp x0, dcolon_saved@page
    add  x0, x0, dcolon_saved@pageoff
    ldr  x1, [x0]
    adrp x0, inline_var@page
    add  x0, x0, inline_var@pageoff
    str  x1, [x0]
1:
    adrp x23, return_stack@page
    add  x23, x23, return_stack@pageoff
    add  x23, x23, #RSTACK_SIZE

    adrp x0, embed_mode@page
    add  x0, x0, embed_mode@pageoff
    ldr  x0, [x0]
    cbnz x0, _embed_quit_return

    adrp x0, quit_ready@page
    add  x0, x0, quit_ready@pageoff
    ldr  x0, [x0]
    cbz  x0, _die
    b    _quit_loop

// GUI/host: finish this kernel_eval without unbalanced-C-stack ret via interp_lr.
// Abort often happens deep in bl helpers; restoring embed_c_sp matches 64Forth.
_embed_quit_return:
    adrp x0, in_interpret@page
    add  x0, x0, in_interpret@pageoff
    str  xzr, [x0]
    bl   _vm_save_stacks
    mov  x0, #0
    // fall through

// Restore the SAVE_C_CALLEE frame saved in embed_c_sp and return x0 to host.
_embed_ret_x0:
    adrp x1, embed_c_sp@page
    add  x1, x1, embed_c_sp@pageoff
    ldr  x1, [x1]
    cbz  x1, _die
    mov  sp, x1
    RESTORE_C_CALLEE
    ret

// ============================================================================
// helpers for inlineable
// ============================================================================
// x0 = code address → x1 = length, or 0 if not inlineable
_inline_len:
    adrp x2, inline_len_tab@page
    add  x2, x2, inline_len_tab@pageoff
1:  ldr  x3, [x2], #16
    cbz  x3, 2f
    cmp  x3, x0
    b.ne 1b
    ldr  x1, [x2, #-8]           // end label
    sub  x1, x1, x0
    ret
2:  mov  x1, #0
    ret

// copy x1 bytes from x0 to HERE, 4-align HERE
_emit_bytes:                       // x0=src, x1=len
    stp  x0, x1, [sp, #-32]!
    stp  x29, x30, [sp, #16]
    bl   _forth_code_begin_write
    ldp  x0, x1, [sp]
    adrp x2, code_here@page
    add  x2, x2, code_here@pageoff
    ldr  x3, [x2]
    cbz  x3, 3f
    cbz  x1, 2f
1:  ldrb w4, [x0], #1
    strb w4, [x3], #1
    subs x1, x1, #1
    b.ne 1b
2:  add  x3, x3, #3
    and  x3, x3, #-4
    str  x3, [x2]
3:  bl   _forth_code_end_write
    ldp  x29, x30, [sp, #16]
    add  sp, sp, #32
    ret

// w0 = instruction
// already have _emit_u32

// x0 = dest addr, x1 = instr addr  → patch B or CBZ at x1 to dest
_patch_rel:
    stp  x29, x30, [sp, #-32]!
    stp  x19, x20, [sp, #16]
    mov  x19, x0                    // dest
    mov  x20, x1                    // instr
    bl   _forth_code_begin_write
    sub  x0, x19, x20
    asr  x0, x0, #2                 // imm in words
    ldr  w1, [x20]
    // CBZ: top 8 bits 0xB4 ; B: top 6 bits 0x14
    lsr  w2, w1, #24
    cmp  w2, #0xB4
    b.eq 1f
    // B imm26
    and  x0, x0, #0x03FFFFFF
    and  w1, w1, #0xFC000000
    orr  w1, w1, w0
    b    2f
1:  // CBZ imm19 at bits 23-5
    and  x0, x0, #0x7FFFF
    mov  w2, w1
    and  w2, w2, #0xFF00001F
    orr  w1, w2, w0, lsl #5
2:  str  w1, [x20]
    bl   _forth_code_end_write
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret

// w0 = one A64 instruction → append to code_here
_emit_u32:
    stp  x29, x30, [sp, #-16]!
    str  w0, [sp, #-16]!
    mov  x0, sp
    mov  x1, #4
    bl   _emit_bytes
    add  sp, sp, #16
    ldp  x29, x30, [sp], #16
    ret

// x0 = 64-bit literal
// emits:
//   movz x0, #b0
//   movk x0, #b1, lsl #16
//   movk x0, #b2, lsl #32
//   movk x0, #b3, lsl #48
//   str  x0, [x22, #-8]!
_emit_native_lit:
    stp  x29, x30, [sp, #-32]!
    str  x19, [sp, #16]
    mov  x19, x0                    // keep value

    mov  x0, x19
    and  x0, x0, #0xFFFF
    movz x1, #0x0000
    movk x1, #0xD280, lsl #16       // MOVZ x0, #imm
    orr  x0, x1, x0, lsl #5
    bl   _emit_u32

    lsr  x0, x19, #16
    and  x0, x0, #0xFFFF
    movz x1, #0x0000
    movk x1, #0xF280, lsl #16       // MOVK x0, #imm
    orr  x0, x1, x0, lsl #5
    orr  x0, x0, #(1 << 21)         // hw = 1 → lsl #16
    bl   _emit_u32

    lsr  x0, x19, #32
    and  x0, x0, #0xFFFF
    movz x1, #0x0000
    movk x1, #0xF280, lsl #16       // MOVK x0, #imm
    orr  x0, x1, x0, lsl #5
    orr  x0, x0, #(2 << 21)         // lsl #32
    bl   _emit_u32

    lsr  x0, x19, #48
    and  x0, x0, #0xFFFF
    movz x1, #0x0000
    movk x1, #0xF280, lsl #16       // MOVK x0, #imm
    orr  x0, x1, x0, lsl #5
    orr  x0, x0, #(3 << 21)         // lsl #48
    bl   _emit_u32

    movz x0, #0x8EC0
    movk x0, #0xF81F, lsl #16     // 0xF81F0EC0 = str x0, [x22, #-8]!
    bl   _emit_u32
    
    ldr  x19, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret

// ============================================================================
// xt in x0.
// Native: INLINE CODE → paste body; INLINE colon (I:) → macro-expand;
//         else emit a call back into the ITC engine.
// Threaded: INLINE colon → macro-expand; else ,
// ============================================================================
_compile_word:                   // x0 = xt
    stp  x29, x30, [sp, #-32]!
    stp  x19, x20, [sp, #16]
    mov  x19, x0                 // save xt
    adrp x1, compiling_native@page
    add  x1, x1, compiling_native@pageoff
    ldr  x1, [x1]
    cbz  x1, 20f                 // threaded

    // ---- native ----
    ldr  x2, [x19, #-8]
    tbz  x2, #62, 15f            // no INLINE bit → call
    ldr  x0, [x19]
    bl   _inline_len             // CODE leaf?
    cbz  x1, 12f
    ldr  x0, [x19]
    bl   _emit_bytes
    b    30f
12: // INLINE colon (I:)? macro-expand if DOCOL
    ldr  x0, [x19]
    adrp x1, DOCOL@page
    add  x1, x1, DOCOL@pageoff
    cmp  x0, x1
    b.ne 15f
    mov  x0, x19
    bl   _macro_expand_colon
    b    30f
15: mov  x0, x19
    bl   _emit_native_call
    b    30f

20: // ---- threaded ----
    ldr  x2, [x19, #-8]
    tbz  x2, #62, 25f
    ldr  x0, [x19]
    adrp x1, DOCOL@page
    add  x1, x1, DOCOL@pageoff
    cmp  x0, x1
    b.ne 25f
    mov  x0, x19
    bl   _macro_expand_colon
    b    30f
25: mov  x0, x19
    bl   _compile_cell
30: ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret

// Expand I:/INLINE colon body (xt in x0). LIT cells are re-compiled as literals.
_macro_expand_colon:
    stp  x29, x30, [sp, #-32]!
    stp  x19, x20, [sp, #16]
    add  x20, x0, #8                 // body pointer
1:  ldr  x19, [x20], #8              // next xt
    adrp x0, cfa_exit@page
    add  x0, x0, cfa_exit@pageoff
    ldr  x0, [x0]
    cmp  x19, x0
    b.eq 9f
    adrp x0, cfa_lit@page
    add  x0, x0, cfa_lit@pageoff
    ldr  x0, [x0]
    cmp  x19, x0
    b.eq 2f
    mov  x0, x19
    bl   _compile_word
    b    1b
2:  ldr  x0, [x20], #8               // literal value
    adrp x1, compiling_native@page
    add  x1, x1, compiling_native@pageoff
    ldr  x1, [x1]
    cbz  x1, 3f
    bl   _emit_native_lit
    b    1b
3:  str  x0, [sp, #-16]!
    adrp x0, cfa_lit@page
    add  x0, x0, cfa_lit@pageoff
    ldr  x0, [x0]
    bl   _compile_cell
    ldr  x0, [sp], #16
    bl   _compile_cell
    b    1b
9:  ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret

// Emit movz/movk sequence loading imm64 in x0 into register rd (x1 = rd 0..31)
_emit_load64_rd:                     // x0=imm, x1=rd
    stp  x29, x30, [sp, #-48]!
    stp  x19, x20, [sp, #16]
    str  x21, [sp, #32]
    mov  x19, x0
    mov  x20, x1                     // rd
    // movz rd, #b0
    and  x0, x19, #0xFFFF
    movz x2, #0x0000
    movk x2, #0xD280, lsl #16
    orr  x0, x2, x0, lsl #5
    orr  x0, x0, x20
    bl   _emit_u32
    // movk rd, #b1, lsl #16
    lsr  x0, x19, #16
    and  x0, x0, #0xFFFF
    movz x2, #0x0000
    movk x2, #0xF280, lsl #16
    orr  x0, x2, x0, lsl #5
    orr  x0, x0, #(1 << 21)
    orr  x0, x0, x20
    bl   _emit_u32
    lsr  x0, x19, #32
    and  x0, x0, #0xFFFF
    movz x2, #0x0000
    movk x2, #0xF280, lsl #16
    orr  x0, x2, x0, lsl #5
    orr  x0, x0, #(2 << 21)
    orr  x0, x0, x20
    bl   _emit_u32
    lsr  x0, x19, #48
    and  x0, x0, #0xFFFF
    movz x2, #0x0000
    movk x2, #0xF280, lsl #16
    orr  x0, x2, x0, lsl #5
    orr  x0, x0, #(3 << 21)
    orr  x0, x0, x20
    bl   _emit_u32
    ldr  x21, [sp, #32]
    ldp  x19, x20, [sp, #16]
    ldp  x29, x30, [sp], #48
    ret

// JIT: load xt into x0, &_native_exec_xt into x16, blr x16
_emit_native_call:                   // x0 = xt
    stp  x29, x30, [sp, #-32]!
    str  x19, [sp, #16]
    mov  x19, x0
    mov  x1, #0                      // rd = x0
    bl   _emit_load64_rd
    adrp x0, _native_exec_xt@page
    add  x0, x0, _native_exec_xt@pageoff
    mov  x1, #16                     // rd = x16
    bl   _emit_load64_rd
    movz x0, #0x0200
    movk x0, #0xD63F, lsl #16        // blr x16
    bl   _emit_u32
    ldr  x19, [sp, #16]
    ldp  x29, x30, [sp], #32
    ret

// Enter ITC word xt (x0) from JIT; return to LR in JIT after word completes.
.globl _native_exec_xt
_native_exec_xt:
    str  x30, [x23, #-8]!            // RPUSH JIT resume
    adrp x19, native_ret_ip@page
    add  x19, x19, native_ret_ip@pageoff
    mov  x21, x0
    ldr  x1, [x21]
    br   x1

XNATIVE_RET:
    ldr  x0, [x23], #8               // RPOP JIT resume
    br   x0

// ============================================================================
// Native colon prologue/epilogue
// ============================================================================
.text
.align 4

native_pro:
    str  x19, [x23, #-8]!        // RPUSH IP
native_pro_end:

native_epi:
    ldr  x19, [x23], #8          // RPOP
    ldr  x21, [x19], #8          // NEXT
    ldr  x1,  [x21]
    br   x1
native_epi_end:

// C: host_jit.c
.globl _code_buf
.globl _forth_code_begin_write
.globl _forth_code_end_write

// ============================================================================
// Cold start, eval API, REPL
// ============================================================================
.globl _kernel_cold_start
_kernel_cold_start:
    SAVE_C_CALLEE
    adrp x22, data_stack@page
    add  x22, x22, data_stack@pageoff
    add  x22, x22, #DSTACK_SIZE
    adrp x23, return_stack@page
    add  x23, x23, return_stack@pageoff
    add  x23, x23, #RSTACK_SIZE

    adrp x0, _code_buf@page
    add  x0, x0, _code_buf@pageoff
    ldr  x0, [x0]                // mmap base
    adrp x1, code_here@page
    add  x1, x1, code_here@pageoff
    str  x0, [x1]
    
    adrp x24, latest_var@page
    add  x24, x24, latest_var@pageoff
    str  xzr, [x24]

    adrp x0, here_ptr@page
    add  x0, x0, here_ptr@pageoff
    adrp x1, user_dict@page
    add  x1, x1, user_dict@pageoff
    str  x1, [x0]

    adrp x0, state_var@page
    add  x0, x0, state_var@pageoff
    str  xzr, [x0]

    bl   _boot_kernel
    bl   _boot_cache

    adrp x0, forth_source@page
    add  x0, x0, forth_source@pageoff
    adrp x1, forth_source_end@page
    add  x1, x1, forth_source_end@pageoff
    sub  x1, x1, x0
    bl   _set_source
    bl   _interpret_run

    adrp x0, quit_ready@page
    add  x0, x0, quit_ready@pageoff
    mov  x1, #1
    str  x1, [x0]
    bl   _vm_save_stacks
    RESTORE_C_CALLEE
    ret

.globl _kernel_eval
_kernel_eval:
    SAVE_C_CALLEE
    // Abort/QUIT may jump here with a deep C stack; remember this frame.
    mov  x2, sp
    adrp x3, embed_c_sp@page
    add  x3, x3, embed_c_sp@pageoff
    str  x2, [x3]
    // x0=line, x1=n — stash across restore
    stp  x0, x1, [sp, #-16]!
    // Like 64Forth: mark embed so QUIT/ABORT return here, not into readline.
    adrp x0, embed_mode@page
    add  x0, x0, embed_mode@pageoff
    mov  x1, #1
    str  x1, [x0]
    bl   _vm_restore_stacks
    ldp  x0, x1, [sp], #16
    bl   _set_source
    bl   _interpret_run
    bl   _vm_save_stacks
    mov  x0, #0
    RESTORE_C_CALLEE
    ret

.globl _kernel_data_depth
_kernel_data_depth:
    adrp x0, data_stack@page
    add  x0, x0, data_stack@pageoff
    add  x0, x0, #DSTACK_SIZE          // empty
    adrp x1, vm_dsp@page
    add  x1, x1, vm_dsp@pageoff
    ldr  x1, [x1]
    cbz  x1, 1f
    sub  x0, x0, x1
    lsr  x0, x0, #3
    ret
1:
    mov  x0, #0
    ret

// CLI entry (clang / 16ForthCLI). The .app uses Swift @main + kernel_eval.
.globl _main
_main:
    stp  x29, x30, [sp, #-16]!
    bl   _forth_io_init
    bl   _kernel_cold_start
    // TTY REPL: QUIT/ABORT must enter readline, not embed return.
    adrp x0, embed_mode@page
    add  x0, x0, embed_mode@pageoff
    str  xzr, [x0]
    b    _quit_loop

_quit_loop:
    bl   _vm_restore_stacks
    bl   _check_data_stack
    cbnz x0, _abort
    adrp x0, input_buffer@page
    add  x0, x0, input_buffer@pageoff
    mov  x1, #2047
    bl   _forth_readline
    cmp  x0, #0
    b.le _exit0
    mov  x1, x0
    adrp x0, input_buffer@page
    add  x0, x0, input_buffer@pageoff
    bl   _set_source
    bl   _interpret_run
    bl   _vm_save_stacks
    b    _quit_loop

_exit0:
    mov  x0, #0
    mov  x16, #1
    svc  #0x80

// ============================================================================
// Strings + embedded Forth
// ============================================================================
.section __TEXT,__const
.align 3
forth_source:
    .incbin "16ForthCLI/kernel.fth"
    .incbin "16ForthCLI/ansfile.fth"
forth_source_end:

.section __TEXT,__const
.align 3
banner:
    .ascii "16Forth ready\n"
.equ banner_len, . - banner

.align 3
empty_help:
    .byte 0

.align 3
str_undef:
    .ascii "undefined: "
.align 3
str_nl:
    .ascii "\n"
.align 3
str_ok:
    .ascii " ok\n"
.align 3
str_colon_fail:
    .ascii " : missing name\n"
.align 3
str_cache_fail:
    .ascii "boot cache fail\n"
.align 3
str_under:
    .quad 17
    .ascii " stack underflow\n"
.align 3
str_over:
    .quad 16
    .ascii " stack overflow\n"
.align 3
str_noinline:
    .quad 17
    .ascii " cannot inline: "
str_noinline_nl:
    .ascii "\n"

.align 3
cnt_lit:        .byte 3, 'L','I','T'
.align 3
cnt_exit:       .byte 4, 'E','X','I','T'
.align 3
cnt_comma:      .byte 1, ','
.align 3
cnt_does:       .byte 7, '(','D','O','E','S','>',')'
.align 3
cnt_slit:       .byte 4, '(','S','"',')'
.align 3
cnt_branch:     .byte 6, 'B','R','A','N','C','H'
.align 3
cnt_0branch:    .byte 7, '0','B','R','A','N','C','H'
.align 3
cnt_paren_inline: .byte 8, '(','I','N','L','I','N','E',')'
