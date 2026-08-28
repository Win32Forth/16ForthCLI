\ Extra tests run after kernel.fth via stdin
1 2 + 48 + EMIT CR
: DBL DUP + ;
7 DBL .
CR
: T 1 2 + 3 = IF 80 EMIT ELSE 70 EMIT THEN CR ;
T
BYE
