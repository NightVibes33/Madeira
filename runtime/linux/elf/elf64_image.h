#ifndef STEAMOS_IOS_ELF64_IMAGE_H
#define STEAMOS_IOS_ELF64_IMAGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum steamos_elf64_error {
    STEAMOS_ELF64_OK = 0,
    STEAMOS_ELF64_ERR_ARGUMENT,
    STEAMOS_ELF64_ERR_TRUNCATED_HEADER,
    STEAMOS_ELF64_ERR_MAGIC,
    STEAMOS_ELF64_ERR_CLASS,
    STEAMOS_ELF64_ERR_ENDIAN,
    STEAMOS_ELF64_ERR_VERSION,
    STEAMOS_ELF64_ERR_TYPE,
    STEAMOS_ELF64_ERR_MACHINE,
    STEAMOS_ELF64_ERR_PHENTSIZE,
    STEAMOS_ELF64_ERR_PHDR_BOUNDS,
    STEAMOS_ELF64_ERR_INTERPRETER_UNSUPPORTED,
    STEAMOS_ELF64_ERR_SEGMENT_BOUNDS,
    STEAMOS_ELF64_ERR_SEGMENT_SIZE,
    STEAMOS_ELF64_ERR_ADDRESS_OVERFLOW,
    STEAMOS_ELF64_ERR_NO_LOAD_SEGMENTS,
    STEAMOS_ELF64_ERR_ENTRY_NOT_EXECUTABLE,
    STEAMOS_ELF64_ERR_TOO_MANY_SEGMENTS
};

enum {
    STEAMOS_ELF64_MAX_LOAD_SEGMENTS = 32,
    STEAMOS_ELF64_PF_X = 1,
    STEAMOS_ELF64_PF_W = 2,
    STEAMOS_ELF64_PF_R = 4
};

struct steamos_elf64_segment {
    uint64_t file_offset;
    uint64_t virtual_address;
    uint64_t file_size;
    uint64_t memory_size;
    uint64_t alignment;
    uint32_t flags;
};

struct steamos_elf64_image {
    uint64_t entry;
    uint64_t load_min;
    uint64_t load_max;
    uint64_t phdr_virtual_address;
    uint16_t phent;
    uint16_t phnum;
    uint16_t elf_type;
    uint16_t load_count;
    struct steamos_elf64_segment load[STEAMOS_ELF64_MAX_LOAD_SEGMENTS];
};

enum steamos_elf64_error steamos_elf64_parse(
    const void *bytes,
    size_t size,
    uint64_t host_page_size,
    struct steamos_elf64_image *out_image);

const char *steamos_elf64_error_string(enum steamos_elf64_error error);

#ifdef __cplusplus
}
#endif

#endif
