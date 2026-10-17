# CHANGELOG

Changelog file for vddhx with newest tags first.

Rules:
- Separated by change type: Added, Changed, Fixed, and Removed.
- Entries may lead with the area in bold, e.g. "**Omnibar**: ...", when it helps.
- Keep things simple and easy to read, long technical topics best left in source.
- Better to keep entries closest to the actual intent: "Bookmarks survive closing
  the tab" is clearer than "Bookmarks are written to a sidecar file".

## Upcoming

### Fixed

- **Packaging**: fix "CPU ISA level is lower than required" by trimming
  the `.note.gnu.property` for DEB and RPM packages.

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
