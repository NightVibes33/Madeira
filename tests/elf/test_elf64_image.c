#include "../../runtime/linux/elf/elf64_image.h"

#include <stdio.h>
#include <stdlib.h>

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

int main(int argc, char **argv)
{
    struct steamos_elf64_image image;
    enum steamos_elf64_error err;
    unsigned char *bytes;
    size_t size;

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
    free(bytes);
    if (err != STEAMOS_ELF64_OK) {
        fprintf(stderr, "parse failed: %s\n", steamos_elf64_error_string(err));
        return 1;
    }
    if (image.elf_type != 2 || image.entry != 0x400080 || image.load_count != 1 ||
        image.load[0].virtual_address != 0x400000 ||
        !(image.load[0].flags & STEAMOS_ELF64_PF_X)) {
        fprintf(stderr, "unexpected parsed image\n");
        return 1;
    }

    puts("STEAMOS_IOS_ELF_PARSE_OK");
    return 0;
}
