# Export compliance

App Store Connect asks, on every upload, whether the app uses encryption.
`ITSAppUsesNonExemptEncryption` is set to `false` in `project.yml` so it is
answered once. This file records what that answer rests on, because the
question is about what the binary *contains*, not only what it runs.

## What is in the binary

| Where | What | Provided by |
|---|---|---|
| `Sources/SZKit/Crypto.swift` | AES-128 CBC and CTR, decrypt only | **Apple** — CommonCrypto (`CCCrypt`, `CCCryptorCreateWithMode`) |
| `App/CoverStore.swift` | SHA-256, used to name a cache file from a URL | **Apple** — CryptoKit. A hash, not encryption |
| `URLSession`, `WKWebView` | TLS to stripzona.com, stripovi.com and the file hosts | **Apple** — the OS |
| `Sources/CUnrar/unrar/crypt.cpp`, `sha1.cpp`, `sha256.cpp`, `blake2s.cpp` | unrar's own AES, for RAR archives that are password-protected | Third party (unrar), compiled in but **unreachable** — see below |
| `Sources/C7z/lzma/` | LZMA decompression | Third party. `Aes.c` is **not** in the compiled set (`Package.swift`); only the header is present in the tree |

## Why the AES in Crypto.swift is there

Mega encrypts the attribute blob that carries a file's name, and the file
itself, with AES. Reading a Mega link therefore means decrypting it. This is
done with CommonCrypto — the implementation is the operating system's, the app
supplies only the key it was given in the link.

## Why unrar's crypto is unreachable

unrar ships its own AES for encrypted RAR archives. It is compiled in because
it is part of the library, but nothing in the app can reach it: there is no
password prompt, no password field, and no call that supplies one. An
encrypted archive fails to open and is reported as an error. Removing
`crypt.cpp` from the compiled set would make this plainer still, at the risk of
breaking RAR 5 header handling — not attempted.

## The exemption relied on

All encryption the app actually performs is provided by the operating system:
CommonCrypto and TLS. That is the exemption for apps that use, access or
incorporate encryption provided by Apple's operating system, and make only
standard HTTPS calls of their own. The third-party AES that is linked but
unreachable is a standard published algorithm in a mass-market application, not
a proprietary or restricted implementation.

## When to revisit this

- A password prompt for encrypted archives — that would make unrar's AES
  reachable, and the answer would need re-examining.
- Any encryption written into the app itself rather than called from the OS.
- Any use of encryption for something other than reading a file host's
  content: storing user data encrypted, a private protocol, DRM.
