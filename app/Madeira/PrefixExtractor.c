// Minimal gzip + ustar extractor used by the bundled Wine prefix.
// Supports regular files, directories, ustar prefix fields, and skipping
// pax/GNU metadata records. Clean SteamIOS builds emit --format=ustar so
// long Steam client paths remain deterministic without pax path overrides.

#include "PrefixExtractor.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <zlib.h>

#define BLOCK 512

static int parse_octal(const char *s, size_t n) {
    int v = 0;
    for (size_t i = 0; i < n && s[i]; i++) {
        if (s[i] == ' ' || s[i] == 0) continue;
        if (s[i] < '0' || s[i] > '7') return -1;
        v = (v << 3) | (s[i] - '0');
    }
    return v;
}

static int mkdir_p(const char *path) {
    char buf[1200];
    strncpy(buf, path, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = 0;
    for (char *p = buf + 1; *p; p++) {
        if (*p == '/') {
            *p = 0;
            if (mkdir(buf, 0755) != 0 && errno != EEXIST) return -1;
            *p = '/';
        }
    }
    if (mkdir(buf, 0755) != 0 && errno != EEXIST) return -1;
    return 0;
}

static void header_path(const char *header, char *out, size_t out_size) {
    char name[101] = {0};
    char prefix[156] = {0};
    memcpy(name, header, 100);
    memcpy(prefix, header + 345, 155);
    if (prefix[0])
        snprintf(out, out_size, "%s/%s", prefix, name);
    else
        snprintf(out, out_size, "%s", name);
}

static int skip_payload(gzFile gz, int size, char *buf) {
    int pad = (size + BLOCK - 1) / BLOCK * BLOCK;
    while (pad > 0) {
        if (gzread(gz, buf, BLOCK) != BLOCK) return -1;
        pad -= BLOCK;
    }
    return 0;
}

static int selected_path(const char *relname, const char *subtree) {
    if (!subtree || !*subtree) return 1;
    size_t n = strlen(subtree);
    return strcmp(relname, subtree) == 0 ||
           (strncmp(relname, subtree, n) == 0 && relname[n] == '/');
}

static int extract_impl(const char *tgz_path, const char *dest_dir, const char *subtree) {
    gzFile gz = gzopen(tgz_path, "rb");
    if (!gz) {
        fprintf(stderr, "[prefix-extract] gzopen failed: %s\n", tgz_path);
        return -1;
    }
    if (mkdir_p(dest_dir) != 0) {
        fprintf(stderr, "[prefix-extract] mkdir_p dest failed: %s\n", dest_dir);
        gzclose(gz);
        return -1;
    }

    char header[BLOCK];
    char buf[BLOCK];
    int files = 0, dirs = 0, skipped = 0;

    for (;;) {
        int n = gzread(gz, header, BLOCK);
        if (n == 0) break;
        if (n != BLOCK) {
            fprintf(stderr, "[prefix-extract] short header read: %d\n", n);
            gzclose(gz);
            return -1;
        }

        int all_zero = 1;
        for (int i = 0; i < BLOCK; i++) if (header[i]) { all_zero = 0; break; }
        if (all_zero) break;

        char archive_name[300] = {0};
        header_path(header, archive_name, sizeof(archive_name));
        int size = parse_octal(header + 124, 12);
        if (size < 0) {
            fprintf(stderr, "[prefix-extract] invalid size for %s\n", archive_name);
            gzclose(gz);
            return -1;
        }
        char type = header[156];

        const char *relname = archive_name;
        if (strncmp(relname, "prefix/", 7) == 0) relname += 7;
        else if (strcmp(relname, "prefix") == 0) relname = "";

        int selected = *relname && selected_path(relname, subtree);

        if (type == '5' || (type == 0 && archive_name[0] &&
                            archive_name[strlen(archive_name) - 1] == '/')) {
            if (selected) {
                char outpath[1500];
                snprintf(outpath, sizeof(outpath), "%s/%s", dest_dir, relname);
                if (mkdir_p(outpath) != 0) {
                    fprintf(stderr, "[prefix-extract] mkdir %s: %s\n", outpath, strerror(errno));
                    gzclose(gz);
                    return -1;
                }
                dirs++;
            }
        } else if (type == '0' || type == 0) {
            if (!selected) {
                if (skip_payload(gz, size, buf) != 0) {
                    fprintf(stderr, "[prefix-extract] short skip for %s\n", relname);
                    gzclose(gz);
                    return -1;
                }
                skipped++;
                continue;
            }

            char outpath[1500];
            snprintf(outpath, sizeof(outpath), "%s/%s", dest_dir, relname);
            char parent[1500];
            strncpy(parent, outpath, sizeof(parent) - 1);
            parent[sizeof(parent) - 1] = 0;
            char *slash = strrchr(parent, '/');
            if (slash) { *slash = 0; if (mkdir_p(parent) != 0) { gzclose(gz); return -1; } }

            int fd = open(outpath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (fd < 0) {
                fprintf(stderr, "[prefix-extract] open %s: %s\n", outpath, strerror(errno));
                gzclose(gz);
                return -1;
            }
            int remaining = size;
            while (remaining > 0) {
                int want = remaining < BLOCK ? remaining : BLOCK;
                int got = gzread(gz, buf, BLOCK);
                if (got != BLOCK) {
                    fprintf(stderr, "[prefix-extract] short data read for %s\n", relname);
                    close(fd);
                    gzclose(gz);
                    return -1;
                }
                if (write(fd, buf, want) != want) {
                    fprintf(stderr, "[prefix-extract] write %s: %s\n", outpath, strerror(errno));
                    close(fd);
                    gzclose(gz);
                    return -1;
                }
                remaining -= want;
            }
            close(fd);
            files++;
        } else {
            if (skip_payload(gz, size, buf) != 0) {
                fprintf(stderr, "[prefix-extract] short metadata skip for %s\n", archive_name);
                gzclose(gz);
                return -1;
            }
        }
    }

    gzclose(gz);
    fprintf(stderr, "[prefix-extract] extracted %d files, %d dirs, skipped %d to %s%s%s\n",
            files, dirs, skipped, dest_dir,
            subtree ? " subtree=" : "", subtree ? subtree : "");
    return 0;
}

int madeira_extract_prefix_tgz(const char *tgz_path, const char *dest_dir) {
    return extract_impl(tgz_path, dest_dir, NULL);
}

int madeira_extract_prefix_subtree_tgz(const char *tgz_path,
                                       const char *dest_dir,
                                       const char *subtree) {
    if (!subtree || !*subtree) return -1;
    return extract_impl(tgz_path, dest_dir, subtree);
}
