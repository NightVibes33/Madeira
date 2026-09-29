#include "initial_stack.h"

#include <limits.h>
#include <string.h>

struct aux_pair {
    uint64_t type;
    uint64_t value;
};

static int is_power_of_two_u64(uint64_t x)
{
    return x && !(x & (x - 1));
}

static int add_overflow_u64(uint64_t a, uint64_t b, uint64_t *out)
{
    if (UINT64_MAX - a < b) return 1;
    *out = a + b;
    return 0;
}

static size_t bounded_strlen(const char *s)
{
    size_t n = 0;
    if (!s) return SIZE_MAX;
    while (n <= STEAMOS_LINUX_STACK_MAX_STRING && s[n]) ++n;
    return n;
}

static enum steamos_linux_stack_error copy_string_down(
    uint8_t *host_base,
    size_t *cursor,
    uint64_t guest_base,
    const char *s,
    uint64_t *out_guest_ptr)
{
    size_t len = bounded_strlen(s);
    uint64_t guest_ptr;

    if (len == SIZE_MAX || len > STEAMOS_LINUX_STACK_MAX_STRING)
        return STEAMOS_LINUX_STACK_ERR_STRING;
    ++len; /* NUL */
    if (*cursor < len) return STEAMOS_LINUX_STACK_ERR_NO_SPACE;

    *cursor -= len;
    memcpy(host_base + *cursor, s, len);
    if (add_overflow_u64(guest_base, (uint64_t)*cursor, &guest_ptr))
        return STEAMOS_LINUX_STACK_ERR_ADDRESS_OVERFLOW;
    *out_guest_ptr = guest_ptr;
    return STEAMOS_LINUX_STACK_OK;
}

enum steamos_linux_stack_error steamos_linux_build_initial_stack(
    void *host_stack_base,
    size_t stack_size,
    uint64_t guest_stack_base,
    const struct steamos_linux_initial_stack_spec *spec,
    uint64_t *out_guest_sp)
{
    uint8_t *host = (uint8_t *)host_stack_base;
    uint64_t argv_ptrs[STEAMOS_LINUX_STACK_MAX_ARGC];
    uint64_t env_ptrs[STEAMOS_LINUX_STACK_MAX_ENVC];
    struct aux_pair aux[9];
    size_t aux_count = 0, cursor = stack_size, i;
    uint64_t random_ptr = 0, stack_end, sp_guest;
    size_t vector_words, vector_bytes, sp_offset;
    uint64_t *words;
    enum steamos_linux_stack_error err;

    if (!host || !spec || !out_guest_sp || !stack_size ||
        !is_power_of_two_u64(spec->page_size))
        return STEAMOS_LINUX_STACK_ERR_ARGUMENT;
    if (spec->argc > STEAMOS_LINUX_STACK_MAX_ARGC ||
        spec->envc > STEAMOS_LINUX_STACK_MAX_ENVC)
        return STEAMOS_LINUX_STACK_ERR_LIMIT;
    if ((spec->argc && !spec->argv) || (spec->envc && !spec->envp))
        return STEAMOS_LINUX_STACK_ERR_ARGUMENT;
    if (add_overflow_u64(guest_stack_base, (uint64_t)stack_size, &stack_end))
        return STEAMOS_LINUX_STACK_ERR_ADDRESS_OVERFLOW;
    (void)stack_end;

    for (i = 0; i < spec->argc; ++i) {
        err = copy_string_down(host, &cursor, guest_stack_base,
                               spec->argv[i], &argv_ptrs[i]);
        if (err != STEAMOS_LINUX_STACK_OK) return err;
    }
    for (i = 0; i < spec->envc; ++i) {
        err = copy_string_down(host, &cursor, guest_stack_base,
                               spec->envp[i], &env_ptrs[i]);
        if (err != STEAMOS_LINUX_STACK_OK) return err;
    }

    if (spec->random_bytes) {
        if (cursor < 16) return STEAMOS_LINUX_STACK_ERR_NO_SPACE;
        cursor -= 16;
        memcpy(host + cursor, spec->random_bytes, 16);
        if (add_overflow_u64(guest_stack_base, (uint64_t)cursor, &random_ptr))
            return STEAMOS_LINUX_STACK_ERR_ADDRESS_OVERFLOW;
    }

#define ADD_AUX(kind, val) do { aux[aux_count].type = (kind); aux[aux_count].value = (val); ++aux_count; } while (0)
    if (spec->phdr) ADD_AUX(STEAMOS_LINUX_AT_PHDR, spec->phdr);
    if (spec->phent) ADD_AUX(STEAMOS_LINUX_AT_PHENT, spec->phent);
    if (spec->phnum) ADD_AUX(STEAMOS_LINUX_AT_PHNUM, spec->phnum);
    ADD_AUX(STEAMOS_LINUX_AT_PAGESZ, spec->page_size);
    if (spec->base) ADD_AUX(STEAMOS_LINUX_AT_BASE, spec->base);
    ADD_AUX(STEAMOS_LINUX_AT_ENTRY, spec->entry);
    if (random_ptr) ADD_AUX(STEAMOS_LINUX_AT_RANDOM, random_ptr);
    if (spec->argc) ADD_AUX(STEAMOS_LINUX_AT_EXECFN, argv_ptrs[0]);
    ADD_AUX(STEAMOS_LINUX_AT_NULL, 0);
#undef ADD_AUX

    vector_words = 1 + spec->argc + 1 + spec->envc + 1 + aux_count * 2;
    if (vector_words > SIZE_MAX / sizeof(uint64_t))
        return STEAMOS_LINUX_STACK_ERR_NO_SPACE;
    vector_bytes = vector_words * sizeof(uint64_t);
    if (cursor < vector_bytes) return STEAMOS_LINUX_STACK_ERR_NO_SPACE;

    sp_offset = (cursor - vector_bytes) & ~(size_t)0x0f;
    if (sp_offset > cursor || cursor - sp_offset < vector_bytes)
        return STEAMOS_LINUX_STACK_ERR_NO_SPACE;

    words = (uint64_t *)(host + sp_offset);
    *words++ = (uint64_t)spec->argc;
    for (i = 0; i < spec->argc; ++i) *words++ = argv_ptrs[i];
    *words++ = 0;
    for (i = 0; i < spec->envc; ++i) *words++ = env_ptrs[i];
    *words++ = 0;
    for (i = 0; i < aux_count; ++i) {
        *words++ = aux[i].type;
        *words++ = aux[i].value;
    }

    if (add_overflow_u64(guest_stack_base, (uint64_t)sp_offset, &sp_guest))
        return STEAMOS_LINUX_STACK_ERR_ADDRESS_OVERFLOW;
    *out_guest_sp = sp_guest;
    return STEAMOS_LINUX_STACK_OK;
}

const char *steamos_linux_stack_error_string(enum steamos_linux_stack_error error)
{
    switch (error) {
    case STEAMOS_LINUX_STACK_OK: return "ok";
    case STEAMOS_LINUX_STACK_ERR_ARGUMENT: return "invalid argument";
    case STEAMOS_LINUX_STACK_ERR_LIMIT: return "argv/envp limit exceeded";
    case STEAMOS_LINUX_STACK_ERR_STRING: return "invalid or overlong string";
    case STEAMOS_LINUX_STACK_ERR_NO_SPACE: return "guest stack mapping too small";
    case STEAMOS_LINUX_STACK_ERR_ADDRESS_OVERFLOW: return "guest stack address overflow";
    default: return "unknown initial-stack error";
    }
}
