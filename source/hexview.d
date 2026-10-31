/// Hex panel widget for ddui: offset, hex and text columns in a monospace face.
///
/// Uses a ddui panel for clipping and wheel routing, but scrolls in rows (pixel
/// offsets overflow on multi-gigabyte files) and draws rows manually, touching
/// only visible bytes.
/// Authors: dd86k <dd@dax.moe>
module hexview;

import ddui;
import core.time : MonoTime, msecs;

/// Caret key bits, above ddui's MU_KEY_* (to 1 << 5) so both share
/// ctx.key_down. Mapped by main.d. Bitmask to match ddui's key input.
enum
{
    HEX_KEY_LEFT  = (1 << 6),   // @suppress(dscanner.style.undocumented_declaration)
    HEX_KEY_RIGHT = (1 << 7),   // @suppress(dscanner.style.undocumented_declaration)
    HEX_KEY_UP    = (1 << 8),   // @suppress(dscanner.style.undocumented_declaration)
    HEX_KEY_DOWN  = (1 << 9),   // @suppress(dscanner.style.undocumented_declaration)
    HEX_KEY_HOME  = (1 << 10),  // @suppress(dscanner.style.undocumented_declaration)
    HEX_KEY_END   = (1 << 11),  // @suppress(dscanner.style.undocumented_declaration)
    HEX_KEY_PGUP  = (1 << 12),  // @suppress(dscanner.style.undocumented_declaration)
    HEX_KEY_PGDN  = (1 << 13),  // @suppress(dscanner.style.undocumented_declaration)
    HEX_KEY_INS   = (1 << 14),  // @suppress(dscanner.style.undocumented_declaration)
    HEX_KEY_DEL   = (1 << 15),  // @suppress(dscanner.style.undocumented_declaration)
    HEX_KEY_UNDO  = (1 << 16),  // @suppress(dscanner.style.undocumented_declaration)
    HEX_KEY_REDO  = (1 << 17),  // @suppress(dscanner.style.undocumented_declaration)
}

/// Caret move queued by hex_move, run on the panel's next frame.
enum HexMove
{
    none,       /// Nothing queued.
    left,       /// Back a nibble when editing, else a byte.
    right,      /// Forward a nibble when editing, else a byte.
    up,         /// Up a row.
    down,       /// Down a row.
    home,       /// Row start.
    end,        /// Row end.
    top,        /// First byte.
    bottom,     /// Last byte, or the append slot.
    pageUp,     /// Up a screen.
    pageDown,   /// Down a screen.
    viewUp,     /// Scroll up a row, caret stays.
    viewDown,   /// Scroll down a row, caret stays.
}

/// Number base of the offset column and lane headers.
enum HexBase { hex, dec, oct }

/// Digit radix of `base`.
uint hex_radix(HexBase base)
{
    final switch (base)
    {
    case HexBase.hex: return 16;
    case HexBase.dec: return 10;
    case HexBase.oct: return 8;
    }
}

/// Glyph colour for the byte at `offset`. `value` saves a buffer read;
/// `user` is HexView.colorUser.
alias HexColorFn = mu_Color function(size_t offset, ubyte value, void* user);

/// Background for the byte at `offset` (`user`: HexView.backUser), alpha 0 for
/// none. Same-colour runs draw as one band.
///
/// Separate from HexColorFn: foreground is what a byte is, background is what
/// was done to it (marked, found).
alias HexBackFn = mu_Color function(size_t offset, ubyte value, void* user);

/// Ditto for a minimap span: wash for `length` bytes from `at`, alpha 0 if none.
/// Needed since cells may cover gigabytes and sampling would miss short marks.
alias HexBackSpanFn = mu_Color function(long at, long length, void* user);

/// Text lane: characters for `value`, empty to draw a dot. `user` is
/// HexView.textUser. A slice since single-byte sets reach beyond ASCII (CP437,
/// EBCDIC) and encode as several UTF-8 bytes.
alias HexTextFn = const(char)[] function(ubyte value, void* user);

/// A structure field or record the panel draws a border around, as returned
/// by HexSpanFn. Not the selection.
struct HexSpan
{
    /// Absolute document offset (not shifted by baseAddress). Cells with the
    /// same start share one border.
    long start;
    long length;    /// In bytes.
    mu_Color edge;  /// Border colour.
}

/// Structure hook: span covering `pos` at `level`, counted from the outermost
/// (0: top-level record), or false. `user` is HexView.spanUser.
///
/// Counted from the top so all bytes of a record share a border regardless of
/// depth. Returns an extent, not a colour: adjacent same-kind fields are still
/// separate boxes; cells join only when their spans start at the same place.
/// Offset-only, so rows above and below can be queried to merge multi-row
/// spans.
alias HexSpanFn = bool function(long pos, int level, ref HexSpan span, void* user);

/// On-demand byte source: fill `buf` from `pos`, return what was read (short at
/// EOF). `user` is HexView.readUser. When set, only visible rows are read and
/// `data` is ignored.
alias HexReadFn = ubyte[] function(long pos, ubyte[] buf, void* user);

/// Overwrite the byte at `pos`. With insertFn and removeFn, makes a HexView
/// editable. `user` is HexView.writeUser.
alias HexReplaceFn = void function(long pos, ubyte value, void* user);

/// Insert a byte at `pos`.
alias HexInsertFn = void function(long pos, ubyte value, void* user);

/// Remove `len` bytes at `pos`.
alias HexRemoveFn = void function(long pos, long len, void* user);

/// Step edit history; returns the touched offset (undo: region start, redo: its
/// end) for the caret, or -1 if nothing left.
alias HexUndoFn = long function(void* user);
/// Ditto.
alias HexRedoFn = long function(void* user);

private enum
{
    MINIMAP_WIDTH = 16,         // pixels
    MINIMAP_BLOCK = 3,          // pixels per cell
    MINIMAP_PROBE = 256,        // bytes sampled per cell
    MINIMAP_VIEW_MIN = 14,      // min viewport marker height
    MINIMAP_VIEW_OUT = 2,       // marker overhang per side
    SCROLLBAR_WIDTH = 14,       // plain scrollbar (minimap off)
    SCROLLBAR_THUMB_MIN = 24,   // min thumb height
    WASH_EDGE_LIFT = 200,       // wash outline brightness, percent
    SPAN_PAD = 1,               // border inset, so it boxes the cells instead of looking like a gridline
    MARGIN_HEX  = 2,            // hex cell bleed
    MARGIN_TEXT = 1,            // text cell bleed
                                // NOTE: 2 leaves a visible gap where lines overlap
}

/// Selection wash, grid and minimap. Highest priority: see hex_draw_row.
enum mu_Color HEX_SEL_WASH = mu_Color(48, 84, 140, 255);

/// Max row width, drawn or auto-fitted.
enum int HEX_COLUMNS_MAX = 256;

/// Panel state and config. Persist across frames; data and options may change
/// per frame.
struct HexView
{
    /// Displayed bytes when readFn is null.
    const(ubyte)[] data;
    /// Number of elements (usually bytes) per row.
    int columns = 16;
    /// Fit `columns` to the panel width. The result is written to `columns`, so
    /// caret math between frames still works.
    bool autoColumns;
    /// Address of the first byte, for showing file offsets of a slice.
    long baseAddress;
    /// Minimum offset digits; widened as needed.
    int offsetDigits = 8;
    /// Base of the offset column and lane headers. Bytes stay hex.
    HexBase offsetBase;
    /// Minimap ribbon; false shows a plain scrollbar instead. Read per frame.
    bool minimap = true;

    /// Caret, the moving end of the selection.
    size_t cursor;
    /// Fixed end. Selection is [anchor, cursor].
    size_t anchor;
    /// Caret exists; set on the first click or key.
    bool active;

    /// Take keyboard focus on the next draw (after opening a file or switching
    /// tabs outside a frame). Cleared once done.
    bool takeFocus;

    /// Move queued by hex_move. One per frame, the last one wins.
    HexMove move;
    /// Queued move keeps the anchor.
    bool moveExtend;

    /// Optional per-byte colour scheme. Null falls back to hex_classify.
    HexColorFn colorFn;
    /// Opaque pointer forwarded to colorFn.
    void* colorUser;

    /// Optional per-byte background wash, drawn under the glyphs. See HexBackFn.
    HexBackFn backFn;
    /// Minimap form of backFn; null leaves the ribbon class-coloured.
    HexBackSpanFn backSpanFn;
    /// Opaque pointer forwarded to both background hooks.
    void* backUser;

    /// Optional: printable ASCII, dots for the rest.
    HexTextFn textFn;
    /// Opaque pointer forwarded to textFn.
    void* textUser;
    /// Text lane header, the charset name.
    const(char)[] textLabel = "ascii";

    /// See HexSpanFn.
    HexSpanFn spanFn;
    /// Opaque pointer forwarded to spanFn.
    void* spanUser;
    /// Bordered nesting levels from the outermost; 0 for none. More than 1 just
    /// makes a grid of the grid.
    int spanDepth = 1;

    /// See HexReadFn.
    HexReadFn readFn;
    /// Opaque pointer forwarded to readFn.
    void* readUser;
    /// Owner's edit counter; the cached window is reread when it or the scroll
    /// changes. Null: reread every frame.
    const(uint)* revision;
    /// Document size, with readFn. Updated by the panel's own edits so it's
    /// consistent within the frame.
    long dataSize;

    /// Write hooks; all three make the panel editable (hex digits, Backspace/
    /// Delete, Insert toggles mode). Addressed by document offset, so editing
    /// requires readFn.
    HexReplaceFn replaceFn;
    /// Ditto.
    HexInsertFn insertFn;
    /// Ditto.
    HexRemoveFn removeFn;
    /// Data pointer for the write and undo hooks.
    void* writeUser;

    /// Undo/Redo hooks for Ctrl+Z / Ctrl+Y (Ctrl+Shift+Z), caret follows. Takes writeUser.
    HexUndoFn undoFn;
    /// Ditto.
    HexRedoFn redoFn;

    /// Insert splices bytes in; overwrite (default) edits in place.
    bool insertMode;

    /// Refuse edits. The caret can still move.
    bool readOnly;

    /// Ignore all pointer and key input except the wheel.
    bool locked;

    /// Byte under the pointer this frame, or -1. Set by hex_view. Only one panel
    /// can be hovered.
    long hoverByte = -1;

    private:

    // First visible row. Rows, not pixels: the pixel height overflows int on
    // large files. Owned by hex_view.
    long topRow;
    // Sub-row wheel remainder.
    int wheelAccum;
    // Horizontal scroll of the byte lanes, in glyphs so the edge never splits
    // one. The offset column stays pinned.
    int leftCol;
    int wheelAccumX;
    // Rows that fit, measured per frame; for hex_set_caret scrolling between
    // frames.
    int visRows = 1;
    // Row area top and row height, for callers measuring overlap in pixels.
    int bodyY;
    int rowHeight = 1;
    // Visible glyph columns and their layout, for hex_reveal between frames.
    int visCols = int.max;
    HexLayout gridLay;
    // Last grid width minus scrollbar, for auto columns. 0 until measured.
    int bodyW;

    // Next hex digit is the low nibble; reset on caret moves. editByte holds the
    // high nibble's result.
    bool editLow;
    ubyte editByte;

    // Button went down inside this grid. Focus alone isn't enough: it can arrive
    // between frames (takeFocus) while a button is held for something else (tab
    // drag).
    bool dragSel;
    // Edge scrolling during a drag: rows owed and last update, clock-paced.
    double edgeRows = 0;
    MonoTime edgeAt;

    // Visible window read through readFn, refilled per frame.
    ubyte[] windowBuf;   // kept across frames
    size_t windowStart;  // document offset of windowBuf[0]
    size_t windowLen;    // valid bytes
    uint windowRev;      // *revision at fill
    void* windowUser;    // readUser at fill

    // Minimap cell colours (dominant class per segment). Rebuilt only on size or
    // cell count change.
    mu_Color[] mapCells;
    size_t mapForSize;   // size at build
    int mapForCells;     // cell count at build
    ubyte[] mapProbe;    // sampling scratch
}

/// Copy a panel for a split view: caret, selection, scroll, columns and mode
/// carry over. Per-frame scratch buffers are dropped (sharing them would mix
/// the panels' reads). Hooks keep the source's user pointers; repoint them
/// before drawing.
HexView hex_split(ref HexView src)
{
    HexView v = src;

    v.windowBuf   = null;
    v.windowStart = 0;
    v.windowLen   = 0;

    v.mapCells    = null;
    v.mapForSize  = 0;
    v.mapForCells = 0;
    v.mapProbe    = null;

    return v;
}

unittest
{
    HexView a;
    a.cursor = 0x40;
    a.anchor = 0x30;
    a.active = true;
    a.columns = 24;
    a.insertMode = true;
    a.topRow = 9;
    a.windowBuf = new ubyte[64];
    a.windowLen = 64;
    a.mapCells = new mu_Color[8];
    a.mapForCells = 8;

    HexView b = hex_split(a);

    assert(b.cursor == 0x40);
    assert(b.anchor == 0x30);
    assert(b.active);
    assert(b.columns == 24);
    assert(b.insertMode);
    assert(b.topRow == 9);

    // Scratch isn't shared...
    assert(b.windowBuf is null);
    assert(b.windowLen == 0);
    assert(b.mapCells is null);
    assert(b.mapForCells == 0);

    // ...and the source keeps its own.
    assert(a.windowBuf.length == 64);
    assert(a.mapCells.length == 8);
}

/// Whether a drag is edge-scrolling; the loop must keep drawing.
bool hex_edge_scrolling()
{
    return edgeLast != MonoTime.init && MonoTime.currTime - edgeLast < 100.msecs;
}

/// Scroll to the top. Call on loading a document so the caret isn't stranded.
void hex_reset_scroll(ref HexView v)
{
    v.topRow     = 0;
    v.wheelAccum = 0;
    v.leftCol     = 0;
    v.wheelAccumX = 0;
}

/// Offset of the first visible byte. For syncing panels (diff); offsets, since
/// panels may differ in columns.
long hex_top_offset(ref const(HexView) v)
{
    int cols = v.columns > 0 ? v.columns : 16;
    return v.topRow * cols;
}

/// Scroll so the row holding `offset` is on top (rounded down to the row),
/// dropping pending wheel movement. Unclamped; the next frame clamps it.
void hex_set_top_offset(ref HexView v, long offset)
{
    int cols = v.columns > 0 ? v.columns : 16;
    v.topRow     = offset > 0 ? offset / cols : 0;
    v.wheelAccum = 0;
}

unittest
{
    HexView v;
    v.columns = 16;
    v.topRow = 4;
    assert(hex_top_offset(v) == 0x40);

    hex_set_top_offset(v, 0x100);
    assert(v.topRow == 16);
    assert(hex_top_offset(v) == 0x100);

    // Mid-row offset: its row goes on top (0x10a -> 0x100).
    hex_set_top_offset(v, 0x10a);
    assert(hex_top_offset(v) == 0x100);

    v.wheelAccum = 7;
    hex_set_top_offset(v, 0x200);
    assert(v.wheelAccum == 0);

    // Negative: top.
    hex_set_top_offset(v, -32);
    assert(v.topRow == 0);

    // Panels of different widths agree on the byte: row 16 in one, 8 in the other.
    HexView wide;
    wide.columns = 32;
    hex_set_top_offset(wide, hex_top_offset(v) + 0x100);
    assert(wide.topRow == 8);
    assert(hex_top_offset(wide) == 0x100);
}

/// Byte count: editor size or slice length.
size_t hex_total(ref const(HexView) v)
{
    if (v.readFn)
        return v.dataSize > 0 ? cast(size_t) v.dataSize : 0;
    return v.data.length;
}

// Byte at an offset, from the window or slice. Outside the window reads 0.
private ubyte hex_byte(ref const(HexView) v, size_t idx)
{
    if (v.readFn)
    {
        size_t off = idx - v.windowStart;
        return off < v.windowLen ? v.windowBuf[off] : 0;
    }
    return v.data[idx];
}

/// Lowest selected index (== highest for a bare caret).
size_t hex_sel_low(ref const(HexView) v)
{
    return v.cursor < v.anchor ? v.cursor : v.anchor;
}

size_t hex_sel_high(ref const(HexView) v)
{
    return v.cursor > v.anchor ? v.cursor : v.anchor;
}

/// Hex digit value 0-15, or -1. Public for callers parsing hex (paste).
int hex_nibble(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

unittest
{
    assert(hex_nibble('0') == 0);
    assert(hex_nibble('9') == 9);
    assert(hex_nibble('a') == 10);
    assert(hex_nibble('f') == 15);
    assert(hex_nibble('A') == 10);
    assert(hex_nibble('F') == 15);
    assert(hex_nibble('g') == -1);
    assert(hex_nibble('/') == -1);
    assert(hex_nibble(' ') == -1);
}

/// Collapse the selection to `pos` and scroll to it. For outside changes
/// (paste). Set dataSize first.
void hex_set_caret(ref HexView v, size_t pos)
{
    size_t total = hex_total(v);
    if (pos > total) // append slot is valid
        pos = total;
    v.cursor  = pos;
    v.anchor  = pos;
    v.active  = true;
    v.editLow = false; // cancels a half-typed byte
    hex_reveal(v, pos, v.columns > 0 ? v.columns : 16, v.visRows);
}

/// Ditto, keeping the anchor so the selection extends (Shift chords handled
/// outside).
void hex_extend_caret(ref HexView v, size_t pos)
{
    size_t total = hex_total(v);
    if (pos > total)
        pos = total;
    v.cursor  = pos;
    v.active  = true;
    v.editLow = false;
    hex_reveal(v, pos, v.columns > 0 ? v.columns : 16, v.visRows);
}

/// Queue caret move `m` for the next frame, keeping the anchor if `extend`.
/// Takes keyboard focus. For key bindings, which run outside a frame.
void hex_move(ref HexView v, HexMove m, bool extend)
{
    v.move = m;
    v.moveExtend = extend;
    v.takeFocus = true;
}

/// Move for the panel's own arrow keys in `keys` (HEX_KEY_* bits), Ctrl held
/// if `ctrl`. First match only.
HexMove hex_key_move(int keys, bool ctrl)
{
    if (keys & HEX_KEY_UP)    return ctrl ? HexMove.viewUp : HexMove.up;
    if (keys & HEX_KEY_DOWN)  return ctrl ? HexMove.viewDown : HexMove.down;
    if (keys & HEX_KEY_PGUP)  return HexMove.pageUp;
    if (keys & HEX_KEY_PGDN)  return HexMove.pageDown;
    if (keys & HEX_KEY_HOME)  return ctrl ? HexMove.top : HexMove.home;
    if (keys & HEX_KEY_END)   return ctrl ? HexMove.bottom : HexMove.end;
    if (keys & HEX_KEY_LEFT)  return HexMove.left;
    if (keys & HEX_KEY_RIGHT) return HexMove.right;
    return HexMove.none;
}


/// Scroll row, to save and restore (omnibar browsing). Clamped on next draw.
long hex_top(ref const(HexView) v)
{
    return v.topRow;
}
/// Ditto.
void hex_set_top(ref HexView v, long row)
{
    v.topRow = row;
}

/// Centre `pos`'s row in the part of the panel below window y `coversTo` (a
/// floating box over the grid). hex_set_caret scrolls minimally, which can land
/// under the box.
void hex_center(ref HexView v, size_t pos, int coversTo = 0)
{
    int hidden;
    if (v.rowHeight > 0 && coversTo > v.bodyY)
        hidden = (coversTo - v.bodyY + v.rowHeight - 1) / v.rowHeight;

    int rows = v.visRows - hidden;
    if (rows < 1) // mostly covered: use what's left
        rows = 1;

    int cols = v.columns > 0 ? v.columns : 16;
    v.topRow = cast(long)(pos / cols) - hidden - rows / 2;
    if (v.topRow < 0)
        v.topRow = 0;
}

unittest
{
    HexView v;
    v.columns = 16;
    v.visRows = 20;
    v.bodyY = 100;
    v.rowHeight = 10; // panel from y=100 to 300

    // Uncovered: row 50 goes 10 rows down (middle of 20).
    hex_center(v, 50 * 16);
    assert(v.topRow == 40);
    hex_center(v, 50 * 16, 90); // box above the grid covers nothing
    assert(v.topRow == 40);

    // Half covered: middle of the remaining half (10 hidden, then 5).
    hex_center(v, 50 * 16, 200);
    assert(v.topRow == 35);

    // Partially covered rows count as hidden.
    hex_center(v, 50 * 16, 190);
    assert(v.topRow == 36);
    hex_center(v, 50 * 16, 191);
    assert(v.topRow == 35);

    // Near the top: no scroll.
    hex_center(v, 3 * 16);
    assert(v.topRow == 0);

    // Fully covered: last sliver.
    hex_center(v, 50 * 16, 300);
    assert(v.topRow == 30);
}

unittest
{
    HexView v;
    v.cursor = 5;
    v.anchor = 2;
    assert(hex_sel_low(v) == 2);
    assert(hex_sel_high(v) == 5);

    v.cursor = 3;
    v.anchor = 9;
    assert(hex_sel_low(v) == 3);
    assert(hex_sel_high(v) == 9);

    // Bare caret: low == high.
    v.cursor = 7;
    v.anchor = 7;
    assert(hex_sel_low(v) == 7);
    assert(hex_sel_high(v) == 7);
}

/// Default colours by ASCII class: dim zeros, bright printable, controls
/// distinct from non-ASCII. Other encodings supply their own colorFn.
mu_Color hex_classify(size_t offset, ubyte value, void* user)
{
    if (value == 0)
        return mu_Color(90, 90, 100, 255);         // zero
    if (value >= 0x20 && value < 0x7f)
        return mu_Color(220, 220, 220, 255);        // printable
    if (value == '\t' || value == '\n' || value == '\r')
        return mu_Color(120, 170, 200, 255);        // whitespace
    if (value < 0x20 || value == 0x7f)
        return mu_Color(200, 130, 90, 255);         // control, DEL
    return mu_Color(150, 190, 130, 255);            // >= 0x80
}

unittest
{
    assert(hex_coleq(hex_classify(0, 0, null),    mu_Color(90, 90, 100, 255)));
    assert(hex_coleq(hex_classify(0, 'A', null),  mu_Color(220, 220, 220, 255)));
    assert(hex_coleq(hex_classify(0, '\n', null), mu_Color(120, 170, 200, 255)));
    assert(hex_coleq(hex_classify(0, 0x01, null), mu_Color(200, 130, 90, 255)));
    assert(hex_coleq(hex_classify(0, 0x7f, null), mu_Color(200, 130, 90, 255)));  // DEL
    assert(hex_coleq(hex_classify(0, 0x80, null), mu_Color(150, 190, 130, 255)));
}

/// Draw and handle a hex panel.
///
/// Takes a header row and a fill row from the layout; needs a bounded height.
/// `font`: monospace TTF_Font*. `reserveBottom`: pixels kept free below for a
/// status bar (0 fills).
/// Returns: MU_RES_CHANGE if the selection moved, else 0.
int hex_view(mu_Context* ctx, const(char)* name, ref HexView v, mu_Font font,
    int reserveBottom = 0)
{
    // Monospace: "0" gives the advance.
    int charW = ctx.text_width(font, "0", 1);
    int rowH  = ctx.text_height(font);
    if (charW <= 0) charW = 1;
    if (rowH  <= 0) rowH  = 1;

    size_t total = hex_total(v);

    // Auto columns use last frame's width: the header is laid out before the body
    // and both need the same count, so resizes lag a frame. Fitted with the widest
    // offset (last byte), so it can't overflow.
    if (v.autoColumns && v.bodyW > 0)
        v.columns = hex_fit_columns(v.bodyW, charW,
            hex_fit_digits(cast(ulong)(v.baseAddress + total), v.offsetDigits,
                v.offsetBase));

    int cols = v.columns > 0 ? v.columns : 16;
    long rows  = (cast(long) total + cols - 1) / cols;

    // Widen for the last row's offset, else large offsets lose digits.
    long lastRowOff = v.baseAddress + (rows > 0 ? (rows - 1) * cols : 0);
    int offsetDigits = hex_fit_digits(cast(ulong) lastRowOff, v.offsetDigits, v.offsetBase);

    HexLayout lay = hex_layout(offsetDigits, cols, charW);

    // Header above the scroll area. Filled now, before the panel (whose border
    // overlaps by a pixel), labelled after it since input can scroll sideways this
    // frame. Uses the panel canvas colour; a transparent fill shows the window.
    int head = -1;
    mu_layout_row(ctx, 1, &head, rowH);
    mu_Rect headRect = mu_layout_next(ctx);
    mu_draw_rect(ctx, headRect, ctx.style.colors[MU_COLOR_PANELBG]);

    // Negative height fills to the floor; minus reserveBottom and spacing leaves
    // the band free.
    int fill = -1;
    int panelH = reserveBottom > 0 ? -(reserveBottom + ctx.style.spacing + 1) : -1;
    mu_layout_row(ctx, 1, &fill, panelH);

    int res = 0;

    // ddui scroll is 32-bit pixels, which overflows on large files. So NOSCROLL,
    // with our own strip: minimap or plain thumb.
    mu_begin_panel_ex(ctx, name, MU_OPT_NOSCROLL);
    {
        mu_Container* cnt = mu_get_current_container(ctx);
        mu_Rect body_ = cnt.body_;

        int visibleRows = body_.h / rowH;
        if (visibleRows < 1) visibleRows = 1;
        // Editable with a full last row: the append slot needs its own row.
        long scrollRows = hex_editable(v) ? cast(long) total / cols + 1 : rows;
        long maxTop = scrollRows > visibleRows ? scrollRows - visibleRows : 0;
        v.visRows = visibleRows; // for hex_set_caret
        v.bodyY = body_.y;
        v.rowHeight = rowH;

        int stripW = v.minimap ? MINIMAP_WIDTH : SCROLLBAR_WIDTH;
        mu_Rect strip = mu_Rect(body_.x + body_.w - stripW, body_.y, stripW, body_.h);
        body_.w -= stripW;
        v.bodyW = body_.w; // for next frame's auto columns

        // NOSCROLL: re-arm the wheel target while hovered. ddui still folds the delta
        // into cnt.scroll.y; drained into rows here.
        if (mu_mouse_over(ctx, cnt.body_))
            ctx.scroll_target = cnt;
        if (cnt.scroll.y != 0)
        {
            v.wheelAccum += cnt.scroll.y;
            cnt.scroll.y = 0;
        }
        long wheelRows = v.wheelAccum / rowH;
        if (wheelRows != 0)
        {
            v.topRow += wheelRows;
            v.wheelAccum -= cast(int)(wheelRows * rowH);
        }
        v.topRow = mu_clamp(v.topRow, 0L, maxTop);

        if (cnt.scroll.x != 0)
        {
            v.wheelAccumX += cnt.scroll.x;
            cnt.scroll.x = 0;
        }
        v.leftCol += v.wheelAccumX / charW;
        v.wheelAccumX %= charW;
        v.visCols = body_.w / charW;
        v.gridLay = lay;
        int maxLeft = mu_max(0, lay.totalCols - v.visCols);
        v.leftCol = mu_clamp(v.leftCol, 0, maxLeft);

        // Input may reveal the caret, moving topRow/leftCol; re-clamp.
        res = hex_input(ctx, name, v, lay, body_, rowH, cols, visibleRows);
        v.topRow = mu_clamp(v.topRow, 0L, maxTop);
        v.leftCol = mu_clamp(v.leftCol, 0, maxLeft);

        hex_fill_window(v, body_, v.topRow, rowH, cols);
        hex_paint(ctx, v, lay, body_, v.topRow, rowH, cols, font);

        if (v.minimap)
            hex_minimap(ctx, v, strip, v.topRow, maxTop, rows, visibleRows);
        else
            hex_plainbar(ctx, v, strip, v.topRow, maxTop, rows, visibleRows);

        mu_end_panel(ctx);
    }

    // Same strip width as the panel, so they agree on the last column.
    hex_header(ctx, v, lay, headRect, font, v.minimap ? MINIMAP_WIDTH : SCROLLBAR_WIDTH);

    return res;
}

private:

// Grid geometry in glyph columns, for hit-testing and drawing: offset, two
// spaces, hex pairs (space between, extra every 8), two spaces, text.
struct HexLayout
{
    int offsetDigits;
    int hexStart;
    int asciiStart;
    int totalCols;  // for content_size.x
    int charW;      // cached
}

// Digits for `maxOffset` in `base`, at least `min`. Max is 22 (octal
// ulong.max), which the offset buffer in hex_draw_row fits.
int hex_fit_digits(ulong maxOffset, int min, HexBase base = HexBase.hex)
{
    if (min <= 0) min = 8;
    uint radix = hex_radix(base);
    int digits = 1;
    for (ulong rest = maxOffset / radix; rest; rest /= radix)
        ++digits;
    return digits > min ? digits : min;
}

unittest
{
    assert(hex_fit_digits(0, 8) == 8);
    assert(hex_fit_digits(0xffffffff, 8) == 8);  // exactly 32 bits
    assert(hex_fit_digits(0x100000000, 8) == 9);
    assert(hex_fit_digits(ulong.max, 8) == 16);
    assert(hex_fit_digits(0xf, 1) == 1);
    assert(hex_fit_digits(0x10, 1) == 2);
    assert(hex_fit_digits(0xfff, 2) == 3);

    assert(hex_fit_digits(0, 0) == 8); // bad floor: 8
    assert(hex_fit_digits(0, -4) == 8);

    import std.conv : octal;
    assert(hex_fit_digits(99_999_999, 8, HexBase.dec) == 8);
    assert(hex_fit_digits(100_000_000, 8, HexBase.dec) == 9);
    assert(hex_fit_digits(ulong.max, 8, HexBase.dec) == 20);
    assert(hex_fit_digits(octal!77777777, 8, HexBase.oct) == 8);
    assert(hex_fit_digits(octal!100000000, 8, HexBase.oct) == 9);
    assert(hex_fit_digits(ulong.max, 8, HexBase.oct) == 22);
}

// Max columns fitting `availW` pixels, min 1. Inverse of hex_layout.
int hex_fit_columns(int availW, int charW, int offsetDigits)
{
    if (charW <= 0) charW = 1;
    if (offsetDigits <= 0) offsetDigits = 8;

    int best = 1;
    for (int cols = 1; cols <= HEX_COLUMNS_MAX; ++cols)
    {
        int need = offsetDigits + 4 + cols * 4 + (cols - 1) / 8;
        if (need * charW > availW)
            break;
        best = cols;
    }
    return best;
}

unittest
{
    // Result fits, one more overflows.
    static void fits(int availW, int charW, int digits)
    {
        int cols = hex_fit_columns(availW, charW, digits);
        assert(cols >= 1);
        assert(hex_layout(digits, cols, charW).totalCols * charW <= availW || cols == 1);
        if (cols < HEX_COLUMNS_MAX)
            assert(hex_layout(digits, cols + 1, charW).totalCols * charW > availW);
    }

    foreach (int w; [40, 100, 337, 640, 800, 1024, 1920])
        foreach (int cw; [7, 8, 11])
            fits(w, cw, 8);

    // 16 columns, 8-digit offset: 77 glyphs.
    assert(hex_fit_columns(77 * 8, 8, 8) == 16);
    assert(hex_fit_columns(77 * 8 - 1, 8, 8) == 15);

    // Wider offset: fewer bytes.
    assert(hex_fit_columns(77 * 8, 8, 16) < 16);

    // Too narrow: still 1 (clipped), no division by zero.
    assert(hex_fit_columns(0, 8, 8) == 1);
    assert(hex_fit_columns(-100, 8, 8) == 1);
    assert(hex_fit_columns(1000, 0, 8) >= 1);   // zero-width font

    // Capped.
    assert(hex_fit_columns(int.max, 1, 8) == HEX_COLUMNS_MAX);
}

HexLayout hex_layout(int offsetDigits, int cols, int charW)
{
    if (offsetDigits <= 0) offsetDigits = 8;
    HexLayout lay;
    lay.offsetDigits = offsetDigits;
    lay.charW = charW;
    lay.hexStart = offsetDigits + 2;
    // 3 glyphs per byte, plus a space per completed group of 8.
    int hexCols = cols * 3 + (cols - 1) / 8;
    lay.asciiStart = lay.hexStart + hexCols + 2;
    lay.totalCols = lay.asciiStart + cols;
    return lay;
}

// Glyph column of byte `i`'s hex pair.
int hex_col_for(ref const(HexLayout) lay, int i)
{
    return lay.hexStart + i * 3 + i / 8;
}

unittest
{
    HexLayout lay = hex_layout(8, 16, 1);
    assert(lay.offsetDigits == 8);
    assert(lay.hexStart == 10);          // 8 digits + 2
    assert(lay.asciiStart == 61);        // + 49 hex + 2
    assert(lay.totalCols == 77);         // + 16 text

    assert(hex_col_for(lay, 0) == 10);
    assert(hex_col_for(lay, 1) == 13);   // +3 per byte
    assert(hex_col_for(lay, 8) == 35);   // +1 group space after 8

    assert(hex_layout(0, 16, 1).offsetDigits == 8);
}

immutable char[16] HEX_DIGITS = "0123456789abcdef";

// `digits` chars of `value` in `base` into buf, most significant first.
void hex_format(char* buf, ulong value, int digits, HexBase base = HexBase.hex)
{
    uint radix = hex_radix(base);
    for (int i = digits - 1; i >= 0; --i)
    {
        buf[i] = HEX_DIGITS[value % radix];
        value /= radix;
    }
}

unittest
{
    char[16] buf = void;
    hex_format(buf.ptr, 0xdeadbeef, 8);
    assert(buf[0 .. 8] == "deadbeef");

    hex_format(buf.ptr, 0, 4);
    assert(buf[0 .. 4] == "0000"); // zero-padded

    hex_format(buf.ptr, 0x100000000UL, 9);
    assert(buf[0 .. 9] == "100000000");

    hex_format(buf.ptr, 0x100000000UL, 4);
    assert(buf[0 .. 4] == "0000"); // truncated to low nibbles

    hex_format(buf.ptr, 1234, 8, HexBase.dec);
    assert(buf[0 .. 8] == "00001234");

    hex_format(buf.ptr, 0x1ff, 4, HexBase.oct);
    assert(buf[0 .. 4] == "0777");
}

// Whether `chars` glyphs at `x` fit within `startX .. endX`. Text clipped
// mid-glyph is misleading, so partially visible labels are skipped. Rects are
// left to the clip.
bool hex_fits(int x, int chars, int charW, int startX, int endX)
{
    return x >= startX && x + chars * charW <= endX;
}

unittest
{
    assert(hex_fits(0, 2, 8, 0, 16));       // reaches the edge
    assert(hex_fits(0, 2, 8, 0, 15) == false);
    assert(hex_fits(100, 5, 8, 0, 200));
    assert(hex_fits(180, 5, 8, 0, 200) == false); // straddles
    assert(hex_fits(-8, 2, 8, 0, 200) == false);  // half scrolled off
}

// Dim column titles (offset, byte lanes) in `r`, the pre-filled header row.
// `stripW`: the scroll strip under the header; subtract it or the header
// labels a column the grid can't draw.
void hex_header(mu_Context* ctx, ref const(HexView) v, ref const(HexLayout) lay,
    mu_Rect r, mu_Font font, int stripW)
{
    mu_push_clip_rect(ctx, r);

    mu_Color dim = mu_Color(140, 140, 150, 255);
    int charW = lay.charW;

    int originX = r.x - v.leftCol * charW;
    int laneX = r.x + lay.hexStart * charW; // pinned offset title before it
    int endX = r.x + r.w - stripW;
    if (hex_fits(r.x, 6, charW, r.x, endX))
        mu_draw_text(ctx, font, "offset", 6, mu_Vec2(r.x, r.y), dim);

    int cols = v.columns > 0 ? v.columns : 16;
    char[2] cell = void;
    uint wrap = hex_radix(v.offsetBase) * hex_radix(v.offsetBase); // labels wrap at 2 digits
    for (int i; i < cols; ++i)
    {
        int x = originX + hex_col_for(lay, i) * charW;
        if (x + 2 * charW > endX)
            break; // past the edge
        if (hex_fits(x, 2, charW, laneX, endX) == false)
            continue;
        hex_format(cell.ptr, i % wrap, 2, v.offsetBase);
        mu_draw_text(ctx, font, cell.ptr, 2, mu_Vec2(x, r.y), dim);
    }

    // Text lane header shows the charset (its only display).
    const(char)[] label = v.textLabel.length ? v.textLabel : "ascii";
    int ax = originX + lay.asciiStart * charW;
    if (hex_fits(ax, cast(int) label.length, charW, laneX, endX))
        mu_draw_text(ctx, font, label.ptr, cast(int) label.length, mu_Vec2(ax, r.y), dim);

    mu_pop_clip_rect(ctx);
}

unittest
{
    // Real frames at widths cutting columns: no text may cross the pane edge.
    enum int CW = 8;
    static extern (C) int width(mu_Font f, const(char)* s, int len)
    {
        import core.stdc.string : strlen;
        return (len < 0 ? cast(int) strlen(s) : len) * CW;
    }
    static extern (C) int height(mu_Font f) { return 16; }

    static mu_Context ctx;
    mu_init(&ctx);
    ctx.text_width   = &width;
    ctx.text_height  = &height;
    ctx.style.padding = 0;
    ctx.style.spacing = 0;

    HexView v;
    v.data    = cast(const(ubyte)[]) "0123456789abcdef0123456789abcdef";
    v.columns = 16;
    HexLayout lay = hex_layout(8, 16, CW);

    // Header spans the strip; it must end before it.
    enum int STRIP = MINIMAP_WIDTH;

    // Count two-glyph draws on line `topY` (header labels, hex pairs) and check
    // all text stays in `startX .. endX`, lanes right of the pinned offset.
    int columnsOn(int topY, int startX, int endX)
    {
        int drawn, columns, pinned;
        mu_Command* cmd;
        while (mu_get_next_command(&ctx, &cmd))
        {
            if (cmd.type != MU_COMMAND_TEXT)
                continue;
            ++drawn;
            int w = width(null, mu_command_text(&ctx, cmd), -1);
            assert(cmd.text.pos.x >= startX);
            assert(cmd.text.pos.x + w <= endX);
            if (w == 2 * CW && cmd.text.pos.y == topY)
                ++columns;
            if (w == 2 * CW)
                assert(cmd.text.pos.x >= startX + lay.hexStart * CW);
            else if (cmd.text.pos.y == topY && cmd.text.pos.x == startX)
                ++pinned;
        }
        assert(drawn > 0); // else the checks pass vacuously
        assert(pinned == 1); // offset title or row offset, even scrolled
        return columns;
    }

    // Measure against the header row rect, not the window.
    mu_Rect headerRect(int paneW)
    {
        mu_Rect r;
        mu_begin(&ctx);
        if (mu_begin_window_ex(&ctx, "w", mu_Rect(0, 0, paneW, 400),
                MU_OPT_NOTITLE | MU_OPT_NORESIZE | MU_OPT_NOSCROLL | MU_OPT_NOFRAME))
        {
            int head = -1;
            mu_layout_row(&ctx, 1, &head, 16);
            r = mu_layout_next(&ctx);
            mu_end_window(&ctx);
        }
        mu_end(&ctx);
        return r;
    }

    // Also scrolled, by whole pairs and mid-pair.
    foreach (int leftCol; [0, 11, 13, 30])
    foreach (int paneW; [180, 260, 337, 400, 512, 640])
    {
        v.leftCol = leftCol;
        mu_Rect hr = headerRect(paneW);
        int endX = hr.x + hr.w - STRIP;

        mu_begin(&ctx);
        if (mu_begin_window_ex(&ctx, "w", mu_Rect(0, 0, paneW, 400),
                MU_OPT_NOTITLE | MU_OPT_NORESIZE | MU_OPT_NOSCROLL | MU_OPT_NOFRAME))
        {
            hex_header(&ctx, v, lay, hr, null, STRIP);
            mu_end_window(&ctx);
        }
        mu_end(&ctx);
        int headerCols = columnsOn(hr.y, hr.x, endX);

        mu_begin(&ctx);
        if (mu_begin_window_ex(&ctx, "w2", mu_Rect(0, 0, paneW, 400),
                MU_OPT_NOTITLE | MU_OPT_NORESIZE | MU_OPT_NOSCROLL | MU_OPT_NOFRAME))
        {
            hex_paint(&ctx, v, lay, mu_Rect(hr.x, 20, hr.w - STRIP, 200), 0, 16, 16, null);
            mu_end_window(&ctx);
        }
        mu_end(&ctx);
        int gridCols = columnsOn(20, hr.x, endX);

        // Header labels exactly the drawable columns.
        assert(headerCols > 0);
        assert(headerCols == gridCols);
    }
}

// Screen position to byte index, or -1. Hex and text columns are hittable.
// `snap` assigns the gap after a pair to it, for hover tracking (a third of
// the hex lane is gaps).
long hex_hit(ref const(HexLayout) lay, mu_Rect body, long topRow, int rowH,
    int cols, size_t total, int mx, int my, bool snap = false)
{
    int localX = mx - body.x;
    int localY = my - body.y;
    if (localX < 0 || localY < 0)
        return -1;

    long row = topRow + localY / rowH;
    int col = localX / lay.charW;

    int ai = col - lay.asciiStart;
    if (ai >= 0 && ai < cols)
        return hex_index(row, cols, ai, total);

    for (int i; i < cols; ++i)
    {
        int start = hex_col_for(lay, i);
        if (col == start || col == start + 1 || (snap && col == start + 2))
            return hex_index(row, cols, i, total);
    }
    return -1;
}

// hex_hit for clicks and drags, never missing: gaps take the left byte, the
// space before text the last pair, past EOF the last byte.
long hex_drag_hit(ref const(HexLayout) lay, mu_Rect body, long topRow, int rowH,
    int cols, size_t total, int mx, int my)
{
    int localY = my - body.y;
    if (localY < 0 || total == 0)
        return -1;

    long row = topRow + localY / rowH;
    int col = (mx - body.x) / lay.charW;

    int i;
    if (col >= lay.asciiStart)
        i = col - lay.asciiStart < cols ? col - lay.asciiStart : cols - 1;
    else
        while (i + 1 < cols && col >= hex_col_for(lay, i + 1))
            ++i;

    long idx = row * cols + i;
    return idx < cast(long) total ? idx : cast(long) total - 1;
}

unittest
{
    HexLayout lay = hex_layout(8, 16, 1);
    mu_Rect body = mu_Rect(0, 0, 200, 100);
    int gap = hex_col_for(lay, 3) + 2; // after pair 3
    assert(hex_hit(lay, body, 0, 1, 16, 100, gap, 2) == -1);
    assert(hex_drag_hit(lay, body, 0, 1, 16, 100, gap, 2) == 2 * 16 + 3);
    int group = hex_col_for(lay, 8) - 1; // group space after 8
    assert(hex_drag_hit(lay, body, 0, 1, 16, 100, group, 0) == 7);
    assert(hex_drag_hit(lay, body, 0, 1, 16, 100, 0, 0) == 0);              // offset column
    assert(hex_drag_hit(lay, body, 0, 1, 16, 100, lay.asciiStart - 1, 0) == 15);
    assert(hex_drag_hit(lay, body, 0, 1, 16, 100, lay.asciiStart + 99, 0) == 15);
    assert(hex_drag_hit(lay, body, 0, 1, 16, 100, gap, 50) == 99);          // past EOF
    assert(hex_drag_hit(lay, body, 0, 1, 16, 100, gap, -1) == -1);
}

// Last edge scroll time. A timestamp, so a panel no longer drawn mid-drag
// can't keep the loop running.
MonoTime edgeLast;

// Rows per second for a pointer `past` pixels beyond the grid, doubling every two rows.
double hex_edge_rate(int past, int rowH)
{
    import std.math : exp2;

    double rows = cast(double)(past < 0 ? -past : past) / rowH;
    return exp2(rows < 74 ? 3 + rows / 2 : 40.0);
}

unittest
{
    assert(hex_edge_rate(1, 20) > 8 && hex_edge_rate(1, 20) < 9);
    assert(hex_edge_rate(-40, 20) == 16);  // symmetric
    assert(hex_edge_rate(400, 20) == 8192);
    assert(hex_edge_rate(int.max, 1) == hex_edge_rate(int.min + 1, 1)); // capped
}

// Rows to scroll this frame, signed like `past`. The first frame starts the
// clock.
long hex_edge_scroll(ref HexView v, int past, int rowH)
{
    MonoTime now = MonoTime.currTime;
    edgeLast = now;
    if (v.edgeAt == MonoTime.init)
    {
        v.edgeAt = now;
        return 0;
    }
    // Don't catch up after stalls.
    double dt = (now - v.edgeAt).total!"usecs" / 1e6;
    if (dt > 0.1)
        dt = 0.1;
    v.edgeAt = now;

    v.edgeRows += hex_edge_rate(past, rowH) * dt;
    long n = cast(long) v.edgeRows;
    v.edgeRows -= n;
    return past < 0 ? -n : n;
}

void hex_edge_stop(ref HexView v)
{
    v.edgeAt = MonoTime.init;
    v.edgeRows = 0;
}

long hex_index(long row, int cols, int i, size_t total)
{
    if (row < 0)
        return -1;
    long idx = row * cols + i;
    if (idx >= cast(long) total)
        return -1;
    return idx;
}

unittest
{
    assert(hex_index(0, 16, 0, 100) == 0);
    assert(hex_index(1, 16, 2, 100) == 18);
    assert(hex_index(6, 16, 3, 100) == 99);  // last byte
    assert(hex_index(-1, 16, 0, 100) == -1);
    assert(hex_index(6, 16, 4, 100) == -1);  // past EOF
    assert(hex_index(10, 16, 0, 100) == -1);
}

// Mouse and keyboard. Returns MU_RES_CHANGE if the selection moved.
int hex_input(mu_Context* ctx, const(char)* name, ref HexView v,
    ref const(HexLayout) lay, mu_Rect body, int rowH, int cols, int visibleRows)
{
    mu_Id id = mu_get_id(ctx, name, cast(int) hex_strlen(name));
    // Claim focus from takeFocus before mu_update_control, or ddui drops it.
    if (v.takeFocus)
    {
        v.takeFocus = false;
        mu_set_focus(ctx, id);
    }
    // Hold focus after release; tab stop for keyboard access.
    mu_update_control(ctx, id, body, MU_OPT_HOLDFOCUS | MU_OPT_TABSTOP);

    // Taken every frame so a move queued while locked doesn't run later.
    HexMove queued = v.move;
    v.move = HexMove.none;

    // Release ends this panel's drag. Before the early returns below.
    if ((ctx.mouse_down & MU_MOUSE_LEFT) == 0)
        v.dragSel = false;
    if (v.dragSel == false)
        hex_edge_stop(v);

    if (v.locked)
    {
        v.hoverByte = -1;
        return 0;
    }

    int res = 0;
    size_t total = hex_total(v);
    bool editable = hex_editable(v);
    // Empty editable panels still take digits; only bail if read-only too.
    if (total == 0 && editable == false)
        return 0;

    // Editable: caret may sit on the append slot.
    long caretMax = editable ? cast(long) total : cast(long) total - 1;

    bool shift = (ctx.key_down & MU_KEY_SHIFT) != 0;

    // Press places the caret, drag extends. mu_mouse_over respects the clip
    // (scrollbar, header excluded). Drags require the press in this grid, not
    // focus: see HexView.dragSel. Hits are measured from the unscrolled origin,
    // except over the pinned offset column.
    mu_Rect grid = body;
    if (ctx.mouse_pos.x >= body.x + lay.hexStart * lay.charW)
        grid.x -= v.leftCol * lay.charW;
    v.hoverByte = mu_mouse_over(ctx, body) ?
        hex_hit(lay, grid, v.topRow, rowH, cols, total, ctx.mouse_pos.x, ctx.mouse_pos.y, true) :
        -1;

    if (ctx.mouse_pressed == MU_MOUSE_LEFT && mu_mouse_over(ctx, body))
    {
        v.dragSel = true; // owns the drag until release

        long hit = hex_drag_hit(lay, grid, v.topRow, rowH, cols, total,
            ctx.mouse_pos.x, ctx.mouse_pos.y);
        if (hit >= 0)
        {
            v.cursor = cast(size_t) hit;
            if (shift == false || v.active == false)
                v.anchor = v.cursor;
            v.active = true;
            v.editLow = false; // high nibble first
            res |= MU_RES_CHANGE;
        }
    }
    else if (v.dragSel && (ctx.mouse_down & MU_MOUSE_LEFT) && v.active)
    {
        // Dragged past top/bottom: scroll, caret rides the edge row.
        int top = body.y;
        int bottom = body.y + visibleRows * rowH - 1;
        int my = ctx.mouse_pos.y;
        int past = my < top ? my - top : my > bottom ? my - bottom : 0;
        if (past != 0)
        {
            v.topRow += hex_edge_scroll(v, past, rowH);
            if (v.topRow < 0)
                v.topRow = 0;
            my = mu_clamp(my, top, bottom);
        }
        else
            hex_edge_stop(v);

        long hit = hex_drag_hit(lay, grid, v.topRow, rowH, cols, total,
            ctx.mouse_pos.x, my);
        if (hit >= 0 && cast(size_t) hit != v.cursor)
        {
            v.cursor = cast(size_t) hit;
            v.editLow = false;
            res |= MU_RES_CHANGE;
        }
    }

    // Keyboard: a queued move (key bindings), else the panel's own arrow keys.
    // Shift keeps the anchor.
    HexMove move = queued;
    bool extend = v.moveExtend;
    if (move == HexMove.none && ctx.focus == id)
    {
        move = hex_key_move(ctx.key_pressed, (ctx.key_down & MU_KEY_CTRL) != 0);
        extend = shift;
    }
    if (move != HexMove.none && v.active)
    {
        long dst = cast(long) v.cursor;
        bool low = v.editLow;
        int page = mu_max(1, (visibleRows - 1) * cols);

        // Byte-wise moves reset to the high nibble.
        final switch (move)
        {
        case HexMove.none:     break;
        // Caret may go off screen. Caller re-clamps topRow.
        case HexMove.viewUp:   v.topRow -= 1; break;
        case HexMove.viewDown: v.topRow += 1; break;
        case HexMove.up:       dst -= cols; low = false; break;
        case HexMove.down:     dst += cols; low = false; break;
        case HexMove.pageUp:   dst -= page; low = false; break;
        case HexMove.pageDown: dst += page; low = false; break;
        case HexMove.home:     dst -= dst % cols; low = false; break;
        case HexMove.end:      dst += (cols - 1) - (dst % cols); low = false; break;
        case HexMove.top:      dst = 0; low = false; break;
        case HexMove.bottom:   dst = caretMax; low = false; break;
        // A nibble when editing, a byte when extending or read-only.
        case HexMove.left, HexMove.right:
            int step = move == HexMove.left ? -1 : 1;
            if (editable && extend == false)
            {
                // The append slot has only a high nibble: cap at caretMax * 2.
                long nib = mu_clamp(dst * 2 + (low ? 1 : 0) + step, 0L, caretMax * 2);
                dst = nib / 2;
                low = (nib & 1) != 0;
            }
            else
            {
                dst += step;
                low = false;
            }
            break;
        }

        dst = mu_clamp(dst, 0L, caretMax);
        if (cast(size_t) dst != v.cursor || low != v.editLow)
        {
            v.cursor  = cast(size_t) dst;
            v.editLow = low;
            if (extend == false)
                v.anchor = v.cursor;
            res |= MU_RES_CHANGE;
            hex_reveal(v, v.cursor, cols, visibleRows);
        }
    }

    if (editable && ctx.focus == id && v.active)
    {
        // Restart the byte's entry so the new mode applies cleanly.
        if (ctx.key_pressed & HEX_KEY_INS)
        {
            v.insertMode = v.insertMode == false;
            v.editLow = false;
        }

        // Delete/Backspace: the selection, else one byte.
        if (ctx.key_pressed & HEX_KEY_DEL)
        {
            hex_delete(v, false, cols, visibleRows);
            res |= MU_RES_CHANGE;
        }
        if (ctx.key_pressed & MU_KEY_BACKSPACE)
        {
            hex_delete(v, true, cols, visibleRows);
            res |= MU_RES_CHANGE;
        }

        for (const(char)* p = ctx.input_text.ptr; *p; ++p)
        {
            int nib = hex_nibble(*p);
            if (nib < 0)
                continue; // hex digits only; no text lane editing
            hex_edit_nibble(v, nib, cols, visibleRows);
            res |= MU_RES_CHANGE;
        }
    }

    // Ctrl+Z back, Ctrl+Y (Ctrl+Shift+Z) forward. The hooks update dataSize for
    // the clamp below.
    if (ctx.focus == id && v.active && (ctx.key_down & MU_KEY_CTRL) &&
        (v.undoFn || v.redoFn) && v.readOnly == false)
    {
        bool shiftHeld = (ctx.key_down & MU_KEY_SHIFT) != 0;
        bool undoKey = (ctx.key_pressed & HEX_KEY_UNDO) != 0;
        bool redoKey = (ctx.key_pressed & HEX_KEY_REDO) != 0;

        long at = -1;
        if (undoKey && shiftHeld == false && v.undoFn)
            at = v.undoFn(v.writeUser);
        else if ((redoKey || (undoKey && shiftHeld)) && v.redoFn)
            at = v.redoFn(v.writeUser);

        if (at >= 0)
        {
            size_t total2 = hex_total(v);
            if (cast(size_t) at > total2)
                at = cast(long) total2;
            v.cursor  = cast(size_t) at;
            v.anchor  = v.cursor;
            v.editLow = false;
            res |= MU_RES_CHANGE;
            hex_reveal(v, v.cursor, cols, visibleRows);
        }
    }

    return res;
}

// Whether all write hooks are set.
bool hex_editable(ref const(HexView) v)
{
    return v.readOnly == false && v.locked == false &&
        v.replaceFn && v.insertFn && v.removeFn;
}

// Apply a typed nibble at the caret, per mode. Keeps dataSize current.
void hex_edit_nibble(ref HexView v, int nib, int cols, int visibleRows)
{
    long pos = cast(long) v.cursor;

    if (v.editLow == false)
    {
        // Insert mode, empty document, or caret at EOF: insert a byte. Else overwrite,
        // keeping the low nibble.
        if (v.insertMode || v.cursor >= hex_total(v))
        {
            v.editByte = cast(ubyte)(nib << 4);
            v.insertFn(pos, v.editByte, v.writeUser);
            if (v.readFn) ++v.dataSize;
        }
        else
        {
            ubyte cur = hex_byte(v, v.cursor);
            v.editByte = cast(ubyte)((nib << 4) | (cur & 0x0f));
            v.replaceFn(pos, v.editByte, v.writeUser);
        }
        v.editLow = true;
    }
    else
    {
        // Low nibble: combine with the high, then advance.
        v.editByte = cast(ubyte)((v.editByte & 0xf0) | nib);
        v.replaceFn(pos, v.editByte, v.writeUser);
        v.editLow = false;
        if (cast(long) v.cursor + 1 <= cast(long) hex_total(v))
            ++v.cursor;
        v.anchor = v.cursor;
        hex_reveal(v, v.cursor, cols, visibleRows);
    }
}

// Delete the selection or one byte. `back`: Backspace, else Delete.
void hex_delete(ref HexView v, bool back, int cols, int visibleRows)
{
    size_t total = hex_total(v);
    if (total == 0)
        return;

    size_t low  = hex_sel_low(v);
    size_t high = hex_sel_high(v);

    if (low != high) // range: drop all
    {
        long len = cast(long)(high - low + 1);
        if (high >= total) len = cast(long) total - cast(long) low; // exclude the append slot
        v.removeFn(cast(long) low, len, v.writeUser);
        if (v.readFn) v.dataSize -= len;
        v.cursor = low;
    }
    else if (back)
    {
        if (v.cursor == 0)
            return;
        --v.cursor;
        v.removeFn(cast(long) v.cursor, 1, v.writeUser);
        if (v.readFn) --v.dataSize;
    }
    else // Delete
    {
        if (v.cursor >= total) // append slot: nothing to delete
            return;
        v.removeFn(cast(long) v.cursor, 1, v.writeUser);
        if (v.readFn) --v.dataSize;
    }

    v.anchor  = v.cursor;
    v.editLow = false;
    hex_reveal(v, v.cursor, cols, visibleRows);
}

// Scroll the caret into view after a keyboard move; hex_view re-clamps.
// Horizontally reveals the hex pair right of the pinned offset column,
// scrolling fully left if it fits there.
void hex_reveal(ref HexView v, size_t cursor, int cols, int visibleRows)
{
    long row = cast(long)(cursor / cols);
    if (row < v.topRow)
        v.topRow = row;
    else if (row >= v.topRow + visibleRows)
        v.topRow = row - visibleRows + 1;

    int start = hex_col_for(v.gridLay, cast(int)(cursor % cols));
    int end = start + 2;
    int pin = v.gridLay.hexStart;
    if (start - pin < v.leftCol)
        v.leftCol = end <= v.visCols ? 0 : start - pin;
    else if (end - v.leftCol > v.visCols)
        v.leftCol = end - v.visCols;
}

unittest
{
    HexView v;
    v.data = new ubyte[64];
    hex_reveal(v, 15, 16, 4); // nothing measured yet
    assert(v.leftCol == 0);

    v.gridLay = hex_layout(8, 16, 1);
    v.visCols = 20;
    hex_reveal(v, 15, 16, 4);
    assert(v.leftCol == hex_col_for(v.gridLay, 15) + 2 - 20); // minimal scroll
    hex_reveal(v, 14, 16, 4);
    assert(v.leftCol == hex_col_for(v.gridLay, 15) + 2 - 20); // already visible
    hex_reveal(v, 3, 16, 4);
    assert(v.leftCol == hex_col_for(v.gridLay, 3) - v.gridLay.hexStart); // past the pin
    hex_reveal(v, 0, 16, 4);
    assert(v.leftCol == 0); // fits from the left
}

/// Bytes `at .. at + len` from the cached window, or null if not fully cached.
public const(ubyte)[] hex_cached(ref const(HexView) v, size_t at, size_t len)
{
    if (v.readFn is null)
        return at + len <= v.data.length ? v.data[at .. at + len] : null;
    if (at < v.windowStart || at + len > v.windowStart + v.windowLen ||
        v.revision is null || v.windowRev != *v.revision || v.windowUser != v.readUser)
        return null;
    return v.windowBuf[at - v.windowStart .. at - v.windowStart + len];
}

// Keep the window covering visible rows plus a screen of slack each side,
// page-aligned. Reread only when visible rows leave it or the revision
// changes. No-op for in-memory data.
void hex_fill_window(ref HexView v, mu_Rect body, long topRow, int rowH, int cols)
{
    if (v.readFn is null)
        return;

    size_t total = hex_total(v);
    long rows  = (cast(long) total + cols - 1) / cols;

    long firstRow = topRow;
    long lastRow  = topRow + body.h / rowH;
    if (firstRow < 0) firstRow = 0;
    if (lastRow >= rows) lastRow = rows - 1;
    if (lastRow < firstRow)
    {
        v.windowLen = 0;
        return;
    }

    size_t start = cast(size_t)(firstRow * cols);
    size_t need  = cast(size_t)((lastRow - firstRow + 1) * cols);
    size_t end   = start + need < total ? start + need : total;

    if (v.revision && v.windowRev == *v.revision && v.windowUser == v.readUser &&
        start >= v.windowStart && end <= v.windowStart + v.windowLen)
        return;

    enum size_t ALIGN = 4096;
    size_t lo = (start > need ? start - need : 0) & ~(ALIGN - 1);
    size_t hi = (end + need + ALIGN - 1) & ~(ALIGN - 1);
    if (hi > total)
        hi = total;
    if (v.windowBuf.length < hi - lo)
        v.windowBuf.length = hi - lo;

    ubyte[] got = v.readFn(cast(long) lo, v.windowBuf[0 .. hi - lo], v.readUser);
    v.windowStart = lo;
    v.windowLen   = got.length;
    v.windowRev   = v.revision ? *v.revision : 0;
    v.windowUser  = v.readUser;
}

unittest
{
    static int reads;
    static ubyte[] fill(long pos, ubyte[] buf, void*)
    {
        ++reads;
        foreach (i, ref ubyte b; buf)
            b = cast(ubyte)(pos + i);
        return buf;
    }

    uint rev;
    HexView v;
    v.readFn   = &fill;
    v.revision = &rev;
    v.dataSize = 1 << 20;
    mu_Rect body = mu_Rect(0, 0, 100, 10 * 16); // ten rows of 16

    hex_fill_window(v, body, 1000, 16, 16);
    assert(reads == 1);
    assert(v.windowStart % 4096 == 0);
    hex_fill_window(v, body, 1001, 16, 16); // small scroll stays inside
    assert(reads == 1);
    assert(hex_cached(v, 1001 * 16, 4) == [0x90, 0x91, 0x92, 0x93]); // 0x3e90

    ++rev; // edit
    assert(hex_cached(v, 1001 * 16, 1) is null);
    hex_fill_window(v, body, 1001, 16, 16);
    assert(reads == 2);

    hex_fill_window(v, body, 50_000, 16, 16); // far away
    assert(reads == 3);
    assert(hex_cached(v, 0, 1) is null);
}

// Minimap ribbon, also a scroll control. Maps the whole document by row, each
// block the dominant class of its segment.
void hex_minimap(mu_Context* ctx, ref HexView v, mu_Rect strip,
    long topRow, long maxTop, long rows, int visibleRows)
{
    mu_draw_rect(ctx, strip, mu_Color(20, 20, 28, 255)); // backdrop

    size_t total = hex_total(v);
    int cells = strip.h / MINIMAP_BLOCK;
    if (total == 0 || cells <= 0)
        return;

    hex_build_minimap(v, cells);

    foreach (i, c; v.mapCells)
    {
        int y = strip.y + cast(int) i * MINIMAP_BLOCK;
        mu_Rect cell = mu_Rect(strip.x, y, strip.w, MINIMAP_BLOCK);
        mu_draw_rect(ctx, cell, c);

        // Washes on top, same priority as the grid. Not cached in mapCells.
        mu_Color wash = hex_map_wash(v, cast(long) i, cells, cast(long) total);
        if (wash.a)
            mu_draw_rect(ctx, cell, wash);
    }

    // Viewport marker; floored height since it can be under a pixel.
    if (rows > 0)
    {
        int hy = strip.y + cast(int)(topRow * strip.h / rows);
        int hh = cast(int)(cast(long) visibleRows * strip.h / rows);
        if (hh < MINIMAP_VIEW_MIN) hh = MINIMAP_VIEW_MIN;
        if (hy + hh > strip.y + strip.h) hy = strip.y + strip.h - hh;
        if (hy < strip.y) hy = strip.y;
        mu_Rect view = mu_Rect(strip.x - MINIMAP_VIEW_OUT, hy,
            strip.w + MINIMAP_VIEW_OUT * 2, hh);
        mu_draw_rect(ctx, view, mu_Color(150, 185, 235, 70)); // region tint
        mu_draw_box(ctx, view, mu_Color(190, 215, 255, 255));  // region border
    }

    // Click or drag to centre the view there.
    mu_Id id = mu_get_id(ctx, "!hexminimap".ptr, 11);
    mu_update_control(ctx, id, strip, 0);
    if (ctx.focus == id && (ctx.mouse_down & MU_MOUSE_LEFT) && maxTop > 0)
    {
        int localY = ctx.mouse_pos.y - strip.y;
        long target = cast(long) localY * rows / strip.h - visibleRows / 2;
        v.topRow = mu_clamp(target, 0L, maxTop);
    }
}

// Wash for minimap cell `index` of `cells` over `total` bytes, alpha 0 for
// none. Same priority as hex_draw_row (selection over hook wash). Queries the
// whole span, so tiny marks show. Lifted like outlines: the ribbon has no
// glyphs to keep readable.
mu_Color hex_map_wash(ref const(HexView) v, long index, int cells, long total)
{
    long start = index * total / cells;
    long end   = (index + 1) * total / cells;
    if (end <= start) // as in hex_build_minimap
        end = start + 1;

    size_t selLow  = hex_sel_low(v);
    size_t selHigh = hex_sel_high(v);
    if (v.active && selLow != selHigh && cast(long) selHigh >= start && cast(long) selLow < end)
        return hex_wash_lift(HEX_SEL_WASH);

    if (v.backSpanFn is null)
        return mu_Color(0, 0, 0, 0);

    mu_Color wash = v.backSpanFn(start, end - start, cast(void*) v.backUser);
    return wash.a ? hex_wash_lift(wash) : wash;
}

unittest
{
    enum int CELLS = 176;

    HexView v;
    v.data   = cast(const(ubyte)[]) "0123456789abcdef\x00\x01";
    v.active = true;
    v.anchor = 0;
    v.cursor = 1; // two bytes at the head
    long total = cast(long) v.data.length;

    // One run, no gaps between selected cells.
    int runs;
    bool prev;
    foreach (int c; 0 .. CELLS)
    {
        bool washed = hex_map_wash(v, c, CELLS, total).a != 0;
        if (washed && prev == false)
            ++runs;
        prev = washed;
    }
    assert(runs == 1);
    assert(hex_map_wash(v, 0, CELLS, total).a != 0);
}

// Plain scrollbar (minimap off), in row units.
void hex_plainbar(mu_Context* ctx, ref HexView v, mu_Rect strip,
    long topRow, long maxTop, long rows, int visibleRows)
{
    mu_draw_rect(ctx, strip, mu_Color(20, 20, 28, 255));
    if (rows <= 0 || strip.h <= 0)
        return;

    // Min size so it stays grabbable.
    int thumbH = cast(int)(cast(long) visibleRows * strip.h / rows);
    if (thumbH < SCROLLBAR_THUMB_MIN) thumbH = SCROLLBAR_THUMB_MIN;
    if (thumbH > strip.h) thumbH = strip.h;
    int travel = strip.h - thumbH;
    int ty = strip.y + (maxTop > 0 ? cast(int)(topRow * travel / maxTop) : 0);
    mu_draw_rect(ctx, mu_Rect(strip.x, ty, strip.w, thumbH),
        mu_Color(90, 110, 150, 255));

    // Click or drag: thumb centre follows the pointer.
    mu_Id id = mu_get_id(ctx, "!hexscroll".ptr, 10);
    mu_update_control(ctx, id, strip, 0);
    if (ctx.focus == id && (ctx.mouse_down & MU_MOUSE_LEFT) && maxTop > 0 && travel > 0)
    {
        int localY = ctx.mouse_pos.y - strip.y - thumbH / 2;
        long target = cast(long) localY * maxTop / travel;
        v.topRow = mu_clamp(target, 0L, maxTop);
    }
}

// Rebuild minimap colours: sample each segment with a fixed budget, keep the
// dominant colour. Cost is `cells` small reads regardless of file size.
void hex_build_minimap(ref HexView v, int cells)
{
    size_t total = hex_total(v);
    if (v.mapForSize == total && v.mapForCells == cells &&
        v.mapCells.length == cast(size_t) cells)
        return;

    if (v.mapCells.length != cast(size_t) cells)
        v.mapCells.length = cells;
    v.mapForSize  = total;
    v.mapForCells = cells;

    if (total == 0)
        return;
    if (v.mapProbe.length < MINIMAP_PROBE)
        v.mapProbe.length = MINIMAP_PROBE;

    long len = cast(long) total;
    for (int c; c < cells; ++c)
    {
        long start = c * len / cells;
        long end   = (c + 1) * len / cells;
        // More cells than bytes: empty spans use the byte at `start`, else uncoloured
        // cells stripe the ribbon.
        long span = end > start ? end - start : 1;
        size_t take = span < MINIMAP_PROBE ? cast(size_t) span : MINIMAP_PROBE;
        ubyte[] chunk = hex_probe(v, start, v.mapProbe[0 .. take]);
        v.mapCells[c] = hex_dominant(v, chunk, start);
    }
}

unittest
{
    enum int CELLS = 176; // 600px window, where striping showed

    HexView v;
    v.data = cast(const(ubyte)[]) "0123456789abcdef\x00\x01";
    hex_build_minimap(v, CELLS);

    // All cells coloured despite 10x more cells than bytes.
    assert(v.mapCells.length == CELLS);
    foreach (mu_Color c; v.mapCells)
        assert(c.a != 0);

    // In order, ends included.
    assert(hex_coleq(v.mapCells[0], hex_dominant(v, v.data[0 .. 1], 0)));
    assert(hex_coleq(v.mapCells[CELLS - 1],
        hex_dominant(v, v.data[$ - 1 .. $], cast(long) v.data.length - 1)));
}

// Read up to buf.length bytes at `pos`; returns what's available.
ubyte[] hex_probe(ref HexView v, long pos, ubyte[] buf)
{
    if (v.readFn)
        return v.readFn(pos, buf, v.readUser);

    if (pos < 0 || cast(size_t) pos >= v.data.length)
        return buf[0 .. 0];
    size_t p = cast(size_t) pos;
    size_t n = v.data.length - p;
    if (n > buf.length) n = buf.length;
    buf[0 .. n] = v.data[p .. p + n];
    return buf[0 .. n];
}

// Dominant colour of a sample, via the panel's scheme so ribbon and grid
// match. Class only; washes are added by hex_map_wash.
mu_Color hex_dominant(ref const(HexView) v, const(ubyte)[] chunk, long baseOff)
{
    if (chunk.length == 0)
        return mu_Color(0, 0, 0, 0);

    HexColorFn colorFn = v.colorFn ? v.colorFn : &hex_classify;
    void* user = cast(void*) v.colorUser;

    // Few colours from hex_classify; extras past the cap don't vote.
    mu_Color[8] pal = void;
    int[8] hits;
    int n;

    foreach (i, b; chunk)
    {
        mu_Color c = colorFn(cast(size_t)(baseOff + i), b, user);
        int j;
        for (; j < n; ++j)
            if (hex_coleq(pal[j], c)) { ++hits[j]; break; }
        if (j == n && n < pal.length)
        {
            pal[n]  = c;
            hits[n] = 1;
            ++n;
        }
    }

    int best;
    for (int j = 1; j < n; ++j)
        if (hits[j] > hits[best])
            best = j;
    return pal[best];
}

bool hex_coleq(mu_Color a, mu_Color b)
{
    return a.r == b.r && a.g == b.g && a.b == b.b && a.a == b.a;
}

unittest
{
    mu_Color a = mu_Color(1, 2, 3, 4);
    assert(hex_coleq(a, mu_Color(1, 2, 3, 4)));
    assert(hex_coleq(a, mu_Color(9, 2, 3, 4)) == false);
    assert(hex_coleq(a, mu_Color(1, 2, 3, 5)) == false); // alpha counts
}

// Draw visible rows only, so command count is bounded.
void hex_paint(mu_Context* ctx, ref const(HexView) v, ref const(HexLayout) lay,
    mu_Rect body, long topRow, int rowH, int cols, mu_Font font)
{
    size_t total = hex_total(v);
    long rows  = (cast(long) total + cols - 1) / cols;
    int charW = lay.charW;
    int originX = body.x - v.leftCol * charW;
    int laneX = body.x + lay.hexStart * charW;
    int endX = body.x + body.w;
    // Lanes scroll under the pinned offset column, clipped so rects stay off it.
    // One pixel early: caret and outlines sit 1px outside their glyphs.
    mu_Rect lanes = mu_Rect(laneX - 1, body.y, mu_max(0, endX - laneX + 1), body.h);

    // Empty document: draw the first offset and a caret.
    if (rows == 0)
    {
        hex_draw_offset(ctx, v, lay, body.x, endX, body.y, 0, font);
        mu_push_clip_rect(ctx, lanes);
        if (v.active)
            hex_draw_caret(ctx, lay, originX, body.y, 0, charW, rowH, hex_caret_nib(v));
        mu_pop_clip_rect(ctx);
        return;
    }

    long firstRow = topRow;
    long lastRow  = topRow + body.h / rowH;
    if (firstRow < 0) firstRow = 0;
    if (lastRow >= rows) lastRow = rows - 1;

    HexColorFn colorFn = v.colorFn ? v.colorFn : &hex_classify;
    size_t selLow  = hex_sel_low(v);
    size_t selHigh = hex_sel_high(v);

    for (long row = firstRow; row <= lastRow; ++row)
        hex_draw_offset(ctx, v, lay, body.x, endX,
            body.y + cast(int)((row - topRow) * rowH), row * cols, font);

    mu_push_clip_rect(ctx, lanes);
    for (long row = firstRow; row <= lastRow; ++row)
    {
        int y = body.y + cast(int)((row - topRow) * rowH);
        hex_draw_row(ctx, v, lay, colorFn, v.backFn, originX, laneX, endX, y,
            row, cols, rowH, charW, selLow, selHigh, font);
    }

    // Caret on the append slot is outside every row's range; draw it here.
    if (v.active && v.cursor == total)
    {
        long row = cast(long)(total / cols);
        int col = cast(int)(total % cols);
        if (row >= firstRow && row <= lastRow + 1)
        {
            int y = body.y + cast(int)((row - topRow) * rowH);
            hex_draw_caret(ctx, lay, originX, y, col, charW, rowH, hex_caret_nib(v));
        }
    }
    mu_pop_clip_rect(ctx);
}

/// Draw the offset of byte `at` at `x`, if it fits before `endX`.
void hex_draw_offset(mu_Context* ctx, ref const(HexView) v, ref const(HexLayout) lay,
    int x, int endX, int y, long at, mu_Font font)
{
    char[24] off = void;
    int digits = lay.offsetDigits > off.length ? cast(int) off.length : lay.offsetDigits;
    hex_format(off.ptr, cast(ulong)(v.baseAddress + at), digits, v.offsetBase);
    if (hex_fits(x, digits, lay.charW, x, endX))
        mu_draw_text(ctx, font, off.ptr, digits, mu_Vec2(x, y), mu_Color(150, 150, 160, 255));
}

void hex_draw_row(mu_Context* ctx, ref const(HexView) v, ref const(HexLayout) lay,
    HexColorFn colorFn, HexBackFn backFn, int originX, int startX, int endX, int y, long row,
    int cols, int rowH, int charW, size_t selLow, size_t selHigh, mu_Font font)
{
    size_t total = hex_total(v);
    size_t rowStart = cast(size_t)(row * cols);
    int count = cast(int) mu_min(cast(size_t) cols, total - rowStart);

    // Backgrounds by priority: hook wash, selection, then the wash outline. The
    // outline goes over the selection so a fresh mark under it stays visible.
    if (backFn)
        hex_wash_fill(ctx, v, lay, backFn, originX, y, rowStart, count, charW, rowH);

    // Selection is contiguous: at most one band. A bare caret has no wash.
    if (v.active && selLow != selHigh && selHigh >= rowStart && selLow < rowStart + count)
    {
        int lo = selLow  > rowStart ? cast(int)(selLow - rowStart) : 0;
        int hi = selHigh < rowStart + count ? cast(int)(selHigh - rowStart) : count - 1;
        hex_draw_band(ctx, lay, originX, y, lo, hi, charW, rowH, HEX_SEL_WASH);
    }

    if (backFn)
        hex_wash_outline(ctx, v, lay, backFn, originX, y, rowStart, count, cols, charW, rowH);

    // Structure borders under the glyphs, outermost first: borders mark records,
    // colours mark fields.
    if (v.spanFn)
        for (int level; level < v.spanDepth; ++level)
            hex_span_outline(ctx, v, lay, originX, y, rowStart, count, cols, charW, rowH, level);

    // Hex pair and text glyph share the byte colour.
    char[2] cell = void;
    char[1] ch = void;
    for (int i; i < count; ++i)
    {
        size_t idx = rowStart + i;
        ubyte b = hex_byte(v, idx);
        mu_Color color = colorFn(idx, b, cast(void*) v.colorUser);

        int hx = originX + hex_col_for(lay, i) * charW;
        if (hex_fits(hx, 2, charW, startX, endX))
        {
            hex_format(cell.ptr, b, 2);
            mu_draw_text(ctx, font, cell.ptr, 2, mu_Vec2(hx, y), color);
        }

        const(char)[] glyph = hex_text(v, b, ch);
        int ax = originX + (lay.asciiStart + i) * charW;
        if (hex_fits(ax, 1, charW, startX, endX))
            mu_draw_text(ctx, font, glyph.ptr, cast(int) glyph.length, mu_Vec2(ax, y), color);
    }

    if (v.active && v.cursor >= rowStart && v.cursor < rowStart + count)
        hex_draw_caret(ctx, lay, originX, y, cast(int)(v.cursor - rowStart), charW, rowH, hex_caret_nib(v));
}

// Text lane characters for a byte; `scratch` holds single-char results.
const(char)[] hex_text(ref const(HexView) v, ubyte b, char[] scratch)
{
    if (v.textFn)
    {
        const(char)[] s = v.textFn(b, cast(void*) v.textUser);
        if (s.length)
            return s;
    }
    else if (b >= 0x20 && b < 0x7f)
    {
        scratch[0] = cast(char) b;
        return scratch[0 .. 1];
    }

    scratch[0] = '.';
    return scratch[0 .. 1];
}

unittest
{
    static const(char)[] upper(ubyte value, void* user)
    {
        // A set mapping one character and leaving the rest unmapped.
        return value == 'a' ? "A" : null;
    }

    char[1] ch = void;
    HexView v;

    assert(hex_text(v, 'a', ch) == "a");
    assert(hex_text(v, 0, ch) == ".");
    assert(hex_text(v, 0x7f, ch) == ".");

    v.textFn = &upper;
    assert(hex_text(v, 'a', ch) == "A");
    assert(hex_text(v, 'b', ch) == "."); // unmapped
    assert(hex_text(v, 0, ch) == ".");
}

// Caret box: -1 whole pair (read-only), 0 high nibble, 1 low. Like GHex.
int hex_caret_nib(ref const(HexView) v)
{
    if (hex_editable(v) == false)
        return -1;
    return v.editLow ? 1 : 0;
}

// Fill washed cells, merging same-colour neighbours (gaps included) into one
// rect.
void hex_wash_fill(mu_Context* ctx, ref const(HexView) v, ref const(HexLayout) lay,
    HexBackFn backFn, int originX, int y, size_t rowStart, int count, int charW,
    int rowH)
{
    int runStart;
    mu_Color runColor; // .init is transparent
    for (int i; i <= count; ++i)
    {
        mu_Color c;
        if (i < count)
            c = backFn(rowStart + i, hex_byte(v, rowStart + i), cast(void*) v.backUser);
        if (i < count && hex_coleq(c, runColor))
            continue;
        if (runColor.a)
            hex_draw_band(ctx, lay, originX, y, runStart, i - 1, charW, rowH, runColor);
        runStart = i;
        runColor = c;
    }
}

// Outline washed cells with a lifted wash colour; survives the selection fill
// (see hex_draw_row). Edges are dropped between same-wash neighbours, so runs
// outline as one region across rows. Rows above and below are queried via
// backSpanFn (offset-only; hex_byte is invalid off-window). No backSpanFn, no
// outline.
void hex_wash_outline(mu_Context* ctx, ref const(HexView) v, ref const(HexLayout) lay,
    HexBackFn backFn, int originX, int y, size_t rowStart, int count, int cols,
    int charW, int rowH)
{
    if (v.backSpanFn is null || count <= 0)
        return;

    void* user = cast(void*) v.backUser;
    mu_Color left;  // carried, not re-queried
    mu_Color here = backFn(rowStart, hex_byte(v, rowStart), user);

    for (int i; i < count; ++i)
    {
        // Transparent at row end: wrapped runs close here and reopen next row.
        mu_Color right;
        if (i + 1 < count)
            right = backFn(rowStart + i + 1, hex_byte(v, rowStart + i + 1), user);

        if (here.a)
        {
            long idx = cast(long)(rowStart + i);
            mu_Color above = idx >= cols
                ? v.backSpanFn(idx - cols, 1, user) : mu_Color(0, 0, 0, 0);
            mu_Color below = v.backSpanFn(idx + cols, 1, user);

            bool joinR = hex_coleq(here, right);
            bool top    = hex_coleq(here, above) == false;
            bool bottom = hex_coleq(here, below) == false;
            bool onL    = hex_coleq(here, left) == false;
            mu_Color edge = hex_wash_lift(here);

            // Joined hex cells extend over the gap, matching the fill.
            int hx0 = originX + hex_col_for(lay, i) * charW;
            int hx1 = originX + charW *
                (joinR ? hex_col_for(lay, i + 1) : hex_col_for(lay, i) + 2);
            hex_draw_edges(ctx, hx0, hx1, y, rowH, top, bottom, onL, joinR == false,
                1, 0, 0, edge);

            // Text lane: no gaps, one glyph wide.
            int ax0 = originX + (lay.asciiStart + i) * charW;
            hex_draw_edges(ctx, ax0, ax0 + charW, y, rowH, top, bottom, onL,
                joinR == false, 1, 0, 0, edge);
        }

        left = here;
        here = right;
    }
}

// Outline structure spans on this row at level `up`, `weight` px thick, in
// each span's edge colour. Like hex_wash_outline but joined by span start, not
// colour (see HexSpanFn).
// NOTE: One hook call per cell per side; if it gets slow, carry each row's
// answers to the next as its top neighbours.
void hex_span_outline(mu_Context* ctx, ref const(HexView) v, ref const(HexLayout) lay,
    int originX, int y, size_t rowStart, int count, int cols, int charW, int rowH,
    int level)
{
    if (count <= 0)
        return;

    HexSpanFn fn = v.spanFn;
    void* user = cast(void*) v.spanUser;

    HexSpan left;
    bool hasLeft;
    HexSpan here;
    bool has = fn(cast(long) rowStart, level, here, user);

    for (int i; i < count; ++i)
    {
        // Closed at row end, reopened next row.
        HexSpan right;
        bool hasRight;
        if (i + 1 < count)
            hasRight = fn(cast(long)(rowStart + i + 1), level, right, user);

        if (has)
        {
            long idx = cast(long)(rowStart + i);

            HexSpan above, below;
            bool hasAbove = idx >= cols && fn(idx - cols, level, above, user);
            bool hasBelow = fn(idx + cols, level, below, user);

            bool joinR  = hex_span_joins(has, here, hasRight, right);
            bool top    = hex_span_joins(has, here, hasAbove, above) == false;
            bool bottom = hex_span_joins(has, here, hasBelow, below) == false;
            bool onL    = hex_span_joins(has, here, hasLeft, left) == false;

            // Joined hex cells extend over the gap.
            int hx0 = originX + hex_col_for(lay, i) * charW;
            int hx1 = originX + charW *
                (joinR ? hex_col_for(lay, i + 1) : hex_col_for(lay, i) + 2);
            hex_draw_edges(ctx, hx0, hx1, y, rowH, top, bottom, onL, joinR == false,
                1, -MARGIN_HEX, SPAN_PAD, here.edge);

            int ax0 = originX + (lay.asciiStart + i) * charW;
            hex_draw_edges(ctx, ax0, ax0 + charW, y, rowH, top, bottom, onL,
                joinR == false, 1, -MARGIN_TEXT, SPAN_PAD, here.edge);
        }

        left    = here;
        hasLeft = has;
        here    = right;
        has     = hasRight;
    }
}

// Whether two cells are in the same span (same start; see HexSpanFn).
bool hex_span_joins(bool hasA, ref const(HexSpan) a, bool hasB, ref const(HexSpan) b)
{
    return hasA && hasB && a.start == b.start;
}

unittest
{
    HexSpan a = HexSpan(16, 4);
    HexSpan b = HexSpan(16, 4);
    HexSpan c = HexSpan(20, 4);

    assert(hex_span_joins(true, a, true, b));

    // Adjacent same-shaped fields stay separate.
    assert(hex_span_joins(true, a, true, c) == false);

    // Uncovered cells never join.
    assert(hex_span_joins(true, a, false, b) == false);
    assert(hex_span_joins(false, a, true, b) == false);
}

// Brighter version of a wash, for its outline. Scaled, not blended to white,
// to keep the hue.
mu_Color hex_wash_lift(mu_Color c)
{
    return mu_Color(hex_lift(c.r), hex_lift(c.g), hex_lift(c.b), 255);
}

ubyte hex_lift(ubyte v)
{
    int n = v * WASH_EDGE_LIFT / 100;
    return cast(ubyte)(n > 255 ? 255 : n);
}

unittest
{
    // Clamps instead of wrapping.
    assert(hex_coleq(hex_wash_lift(mu_Color(125, 85, 22, 255)), mu_Color(250, 170, 44, 255)));
    assert(hex_coleq(hex_wash_lift(mu_Color(200, 0, 0, 128)), mu_Color(255, 0, 0, 255)));
}

// Draw the cell edges not shared with neighbours, `weight` px, inset by
// `padX`/`padY` (negative pushes outward). Padding only applies to drawn
// sides so runs don't notch. Cells too small to pad draw flush.
void hex_draw_edges(mu_Context* ctx, int x0, int x1, int y, int rowH,
    bool top, bool bottom, bool left, bool right, int weight, int padX, int padY,
    mu_Color color)
{
    int iy = y + padY;
    int ih = rowH - 2 * padY;
    if (ih < 2 * weight)
    {
        iy = y;
        ih = rowH;
    }

    int ix0 = x0 + (left ? padX : 0);
    int ix1 = x1 - (right ? padX : 0);
    if (ix1 - ix0 < 2 * weight)
    {
        ix0 = x0;
        ix1 = x1;
    }

    if (top)    mu_draw_rect(ctx, mu_Rect(ix0, iy, ix1 - ix0, weight), color);
    if (bottom) mu_draw_rect(ctx, mu_Rect(ix0, iy + ih - weight, ix1 - ix0, weight), color);
    if (left)   mu_draw_rect(ctx, mu_Rect(ix0, iy, weight, ih), color);
    if (right)  mu_draw_rect(ctx, mu_Rect(ix1 - weight, iy, weight, ih), color);
}

// Fill columns `lo` to `hi` in both lanes; the hex band covers the gaps.
void hex_draw_band(mu_Context* ctx, ref const(HexLayout) lay, int originX, int y,
    int lo, int hi, int charW, int rowH, mu_Color color)
{
    int hx = originX + hex_col_for(lay, lo) * charW;
    int hw = (hex_col_for(lay, hi) + 2 - hex_col_for(lay, lo)) * charW;
    mu_draw_rect(ctx, mu_Rect(hx, y, hw, rowH), color);

    int ax = originX + (lay.asciiStart + lo) * charW;
    int aw = (hi - lo + 1) * charW;
    mu_draw_rect(ctx, mu_Rect(ax, y, aw, rowH), color);
}

// Caret outline in both lanes at column `col`. `nib`: -1 whole pair, 0 high,
// 1 low. The text lane is one glyph.
void hex_draw_caret(mu_Context* ctx, ref const(HexLayout) lay, int originX, int y,
    int col, int charW, int rowH, int nib)
{
    mu_Color curColor = mu_Color(120, 170, 235, 255);
    int hx = originX + hex_col_for(lay, col) * charW;
    if (nib < 0)
        mu_draw_box(ctx, mu_Rect(hx - 1, y, 2 * charW + 2, rowH), curColor);
    else
        mu_draw_box(ctx, mu_Rect(hx + nib * charW - 1, y, charW + 2, rowH), curColor);
    int ax = originX + (lay.asciiStart + col) * charW;
    mu_draw_box(ctx, mu_Rect(ax - 1, y, charW + 2, rowH), curColor);
}

// Avoids a C import for one call.
size_t hex_strlen(const(char)* s)
{
    size_t n;
    while (s[n]) ++n;
    return n;
}

unittest
{
    assert(hex_strlen("") == 0);
    assert(hex_strlen("hex") == 3);
    assert(hex_strlen("hexpanel") == 8);
}
