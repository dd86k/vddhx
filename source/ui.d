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
import split;
import tabbar;
import ddhx.inspector : InspectorType, inspector_rows, byteSize, formatInspector;
import std.system : Endian;
import render : render_font_mono;
import std.array : Appender, appender;
import std.format : format, sformat;
import std.path : baseName;

/// One open document: the ddhx editor that owns the bytes, and where they live
/// on disk. Nothing here says how the bytes are being looked at - that is a
/// View's business - so one document can be open in several panels at once.
private struct Document
{
    /// The editor backing the document. It owns the bytes and all the
    /// piece-table/undo machinery; a panel only ever reads through it.
    IDocumentEditor editor;

    /// Disk path backing the document, empty for an in-memory scratch buffer.
    /// Set on Open (and once a scratch buffer is first saved through Save As),
    /// it is the target an in-place Save writes to.
    string path;

    /// What the tab shows: the file's base name, or "untitled" for a scratch.
    string title;

    /// Bookmarked runs of bytes, sorted. Per document rather than per view,
    /// since an offset only means something against the bytes it points into: a
    /// mark set in one panel is a mark in every panel showing the same file.
    /// The panel tints them and the omnibar's '@' lists them.
    ///
    /// Edits made through a panel carry them along (see bookmark_shift), but
    /// undo and redo do not: the editor reports only where a change landed, not
    /// how many bytes it moved, so a mark can end up a few bytes off its bytes
    /// after a rolled-back insert. It is never wrong about which document it
    /// belongs to, only about where in it.
    Bookmark[] marks;
}

/// One way of looking at a document: which document, plus everything about the
/// looking - caret, selection, scroll position, entry mode.
///
/// Split from Document so the same file can be open in two panels at different
/// offsets, each with its own caret, the way an editor's windows sit over its
/// buffers. Today the tab strip keeps one view per document; the split panes
/// this was done for are what will make several of them at once.
private struct View
{
    /// The document this is a view of. Never null while the view is in a pane.
    Document* doc;

    /// Persisted hex panel state (the selection lives here across frames). The
    /// caret is active from the outset so it sits ready on a blank panel,
    /// letting a file be built from scratch before anything is opened.
    HexView hex = { active: true };
}

/// One pane: a strip of tabs over a hex panel, filling its share of the window.
///
/// Panes sit side by side in a flat row with a splitter between each pair - the
/// way an editor's groups do - rather than nesting. Each holds its own tabs and
/// its own front tab, so the same file can be open on the left at one offset and
/// on the right at another.
private struct Pane
{
    /// The views this pane has tabs for, in strip order. Never empty while the
    /// pane is in `panes`: a pane that loses its last tab is closed with it.
    View*[] views;

    /// Index into `views` of the one on screen.
    size_t current;

    /// The strip's own scroll offset and in-progress drag.
    TabBar tabs;

    /// Item slice handed to the strip, rebuilt each frame into storage that only
    /// ever grows, so a steady tab count costs no allocation.
    TabItem[] items;

    /// Share of the row this pane takes, against its neighbours'. Relative, so a
    /// window resize needs no arithmetic here: the same weights simply divide a
    /// different number of pixels.
    int weight = SPLIT_WEIGHT;

    /// Where this pane was last drawn. Recorded by ui_panes so that a hit test
    /// can be made from outside a frame: a file dragged over the window arrives
    /// as an SDL event carrying a window coordinate and nothing else, and the
    /// pane it is pointing at has to be worked out from that alone.
    mu_Rect rect;
}

/// Every open document, every view onto one, and every pane showing views.
///
/// All held by pointer: the panel's callbacks park a Document* and a View* for
/// ddui to hand back on every read, colour and edit, and those have to survive a
/// document being closed out of the middle of the array. Panes likewise, since a
/// pane's ddui ids and tab state have to outlive its neighbours closing.
///
/// None is ever empty: startup opens a scratch buffer, closing the last tab of
/// the last pane leaves a fresh one behind, and a pane that empties is closed
/// unless it is the only one. So every action below always has a pane, a view
/// and a document to work on.
private __gshared Document*[] docs;
/// Ditto.
private __gshared Pane*[] panes;

/// Index into `panes` of the one taking the keyboard. Every action below acts on
/// this pane's front tab.
private __gshared size_t focused;

/// Scratch for laying the pane row out: the weights copied out of `panes` and the
/// pixel widths they come to. Both only ever grow.
private __gshared int[] paneWeights;
/// Ditto.
private __gshared int[] paneWidths;

/// Narrowest a pane may be dragged, in pixels. Enough that the offset column and
/// a few bytes stay legible: a pane squeezed below this is not a view of anything.
private enum int PANE_MIN = 180;

/// Scratch buffers are numbered in creation order: "untitled", "untitled 2"...
private __gshared uint untitled;

/// Omnibar state, and the candidate rows handed to it. Like the tab strip's, the
/// row storage is rebuilt each frame into an array that only ever grows.
private __gshared Omnibar omni;
/// Ditto.
private __gshared OmniItem[] omniItems;

/// The pane and tab each switcher row stands for, parallel to `omniItems` while
/// the switcher is the mode showing. A row's id indexes this.
private __gshared size_t[2][] omniTabs;

/// The pane taking the keyboard, the view it has in front, and the document that
/// view is showing. Every action below acts on one of the three: `pane` for the
/// tabs, `view` for anything about the caret and what is on screen, `doc` for
/// anything about the bytes themselves.
private ref Pane pane()
{
    return *panes[focused];
}
/// Ditto.
private ref View view()
{
    return *panes[focused].views[panes[focused].current];
}
/// Ditto.
private ref Document doc()
{
    return *view().doc;
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

    Document* d = new Document;
    d.editor = spawnEditor(); // no document: a zero-length, in-memory buffer
    d.title  = untitled == 1 ? "untitled" : format("untitled %u", untitled);
    docs ~= d;

    View* v = new View;
    v.doc = d;
    wireView(v);

    // The first tab of all has no pane to go in yet: ui_init opens it before
    // anything has laid the window out.
    if (panes.length == 0)
        panes ~= newPane();

    Pane* p = panes[focused];
    p.views ~= v;
    p.current = p.views.length - 1;
    v.hex.takeFocus = true; // ready to take bytes without a click first
}

/// A fresh pane with no tabs in it. Callers fill in `views` before the next frame.
private Pane* newPane()
{
    Pane* p = new Pane;

    // The strip caps this pane's own canvas, not the window, so the active tab
    // takes the grid's colour rather than the window's and the two read as one
    // surface. ui_style cannot do it: panes come and go long after it has run.
    p.tabs.content = CANVAS;
    return p;
}

/// Bring the tab at `index` to the front of the focused pane. Out-of-range
/// indices are ignored, so a stale index from a strip built before a close
/// cannot strand the panel.
void ui_select_tab(size_t index)
{
    ui_select_tab_in(focused, index);
}

/// Ditto, in a named pane - which also becomes the focused one, since bringing a
/// tab forward is asking to work in it.
private void ui_select_tab_in(size_t paneIndex, size_t index)
{
    if (paneIndex >= panes.length)
        return;
    Pane* p = panes[paneIndex];
    if (index >= p.views.length)
        return;
    focused = paneIndex;
    p.current = index;
    p.views[index].hex.takeFocus = true; // typing follows the tab that came forward
}

/// Step `delta` tabs along from the current one, wrapping at either end.
void ui_cycle_tab(int delta)
{
    Pane* p = panes[focused];
    if (p.views.length <= 1)
        return;

    long count = cast(long) p.views.length;
    long at = (cast(long) p.current + delta) % count;
    if (at < 0)
        at += count;
    ui_select_tab(cast(size_t) at);
}

/// Close the tab at `index`, resolving unsaved edits first (the document is
/// brought to the front for the prompt, and a cancel leaves it open). Closing
/// the last one closes the editor too, the way a tabbed application does.
///
/// It is the view that closes. The document behind it only goes when nothing
/// else is looking at it, so closing one half of a split leaves the file open in
/// the other half - and, since the bytes are not going anywhere, that close has
/// nothing to prompt about either.
void ui_close_tab(size_t index)
{
    ui_close_tab_in(focused, index);
}

/// Ditto, in a named pane. The pane is named rather than taken by pointer
/// because the prompt below can bring another pane forward on its way past.
private void ui_close_tab_in(size_t paneIndex, size_t index)
{
    if (paneIndex >= panes.length || index >= panes[paneIndex].views.length)
        return;

    Document* d = panes[paneIndex].views[index].doc;
    bool last = ui_view_count(d) <= 1;
    if (last && ui_confirm_discard(d, "Close document") != Confirm.proceed)
        return;

    // Re-read the pane: the prompt above may have moved the focus to it, and a
    // Save As raised from it may have run a frame's worth of work.
    Pane* p = panes[paneIndex];
    p.views = p.views[0 .. index] ~ p.views[index + 1 .. $];
    if (last)
        ui_drop_document(d);

    if (p.views.length == 0)
    {
        // An empty pane goes, and the row closes over it - unless it is the only
        // one left, in which case there is nothing to close over it and the
        // window itself is what is being shut.
        if (panes.length > 1)
        {
            ui_drop_pane(paneIndex);
            return;
        }

        // Out of tabs in the last pane: quit, through SDL's own event queue so it
        // meets the same route as the window close button. That lands next frame,
        // and the rest of this one still has a panel to draw, so put a scratch
        // buffer up meanwhile - it has no edits, so it cannot hold the quit up.
        ui_new_tab();
        SDL_Event quit; // .init zeroes the union
        quit.type = SDL_EVENT_QUIT;
        SDL_PushEvent(&quit);
        return;
    }

    // Closing a tab left of the front one shifts it down; closing the front one
    // keeps the index, which now names its right-hand neighbour (or the new last
    // tab, when the front one was the last).
    if (index < p.current)
        --p.current;
    if (p.current >= p.views.length)
        p.current = p.views.length - 1;
    p.views[p.current].hex.takeFocus = true; // ready to type in
}

/// How many views, in any pane, are currently showing `d`. Closing the last of
/// them is what closes the document itself.
private size_t ui_view_count(const(Document)* d)
{
    size_t n;
    foreach (Pane* p; panes)
        foreach (View* v; p.views)
            if (v.doc is d)
                ++n;
    return n;
}

/// Close `d`'s editor and drop it from `docs`. Only for a document no view is
/// left showing: every View.doc still held by a pane has to stay valid.
private void ui_drop_document(Document* d)
{
    if (d.editor)
        d.editor.close();
    foreach (size_t i, Document* other; docs)
    {
        if (other !is d)
            continue;
        docs = docs[0 .. i] ~ docs[i + 1 .. $];
        return;
    }
}

/// Bring a view of `d` to the front, so a prompt about it is a prompt about what
/// is on screen. Does nothing when no view is showing it.
private void ui_focus_document(const(Document)* d)
{
    foreach (size_t i, Pane* p; panes)
    {
        foreach (size_t j, View* v; p.views)
        {
            if (v.doc is d)
            {
                ui_select_tab_in(i, j);
                return;
            }
        }
    }
}

/// Drop the pane at `index` from the row, handing its share of the width to a
/// neighbour so the panes still fill the window between them. Its views go with
/// it, so the caller closes those first (ui_close_tab_in does).
private void ui_drop_pane(size_t index)
{
    if (index >= panes.length || panes.length <= 1)
        return;

    // The pane on the left inherits the space, or the one on the right when the
    // pane closing is the first: either way the row's total weight is unchanged
    // and nothing else on it moves.
    size_t heir = index > 0 ? index - 1 : index + 1;
    panes[heir].weight += panes[index].weight;

    panes = panes[0 .. index] ~ panes[index + 1 .. $];

    // Closing a pane left of the focused one shifts it down; closing the focused
    // one keeps the index, which now names its right-hand neighbour (or the new
    // last pane, when the one that went was the last).
    if (focused > index)
        --focused;
    if (focused >= panes.length)
        focused = panes.length - 1;

    pane.views[pane.current].hex.takeFocus = true; // the pane that took over
}

/// Split the focused pane in two: a second pane opens beside it, showing the
/// same document at the same offset, and takes the keyboard.
///
/// The same document rather than a copy of it - one editor, one undo history,
/// one set of bookmarks - so the two panes are two windows onto one file, and an
/// edit made in either shows up in both. What they do not share is the looking:
/// the new view carries the old one's caret and scroll position as a starting
/// point and then moves on its own, which is the whole use of a split here.
void ui_split()
{
    View* src = pane.views[pane.current];

    View* v = new View;
    v.doc = src.doc;
    v.hex = hex_split(src.hex); // its own scratch buffers, the same place in the file
    wireView(v);                // and its own hooks, pointing at itself
    v.hex.takeFocus = true;

    Pane* p = newPane();
    p.views ~= v;

    // The new pane takes half the space of the one it came out of, so the rest of
    // the row is left exactly as it was.
    p.weight = panes[focused].weight / 2;
    panes[focused].weight -= p.weight;

    panes = panes[0 .. focused + 1] ~ p ~ panes[focused + 1 .. $];
    ++focused;
}

/// Close the focused pane, tab by tab, so each document still gets its say about
/// unsaved changes. A cancelled prompt stops the whole thing where it stands.
/// The last pane cannot be closed: there would be nothing left to draw.
void ui_close_pane()
{
    if (panes.length <= 1)
    {
        ui_status("the last pane cannot be closed");
        return;
    }

    Pane* p = panes[focused];
    for (;;)
    {
        // Found again each round rather than held as an index: a prompt can bring
        // another pane forward on its way past, and the last tab closing takes
        // this pane out of the row altogether.
        size_t at = size_t.max;
        foreach (size_t i, Pane* q; panes)
            if (q is p)
            {
                at = i;
                break;
            }
        if (at == size_t.max)
            return; // gone, which is what was asked for

        size_t before = p.views.length;
        ui_close_tab_in(at, p.current);
        if (p.views.length == before) // a prompt was cancelled: leave it open
            return;
    }
}

/// Move the keyboard to the pane at `index`, counted from the left. Out of range
/// does nothing, so Ctrl+9 on a two-pane window is simply ignored.
void ui_focus_pane(size_t index)
{
    if (index >= panes.length)
        return;
    focused = index;
    pane.views[pane.current].hex.takeFocus = true;
}

/// Step `delta` panes along from the focused one, wrapping at either end.
void ui_cycle_pane(int delta)
{
    if (panes.length <= 1)
        return;

    long count = cast(long) panes.length;
    long at = (cast(long) focused + delta) % count;
    if (at < 0)
        at += count;
    ui_focus_pane(cast(size_t) at);
}

/// Close the tab on screen. The Ctrl+W and File > Close Tab route.
void ui_close_current_tab()
{
    ui_close_tab(pane.current);
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
    ui_wakeup();
}

/// Nudge the event loop into drawing a frame. It sleeps between events, so a
/// change made from anywhere but an event - the dialog callbacks above and
/// below, which SDL answers on its own thread - would sit unseen until the next
/// keystroke or mouse move. SDL's queue is the wakeup: pushing to it is safe
/// from any thread, and the loop ignores the event itself.
private void ui_wakeup() nothrow
{
    SDL_Event wake; // .init zeroes the union
    wake.type = SDL_EVENT_USER;
    SDL_PushEvent(&wake);
}

/// ddui-side byte source: hand the panel's window request straight to the editor,
/// which fills only those bytes. `user` is the editor stashed in hex.readUser.
///
/// The editor rather than the view, because this doubles as the byte source the
/// search module walks a document with (see ui_find_step), where there is no
/// panel involved at all.
private ubyte[] hexRead(long pos, ubyte[] buf, void* user)
{
    IDocumentEditor ed = cast(IDocumentEditor) user;
    return ed.view(pos, buf);
}

/// ddui-side colour scheme: bookmarked bytes stand out, everything else is
/// classified the way the panel would have classified it anyway. `user` is the
/// Document stashed in hex.colorUser - the marks belong to the bytes being drawn,
/// not to whichever document happens to be in front.
private mu_Color hexColor(size_t offset, ubyte value, void* user)
{
    Document* d = cast(Document*) user;
    if (d && bookmark_has(d.marks, cast(long) offset))
        return BOOKMARK_TINT;
    return hex_classify(offset, value, null);
}

/// ddui-side write hooks: forward the panel's single-byte edits to the editor.
/// The editor holds them in its piece table (nothing touches disk until a Save),
/// so these work even on a file opened read-only. A rejected edit (a fixed-size
/// document, say) throws; swallow it with a log rather than unwinding the frame.
///
/// `user` is the View that owns the panel, from hex.writeUser, which is what
/// says whose bytes are being edited: the panel taking keys is not necessarily
/// a view of the document in front once panels can sit side by side.
private void hexReplace(long pos, ubyte value, void* user)
{
    View* v = cast(View*) user;
    try
        v.doc.editor.replace(pos, &value, 1);
    catch (Exception e)
        logWarn("replace failed: %s", e.msg);
}
/// Ditto.
private void hexInsert(long pos, ubyte value, void* user)
{
    View* v = cast(View*) user;
    try
    {
        v.doc.editor.insert(pos, &value, 1);
        bookmark_shift(v.doc.marks, pos, 1); // the bytes past it all moved up one
    }
    catch (Exception e)
        logWarn("insert failed: %s", e.msg);
}
/// Ditto.
private void hexRemove(long pos, long len, void* user)
{
    View* v = cast(View*) user;
    try
    {
        v.doc.editor.remove(pos, len);
        bookmark_shift(v.doc.marks, pos, -len);
    }
    catch (Exception e)
        logWarn("remove failed: %s", e.msg);
}

/// ddui-side history hooks: step the editor's undo/redo and hand back where the
/// change landed so the panel can chase it with the caret. The editor's size can
/// jump either way here, so refresh the panel's copy before returning - the copy
/// belonging to the view that took the keystroke, which `user` names. Any other
/// view of the same document picks the new size up from ui_frame next frame.
private long hexUndo(void* user)
{
    View* v = cast(View*) user;
    long at = -1;
    try
        at = v.doc.editor.undo();
    catch (Exception e)
        logWarn("undo failed: %s", e.msg);
    v.hex.dataSize = v.doc.editor.size();
    return at;
}
/// Ditto.
private long hexRedo(void* user)
{
    View* v = cast(View*) user;
    long at = -1;
    try
        at = v.doc.editor.redo();
    catch (Exception e)
        logWarn("redo failed: %s", e.msg);
    v.hex.dataSize = v.doc.editor.size();
    return at;
}

/// Point a view's panel at its document: read, colour, write and history hooks,
/// plus the size the panel starts from. Called on every new view and whenever a
/// view is pointed at a different document, so editing always targets the bytes
/// that panel is showing.
///
/// The view is taken by pointer because that pointer is what the hooks above are
/// handed back on every call, long after this returns.
private void wireView(View* v)
{
    IDocumentEditor ed = v.doc.editor;
    v.hex.readFn    = &hexRead;
    v.hex.readUser  = cast(void*) ed;
    v.hex.replaceFn = &hexReplace;
    v.hex.insertFn  = &hexInsert;
    v.hex.removeFn  = &hexRemove;
    v.hex.undoFn    = &hexUndo;
    v.hex.redoFn    = &hexRedo;
    v.hex.writeUser = cast(void*) v;
    v.hex.colorFn   = &hexColor;
    v.hex.colorUser = cast(void*) v.doc;
    v.hex.data      = null;
    v.hex.dataSize  = ed ? ed.size() : 0;
}

/// The pane a file is currently being dragged over, or -1 for none. Only ever
/// set while a drag is in flight over the window; see ui_drop_hover.
private __gshared ptrdiff_t dropPane = -1;

/// Colour a pane is picked out in while a file is held over it.
private enum mu_Color DROP_EDGE = mu_Color(110, 170, 255, 255);
/// Ditto, the wash over the pane itself, translucent so the bytes read through.
private enum mu_Color DROP_WASH = mu_Color(110, 170, 255, 40);
/// Thickness of the edge, in pixels.
private enum int DROP_EDGE_W = 2;

/// The pane at a window coordinate, or -1 when the point is not in one (the
/// menubar, the status bar, a splitter between two panes).
private ptrdiff_t ui_pane_at(int x, int y)
{
    foreach (size_t i, Pane* p; panes)
    {
        mu_Rect r = p.rect;
        if (x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h)
            return cast(ptrdiff_t) i;
    }
    return -1;
}

/// A file is being dragged over the window: mark the pane under the pointer so
/// the user can see where it would land before letting go. Called for every
/// position report SDL sends while the drag is in flight.
void ui_drop_hover(int x, int y)
{
    dropPane = ui_pane_at(x, y);
}

/// The drag is over, dropped or not: stop marking anything.
void ui_drop_clear()
{
    dropPane = -1;
}

/// Open a dropped file in the pane it was dropped on, rather than in whichever
/// pane happened to have the keyboard. Dropping is a pointing gesture: the pane
/// under the cursor is the one being asked for, and it takes the focus with the
/// file. A drop that misses every pane falls back to the focused one.
void ui_drop_file(string path, int x, int y)
{
    ptrdiff_t at = ui_pane_at(x, y);
    if (at >= 0)
        focused = cast(size_t) at;
    ui_drop_clear();
    ui_open(path);
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
    // A scratch buffer nothing else is looking at is taken over rather than left
    // behind as an empty tab; one another view is showing has to stay put, since
    // pulling its editor out from under that view would strand it. The tab lands
    // in the focused pane, which is where the user was working.
    Pane* p = panes[focused];
    Document* d = p.views[p.current].doc;
    if (scratchEmpty(*d) && ui_view_count(d) == 1)
    {
        if (d.editor)
            d.editor.close(); // release the placeholder and its handle
    }
    else
    {
        d = new Document;
        docs ~= d;

        View* fresh = new View;
        fresh.doc = d;
        p.views ~= fresh;
        p.current = p.views.length - 1;
    }

    d.editor = ed;
    d.path   = path; // in-place Save now has a target
    d.title  = baseName(path);

    View* v = p.views[p.current];
    v.doc = d;
    wireView(v); // picks the new editor up, on a fresh view and a reused one alike
    v.hex.baseAddress = 0;
    v.hex.active = true;    // show the caret right away on the first byte
    v.hex.takeFocus = true; // and let it take keys without a click first
    v.hex.cursor = 0;
    v.hex.anchor = 0;
    hex_reset_scroll(v.hex); // and scroll to the top so that first byte is visible
    logInfo("opened %s (%s bytes)", path, v.hex.dataSize);
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
    ui_wakeup();
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
    foreach (Document* d; docs)
    {
        if (d.editor !is pendingSaveTarget)
            continue;
        if (saveTo(*d, dest))
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

/// Resolve the byte range Copy and Cut act on in `v`, clamped to its document.
/// Returns false when there is nothing to act on: no document, no caret placed
/// yet, or the caret parked on the append slot past the last byte. A bare caret
/// gives a single byte, matching what the status bar reports and what Delete
/// removes.
///
/// The view is a parameter rather than read off `current` because a selection is
/// a property of a panel: with panes on screen at once, the one being copied out
/// of is whichever has focus, not whichever the tab strip has in front. Taking
/// the View also reaches its document, so the pair never has to be passed apart.
private bool ui_selection(ref View v, out size_t low, out size_t high)
{
    if (v.doc.editor is null || v.hex.active == false)
        return false;

    size_t total = hex_total(v.hex);
    low  = hex_sel_low(v.hex);
    high = hex_sel_high(v.hex);
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
    if (ui_selection(view, low, high) == false)
        return false;

    size_t len = high - low + 1;
    if (len > COPY_MAX)
    {
        logWarn("copy refused: %s bytes selected, over the %s byte limit", len, COPY_MAX);
        return false;
    }

    static immutable string digits = "0123456789abcdef";
    int cols = view.hex.columns > 0 ? view.hex.columns : 16;
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
    if (ui_selection(view, low, high) == false)
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

    view.hex.dataSize = doc.editor.size();
    hex_set_caret(view.hex, low); // the caret closes onto the gap the cut left
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
    size_t total = hex_total(view.hex);
    size_t low   = view.hex.active ? hex_sel_low(view.hex) : 0;
    size_t high  = view.hex.active ? hex_sel_high(view.hex) : 0;
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
        if (replacing || view.hex.insertMode || low >= total)
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
    view.hex.dataSize = editor.size();
    hex_set_caret(view.hex, ok ? low + bytes.length : low);
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

/// Resolve unsaved edits in `d` before an action that would discard them
/// (closing the last view of it, or quitting). With no edits pending it proceeds
/// silently; otherwise it brings a view of that document to the front - so the
/// prompt is about what is on screen, and a Save As raised from here lands on
/// it - and puts up a native Save / Don't Save / Cancel prompt titled `title`.
/// Returns Confirm.proceed when the caller may go ahead (saved or discarded) and
/// Confirm.cancel when the user backed out, a chosen save has yet to finish, or
/// the prompt itself failed (fail safe: never lose data on an error).
private Confirm ui_confirm_discard(Document* d, const(char)* title)
{
    if (d is null)
        return Confirm.proceed;
    if ((d.editor && d.editor.edited()) == false)
        return Confirm.proceed;

    ui_focus_document(d);

    static immutable SDL_MessageBoxButtonData[3] buttons = [
        { SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT, btnSave,     "Save" },
        { cast(SDL_MessageBoxButtonFlags) 0,       btnDontSave, "Don't Save" },
        { SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT, btnCancel,   "Cancel" },
    ];
    // Name the document: with several tabs open, "the document" is not enough
    // to tell the user which one they are about to lose.
    string message = format("%s has unsaved changes.", d.title);
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
/// Every open document is asked about in turn, each prompt naming its own, and
/// the first cancel stops the quit with the rest left untouched. Documents
/// rather than tabs, so a file open in two panels is only asked about once.
bool ui_may_quit()
{
    foreach (Document* d; docs)
        if (ui_confirm_discard(d, "Quit vddhx") != Confirm.proceed)
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
    CMD_SKIP_NEXT, CMD_SKIP_PREV,
    CMD_MARK, CMD_MARK_NEXT, CMD_MARK_PREV, CMD_MARK_LIST, CMD_MARK_CLEAR,
    CMD_SPLIT, CMD_CLOSE_PANE, CMD_PANE_NEXT, CMD_PANE_PREV,
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
    Entry("Skip Forward",     "Ctrl+Right",   CMD_SKIP_NEXT),
    Entry("Skip Back",        "Ctrl+Left",    CMD_SKIP_PREV),
    Entry("Toggle Bookmark",  "Ctrl+B",       CMD_MARK),
    Entry("Next Bookmark",    "]",            CMD_MARK_NEXT),
    Entry("Previous Bookmark","[",            CMD_MARK_PREV),
    Entry("Bookmarks...",     "",             CMD_MARK_LIST),
    Entry("Clear Bookmarks",  "",             CMD_MARK_CLEAR),
    Entry("Split Pane",       "Ctrl+\\",      CMD_SPLIT),
    Entry("Close Pane",       "",             CMD_CLOSE_PANE),
    Entry("Next Pane",        "",             CMD_PANE_NEXT),
    Entry("Previous Pane",    "",             CMD_PANE_PREV),
    Entry("Toggle Minimap",   "",             CMD_MINIMAP),
    Entry("About vddhx",      "",             CMD_ABOUT),
    Entry("Quit",             "Ctrl+Q",       CMD_QUIT),
];

/// The head of the '?' sheet: the omnibar's own prefixes, the characters that
/// pick what the box is searching. They are as much a shortcut as any chord, and
/// the only ones with nowhere else to be advertised, so the sheet opens on them.
/// The characters come from the omnibar's own enums, so the sheet cannot drift
/// from what the box actually answers to.
private immutable Entry[] PREFIXES = [
    Entry("Omnibar: switch tab",             "(no prefix)"),
    Entry("Omnibar: run a command",          "" ~ OMNI_COMMAND),
    Entry("Omnibar: go to an offset",        "" ~ OMNI_ADDRESS),
    Entry("Omnibar: find a pattern",         "" ~ OMNI_FIND),
    Entry("Omnibar: inspect bytes at caret", "" ~ OMNI_INSPECT),
    Entry("Omnibar: list bookmarks",         "" ~ OMNI_BOOKMARK),
    Entry("Omnibar: this sheet",             "" ~ OMNI_HELP),
];

/// The rest of the '?' sheet: every key the application answers to, in the order
/// they come up - the omnibar itself, then the window, then the caret and the
/// bytes under it. Nothing here runs; it is the sheet you open to remember a
/// chord.
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
    Entry("Split the pane",               "Ctrl+\\"),
    Entry("Go to pane 1, 2, 3...",        "Ctrl+1 .. Ctrl+9"),
    Entry("Quit",                         "Ctrl+Q"),
    Entry("Find",                         "Ctrl+F"),
    Entry("Find next / previous",         "Ctrl+N / Ctrl+Shift+N"),
    Entry("Inspect bytes at the caret",   "Alt+I"),
    Entry("Toggle bookmark",              "Ctrl+B"),
    Entry("Next / previous bookmark",     "] / ["),
    Entry("Cut / copy / paste bytes",     "Ctrl+X / C / V"),
    Entry("Undo / redo",                  "Ctrl+Z / Ctrl+Y"),
    Entry("Move the caret",               "Arrows"),
    Entry("Skip the run under the caret", "Ctrl+Left / Ctrl+Right"),
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
        view.hex.takeFocus = true; // typing goes back to the bytes
}

/// Put the omnibar away, whatever it was showing. The Esc route.
void ui_omni_close()
{
    if (omni_shown(omni) == false)
        return;
    omni_hide(omni);
    view.hex.takeFocus = true;
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
        // One row per tab across every pane, not per document: the switcher picks
        // a panel to go to, and two views of one file are two places to be. The
        // path is what tells two same-named files apart, so it is both the detail
        // column and, through the omnibar's matching, searchable itself.
        //
        // A row's id is its place in this list rather than a tab index, since a
        // tab index means nothing without the pane it counts within; omniTabs
        // carries the pair back for ui_omni_accept to act on.
        size_t at;
        foreach (size_t pi, Pane* p; panes)
        {
            foreach (size_t ti, View* v; p.views)
            {
                if (at >= omniTabs.length)
                    omniTabs.length = at + 16;
                omniTabs[at] = [ pi, ti ];
                put(v.doc.title, v.doc.path.length ? v.doc.path : "not saved yet",
                    cast(int) at, v.doc.editor && v.doc.editor.edited());
                ++at;
            }
        }
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
        // The prefixes first, then the chords: equal scores keep this order, so
        // an unfiltered sheet reads as the two lists it is.
        foreach (ref immutable Entry e; PREFIXES)
            put(e.label, e.keys, e.id);
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
    return address_parse(omni_query(omni), cast(long) view.hex.cursor,
        cast(long) hex_total(view.hex));
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
    size_t total = hex_total(view.hex);
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
    long total = cast(long) hex_total(view.hex);
    long at = cast(long) hex_sel_low(view.hex);
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
        // The id indexes the flat list the rows were built from, which carries
        // the pane the tab lives in as well as the tab itself.
        if (id >= 0 && id < omniTabs.length)
            ui_select_tab_in(omniTabs[id][0], omniTabs[id][1]); // takes focus itself
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
            hex_set_caret(view.hex, cast(size_t) a.pos); // scrolls it into view
            logInfo("went to %#x", a.pos);
        }
        view.hex.takeFocus = true;
        break;
    case OmniMode.find:
        // Take the pattern as the one to repeat, then look for it from just past
        // the caret, so Enter on the same pattern walks the document.
        Needle needle;
        if (ui_find_needle(needle))
        {
            lastNeedle = needle;
            haveNeedle = true;
            ui_find_step(view, false, cast(long) view.hex.cursor + 1);
        }
        view.hex.takeFocus = true;
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
        view.hex.takeFocus = true;
        break;
    case OmniMode.bookmark:
        if (id >= 0 && id < doc.marks.length)
            ui_mark_select(view, id);
        view.hex.takeFocus = true;
        break;
    case OmniMode.help:
        view.hex.takeFocus = true; // nothing to run: the sheet is there to be read
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

/// Look through `v`'s document for the last pattern from `from`, in whichever
/// direction, and put that view's selection on what turns up. Reports through the
/// status bar either way: a search that found nothing has to say so, or it reads
/// as a dropped keystroke.
private void ui_find_step(ref View v, bool backward, long from)
{
    if (haveNeedle == false)
    {
        ui_status("no pattern to find yet");
        return;
    }
    if (v.doc.editor is null)
        return;

    long at = search_find(lastNeedle, from, cast(long) hex_total(v.hex),
        backward, &hexRead, cast(void*) v.doc.editor);
    if (at < 0)
    {
        ui_status("not found");
        return;
    }

    ui_select_range(v, cast(size_t) at, lastNeedle.length);
    ui_status("found at %#x", at);
}

/// Repeat the last search from where the caret is. The step off the caret is
/// what keeps a repeat moving instead of finding the same match again.
void ui_find_repeat(bool backward)
{
    long from = cast(long) view.hex.cursor + (backward ? -1 : 1);
    ui_find_step(view, backward, from);
}

/// Move past the run of identical elements at the caret, the way ddhx's skip-back
/// and skip-forward do: it lands on the first element either side that holds
/// something else, so a field of zeroes or a stretch of padding is crossed in one
/// keystroke. A run reaching the end of the document goes there rather than
/// leaving the key looking dropped.
///
/// The element is the byte under a bare caret, and the whole of the selection
/// when there is one, which is how a table of records is walked a record at a
/// time: select one, and each keystroke steps to the next one that reads
/// differently. What is landed on stays selected, so the walk can be repeated -
/// ddhx drops the selection there and vddhx keeps it, since a chord that cannot
/// be pressed twice is half a movement.
void ui_skip_element(bool backward)
{
    if (doc.editor is null)
        return;

    long total = cast(long) hex_total(view.hex);
    if (total <= 0)
        return;

    // The selection is the element, taken from its low end the way ddhx takes it,
    // so both directions step in the same lane. A selection can outlive the bytes
    // it covered (a delete under it), so it is clamped to the document first.
    long from = cast(long) hex_sel_low(view.hex);
    long high = cast(long) hex_sel_high(view.hex);
    if (high >= total)
        high = total - 1;
    long len = high >= from ? high - from + 1 : 1;
    if (len > cast(long) SEARCH_ELEMENT_MAX)
    {
        ui_status("selection too long to skip over (max %u bytes)", SEARCH_ELEMENT_MAX);
        return;
    }
    // Nothing ahead of the append slot past the last byte, so a forward skip from
    // there has nowhere to go; backward still walks the run behind it.
    if (from >= total && backward == false)
        return;

    long at = search_skip(from, len, total, backward, &hexRead, cast(void*) doc.editor);
    if (at < 0)
        return;
    if (len > 1)
        ui_select_range(view, cast(size_t) at, cast(size_t) len);
    else
        hex_set_caret(view.hex, cast(size_t) at);
}

/// Put `v`'s selection over `len` bytes at `start` and scroll it into view. The
/// caret lands on the run's last byte, so the panel's own reveal keeps the run
/// on screen and Shift+arrows carry on extending from there.
private void ui_select_range(ref View v, size_t start, size_t len)
{
    hex_set_caret(v.hex, start); // clamps, actives, and scrolls onto it
    if (len > 1)
    {
        size_t total = hex_total(v.hex);
        size_t end = start + len - 1;
        if (end >= total && total)
            end = total - 1;
        v.hex.cursor = end;
    }
}

/// Set or clear a bookmark over the selection, or over the byte under the caret
/// when nothing is selected. Marking what is selected is the point: a field or a
/// header is worth coming back to, a lone byte of it rarely is.
void ui_mark_toggle()
{
    long at  = cast(long) hex_sel_low(view.hex);
    long len = cast(long) hex_sel_high(view.hex) - at + 1;

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
    ptrdiff_t index = bookmark_step(doc.marks, cast(long) hex_sel_low(view.hex), dir);
    if (index < 0)
    {
        ui_status("no bookmarks in this document");
        return;
    }
    ui_mark_select(view, index);
}

/// Put `v`'s selection over the bookmark at `index` in its document's list.
private void ui_mark_select(ref View v, ptrdiff_t index)
{
    ui_select_range(v, cast(size_t) v.doc.marks[index].at,
        cast(size_t) v.doc.marks[index].length);
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
    case CMD_SKIP_NEXT: ui_skip_element(false); break;
    case CMD_SKIP_PREV: ui_skip_element(true);  break;
    case CMD_MARK:      ui_mark_toggle();      break;
    case CMD_MARK_NEXT: ui_mark_step(1);       break;
    case CMD_MARK_PREV: ui_mark_step(-1);      break;
    case CMD_SPLIT:      ui_split();           break;
    case CMD_CLOSE_PANE: ui_close_pane();      break;
    case CMD_PANE_NEXT:  ui_cycle_pane(1);     break;
    case CMD_PANE_PREV:  ui_cycle_pane(-1);    break;
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
    view.hex.takeFocus = true; // whatever it was, the bytes take keys again after
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

        // The panes take the rest of the window, save a strip at the bottom
        // reserved for the status bar.
        int statusH = ctx.text_height(ctx.style.font) + 6;
        ui_panes(ctx, statusH);

        // Status bar: edit mode, a dirty marker, caret offset and selection length,
        // echoing what the panel reports back through its state. Pinned to the
        // window's bottom edge in the strip hex_view kept free above.
        static immutable int[1] srow = [ -1 ];
        mu_layout_row(ctx, 1, srow.ptr, statusH);
        mu_Rect sr = mu_layout_next(ctx);
        mu_draw_rect(ctx, sr, mu_Color(30, 30, 40, 255));
        char[80] statusbuf = void;
        size_t selLen = hex_total(view.hex) ?
            hex_sel_high(view.hex) - hex_sel_low(view.hex) + 1 : 0;
        string mode  = view.hex.insertMode ? "INS" : "OVR";
        string dirty = (doc.editor && doc.editor.edited()) ? " *" : "";
        char[] status = sformat(statusbuf, "%s%s  offset %08X  selected %u byte(s)",
            mode, dirty, view.hex.cursor, selLen);
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
    case OmniAction.dismiss: view.hex.takeFocus = true;     break;
    }
}

/// What a tab strip asked for this frame, held until every pane has been drawn.
///
/// A close can take a whole pane out of the row, which would leave the loop over
/// `panes` walking an array that has moved under it. So the strips only report,
/// and the one action a frame can carry is applied once the loop is done - still
/// this frame, so nothing the user did is left waiting for the next one.
private struct TabRequest
{
    size_t pane;
    TabAction action;
    int index;
    int target;
}

/// Lay the panes out across the window and draw each one.
///
/// A row of panes, splitters between them, sharing the width by weight. The row
/// takes the whole window below the toolbar bar `statusH` pixels at the bottom,
/// which the status bar then lands in.
private void ui_panes(mu_Context* ctx, int statusH)
{
    size_t n = panes.length;

    // One full-width row for the lot, then every pane and splitter placed inside
    // it by hand: ddui hands an absolute rect straight back without advancing its
    // own layout, which is what lets a column be pinned to a computed rect.
    static immutable int[1] full = [ -1 ];
    mu_layout_row(ctx, 1, full.ptr, -(statusH + ctx.style.spacing + 1));
    mu_Rect row = mu_layout_next(ctx);

    int bars  = cast(int)(n - 1) * SPLIT_WIDTH;
    int avail = mu_max(0, row.w - bars);

    if (paneWeights.length < n) paneWeights.length = n;
    if (paneWidths.length  < n) paneWidths.length  = n;
    foreach (size_t i, Pane* p; panes)
        paneWeights[i] = p.weight;
    split_layout(paneWeights[0 .. n], avail, paneWidths[0 .. n]);

    TabRequest req = { action: TabAction.none };
    int x = row.x;
    foreach (size_t i, Pane* p; panes)
    {
        mu_Rect r = mu_Rect(x, row.y, paneWidths[i], row.h);
        x += r.w;
        p.rect = r; // for the out-of-frame hit test; see Pane.rect

        // Clicking anywhere in a pane is what moves the keyboard to it, so the
        // menus, the omnibar and every chord act on the pane last worked in. The
        // panel inside also takes ddui's own focus from the same press; this is
        // the application's notion of where the user is, alongside it.
        if (ctx.mouse_pressed == MU_MOUSE_LEFT && mu_mouse_over(ctx, r))
            focused = i;

        // Everything this pane draws is scoped under the pane's own identity, so
        // the widgets inside can go on using plain constant names and still come
        // out unique per pane: ddui seeds every id it hashes with the top of the
        // id stack, containers included. That is what keeps two panes from
        // sharing one panel's scroll offset and body rect.
        //
        // It is the pointer's value that is hashed - the bytes at `&p` - and not
        // the array slot it was read from, which moves whenever `panes` grows. A
        // pane is heap allocated and never moves, so the value is stable for as
        // long as the pane is.
        mu_push_id(ctx, &p, (Pane*).sizeof);
        scope(exit) mu_pop_id(ctx);

        mu_layout_set_next(ctx, r, 0);
        mu_layout_begin_column(ctx);
        ui_pane(ctx, *p, i, req);
        mu_layout_end_column(ctx);

        // A splitter between each pair, dragged to trade width across it. The
        // weights are written back through the scratch the layout was built from,
        // so the panes redraw at the new sizes on the very next frame.
        if (i + 1 < n)
        {
            mu_Rect sr = mu_Rect(x, row.y, SPLIT_WIDTH, row.h);
            x += SPLIT_WIDTH;
            int dx = split_bar(ctx, "bar", sr);
            if (dx && split_resize(paneWeights[0 .. n], i, dx, avail, PANE_MIN))
                foreach (size_t j, Pane* q; panes)
                    q.weight = paneWeights[j];
        }
    }

    // A file held over the window picks out the pane it would land in. Drawn
    // after the loop so it washes over the panel rather than under it: a hex
    // panel is a ddui panel, not a root container, so its commands sit inline in
    // this window's list and anything added later paints on top.
    if (dropPane >= 0 && dropPane < panes.length)
    {
        mu_Rect r = panes[dropPane].rect;
        mu_draw_rect(ctx, r, DROP_WASH);
        mu_draw_rect(ctx, mu_Rect(r.x, r.y, r.w, DROP_EDGE_W), DROP_EDGE);
        mu_draw_rect(ctx, mu_Rect(r.x, r.y + r.h - DROP_EDGE_W, r.w, DROP_EDGE_W), DROP_EDGE);
        mu_draw_rect(ctx, mu_Rect(r.x, r.y, DROP_EDGE_W, r.h), DROP_EDGE);
        mu_draw_rect(ctx, mu_Rect(r.x + r.w - DROP_EDGE_W, r.y, DROP_EDGE_W, r.h), DROP_EDGE);
    }

    // Now that the loop is done with `panes`, whatever a strip asked for is safe
    // to carry out, even where it drops the pane that asked.
    switch (req.action)
    {
    case TabAction.select: ui_select_tab_in(req.pane, req.index); break;
    case TabAction.close:  ui_close_tab_in(req.pane, req.index);  break;
    case TabAction.add:    focused = req.pane; ui_new_tab();      break;
    case TabAction.move:   ui_move_tab(req.pane, req.index, req.target); break;
    default:
    }
}

/// Draw one pane: its tab strip, then the hex panel filling what is left of the
/// column it was given.
///
/// One tab per view, named after the document it shows and carrying that
/// document's unsaved-changes dot. Two views of one file are two tabs, both named
/// the same, whether they sit in one pane or in two.
///
/// The item slice is rebuilt every frame (titles and dirty flags both move under
/// us) into storage that only ever grows, so a steady tab count costs no
/// allocation. What the strip reports goes into `req` rather than happening here;
/// see TabRequest.
private void ui_pane(mu_Context* ctx, ref Pane p, size_t index, ref TabRequest req)
{
    if (p.items.length < p.views.length)
        p.items.length = p.views.length;
    foreach (size_t i, View* v; p.views)
        p.items[i] = TabItem(v.doc.title, v.doc.editor && v.doc.editor.edited());

    // Only the pane taking keys lights its accent, so with several panes open it
    // is never a guess which one a keystroke lands in.
    p.tabs.unfocused = index != focused;

    int at, target;
    TabAction action = tab_bar(ctx, "tabs", p.tabs,
        p.items[0 .. p.views.length], cast(int) p.current, at, target);
    if (action != TabAction.none)
        req = TabRequest(index, action, at, target);

    View* v = p.views[p.current];
    v.hex.minimap = minimapOn != 0;

    // The editor's size shifts as inserts and deletes land, so refresh the
    // panel's copy each frame before it draws; the panel keeps it live within a
    // frame, this keeps it authoritative across them - and across panes, where an
    // edit made in one is a size change the other has yet to hear about.
    if (v.doc.editor)
        v.hex.dataSize = v.doc.editor.size();

    // The panel fills the rest of the column, so nothing is reserved below it:
    // the status bar is the window's, not this pane's. The name is a constant
    // because ui_panes has this pane's id pushed: see the scope it sets up there.
    // Check return with `& MU_RES_CHANGE`
    cast(void) hex_view(ctx, "hex", v.hex, render_font_mono(), 0);
}

/// Reorder the tab strip: take the view at `from` and put it at `to`, shifting
/// whatever it passes over the other way. The drag route, so the strip the
/// pointer leaves behind is the order that sticks.
private void ui_move_tab(size_t paneIndex, size_t from, size_t to)
{
    if (paneIndex >= panes.length)
        return;
    Pane* p = panes[paneIndex];
    if (from >= p.views.length || to >= p.views.length || from == to)
        return;

    View* moved = p.views[from];
    if (from < to)
        foreach (i; from .. to)
            p.views[i] = p.views[i + 1];
    else
        foreach_reverse (i; to .. from)
            p.views[i + 1] = p.views[i];
    p.views[to] = moved;

    p.current = tab_reindex(p.current, from, to);
}

/// Where the tab at `at` ends up once the one at `from` is moved to `to`. The
/// moved tab lands on `to` itself; everything between the two shifts one place
/// the other way, and everything outside that span stays where it is.
private size_t tab_reindex(size_t at, size_t from, size_t to)
{
    if (at == from)
        return to;
    if (from < to)
        return at > from && at <= to ? at - 1 : at;
    return at >= to && at < from ? at + 1 : at;
}

unittest
{
    // [A B C D], A to the middle: B and C shuffle down, D is untouched.
    assert(tab_reindex(0, 0, 2) == 2); // the moved tab itself
    assert(tab_reindex(1, 0, 2) == 0);
    assert(tab_reindex(2, 0, 2) == 1);
    assert(tab_reindex(3, 0, 2) == 3);

    // [A B C D], D to index 1: B and C shuffle up, A is untouched.
    assert(tab_reindex(3, 3, 1) == 1);
    assert(tab_reindex(1, 3, 1) == 2);
    assert(tab_reindex(2, 3, 1) == 3);
    assert(tab_reindex(0, 3, 1) == 0);

    // A one-step swap either way, which is what a slow drag actually emits.
    assert(tab_reindex(0, 0, 1) == 1);
    assert(tab_reindex(1, 0, 1) == 0);
    assert(tab_reindex(2, 0, 1) == 2);

    // A move that goes nowhere leaves every index alone.
    foreach (size_t i; 0 .. 4)
        assert(tab_reindex(i, 2, 2) == i);
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
