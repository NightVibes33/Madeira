#ifndef PREFIX_EXTRACTOR_H
#define PREFIX_EXTRACTOR_H

// Extracts a gzipped tar into dest_dir. Returns 0 on success, -1 on error.
// The tarball is expected to have a single top-level "prefix/" directory;
// its contents are extracted directly into dest_dir.
int madeira_extract_prefix_tgz(const char *tgz_path, const char *dest_dir);

// Extract only one subtree (relative to the stripped prefix/ root) from the
// same archive. Used to migrate the fully bundled Steam client into an
// already-existing Wine prefix without overwriting registry/user state.
int madeira_extract_prefix_subtree_tgz(const char *tgz_path,
                                       const char *dest_dir,
                                       const char *subtree);

#endif
