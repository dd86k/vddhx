# CHANGELOG

Changelog file for vddhx with newest tags first.

Rules:
- Separated by change type: Added, Changed, Fixed, and Removed.
- Entries may lead with the area in bold, e.g. "**Omnibar**: ...", when it helps.
- Keep things simple and easy to read, long technical topics best left in source.
- Better to keep entries closest to the actual intent: "Bookmarks survive closing
  the tab" is clearer than "Bookmarks are written to a sidecar file".

## Unreleased

### Added

- **Bookmarks**: "Bookmark All Matches..." command.
  Search data and mark new bookmarks using a pattern. Esc cancels it.
- **Bookmarks**: "Save Bookmarks..." and "Load Bookmarks...", in ddhx's format.
  Names are kept.
- "Replace..." and "Insert..." commands with their Range equivalent.
  Same syntax as ddhx.
- **Settings**: Add `writemode readonly`.
- Decimal and octal offsets: "Offset Format..." per view, `address` in Settings.
  Same values as ddhx.

## v0.1.1

### Added

- **Logging**: each session writes a log file, the previous one kept as
  `vddhx.log.old`. Help > About links to its folder, and the README lists
  where it and `.vddhxrc` live.
- `--trace` logs everything, SDL's own messages included. `--verbose` is now
  listed in `--help`.

### Changed

- SDL's warnings and errors now show up in vddhx's log.
- Failed actions (save, paste, undo...) are logged as errors; routine ones
  (goto, copy, paste) only with `--verbose`.

### Fixed

- **Packaging**: fix "CPU ISA level is lower than required" by trimming
  the `.note.gnu.property` for DEB and RPM packages.
- Closing a tab releases every file it held open, not just the first.

## v0.1.0

First release of vddhx, a graphical port of the ddhx hex editor. It runs on
SDL3 and ddui and uses the same document core as ddhx, so large files and
devices stay cheap to open and scroll.

### Highlights

- **Tabs and splits**: several documents and several views of each. Drag tabs
  between panes or onto a pane's edge to split it. An edit made in one view
  shows in all of them.
- **ddhx syntax**: goto (0x1f40, +16, %50) and find patterns (utf8:,
  x:, u32:, f64:, ? and * wildcards, ranges) are read by ddhx's own
  parser.
- **Omnibar** (Ctrl+E): one box for views, commands (>), offsets (:),
  find (/), the inspector (=), bookmarks (@), structure fields (#) and
  shortcuts (?).
- **Colouring**: bytes are coloured by class under the chosen character set
  (ASCII, CP437, EBCDIC, Mac OS Roman, Latin-1, Windows-1252). A minimap
  shows the same colours plus bookmark and diff marks.
- **Structure overlay**: PNG files get their fields coloured and named, a
  breadcrumb trail, and a "go to field" list.
- **Editing**: overwrite and insert modes, undo/redo, hex and text copy/cut,
  skip or select a run of identical bytes in one keystroke.
- **Bookmarks** (named or not), an inspector for the bytes at the caret, and a
  per-document byte order setting.
- **Compare**: synced scrolling and highlighted differences between two
  documents.
- **Disks**: lists drives and partitions on Windows and Linux, opens them
  read-only, and asks for elevation (UAC, pkexec) only when needed. vddhx
  itself never runs privileged.
- **Settings** (Edit > Settings): opens as a tab. Defaults for new tabs and
  window options apply and save at once, to a .vddhxrc in ddhx's syntax.

### Known limitations

- Offsets are shown in hex only.
- Bookmarks are not saved; they are lost when the tab closes.
- Compare goes strictly byte for byte by offset, so it does not realign after
  an insertion.
- The structure overlay only understands PNG so far.
