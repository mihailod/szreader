// SZPages is where the archive formats and the page decoder live, split out so
// the thumbnail extension can link them without dragging the catalogues in
// with them (see Package.swift). That split is a packaging decision, not an
// API one: `ArchiveKind`, `ComicDocument` and the readers were one module to
// every caller before it and stay one module to every caller after it.
//
// Re-exported rather than imported in each file that needs it, so no call site
// has to know which side of the line a type landed on.
@_exported import SZPages
