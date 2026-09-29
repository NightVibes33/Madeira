#include "../../runtime/linux/process/initial_stack.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "CHECK failed: %s line %d\n", #x, __LINE__); return 1; } } while (0)

static const char *guest_cstr(const uint8_t *host, uint64_t guest_base, uint64_t ptr)
{
    if (ptr < guest_base || ptr >= guest_base + 4096) return NULL;
    return (const char *)(host + (size_t)(ptr - guest_base));
}

int main(void)
{
    uint8_t stack[4096] = {0};
    const uint64_t guest_base = 0x700000000000ULL;
    const char *argv[] = {"steam-runtime", "-silent"};
    const char *envp[] = {"HOME=/steam", "LANG=C"};
    uint8_t random_bytes[16];
    struct steamos_linux_initial_stack_spec spec = {0};
    uint64_t sp, *w;
    size_t i;
    int saw_pagesz = 0, saw_entry = 0, saw_random = 0, saw_execfn = 0;

    for (i = 0; i < sizeof(random_bytes); ++i) random_bytes[i] = (uint8_t)(0xa0 + i);

    spec.argv = argv;
    spec.argc = 2;
    spec.envp = envp;
    spec.envc = 2;
    spec.phdr = 0x400040;
    spec.phent = 56;
    spec.phnum = 7;
    spec.page_size = 0x4000;
    spec.base = 0x7f0000000000ULL;
    spec.entry = 0x401000;
    spec.random_bytes = random_bytes;

    CHECK(steamos_linux_build_initial_stack(stack, sizeof(stack), guest_base, &spec, &sp) == STEAMOS_LINUX_STACK_OK);
    CHECK((sp & 0xf) == 0);
    CHECK(sp >= guest_base && sp < guest_base + sizeof(stack));

    w = (uint64_t *)(stack + (size_t)(sp - guest_base));
    CHECK(*w++ == 2);
    CHECK(strcmp(guest_cstr(stack, guest_base, *w++), "steam-runtime") == 0);
    CHECK(strcmp(guest_cstr(stack, guest_base, *w++), "-silent") == 0);
    CHECK(*w++ == 0);
    CHECK(strcmp(guest_cstr(stack, guest_base, *w++), "HOME=/steam") == 0);
    CHECK(strcmp(guest_cstr(stack, guest_base, *w++), "LANG=C") == 0);
    CHECK(*w++ == 0);

    for (;;) {
        uint64_t type = *w++;
        uint64_t value = *w++;
        if (type == STEAMOS_LINUX_AT_NULL) {
            CHECK(value == 0);
            break;
        }
        if (type == STEAMOS_LINUX_AT_PAGESZ) {
            CHECK(value == 0x4000);
            saw_pagesz = 1;
        } else if (type == STEAMOS_LINUX_AT_ENTRY) {
            CHECK(value == 0x401000);
            saw_entry = 1;
        } else if (type == STEAMOS_LINUX_AT_RANDOM) {
            const uint8_t *p = stack + (size_t)(value - guest_base);
            CHECK(memcmp(p, random_bytes, 16) == 0);
            saw_random = 1;
        } else if (type == STEAMOS_LINUX_AT_EXECFN) {
            CHECK(strcmp(guest_cstr(stack, guest_base, value), "steam-runtime") == 0);
            saw_execfn = 1;
        }
    }
    CHECK(saw_pagesz && saw_entry && saw_random && saw_execfn);

    {
        struct steamos_linux_initial_stack_spec bad = spec;
        bad.page_size = 0x3000;
        CHECK(steamos_linux_build_initial_stack(stack, sizeof(stack), guest_base, &bad, &sp) ==
              STEAMOS_LINUX_STACK_ERR_ARGUMENT);
    }
    {
        struct steamos_linux_initial_stack_spec bad = spec;
        bad.argc = STEAMOS_LINUX_STACK_MAX_ARGC + 1;
        CHECK(steamos_linux_build_initial_stack(stack, sizeof(stack), guest_base, &bad, &sp) ==
              STEAMOS_LINUX_STACK_ERR_LIMIT);
    }
    CHECK(steamos_linux_build_initial_stack(stack, 32, guest_base, &spec, &sp) ==
          STEAMOS_LINUX_STACK_ERR_NO_SPACE);
    CHECK(steamos_linux_build_initial_stack(stack, sizeof(stack), UINT64_MAX - 64, &spec, &sp) ==
          STEAMOS_LINUX_STACK_ERR_ADDRESS_OVERFLOW);

    puts("STEAMOS_IOS_LINUX_INITIAL_STACK_OK");
    return 0;
}
