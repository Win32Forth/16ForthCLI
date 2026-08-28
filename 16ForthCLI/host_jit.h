//
//  host_jit.h
//  16ForthCLI
//
//  Created by Tom's MacBook Air on 8/27/26.
//
#ifndef HOST_JIT_H
#define HOST_JIT_H
#include <stddef.h>

extern void *code_buf;
extern size_t code_len;

void forth_codebuf_init(void);
void forth_code_begin_write(void);
void forth_code_end_write(void);

#endif
