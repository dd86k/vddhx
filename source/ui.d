/// UI layout for vddhx.
module ui;

import core.atomic : atomicLoad, atomicStore;
import std.string : fromStringz;
import bindbc.sdl;
import ddlogger;
import ddui;
import ddhx.document : FileDocument, IDocument;
import ddhx.editor : IDocumentEditor, spawnEditor;
import about : about_open, about_frame;
import hexview;
import render : render_font_mono;
import std.array : Appender, appender;
import std.format : sformat;

/// Persisted hex panel state (selection lives here across frames). The caret is
/// active from the outset so it sits ready on the blank panel, letting a file be
/// built from scratch through ddhx's editor before anything is opened.
private __gshared HexView hex = { active: true };

/// The ddhx editor backing the panel once a file is open. It owns the document
/// and all the piece-table/undo machinery; the panel only ever reads through it.
private __gshared IDocumentEditor editor;
/// Set once a file is open, so the sample fallback stays out of the way.
private __gshared bool loaded;

/// The main window, for parenting the native Open dialog. main sets it up front.
private __gshared SDL_Window* uiWindow;

/// Minimap toolbar toggle (int for mu_checkbox); pushed onto hex.minimap.
private __gshared int minimapOn = 1;

/// Path the async Open dialog picked, waiting for the next frame to consume it.
/// Written by the dialog callback (possibly off-thread), read on the main thread,
/// so the ready flag is atomic and orders the buffer write against the read.
private __gshared char[4096] pendingPath;
private shared bool pendingReady;

/// Ditto, for the async Save As dialog. The callback does no GC work, so the
/// chosen path is stashed here and the actual write happens on the main thread.
private __gshared char[4096] pendingSavePath;
private shared bool pendingSaveReady;

/// Disk path backing the open document, empty for the in-memory scratch buffer.
/// Set on Open (and once a scratch buffer is first saved through Save As), it is
/// the target an in-place Save writes to.
private __gshared string loadedPath;

/// Hand the UI the window handle before the first frame. Also spins up an empty
/// editor and wires the panel to it, so the blank panel is editable from the
/// outset: a file can be built from scratch before anything is ever opened.
void ui_init(SDL_Window* window)
{
    uiWindow = window;

    editor = spawnEditor(); // no document: a zero-length, in-memory scratch buffer
    wireEditor(editor);
    hex.dataSize = 0;
}

/// SDL Open-dialog callback. May fire on another thread, so it does no GC work:
/// it just copies the first chosen path out and flags it for ui_frame to open.
/// `fileList` is null on error and an empty (null-terminated) list on cancel.
extern (C) private void ui_on_file_picked(void* user, const(char*)* fileList, int filter) nothrow
{
    if (fileList is null || *fileList is null)
        return;
    const(char)* path = *fileList; // first selection; the dialog is single-select
    size_t n;
    while (path[n] && n + 1 < pendingPath.length)
    {
        pendingPath[n] = path[n];
        ++n;
    }
    pendingPath[n] = 0;
    atomicStore(pendingReady, true);
}

/// ddui-side byte source: hand the panel's window request straight to the editor,
/// which fills only those bytes. `user` is the editor stashed in hex.readUser.
private ubyte[] hexRead(long pos, ubyte[] buf, void* user)
{
    IDocumentEditor ed = cast(IDocumentEditor) user;
    return ed.view(pos, buf);
}

/// ddui-side write hooks: forward the panel's single-byte edits to the editor.
/// The editor holds them in its piece table (nothing touches disk until a Save),
/// so these work even on a file opened read-only. A rejected edit (a fixed-size
/// document, say) throws; swallow it with a log rather than unwinding the frame.
private void hexReplace(long pos, ubyte value, void* user)
{
    IDocumentEditor ed = cast(IDocumentEditor) user;
    try
        ed.replace(pos, &value, 1);
    catch (Exception e)
        logWarn("replace failed: %s", e.msg);
}
/// Ditto.
private void hexInsert(long pos, ubyte value, void* user)
{
    IDocumentEditor ed = cast(IDocumentEditor) user;
    try
        ed.insert(pos, &value, 1);
    catch (Exception e)
        logWarn("insert failed: %s", e.msg);
}
/// Ditto.
private void hexRemove(long pos, long len, void* user)
{
    IDocumentEditor ed = cast(IDocumentEditor) user;
    try
        ed.remove(pos, len);
    catch (Exception e)
        logWarn("remove failed: %s", e.msg);
}

/// ddui-side history hooks: step the editor's undo/redo and hand back where the
/// change landed so the panel can chase it with the caret. The editor's size can
/// jump either way here, so refresh the panel's copy before returning.
private long hexUndo(void* user)
{
    IDocumentEditor ed = cast(IDocumentEditor) user;
    long at = -1;
    try
        at = ed.undo();
    catch (Exception e)
        logWarn("undo failed: %s", e.msg);
    hex.dataSize = ed.size();
    return at;
}
/// Ditto.
private long hexRedo(void* user)
{
    IDocumentEditor ed = cast(IDocumentEditor) user;
    long at = -1;
    try
        at = ed.redo();
    catch (Exception e)
        logWarn("redo failed: %s", e.msg);
    hex.dataSize = ed.size();
    return at;
}

/// Point the panel's read, write and history hooks at `ed`. Called with the
/// initial empty editor and again on every Open, so editing always targets the
/// live document.
private void wireEditor(IDocumentEditor ed)
{
    hex.readFn    = &hexRead;
    hex.readUser  = cast(void*) ed;
    hex.replaceFn = &hexReplace;
    hex.insertFn  = &hexInsert;
    hex.removeFn  = &hexRemove;
    hex.undoFn    = &hexUndo;
    hex.redoFn    = &hexRedo;
    hex.writeUser = cast(void*) ed;
    hex.data      = null;
}

/// Put up the native Open dialog. It runs async: ui_on_file_picked stashes the
/// chosen path and the next frame opens it. Null filters means "all files", and
/// the trailing false keeps it single-select.
void ui_open_dialog()
{
    SDL_ShowOpenFileDialog(&ui_on_file_picked, null, uiWindow, null, 0, null, false);
}

/// Open `path` through a fresh ddhx editor and point the panel at it. On failure
/// the panel is left untouched (the sample keeps showing) and the error logged.
void ui_open(string path)
{
    // Loading replaces the live document, so resolve any unsaved edits first.
    if (ui_confirm_discard("Open another file") != Confirm.proceed)
        return;

    try
    {
        IDocument doc = new FileDocument(path); // read-only by default
        IDocumentEditor ed = spawnEditor();     // null picks the default backend
        ed.open(doc);

        // Built the new editor without throwing; now release the old one (if any)
        // and its file handle before swapping it in.
        if (editor)
            editor.close();
        editor         = ed;
        loadedPath     = path; // in-place Save now has a target
        wireEditor(ed);
        hex.dataSize   = ed.size();
        hex.baseAddress = 0;
        hex.active     = true; // show the caret right away on the first byte
        hex.cursor     = 0;
        hex.anchor     = 0;
        hex_reset_scroll(hex); // and scroll to the top so that first byte is visible
        loaded         = true;
        logInfo("opened %s (%s bytes)", path, hex.dataSize);
    }
    catch (Exception e)
        logWarn("open failed: %s", e.msg);
}

/// Write the open document's current contents to `path` and mark it saved.
///
/// Uses the document's "replace" strategy: stream the edited view into a temp
/// file alongside the target, then atomically rename it over the target. The
/// read-only source handle stays valid across the rename (it keeps referencing
/// the original inode), so the editor and its undo history survive without a
/// reopen. Returns false, and leaves the file untouched, if the write fails.
private bool saveTo(string path)
{
    import std.stdio : File;
    import std.file : rename, exists, remove;

    if (editor is null)
        return false;

    long docsize = editor.size();
    string tmp = path ~ ".vddhx-tmp"; // same directory, so rename is atomic
    try
    {
        {
            File fout = File(tmp, "wb");
            scope(exit) fout.close();
            ubyte[64 * 1024] buffer = void;
            long pos;
            while (pos < docsize)
            {
                ubyte[] chunk = editor.view(pos, buffer);
                if (chunk.length == 0) // nothing more readable; avoid spinning
                    break;
                fout.rawWrite(chunk);
                pos += chunk.length;
            }
            fout.flush();
        }
        rename(tmp, path);
    }
    catch (Exception e)
    {
        try { if (exists(tmp)) remove(tmp); }
        catch (Exception) {} // best-effort cleanup; report the original cause
        logWarn("save failed: %s", e.msg);
        return false;
    }

    editor.markSaved();
    logInfo("saved %s (%s bytes)", path, docsize);
    return true;
}

/// Save As dialog callback. Like ui_on_file_picked it may run off-thread, so it
/// only copies the chosen path out and flags it for the next frame to write.
extern (C) private void ui_on_save_picked(void* user, const(char*)* fileList, int filter) nothrow
{
    if (fileList is null || *fileList is null)
        return;
    const(char)* path = *fileList;
    size_t n;
    while (path[n] && n + 1 < pendingSavePath.length)
    {
        pendingSavePath[n] = path[n];
        ++n;
    }
    pendingSavePath[n] = 0;
    atomicStore(pendingSaveReady, true);
}

/// Save the open document. With a known path it writes in place and reports
/// whether that succeeded. With none (a scratch buffer built from nothing) there
/// is nowhere to write yet, so it opens a native Save As dialog and returns
/// false: the write lands later, on the main thread, once a path is chosen.
bool ui_save()
{
    if (loadedPath.length)
        return saveTo(loadedPath);

    ui_save_as();
    return false;
}

/// Put up the native Save As dialog, whatever path the document already has.
/// Async like the Open dialog: ui_on_save_picked stashes the destination and the
/// next frame writes there, then adopts it as the document's home so a later
/// in-place Save follows it.
void ui_save_as()
{
    SDL_ShowSaveFileDialog(&ui_on_save_picked, null, uiWindow, null, 0, null);
}

/// Bytes one Copy will format. The text runs three characters per byte, so this
/// caps the clipboard string near 48 MB; a larger selection is refused outright
/// rather than quietly spending the memory (and the time) on it.
private enum COPY_MAX = 16 * 1024 * 1024;

/// Resolve the byte range Copy and Cut act on, clamped to the document. Returns
/// false when there is nothing to act on: no document, no caret placed yet, or
/// the caret parked on the append slot past the last byte. A bare caret gives a
/// single byte, matching what the status bar reports and what Delete removes.
private bool ui_selection(out size_t low, out size_t high)
{
    if (editor is null || hex.active == false)
        return false;

    size_t total = hex_total(hex);
    low  = hex_sel_low(hex);
    high = hex_sel_high(hex);
    if (total == 0 || low >= total)
        return false;
    if (high >= total)
        high = total - 1;
    return true;
}

/// Copy the selected bytes to the clipboard as hex text, lower case and wrapped
/// at the panel's column count:
/// ---
/// de ad be ef ...
/// ---
/// Text, so it drops into any editor or chat window as a readable dump, and
/// ui_paste reads the same shape back in. Returns whether the bytes reached the
/// clipboard, so ui_cut only removes what it managed to copy.
bool ui_copy()
{
    size_t low, high;
    if (ui_selection(low, high) == false)
        return false;

    size_t len = high - low + 1;
    if (len > COPY_MAX)
    {
        logWarn("copy refused: %s bytes selected, over the %s byte limit", len, COPY_MAX);
        return false;
    }

    static immutable string digits = "0123456789abcdef";
    int cols = hex.columns > 0 ? hex.columns : 16;
    Appender!(char[]) text = appender!(char[]);
    text.reserve(len * 3 + 1); // two digits and a separator each, plus the terminator

    // Pull the run out of the editor a chunk at a time; the selection can be
    // large and only the bytes being formatted need to be held.
    ubyte[64 * 1024] buffer = void;
    size_t done;
    while (done < len)
    {
        size_t want = len - done;
        if (want > buffer.length) want = buffer.length;
        ubyte[] chunk = editor.view(cast(long)(low + done), buffer[0 .. want]);
        if (chunk.length == 0)
            break; // nothing more readable; avoid spinning
        foreach (i, ubyte b; chunk)
        {
            size_t at = done + i;
            if (at)
                text.put(at % cols == 0 ? '\n' : ' '); // break rows like the panel does
            text.put(digits[b >> 4]);
            text.put(digits[b & 0x0f]);
        }
        done += chunk.length;
    }
    text.put('\0'); // SDL takes a C string

    if (SDL_SetClipboardText(text.data.ptr) == false)
    {
        logWarn("copy failed: %s", SDL_GetError().fromStringz);
        return false;
    }
    logInfo("copied %s byte(s) from %#x", done, low);
    return true;
}

/// Copy the selected bytes, then remove them from the document. The clipboard is
/// written first and the removal only follows a copy that took, so a refused or
/// failed copy leaves the bytes where they are. A bare caret cuts the byte under
/// it, the same one Delete would drop.
void ui_cut()
{
    size_t low, high;
    if (ui_selection(low, high) == false)
        return;
    if (ui_copy() == false)
        return;

    try
        editor.remove(cast(long) low, cast(long)(high - low + 1));
    catch (Exception e)
    {
        logWarn("cut failed: %s", e.msg);
        return;
    }

    hex.dataSize = editor.size();
    hex_set_caret(hex, low); // the caret closes onto the gap the cut left
}

/// Paste hex text from the clipboard at the caret.
///
/// Reads back what ui_copy writes, plus the usual variations: whitespace, commas,
/// semicolons and colons all separate bytes, and a 0x prefix on a token is
/// skipped, so "de ad", "DEAD" and "0xde, 0xad" all land the same two bytes. Each
/// token must hold whole bytes (an even run of digits); anything else refuses the
/// paste whole, leaving the document untouched, rather than guessing at a nibble.
///
/// Where the bytes land follows the panel's entry mode, the way typing digits
/// does: overwrite replaces the bytes at the caret (growing the document when the
/// paste runs past EOF), insert splices them in. A selection wider than a single
/// byte is what the paste replaces, in either mode.
void ui_paste()
{
    if (editor is null)
        return;

    char* clip = SDL_GetClipboardText(); // caller frees; an empty string on failure
    if (clip is null)
    {
        logWarn("paste failed: %s", SDL_GetError().fromStringz);
        return;
    }
    scope(exit) SDL_free(clip);

    ubyte[] bytes = parseHexText(clip);
    if (bytes.length == 0)
    {
        logWarn("paste refused: the clipboard does not hold hex byte pairs");
        return;
    }

    size_t total = hex_total(hex);
    size_t low   = hex.active ? hex_sel_low(hex) : 0;
    size_t high  = hex.active ? hex_sel_high(hex) : 0;
    if (low > total) low = total;   // a caret left stale by an outside change
    if (high > total) high = total;
    long pos = cast(long) low;

    bool ok;
    try
    {
        // A selection is what the paste replaces, so drop it first and splice the
        // bytes into the gap; the entry mode only decides how a bare caret takes
        // them. The remove and the insert are separate history entries, so undoing
        // a paste over a selection takes two steps.
        bool replacing = high > low;
        if (replacing)
        {
            long cut = cast(long)(high - low + 1);
            if (high >= total) cut = cast(long) total - pos; // clamp off the append slot
            if (cut > 0) editor.remove(pos, cut);
            else replacing = false;
        }
        // Past EOF there is nothing to overwrite, so append there whatever the mode.
        if (replacing || hex.insertMode || low >= total)
            editor.insert(pos, bytes.ptr, bytes.length);
        else
            editor.replace(pos, bytes.ptr, bytes.length);
        ok = true;
    }
    catch (Exception e)
        logWarn("paste failed: %s", e.msg);

    // The document may have moved even on a failed insert-after-remove, so refresh
    // the panel and put the caret past the pasted run either way.
    hex.dataSize = editor.size();
    hex_set_caret(hex, ok ? low + bytes.length : low);
    if (ok)
        logInfo("pasted %s byte(s) at %#x", bytes.length, low);
}

/// Parse clipboard text into the bytes it spells out. Returns null when the text
/// holds anything but separated runs of hex digit pairs, so an unrelated paste is
/// refused rather than half-applied. See ui_paste for the accepted shapes.
private ubyte[] parseHexText(const(char)* text)
{
    static bool separator(char c)
    {
        return c == ' ' || c == '\t' || c == '\r' || c == '\n' ||
               c == ',' || c == ';'  || c == ':';
    }

    Appender!(ubyte[]) bytes = appender!(ubyte[]);
    for (const(char)* p = text; *p; )
    {
        if (separator(*p))
        {
            ++p;
            continue;
        }

        // A token: an optional 0x prefix, then hex digits taken two at a time.
        if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X') && hex_nibble(p[2]) >= 0)
            p += 2;

        size_t pairs;
        while (hex_nibble(*p) >= 0)
        {
            int hi = hex_nibble(*p++);
            int lo = hex_nibble(*p);
            if (lo < 0)
                return null; // a lone digit: refuse rather than guess the other half
            ++p;
            bytes.put(cast(ubyte)((hi << 4) | lo));
            ++pairs;
        }
        if (pairs == 0)
            return null; // neither separator nor hex digit: not a hex dump
    }
    return bytes.data;
}

unittest
{
    assert(parseHexText("de ad be ef") == [ 0xde, 0xad, 0xbe, 0xef ]);
    assert(parseHexText("DEADBEEF")    == [ 0xde, 0xad, 0xbe, 0xef ]); // one run
    assert(parseHexText("0xde, 0xAD")  == [ 0xde, 0xad ]);             // C-ish source
    assert(parseHexText("de ad\nbe ef") == [ 0xde, 0xad, 0xbe, 0xef ]); // wrapped copy
    assert(parseHexText("de:ad;be")    == [ 0xde, 0xad, 0xbe ]);
    assert(parseHexText("  ").length == 0);   // separators alone spell no bytes
    assert(parseHexText("").length == 0);
    assert(parseHexText("de a") is null);     // half a byte
    assert(parseHexText("dead beefs") is null); // stray letter past 'f'
    assert(parseHexText("hello") is null);
    assert(parseHexText("0x") is null);       // a prefix with no digits behind it
}

/// Outcome of the unsaved-changes prompt.
private enum Confirm { proceed, cancel }

/// Button ids for the prompt, kept distinct from the unset -1 sentinel.
private enum { btnSave = 1, btnDontSave = 2, btnCancel = 3 }

/// Resolve unsaved edits before an action that would discard them (quitting or
/// loading another file). With no edits pending it proceeds silently; otherwise
/// it puts up a native Save / Don't Save / Cancel prompt titled `title`.
/// Returns Confirm.proceed when the caller may go ahead (saved or discarded) and
/// Confirm.cancel when the user backed out, a chosen save has yet to finish, or
/// the prompt itself failed (fail safe: never lose data on an error).
private Confirm ui_confirm_discard(const(char)* title)
{
    if ((editor && editor.edited()) == false)
        return Confirm.proceed;

    static immutable SDL_MessageBoxButtonData[3] buttons = [
        { SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT, btnSave,     "Save" },
        { cast(SDL_MessageBoxButtonFlags) 0,       btnDontSave, "Don't Save" },
        { SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT, btnCancel,   "Cancel" },
    ];
    SDL_MessageBoxData data = {
        flags:      SDL_MESSAGEBOX_WARNING,
        window:     uiWindow,
        title:      title,
        message:    "The document has unsaved changes.",
        numButtons: buttons.length,
        buttons:    buttons.ptr,
    };

    int clicked = -1;
    if (SDL_ShowMessageBox(&data, &clicked) == false)
    {
        logWarn("message box failed: %s", SDL_GetError().fromStringz);
        return Confirm.cancel;
    }

    switch (clicked)
    {
    case btnSave:     return ui_save() ? Confirm.proceed : Confirm.cancel;
    case btnDontSave: return Confirm.proceed;
    default:          return Confirm.cancel; // Cancel, or the window was closed
    }
}

/// Ask the user to resolve unsaved edits before quitting. True to go ahead.
/// main calls this on every quit route so the window keeps running on Cancel.
bool ui_may_quit()
{
    return ui_confirm_discard("Quit vddhx") == Confirm.proceed;
}

/// Build one frame of UI. Call between mu_begin and mu_end.
/// Params:
///     ctx = ddui context.
///     width = Current window width in pixels.
///     height = Current window height in pixels.
void ui_frame(mu_Context* ctx, int width, int height)
{
    // The menubar sits flush against the window's top and side edges, so drop
    // the window body's outer padding while the layout body is pushed. The inset
    // is fixed when mu_begin_window_ex pushes the body, so zero padding across
    // that call, then restore it for the normally-padded content below.
    int padding = ctx.style.padding;
    ctx.style.padding = 0;

    int opened = mu_begin_window_ex(ctx, "vddhx",
        mu_Rect(0, 0, width, height),
        MU_OPT_NOTITLE | MU_OPT_NORESIZE | MU_OPT_NOCLOSE);

    ctx.style.padding = padding;

    if (opened)
    {
        // Keep the window glued to the full client area on resize.
        mu_Container* win = mu_get_current_container(ctx);
        win.rect = mu_Rect(0, 0, width, height);

        // Pick up a file the async Open dialog chose since the last frame.
        if (atomicLoad(pendingReady))
        {
            atomicStore(pendingReady, false);
            ui_open(pendingPath.ptr.fromStringz.idup);
        }

        // Likewise a Save As destination: write there, and adopt it as the
        // document's home so later saves land in place without asking again.
        if (atomicLoad(pendingSaveReady))
        {
            atomicStore(pendingSaveReady, false);
            string dest = pendingSavePath.ptr.fromStringz.idup;
            if (saveTo(dest))
                loadedPath = dest;
        }

        ui_menubar(ctx);

        // Quick toolbar: the minimap toggle. Off falls back to a fat scrollbar.
        static immutable int[1] bar = [ 120 ];
        mu_layout_row(ctx, 1, bar.ptr, 0);
        mu_checkbox(ctx, "Minimap", &minimapOn);
        hex.minimap = minimapOn != 0;

        // The editor's size shifts as inserts and deletes land, so refresh the
        // panel's copy each frame before it draws; the panel keeps it live within
        // a frame, this keeps it authoritative across them.
        if (editor)
            hex.dataSize = editor.size();

        // The panel takes the rest of the window, save a strip at the bottom
        // reserved for the status bar. Feed it the monospace face.
        int statusH = ctx.text_height(ctx.style.font) + 6;
        // Check return with `& MU_RES_CHANGE`
        cast(void)hex_view(ctx, "hexpanel", hex, render_font_mono(), statusH);

        // Status bar: edit mode, a dirty marker, caret offset and selection length,
        // echoing what the panel reports back through its state. Pinned to the
        // window's bottom edge in the strip hex_view kept free above.
        static immutable int[1] srow = [ -1 ];
        mu_layout_row(ctx, 1, srow.ptr, statusH);
        mu_Rect sr = mu_layout_next(ctx);
        mu_draw_rect(ctx, sr, mu_Color(30, 30, 40, 255));
        char[80] statusbuf = void;
        size_t selLen = hex_total(hex) ? hex_sel_high(hex) - hex_sel_low(hex) + 1 : 0;
        string mode  = hex.insertMode ? "INS" : "OVR";
        string dirty = (editor && editor.edited()) ? " *" : "";
        char[] status = sformat(statusbuf, "%s%s  offset %08X  selected %u byte(s)",
            mode, dirty, hex.cursor, selLen);
        int th = ctx.text_height(ctx.style.font);
        mu_draw_text(ctx, ctx.style.font, cast(string) status,
            mu_Vec2(sr.x + 4, sr.y + (sr.h - th) / 2), mu_Color(170, 170, 185, 255));

        mu_end_window(ctx);
    }

    // Help > About, as its own root container so it floats over the main window.
    about_frame(ctx, width, height);
}

/// Draw the top menubar. Each menu opens a dropdown of actions that print to
/// stdout, mirroring the demo button. Built on ddui's native menubar, which
/// packs the titles left-to-right and manages the dropdowns and outside-click
/// dismissal itself.
private void ui_menubar(mu_Context* ctx)
{
    mu_begin_menubar(ctx);

    // ddui derives a dropdown item's height (size.y + padding*2) and text inset
    // (padding) from style.padding, recomputed per item. The bar title width and
    // the dropdown's own body margin, by contrast, are baked in during
    // mu_begin_menu. So bumping padding only around the mu_menu_item calls
    // loosens the rows alone, leaving the titles and the popup frame untouched.
    int basePadding = ctx.style.padding;
    int itemPadding = basePadding + 4;

    // A dropdown takes its width from style.menu_width alone, so a label and a
    // right-aligned shortcut overlap once they outgrow the stock 160px (as
    // "Save As..." and Ctrl+Shift+S do). Measure the widest pair drawn below and
    // give the dropdowns room for it, rather than pinning a pixel count that a
    // change of font - or a longer shortcut - would quietly break again.
    int itemWidth(const(char)* label, const(char)* shortcut)
    {
        // One padding inset on each side, plus two more as the gap between the
        // label and the shortcut, so they never touch.
        return ctx.text_width(ctx.style.font, label, -1) +
               ctx.text_width(ctx.style.font, shortcut, -1) + itemPadding * 4;
    }
    int baseMenuWidth = ctx.style.menu_width;
    ctx.style.menu_width = mu_max(baseMenuWidth, itemWidth("Save As...", "Ctrl+Shift+S"));
    scope(exit) ctx.style.menu_width = baseMenuWidth;

    if (mu_begin_menu(ctx, "File"))
    {
        ctx.style.padding = itemPadding;
        // The ellipsis marks the entries that put up a dialog before doing
        // anything, the way every desktop toolkit marks them.
        if (mu_menu_item_ex(ctx, "Open...",    "Ctrl+O",       0, 0)) ui_open_dialog();
        if (mu_menu_item_ex(ctx, "Save",       "Ctrl+S",       0, 0)) ui_save();
        if (mu_menu_item_ex(ctx, "Save As...", "Ctrl+Shift+S", 0, 0)) ui_save_as();
        // Route Quit through SDL's own event queue so main stays the single
        // owner of the loop flag; the existing SDL_EVENT_QUIT case ends the loop.
        if (mu_menu_item_ex(ctx, "Quit", "Ctrl+Q", 0, 0))
        {
            SDL_Event quit; // .init zeroes the union
            quit.type = SDL_EVENT_QUIT;
            SDL_PushEvent(&quit);
        }
        ctx.style.padding = basePadding;
        mu_end_menu(ctx);
    }

    if (mu_begin_menu(ctx, "Edit"))
    {
        ctx.style.padding = itemPadding;
        if (mu_menu_item_ex(ctx, "Cut",   "Ctrl+X", 0, 0)) ui_cut();
        if (mu_menu_item_ex(ctx, "Copy",  "Ctrl+C", 0, 0)) ui_copy();
        if (mu_menu_item_ex(ctx, "Paste", "Ctrl+V", 0, 0)) ui_paste();
        ctx.style.padding = basePadding;
        mu_end_menu(ctx);
    }

    if (mu_begin_menu(ctx, "Help"))
    {
        ctx.style.padding = itemPadding;
        if (mu_menu_item(ctx, "About")) about_open();
        ctx.style.padding = basePadding;
        mu_end_menu(ctx);
    }

    mu_end_menubar(ctx);
}
