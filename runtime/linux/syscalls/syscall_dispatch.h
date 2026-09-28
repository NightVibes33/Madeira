#ifndef STEAMOS_IOS_SYSCALL_DISPATCH_H
#define STEAMOS_IOS_SYSCALL_DISPATCH_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    STEAMOS_LINUX_SYS_WRITE = 1,
    STEAMOS_LINUX_SYS_EXIT = 60,
    STEAMOS_LINUX_SYS_EXIT_GROUP = 231,
};

enum {
    STEAMOS_LINUX_EBADF = 9,
    STEAMOS_LINUX_EINVAL = 22,
    STEAMOS_LINUX_ENOSYS = 38,
};

typedef int64_t (*steamos_linux_write_fn)(
    void *opaque, uint64_t fd, uint64_t guest_buffer, uint64_t count);
typedef void (*steamos_linux_exit_fn)(
    void *opaque, int64_t status, int is_group_exit);
typedef void (*steamos_linux_missing_fn)(
    void *opaque, uint64_t number, const uint64_t args[6]);

typedef struct steamos_linux_syscall_ops {
    steamos_linux_write_fn write;
    steamos_linux_exit_fn exit;
    steamos_linux_missing_fn missing;
} steamos_linux_syscall_ops;

int64_t steamos_linux_dispatch_syscall(
    uint64_t number,
    const uint64_t args[6],
    const steamos_linux_syscall_ops *ops,
    void *opaque);

#ifdef __cplusplus
}
#endif

#endif
