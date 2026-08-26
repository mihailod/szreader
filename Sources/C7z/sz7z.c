#include "sz7z.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "7z.h"
#include "7zAlloc.h"
#include "7zCrc.h"
#include "7zFile.h"
#include "7zTypes.h"

/* Big enough that the SDK's look-ahead reader is not re-filling constantly,
 * small enough to be irrelevant next to a comic. */
#define SZ7Z_LOOKAHEAD (1 << 16)

/* Built from 7zAlloc.h rather than using the SDK's g_Alloc, which lives in
 * Alloc.c — a file its own 7z decoder set does not include. The CLI sample
 * does the same. */
static const ISzAlloc sz7zAlloc = { SzAlloc, SzFree };

/* One archive, opened and ready to read. Bundled because opening a 7z means
 * five pieces of state that must be torn down in the right order. */
typedef struct {
    CFileInStream stream;
    CLookToRead2 look;
    CSzArEx db;
    Byte *lookBuffer;
    int streamOpen;
    int dbInitialised;
} SZ7zArchive;

static void sz7z_close(SZ7zArchive *a) {
    if (a->dbInitialised) SzArEx_Free(&a->db, &sz7zAlloc);
    if (a->streamOpen) File_Close(&a->stream.file);
    free(a->lookBuffer);
    memset(a, 0, sizeof(*a));
}

static SRes sz7z_open(SZ7zArchive *a, const char *path) {
    memset(a, 0, sizeof(*a));

    /* The CRC table is global to the SDK and must exist before any read.
     * Generating it twice is harmless; not generating it corrupts every
     * checksum comparison. */
    CrcGenerateTable();

    if (InFile_Open(&a->stream.file, path) != 0) return SZ_ERROR_NO_ARCHIVE;
    a->streamOpen = 1;

    FileInStream_CreateVTable(&a->stream);
    LookToRead2_CreateVTable(&a->look, False);
    a->look.realStream = &a->stream.vt;
    LookToRead2_INIT(&a->look)

    a->lookBuffer = (Byte *)malloc(SZ7Z_LOOKAHEAD);
    if (!a->lookBuffer) { sz7z_close(a); return SZ_ERROR_MEM; }
    a->look.buf = a->lookBuffer;
    a->look.bufSize = SZ7Z_LOOKAHEAD;

    SzArEx_Init(&a->db);
    a->dbInitialised = 1;

    SRes res = SzArEx_Open(&a->db, &a->look.vt, &sz7zAlloc, &sz7zAlloc);
    if (res != SZ_OK) { sz7z_close(a); return res; }
    return SZ_OK;
}

/* UTF-16 to UTF-8. The SDK stores names as UTF-16 and its own converter is in
 * the CLI sample rather than the library, so this is the one piece of encoding
 * work that has to live here.
 *
 * Writes into `out` when there is room and always returns the byte count, so a
 * NULL destination sizes the buffer. Surrogate pairs are joined; an unpaired
 * surrogate is replaced rather than dropped, because a name that loses a
 * character silently stops matching the file on disk. */
static size_t sz7z_utf16_to_utf8(const UInt16 *src, size_t srcLen,
                                 char *out, size_t capacity) {
    size_t written = 0;
    for (size_t i = 0; i < srcLen; i++) {
        unsigned int scalar = src[i];
        if (scalar >= 0xD800 && scalar <= 0xDBFF && i + 1 < srcLen
            && src[i + 1] >= 0xDC00 && src[i + 1] <= 0xDFFF) {
            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (src[i + 1] - 0xDC00);
            i++;
        } else if (scalar >= 0xD800 && scalar <= 0xDFFF) {
            scalar = 0xFFFD;
        }

        char encoded[4];
        size_t length;
        if (scalar < 0x80) {
            encoded[0] = (char)scalar; length = 1;
        } else if (scalar < 0x800) {
            encoded[0] = (char)(0xC0 | (scalar >> 6));
            encoded[1] = (char)(0x80 | (scalar & 0x3F)); length = 2;
        } else if (scalar < 0x10000) {
            encoded[0] = (char)(0xE0 | (scalar >> 12));
            encoded[1] = (char)(0x80 | ((scalar >> 6) & 0x3F));
            encoded[2] = (char)(0x80 | (scalar & 0x3F)); length = 3;
        } else {
            encoded[0] = (char)(0xF0 | (scalar >> 18));
            encoded[1] = (char)(0x80 | ((scalar >> 12) & 0x3F));
            encoded[2] = (char)(0x80 | ((scalar >> 6) & 0x3F));
            encoded[3] = (char)(0x80 | (scalar & 0x3F)); length = 4;
        }
        if (out && written + length <= capacity) memcpy(out + written, encoded, length);
        written += length;
    }
    return written;
}

/* Entry name as UTF-8, allocated by the caller's malloc. */
static char *sz7z_entry_name(const CSzArEx *db, size_t index) {
    size_t utf16Len = SzArEx_GetFileNameUtf16(db, index, NULL);   /* includes terminator */
    if (utf16Len == 0) return NULL;
    UInt16 *utf16 = (UInt16 *)malloc(utf16Len * sizeof(UInt16));
    if (!utf16) return NULL;
    SzArEx_GetFileNameUtf16(db, index, utf16);

    size_t chars = utf16Len > 0 ? utf16Len - 1 : 0;               /* drop terminator */
    size_t bytes = sz7z_utf16_to_utf8(utf16, chars, NULL, 0);
    char *utf8 = (char *)malloc(bytes + 1);
    if (utf8) {
        sz7z_utf16_to_utf8(utf16, chars, utf8, bytes);
        utf8[bytes] = '\0';
    }
    free(utf16);
    return utf8;
}

int sz7z_list(const char *archivePath, char *buffer, size_t capacity, size_t *needed) {
    SZ7zArchive archive;
    SRes res = sz7z_open(&archive, archivePath);
    if (res != SZ_OK) return (int)res;

    size_t used = 0;
    for (UInt32 i = 0; i < archive.db.NumFiles; i++) {
        if (SzArEx_IsDir(&archive.db, i)) continue;
        char *name = sz7z_entry_name(&archive.db, i);
        if (!name) continue;
        size_t length = strlen(name) + 1;
        if (buffer && used + length <= capacity) memcpy(buffer + used, name, length);
        used += length;
        free(name);
    }
    if (needed) *needed = used;
    sz7z_close(&archive);
    return SZ7Z_OK;
}

/* Creates every directory along `path`, which may contain separators the
 * archive carried inside entry names. */
static int sz7z_make_directories(const char *path) {
    char *copy = strdup(path);
    if (!copy) return 0;
    for (char *p = copy + 1; *p; p++) {
        if (*p != '/') continue;
        *p = '\0';
        mkdir(copy, 0755);              /* EEXIST is the normal case */
        *p = '/';
    }
    mkdir(copy, 0755);
    free(copy);
    return 1;
}

/* Whether an entry name ends in an extension a page is stored as.
 *
 * Extension rather than content: the whole point is to decompress nothing we
 * do not need, and deciding by content would mean extracting the `.nfo` to
 * discover it is an `.nfo`. */
static int sz7z_looks_like_image(const char *name) {
    static const char *kImages[] = {
        "jpg", "jpeg", "png", "gif", "bmp", "webp", "tif", "tiff", "heic", NULL,
    };
    const char *dot = strrchr(name, '.');
    if (!dot) return 0;

    char ext[8];
    size_t n = strlen(dot + 1);
    if (n == 0 || n >= sizeof(ext)) return 0;
    for (size_t i = 0; i < n; i++) {
        char c = dot[1 + i];
        ext[i] = (c >= 'A' && c <= 'Z') ? (char)(c - 'A' + 'a') : c;
    }
    ext[n] = '\0';

    for (int i = 0; kImages[i]; i++) {
        if (strcmp(ext, kImages[i]) == 0) return 1;
    }
    return 0;
}

int sz7z_extract_first_image(const char *archivePath, const char *destinationDir,
                             char *nameBuffer, size_t nameCapacity) {
    SZ7zArchive archive;
    SRes res = sz7z_open(&archive, archivePath);
    if (res != SZ_OK) return (int)res;

    UInt32 blockIndex = 0xFFFFFFFF;
    Byte *outBuffer = NULL;
    size_t outBufferSize = 0;
    int found = 0;

    sz7z_make_directories(destinationDir);

    for (UInt32 i = 0; i < archive.db.NumFiles && res == SZ_OK && !found; i++) {
        if (SzArEx_IsDir(&archive.db, i)) continue;

        char *name = sz7z_entry_name(&archive.db, i);
        if (!name) { res = SZ_ERROR_MEM; break; }

        /* Same refusal as the full extraction: an entry naming "../" or an
         * absolute path writes outside the destination, and a comic has no
         * reason to carry one. */
        if (name[0] == '/' || strstr(name, "..") != NULL || !sz7z_looks_like_image(name)) {
            free(name);
            continue;
        }
        if (nameBuffer && strlen(name) + 1 > nameCapacity) {
            free(name);
            res = SZ_ERROR_OUTPUT_EOF;
            break;
        }

        size_t offset = 0, sizeProcessed = 0;
        res = SzArEx_Extract(&archive.db, &archive.look.vt, i, &blockIndex,
                             &outBuffer, &outBufferSize, &offset, &sizeProcessed,
                             &sz7zAlloc, &sz7zAlloc);
        if (res != SZ_OK) { free(name); break; }

        size_t pathLength = strlen(destinationDir) + 1 + strlen(name) + 1;
        char *path = (char *)malloc(pathLength);
        if (!path) { free(name); res = SZ_ERROR_MEM; break; }
        snprintf(path, pathLength, "%s/%s", destinationDir, name);

        char *lastSlash = strrchr(path, '/');
        if (lastSlash) {
            *lastSlash = '\0';
            sz7z_make_directories(path);
            *lastSlash = '/';
        }

        CSzFile file;
        if (OutFile_Open(&file, path) == 0) {
            size_t remaining = sizeProcessed;
            if (File_Write(&file, outBuffer + offset, &remaining) != 0
                || remaining != sizeProcessed) {
                res = SZ_ERROR_WRITE;
            } else {
                if (nameBuffer) memcpy(nameBuffer, name, strlen(name) + 1);
                found = 1;
            }
            File_Close(&file);
        } else {
            res = SZ_ERROR_WRITE;
        }
        free(path);
        free(name);
    }

    ISzAlloc_Free(&sz7zAlloc, outBuffer);
    sz7z_close(&archive);
    if (res != SZ_OK) return (int)res;
    /* Opened and whole, but with no page in it. Its own outcome, not a fault. */
    return found ? SZ7Z_OK : SZ_ERROR_NO_ARCHIVE;
}

int sz7z_extract_all(const char *archivePath, const char *destinationDir) {
    SZ7zArchive archive;
    SRes res = sz7z_open(&archive, archivePath);
    if (res != SZ_OK) return (int)res;

    /* Carried across iterations on purpose: the SDK keeps the decompressed
     * solid block here, so extracting in index order decompresses each block
     * once instead of once per entry. */
    UInt32 blockIndex = 0xFFFFFFFF;
    Byte *outBuffer = NULL;
    size_t outBufferSize = 0;

    sz7z_make_directories(destinationDir);

    for (UInt32 i = 0; i < archive.db.NumFiles && res == SZ_OK; i++) {
        if (SzArEx_IsDir(&archive.db, i)) continue;

        char *name = sz7z_entry_name(&archive.db, i);
        if (!name) { res = SZ_ERROR_MEM; break; }

        /* Entry names are attacker-controlled: an archive can carry "../" or an
         * absolute path and write outside the destination. Both are refused
         * rather than sanitised, because a comic has no reason to contain one. */
        if (name[0] == '/' || strstr(name, "..") != NULL) { free(name); continue; }

        size_t offset = 0, sizeProcessed = 0;
        res = SzArEx_Extract(&archive.db, &archive.look.vt, i, &blockIndex,
                             &outBuffer, &outBufferSize, &offset, &sizeProcessed,
                             &sz7zAlloc, &sz7zAlloc);
        if (res != SZ_OK) { free(name); break; }

        size_t pathLength = strlen(destinationDir) + 1 + strlen(name) + 1;
        char *path = (char *)malloc(pathLength);
        if (!path) { free(name); res = SZ_ERROR_MEM; break; }
        snprintf(path, pathLength, "%s/%s", destinationDir, name);

        /* An entry may name a folder that has no directory entry of its own. */
        char *lastSlash = strrchr(path, '/');
        if (lastSlash) {
            *lastSlash = '\0';
            sz7z_make_directories(path);
            *lastSlash = '/';
        }

        CSzFile file;
        if (OutFile_Open(&file, path) == 0) {
            size_t remaining = sizeProcessed;
            if (File_Write(&file, outBuffer + offset, &remaining) != 0
                || remaining != sizeProcessed) {
                res = SZ_ERROR_WRITE;
            }
            File_Close(&file);
        } else {
            res = SZ_ERROR_WRITE;
        }
        free(path);
        free(name);
    }

    ISzAlloc_Free(&sz7zAlloc, outBuffer);
    sz7z_close(&archive);
    return (int)res;
}
