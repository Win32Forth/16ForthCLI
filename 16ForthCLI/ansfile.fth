\  ansfile.fth
\  16ForthCLI
\
\  Created by Tom's MacBook Air on 8/25/26.
\
\ ansfile.fth — ANS File-Access word set (minimal useful subset)
\ Requires the (FILE-OP) multiplexor in the kernel.

\ Family constants
1 CONSTANT R/O
2 CONSTANT W/O
3 CONSTANT R/W
16 CONSTANT BIN

\ Internal helper: call the multiplexor
\ ( op a b c ptr -- ior )
\ : (FILE-OP)  (FILE-OP) ; \no helper for now, trying to geet it to run

CREATE (FNAME) 256 ALLOT

\ Copy a Forth string to a NUL-terminated C string in (FNAME)
: >FNAME  ( c-addr u -- c-addr' )
    DUP 255 > IF DROP 255 THEN
    (FNAME) 2dup c!             \ ( c-adr u -- c-adr ) store count in (FNAME)
    1+ >R                       \ inc dest, addr on R stack
                                \ ( c-addr u )
    BEGIN DUP WHILE             \ ( c-addr u )
        OVER C@ R@ C!           \ ( c-addr u ) store first char in dest addr
        1- SWAP 1+ SWAP         \ ( c-addr+1 u-1 ) bump to next char in string
        R> 1+ >R                \ Adjust dest addr to next char
    REPEAT
    2DROP                       \ ( -- ) clean up stack
    0 R> C!                     \ NUL terminate destination string
    (FNAME) 1+ ;                \ ( -- dest addr of null term string )

\ ---- Standard words -------------------------------------------------------

\ (In practice you will expose FILE-O1/FILE-O2 as CONSTANTs or VALUEs)

\ Because the result cells are in assembly, the cleanest high-level interface is:
\ We define thin wrappers that push the results.

\ For simplicity in this first version we assume the assembly also
\ pushes the results or we add two more tiny CODE words.
\ Here is a pragmatic version that works with the multiplexor returning ior
\ and storing results in known locations.

\ ---- Practical high-level definitions (recommended) -----------------------

\ You will need two small CODE words or VALUEs that fetch FILE-O1 / FILE-O2.
\ Add these two lines in assembly (or expose them):

\ BOOT_WORD "FILE-O1", "...", 0, XFO1
\ XFO1: adrp x0, FILE-O1@page ; add x0,x0,FILE-O1@pageoff ; ldr x0,[x0] ; DPUSH ; NEXT
\ (same for FILE-O2)

\ Then the high-level words become:

\ Same pattern for OPEN-FILE
: OPEN-FILE  ( c-addr u fam -- fileid ior )
    >R >FNAME
    R> SWAP
    (OPEN-FILE) ;

: CREATE-FILE  ( c-addr u fam -- fileid ior )
    >R                  \ R: fam
    >FNAME              \ ptr
    R> SWAP             \ fam ptr
    (CREATE-FILE) ;

: CLOSE-FILE  ( fileid -- ior )
    (CLOSE-FILE) ;

: READ-FILE  ( c-addr u fileid -- u2 ior )
    (READ-FILE) ;

: WRITE-FILE  ( c-addr u fileid -- ior )
    (WRITE-FILE) ;

: READ-LINE  ( c-addr u1 fileid -- u2 flag ior )
    (READ-LINE) ;

: WRITE-LINE  ( c-addr u fileid -- ior )
    (WRITE-LINE) ;

: FILE-SIZE  ( fileid -- ud ior )
    (FILE-SIZE) ;

: FILE-POSITION  ( fileid -- ud ior )
    (FILE-POSITION) ;

: DELETE-FILE  ( c-addr u -- ior )
    >FNAME
    (DELETE-FILE) ;

: REPOSITION-FILE  ( ud fileid -- ior )
    (REPOSITION-FILE) ;
    
\ Optional convenience
: INCLUDE-FILE  ( i*x fileid -- j*x )
    \ simplistic version – read whole file into a temporary buffer later
    CLOSE-FILE DROP ;


: FILE-SMOKE  ( -- )
    S" smoke.txt" R/W CREATE-FILE
    DUP IF ." create ior=" . CR DROP EXIT THEN
    DROP
    >R
    S" line one" R@ WRITE-LINE .
    S" line two" R@ WRITE-LINE .
    R@ CLOSE-FILE .
    R> DROP

    S" smoke.txt" R/O OPEN-FILE
    DUP IF ." open ior=" . CR DROP EXIT THEN
    DROP
    >R
    PAD 80 R@ READ-LINE
    DUP IF ." read1 ior=" . CR 2DROP R> DROP EXIT THEN
    DROP
    IF PAD SWAP TYPE CR ELSE DROP THEN
    PAD 80 R@ READ-LINE
    DUP IF ." read2 ior=" . CR 2DROP R> DROP EXIT THEN
    DROP
    IF PAD SWAP TYPE CR ELSE DROP THEN
    R> CLOSE-FILE .
    .S ;

: T-SIZE  ( -- )
    S" smoke.txt" R/O OPEN-FILE
    IF ." open " . CR EXIT THEN DROP
    >R
    R@ FILE-SIZE
    IF ." size ior " . CR 2DROP
    ELSE ." size " . . CR THEN
    R> CLOSE-FILE DROP ;

: T-POS  ( -- )
    S" smoke.txt" R/O OPEN-FILE
    IF ." open " . CR EXIT THEN DROP
    >R
    R@ FILE-POSITION
    IF ." pos ior " . CR 2DROP
    ELSE ." pos " . . CR THEN
    R> CLOSE-FILE DROP ;

: T-REPOS  ( -- )
    S" smoke.txt" R/W OPEN-FILE
    IF ." open " . CR EXIT THEN DROP
    >R
    0 0 R@ REPOSITION-FILE .
    R@ FILE-POSITION
    IF ." pos ior " . CR 2DROP
    ELSE ." pos " . . CR THEN
    R> CLOSE-FILE DROP ;

: T-DELETE  ( -- )
    S" smoke.txt" DELETE-FILE .
    S" smoke.txt" R/O OPEN-FILE
    IF ." deleted ok, open ior=" . CR DROP
    ELSE ." still exists " DROP CLOSE-FILE DROP THEN ;
    

\ -----------------------------------------------------------------------------
\ End of ansfile.fth
