/// A hex panel widget for ddui.
///
/// ddui ships buttons, labels, sliders and the like, but nothing for showing
/// raw bytes, so vddhx grows its own. The panel renders the classic three
/// columns (offset / hex / ASCII) in a monospace face, tints each byte through
/// a caller-supplied colour scheme, and tracks a selection the caller can read
/// back. It rides on a ddui panel container for clipping and wheel routing;
/// scrolling itself is tracked in row units (so a multi-gigabyte file never
/// overflows a pixel-based offset), and the rows are drawn by hand and
/// virtualised, so only the bytes on screen are ever touched no matter how large
/// the buffer is.
/// Authors: dd
module hexview;

import ddui;

/// Extra ddui key bits for the hex panel's caret. ddui's own MU_KEY_* flags
/// stop at (1 << 5); these carry on from there so both can share ctx.key_down.
/// main.d maps the arrow / paging keys onto them. Kept as a bitmask (rather than
/// distinct codes) to match how ddui feeds keys, one OR per pressed key.
enum
{
    HEX_KEY_LEFT  = (1 << 6),
    HEX_KEY_RIGHT = (1 << 7),
    HEX_KEY_UP    = (1 << 8),
    HEX_KEY_DOWN  = (1 << 9),
    HEX_KEY_HOME  = (1 << 10),
    HEX_KEY_END   = (1 << 11),
    HEX_KEY_PGUP  = (1 << 12),
    HEX_KEY_PGDN  = (1 << 13),
    HEX_KEY_INS   = (1 << 14), // toggle insert / overwrite
    HEX_KEY_DEL   = (1 << 15), // forward delete
    HEX_KEY_UNDO  = (1 << 16), // with Ctrl: undo
    HEX_KEY_REDO  = (1 << 17), // with Ctrl: redo
}

/// Per-byte colour hook. Return the colour for the byte at `offset` (its value
/// is passed so the common "colour by value" schemes need no buffer access).
/// `user` is the pointer handed to HexView.colorUser, for schemes that need
/// outside context (a type map, a diff mask, a search hit set...).
alias HexColorFn = mu_Color function(size_t offset, ubyte value, void* user);

/// On-demand byte source, for showing a slice of something too large to hold in
/// memory (a multi-gigabyte file behind a ddhx editor, say). Fill `buf` starting
/// at document offset `pos` and return the bytes actually read (a short slice at
/// EOF is fine). `user` is HexView.readUser. When a HexView sets readFn, the
/// panel pulls only the on-screen rows through it each frame; `data` is ignored.
alias HexReadFn = ubyte[] function(long pos, ubyte[] buf, void* user);

/// Overwrite hook: set the byte at document offset `pos` to `value`. Supply this
/// alongside insertFn and removeFn to make a HexView editable; see
/// HexView.replaceFn. `user` is HexView.writeUser.
alias HexReplaceFn = void function(long pos, ubyte value, void* user);

/// Insert hook: splice `value` in as a fresh byte at document offset `pos`,
/// shifting the rest of the document up by one. See HexView.insertFn.
alias HexInsertFn = void function(long pos, ubyte value, void* user);

/// Remove hook: drop `len` bytes starting at document offset `pos`. See
/// HexView.removeFn.
alias HexRemoveFn = void function(long pos, long len, void* user);

/// Undo / redo hooks: step the document's edit history one entry. Return the
/// document offset the change touched (undo: the start of the affected region,
/// redo: its end) so the panel can move the caret onto it, or -1 when there is
/// nothing left to step. `user` is HexView.writeUser. See HexView.undoFn.
alias HexUndoFn = long function(void* user);
/// Ditto.
alias HexRedoFn = long function(void* user);

// Minimap ribbon geometry, plain-scrollbar geometry, and sampling budget.
private enum
{
    MINIMAP_WIDTH = 16,  // ribbon width in pixels
    MINIMAP_BLOCK = 3,   // pixels per cell (the pixelisation)
    MINIMAP_PROBE = 256, // bytes sampled per cell, a fixed read budget
    MINIMAP_VIEW_MIN = 14, // floor for the viewport marker so it stays a region
    MINIMAP_VIEW_OUT = 2,  // px the marker overhangs each ribbon edge, for visibility
    SCROLLBAR_WIDTH = 14,   // plain scroll strip width (minimap off)
    SCROLLBAR_THUMB_MIN = 24, // floor for the plain thumb so it stays grabbable
}

/// State and configuration for one hex panel. Persist it across frames (the
/// selection lives here); the byte buffer and options can change frame to frame.
struct HexView
{
    /// The bytes on display when readFn is null. May be empty.
    const(ubyte)[] data;
    /// Bytes per row. Powers of two read most naturally; 16 is conventional.
    int columns = 16;
    /// Address printed for the first byte, so a slice can show file offsets.
    long baseAddress;
    /// Minimum hex digits in the offset column. 8 fits a 32-bit span; the panel
    /// widens past this on its own when the highest address needs more, so a file
    /// spilling past 0xffffffff grows the column rather than dropping its top nibble.
    int offsetDigits = 8;
    /// Show the minimap ribbon down the right edge, coloured through the same
    /// scheme as the bytes. When false, the panel shows a wider plain scrollbar
    /// instead. Flip it from a toolbar; hex_view reads it each frame.
    bool minimap = true;

    /// Caret byte index (the moving end of the selection).
    size_t cursor;
    /// Anchor byte index (the fixed end). The selection spans [anchor, cursor].
    size_t anchor;
    /// Whether a caret / selection exists yet. Set on the first click or key.
    bool active;

    /// Set to hand the panel keyboard focus on the next frame it draws, without
    /// the user having to click into the grid first. For callers that put a
    /// document in front from outside a frame - opening a file, switching tabs -
    /// after which typing should land in the bytes. Cleared once honoured.
    bool takeFocus;

    /// Optional per-byte colour scheme. Null falls back to hex_classify.
    HexColorFn colorFn;
    /// Opaque pointer forwarded to colorFn.
    void* colorUser;

    /// Optional on-demand byte source. When set, the panel reads only the
    /// visible rows through it and `data` is ignored; see HexReadFn.
    HexReadFn readFn;
    /// Opaque pointer forwarded to readFn.
    void* readUser;
    /// Total document size in bytes. Only consulted when readFn is set. The panel
    /// keeps it in step with its own edits so a growing or shrinking file stays
    /// consistent within the frame that changed it.
    long dataSize;

    /// Optional write hooks. Supply all three to make the panel editable: typing
    /// hex digits edits the byte under the caret, Backspace/Delete remove bytes,
    /// and the Insert key flips between overwrite and insert. Leave any one null
    /// and the panel stays read-only. Edits are addressed by document offset and
    /// target the same source the reads come from (the editor behind readFn), so
    /// editing implies the readFn path. `user` is HexView.writeUser.
    HexReplaceFn replaceFn;
    /// Ditto.
    HexInsertFn insertFn;
    /// Ditto.
    HexRemoveFn removeFn;
    /// Opaque pointer forwarded to the write hooks (the editor, in practice).
    void* writeUser;

    /// Optional undo / redo hooks. Supply them to let Ctrl+Z and Ctrl+Y (or
    /// Ctrl+Shift+Z) walk the editor's history; the caret follows the change.
    /// They take HexView.writeUser like the write hooks. See HexUndoFn.
    HexUndoFn undoFn;
    /// Ditto.
    HexRedoFn redoFn;

    /// Insert vs overwrite entry. Overwrite (the default) edits the nibble under
    /// the caret in place; insert splices a fresh byte in and pushes the rest up.
    /// The Insert key toggles it; a toolbar or status bar can read it back.
    bool insertMode;
    
    private:

    // Row-based scroll position: index of the first visible row, the single
    // source of truth for what is on screen. Kept in rows (not pixels) so it
    // never overflows on multi-gigabyte files, where the grid's full pixel height
    // would blow past a 32-bit int. hex_view owns it.
    long topRow;
    // Leftover wheel pixels below one row height, carried between frames so a slow
    // wheel still advances when a notch is shorter than a row.
    int wheelAccum;
    // Rows that fit on screen, measured by hex_view each frame. Kept here so a
    // caret move driven from outside a frame (hex_set_caret) can scroll to it
    // without the caller knowing the panel's geometry.
    int visRows = 1;

    // Nibble sub-position within the caret byte: false means the next hex digit
    // is the byte's high nibble (a fresh byte), true its low nibble. Reset on any
    // caret move so every byte starts clean. editByte holds the value written for
    // the high nibble, so the low nibble folds in without re-reading the source.
    bool editLow;
    ubyte editByte;

    // Reused scratch for the visible window when reading through readFn: the
    // buffer grows to fit the on-screen rows and is refilled every frame, so a
    // huge document costs only a screenful of bytes here.
    ubyte[] windowBuf;   // capacity, kept across frames
    size_t windowStart;  // document offset of windowBuf[0]
    size_t windowLen;    // valid bytes currently in windowBuf

    // Minimap cell cache: one colour per vertical cell, each the dominant class
    // of the file segment it covers. Rebuilt only when the document size or the
    // cell count changes, so a still view redraws it for free.
    mu_Color[] mapCells;
    size_t mapForSize;   // document size the cache was built for
    int mapForCells;     // cell count the cache was built for
    ubyte[] mapProbe;    // reused per-cell sampling scratch
}

/// Scroll the view back to the top. Call when a fresh document is loaded so the
/// panel never inherits the previous file's scroll offset and strands the caret
/// (which the caller has just reset to the first byte) off screen.
void hex_reset_scroll(ref HexView v)
{
    v.topRow     = 0;
    v.wheelAccum = 0;
}

/// Total byte count on display, from the editor size or the in-memory slice.
size_t hex_total(ref const(HexView) v)
{
    if (v.readFn)
        return v.dataSize > 0 ? cast(size_t) v.dataSize : 0;
    return v.data.length;
}

// One byte at a document offset, from the window scratch or the in-memory slice.
// Offsets outside the filled window read as zero (e.g. an unmapped page).
private ubyte hex_byte(ref const(HexView) v, size_t idx)
{
    if (v.readFn)
    {
        size_t off = idx - v.windowStart;
        return off < v.windowLen ? v.windowBuf[off] : 0;
    }
    return v.data[idx];
}

/// Lowest selected byte index (== highest when it is a bare caret).
size_t hex_sel_low(ref const(HexView) v)
{
    return v.cursor < v.anchor ? v.cursor : v.anchor;
}

/// Highest selected byte index.
size_t hex_sel_high(ref const(HexView) v)
{
    return v.cursor > v.anchor ? v.cursor : v.anchor;
}

/// Map a hex digit to its 0-15 value, or -1 when the character is not a hex
/// digit. The panel folds typed digits in through this; it is public so a caller
/// reading hex text of its own (a clipboard paste, say) agrees on what a digit is.
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
    assert(hex_nibble('A') == 10);  // upper case folds to the same value
    assert(hex_nibble('F') == 15);
    assert(hex_nibble('g') == -1);  // past 'f'
    assert(hex_nibble('/') == -1);  // just below '0'
    assert(hex_nibble(' ') == -1);
}

/// Drop the caret on `pos`, collapsing the selection onto it and scrolling it
/// into view. For callers that change the document from outside the panel - a
/// paste, say - and need the caret to follow the result. Set dataSize first so
/// the clamp sees the new size.
void hex_set_caret(ref HexView v, size_t pos)
{
    size_t total = hex_total(v);
    if (pos > total) // the append slot past the last byte is a valid caret
        pos = total;
    v.cursor  = pos;
    v.anchor  = pos;
    v.active  = true;
    v.editLow = false; // an outside edit ends any half-typed byte
    hex_reveal(v, pos, v.columns > 0 ? v.columns : 16, v.visRows);
}

unittest
{
    HexView v;
    v.cursor = 5;
    v.anchor = 2;
    assert(hex_sel_low(v) == 2);
    assert(hex_sel_high(v) == 5);

    // Order of the two ends must not matter.
    v.cursor = 3;
    v.anchor = 9;
    assert(hex_sel_low(v) == 3);
    assert(hex_sel_high(v) == 9);

    // A bare caret: low and high collapse onto the same byte.
    v.cursor = 7;
    v.anchor = 7;
    assert(hex_sel_low(v) == 7);
    assert(hex_sel_high(v) == 7);
}

/// Default colour scheme: dim the padding zeros, keep printable ASCII bright,
/// tint control bytes cool and high-range bytes warm, so structure in a binary
/// (strings, runs of zeros, tables) is legible at a glance.
mu_Color hex_classify(size_t offset, ubyte value, void* user)
{
    if (value == 0)
        return mu_Color(90, 90, 100, 255);         // padding / null
    if (value >= 0x20 && value < 0x7f)
        return mu_Color(220, 220, 220, 255);        // printable ASCII
    if (value == '\t' || value == '\n' || value == '\r')
        return mu_Color(120, 170, 200, 255);        // whitespace controls
    if (value < 0x20)
        return mu_Color(200, 130, 90, 255);         // other control bytes
    return mu_Color(150, 190, 130, 255);            // high range (>= 0x80)
}

unittest
{
    assert(hex_coleq(hex_classify(0, 0, null),    mu_Color(90, 90, 100, 255)));  // null
    assert(hex_coleq(hex_classify(0, 'A', null),  mu_Color(220, 220, 220, 255))); // printable
    assert(hex_coleq(hex_classify(0, '\n', null), mu_Color(120, 170, 200, 255))); // whitespace
    assert(hex_coleq(hex_classify(0, 0x01, null), mu_Color(200, 130, 90, 255)));  // control
    assert(hex_coleq(hex_classify(0, 0x80, null), mu_Color(150, 190, 130, 255))); // high range
}

/// Draw and drive a hex panel.
///
/// Consumes a fixed header row plus a fill row from the current layout, so it
/// wants a column or window with a bounded height to sit in. Selection changes
/// (mouse or keyboard) are reported through the return value.
/// Params:
///     ctx  = ddui context.
///     name = Stable id string, unique among sibling widgets.
///     v    = Panel state; read back the selection from it after the call.
///     font = Monospace face handle (a TTF_Font*), used for every glyph here.
///     reserveBottom = Pixels to keep free below the panel for a caller-drawn
///                     bottom row (a status bar). 0 fills to the container floor.
/// Returns: MU_RES_CHANGE when the selection moved this frame, else 0.
int hex_view(mu_Context* ctx, const(char)* name, ref HexView v, mu_Font font,
    int reserveBottom = 0)
{
    // Monospace metrics: one glyph advance and one line height drive all
    // column and row placement below. Measuring "0" is enough on a mono face.
    int charW = ctx.text_width(font, "0", 1);
    int rowH  = ctx.text_height(font);
    if (charW <= 0) charW = 1;
    if (rowH  <= 0) rowH  = 1;

    int cols = v.columns > 0 ? v.columns : 16;
    size_t total = hex_total(v);
    long rows  = (cast(long) total + cols - 1) / cols;

    // Widen the offset column to fit the highest address it will print (the last
    // row's label), floored at v.offsetDigits. Without this a document past
    // 0xffffffff would have its top nibbles dropped by hex_format's fixed width.
    long lastRowOff = v.baseAddress + (rows > 0 ? (rows - 1) * cols : 0);
    int offsetDigits = hex_fit_digits(cast(ulong) lastRowOff, v.offsetDigits);

    // Character-grid column origins (see layout note in hex_draw_row).
    HexLayout lay = hex_layout(offsetDigits, cols, charW);

    // Header row, drawn fixed above the scroll area so it never scrolls away.
    hex_header(ctx, v, lay, rowH, font);

    // The scroll panel fills whatever height is left in the caller's layout. A
    // negative row height fills to the container floor; pushing it up by
    // reserveBottom (plus one spacing gap) leaves exactly that band free below,
    // where the caller's next widget - a status bar - then lands.
    int fill = -1;
    int panelH = reserveBottom > 0 ? -(reserveBottom + ctx.style.spacing + 1) : -1;
    mu_layout_row(ctx, 1, &fill, panelH);

    int res = 0;

    // Scrolling is driven in row units here, not through ddui's own pixel-based
    // scrollbar: a multi-gigabyte file has billions of rows, and the grid's full
    // pixel height would overflow the 32-bit ints ddui tracks scroll offsets in.
    // So the panel runs NOSCROLL and we own the scroll strip on the right edge:
    // the minimap ribbon, or a plain thumb when the minimap is off.
    mu_begin_panel_ex(ctx, name, MU_OPT_NOSCROLL);
    {
        mu_Container* cnt = mu_get_current_container(ctx);
        mu_Rect body = cnt.body_;

        int visibleRows = body.h / rowH;
        if (visibleRows < 1) visibleRows = 1;
        long maxTop = rows > visibleRows ? rows - visibleRows : 0;
        v.visRows = visibleRows; // for hex_set_caret, between frames

        // Carve the scroll strip off the right edge; the grid takes the rest.
        int stripW = v.minimap ? MINIMAP_WIDTH : SCROLLBAR_WIDTH;
        mu_Rect strip = mu_Rect(body.x + body.w - stripW, body.y, stripW, body.h);
        body.w -= stripW;

        // Wheel: NOSCROLL means ddui no longer routes the wheel or clamps for us,
        // so re-arm the wheel target while the mouse is over the panel. ddui folds
        // the notch delta into cnt.scroll.y (pixels) at frame end; we drain that
        // into whole rows, carrying the sub-row remainder so a slow wheel still
        // advances when a notch is shorter than a row.
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

        // Input can move the caret and reveal it, nudging topRow; re-clamp after.
        res = hex_input(ctx, name, v, lay, body, rowH, cols, visibleRows);
        v.topRow = mu_clamp(v.topRow, 0L, maxTop);

        // Pull just the on-screen rows from the editor before painting them.
        hex_fill_window(v, body, v.topRow, rowH, cols);
        hex_paint(ctx, v, lay, body, v.topRow, rowH, cols, font);

        if (v.minimap)
            hex_minimap(ctx, v, strip, v.topRow, maxTop, rows, visibleRows);
        else
            hex_plainbar(ctx, v, strip, v.topRow, maxTop, rows, visibleRows);

        mu_end_panel(ctx);
    }

    return res;
}

private:

// Character-grid origins, in glyph columns, shared by hit-testing and drawing.
// The byte grid is one big monospace sheet: offset column, a two-space gap, the
// hex pairs (a blank between each, an extra blank after every 8 for grouping), a
// two-space gap, then the ASCII column.
struct HexLayout
{
    int offsetDigits;
    int hexStart;   // first glyph column of the hex area
    int asciiStart; // first glyph column of the ASCII area
    int totalCols;  // full grid width, for content_size.x
    int charW;      // glyph advance, cached for pixel maths
}

// Hex digits needed to print `maxOffset`, floored at `min` (the caller's
// offsetDigits). One digit per nibble up to the value's most significant set bit;
// ulong.max lands on 16, the full width of a 64-bit address and the widest the
// fixed offset scratch in hex_draw_row holds, so no separate cap is needed.
int hex_fit_digits(ulong maxOffset, int min)
{
    import core.bitop : bsr;

    if (min <= 0) min = 8;
    int digits = maxOffset ? bsr(maxOffset) / 4 + 1 : 1;
    return digits > min ? digits : min;
}

unittest
{
    // Floored at the caller's minimum while the value still fits.
    assert(hex_fit_digits(0, 8) == 8);
    assert(hex_fit_digits(0xffffffff, 8) == 8);  // fills 32 bits exactly, no growth

    // Grows one nibble at a time past the floor once the value needs it.
    assert(hex_fit_digits(0x100000000, 8) == 9); // one past 0xffffffff
    assert(hex_fit_digits(ulong.max, 8) == 16);  // full 64-bit width, the natural cap
    assert(hex_fit_digits(0xf, 1) == 1);
    assert(hex_fit_digits(0x10, 1) == 2);
    assert(hex_fit_digits(0xfff, 2) == 3);

    // A zero or negative floor falls back to the conventional 8.
    assert(hex_fit_digits(0, 0) == 8);
    assert(hex_fit_digits(0, -4) == 8);
}

HexLayout hex_layout(int offsetDigits, int cols, int charW)
{
    if (offsetDigits <= 0) offsetDigits = 8;
    HexLayout lay;
    lay.offsetDigits = offsetDigits;
    lay.charW = charW;
    lay.hexStart = offsetDigits + 2;
    // Each byte: 2 digits + 1 space = 3 cols; +1 extra space per completed group
    // of 8. The last byte needs no trailing group space, hence (cols - 1) / 8.
    int hexCols = cols * 3 + (cols - 1) / 8;
    lay.asciiStart = lay.hexStart + hexCols + 2;
    lay.totalCols = lay.asciiStart + cols;
    return lay;
}

// Glyph column where byte `i`'s hex pair begins.
int hex_col_for(ref const(HexLayout) lay, int i)
{
    return lay.hexStart + i * 3 + i / 8;
}

unittest
{
    // 8-digit offset, 16 columns, 1px glyphs: check the documented origins.
    HexLayout lay = hex_layout(8, 16, 1);
    assert(lay.offsetDigits == 8);
    assert(lay.hexStart == 10);          // 8 offset digits + 2-space gap
    assert(lay.asciiStart == 61);        // hexStart + 49 hex cols + 2-space gap
    assert(lay.totalCols == 77);         // asciiStart + 16 ascii glyphs

    assert(hex_col_for(lay, 0) == 10);   // first pair at hexStart
    assert(hex_col_for(lay, 1) == 13);   // +3 cols per byte (2 digits + space)
    assert(hex_col_for(lay, 8) == 35);   // +1 extra group space after the first 8

    // A non-positive offset width defaults to 8.
    assert(hex_layout(0, 16, 1).offsetDigits == 8);
}

immutable char[16] HEX_DIGITS = "0123456789abcdef";

// Write `digits` hex chars of `value` into buf (most significant first).
void hex_format(char* buf, ulong value, int digits)
{
    for (int i = digits - 1; i >= 0; --i)
    {
        buf[i] = HEX_DIGITS[value & 0xf];
        value >>= 4;
    }
}

unittest
{
    char[16] buf = void;
    hex_format(buf.ptr, 0xdeadbeef, 8);
    assert(buf[0 .. 8] == "deadbeef");

    hex_format(buf.ptr, 0, 4);
    assert(buf[0 .. 4] == "0000"); // zero-padded to width

    hex_format(buf.ptr, 0x100000000UL, 9);
    assert(buf[0 .. 9] == "100000000"); // a 9-digit address survives when given the width

    hex_format(buf.ptr, 0x100000000UL, 4);
    assert(buf[0 .. 4] == "0000"); // too-narrow width keeps only the low nibbles
}

// Fixed column titles: the offset heading and the 00..0F byte-lane numbers,
// drawn dim so they read as chrome rather than data.
void hex_header(mu_Context* ctx, ref const(HexView) v, ref const(HexLayout) lay,
    int rowH, mu_Font font)
{
    int head = -1;
    mu_layout_row(ctx, 1, &head, rowH);
    mu_Rect r = mu_layout_next(ctx);

    // The header labels the grid, so it belongs to the grid's surface rather
    // than to whatever the caller's window is painted in: take the same canvas
    // the panel body below gets. A transparent canvas draws nothing, leaving the
    // window's own colour showing, as before.
    mu_draw_rect(ctx, r, ctx.style.colors[MU_COLOR_PANELBG]);

    mu_push_clip_rect(ctx, r);

    mu_Color dim = mu_Color(140, 140, 150, 255);
    int charW = lay.charW;

    mu_draw_text(ctx, font, "offset", 6, mu_Vec2(r.x, r.y), dim);

    int cols = v.columns > 0 ? v.columns : 16;
    char[2] cell = void;
    for (int i; i < cols; ++i)
    {
        hex_format(cell.ptr, i & 0xff, 2);
        int x = r.x + hex_col_for(lay, i) * charW;
        mu_draw_text(ctx, font, cell.ptr, 2, mu_Vec2(x, r.y), dim);
    }

    int ax = r.x + lay.asciiStart * charW;
    mu_draw_text(ctx, font, "ascii", 5, mu_Vec2(ax, r.y), dim);

    mu_pop_clip_rect(ctx);
}

// Map a mouse position (screen space) to a byte index, or -1 if it misses a
// cell. Both the hex pairs and the ASCII column are hittable.
long hex_hit(ref const(HexLayout) lay, mu_Rect body, long topRow, int rowH,
    int cols, size_t total, int mx, int my)
{
    int localX = mx - body.x;
    int localY = my - body.y;
    if (localX < 0 || localY < 0)
        return -1;

    long row = topRow + localY / rowH;
    int col = localX / lay.charW;

    // ASCII column: one glyph per byte, contiguous.
    int ai = col - lay.asciiStart;
    if (ai >= 0 && ai < cols)
        return hex_index(row, cols, ai, total);

    // Hex column: two glyphs per byte with gaps; walk the lanes to find a hit.
    for (int i; i < cols; ++i)
    {
        int start = hex_col_for(lay, i);
        if (col == start || col == start + 1)
            return hex_index(row, cols, i, total);
    }
    return -1;
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
    assert(hex_index(1, 16, 2, 100) == 18);  // row*cols + i
    assert(hex_index(6, 16, 3, 100) == 99);  // last valid byte
    assert(hex_index(-1, 16, 0, 100) == -1); // negative row misses
    assert(hex_index(6, 16, 4, 100) == -1);  // 100 >= total, past EOF
    assert(hex_index(10, 16, 0, 100) == -1); // whole row past EOF
}

// Mouse and keyboard handling. Returns MU_RES_CHANGE when the selection moved.
int hex_input(mu_Context* ctx, const(char)* name, ref HexView v,
    ref const(HexLayout) lay, mu_Rect body, int rowH, int cols, int visibleRows)
{
    mu_Id id = mu_get_id(ctx, name, cast(int) hex_strlen(name));
    // A caller can hand the panel focus between frames (see takeFocus); claim it
    // before mu_update_control, which is what reports the focus as still live
    // this frame and keeps ddui from dropping it at frame end.
    if (v.takeFocus)
    {
        v.takeFocus = false;
        mu_set_focus(ctx, id);
    }
    // Hold focus so the caret keeps taking keys after the click is released,
    // and join the tab ring so the panel is reachable without a mouse.
    mu_update_control(ctx, id, body, MU_OPT_HOLDFOCUS | MU_OPT_TABSTOP);

    int res = 0;
    size_t total = hex_total(v);
    bool editable = hex_editable(v);
    // An empty read-only panel has nothing to drive; an empty editable one still
    // takes digits to build a file from scratch, so only bail when both hold.
    if (total == 0 && editable == false)
        return 0;

    // Editing lets the caret park one slot past the last byte, an append point at
    // EOF; a read-only view keeps it on a real byte.
    long caretMax = editable ? cast(long) total : cast(long) total - 1;

    bool shift = (ctx.key_down & MU_KEY_SHIFT) != 0;

    // Press: place the caret; drag: extend it. mu_mouse_over honours the panel
    // clip, so presses on the scrollbar or header do not land here.
    if (ctx.mouse_pressed == MU_MOUSE_LEFT && mu_mouse_over(ctx, body))
    {
        long hit = hex_hit(lay, body, v.topRow, rowH, cols, total,
            ctx.mouse_pos.x, ctx.mouse_pos.y);
        if (hit >= 0)
        {
            v.cursor = cast(size_t) hit;
            if (shift == false || v.active == false)
                v.anchor = v.cursor;
            v.active = true;
            v.editLow = false; // fresh caret starts on a byte's high nibble
            res |= MU_RES_CHANGE;
        }
    }
    else if (ctx.focus == id && (ctx.mouse_down & MU_MOUSE_LEFT) && v.active)
    {
        long hit = hex_hit(lay, body, v.topRow, rowH, cols, total,
            ctx.mouse_pos.x, ctx.mouse_pos.y);
        if (hit >= 0 && cast(size_t) hit != v.cursor)
        {
            v.cursor = cast(size_t) hit;
            v.editLow = false;
            res |= MU_RES_CHANGE;
        }
    }

    // Keyboard caret: only when focused. Movement clamps to the buffer; Shift
    // keeps the anchor to grow a selection, otherwise it collapses to a caret.
    if (ctx.focus == id && ctx.key_pressed && v.active)
    {
        long dst = cast(long) v.cursor;
        bool low = v.editLow;
        int keys = ctx.key_pressed;
        int page = mu_max(1, (visibleRows - 1) * cols);
        bool ctrl = (ctx.key_down & MU_KEY_CTRL) != 0;

        // Vertical and paging moves are byte-granular and land on a fresh byte,
        // so they restart nibble entry on the high nibble.
        bool byteMove = (keys & (HEX_KEY_UP | HEX_KEY_DOWN | HEX_KEY_PGUP |
            HEX_KEY_PGDN | HEX_KEY_HOME | HEX_KEY_END)) != 0;
        if (keys & HEX_KEY_UP)    dst -= cols;
        if (keys & HEX_KEY_DOWN)  dst += cols;
        if (keys & HEX_KEY_PGUP)  dst -= page;
        if (keys & HEX_KEY_PGDN)  dst += page;
        if (keys & HEX_KEY_HOME)  dst = ctrl ? 0 : dst - dst % cols;                 // Ctrl: SOF, else row start
        if (keys & HEX_KEY_END)   dst = ctrl ? caretMax : dst + (cols - 1) - (dst % cols);  // Ctrl: EOF, else row end
        if (byteMove) low = false;

        // Left / Right walk one nibble at a time when editing, so the caret
        // advances digit by digit the way typing does. Extending a selection, or a
        // read-only view with no nibble caret, steps a whole byte instead.
        if (keys & (HEX_KEY_LEFT | HEX_KEY_RIGHT))
        {
            if (editable && shift == false)
            {
                // The append slot past EOF has just a high nibble, so caretMax * 2
                // (its high nibble) caps the walk; the low nibbles below stay reachable.
                long maxNib = caretMax * 2;
                long nib = dst * 2 + (low ? 1 : 0);
                if (keys & HEX_KEY_LEFT)  nib -= 1;
                if (keys & HEX_KEY_RIGHT) nib += 1;
                nib = mu_clamp(nib, 0L, maxNib);
                dst = nib / 2;
                low = (nib & 1) != 0;
            }
            else
            {
                if (keys & HEX_KEY_LEFT)  dst -= 1;
                if (keys & HEX_KEY_RIGHT) dst += 1;
                low = false;
            }
        }

        dst = mu_clamp(dst, 0L, caretMax);
        if (cast(size_t) dst != v.cursor || low != v.editLow)
        {
            v.cursor  = cast(size_t) dst;
            v.editLow = low;
            if (shift == false)
                v.anchor = v.cursor;
            res |= MU_RES_CHANGE;
            hex_reveal(v, v.cursor, cols, visibleRows);
        }
    }

    // Editing keys: only with the write hooks in place and the panel focused.
    if (editable && ctx.focus == id && v.active)
    {
        // Insert key flips overwrite <-> insert; restart the current byte's entry
        // so the mode change applies from a clean nibble.
        if (ctx.key_pressed & HEX_KEY_INS)
        {
            v.insertMode = v.insertMode == false;
            v.editLow = false;
        }

        // Delete / Backspace drop the selection whole, else one byte.
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

        // Hex digits typed as text: fold each nibble into the byte under the caret.
        for (const(char)* p = ctx.input_text.ptr; *p; ++p)
        {
            int nib = hex_nibble(*p);
            if (nib < 0)
                continue; // ignore any non-hex text (ascii-pane editing is not here)
            hex_edit_nibble(v, nib, cols, visibleRows);
            res |= MU_RES_CHANGE;
        }
    }

    // Undo / redo: Ctrl+Z steps back, Ctrl+Y (or Ctrl+Shift+Z) forward. The hook
    // returns where the change landed - undo at its start, redo at its end - and
    // refreshes dataSize as a side effect, so hex_total is current when we clamp
    // the caret onto it below.
    if (ctx.focus == id && v.active && (ctx.key_down & MU_KEY_CTRL) &&
        (v.undoFn || v.redoFn))
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

// Whether the panel carries the full set of write hooks needed to edit.
bool hex_editable(ref const(HexView) v)
{
    return v.replaceFn && v.insertFn && v.removeFn;
}

// Apply one typed hex nibble at the caret, overwriting or inserting per the mode.
// The high nibble starts (or splices) the byte; the low nibble completes it and
// steps the caret on. dataSize is kept live so hex_total stays right this frame.
void hex_edit_nibble(ref HexView v, int nib, int cols, int visibleRows)
{
    long pos = cast(long) v.cursor;

    if (v.editLow == false)
    {
        // High nibble. Insert mode, an empty document, or the caret parked at EOF
        // all splice a fresh byte; otherwise overwrite the byte in place, keeping
        // its existing low nibble.
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
        // Low nibble: fold into the byte written above, then step to the next.
        v.editByte = cast(ubyte)((v.editByte & 0xf0) | nib);
        v.replaceFn(pos, v.editByte, v.writeUser);
        v.editLow = false;
        if (cast(long) v.cursor + 1 <= cast(long) hex_total(v))
            ++v.cursor;
        v.anchor = v.cursor;
        hex_reveal(v, v.cursor, cols, visibleRows);
    }
}

// Delete the selection, or one byte, on Delete/Backspace. `back` true steps the
// caret back before deleting (Backspace); false drops the byte under it (Delete).
void hex_delete(ref HexView v, bool back, int cols, int visibleRows)
{
    size_t total = hex_total(v);
    if (total == 0)
        return;

    size_t low  = hex_sel_low(v);
    size_t high = hex_sel_high(v);

    if (low != high) // a real range: drop it whole
    {
        long len = cast(long)(high - low + 1);
        if (high >= total) len = cast(long) total - cast(long) low; // clamp off the append slot
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
    else // forward delete
    {
        if (v.cursor >= total) // append slot: nothing under the caret
            return;
        v.removeFn(cast(long) v.cursor, 1, v.writeUser);
        if (v.readFn) --v.dataSize;
    }

    v.anchor  = v.cursor;
    v.editLow = false;
    hex_reveal(v, v.cursor, cols, visibleRows);
}

// Scroll so the caret's row is in view after a keyboard move. Nudges the
// row-based scroll position; hex_view re-clamps it after input.
void hex_reveal(ref HexView v, size_t cursor, int cols, int visibleRows)
{
    long row = cast(long)(cursor / cols);
    if (row < v.topRow)
        v.topRow = row;
    else if (row >= v.topRow + visibleRows)
        v.topRow = row - visibleRows + 1;
}

// Refill the window scratch with the rows currently on screen, so painting reads
// only the visible slice from the editor. No-op for the in-memory data path.
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
    if (v.windowBuf.length < need)
        v.windowBuf.length = need;

    ubyte[] got = v.readFn(cast(long) start, v.windowBuf[0 .. need], v.readUser);
    v.windowStart = start;
    v.windowLen   = got.length;
}

// Draw the minimap ribbon and let it drive the scroll position. The ribbon maps
// the whole document onto its height; each block is coloured by the dominant
// class of the segment it covers, through the panel's own colour scheme. The
// mapping is by row (not pixel), so it holds up on files of any size.
void hex_minimap(mu_Context* ctx, ref HexView v, mu_Rect strip,
    long topRow, long maxTop, long rows, int visibleRows)
{
    mu_draw_rect(ctx, strip, mu_Color(20, 20, 28, 255)); // ribbon backdrop

    size_t total = hex_total(v);
    int cells = strip.h / MINIMAP_BLOCK;
    if (total == 0 || cells <= 0)
        return;

    hex_build_minimap(v, cells);

    foreach (i, c; v.mapCells)
    {
        int y = strip.y + cast(int) i * MINIMAP_BLOCK;
        mu_draw_rect(ctx, mu_Rect(strip.x, y, strip.w, MINIMAP_BLOCK), c);
    }

    // Viewport marker: the visible row span mapped onto the ribbon. On big files
    // that span is a fraction of a pixel, so floor its height to keep a visible
    // region rather than a hairline, and clamp it inside the ribbon.
    if (rows > 0)
    {
        int hy = strip.y + cast(int)(topRow * strip.h / rows);
        int hh = cast(int)(cast(long) visibleRows * strip.h / rows);
        if (hh < MINIMAP_VIEW_MIN) hh = MINIMAP_VIEW_MIN;
        if (hy + hh > strip.y + strip.h) hy = strip.y + strip.h - hh;
        if (hy < strip.y) hy = strip.y;
        mu_Rect view = mu_Rect(strip.x - MINIMAP_VIEW_OUT, hy,
            strip.w + MINIMAP_VIEW_OUT * 2, hh);
        mu_draw_rect(ctx, view, mu_Color(150, 185, 235, 70)); // translucent region tint
        mu_draw_box(ctx, view, mu_Color(190, 215, 255, 255));  // crisp region border
    }

    // Click or drag anywhere on the ribbon to centre the view there.
    mu_Id id = mu_get_id(ctx, "!hexminimap".ptr, 11);
    mu_update_control(ctx, id, strip, 0);
    if (ctx.focus == id && (ctx.mouse_down & MU_MOUSE_LEFT) && maxTop > 0)
    {
        int localY = ctx.mouse_pos.y - strip.y;
        long target = cast(long) localY * rows / strip.h - visibleRows / 2;
        v.topRow = mu_clamp(target, 0L, maxTop);
    }
}

// The plain scroll strip shown when the minimap is off: a track with a thumb
// sized to the visible fraction of the document. Like the minimap it is driven
// in row units, so it stays exact no matter how large the file is.
void hex_plainbar(mu_Context* ctx, ref HexView v, mu_Rect strip,
    long topRow, long maxTop, long rows, int visibleRows)
{
    mu_draw_rect(ctx, strip, mu_Color(20, 20, 28, 255)); // track
    if (rows <= 0 || strip.h <= 0)
        return;

    // Thumb sized to the visible fraction, floored so it stays grabbable.
    int thumbH = cast(int)(cast(long) visibleRows * strip.h / rows);
    if (thumbH < SCROLLBAR_THUMB_MIN) thumbH = SCROLLBAR_THUMB_MIN;
    if (thumbH > strip.h) thumbH = strip.h;
    int travel = strip.h - thumbH;
    int ty = strip.y + (maxTop > 0 ? cast(int)(topRow * travel / maxTop) : 0);
    mu_draw_rect(ctx, mu_Rect(strip.x, ty, strip.w, thumbH),
        mu_Color(90, 110, 150, 255)); // thumb

    // Click or drag to move the thumb; its centre follows the cursor.
    mu_Id id = mu_get_id(ctx, "!hexscroll".ptr, 10);
    mu_update_control(ctx, id, strip, 0);
    if (ctx.focus == id && (ctx.mouse_down & MU_MOUSE_LEFT) && maxTop > 0 && travel > 0)
    {
        int localY = ctx.mouse_pos.y - strip.y - thumbH / 2;
        long target = cast(long) localY * maxTop / travel;
        v.topRow = mu_clamp(target, 0L, maxTop);
    }
}

// Rebuild the minimap colour cache: sample each segment of the document with a
// fixed byte budget and record its dominant colour. File-size independent - a
// 1 TB file and a 1 KB file both cost `cells` small reads - and only run when
// the size or the ribbon height actually changed.
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
        long span  = end - start;
        if (span <= 0)
        {
            v.mapCells[c] = mu_Color(0, 0, 0, 0);
            continue;
        }
        size_t take = span < MINIMAP_PROBE ? cast(size_t) span : MINIMAP_PROBE;
        ubyte[] chunk = hex_probe(v, start, v.mapProbe[0 .. take]);
        v.mapCells[c] = hex_dominant(v, chunk, start);
    }
}

// Read up to buf.length bytes at document offset `pos`, from the editor window
// source or the in-memory slice. Returns the bytes actually available.
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

// Dominant colour of a sampled chunk: classify each byte through the panel's
// scheme (hex_classify by default) and return the most common colour, so the
// ribbon and the byte grid always agree on how a region looks.
mu_Color hex_dominant(ref const(HexView) v, const(ubyte)[] chunk, long baseOff)
{
    if (chunk.length == 0)
        return mu_Color(0, 0, 0, 0);

    HexColorFn colorFn = v.colorFn ? v.colorFn : &hex_classify;
    void* user = cast(void*) v.colorUser;

    // Small fixed tally: hex_classify yields a handful of colours, so a short
    // distinct list covers it; any beyond the cap just miss the vote.
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
    assert(hex_coleq(a, mu_Color(9, 2, 3, 4)) == false); // r differs
    assert(hex_coleq(a, mu_Color(1, 2, 3, 5)) == false); // a differs, must still count
}

// Draw the visible rows: only the slice inside the viewport is emitted, so the
// command count stays bounded regardless of buffer size.
void hex_paint(mu_Context* ctx, ref const(HexView) v, ref const(HexLayout) lay,
    mu_Rect body, long topRow, int rowH, int cols, mu_Font font)
{
    size_t total = hex_total(v);
    long rows  = (cast(long) total + cols - 1) / cols;
    int charW = lay.charW;

    // Empty document: no bytes, but still draw the first row's offset and a caret
    // so it reads as an insertion point ready to build a file from scratch.
    if (rows == 0)
    {
        char[24] off = void;
        int digits = lay.offsetDigits > off.length ? cast(int) off.length : lay.offsetDigits;
        hex_format(off.ptr, cast(ulong) v.baseAddress, digits);
        mu_draw_text(ctx, font, off.ptr, digits, mu_Vec2(body.x, body.y),
            mu_Color(150, 150, 160, 255));
        if (v.active)
            hex_draw_caret(ctx, lay, body.x, body.y, 0, charW, rowH, hex_caret_nib(v));
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
    {
        int y = body.y + cast(int)((row - topRow) * rowH);
        hex_draw_row(ctx, v, lay, colorFn, body.x, y, row, cols, rowH, charW,
            selLow, selHigh, font);
    }

    // Append caret: when editing parks the caret one slot past the last byte, it
    // sits in no row's byte range, so draw it here in the empty EOF cell. That
    // cell can open a fresh row (when the file fills its last row exactly).
    if (v.active && v.cursor == total)
    {
        long row = cast(long)(total / cols);
        int col = cast(int)(total % cols);
        if (row >= firstRow && row <= lastRow + 1)
        {
            int y = body.y + cast(int)((row - topRow) * rowH);
            hex_draw_caret(ctx, lay, body.x, y, col, charW, rowH, hex_caret_nib(v));
        }
    }
}

void hex_draw_row(mu_Context* ctx, ref const(HexView) v, ref const(HexLayout) lay,
    HexColorFn colorFn, int originX, int y, long row, int cols, int rowH,
    int charW, size_t selLow, size_t selHigh, mu_Font font)
{
    size_t total = hex_total(v);
    size_t rowStart = cast(size_t)(row * cols);
    int count = cast(int) mu_min(cast(size_t) cols, total - rowStart);

    mu_Color offColor = mu_Color(150, 150, 160, 255);
    mu_Color selColor = mu_Color(48, 84, 140, 255); // selection wash

    // Offset label.
    char[24] off = void;
    int digits = lay.offsetDigits > off.length ? cast(int) off.length : lay.offsetDigits;
    hex_format(off.ptr, cast(ulong)(v.baseAddress + row * cols), digits);
    mu_draw_text(ctx, font, off.ptr, digits, mu_Vec2(originX, y), offColor);

    // Selection wash, drawn before the glyphs so text sits on top. A row's
    // selected bytes are contiguous, so at most one hex band and one ASCII band.
    // A bare caret (selLow == selHigh) draws no wash; only the outline below.
    if (v.active && selLow != selHigh && selHigh >= rowStart && selLow < rowStart + count)
    {
        int lo = selLow  > rowStart ? cast(int)(selLow - rowStart) : 0;
        int hi = selHigh < rowStart + count ? cast(int)(selHigh - rowStart) : count - 1;

        int hx = originX + hex_col_for(lay, lo) * charW;
        int hw = (hex_col_for(lay, hi) + 2 - hex_col_for(lay, lo)) * charW;
        mu_draw_rect(ctx, mu_Rect(hx, y, hw, rowH), selColor);

        int ax = originX + (lay.asciiStart + lo) * charW;
        int aw = (hi - lo + 1) * charW;
        mu_draw_rect(ctx, mu_Rect(ax, y, aw, rowH), selColor);
    }

    // Byte cells: each hex pair and its ASCII glyph share the byte's colour.
    char[2] cell = void;
    char[1] ch = void;
    for (int i; i < count; ++i)
    {
        size_t idx = rowStart + i;
        ubyte b = hex_byte(v, idx);
        mu_Color color = colorFn(idx, b, cast(void*) v.colorUser);

        hex_format(cell.ptr, b, 2);
        int hx = originX + hex_col_for(lay, i) * charW;
        mu_draw_text(ctx, font, cell.ptr, 2, mu_Vec2(hx, y), color);

        ch[0] = (b >= 0x20 && b < 0x7f) ? cast(char) b : '.';
        int ax = originX + (lay.asciiStart + i) * charW;
        mu_draw_text(ctx, font, ch.ptr, 1, mu_Vec2(ax, y), color);
    }

    // Caret outline around the single moving byte.
    if (v.active && v.cursor >= rowStart && v.cursor < rowStart + count)
        hex_draw_caret(ctx, lay, originX, y, cast(int)(v.cursor - rowStart), charW, rowH,
            hex_caret_nib(v));
}

// Which nibble the caret boxes on the byte under it: -1 for the whole pair (a
// read-only view has no nibble entry), 0 for the high nibble, 1 for the low.
// Editing narrows the caret to the digit the next keypress lands in, matching
// the nibble-caret convention of GHex and friends.
int hex_caret_nib(ref const(HexView) v)
{
    if (hex_editable(v) == false)
        return -1;
    return v.editLow ? 1 : 0;
}

// Draw the caret outline (hex and ASCII lanes) around grid column `col` of the
// row at `y`. Shared by the normal rows and the empty-document caret. `nib` picks
// the hex-lane box: -1 spans the whole pair, 0 the high digit, 1 the low; the
// ASCII lane is always one glyph, since a character has no sub-position.
void hex_draw_caret(mu_Context* ctx, ref const(HexLayout) lay, int originX, int y,
    int col, int charW, int rowH, int nib)
{
    mu_Color curColor = mu_Color(120, 170, 235, 255); // caret outline
    int hx = originX + hex_col_for(lay, col) * charW;
    if (nib < 0)
        mu_draw_box(ctx, mu_Rect(hx - 1, y, 2 * charW + 2, rowH), curColor);
    else
        mu_draw_box(ctx, mu_Rect(hx + nib * charW - 1, y, charW + 2, rowH), curColor);
    int ax = originX + (lay.asciiStart + col) * charW;
    mu_draw_box(ctx, mu_Rect(ax - 1, y, charW + 2, rowH), curColor);
}

// Local strlen so the module needs no C import for one call.
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
