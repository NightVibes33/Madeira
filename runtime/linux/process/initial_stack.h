#ifndef STEAMOS_IOS_INITIAL_STACK_H
#define STEAMOS_IOS_INITIAL_STACK_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum steamos_linux_stack_error {
    STEAMOS_LINUX_STACK_OK = 0,
    STEAMOS_LINUX_STACK_ERR_ARGUMENT,
    STEAMOS_LINUX_STACK_ERR_LIMIT,
    STEAMOS_LINUX_STACK_ERR_STRING,
    STEAMOS_LINUX_STACK_ERR_NO_SPACE,
    STEAMOS_LINUX_STACK_ERR_ADDRESS_OVERFLOW,
};

enum {
    STEAMOS_LINUX_STACK_MAX_ARGC = 64,
    STEAMOS_LINUX_STACK_MAX_ENVC = 128,
    STEAMOS_LINUX_STACK_MAX_STRING = 4096,
    STEAMOS_LINUX_AT_NULL = 0,
    STEAMOS_LINUX_AT_PHDR = 3,
    STEAMOS_LINUX_AT_PHENT = 4,
    STEAMOS_LINUX_AT_PHNUM = 5,
    STEAMOS_LINUX_AT_PAGESZ = 6,
    STEAMOS_LINUX_AT_BASE = 7,
    STEAMOS_LINUX_AT_ENTRY = 9,
    STEAMOS_LINUX_AT_RANDOM = 25,
    STEAMOS_LINUX_AT_EXECFN = 31,
};

struct steamos_linux_initial_stack_spec {
    const char *const *argv;
    size_t argc;
    const char *const *envp;
    size_t envc;

    uint64_t phdr;
    uint64_t phent;
    uint64_t phnum;
    uint64_t page_size;
    uint64_t base;
    uint64_t entry;

    /* Optional 16 bytes copied to guest stack and exposed as AT_RANDOM. */
    const uint8_t *random_bytes;
};

enum steamos_linux_stack_error steamos_linux_build_initial_stack(
    void *host_stack_base,
    size_t stack_size,
    uint64_t guest_stack_base,
    const struct steamos_linux_initial_stack_spec *spec,
    uint64_t *out_guest_sp);

const char *steamos_linux_stack_error_string(enum steamos_linux_stack_error error);

#ifdef __cplusplus
}
#endif

#endif
