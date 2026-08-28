#include <stdio.h>
#include <string.h>
#include "host_jit.h"

void forth_io_init(void)
{
    setvbuf(stdin,  NULL, _IONBF, 0);
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    forth_codebuf_init();
}

// Prompt, then one line from stdin. Returns length, or 0 on EOF.
long forth_readline(char *buf, long n)
{
    fputs(" ok\n", stdout);
    fflush(stdout);
    if (n < 2)
        return 0;
    if (fgets(buf, (int)n, stdin) == NULL)
        return 0;
    return (long)strlen(buf);
}

long long host_file_op(long long op,
                       long long a, long long b, long long c,
                       void *ptr,
                       long long *o1, long long *o2);
