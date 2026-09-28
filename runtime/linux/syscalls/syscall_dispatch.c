#include "syscall_dispatch.h"

int64_t steamos_linux_dispatch_syscall(
    uint64_t number,
    const uint64_t args[6],
    const steamos_linux_syscall_ops *ops,
    void *opaque)
{
    if (!args || !ops) return -STEAMOS_LINUX_EINVAL;

    switch (number) {
    case STEAMOS_LINUX_SYS_WRITE:
        if (!ops->write) return -STEAMOS_LINUX_ENOSYS;
        return ops->write(opaque, args[0], args[1], args[2]);

    case STEAMOS_LINUX_SYS_EXIT:
        if (!ops->exit) return -STEAMOS_LINUX_ENOSYS;
        ops->exit(opaque, (int64_t)args[0], 0);
        return 0;

    case STEAMOS_LINUX_SYS_EXIT_GROUP:
        if (!ops->exit) return -STEAMOS_LINUX_ENOSYS;
        ops->exit(opaque, (int64_t)args[0], 1);
        return 0;

    default:
        if (ops->missing) ops->missing(opaque, number, args);
        return -STEAMOS_LINUX_ENOSYS;
    }
}
