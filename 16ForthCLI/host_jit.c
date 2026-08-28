//
//  host_jit.c
//  16ForthCLI
//
//  Created by Tom's MacBook Air on 8/27/26.
//
#include <pthread.h>
#include <sys/mman.h>
#include <libkern/OSCacheControl.h>
#include <stddef.h>
#include <stdio.h>

void *code_buf;
size_t code_len = 1 << 20;

void forth_codebuf_init(void)
{
    code_buf = mmap(NULL, code_len,
                    PROT_READ | PROT_WRITE | PROT_EXEC,
                    MAP_ANON | MAP_PRIVATE | MAP_JIT, -1, 0);
    if (code_buf == MAP_FAILED) {
        perror("forth_codebuf_init mmap");
        code_buf = NULL;
    }
}

void forth_code_begin_write(void)
{
    if (!code_buf)
        return;
    pthread_jit_write_protect_np(0);
}

void forth_code_end_write(void)
{
    if (!code_buf)
        return;
    pthread_jit_write_protect_np(1);
    sys_icache_invalidate(code_buf, code_len);
}

