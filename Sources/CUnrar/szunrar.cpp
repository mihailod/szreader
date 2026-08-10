#include "szunrar.h"

#include "raros.hpp"   // must precede dll.hpp: defines the POSIX type shims
#include "dll.hpp"

#include <string.h>

namespace {

int openArchive(const char *path, unsigned int mode, HANDLE *out) {
    RAROpenArchiveDataEx data;
    memset(&data, 0, sizeof(data));
    data.ArcName = const_cast<char *>(path);
    data.OpenMode = mode;

    HANDLE handle = RAROpenArchiveEx(&data);
    if (handle == NULL) {
        return data.OpenResult != 0 ? static_cast<int>(data.OpenResult) : ERAR_EOPEN;
    }
    if (data.OpenResult != 0) {
        RARCloseArchive(handle);
        return static_cast<int>(data.OpenResult);
    }
    *out = handle;
    return SZUNRAR_OK;
}

} // namespace

int szunrar_list(const char *archivePath, char *buffer, size_t capacity, size_t *needed) {
    HANDLE handle = NULL;
    int rc = openArchive(archivePath, RAR_OM_LIST, &handle);
    if (rc != SZUNRAR_OK) return rc;

    size_t used = 0;
    RARHeaderDataEx header;
    memset(&header, 0, sizeof(header));

    while (RARReadHeaderEx(handle, &header) == 0) {
        if ((header.Flags & RHDF_DIRECTORY) == 0) {
            size_t length = strlen(header.FileName) + 1;
            if (buffer != NULL && used + length <= capacity) {
                memcpy(buffer + used, header.FileName, length);
            }
            used += length;
        }
        int processed = RARProcessFile(handle, RAR_SKIP, NULL, NULL);
        if (processed != 0) {
            RARCloseArchive(handle);
            return processed;
        }
        memset(&header, 0, sizeof(header));
    }

    RARCloseArchive(handle);
    if (needed != NULL) *needed = used;
    if (buffer != NULL && used > capacity) return ERAR_SMALL_BUF;
    return SZUNRAR_OK;
}

int szunrar_extract_all(const char *archivePath, const char *destinationDir) {
    HANDLE handle = NULL;
    int rc = openArchive(archivePath, RAR_OM_EXTRACT, &handle);
    if (rc != SZUNRAR_OK) return rc;

    RARHeaderDataEx header;
    memset(&header, 0, sizeof(header));

    while (RARReadHeaderEx(handle, &header) == 0) {
        // Encrypted entries would otherwise prompt or emit garbage; fail loudly.
        if (header.Flags & RHDF_ENCRYPTED) {
            RARCloseArchive(handle);
            return ERAR_MISSING_PASSWORD;
        }
        int processed = RARProcessFile(handle, RAR_EXTRACT,
                                       const_cast<char *>(destinationDir), NULL);
        if (processed != 0) {
            RARCloseArchive(handle);
            return processed;
        }
        memset(&header, 0, sizeof(header));
    }

    RARCloseArchive(handle);
    return SZUNRAR_OK;
}

int szunrar_is_password_error(int code) {
    return code == ERAR_MISSING_PASSWORD || code == ERAR_BAD_PASSWORD;
}

const char *szunrar_error_string(int code) {
    switch (code) {
    case SZUNRAR_OK:             return "ok";
    case ERAR_END_ARCHIVE:       return "end of archive";
    case ERAR_NO_MEMORY:         return "out of memory";
    case ERAR_BAD_DATA:          return "corrupt data (CRC failed)";
    case ERAR_BAD_ARCHIVE:       return "not a valid RAR archive";
    case ERAR_UNKNOWN_FORMAT:    return "unknown RAR format version";
    case ERAR_EOPEN:             return "could not open archive";
    case ERAR_ECREATE:           return "could not create output file";
    case ERAR_ECLOSE:            return "could not close file";
    case ERAR_EREAD:             return "read error";
    case ERAR_EWRITE:            return "write error";
    case ERAR_SMALL_BUF:         return "buffer too small";
    case ERAR_UNKNOWN:           return "unknown error";
    case ERAR_MISSING_PASSWORD:  return "archive is password protected";
    case ERAR_EREFERENCE:        return "missing reference record";
    case ERAR_BAD_PASSWORD:      return "wrong password";
    default:                     return "unrecognised unrar error";
    }
}
