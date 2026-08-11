#ifndef SZ7Z_H
#define SZ7Z_H

#include <stddef.h>

/*
 * A small C surface over the LZMA SDK's 7z reader, mirroring szunrar.h so the
 * Swift side treats both containers the same way.
 *
 * Extraction goes to a directory rather than to memory for the same reason as
 * RAR: 7z archives are usually *solid*, meaning entries share compression
 * state, so reading entry N costs decompressing everything before it. The SDK
 * keeps one decompressed block cached across calls, which makes unpacking in
 * index order the only sane access pattern.
 */

#ifdef __cplusplus
extern "C" {
#endif

#define SZ7Z_OK 0

/* Entry names of the non-directory members, UTF-8, each NUL-terminated and
 * packed back to back into `buffer`. `*needed` always receives the required
 * byte count, so a first call with buffer == NULL sizes the allocation.
 * Returns SZ7Z_OK, or an SRes code from the SDK. */
int sz7z_list(const char *archivePath, char *buffer, size_t capacity, size_t *needed);

/* Unpacks every entry beneath `destinationDir`, preserving internal paths.
 * Returns SZ7Z_OK, or an SRes code from the SDK. */
int sz7z_extract_all(const char *archivePath, const char *destinationDir);

#ifdef __cplusplus
}
#endif

#endif /* SZ7Z_H */
