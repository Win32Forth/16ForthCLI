//
//  host_file.c
//  16ForthCLI
//
//  Created by Tom's MacBook Air on 8/25/26.
//
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

// Operation codes
enum {
    FOP_OPEN        = 1,
    FOP_CREATE      = 2,
    FOP_CLOSE       = 3,
    FOP_READ        = 4,
    FOP_WRITE       = 5,
    FOP_READ_LINE   = 6,
    FOP_WRITE_LINE  = 7,
    FOP_FILE_SIZE   = 8,
    FOP_FILE_POS    = 9,
    FOP_REPOSITION  = 10,
    FOP_DELETE      = 11
};

// fam values used by Forth
#define FAM_RO   1
#define FAM_WO   2
#define FAM_RW   3
#define FAM_BIN  0x10

/*
 * host_file_op
 *   op   = operation code
 *   a,b,c = integer arguments
 *   ptr  = pointer argument (c-addr, filename, buffer…)
 *   o1,o2 = optional output results
 *
 * Returns ior (0 = success, non-zero = error)
 */
long long host_file_op(long long op,
                       long long a, long long b, long long c,
                       void *ptr,
                       long long *o1, long long *o2)
{
    switch (op) {

    case FOP_OPEN:      // a = fam, ptr = filename (NUL-terminated)
    case FOP_CREATE: {
        // … rest of the case
        const char *mode;
        int fam = (int)a & 0x0F;
        int bin = (int)a & FAM_BIN;

        if (op == FOP_CREATE) {
            if (fam == FAM_RO) mode = bin ? "wb" : "w";
            else               mode = bin ? "w+b" : "w+";
        } else {
            if (fam == FAM_RO) mode = bin ? "rb" : "r";
            else if (fam == FAM_WO) mode = bin ? "wb" : "w";
            else               mode = bin ? "r+b" : "r+";
        }

        FILE *f = fopen((const char *)ptr, mode);
        if (!f) {
            return (long long)errno;
        }
        if (o1) *o1 = (long long)(uintptr_t)f;
        return 0;
    }

    case FOP_CLOSE: {   // a = fileid
        FILE *f = (FILE *)(uintptr_t)a;
        if (!f) return -1;
        return fclose(f) ? (long long)errno : 0;
    }

    case FOP_READ: {    // a = fileid, b = u, ptr = c-addr → o1 = u2
        FILE *f = (FILE *)(uintptr_t)a;
        if (!f) return -1;
        size_t n = fread(ptr, 1, (size_t)b, f);
        if (o1) *o1 = (long long)n;
        if (ferror(f)) return (long long)errno;
        return 0;
    }

    case FOP_WRITE: {   // a = fileid, b = u, ptr = c-addr
        FILE *f = (FILE *)(uintptr_t)a;
        if (!f) return -1;
        size_t n = fwrite(ptr, 1, (size_t)b, f);
        if (n != (size_t)b) return (long long)errno;
        return 0;
    }

    case FOP_READ_LINE: { // a = fileid, b = u1, ptr = c-addr → o1 = u2, o2 = flag
        FILE *f = (FILE *)(uintptr_t)a;
        if (!f) return -1;
        if (!fgets((char *)ptr, (int)b, f)) {
            if (o1) *o1 = 0;
            if (o2) *o2 = 0;          // flag = false
            return feof(f) ? 0 : (long long)errno;
        }
        size_t len = strlen((char *)ptr);
        if (len > 0 && ((char *)ptr)[len-1] == '\n') {
            ((char *)ptr)[--len] = 0;
            if (len > 0 && ((char *)ptr)[len-1] == '\r')
                ((char *)ptr)[--len] = 0;
        }
        if (o1) *o1 = (long long)len;
        if (o2) *o2 = -1;             // flag = true
        return 0;
    }

    case FOP_WRITE_LINE: { // a = fileid, b = u, ptr = c-addr
        FILE *f = (FILE *)(uintptr_t)a;
        if (!f) return -1;
        if (b > 0 && fwrite(ptr, 1, (size_t)b, f) != (size_t)b)
            return (long long)errno;
        if (fputc('\n', f) == EOF) return (long long)errno;
        return 0;
    }

    case FOP_FILE_SIZE: { // a = fileid → o1 = size (low), o2 = 0 (high for ud)
        FILE *f = (FILE *)(uintptr_t)a;
        if (!f) return -1;
        long cur = ftell(f);
        if (cur < 0) return (long long)errno;
        if (fseek(f, 0, SEEK_END) != 0) return (long long)errno;
        long sz = ftell(f);
        fseek(f, cur, SEEK_SET);
        if (sz < 0) return (long long)errno;
        if (o1) *o1 = (long long)sz;
        if (o2) *o2 = 0;
        return 0;
    }

    case FOP_FILE_POS: {  // a = fileid → o1 = pos
        FILE *f = (FILE *)(uintptr_t)a;
        if (!f) return -1;
        long pos = ftell(f);
        if (pos < 0) return (long long)errno;
        if (o1) *o1 = (long long)pos;
        if (o2) *o2 = 0;
        return 0;
    }

    case FOP_REPOSITION: { // a = fileid, b = ud low, c = ud high (ignored)
        FILE *f = (FILE *)(uintptr_t)a;
        if (!f) return -1;
        if (fseek(f, (long)b, SEEK_SET) != 0) return (long long)errno;
        return 0;
    }

    case FOP_DELETE: {    // ptr = filename
        return remove((const char *)ptr) ? (long long)errno : 0;
    }

    default:
        return -1;
    }
}
