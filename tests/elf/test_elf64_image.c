#include "../../runtime/linux/elf/elf64_image.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned char *read_all(const char *path, size_t *size)
{
    FILE *f = fopen(path, "rb");
    long end;
    unsigned char *bytes;
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) || (end = ftell(f)) < 0 || fseek(f, 0, SEEK_SET)) {
        fclose(f);
        return NULL;
    }
    bytes = (unsigned char *)malloc((size_t)end);
    if (!bytes || fread(bytes, 1, (size_t)end, f) != (size_t)end) {
        free(bytes);
        fclose(f);
        return NULL;
    }
    fclose(f);
    *size = (size_t)end;
    return bytes;
}

static void put_u16(unsigned char *p, unsigned short v)
{
    memcpy(p, &v, sizeof(v));
}

static void put_u64(unsigned char *p, unsigned long long v)
{
    memcpy(p, &v, sizeof(v));
}

static int expect_error(const unsigned char *original, size_t size,
                        enum steamos_elf64_error expected,
                        void (*mutate)(unsigned char *, size_t),
                        const char *name)
{
    struct steamos_elf64_image image;
    unsigned char *copy = (unsigned char *)malloc(size);
    enum steamos_elf64_error got;
    if (!copy) return 1;
    memcpy(copy, original, size);
    mutate(copy, size);
    got = steamos_elf64_parse(copy, size, 0x4000, &image);
    free(copy);
    if (got != expected) {
        fprintf(stderr, "%s: expected %s, got %s\n", name,
                steamos_elf64_error_string(expected),
                steamos_elf64_error_string(got));
        return 1;
    }
    return 0;
}

static void bad_magic(unsigned char *b, size_t n) { (void)n; b[0] = 0; }
static void bad_class(unsigned char *b, size_t n) { (void)n; b[4] = 1; }
static void bad_machine(unsigned char *b, size_t n) { (void)n; put_u16(b + 18, 3); }
static void bad_phdr_bounds(unsigned char *b, size_t n) { (void)n; put_u64(b + 32, ~0ULL - 8); }
static void dynamic_interp(unsigned char *b, size_t n) { (void)n; memcpy(b + 64, "\x03\x00\x00\x00", 4); }
static void bad_segment_size(unsigned char *b, size_t n) {
    (void)n; put_u64(b + 64 + 32, 32); put_u64(b + 64 + 40, 16);
}
static void bad_segment_bounds(unsigned char *b, size_t n) {
    (void)n; put_u64(b + 64 + 8, 0x1000); put_u64(b + 64 + 32, 16); put_u64(b + 64 + 40, 16);
}
static void bad_entry(unsigned char *b, size_t n) { (void)n; put_u64(b + 24, 0x500000); }
static void bad_address_overflow(unsigned char *b, size_t n) {
    (void)n;
    put_u64(b + 64 + 16, ~0ULL - 7); /* p_vaddr */
    put_u64(b + 64 + 32, 0);         /* p_filesz: do not trip size validation first */
    put_u64(b + 64 + 40, 16);        /* p_memsz: vaddr + memsz overflows */
}

int main(int argc, char **argv)
{
    struct steamos_elf64_image image;
    enum steamos_elf64_error err;
    unsigned char *bytes;
    size_t size;
    int failed = 0;

    if (argc != 2) {
        fprintf(stderr, "usage: %s smoke.elf\n", argv[0]);
        return 2;
    }
    bytes = read_all(argv[1], &size);
    if (!bytes) {
        fprintf(stderr, "failed to read %s\n", argv[1]);
        return 2;
    }

    err = steamos_elf64_parse(bytes, size, 0x4000, &image);
    if (err != STEAMOS_ELF64_OK) {
        fprintf(stderr, "parse failed: %s\n", steamos_elf64_error_string(err));
        free(bytes);
        return 1;
    }
    if (image.elf_type != 2 || image.entry != 0x400080 || image.load_count != 1 ||
        image.load[0].virtual_address != 0x400000 ||
        !(image.load[0].flags & STEAMOS_ELF64_PF_X)) {
        fprintf(stderr, "unexpected parsed image\n");
        free(bytes);
        return 1;
    }

    failed |= expect_error(bytes, size, STEAMOS_ELF64_ERR_MAGIC, bad_magic, "bad magic");
    failed |= expect_error(bytes, size, STEAMOS_ELF64_ERR_CLASS, bad_class, "bad class");
    failed |= expect_error(bytes, size, STEAMOS_ELF64_ERR_MACHINE, bad_machine, "bad machine");
    failed |= expect_error(bytes, size, STEAMOS_ELF64_ERR_PHDR_BOUNDS, bad_phdr_bounds, "phdr bounds");
    failed |= expect_error(bytes, size, STEAMOS_ELF64_ERR_INTERPRETER_UNSUPPORTED, dynamic_interp, "PT_INTERP L1 guard");
    failed |= expect_error(bytes, size, STEAMOS_ELF64_ERR_SEGMENT_SIZE, bad_segment_size, "segment size");
    failed |= expect_error(bytes, size, STEAMOS_ELF64_ERR_SEGMENT_BOUNDS, bad_segment_bounds, "segment bounds");
    failed |= expect_error(bytes, size, STEAMOS_ELF64_ERR_ENTRY_NOT_EXECUTABLE, bad_entry, "entry coverage");
    failed |= expect_error(bytes, size, STEAMOS_ELF64_ERR_ADDRESS_OVERFLOW, bad_address_overflow, "address overflow");

    err = steamos_elf64_parse(bytes, size, 0x3000, &image);
    if (err != STEAMOS_ELF64_ERR_ARGUMENT) {
        fprintf(stderr, "invalid page size: expected argument error, got %s\n",
                steamos_elf64_error_string(err));
        failed = 1;
    }

    free(bytes);
    if (failed) return 1;
    puts("STEAMOS_IOS_ELF_PARSE_OK");
    puts("STEAMOS_IOS_ELF_NEGATIVE_CASES_OK");
    return 0;
}
