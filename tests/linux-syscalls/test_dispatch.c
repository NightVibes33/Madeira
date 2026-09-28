#include "../../runtime/linux/syscalls/syscall_dispatch.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct {
    int writes;
    uint64_t fd, buffer, count;
    int exits;
    int64_t status;
    int group;
    int missing;
    uint64_t missing_number;
} state_t;

static int64_t on_write(void *opaque, uint64_t fd, uint64_t buffer, uint64_t count)
{
    state_t *s = (state_t *)opaque;
    s->writes++; s->fd = fd; s->buffer = buffer; s->count = count;
    return (int64_t)count;
}

static void on_exit(void *opaque, int64_t status, int group)
{
    state_t *s = (state_t *)opaque;
    s->exits++; s->status = status; s->group = group;
}

static void on_missing(void *opaque, uint64_t number, const uint64_t args[6])
{
    state_t *s = (state_t *)opaque;
    (void)args;
    s->missing++; s->missing_number = number;
}

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "CHECK failed: %s line %d\n", #x, __LINE__); return 1; } } while (0)

int main(void)
{
    state_t s;
    uint64_t args[6] = {1, 0x1234, 19, 0, 0, 0};
    steamos_linux_syscall_ops ops = {on_write, on_exit, on_missing};
    int64_t r;

    memset(&s, 0, sizeof(s));
    r = steamos_linux_dispatch_syscall(STEAMOS_LINUX_SYS_WRITE, args, &ops, &s);
    CHECK(r == 19 && s.writes == 1 && s.fd == 1 && s.buffer == 0x1234 && s.count == 19);

    memset(&s, 0, sizeof(s)); args[0] = 42;
    r = steamos_linux_dispatch_syscall(STEAMOS_LINUX_SYS_EXIT, args, &ops, &s);
    CHECK(r == 0 && s.exits == 1 && s.status == 42 && s.group == 0);

    memset(&s, 0, sizeof(s)); args[0] = 7;
    r = steamos_linux_dispatch_syscall(STEAMOS_LINUX_SYS_EXIT_GROUP, args, &ops, &s);
    CHECK(r == 0 && s.exits == 1 && s.status == 7 && s.group == 1);

    memset(&s, 0, sizeof(s));
    r = steamos_linux_dispatch_syscall(9999, args, &ops, &s);
    CHECK(r == -STEAMOS_LINUX_ENOSYS && s.missing == 1 && s.missing_number == 9999);

    CHECK(steamos_linux_dispatch_syscall(0, NULL, &ops, &s) == -STEAMOS_LINUX_EINVAL);
    CHECK(steamos_linux_dispatch_syscall(0, args, NULL, &s) == -STEAMOS_LINUX_EINVAL);

    puts("STEAMOS_IOS_LINUX_SYSCALL_DISPATCH_OK");
    return 0;
}
