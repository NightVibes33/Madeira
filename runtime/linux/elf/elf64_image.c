#include "elf64_image.h"

#include <limits.h>
#include <string.h>

#define EI_MAG0 0
#define EI_MAG1 1
#define EI_MAG2 2
#define EI_MAG3 3
#define EI_CLASS 4
#define EI_DATA 5
#define EI_VERSION 6
#define ELFCLASS64 2
#define ELFDATA2LSB 1
#define EV_CURRENT 1
#define ET_EXEC 2
#define ET_DYN 3
#define EM_X86_64 62
#define PT_LOAD 1
#define PT_INTERP 3

struct elf64_ehdr_wire {
    uint8_t e_ident[16];
    uint16_t e_type;
    uint16_t e_machine;
    uint32_t e_version;
    uint64_t e_entry;
    uint64_t e_phoff;
    uint64_t e_shoff;
    uint32_t e_flags;
    uint16_t e_ehsize;
    uint16_t e_phentsize;
    uint16_t e_phnum;
    uint16_t e_shentsize;
    uint16_t e_shnum;
    uint16_t e_shstrndx;
};

struct elf64_phdr_wire {
    uint32_t p_type;
    uint32_t p_flags;
    uint64_t p_offset;
    uint64_t p_vaddr;
    uint64_t p_paddr;
    uint64_t p_filesz;
    uint64_t p_memsz;
    uint64_t p_align;
};

static int add_overflow_u64(uint64_t a, uint64_t b, uint64_t *out)
{
    if (UINT64_MAX - a < b) return 1;
    *out = a + b;
    return 0;
}

static int mul_overflow_u64(uint64_t a, uint64_t b, uint64_t *out)
{
    if (a && b > UINT64_MAX / a) return 1;
    *out = a * b;
    return 0;
}

static int is_power_of_two_u64(uint64_t x)
{
    return x && !(x & (x - 1));
}

static uint64_t align_down(uint64_t value, uint64_t alignment)
{
    return value & ~(alignment - 1);
}

static int align_up_checked(uint64_t value, uint64_t alignment, uint64_t *out)
{
    uint64_t tmp;
    if (add_overflow_u64(value, alignment - 1, &tmp)) return 1;
    *out = tmp & ~(alignment - 1);
    return 0;
}

enum steamos_elf64_error steamos_elf64_parse(
    const void *bytes,
    size_t size,
    uint64_t host_page_size,
    struct steamos_elf64_image *out_image)
{
    const uint8_t *data = (const uint8_t *)bytes;
    struct elf64_ehdr_wire eh;
    uint64_t ph_bytes, ph_end;
    uint64_t min_addr = UINT64_MAX, max_addr = 0;
    int entry_is_executable = 0;
    uint16_t load_count = 0;
    uint16_t i;

    if (!data || !out_image || !is_power_of_two_u64(host_page_size))
        return STEAMOS_ELF64_ERR_ARGUMENT;
    memset(out_image, 0, sizeof(*out_image));

    if (size < sizeof(eh)) return STEAMOS_ELF64_ERR_TRUNCATED_HEADER;
    memcpy(&eh, data, sizeof(eh));

    if (eh.e_ident[EI_MAG0] != 0x7f || eh.e_ident[EI_MAG1] != 'E' ||
        eh.e_ident[EI_MAG2] != 'L' || eh.e_ident[EI_MAG3] != 'F')
        return STEAMOS_ELF64_ERR_MAGIC;
    if (eh.e_ident[EI_CLASS] != ELFCLASS64) return STEAMOS_ELF64_ERR_CLASS;
    if (eh.e_ident[EI_DATA] != ELFDATA2LSB) return STEAMOS_ELF64_ERR_ENDIAN;
    if (eh.e_ident[EI_VERSION] != EV_CURRENT || eh.e_version != EV_CURRENT)
        return STEAMOS_ELF64_ERR_VERSION;
    if (eh.e_type != ET_EXEC && eh.e_type != ET_DYN) return STEAMOS_ELF64_ERR_TYPE;
    if (eh.e_machine != EM_X86_64) return STEAMOS_ELF64_ERR_MACHINE;
    if (eh.e_phentsize != sizeof(struct elf64_phdr_wire)) return STEAMOS_ELF64_ERR_PHENTSIZE;

    if (mul_overflow_u64(eh.e_phnum, eh.e_phentsize, &ph_bytes) ||
        add_overflow_u64(eh.e_phoff, ph_bytes, &ph_end) ||
        ph_end > (uint64_t)size)
        return STEAMOS_ELF64_ERR_PHDR_BOUNDS;

    for (i = 0; i < eh.e_phnum; ++i) {
        struct elf64_phdr_wire ph;
        uint64_t ph_offset = eh.e_phoff + (uint64_t)i * eh.e_phentsize;
        uint64_t file_end, mem_end, map_end, map_start;

        memcpy(&ph, data + ph_offset, sizeof(ph));
        if (ph.p_type == PT_INTERP)
            return STEAMOS_ELF64_ERR_INTERPRETER_UNSUPPORTED;
        if (ph.p_type != PT_LOAD || !ph.p_memsz) continue;
        if (load_count == STEAMOS_ELF64_MAX_LOAD_SEGMENTS)
            return STEAMOS_ELF64_ERR_TOO_MANY_SEGMENTS;
        if (ph.p_filesz > ph.p_memsz) return STEAMOS_ELF64_ERR_SEGMENT_SIZE;
        if (add_overflow_u64(ph.p_offset, ph.p_filesz, &file_end) || file_end > (uint64_t)size)
            return STEAMOS_ELF64_ERR_SEGMENT_BOUNDS;
        if (add_overflow_u64(ph.p_vaddr, ph.p_memsz, &mem_end))
            return STEAMOS_ELF64_ERR_ADDRESS_OVERFLOW;

        map_start = align_down(ph.p_vaddr, host_page_size);
        if (align_up_checked(mem_end, host_page_size, &map_end))
            return STEAMOS_ELF64_ERR_ADDRESS_OVERFLOW;
        if (map_start < min_addr) min_addr = map_start;
        if (map_end > max_addr) max_addr = map_end;

        out_image->load[load_count].file_offset = ph.p_offset;
        out_image->load[load_count].virtual_address = ph.p_vaddr;
        out_image->load[load_count].file_size = ph.p_filesz;
        out_image->load[load_count].memory_size = ph.p_memsz;
        out_image->load[load_count].alignment = ph.p_align;
        out_image->load[load_count].flags = ph.p_flags;
        ++load_count;

        if ((ph.p_flags & STEAMOS_ELF64_PF_X) && eh.e_entry >= ph.p_vaddr && eh.e_entry < mem_end)
            entry_is_executable = 1;
    }

    if (!load_count) return STEAMOS_ELF64_ERR_NO_LOAD_SEGMENTS;
    if (!entry_is_executable) return STEAMOS_ELF64_ERR_ENTRY_NOT_EXECUTABLE;

    out_image->entry = eh.e_entry;
    out_image->load_min = min_addr;
    out_image->load_max = max_addr;
    out_image->elf_type = eh.e_type;
    out_image->load_count = load_count;
    return STEAMOS_ELF64_OK;
}

const char *steamos_elf64_error_string(enum steamos_elf64_error error)
{
    switch (error) {
    case STEAMOS_ELF64_OK: return "ok";
    case STEAMOS_ELF64_ERR_ARGUMENT: return "invalid argument";
    case STEAMOS_ELF64_ERR_TRUNCATED_HEADER: return "truncated ELF header";
    case STEAMOS_ELF64_ERR_MAGIC: return "invalid ELF magic";
    case STEAMOS_ELF64_ERR_CLASS: return "ELF is not 64-bit";
    case STEAMOS_ELF64_ERR_ENDIAN: return "ELF is not little-endian";
    case STEAMOS_ELF64_ERR_VERSION: return "unsupported ELF version";
    case STEAMOS_ELF64_ERR_TYPE: return "unsupported ELF type";
    case STEAMOS_ELF64_ERR_MACHINE: return "ELF is not x86-64";
    case STEAMOS_ELF64_ERR_PHENTSIZE: return "unexpected program-header size";
    case STEAMOS_ELF64_ERR_PHDR_BOUNDS: return "program-header table is out of bounds";
    case STEAMOS_ELF64_ERR_INTERPRETER_UNSUPPORTED: return "PT_INTERP requires the L1 dynamic loader";
    case STEAMOS_ELF64_ERR_SEGMENT_BOUNDS: return "load segment exceeds file bounds";
    case STEAMOS_ELF64_ERR_SEGMENT_SIZE: return "load segment file size exceeds memory size";
    case STEAMOS_ELF64_ERR_ADDRESS_OVERFLOW: return "ELF address arithmetic overflow";
    case STEAMOS_ELF64_ERR_NO_LOAD_SEGMENTS: return "ELF contains no loadable segments";
    case STEAMOS_ELF64_ERR_ENTRY_NOT_EXECUTABLE: return "entry point is not in an executable segment";
    case STEAMOS_ELF64_ERR_TOO_MANY_SEGMENTS: return "too many loadable segments";
    default: return "unknown ELF error";
    }
}
