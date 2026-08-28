\ Minimal high-level Forth built on the 16 assembly primitives
\ Copy this file into your Xcode project as kernel.fth

\ --- Stack & memory helpers -----------------------------------------------
: NIP   SWAP DROP ;
: TUCK  SWAP OVER ;
: 2DUP  OVER OVER ;
: 2DROP DROP DROP ;
: CELL+ CELL + ;
: CELLS CELL * ;
: 1+    1 + ;
: 1-    1 - ;

\ --- Constants / variables ------------------------------------------------
0 CONSTANT FALSE
-1 CONSTANT TRUE
8 CONSTANT CELL

VARIABLE STATE
VARIABLE HERE
VARIABLE LATEST

\ --- Colon compiler -------------------------------------------------------
: :     ( "name" -- )
    CREATE ]
    DOES>  ( runtime for colon words — docol is implicit via CFA ) ;

: ;     ( -- )
    POSTPONE EXIT  [  ; IMMEDIATE

: CREATE ( "name" -- )
    \ header + DOES> stub  (implemented via the assembly header builder)
    ;

: DOES>  ( -- )
    \ classic DOES>  (needs a tiny assembly helper or pure Forth version)
    ;

\ --- Literals & compile ---------------------------------------------------
: LITERAL  ( n -- )  POSTPONE LIT  ,  ; IMMEDIATE
: [        0 STATE !  ; IMMEDIATE
: ]       -1 STATE !  ;

\ --- Control structures ---------------------------------------------------
: IF      POSTPONE 0BRANCH  HERE  0 ,  ; IMMEDIATE
: THEN    HERE  SWAP !  ; IMMEDIATE
: ELSE    POSTPONE BRANCH  HERE  0 ,  SWAP  POSTPONE THEN  ; IMMEDIATE

: BEGIN   HERE  ; IMMEDIATE
: UNTIL   POSTPONE 0BRANCH  ,  ; IMMEDIATE
: AGAIN   POSTPONE BRANCH  ,  ; IMMEDIATE
: WHILE   POSTPONE IF  SWAP  ; IMMEDIATE
: REPEAT  POSTPONE AGAIN  POSTPONE THEN  ; IMMEDIATE

\ --- I/O ------------------------------------------------------------------
: CR      10 EMIT ;
: SPACE   32 EMIT ;
: SPACES  0 ?DO SPACE LOOP ;
: TYPE    ( addr len -- )  0 ?DO  DUP C@ EMIT  1+  LOOP  DROP ;
: ."      POSTPONE S"  POSTPONE TYPE  ; IMMEDIATE

\ --- Simple number output -------------------------------------------------
: .       ( n -- )  \ very minimal
    DUP 0< IF  45 EMIT  NEGATE  THEN
    \ (convert and emit digits — left as exercise or expand later)
    DROP  SPACE ;

\ --- Dictionary listing ---------------------------------------------------
: WORDS
    LATEST @
    BEGIN  DUP  WHILE
        DUP >NAME COUNT TYPE SPACE
        >LINK @
    REPEAT  DROP CR ;

\ --- Test -----------------------------------------------------------------
: SQUARE  DUP * ;
: TEST    5 SQUARE . CR ;

\ End of minimal system — you can now keep adding pure Forth
