/// A hex panel widget for ddui.
///
/// The classic three columns (offset / hex / ASCII) in a monospace face, tinted
/// through a caller-supplied colour scheme, with a selection the caller can read
/// back. It rides on a ddui panel container for clipping and wheel routing, but
/// scrolls in row units - a multi-gigabyte file overflows a pixel offset - and
/// draws its rows by hand, so only the bytes on screen are ever touched.
/// Authors: dd86k <dd@dax.moe>
module hexview;

import ddui;

/// Extra ddui key bits for the hex panel's caret. ddui's own MU_KEY_* flags
/// stop at (1 << 5); these carry on from there so both can share ctx.key_down.
/// main.d maps the arrow / paging keys onto them. Kept as a bitmask (rather than
/// distinct codes) to match how ddui feeds keys, one OR per pressed key.
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

/// Per-byte colour hook. Return the colour for the byte at `offset` (its value
/// is passed so the common "colour by value" schemes need no buffer access).
/// `user` is the pointer handed to HexView.colorUser, for schemes that need
/// outside context (a type map, a diff mask, a search hit set...).
alias HexColorFn = mu_Color function(size_t offset, ubyte value, void* user);

/// Per-byte background hook (`user` is HexView.backUser). Return the wash to fill
/// the byte's cell with before its glyphs go down, or any colour with alpha 0 for
/// none; runs of one colour are drawn as a single band.
///
/// Separate from HexColorFn because the two answer different questions: the
/// foreground says what a byte *is*, the background what has been *done* to it
/// (marked, hit by a find). Overloading the first for the second costs it on
/// exactly the bytes the user singled out.
alias HexBackFn = mu_Color function(size_t offset, ubyte value, void* user);

/// Ditto, asked of a whole span for the minimap: the wash for the run of `length`
/// bytes from `at`, or alpha 0 when no byte in it carries one.
///
/// The ribbon cannot go through HexBackFn per byte, one cell standing for a
/// segment that may be gigabytes, nor through the sampled read hex_dominant uses,
/// which would step over a short mark. So it asks the span outright.
alias HexBackSpanFn = mu_Color function(long at, long length, void* user);

/// The extent of one structure span, and the colour its border is drawn in.
struct HexSpan
{
    long start;
    long length;
    mu_Color edge;
}

/// Structure hook: the span covering `pos` at nesting level `level`, counted inwards
/// from the outermost - 0 the record at the top, 1 whatever of it holds the byte - or
/// false when nothing covers it. `user` is HexView.spanUser.
///
/// From the outside rather than from the byte, because that is the question a border
/// grouping a record asks. A chunk's length field and a byte deep in its payload sit
/// at different depths, so counting outwards from each would put them in different
/// boxes; counted inwards they are both in the chunk, which is where they are.
///
/// It answers with an extent rather than a colour to join neighbouring cells by, which
/// is what separates it from HexBackFn: two fields of one kind side by side are two
/// fields, and joining them by what they look like would draw one box where the
/// document has two. Cells join only when their spans begin in the same place.
///
/// It is asked by offset alone, never about a byte's value, so the panel can ask it
/// about the rows above and below the one it is drawing - which is what lets a field
/// spanning several rows come out as one region rather than as a box per row.
alias HexSpanFn = bool function(long pos, int level, ref HexSpan span, void* user);

/// On-demand byte source, for showing a slice of something too large to hold in
/// memory. Fill `buf` from document offset `pos` and return the bytes actually
/// read (a short slice at EOF is fine); `user` is HexView.readUser. With this set
/// the panel pulls only the on-screen rows through it and ignores `data`.
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

/// Undo / redo hooks: step the document's edit history one entry, returning the
/// offset the change touched (undo: the start of the region, redo: its end) so the
/// panel can move the caret onto it, or -1 when there is nothing left to step.
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
    WASH_EDGE_LIFT = 200, // how much brighter a wash's outline is, in percent
    SPAN_PAD = 1, // gap a structure border keeps off its cells, so it reads as a box
                  // round the bytes rather than as another gridline between them
    MARGIN_HEX  = 2,    // px marging (bleed) for hex cells
    MARGIN_TEXT = 1,    // px marging (bleed) for text characters
                        // making this 2 makes overlapping lines visible due to a created gap
}

/// Wash behind the selected bytes, in the grid and on the minimap ribbon. The
/// topmost of the panel's backgrounds: see the rendering priority in hex_draw_row.
enum mu_Color HEX_SEL_WASH = mu_Color(48, 84, 140, 255);

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
    /// Minimum hex digits in the offset column, 8 fitting a 32-bit span. The panel
    /// widens past this on its own when the highest address needs more.
    int offsetDigits = 8;
    /// Show the minimap ribbon down the right edge, coloured through the same
    /// scheme as the bytes; false shows a wider plain scrollbar instead. Read each
    /// frame, so a toolbar can flip it.
    bool minimap = true;

    /// Caret byte index (the moving end of the selection).
    size_t cursor;
    /// Anchor byte index (the fixed end). The selection spans [anchor, cursor].
    size_t anchor;
    /// Whether a caret / selection exists yet. Set on the first click or key.
    bool active;

    /// Hand the panel keyboard focus on the next frame it draws, for a caller that
    /// puts a document in front from outside a frame - opening a file, switching
    /// tabs - after which typing should land in the bytes. Cleared once honoured.
    bool takeFocus;

    /// Optional per-byte colour scheme. Null falls back to hex_classify.
    HexColorFn colorFn;
    /// Opaque pointer forwarded to colorFn.
    void* colorUser;

    /// Optional per-byte background wash, drawn under the glyphs. See HexBackFn.
    HexBackFn backFn;
    /// Span form of the same, for the minimap ribbon. Supply it alongside backFn to
    /// have the wash show up there too; null leaves the ribbon coloured by class
    /// alone. See HexBackSpanFn.
    HexBackSpanFn backSpanFn;
    /// Opaque pointer forwarded to both background hooks.
    void* backUser;

    /// Optional structure hook, drawing a border round the record each byte belongs
    /// to. See HexSpanFn.
    HexSpanFn spanFn;
    /// Opaque pointer forwarded to spanFn.
    void* spanUser;
    /// How many nesting levels get a border, outermost first; 0 draws none. One box
    /// per record groups; a box per field as well only makes a grid out of a grid.
    int spanDepth = 1;

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
    /// and Insert flips between overwrite and insert. Edits are addressed by
    /// document offset against the same source the reads come from, so editing
    /// implies the readFn path.
    HexReplaceFn replaceFn;
    /// Ditto.
    HexInsertFn insertFn;
    /// Ditto.
    HexRemoveFn removeFn;
    /// Opaque pointer forwarded to the write hooks (the editor, in practice).
    void* writeUser;

    /// Optional undo / redo hooks, letting Ctrl+Z and Ctrl+Y (or Ctrl+Shift+Z) walk
    /// the editor's history with the caret following the change. They take
    /// HexView.writeUser like the write hooks. See HexUndoFn.
    HexUndoFn undoFn;
    /// Ditto.
    HexRedoFn redoFn;

    /// Insert vs overwrite entry. Overwrite (the default) edits the nibble under
    /// the caret in place; insert splices a fresh byte in and pushes the rest up.
    bool insertMode;

    /// Byte the pointer is resting on this frame, or -1 for none. Written by hex_view
    /// on every frame it draws, for a caller with something to say about the byte
    /// under the pointer rather than the one under the caret.
    ///
    /// Only one panel can hold the pointer, so a caller with several of them can find
    /// the hovered one by asking each rather than being told.
    long hoverByte = -1;

    private:

    // Index of the first visible row, the single source of truth for what is on
    // screen. In rows rather than pixels, the grid's full pixel height blowing past
    // a 32-bit int on a multi-gigabyte file. hex_view owns it.
    long topRow;
    // Leftover wheel pixels below one row height, carried between frames so a slow
    // wheel still advances when a notch is shorter than a row.
    int wheelAccum;
    // Rows that fit on screen, measured by hex_view each frame. Kept here so a
    // caret move driven from outside a frame (hex_set_caret) can scroll to it
    // without the caller knowing the panel's geometry.
    int visRows = 1;

    // Nibble sub-position within the caret byte: false means the next hex digit is
    // the byte's high nibble, true its low. Reset on any caret move. editByte holds
    // what the high nibble wrote, so the low one folds in without re-reading.
    bool editLow;
    ubyte editByte;

    // Whether the mouse button now held went down inside this panel's grid, which
    // is what a selection drag needs. Focus alone will not do: it can arrive
    // between frames (see takeFocus), and a button held for something else - a tab
    // being dragged across the window - would then sweep out a selection.
    bool dragSel;

    // Reused scratch for the visible window when reading through readFn, refilled
    // every frame, so a huge document costs only a screenful of bytes here.
    ubyte[] windowBuf;   // capacity, kept across frames
    size_t windowStart;  // document offset of windowBuf[0]
    size_t windowLen;    // valid bytes currently in windowBuf

    // One colour per vertical minimap cell, each the dominant class of the file
    // segment it covers. Rebuilt only when the document size or the cell count
    // changes, so a still view redraws it for free.
    mu_Color[] mapCells;
    size_t mapForSize;   // document size the cache was built for
    int mapForCells;     // cell count the cache was built for
    ubyte[] mapProbe;    // reused per-cell sampling scratch
}

/// Copy `src` into a second panel onto the same bytes, for splitting a view in
/// two: the caret, selection, scroll position, column count and entry mode all
/// carry over, and the two then move independently.
///
/// A plain struct copy will not do - the scratch buffers refilled every frame
/// would have each panel drawing through whatever the other last put there - so
/// they are dropped here and reallocated on the new panel's first frame.
///
/// The hooks come across carrying the source panel's user pointers, so a caller
/// routing them per view has to point them at the new one before it draws.
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

    // The scratch does not: the two panels must not share a byte of it.
    assert(b.windowBuf is null);
    assert(b.windowLen == 0);
    assert(b.mapCells is null);
    assert(b.mapForCells == 0);

    // ... and the source keeps its own.
    assert(a.windowBuf.length == 64);
    assert(a.mapCells.length == 8);
}

/// Scroll the view back to the top. Call when a fresh document is loaded so the
/// panel never inherits the previous file's scroll offset and strands the caret
/// (which the caller has just reset to the first byte) off screen.
void hex_reset_scroll(ref HexView v)
{
    v.topRow     = 0;
    v.wheelAccum = 0;
}

/// Document offset of the first byte on screen.
///
/// For a caller keeping two panels in step - a byte-for-byte comparison. In
/// offsets rather than rows because two panels need not agree on their bytes per
/// row, and it is the byte the user is looking at that has to match.
long hex_top_offset(ref const(HexView) v)
{
    int cols = v.columns > 0 ? v.columns : 16;
    return v.topRow * cols;
}

/// Ditto, the other way: scroll so that the row holding `offset` is the first on
/// screen. Rounded down, a panel scrolling by whole rows, and the pending sub-row
/// wheel movement is dropped rather than dragging the panel off the row it was
/// just put on.
///
/// No clamping here - what fits on screen is only known while drawing - so an
/// offset past the end is safe to ask for and the next frame pulls it back.
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

    // One mid-row puts that row on top: 0x10a is in the row starting at 0x100.
    hex_set_top_offset(v, 0x10a);
    assert(hex_top_offset(v) == 0x100);

    v.wheelAccum = 7;
    hex_set_top_offset(v, 0x200);
    assert(v.wheelAccum == 0);

    // A negative offset is the top, not a negative row.
    hex_set_top_offset(v, -32);
    assert(v.topRow == 0);

    // Two panels at different widths agree on the byte, not on the row: the same
    // offset is row 16 in one and row 8 in the other.
    HexView wide;
    wide.columns = 32;
    hex_set_top_offset(wide, hex_top_offset(v) + 0x100);
    assert(wide.topRow == 8);
    assert(hex_top_offset(wide) == 0x100);
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

/// Map a hex digit to its 0-15 value, or -1 for anything else. Public so a caller
/// reading hex text of its own (a clipboard paste) agrees on what a digit is.
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
    assert(hex_nibble('g') == -1); // past 'f'
    assert(hex_nibble('/') == -1); // just below '0'
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
/// wants a column or window with a bounded height to sit in. `font` is a monospace
/// face handle (a TTF_Font*), and `reserveBottom` pixels are kept free below the
/// panel for a caller-drawn status bar (0 fills to the container floor).
/// Returns: MU_RES_CHANGE when the selection moved this frame, else 0.
int hex_view(mu_Context* ctx, const(char)* name, ref HexView v, mu_Font font,
    int reserveBottom = 0)
{
    // One glyph advance and one line height drive every placement below, and on a
    // mono face measuring "0" is enough to get them.
    int charW = ctx.text_width(font, "0", 1);
    int rowH  = ctx.text_height(font);
    if (charW <= 0) charW = 1;
    if (rowH  <= 0) rowH  = 1;

    int cols = v.columns > 0 ? v.columns : 16;
    size_t total = hex_total(v);
    long rows  = (cast(long) total + cols - 1) / cols;

    // Widen the offset column to fit the last row's label. Without this a document
    // past 0xffffffff loses its top nibbles to hex_format's fixed width.
    long lastRowOff = v.baseAddress + (rows > 0 ? (rows - 1) * cols : 0);
    int offsetDigits = hex_fit_digits(cast(ulong) lastRowOff, v.offsetDigits);

    HexLayout lay = hex_layout(offsetDigits, cols, charW);

    // Fixed above the scroll area, so it never scrolls away. The same strip the
    // panel below carves off, so the two agree on the last usable column.
    hex_header(ctx, v, lay, rowH, font, v.minimap ? MINIMAP_WIDTH : SCROLLBAR_WIDTH);

    // A negative row height fills to the container floor; pushing it up by
    // reserveBottom plus a spacing gap leaves exactly that band free below, where
    // the caller's next widget lands.
    int fill = -1;
    int panelH = reserveBottom > 0 ? -(reserveBottom + ctx.style.spacing + 1) : -1;
    mu_layout_row(ctx, 1, &fill, panelH);

    int res = 0;

    // ddui tracks scroll offsets in 32-bit pixels, which the full height of a
    // multi-gigabyte grid overflows. So the panel runs NOSCROLL and owns the strip
    // on its right edge: the minimap ribbon, or a plain thumb with it off.
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

        // NOSCROLL means ddui no longer routes the wheel, so re-arm the target
        // while the mouse is over the panel. It still folds the notch delta into
        // cnt.scroll.y at frame end, which is drained into whole rows here.
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
// The grid is one monospace sheet: offset column, a two-space gap, the hex pairs
// (a blank between each, an extra after every 8), a two-space gap, then ASCII.
struct HexLayout
{
    int offsetDigits;
    int hexStart;   // first glyph column of the hex area
    int asciiStart; // first glyph column of the ASCII area
    int totalCols;  // full grid width, for content_size.x
    int charW;      // glyph advance, cached for pixel maths
}

// Hex digits needed to print `maxOffset`, floored at `min`. ulong.max lands on
// 16, which is also the widest the offset scratch in hex_draw_row holds, so no
// separate cap is needed.
int hex_fit_digits(ulong maxOffset, int min)
{
    import core.bitop : bsr;

    if (min <= 0) min = 8;
    int digits = maxOffset ? bsr(maxOffset) / 4 + 1 : 1;
    return digits > min ? digits : min;
}

unittest
{
    assert(hex_fit_digits(0, 8) == 8);
    assert(hex_fit_digits(0xffffffff, 8) == 8);  // fills 32 bits exactly, no growth
    assert(hex_fit_digits(0x100000000, 8) == 9); // one past 0xffffffff
    assert(hex_fit_digits(ulong.max, 8) == 16);  // the natural cap
    assert(hex_fit_digits(0xf, 1) == 1);
    assert(hex_fit_digits(0x10, 1) == 2);
    assert(hex_fit_digits(0xfff, 2) == 3);

    assert(hex_fit_digits(0, 0) == 8); // a bad floor falls back to 8
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
    // 8-digit offset, 16 columns, 1px glyphs.
    HexLayout lay = hex_layout(8, 16, 1);
    assert(lay.offsetDigits == 8);
    assert(lay.hexStart == 10);          // 8 offset digits + 2-space gap
    assert(lay.asciiStart == 61);        // hexStart + 49 hex cols + 2-space gap
    assert(lay.totalCols == 77);         // asciiStart + 16 ascii glyphs

    assert(hex_col_for(lay, 0) == 10);   // first pair at hexStart
    assert(hex_col_for(lay, 1) == 13);   // +3 cols per byte (2 digits + space)
    assert(hex_col_for(lay, 8) == 35);   // +1 extra group space after the first 8

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
    assert(buf[0 .. 9] == "100000000");

    hex_format(buf.ptr, 0x100000000UL, 4);
    assert(buf[0 .. 4] == "0000"); // too narrow: only the low nibbles survive
}

// Whether `chars` glyphs starting at `x` end before `endX`. Text is clipped by
// the pixel, so a label straddling a pane's edge comes out as half a glyph, which
// reads as a digit rather than as nothing; a narrow pane stops on the last whole
// one instead. Rects (washes, the caret) are left to the clip rect, having no
// half-legible state to fall into.
bool hex_fits(int x, int chars, int charW, int endX)
{
    return x + chars * charW <= endX;
}

unittest
{
    assert(hex_fits(0, 2, 8, 16));       // exactly reaches the edge
    assert(hex_fits(0, 2, 8, 15) == false);
    assert(hex_fits(100, 5, 8, 200));
    assert(hex_fits(180, 5, 8, 200) == false); // straddles it
}

// Fixed column titles: the offset heading and the 00..0F byte-lane numbers,
// drawn dim so they read as chrome rather than data.
//
// `stripW` is the scroll strip the grid below gives up on its right edge; the
// header row spans it, so without subtracting it a narrow pane labels one more
// column than hex_paint has room to draw.
void hex_header(mu_Context* ctx, ref const(HexView) v, ref const(HexLayout) lay,
    int rowH, mu_Font font, int stripW)
{
    int head = -1;
    mu_layout_row(ctx, 1, &head, rowH);
    mu_Rect r = mu_layout_next(ctx);

    // The header labels the grid, so it takes the same canvas the panel body gets
    // rather than the caller's window colour. A transparent canvas draws nothing,
    // leaving that colour showing anyway.
    mu_draw_rect(ctx, r, ctx.style.colors[MU_COLOR_PANELBG]);

    mu_push_clip_rect(ctx, r);

    mu_Color dim = mu_Color(140, 140, 150, 255);
    int charW = lay.charW;

    int endX = r.x + r.w - stripW;
    if (hex_fits(r.x, 6, charW, endX))
        mu_draw_text(ctx, font, "offset", 6, mu_Vec2(r.x, r.y), dim);

    int cols = v.columns > 0 ? v.columns : 16;
    char[2] cell = void;
    for (int i; i < cols; ++i)
    {
        int x = r.x + hex_col_for(lay, i) * charW;
        if (hex_fits(x, 2, charW, endX) == false)
            break; // columns only go rightwards
        hex_format(cell.ptr, i & 0xff, 2);
        mu_draw_text(ctx, font, cell.ptr, 2, mu_Vec2(x, r.y), dim);
    }

    int ax = r.x + lay.asciiStart * charW;
    if (hex_fits(ax, 5, charW, endX))
        mu_draw_text(ctx, font, "ascii", 5, mu_Vec2(ax, r.y), dim);

    mu_pop_clip_rect(ctx);
}

unittest
{
    // Drive real frames at widths that cut the grid mid-column and check every
    // text command the header and the rows emit: none may cross the pane's edge,
    // where the clip rect would halve a glyph.
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

    // The strip the grid gives up on its right edge: the header spans it, so it
    // has to end that much earlier or it labels a column with no bytes under it.
    enum int STRIP = MINIMAP_WIDTH;

    // Two-glyph draws on line `topY` are the header's column labels and the grid's
    // byte pairs; the offset (8) and "ascii" (5) are longer, the ASCII lane
    // shorter. Returns how many, and checks none of the line crosses `endX`.
    int columnsOn(int topY, int endX)
    {
        int drawn, columns;
        mu_Command* cmd;
        while (mu_get_next_command(&ctx, &cmd))
        {
            if (cmd.type != MU_COMMAND_TEXT)
                continue;
            ++drawn;
            int w = width(null, mu_command_text(&ctx, cmd), -1);
            assert(cmd.text.pos.x + w <= endX); // no glyph crosses the edge
            if (w == 2 * CW && cmd.text.pos.y == topY)
                ++columns;
        }
        assert(drawn > 0); // or the bound above passes by drawing nothing
        return columns;
    }

    // The header takes a full layout row, so its rect - not the window's - is what
    // the grid has to be measured against. It is the panel background, the first
    // rect the header emits.
    mu_Rect headerRect(int paneW)
    {
        mu_begin(&ctx);
        if (mu_begin_window_ex(&ctx, "w", mu_Rect(0, 0, paneW, 400),
                MU_OPT_NOTITLE | MU_OPT_NORESIZE | MU_OPT_NOSCROLL | MU_OPT_NOFRAME))
        {
            hex_header(&ctx, v, lay, 16, null, STRIP);
            mu_end_window(&ctx);
        }
        mu_end(&ctx);

        mu_Command* cmd;
        while (mu_get_next_command(&ctx, &cmd))
            if (cmd.type == MU_COMMAND_RECT)
                return cmd.rect.rect;
        assert(0, "header drew no background");
    }

    foreach (int paneW; [180, 260, 337, 400, 512, 640])
    {
        mu_Rect hr = headerRect(paneW);
        int endX = hr.x + hr.w - STRIP;

        mu_begin(&ctx);
        if (mu_begin_window_ex(&ctx, "w", mu_Rect(0, 0, paneW, 400),
                MU_OPT_NOTITLE | MU_OPT_NORESIZE | MU_OPT_NOSCROLL | MU_OPT_NOFRAME))
        {
            hex_header(&ctx, v, lay, 16, null, STRIP);
            mu_end_window(&ctx);
        }
        mu_end(&ctx);
        int headerCols = columnsOn(hr.y, endX);

        mu_begin(&ctx);
        if (mu_begin_window_ex(&ctx, "w2", mu_Rect(0, 0, paneW, 400),
                MU_OPT_NOTITLE | MU_OPT_NORESIZE | MU_OPT_NOSCROLL | MU_OPT_NOFRAME))
        {
            hex_paint(&ctx, v, lay, mu_Rect(hr.x, 20, hr.w - STRIP, 200), 0, 16, 16, null);
            mu_end_window(&ctx);
        }
        mu_end(&ctx);
        int gridCols = columnsOn(20, endX);

        // The header must label exactly the columns the grid has room to draw.
        assert(headerCols > 0);
        assert(headerCols == gridCols);
    }
}

// Map a mouse position (screen space) to a byte index, or -1 if it misses a
// cell. Both the hex pairs and the ASCII column are hittable.
//
// `snap` takes the gap after a hex pair as part of that pair. A click wants the
// strict reading, landing the caret only where a byte was actually pointed at, but
// anything tracking the pointer as it moves wants the forgiving one: a third of the
// hex lane is gaps, and a hover that drops out in each of them never settles.
long hex_hit(ref const(HexLayout) lay, mu_Rect body, long topRow, int rowH,
    int cols, size_t total, int mx, int my, bool snap = false)
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
        if (col == start || col == start + 1 || (snap && col == start + 2))
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
    // Focus handed over between frames (see takeFocus) is claimed before
    // mu_update_control, which is what keeps ddui from dropping it at frame end.
    if (v.takeFocus)
    {
        v.takeFocus = false;
        mu_set_focus(ctx, id);
    }
    // Hold focus so the caret keeps taking keys after the click is released,
    // and join the tab ring so the panel is reachable without a mouse.
    mu_update_control(ctx, id, body, MU_OPT_HOLDFOCUS | MU_OPT_TABSTOP);

    // The button coming up ends any selection drag this panel had begun. Ahead of
    // the bail-outs below, so an empty read-only panel cannot leave it set.
    if ((ctx.mouse_down & MU_MOUSE_LEFT) == 0)
        v.dragSel = false;

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

    // Press places the caret, drag extends it. mu_mouse_over honours the panel
    // clip, so presses on the scrollbar or header do not land here, and the drag
    // arm asks whether the press landed in this grid rather than whether the panel
    // has focus. See HexView.dragSel.
    v.hoverByte = mu_mouse_over(ctx, body) ?
        hex_hit(lay, body, v.topRow, rowH, cols, total, ctx.mouse_pos.x, ctx.mouse_pos.y, true) :
        -1;

    if (ctx.mouse_pressed == MU_MOUSE_LEFT && mu_mouse_over(ctx, body))
    {
        v.dragSel = true; // this panel owns the drag until the button comes up

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
    else if (v.dragSel && (ctx.mouse_down & MU_MOUSE_LEFT) && v.active)
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

    // Keyboard caret. Shift keeps the anchor to grow a selection, otherwise it
    // collapses onto the caret.
    if (ctx.focus == id && ctx.key_pressed && v.active)
    {
        long dst = cast(long) v.cursor;
        bool low = v.editLow;
        int keys = ctx.key_pressed;
        int page = mu_max(1, (visibleRows - 1) * cols);
        bool ctrl = (ctx.key_down & MU_KEY_CTRL) != 0;

        // Vertical and paging moves land on a fresh byte, so they restart nibble
        // entry on the high nibble.
        bool byteMove = (keys & (HEX_KEY_UP | HEX_KEY_DOWN | HEX_KEY_PGUP |
            HEX_KEY_PGDN | HEX_KEY_HOME | HEX_KEY_END)) != 0;
        if (keys & HEX_KEY_UP)    dst -= cols;
        if (keys & HEX_KEY_DOWN)  dst += cols;
        if (keys & HEX_KEY_PGUP)  dst -= page;
        if (keys & HEX_KEY_PGDN)  dst += page;
        if (keys & HEX_KEY_HOME)  dst = ctrl ? 0 : dst - dst % cols;                 // Ctrl: SOF, else row start
        if (keys & HEX_KEY_END)   dst = ctrl ? caretMax : dst + (cols - 1) - (dst % cols);  // Ctrl: EOF, else row end
        if (byteMove) low = false;

        // Left / Right walk one nibble at a time when editing, the way typing
        // advances. Extending a selection, or a read-only view with no nibble
        // caret, steps a whole byte instead.
        if (keys & (HEX_KEY_LEFT | HEX_KEY_RIGHT))
        {
            if (editable && shift == false)
            {
                // The append slot past EOF has only a high nibble, so the walk caps
                // at caretMax * 2; the low nibbles below stay reachable.
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

    if (editable && ctx.focus == id && v.active)
    {
        // Restart the current byte's entry, so the mode change applies from a
        // clean nibble.
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

        for (const(char)* p = ctx.input_text.ptr; *p; ++p)
        {
            int nib = hex_nibble(*p);
            if (nib < 0)
                continue; // ignore any non-hex text (ascii-pane editing is not here)
            hex_edit_nibble(v, nib, cols, visibleRows);
            res |= MU_RES_CHANGE;
        }
    }

    // Ctrl+Z steps back, Ctrl+Y (or Ctrl+Shift+Z) forward. The hook refreshes
    // dataSize as a side effect, so hex_total is current for the clamp below.
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
// dataSize is kept live so hex_total stays right within the frame.
void hex_edit_nibble(ref HexView v, int nib, int cols, int visibleRows)
{
    long pos = cast(long) v.cursor;

    if (v.editLow == false)
    {
        // Insert mode, an empty document, or the caret parked at EOF all splice a
        // fresh byte; otherwise overwrite in place, keeping the existing low nibble.
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

// Draw the minimap ribbon and let it drive the scroll position. It maps the whole
// document onto its height, each block coloured by the dominant class of the
// segment it covers; the mapping is by row, so it holds up on files of any size.
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
        mu_Rect cell = mu_Rect(strip.x, y, strip.w, MINIMAP_BLOCK);
        mu_draw_rect(ctx, cell, c);

        // Backgrounds over it, in the grid's own priority. Not baked into mapCells,
        // which is only rebuilt on a change of size or ribbon height.
        mu_Color wash = hex_map_wash(v, cast(long) i, cells, cast(long) total);
        if (wash.a)
            mu_draw_rect(ctx, cell, wash);
    }

    // The visible row span mapped onto the ribbon. On big files that is a fraction
    // of a pixel, hence the floor on its height.
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

// The wash for minimap cell `index` of `cells`, over a document of `total` bytes,
// or alpha 0 for none. Follows hex_draw_row's priority - selection over the hook's
// wash - so the ribbon and the grid mark the same regions the same way, and asks
// about the cell's whole span rather than the sample its class colour came from,
// so a mark of a few bytes in a huge file still shows.
//
// Both come back lifted, the way a run's outline does: a wash is dark because it
// has to hold glyphs, and three pixels of ribbon hold nothing.
mu_Color hex_map_wash(ref const(HexView) v, long index, int cells, long total)
{
    long start = index * total / cells;
    long end   = (index + 1) * total / cells;
    if (end <= start) // ditto hex_build_minimap: the cell stands on `start`
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
    v.cursor = 1; // a two-byte selection at the head
    long total = cast(long) v.data.length;

    // One run, not one washed cell per selected byte with backdrop between them.
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

// The plain scroll strip shown when the minimap is off: a track with a thumb sized
// to the visible fraction, driven in row units like the minimap.
void hex_plainbar(mu_Context* ctx, ref HexView v, mu_Rect strip,
    long topRow, long maxTop, long rows, int visibleRows)
{
    mu_draw_rect(ctx, strip, mu_Color(20, 20, 28, 255)); // track
    if (rows <= 0 || strip.h <= 0)
        return;

    // Floored so the thumb stays grabbable.
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

// Rebuild the minimap colour cache: sample each segment with a fixed byte budget
// and record its dominant colour. A 1 TB file and a 1 KB one both cost `cells`
// small reads, and only when the size or the ribbon height changed.
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
        // A document shorter than the ribbon has cells gives most of them an empty
        // span. Each still stands on the byte at `start`, so a small file draws as
        // bands; an uncoloured cell would show the backdrop and stripe the ribbon.
        long span = end > start ? end - start : 1;
        size_t take = span < MINIMAP_PROBE ? cast(size_t) span : MINIMAP_PROBE;
        ubyte[] chunk = hex_probe(v, start, v.mapProbe[0 .. take]);
        v.mapCells[c] = hex_dominant(v, chunk, start);
    }
}

unittest
{
    enum int CELLS = 176; // a 600px window's worth, where the striping showed

    HexView v;
    v.data = cast(const(ubyte)[]) "0123456789abcdef\x00\x01";
    hex_build_minimap(v, CELLS);

    // Every cell takes a colour even though there are ten times as many cells as
    // bytes: an uncoloured one lets the backdrop through and stripes the ribbon.
    assert(v.mapCells.length == CELLS);
    foreach (mu_Color c; v.mapCells)
        assert(c.a != 0);

    // And they still walk the document in order, ends included.
    assert(hex_coleq(v.mapCells[0], hex_dominant(v, v.data[0 .. 1], 0)));
    assert(hex_coleq(v.mapCells[CELLS - 1],
        hex_dominant(v, v.data[$ - 1 .. $], cast(long) v.data.length - 1)));
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

// Dominant colour of a sampled chunk, classified through the panel's own scheme so
// the ribbon and the byte grid agree on how a region looks. The class layer only:
// the backgrounds go over it in hex_map_wash, which is asked of the whole span
// because a vote taken over a sample can miss what it is marking.
mu_Color hex_dominant(ref const(HexView) v, const(ubyte)[] chunk, long baseOff)
{
    if (chunk.length == 0)
        return mu_Color(0, 0, 0, 0);

    HexColorFn colorFn = v.colorFn ? v.colorFn : &hex_classify;
    void* user = cast(void*) v.colorUser;

    // hex_classify yields a handful of colours, so a short list covers the tally;
    // any beyond the cap just miss the vote.
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

// Draw the visible rows. Only the slice inside the viewport is emitted, so the
// command count stays bounded regardless of buffer size.
void hex_paint(mu_Context* ctx, ref const(HexView) v, ref const(HexLayout) lay,
    mu_Rect body, long topRow, int rowH, int cols, mu_Font font)
{
    size_t total = hex_total(v);
    long rows  = (cast(long) total + cols - 1) / cols;
    int charW = lay.charW;

    // An empty document still draws its first offset and a caret, so it reads as an
    // insertion point ready to build a file from scratch.
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
        hex_draw_row(ctx, v, lay, colorFn, v.backFn, body.x, body.x + body.w, y,
            row, cols, rowH, charW, selLow, selHigh, font);
    }

    // The caret parked one slot past the last byte sits in no row's byte range, so
    // it is drawn here, in a cell that may open a fresh row.
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
    HexColorFn colorFn, HexBackFn backFn, int originX, int endX, int y, long row,
    int cols, int rowH, int charW, size_t selLow, size_t selHigh, mu_Font font)
{
    size_t total = hex_total(v);
    size_t rowStart = cast(size_t)(row * cols);
    int count = cast(int) mu_min(cast(size_t) cols, total - rowStart);

    mu_Color offColor = mu_Color(150, 150, 160, 255);

    char[24] off = void;
    int digits = lay.offsetDigits > off.length ? cast(int) off.length : lay.offsetDigits;
    hex_format(off.ptr, cast(ulong)(v.baseAddress + row * cols), digits);
    if (hex_fits(originX, digits, charW, endX))
        mu_draw_text(ctx, font, off.ptr, digits, mu_Vec2(originX, y), offColor);

    // Backgrounds under the glyphs, in rendering priority: the hook's wash, the
    // selection over it, the wash's own outline over that.
    //
    // The selection takes the fill, being where the user is looking *now*. But an
    // opaque fill would leave a mark under it with nothing on screen, and that
    // happens exactly when the mark was just set - so the outline goes over the
    // selection and the mark keeps its shape either way.
    if (backFn)
        hex_wash_fill(ctx, v, lay, backFn, originX, y, rowStart, count, charW, rowH);

    // A row's selected bytes are contiguous, so at most one band. A bare caret
    // draws no wash, only the outline below.
    if (v.active && selLow != selHigh && selHigh >= rowStart && selLow < rowStart + count)
    {
        int lo = selLow  > rowStart ? cast(int)(selLow - rowStart) : 0;
        int hi = selHigh < rowStart + count ? cast(int)(selHigh - rowStart) : count - 1;
        hex_draw_band(ctx, lay, originX, y, lo, hi, charW, rowH, HEX_SEL_WASH);
    }

    if (backFn)
        hex_wash_outline(ctx, v, lay, backFn, originX, y, rowStart, count, cols, charW, rowH);

    // Structure borders, under the glyphs and drawn from the outside in, so a record
    // groups its fields rather than every field carrying a box of its own. What tells
    // the fields apart is their colour; what the border says is where a record begins
    // and ends, which is the one thing colour cannot.
    if (v.spanFn)
        for (int level; level < v.spanDepth; ++level)
            hex_span_outline(ctx, v, lay, originX, y, rowStart, count, cols, charW, rowH, level);

    // Each hex pair and its ASCII glyph share the byte's colour.
    char[2] cell = void;
    char[1] ch = void;
    for (int i; i < count; ++i)
    {
        size_t idx = rowStart + i;
        ubyte b = hex_byte(v, idx);
        mu_Color color = colorFn(idx, b, cast(void*) v.colorUser);

        int hx = originX + hex_col_for(lay, i) * charW;
        if (hex_fits(hx, 2, charW, endX))
        {
            hex_format(cell.ptr, b, 2);
            mu_draw_text(ctx, font, cell.ptr, 2, mu_Vec2(hx, y), color);
        }

        ch[0] = (b >= 0x20 && b < 0x7f) ? cast(char) b : '.';
        int ax = originX + (lay.asciiStart + i) * charW;
        if (hex_fits(ax, 1, charW, endX))
            mu_draw_text(ctx, font, ch.ptr, 1, mu_Vec2(ax, y), color);
    }

    if (v.active && v.cursor >= rowStart && v.cursor < rowStart + count)
        hex_draw_caret(ctx, lay, originX, y, cast(int)(v.cursor - rowStart), charW, rowH, hex_caret_nib(v));
}

// Which nibble the caret boxes: -1 for the whole pair (a read-only view has no
// nibble entry), 0 for the high nibble, 1 for the low. Editing narrows it to the
// digit the next keypress lands in, as GHex and friends do.
int hex_caret_nib(ref const(HexView) v)
{
    if (hex_editable(v) == false)
        return -1;
    return v.editLow ? 1 : 0;
}

// Fill the row's washed cells, banded: neighbouring bytes of one colour merge into
// a single rect, the gaps between the hex pairs included, so a marked run reads as
// one block rather than as cells with seams between them.
void hex_wash_fill(mu_Context* ctx, ref const(HexView) v, ref const(HexLayout) lay,
    HexBackFn backFn, int originX, int y, size_t rowStart, int count, int charW,
    int rowH)
{
    int runStart;
    mu_Color runColor; // .init is transparent, so the first washed cell flushes it
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

// Outline the row's washed cells in a lifted version of each cell's own wash. This
// is what survives the selection being drawn over the fill; see the rendering
// priority in hex_draw_row.
//
// Per cell rather than per run, an edge being dropped wherever the neighbour
// across it carries the same wash, so a run comes out as one outlined region even
// when it wraps over several rows. The neighbours above and below are asked of
// backSpanFn, which answers by offset alone: hex_byte cannot be trusted past the
// window the panel read, which is what a row off screen is. Without a backSpanFn
// there is no way to ask, so there is no outline either.
void hex_wash_outline(mu_Context* ctx, ref const(HexView) v, ref const(HexLayout) lay,
    HexBackFn backFn, int originX, int y, size_t rowStart, int count, int cols,
    int charW, int rowH)
{
    if (v.backSpanFn is null || count <= 0)
        return;

    void* user = cast(void*) v.backUser;
    mu_Color left;  // the cell before this one, carried along rather than re-asked
    mu_Color here = backFn(rowStart, hex_byte(v, rowStart), user);

    for (int i; i < count; ++i)
    {
        // Transparent at the row's end, so a run that wraps is closed off here
        // and opened again at column 0 of the next row, which is where it is.
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

            // The hex lane's cell runs to where the next one starts when the two
            // are joined, so the outline covers the gap the fill covered.
            int hx0 = originX + hex_col_for(lay, i) * charW;
            int hx1 = originX + charW *
                (joinR ? hex_col_for(lay, i + 1) : hex_col_for(lay, i) + 2);
            hex_draw_edges(ctx, hx0, hx1, y, rowH, top, bottom, onL, joinR == false,
                1, 0, 0, edge);

            // The ASCII lane has no gaps, so its cells are one character wide.
            int ax0 = originX + (lay.asciiStart + i) * charW;
            hex_draw_edges(ctx, ax0, ax0 + charW, y, rowH, top, bottom, onL,
                joinR == false, 1, 0, 0, edge);
        }

        left = here;
        here = right;
    }
}

// Outline the structure spans crossing this row at nesting level `up`, `weight` pixels
// thick, in each span's own edge colour.
//
// Built the same way as hex_wash_outline - edges dropped wherever the neighbour across
// them is in the same thing, so a span wrapping over several rows comes out as one
// region - but joining on where a span starts rather than on what colour it is. See
// HexSpanFn for why the difference matters.
//
// One hook call per cell per side. That is a few thousand a frame at a screenful of
// bytes, each a lookup rather than a read; if it ever shows up, one row's answers are
// the next row's neighbours above and could be carried instead of asked twice.
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
        // Nothing past the row's last cell, so a span carrying on is closed off here
        // and opened again at column 0 of the next row, which is where it is.
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

            // The hex lane's cell runs to where the next one starts when the two are
            // joined, so the border covers the gap between the pairs.
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

// Whether two cells belong to one span, and so have no border drawn between them.
// Where a span begins, not what it looks like: see HexSpanFn.
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

    // Two fields of one shape back to back stay two fields, which colour alone would
    // have merged.
    assert(hex_span_joins(true, a, true, c) == false);

    // A cell no span covers ends whatever the cell beside it was in.
    assert(hex_span_joins(true, a, false, b) == false);
    assert(hex_span_joins(false, a, true, b) == false);
}

// The same colour carried brighter, for a wash's outline. Scaled rather than
// blended towards white, so the edge keeps the wash's hue and reads as its own
// rather than as a highlight of its own.
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
    // A channel already high clamps rather than wrapping around.
    assert(hex_coleq(hex_wash_lift(mu_Color(125, 85, 22, 255)), mu_Color(250, 170, 44, 255)));
    assert(hex_coleq(hex_wash_lift(mu_Color(200, 0, 0, 128)), mu_Color(255, 0, 0, 255)));
}

// Draw the edges of one cell that its neighbours do not span, `weight` pixels each,
// held `padX` / `padY` pixels off the cell's bounds. A negative pad pushes that side
// outwards instead, for a lane whose glyphs leave no room inside.
//
// The padding is only taken off the sides actually drawn, so a run stays one unbroken
// box: an edge dropped for a neighbour is an edge the box does not turn at, and pulling
// the span in there would leave a notch mid-run. A cell too small to pad draws flush
// rather than inside out.
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

// Fill grid columns `lo` through `hi` of the row at `y`, in both lanes, since a
// span means the same bytes in each. The hex band runs over the gaps between the
// pairs rather than leaving them unpainted, so it reads as one block.
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

// Draw the caret outline in both lanes around grid column `col` of the row at `y`.
// `nib` picks the hex-lane box: -1 spans the whole pair, 0 the high digit, 1 the
// low. The ASCII lane is always one glyph, a character having no sub-position.
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
