#ifndef SZUNRAR_H
#define SZUNRAR_H

#include <stddef.h>

/*
 * A small C surface over unrar's dll API, so Swift can call it without any
 * C++ interop. unrar's own dll.hpp is not self-contained (it needs raros.hpp
 * first) and its types are Windows-flavoured, which is awkward to import
 * directly.
 *
 * Extraction goes to a directory rather than to memory on purpose: RAR
 * archives are frequently *solid*, meaning entries share compression state and
 * random access to entry N costs decompressing everything before it. Unpacking
 * once, in order, is the only sane access pattern.
 */

#ifdef __cplusplus
extern "C" {
#endif

#define SZUNRAR_OK 0

/* Entry names of the non-directory members, each NUL-terminated, packed back
 * to back into `buffer`. `*needed` always receives the required byte count, so
 * a first call with buffer == NULL sizes the allocation.
 * Returns SZUNRAR_OK, or an ERAR_* code from unrar. */
int szunrar_list(const char *archivePath, char *buffer, size_t capacity, size_t *needed);

/* Unpacks every entry beneath `destinationDir`, preserving internal paths.
 * Returns SZUNRAR_OK, or an ERAR_* code. */
int szunrar_extract_all(const char *archivePath, const char *destinationDir);

/* Stable, human-readable text for an ERAR_* code. */
const char *szunrar_error_string(int code);

/* Non-zero when the archive needs a password we do not have. */
int szunrar_is_password_error(int code);

#ifdef __cplusplus
}
#endif

#endif /* SZUNRAR_H */
