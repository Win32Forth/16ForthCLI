\ Headless checks for INLINE-ON / trampoline / D: restore / nested I:
ABORT

\ Nested I: macros
I: 2-  1- 1- ;
: NESTED  5 2- . CR ;
NESTED

INLINE-ON
: SQ  DUP * ;
\ SQ is whole-word native; USE-SQ calls it via trampoline; 1- style leaves expand
: USE-SQ  7 SQ . CR ;
USE-SQ

\ D: forces threaded for one def, then restores INLINE-ON
D: SLOW  3 4 + . CR ;
SLOW
INLINE? @ . CR
: STILL-ON  2 SQ . CR ;
STILL-ON

INLINE-OFF
BYE
