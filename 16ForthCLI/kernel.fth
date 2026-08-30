\ High-level 16Forth — loaded after the 16 inner primitives and the
\ assembly bootstrap compiler (: ; CREATE DOES> , HERE POSTPONE ...).
\ This file is real Forth, not .ascii embedded in the assembler.

CREATE PAD 256 ALLOT

\ --- Stack helpers ----------------------------------------------------------
: NIP   SWAP DROP ;
: TUCK  SWAP OVER ;
: 2DUP  OVER OVER ;
: 2DROP DROP DROP ;
: ROT   >R SWAP R> SWAP ;
I: 1+    1 + ;
I: 1-    1 - ;
: NEGATE  0 SWAP - ;
: 2SWAP  ROT >R ROT R> ;

\ --- CREATE-family ----------------------------------------------------------
: CONSTANT  CREATE , DOES> @ ;
: VARIABLE  CREATE 0 , ;

0 CONSTANT FALSE
-1 CONSTANT TRUE
8 CONSTANT CELL
32 CONSTANT BL

I: CELL+ CELL + ;
I: CELLS CELL * ;

\ --- Logic (built on CODE 0= 0< < AND INVERT) -------------------------------
I: =    - 0= ;
: <>   = INVERT ;
: >    SWAP < ;
: 0<>  0= INVERT ;

\ --- Compile state ----------------------------------------------------------
: [  0 STATE !  ; IMMEDIATE
: ] -1 STATE !  ;
: LITERAL  POSTPONE LIT  ,  ; IMMEDIATE
: [']  '  POSTPONE LITERAL  ; IMMEDIATE
: RECURSE  LATEST @  ,  ; IMMEDIATE

\ --- Control structures (BRANCH / 0BRANCH store absolute dest) --------------
\ : IF    POSTPONE 0BRANCH  HERE  0 ,  ; IMMEDIATE
\ : THEN  HERE SWAP !  ; IMMEDIATE
\ : ELSE  POSTPONE BRANCH  HERE  0 ,  SWAP  POSTPONE THEN  ; IMMEDIATE

\ : BEGIN   HERE  ; IMMEDIATE
\ : UNTIL   POSTPONE 0BRANCH  ,  ; IMMEDIATE
\ : AGAIN   POSTPONE BRANCH  ,  ; IMMEDIATE
\ : WHILE   POSTPONE IF  SWAP  ; IMMEDIATE
\ : REPEAT  POSTPONE AGAIN  POSTPONE THEN  ; IMMEDIATE

: MIN  ( n1 n2 -- n3 )  2DUP < IF DROP ELSE NIP THEN ;
: MAX  ( n1 n2 -- n3 )  2DUP < IF NIP ELSE DROP THEN ;

: ABS   DUP 0< IF NEGATE THEN ;
: ?DUP  DUP IF DUP THEN ;

\ --- Arithmetic extras ------------------------------------------------------
: /MOD  ( n1 n2 -- rem quot )  2DUP / DUP >R * - R> ;
: MOD   /MOD DROP ;

\ --- I/O --------------------------------------------------------------------
: CR      10 EMIT ;
: SPACE   BL EMIT ;
: SPACES  BEGIN DUP WHILE SPACE 1 - REPEAT DROP ;
: COUNT   DUP C@ SWAP 1 + SWAP ;
: TYPE    BEGIN DUP WHILE OVER C@ EMIT SWAP 1 + SWAP 1 - REPEAT 2DROP ;
: ."      POSTPONE S"  POSTPONE TYPE  ; IMMEDIATE

\ --- Memory words
: CMOVE  ( c-addr1 c-addr2 u -- )
    BEGIN DUP WHILE
        >R  OVER C@  OVER C!  1 + SWAP 1 + SWAP  R> 1 -
    REPEAT  2DROP DROP ;
    
\ --- Number output ----------------------------------------------------------
: U.  10 /MOD DUP IF RECURSE ELSE DROP THEN  48 + EMIT ;
: (.) DUP 0< IF 45 EMIT NEGATE THEN U. ;
: .   (.) SPACE ;

: .S  ( -- )
     DEPTH ." (" DUP (.) ." ) "
     DUP  0 > IF
         BEGIN DUP WHILE
             DUP PICK . 1 -
         REPEAT
     THEN DROP CR ;

\ --- Inline enable/disable -------------------------------------------------
\ Build/kernel stays INLINE-OFF (threaded, SEE-friendly).
\ App workflow: develop with INLINE-OFF; later INLINE-ON and recompile so
\ new : words are whole-word native. Marked I:/CODE leaves paste or macro-
\ expand (nested I: ok); anything else is a native trampoline call.
\ D: (asm) saves INLINE?, forces OFF for that definition, restores on ;.
: INLINE-ON   -1 INLINE? ! ;
: INLINE-OFF   0 INLINE? ! ;

\ --- Dictionary walking -----------------------------------------------------
: >LINK  16 - ;
: >FLAGS 8 - ;
: >NAME  DUP >FLAGS @ 65535 AND - ;

: WORDS ( -- )
    0 >R
    LATEST @
    BEGIN DUP WHILE
        DUP >NAME COUNT DUP R> + >R TYPE SPACE
        R@ 60 > IF CR R> DROP 0 >R THEN
        >LINK @
    REPEAT DROP R> DROP CR ;

\ --- Smoke tests (left INLINE-OFF so the image boots debuggable) ------------
: SQUARE  DUP * ;
: TEST    5 SQUARE . CR ;

\ After load, user may:  INLINE-ON  and redefine app words for speed.
\ Or wrap a single threaded definition:  D: DEBUGGY ... ;

\ S" hi" TYPE CR
\ TEST
