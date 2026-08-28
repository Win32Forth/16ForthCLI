#ifndef MINIMAL_FORTH_KERNEL_API_H
#define MINIMAL_FORTH_KERNEL_API_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void kernel_cold_start(void);
int  kernel_eval(const char *line, size_t n);
int  kernel_data_depth(void);

#ifdef __cplusplus
}
#endif
#endif

