/// UI layout for vddhx.
module ui;

import core.atomic : atomicLoad, atomicStore;
import std.string : fromStringz, toStringz;
import bindbc.sdl;
import ddlogger;
import ddui;
import ddhx.document : FileDocument, IDocument;
import ddhx.editor : IDocumentEditor, spawnEditor;
import about : about_open, about_frame;
import address : Address, address_parse;
import bookmarks;
import hexview;
import omnibar;
import search;
import tabbar;
import ddhx.inspector : InspectorType, inspector_rows, byteSize, formatInspector;
import std.system : Endian;
import render : render_font_mono;
import std.array : Appender, appender;
import std.format : format, sformat;
import std.path : baseName;

/// One open document: the ddhx editor that owns the bytes, where they live on
/// disk, and the panel state viewing them. One tab shows one of these.
private struct Document
{
    /// The editor backing the panel. It owns the document and all the
    /// piece-table/undo machinery; the panel only ever reads through it.
    IDocumentEditor editor;

    /// Disk path backing the document, empty for an in-memory scratch buffer.
    /// Set on Open (and once a scratch buffer is first saved through Save As),
    /// it is the target an in-place Save writes to.
    string path;

    /// What the tab shows: the file's base name, or "untitled" for a scratch.
    string title;

    /// Persisted hex panel state (the selection lives here across frames). The
    /// caret is active from the outset so it sits ready on a blank panel,
    /// letting a file be built from scratch before anything is opened.
    HexView hex = { active: true };

    /// Bookmarked runs of bytes, sorted. Per document, since an offset only
    /// means something against the bytes it points into. The panel tints them
    /// and the omnibar's '@' lists them.
    ///
    /// Edits made through the panel carry them along (see bookmark_shift), but
    /// undo and redo do not: the editor reports only where a change landed, not
    /// how many bytes it moved, so a mark can end up a few bytes off its bytes
    /// after a rolled-back insert. It is never wrong about which document it
    /// belongs to, only about where in it.
    Bookmark[] marks;
}

/// Every open document, one per tab, and the index of the one on screen.
///
/// Never empty: startup opens a scratch buffer and closing the last tab leaves
/// a fresh one behind, so the panel - and every action below - always has a
/// document to work on.
private __gshared Document[] docs;
/// Ditto.
private __gshared size_t current;

/// Tab strip state, and the item slice handed to it. The slice is reused across
/// frames so drawing the strip allocates nothing once the tabs settle.
private __gshared TabBar tabstrip;
/// Ditto.
private __gshared TabItem[] tabItems;

/// Scratch buffers are numbered in creation order: "untitled", "untitled 2"...
private __gshared uint untitled;

/// Omnibar state, and the candidate rows handed to it. Like the tab strip's, the
/// row storage is rebuilt each frame into an array that only ever grows.
private __gshared Omnibar omni;
/// Ditto.
private __gshared OmniItem[] omniItems;

/// The document the tab strip has in front. Every action below acts on it.
private ref Document doc()
{
    return docs[current];
}

/// The main window, for parenting the native Open dialog. main sets it up front.
private __gshared SDL_Window* uiWindow;

/// Colour behind the hex grid. Dark on purpose: the byte colours - the dimmed
/// padding zeros above all - are picked to read against something near black,
/// and lose most of their contrast on a mid grey.
private enum mu_Color CANVAS = mu_Color(0, 0, 0, 255);

/// Colour a bookmarked byte is drawn in, in the grid and in the minimap ribbon.
/// Amber: nothing hex_classify hands out is near it, so a mark reads as a mark
/// rather than as one more class of byte.
private enum mu_Color BOOKMARK_TINT = mu_Color(240, 180, 70, 255);

/// Apply the application's own style over ddui's defaults. Call once after
/// mu_init, before the first frame.
///
/// ddui leaves MU_COLOR_PANELBG fully transparent, so the hex panel would take
/// whatever it sits on - the window's grey. It used to come out black anyway,
/// because the renderer ignored the alpha channel; now that it honours it, the
/// canvas has to be asked for. The tab strip is told the same colour so the
/// active tab reads as joined to the grid below it.
void ui_style(mu_Context* ctx)
{
    ctx.style.colors[MU_COLOR_PANELBG] = CANVAS;
    tabstrip.content = CANVAS;
}

/// Last thing the application had to say, shown at the right of the status bar
/// until something replaces it. Where a find that came up empty, a bookmark set,
/// or a copied inspector reading reports itself: all of those are keystrokes
/// whose whole result would otherwise be invisible.
private __gshared char[96] statusText;
/// Ditto.
private __gshared size_t statusLen;

/// Ditto. Formatted into a fixed buffer, so keep the message short; anything
/// that does not fit is dropped rather than half-shown.
private void ui_status(Args...)(string fmt, Args args)
{
    try
        statusLen = sformat(statusText, fmt, args).length;
    catch (Exception e)
        statusLen = 0;
}

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

/// The editor the open Save As dialog was raised for. Tabs can be switched or
/// closed while a non-modal dialog is up, so the destination is matched back to
/// the document that asked for it rather than to whatever is in front when it
/// returns - saving one file's bytes under another's name would lose both.
private __gshared IDocumentEditor pendingSaveTarget;

/// Hand the UI the window handle before the first frame. Also opens the first
/// tab, an empty editable scratch buffer, so a file can be built from scratch
/// before anything is ever opened.
void ui_init(SDL_Window* window)
{
    uiWindow = window;
    ui_new_tab();
}

/// Open a fresh scratch document in a new tab and bring it to the front: a
/// zero-length in-memory buffer with no path, editable from the outset, which
/// gets a name the first time it is saved.
void ui_new_tab()
{
    ++untitled;

    Document d;
    d.editor = spawnEditor(); // no document: a zero-length, in-memory buffer
    d.title  = untitled == 1 ? "untitled" : format("untitled %u", untitled);

    docs ~= d;
    current = docs.length - 1;
    wireEditor(docs[current]);
    doc.hex.takeFocus = true; // ready to take bytes without a click first
}

/// Bring the tab at `index` to the front. Out-of-range indices are ignored, so
/// a stale index from a strip built before a close cannot strand the panel.
void ui_select_tab(size_t index)
{
    if (index >= docs.length)
        return;
    current = index;
    doc.hex.takeFocus = true; // typing follows the tab that came forward
}

/// Step `delta` tabs along from the current one, wrapping at either end.
void ui_cycle_tab(int delta)
{
    if (docs.length <= 1)
        return;

    long count = cast(long) docs.length;
    long at = (cast(long) current + delta) % count;
    if (at < 0)
        at += count;
    ui_select_tab(cast(size_t) at);
}

/// Close the tab at `index`, resolving unsaved edits first (the document is
/// brought to the front for the prompt, and a cancel leaves it open). Closing
/// the last one closes the editor too, the way a tabbed application does.
void ui_close_tab(size_t index)
{
    if (index >= docs.length)
        return;
    if (ui_confirm_discard(index, "Close document") != Confirm.proceed)
        return;

    if (docs[index].editor)
        docs[index].editor.close();
    docs = docs[0 .. index] ~ docs[index + 1 .. $];

    if (docs.length == 0)
    {
        // Out of documents: quit, through SDL's own event queue so it meets the
        // same route as the window close button. That lands next frame, and the
        // rest of this one still has a panel to draw, so put a scratch buffer up
        // meanwhile - it has no edits, so it cannot hold the quit up.
        ui_new_tab(); // it sets current itself
        SDL_Event quit; // .init zeroes the union
        quit.type = SDL_EVENT_QUIT;
        SDL_PushEvent(&quit);
        return;
    }

    // Closing a tab left of the front one shifts it down; closing the front one
    // keeps the index, which now names its right-hand neighbour (or the new last
    // tab, when the front one was the last).
    if (index < current)
        --current;
    if (current >= docs.length)
        current = docs.length - 1;
    doc.hex.takeFocus = true; // the tab that took its place is ready to type in
}

/// Close the tab on screen. The Ctrl+W and File > Close Tab route.
void ui_close_current_tab()
{
    ui_close_tab(current);
}

/// The title text last handed to SDL, NUL-terminated, and its length. Kept so
/// the per-frame refresh can tell when nothing has changed and skip the call.
private __gshared char[512] titleShown;
private __gshared size_t titleShownLen;

/// Keep the window title naming the document in front, with a marker while it
/// has unsaved edits. Called every frame: the text is composed into a stack
/// buffer and compared, so a steady document costs a memcmp rather than a
/// window-manager round trip.
private void ui_window_title()
{
    if (uiWindow is null)
        return;

    char[512] buf = void;
    char[] text = ui_title_text(buf, doc.title, doc.editor && doc.editor.edited());
    if (text.length == titleShownLen && text == titleShown[0 .. titleShownLen])
        return;

    titleShown[0 .. text.length] = text;
    titleShown[text.length] = 0; // SDL takes a C string
    titleShownLen = text.length;
    SDL_SetWindowTitle(uiWindow, titleShown.ptr);
}

/// Compose "name * - vddhx" into `buf` and return the slice written. A name too
/// long for the buffer is cut back, on a UTF-8 boundary so the title never
/// carries half a character. `buf` must have room for the fixed parts.
private char[] ui_title_text(char[] buf, string name, bool dirty)
{
    enum string DIRTY  = " *";
    enum string SUFFIX = " - vddhx";
    assert(buf.length > DIRTY.length + SUFFIX.length);

    size_t room = buf.length - DIRTY.length - SUFFIX.length;
    if (name.length > room)
    {
        size_t cut = room;
        while (cut > 0 && (name[cut] & 0xc0) == 0x80) // the cut landed mid-character
            --cut;
        name = name[0 .. cut];
    }

    size_t n = name.length;
    buf[0 .. n] = name;
    if (dirty)
    {
        buf[n .. n + DIRTY.length] = DIRTY;
        n += DIRTY.length;
    }
    buf[n .. n + SUFFIX.length] = SUFFIX;
    return buf[0 .. n + SUFFIX.length];
}

unittest
{
    char[32] buf = void;
    assert(ui_title_text(buf, "mid.bin", false) == "mid.bin - vddhx");
    assert(ui_title_text(buf, "mid.bin", true)  == "mid.bin * - vddhx");
    assert(ui_title_text(buf, "", false)        == " - vddhx");

    // 32 bytes of buffer, 10 of them spoken for by the fixed parts, so a name is
    // cut back to 22 bytes.
    assert(ui_title_text(buf, "123456789012345678901234", false) ==
        "1234567890123456789012 - vddhx");
    // 22 bytes exactly, the last two being "é": nothing to cut.
    assert(ui_title_text(buf, "12345678901234567890é", false) ==
        "12345678901234567890é - vddhx");
    // One byte over, with the cut falling inside that "é": it goes whole.
    assert(ui_title_text(buf, "123456789012345678901é", false) ==
        "123456789012345678901 - vddhx");
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

/// ddui-side colour scheme: bookmarked bytes stand out, everything else is
/// classified the way the panel would have classified it anyway. Only the front
/// document is ever drawn, so the marks to check are its own - the same
/// assumption the history hooks below make.
private mu_Color hexColor(size_t offset, ubyte value, void* user)
{
    if (bookmark_has(doc.marks, cast(long) offset))
        return BOOKMARK_TINT;
    return hex_classify(offset, value, null);
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
    {
        ed.insert(pos, &value, 1);
        bookmark_shift(doc.marks, pos, 1); // the bytes past it all moved up one
    }
    catch (Exception e)
        logWarn("insert failed: %s", e.msg);
}
/// Ditto.
private void hexRemove(long pos, long len, void* user)
{
    IDocumentEditor ed = cast(IDocumentEditor) user;
    try
    {
        ed.remove(pos, len);
        bookmark_shift(doc.marks, pos, -len);
    }
    catch (Exception e)
        logWarn("remove failed: %s", e.msg);
}

/// ddui-side history hooks: step the editor's undo/redo and hand back where the
/// change landed so the panel can chase it with the caret. The editor's size can
/// jump either way here, so refresh the panel's copy before returning. Only the
/// panel on screen takes input, so the size to refresh is the front document's.
private long hexUndo(void* user)
{
    IDocumentEditor ed = cast(IDocumentEditor) user;
    long at = -1;
    try
        at = ed.undo();
    catch (Exception e)
        logWarn("undo failed: %s", e.msg);
    doc.hex.dataSize = ed.size();
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
    doc.hex.dataSize = ed.size();
    return at;
}

/// Point a document's panel at its own editor: read, write and history hooks,
/// plus the size the panel starts from. Called on every new tab and every Open,
/// so editing always targets the document the tab holds.
private void wireEditor(ref Document d)
{
    d.hex.readFn    = &hexRead;
    d.hex.readUser  = cast(void*) d.editor;
    d.hex.replaceFn = &hexReplace;
    d.hex.insertFn  = &hexInsert;
    d.hex.removeFn  = &hexRemove;
    d.hex.undoFn    = &hexUndo;
    d.hex.redoFn    = &hexRedo;
    d.hex.colorFn   = &hexColor;
    d.hex.writeUser = cast(void*) d.editor;
    d.hex.data      = null;
    d.hex.dataSize  = d.editor ? d.editor.size() : 0;
}

/// Put up the native Open dialog. It runs async: ui_on_file_picked stashes the
/// chosen path and the next frame opens it. Null filters means "all files", and
/// the trailing false keeps it single-select.
void ui_open_dialog()
{
    SDL_ShowOpenFileDialog(&ui_on_file_picked, null, uiWindow, null, 0, null, false);
}

/// Open `path` through a fresh ddhx editor and give it a tab.
///
/// The file lands in a new tab, unless the one in front is an untouched scratch
/// buffer - the state the app starts in - which it takes over rather than
/// leaving an empty tab behind. On failure nothing changes and the error is
/// logged, so a bad path never disturbs what is already open.
void ui_open(string path)
{
    IDocumentEditor ed;
    try
    {
        IDocument document = new FileDocument(path); // read-only by default
        ed = spawnEditor();                          // the default backend
        ed.open(document);
    }
    catch (Exception e)
    {
        logWarn("open failed: %s", e.msg);
        return;
    }

    // Built the editor without throwing, so the tab it goes in is settled now.
    if (scratchEmpty(doc))
    {
        if (doc.editor)
            doc.editor.close(); // release the placeholder and its handle
    }
    else
    {
        docs ~= Document.init;
        current = docs.length - 1;
    }

    Document* d = &docs[current];
    d.editor = ed;
    d.path   = path; // in-place Save now has a target
    d.title  = baseName(path);
    wireEditor(*d);
    d.hex.baseAddress = 0;
    d.hex.active = true;    // show the caret right away on the first byte
    d.hex.takeFocus = true; // and let it take keys without a click first
    d.hex.cursor = 0;
    d.hex.anchor = 0;
    hex_reset_scroll(d.hex); // and scroll to the top so that first byte is visible
    logInfo("opened %s (%s bytes)", path, d.hex.dataSize);
}

/// Whether `d` is a scratch buffer nothing has been done to: no path, no edits
/// and no bytes. That is what a fresh tab (and the app itself) starts as, and
/// what an Open takes over instead of stacking a tab on top of it.
private bool scratchEmpty(ref Document d)
{
    return d.path.length == 0 && d.editor &&
        d.editor.edited() == false && d.editor.size() == 0;
}

/// Write the open document's current contents to `path` and mark it saved.
///
/// Uses the document's "replace" strategy: stream the edited view into a temp
/// file alongside the target, then atomically rename it over the target. The
/// read-only source handle stays valid across the rename (it keeps referencing
/// the original inode), so the editor and its undo history survive without a
/// reopen. Returns false, and leaves the file untouched, if the write fails.
private bool saveTo(ref Document d, string path)
{
    import std.stdio : File;
    import std.file : rename, exists, remove;

    if (d.editor is null)
        return false;

    IDocumentEditor editor = d.editor;
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
    if (doc.path.length)
        return saveTo(doc, doc.path);

    ui_save_as();
    return false;
}

/// Put up the native Save As dialog, whatever path the document already has.
/// Async like the Open dialog: ui_on_save_picked stashes the destination and the
/// next frame writes there, then adopts it as the document's home so a later
/// in-place Save follows it.
void ui_save_as()
{
    pendingSaveTarget = doc.editor;
    SDL_ShowSaveFileDialog(&ui_on_save_picked, null, uiWindow, null, 0, null);
}

/// Write the document the Save As dialog was raised for to `dest` and adopt it
/// as that document's home, so a later in-place Save follows it. The document is
/// found again by the editor the dialog was opened for, not by tab index: both
/// can have moved while the dialog was up. A closed one drops the write.
private void ui_save_pending(string dest)
{
    foreach (ref Document d; docs)
    {
        if (d.editor !is pendingSaveTarget)
            continue;
        if (saveTo(d, dest))
        {
            d.path  = dest;
            d.title = baseName(dest);
        }
        return;
    }
    logWarn("save as: the document was closed before a destination was chosen");
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
    if (doc.editor is null || doc.hex.active == false)
        return false;

    size_t total = hex_total(doc.hex);
    low  = hex_sel_low(doc.hex);
    high = hex_sel_high(doc.hex);
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
    int cols = doc.hex.columns > 0 ? doc.hex.columns : 16;
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
        ubyte[] chunk = doc.editor.view(cast(long)(low + done), buffer[0 .. want]);
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
        doc.editor.remove(cast(long) low, cast(long)(high - low + 1));
    catch (Exception e)
    {
        logWarn("cut failed: %s", e.msg);
        return;
    }
    bookmark_shift(doc.marks, cast(long) low, -cast(long)(high - low + 1));

    doc.hex.dataSize = doc.editor.size();
    hex_set_caret(doc.hex, low); // the caret closes onto the gap the cut left
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
    if (doc.editor is null)
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

    IDocumentEditor editor = doc.editor;
    size_t total = hex_total(doc.hex);
    size_t low   = doc.hex.active ? hex_sel_low(doc.hex) : 0;
    size_t high  = doc.hex.active ? hex_sel_high(doc.hex) : 0;
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
            if (cut > 0)
            {
                editor.remove(pos, cut);
                bookmark_shift(doc.marks, pos, -cut);
            }
            else replacing = false;
        }
        // Past EOF there is nothing to overwrite, so append there whatever the mode.
        if (replacing || doc.hex.insertMode || low >= total)
        {
            editor.insert(pos, bytes.ptr, bytes.length);
            bookmark_shift(doc.marks, pos, cast(long) bytes.length);
        }
        else
            editor.replace(pos, bytes.ptr, bytes.length);
        ok = true;
    }
    catch (Exception e)
        logWarn("paste failed: %s", e.msg);

    // The document may have moved even on a failed insert-after-remove, so refresh
    // the panel and put the caret past the pasted run either way.
    doc.hex.dataSize = editor.size();
    hex_set_caret(doc.hex, ok ? low + bytes.length : low);
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

/// Resolve unsaved edits in the document at `index` before an action that would
/// discard them (closing its tab, or quitting). With no edits pending it
/// proceeds silently; otherwise it brings that document to the front - so the
/// prompt is about what is on screen, and a Save As raised from here lands on
/// it - and puts up a native Save / Don't Save / Cancel prompt titled `title`.
/// Returns Confirm.proceed when the caller may go ahead (saved or discarded) and
/// Confirm.cancel when the user backed out, a chosen save has yet to finish, or
/// the prompt itself failed (fail safe: never lose data on an error).
private Confirm ui_confirm_discard(size_t index, const(char)* title)
{
    if (index >= docs.length)
        return Confirm.proceed;
    if ((docs[index].editor && docs[index].editor.edited()) == false)
        return Confirm.proceed;

    current = index;

    static immutable SDL_MessageBoxButtonData[3] buttons = [
        { SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT, btnSave,     "Save" },
        { cast(SDL_MessageBoxButtonFlags) 0,       btnDontSave, "Don't Save" },
        { SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT, btnCancel,   "Cancel" },
    ];
    // Name the document: with several tabs open, "the document" is not enough
    // to tell the user which one they are about to lose.
    string message = format("%s has unsaved changes.", docs[index].title);
    SDL_MessageBoxData data = {
        flags:      SDL_MESSAGEBOX_WARNING,
        window:     uiWindow,
        title:      title,
        message:    message.toStringz,
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
/// Every open tab is asked about in turn, each prompt naming its own document,
/// and the first cancel stops the quit with the rest left untouched.
bool ui_may_quit()
{
    foreach (size_t i, ref Document d; docs)
        if (ui_confirm_discard(i, "Quit vddhx") != Confirm.proceed)
            return false;
    return true;
}

/// One row of the omnibar's command list or shortcut sheet: what it is called,
/// the keys that reach it, and - for a command - the code ui_omni_run acts on.
private struct Entry
{
    string label;
    string keys;
    int id = -1;
}

/// Commands the omnibar's '>' mode offers. The menus' own actions, so anything
/// reachable by mouse is reachable by typing its name; ddhx's document-level
/// commands (go to offset, search, ...) join this table as ddhx exposes them.
private enum
{
    CMD_NEW_TAB, CMD_OPEN, CMD_SAVE, CMD_SAVE_AS, CMD_CLOSE_TAB,
    CMD_CUT, CMD_COPY, CMD_PASTE, CMD_GOTO,
    CMD_FIND, CMD_FIND_NEXT, CMD_FIND_PREV, CMD_INSPECT,
    CMD_MARK, CMD_MARK_NEXT, CMD_MARK_PREV, CMD_MARK_LIST, CMD_MARK_CLEAR,
    CMD_MINIMAP, CMD_ABOUT, CMD_QUIT,
}

/// Ditto.
private immutable Entry[] COMMANDS = [
    Entry("New Tab",          "Ctrl+T",       CMD_NEW_TAB),
    Entry("Open File...",     "Ctrl+O",       CMD_OPEN),
    Entry("Save",             "Ctrl+S",       CMD_SAVE),
    Entry("Save As...",       "Ctrl+Shift+S", CMD_SAVE_AS),
    Entry("Close Tab",        "Ctrl+W",       CMD_CLOSE_TAB),
    Entry("Cut",              "Ctrl+X",       CMD_CUT),
    Entry("Copy",             "Ctrl+C",       CMD_COPY),
    Entry("Paste",            "Ctrl+V",       CMD_PASTE),
    Entry("Go to Offset...",  "Ctrl+G",       CMD_GOTO),
    Entry("Find...",          "Ctrl+F",       CMD_FIND),
    Entry("Find Next",        "Ctrl+N",       CMD_FIND_NEXT),
    Entry("Find Previous",    "Ctrl+Shift+N", CMD_FIND_PREV),
    Entry("Inspect Bytes...", "Alt+I",        CMD_INSPECT),
    Entry("Toggle Bookmark",  "Ctrl+B",       CMD_MARK),
    Entry("Next Bookmark",    "]",            CMD_MARK_NEXT),
    Entry("Previous Bookmark","[",            CMD_MARK_PREV),
    Entry("Bookmarks...",     "",             CMD_MARK_LIST),
    Entry("Clear Bookmarks",  "",             CMD_MARK_CLEAR),
    Entry("Toggle Minimap",   "",             CMD_MINIMAP),
    Entry("About vddhx",      "",             CMD_ABOUT),
    Entry("Quit",             "Ctrl+Q",       CMD_QUIT),
];

/// The '?' sheet: every key the application answers to, in the order they come
/// up - the omnibar itself, then the window, then the caret and the bytes under
/// it. Nothing here runs; it is the sheet you open to remember a chord.
private immutable Entry[] SHORTCUTS = [
    Entry("Omnibar",                      "Ctrl+E"),
    Entry("Omnibar, on commands",         "Ctrl+Shift+P"),
    Entry("Omnibar, on an offset",        "Ctrl+G"),
    Entry("Close the omnibar",            "Esc"),
    Entry("New tab",                      "Ctrl+T"),
    Entry("Open file",                    "Ctrl+O"),
    Entry("Save",                         "Ctrl+S"),
    Entry("Save as",                      "Ctrl+Shift+S"),
    Entry("Close tab",                    "Ctrl+W"),
    Entry("Next / previous tab",          "Ctrl+Tab / Ctrl+Shift+Tab"),
    Entry("Quit",                         "Ctrl+Q"),
    Entry("Find",                         "Ctrl+F"),
    Entry("Find next / previous",         "Ctrl+N / Ctrl+Shift+N"),
    Entry("Inspect bytes at the caret",   "Alt+I"),
    Entry("Toggle bookmark",              "Ctrl+B"),
    Entry("Next / previous bookmark",     "] / ["),
    Entry("Cut / copy / paste bytes",     "Ctrl+X / C / V"),
    Entry("Undo / redo",                  "Ctrl+Z / Ctrl+Y"),
    Entry("Move the caret",               "Arrows"),
    Entry("Extend the selection",         "Shift+Arrows"),
    Entry("Row start / row end",          "Home / End"),
    Entry("File start / file end",        "Ctrl+Home / Ctrl+End"),
    Entry("Page up / page down",          "PgUp / PgDn"),
    Entry("Overwrite or insert",          "Insert"),
    Entry("Delete a byte, back / forward", "Backspace / Delete"),
    Entry("Type a byte",                  "0-9 a-f"),
];

/// Whether the omnibar has the keyboard. main asks before routing a key, since
/// the box takes text where the panel would take hex digits and chords.
bool ui_omni_active()
{
    return omni_shown(omni);
}

/// Raise the omnibar on the mode `prefix` opens, or put it away when it is
/// already on that mode (see omni_toggle). The Ctrl+E and Ctrl+Shift+P route.
void ui_omni_toggle(char prefix = 0)
{
    omni_toggle(omni, prefix);
    if (omni_shown(omni) == false)
        doc.hex.takeFocus = true; // typing goes back to the bytes
}

/// Put the omnibar away, whatever it was showing. The Esc route.
void ui_omni_close()
{
    if (omni_shown(omni) == false)
        return;
    omni_hide(omni);
    doc.hex.takeFocus = true;
}

/// Fill the omnibar's row list for the mode it is currently in. Rebuilt every
/// frame: titles, dirty flags and the tab count all move under us.
private const(OmniItem)[] ui_omni_items()
{
    rowUsed = 0; // this frame's rows start over the last frame's
    size_t n;
    void put(string label, string detail, int id, bool marked = false, bool pinned = false)
    {
        if (n >= omniItems.length)
            omniItems.length = n + 16;
        omniItems[n++] = OmniItem(label, detail, id, marked, pinned);
    }

    final switch (omni_mode(omni))
    {
    case OmniMode.switcher:
        // The path is what tells two same-named files apart, so it is both the
        // detail column and, through the omnibar's matching, searchable itself.
        foreach (size_t i, ref Document d; docs)
            put(d.title, d.path.length ? d.path : "not saved yet", cast(int) i,
                d.editor && d.editor.edited());
        break;
    case OmniMode.command:
        foreach (ref immutable Entry e; COMMANDS)
            put(e.label, e.keys, e.id);
        break;
    case OmniMode.address:
        // One row, pinned: it is a readout of the offset being typed rather than
        // something to pick out of a list, so the query must not filter it away.
        string label, detail;
        ui_goto_preview(label, detail);
        put(label, detail, 0, false, true);
        break;
    case OmniMode.find:
        // Likewise a readout, of the bytes the pattern comes to. What it would
        // find is deliberately not looked up here: this runs every frame, and
        // scanning the document per keystroke is not something to do quietly.
        string flabel, fdetail;
        ui_find_preview(flabel, fdetail);
        put(flabel, fdetail, 0, false, true);
        break;
    case OmniMode.inspect:
        ubyte[8] raw = void;
        ubyte[] bytes = ui_inspect_bytes(raw);
        char[64] value = void;
        foreach (size_t i, ref immutable Inspect row; INSPECT)
            put(row.label, ui_row_text(ui_inspect_value(cast(int) i, bytes, value)),
                cast(int) i);
        break;
    case OmniMode.bookmark:
        if (doc.marks.length == 0)
        {
            put("no bookmarks in this document", "Ctrl+B marks the selection",
                -1, false, true);
            break;
        }
        // The row's id is the mark's place in the list, not the offset itself:
        // an offset does not fit an int on a document worth bookmarking.
        foreach (size_t i, ref Bookmark mark; doc.marks)
        {
            char[48] head = void;
            size_t used = sformat(head, "0x%08x", mark.at).length;
            if (mark.length > 1)
                used += sformat(head[used .. $], " .. 0x%08x",
                    mark.at + mark.length - 1).length;
            put(ui_row_text(head[0 .. used]), ui_bookmark_bytes(mark), cast(int) i);
        }
        break;
    case OmniMode.help:
        foreach (ref immutable Entry e; SHORTCUTS)
            put(e.label, e.keys, e.id);
        break;
    }
    return omniItems[0 .. n];
}

/// Where the omnibar's ':' mode is currently pointing: the offset its text spells
/// out, resolved against the document in front. See the address module for what
/// counts as an offset.
private Address ui_goto_target()
{
    return address_parse(omni_query(omni), cast(long) doc.hex.cursor,
        cast(long) hex_total(doc.hex));
}

/// Storage the omnibar's row text is composed into, and how much of it this
/// frame has taken. Rows that are computed rather than named - an offset
/// readout, a bookmark's bytes, an inspector reading - would otherwise allocate
/// a string per row per frame, which is a few thousand pieces of garbage a
/// second for text nothing outlives the frame. It only ever grows.
private __gshared char[] rowArena;
/// Ditto.
private __gshared size_t rowUsed;

/// Park `text` in the arena and hand back a slice of it, good until the next
/// frame's rows are built. Compose into a stack buffer, then park it here.
private string ui_row_text(const(char)[] text)
{
    if (rowUsed + text.length > rowArena.length)
        rowArena.length = (rowUsed + text.length) * 2 + 256;
    size_t at = rowUsed;
    rowArena[at .. at + text.length] = text;
    rowUsed += text.length;
    return cast(string) rowArena[at .. rowUsed];
}

/// Text for the ':' mode's one row: where the caret would land, or - while the
/// text is not an offset yet, which is most of the time it is being typed - the
/// syntax it is waiting for.
private void ui_goto_preview(out string label, out string detail)
{
    Address a = ui_goto_target();
    if (a.ok == false)
    {
        label  = "offset: 1234, 0x1f40, 0b1011, +16, -16, %50";
        detail = "waiting for an offset";
        return;
    }

    char[96] buf = void;
    size_t total = hex_total(doc.hex);
    label = ui_row_text(sformat(buf, "Go to 0x%08x", a.pos));

    // What that offset means in the document: the decimal count and how far in
    // it lands, since the whole point of "%50" is not knowing the number.
    int percent = total ? cast(int)((a.pos * 100) / cast(long) total) : 0;
    if (a.clamped)
        detail = ui_row_text(sformat(buf,
            "%u, clamped to the document (%u bytes)", a.pos, total));
    else
        detail = ui_row_text(sformat(buf,
            "%u of %u bytes, %d%%", a.pos, total, percent));
}

/// The pattern the find box is currently spelling out, read out of its text.
private bool ui_find_needle(out Needle needle)
{
    return search_parse(omni_query(omni), needle);
}

/// Text for the '/' mode's one row: the bytes the pattern comes to, so what is
/// about to be searched for is never a guess.
private void ui_find_preview(out string label, out string detail)
{
    Needle needle;
    if (ui_find_needle(needle) == false)
    {
        label  = `pattern: text, "quoted text", 0xdeadbeef, x:de ad, d:255, o:377, ?`;
        detail = "waiting for a pattern";
        return;
    }

    // The elements as bytes, with '??' where a wildcard stands. Long patterns
    // are cut off here rather than in the row: the box would elide the tail
    // anyway, and this keeps the arena's slice short.
    char[128] buf = void;
    size_t at;
    foreach (ushort element; needle.data[0 .. needle.length])
    {
        if (at + 3 > buf.length - 4)
        {
            at += sformat(buf[at .. $], " ...").length;
            break;
        }
        if (at)
            buf[at++] = ' ';
        if (element == SEARCH_ANY)
        {
            buf[at .. at + 2] = "??";
            at += 2;
        }
        else
            at += sformat(buf[at .. $], "%02x", cast(ubyte) element).length;
    }

    char[64] count = void;
    label  = ui_row_text(buf[0 .. at]);
    detail = ui_row_text(sformat(count, "%u byte(s), from the caret",
        needle.length));
}

/// One row of the '=' inspector: a type, and the byte order it is read in.
private struct Inspect
{
    string label;
    InspectorType type;
    Endian endian;
}

/// The readings the '=' mode offers, little-endian first so the common ones are
/// on screen without scrolling, then the same types the other way round. Single
/// bytes have no byte order to argue about, so they appear once.
private immutable Inspect[] INSPECT = [
    Inspect("u8",     InspectorType.u8,  Endian.littleEndian),
    Inspect("i8",     InspectorType.i8,  Endian.littleEndian),
    Inspect("u16 LE", InspectorType.u16, Endian.littleEndian),
    Inspect("i16 LE", InspectorType.i16, Endian.littleEndian),
    Inspect("u32 LE", InspectorType.u32, Endian.littleEndian),
    Inspect("i32 LE", InspectorType.i32, Endian.littleEndian),
    Inspect("u64 LE", InspectorType.u64, Endian.littleEndian),
    Inspect("i64 LE", InspectorType.i64, Endian.littleEndian),
    Inspect("f32 LE", InspectorType.f32, Endian.littleEndian),
    Inspect("f64 LE", InspectorType.f64, Endian.littleEndian),
    Inspect("u16 BE", InspectorType.u16, Endian.bigEndian),
    Inspect("i16 BE", InspectorType.i16, Endian.bigEndian),
    Inspect("u32 BE", InspectorType.u32, Endian.bigEndian),
    Inspect("i32 BE", InspectorType.i32, Endian.bigEndian),
    Inspect("u64 BE", InspectorType.u64, Endian.bigEndian),
    Inspect("i64 BE", InspectorType.i64, Endian.bigEndian),
    Inspect("f32 BE", InspectorType.f32, Endian.bigEndian),
    Inspect("f64 BE", InspectorType.f64, Endian.bigEndian),
];

/// Read the bytes the inspector works from: as many as its widest type needs,
/// from where the selection starts - which is the caret itself when there is no
/// selection, and the first of the bytes when there is, since that is the one a
/// reading of them would begin at. A short read near EOF is fine:
/// formatInspector says "N/A" for the types that no longer fit.
private ubyte[] ui_inspect_bytes(ubyte[] buf)
{
    if (doc.editor is null)
        return null;
    long total = cast(long) hex_total(doc.hex);
    long at = cast(long) hex_sel_low(doc.hex);
    if (at >= total)
        return null;
    return doc.editor.view(at, buf);
}

/// Format one inspector row's value into `buf`.
private const(char)[] ui_inspect_value(int index, ubyte[] bytes, char[] buf)
{
    if (index < 0 || index >= INSPECT.length)
        return null;
    return formatInspector(buf, INSPECT[index].type, bytes, INSPECT[index].endian);
}

/// Act on the row the omnibar took, in the mode it was showing when the list was
/// built (which is not necessarily the mode its text spells out now: a prefix
/// typed this frame only reaches the list on the next one).
private void ui_omni_accept(OmniMode mode, int id)
{
    final switch (mode)
    {
    case OmniMode.switcher:
        if (id >= 0)
            ui_select_tab(cast(size_t) id); // hands the panel focus itself
        break;
    case OmniMode.command:
        ui_omni_run(id);
        break;
    case OmniMode.address:
        // Parsed again here rather than carried in the row's id: the id is an int
        // and an offset is not, and the text is still where the box left it. A
        // half-typed offset takes nothing and just puts the box away.
        Address a = ui_goto_target();
        if (a.ok)
        {
            hex_set_caret(doc.hex, cast(size_t) a.pos); // scrolls it into view
            logInfo("went to %#x", a.pos);
        }
        doc.hex.takeFocus = true;
        break;
    case OmniMode.find:
        // Take the pattern as the one to repeat, then look for it from just past
        // the caret, so Enter on the same pattern walks the document.
        Needle needle;
        if (ui_find_needle(needle))
        {
            lastNeedle = needle;
            haveNeedle = true;
            ui_find_step(false, cast(long) doc.hex.cursor + 1);
        }
        doc.hex.takeFocus = true;
        break;
    case OmniMode.inspect:
        // Nothing to jump to: the reading itself is the answer, so it goes to
        // the clipboard where it can be pasted into whatever asked the question.
        ubyte[8] raw = void;
        char[64] buf = void;
        const(char)[] value = ui_inspect_value(id, ui_inspect_bytes(raw), buf);
        if (value.length && id >= 0)
        {
            char[80] clip = void;
            size_t n = sformat(clip, "%s\0", value).length;
            if (SDL_SetClipboardText(clip.ptr))
                ui_status("copied %s", INSPECT[id].label);
            else
                logWarn("copy failed: %s", SDL_GetError().fromStringz);
        }
        doc.hex.takeFocus = true;
        break;
    case OmniMode.bookmark:
        if (id >= 0 && id < doc.marks.length)
            ui_mark_select(id);
        doc.hex.takeFocus = true;
        break;
    case OmniMode.help:
        doc.hex.takeFocus = true; // nothing to run: the sheet is there to be read
        break;
    }
}

/// The bytes a bookmark covers, as the detail column of its row: the first few
/// of them, enough to recognise what was marked, with the ASCII beside it for
/// text and the run's length after it when there is more than fits.
private string ui_bookmark_bytes(ref const(Bookmark) mark)
{
    if (doc.editor is null)
        return null;

    ubyte[8] raw = void;
    ubyte[] bytes = doc.editor.view(mark.at, raw);
    if (bytes.length == 0)
        return "past the end of the document";
    if (bytes.length > mark.length)
        bytes = bytes[0 .. cast(size_t) mark.length];

    char[80] buf = void;
    size_t n;
    foreach (ubyte b; bytes)
        n += sformat(buf[n .. $], "%02x ", b).length;
    foreach (ubyte b; bytes)
        buf[n++] = b >= 0x20 && b < 0x7f ? cast(char) b : '.';
    if (mark.length > bytes.length)
        n += sformat(buf[n .. $], "  (%d bytes)", mark.length).length;
    return ui_row_text(buf[0 .. n]);
}

/// The pattern the last search ran with, kept so Find Next has something to
/// repeat once the box is gone.
private __gshared Needle lastNeedle;
/// Ditto.
private __gshared bool haveNeedle;

/// Look for the last pattern from `from`, in whichever direction, and put the
/// selection on what turns up. Reports through the status bar either way: a
/// search that found nothing has to say so, or it reads as a dropped keystroke.
private void ui_find_step(bool backward, long from)
{
    if (haveNeedle == false)
    {
        ui_status("no pattern to find yet");
        return;
    }
    if (doc.editor is null)
        return;

    long at = search_find(lastNeedle, from, cast(long) hex_total(doc.hex),
        backward, &hexRead, cast(void*) doc.editor);
    if (at < 0)
    {
        ui_status("not found");
        return;
    }

    ui_select_range(cast(size_t) at, lastNeedle.length);
    ui_status("found at %#x", at);
}

/// Repeat the last search from where the caret is. The step off the caret is
/// what keeps a repeat moving instead of finding the same match again.
void ui_find_repeat(bool backward)
{
    long from = cast(long) doc.hex.cursor + (backward ? -1 : 1);
    ui_find_step(backward, from);
}

/// Put the selection over `len` bytes at `start` and scroll it into view. The
/// caret lands on the run's last byte, so the panel's own reveal keeps the run
/// on screen and Shift+arrows carry on extending from there.
private void ui_select_range(size_t start, size_t len)
{
    hex_set_caret(doc.hex, start); // clamps, actives, and scrolls onto it
    if (len > 1)
    {
        size_t total = hex_total(doc.hex);
        size_t end = start + len - 1;
        if (end >= total && total)
            end = total - 1;
        doc.hex.cursor = end;
    }
}

/// Set or clear a bookmark over the selection, or over the byte under the caret
/// when nothing is selected. Marking what is selected is the point: a field or a
/// header is worth coming back to, a lone byte of it rarely is.
void ui_mark_toggle()
{
    long at  = cast(long) hex_sel_low(doc.hex);
    long len = cast(long) hex_sel_high(doc.hex) - at + 1;

    bool set = bookmark_toggle(doc.marks, at, len);
    if (len > 1)
        ui_status(set ? "bookmarked %#x, %d byte(s)" : "cleared %#x, %d byte(s)",
            at, len);
    else
        ui_status(set ? "bookmark set at %#x" : "bookmark cleared at %#x", at);
}

/// Jump to the bookmark either side of the selection, wrapping at the ends, and
/// select the whole of what was marked there.
void ui_mark_step(int dir)
{
    ptrdiff_t index = bookmark_step(doc.marks, cast(long) hex_sel_low(doc.hex), dir);
    if (index < 0)
    {
        ui_status("no bookmarks in this document");
        return;
    }
    ui_mark_select(index);
}

/// Put the selection over the bookmark at `index` in the front document's list.
private void ui_mark_select(ptrdiff_t index)
{
    ui_select_range(cast(size_t) doc.marks[index].at,
        cast(size_t) doc.marks[index].length);
}

/// Run one command from the '>' list. Everything here is an entry point the
/// menubar already calls, so a command and its menu item cannot drift apart.
private void ui_omni_run(int id)
{
    switch (id)
    {
    case CMD_NEW_TAB:   ui_new_tab();          break;
    case CMD_OPEN:      ui_open_dialog();      break;
    case CMD_SAVE:      ui_save();             break;
    case CMD_SAVE_AS:   ui_save_as();          break;
    case CMD_CLOSE_TAB: ui_close_current_tab(); break;
    case CMD_CUT:       ui_cut();              break;
    case CMD_COPY:      ui_copy();             break;
    case CMD_PASTE:     ui_paste();            break;
    case CMD_MINIMAP:   minimapOn = minimapOn ? 0 : 1; break;
    case CMD_FIND_NEXT: ui_find_repeat(false); break;
    case CMD_FIND_PREV: ui_find_repeat(true);  break;
    case CMD_MARK:      ui_mark_toggle();      break;
    case CMD_MARK_NEXT: ui_mark_step(1);       break;
    case CMD_MARK_PREV: ui_mark_step(-1);      break;
    case CMD_MARK_CLEAR:
        ui_status("cleared %u bookmark(s)", doc.marks.length);
        doc.marks = null;
        break;
    // Back into the box on another prefix: an offset, a pattern, a reading and
    // the bookmark list are all typed there rather than in dialogs of their own.
    // It reopens next frame and grabs the keyboard when it does, so the panel
    // must not be handed focus on the way out.
    case CMD_GOTO:      omni_show(omni, OMNI_ADDRESS);  return;
    case CMD_FIND:      omni_show(omni, OMNI_FIND);     return;
    case CMD_INSPECT:   omni_show(omni, OMNI_INSPECT);  return;
    case CMD_MARK_LIST: omni_show(omni, OMNI_BOOKMARK); return;
    case CMD_ABOUT:     about_open();          break;
    case CMD_QUIT:
        // Through SDL's own queue, so it meets the same unsaved-changes check as
        // the window close button and File > Quit.
        SDL_Event quit; // .init zeroes the union
        quit.type = SDL_EVENT_QUIT;
        SDL_PushEvent(&quit);
        return;
    default:
        return;
    }
    doc.hex.takeFocus = true; // whatever it was, the bytes take keys again after
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

        // Rows in this window abut. ddui leaves a gap between rows, painted in
        // the window's own colour, which stripes the chrome (menubar, toolbar,
        // tabs) and the grid (column header, bytes) with pale seams instead of
        // letting each read as one surface. Restored on the way out, so the
        // About dialog keeps the stock spacing.
        int spacing = ctx.style.spacing;
        ctx.style.spacing = 0;
        scope(exit) ctx.style.spacing = spacing;

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
            ui_save_pending(pendingSavePath.ptr.fromStringz.idup);
        }

        ui_menubar(ctx);

        // Quick toolbar: the minimap toggle. Off falls back to a fat scrollbar.
        // It sits above the tabs, with the menubar, because it is a view setting
        // for the whole application rather than one document's: every tab draws
        // through the same panel and reads the same flag.
        // ddui paints nothing behind a plain layout row, so the toolbar would
        // show the window's pale grey between the dark menubar and tab strip.
        // Take the row, fill it in the same chrome colour, then put the widget
        // back inside it; an absolute rect is handed straight back by the layout
        // without advancing it.
        int toolbarH = ctx.style.size.y + ctx.style.padding * 2; // the menubar's
        static immutable int[1] full = [ -1 ];
        mu_layout_row(ctx, 1, full.ptr, toolbarH);
        mu_Rect toolbar = mu_layout_next(ctx);
        mu_draw_rect(ctx, toolbar, ctx.style.colors[MU_COLOR_TITLEBG]);
        mu_layout_set_next(ctx, mu_Rect(toolbar.x + ctx.style.padding, toolbar.y,
            120, toolbar.h), 0);
        mu_checkbox(ctx, "Minimap", &minimapOn);

        // Tabs last, so the strip sits directly on top of the document it names.
        ui_tabs(ctx);
        doc.hex.minimap = minimapOn != 0;

        // The editor's size shifts as inserts and deletes land, so refresh the
        // panel's copy each frame before it draws; the panel keeps it live within
        // a frame, this keeps it authoritative across them.
        if (doc.editor)
            doc.hex.dataSize = doc.editor.size();

        // The panel takes the rest of the window, save a strip at the bottom
        // reserved for the status bar. Feed it the monospace face. Every tab
        // draws through this one panel - only one is ever on screen - so its
        // ddui container is shared and the per-document state lives in HexView.
        int statusH = ctx.text_height(ctx.style.font) + 6;
        // Check return with `& MU_RES_CHANGE`
        cast(void)hex_view(ctx, "hexpanel", doc.hex, render_font_mono(), statusH);

        // Status bar: edit mode, a dirty marker, caret offset and selection length,
        // echoing what the panel reports back through its state. Pinned to the
        // window's bottom edge in the strip hex_view kept free above.
        static immutable int[1] srow = [ -1 ];
        mu_layout_row(ctx, 1, srow.ptr, statusH);
        mu_Rect sr = mu_layout_next(ctx);
        mu_draw_rect(ctx, sr, mu_Color(30, 30, 40, 255));
        char[80] statusbuf = void;
        size_t selLen = hex_total(doc.hex) ?
            hex_sel_high(doc.hex) - hex_sel_low(doc.hex) + 1 : 0;
        string mode  = doc.hex.insertMode ? "INS" : "OVR";
        string dirty = (doc.editor && doc.editor.edited()) ? " *" : "";
        char[] status = sformat(statusbuf, "%s%s  offset %08X  selected %u byte(s)",
            mode, dirty, doc.hex.cursor, selLen);
        int th = ctx.text_height(ctx.style.font);
        int ty = sr.y + (sr.h - th) / 2;
        mu_draw_text(ctx, ctx.style.font, cast(string) status,
            mu_Vec2(sr.x + 4, ty), mu_Color(170, 170, 185, 255));

        // The last message, against the right edge so it never collides with the
        // fixed readout on the left.
        if (statusLen)
        {
            string message = cast(string) statusText[0 .. statusLen];
            int mw = ctx.text_width(ctx.style.font, message.ptr, cast(int) message.length);
            mu_draw_text(ctx, ctx.style.font, message,
                mu_Vec2(sr.x + sr.w - 4 - mw, ty), mu_Color(200, 200, 150, 255));
        }

        // Name the document in the title bar last, so it agrees with the status
        // bar above: both then report the state this frame's input left behind,
        // rather than the title trailing an edit by a frame.
        ui_window_title();

        mu_end_window(ctx);
    }

    // Help > About, as its own root container so it floats over the main window.
    about_frame(ctx, width, height);

    // The omnibar goes last, over everything: it is the one thing that can be up
    // while the rest of the window carries on drawing behind it. The mode is read
    // before the box runs, so accepting acts on the list that was actually shown
    // rather than on one a prefix typed this same frame would have swapped in.
    OmniMode mode = omni_mode(omni);
    int chosen;
    const(OmniItem)[] rows = ui_omni_active() ? ui_omni_items() : null;
    final switch (omni_frame(ctx, omni, rows, width, height, chosen))
    {
    case OmniAction.none:    break;
    case OmniAction.accept:  ui_omni_accept(mode, chosen); break;
    case OmniAction.dismiss: doc.hex.takeFocus = true;     break;
    }
}

/// Draw the tab strip and act on what was clicked: one tab per open document,
/// showing its name and an unsaved-changes dot, plus the trailing + button.
///
/// The item slice is rebuilt every frame from `docs` (titles and dirty flags
/// both move under us) into storage that only ever grows, so a steady tab count
/// costs no allocation. Actions land straight away: a close can drop the
/// document the rest of this frame would have drawn, which is why everything
/// below the strip reads through `doc` rather than holding a reference.
private void ui_tabs(mu_Context* ctx)
{
    if (tabItems.length < docs.length)
        tabItems.length = docs.length;
    foreach (size_t i, ref Document d; docs)
        tabItems[i] = TabItem(d.title, d.editor && d.editor.edited());

    int index;
    TabAction action = tab_bar(ctx, "tabs", tabstrip, tabItems[0 .. docs.length],
        cast(int) current, index);
    switch (action)
    {
    case TabAction.select: ui_select_tab(index); break;
    case TabAction.close:  ui_close_tab(index);  break;
    case TabAction.add:    ui_new_tab();         break;
    default:
    }
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
        if (mu_menu_item_ex(ctx, "New Tab",    "Ctrl+T",       0, 0)) ui_new_tab();
        if (mu_menu_item_ex(ctx, "Open...",    "Ctrl+O",       0, 0)) ui_open_dialog();
        mu_menu_separator(ctx);
        if (mu_menu_item_ex(ctx, "Save",       "Ctrl+S",       0, 0)) ui_save();
        if (mu_menu_item_ex(ctx, "Save As...", "Ctrl+Shift+S", 0, 0)) ui_save_as();
        mu_menu_separator(ctx);
        if (mu_menu_item_ex(ctx, "Close Tab",  "Ctrl+W",       0, 0)) ui_close_current_tab();
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
