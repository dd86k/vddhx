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
import elite : elite_frame, elite_animating;
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

private:

/// One open document: the ddhx editor that owns the bytes, and where they live on
/// disk. Nothing here says how they are being looked at - that is a View's
/// business - so one document can be open in several panels at once.
struct Document
{
    /// Owns the bytes and all the piece-table/undo machinery; a panel only ever
    /// reads through it.
    IDocumentEditor editor;

    /// Disk path, empty for an in-memory scratch buffer. Set on Open and on a
    /// first Save As, it is the target an in-place Save writes to.
    string path;

    /// What the tab shows: the file's base name, or "untitled" for a scratch.
    string title;

    /// Bookmarked runs of bytes, sorted. Per document rather than per view, since
    /// an offset only means something against the bytes it points into.
    ///
    /// Edits made through a panel carry them along (see bookmark_shift), but undo
    /// and redo do not: the editor reports only where a change landed, not how far
    /// it moved, so a mark can end up a few bytes off after a rolled-back insert.
    Bookmark[] marks;
}

/// One way of looking at a document: which document, plus everything about the
/// looking - caret, selection, scroll position, entry mode.
///
/// Split from Document so the same file can be open in two panels at different
/// offsets, each with its own caret, the way an editor's windows sit over its
/// buffers. Splitting a pane is what makes a second one.
struct View
{
    /// The document this is a view of. Never null while the view is in a pane.
    Document* doc;

    /// Persisted hex panel state. The caret is active from the outset so it sits
    /// ready on a blank panel, letting a file be built before anything is opened.
    HexView hex = { active: true };

    /// The comparison this view is one side of, null for an ordinary view. Which
    /// side it is - and so whether it carries the colouring - is read off the Diff;
    /// see diff_peer.
    Diff* diff;

    /// The counterpart's bytes, one block at a time. The colour hook is asked about
    /// one byte at a time but in offset order, so reading a block ahead answers a
    /// screenful of them.
    ///
    /// Dropped at the top of every frame the view draws (see ui_pane) rather than
    /// invalidated on edits: the counterpart can be typed into in its own pane,
    /// undone, or reloaded, and none of that passes through here.
    ubyte[] peerBuf;
    /// Ditto, the document offset `peerBuf[0]` holds.
    size_t peerStart;
    /// Ditto, how much of it is valid. Zero means nothing is cached.
    size_t peerLen;

    /// The counterpart's size, read once a frame alongside the block above. What
    /// separates a byte that differs from one the other document does not have.
    long peerSize;

    /// Where this view was scrolled to when it was last drawn, so the next frame
    /// can tell whether the user moved it. Only the side that moved drives the
    /// other; see ui_sync_diffs.
    long topSeen;

    /// Whether that position was put there by the counterpart rather than the user.
    /// What tells a scroll the panel could not honour in full - the shorter of two
    /// files, stopped at its last screenful - from the user scrolling this side,
    /// which look identical from outside and would have the two panes dragging each
    /// other back and forth.
    bool topForced;
}

/// Two views held against each other and compared byte for byte.
///
/// The pairing is between views rather than documents: it is the two tabs the user
/// put side by side, so one file can be compared against two others at once and
/// each pairing scrolls as its own unit. A view is in at most one comparison, and
/// both sides point at the same Diff.
///
/// The two sides are not alike, hence the names. The comparison is something done
/// *to* a document the user already had open: that one goes on looking exactly as
/// it did, and the file opened against it is the one that reports. So only
/// `against` is tinted and only `against` reads the other's bytes at all.
///
/// Strictly offset-aligned - byte n against byte n - which is the honest reading
/// for firmware images and same-size structures, and visibly wrong the moment one
/// side has an insertion. Aligning on content instead would need rows standing for
/// no offset at all, but a hex panel row *is* its offset (`row * columns`), so the
/// display would part company with the offsets the caret, the bookmarks and every
/// edit are addressed in. That is a feature of its own, not a tweak to this one.
struct Diff
{
    /// The view the comparison was started from: the document the user was
    /// already working in, left in its ordinary colours.
    View* base;

    /// The view opened against it, which carries the colouring. Never the same
    /// view as `base`.
    View* against;
}

/// The other side of `v`'s comparison, or null when it is not in one.
View* diff_peer(View* v)
{
    if (v is null || v.diff is null)
        return null;
    return v.diff.base is v ? v.diff.against : v.diff.base;
}

/// Whether `v` is the side that reports: the one drawn against the other, and so
/// the only one that dims its matching bytes and colours its differing ones.
bool diff_reports(View* v)
{
    return v.diff && v.diff.against is v;
}

/// One pane: a strip of tabs over a hex panel, filling its share of the window.
/// Where it sits is the grid's business, not its own; see Column.
struct Pane
{
    /// The views this pane has tabs for, in strip order. Never empty while the
    /// pane is in the grid: a pane that loses its last tab is closed with it.
    View*[] views;

    /// Index into `views` of the one on screen.
    size_t current;

    /// The strip's own scroll offset and in-progress drag.
    TabBar tabs;

    /// Item slice handed to the strip, rebuilt each frame into storage that only
    /// ever grows, so a steady tab count costs no allocation.
    TabItem[] items;

    /// Share of its column's height this pane takes, against the panes stacked
    /// with it. Relative, so a window resize needs no arithmetic here: the same
    /// weights simply divide a different number of pixels.
    int weight = SPLIT_WEIGHT;

    /// Where this pane was last drawn, recorded by ui_panes so a hit test can be
    /// made from outside a frame: a file dragged over the window arrives as an SDL
    /// event carrying a window coordinate and nothing else.
    mu_Rect rect;
}

/// One column of the grid: panes stacked top to bottom over a shared width.
///
/// The grid is two levels deep and no more - a row of columns across the window, a
/// stack of panes down each - rather than a tree. That covers the splits an editor
/// actually offers and keeps the layout to two passes of the same flat arithmetic
/// (see split.d), with no interior node that can be left holding one child.
struct Column
{
    /// The panes in it, top to bottom. Never empty while the column is in
    /// `columns`: a column that loses its last pane is closed with it.
    Pane*[] panes;

    /// Share of the window's width this column takes, against its neighbours'.
    int weight = SPLIT_WEIGHT;

    /// Where the column was last drawn, the same way a pane records its own rect.
    /// A sideways split reaches around a whole column rather than into it, so this
    /// is the shape that has to be shown to somebody about to make one.
    mu_Rect rect;
}

/// Every open document, every view onto one, and every column of panes.
///
/// All held by pointer: the panel's callbacks park a Document* and a View* for ddui
/// to hand back on every read, colour and edit, and those have to survive a
/// document being closed out of the middle of the array. A pane is named by its
/// pointer everywhere below for the same reason, so that splitting or closing
/// elsewhere cannot turn a reference to one pane into a reference to another.
///
/// None is ever empty: startup opens a scratch buffer, closing the last tab of the
/// last pane leaves a fresh one behind, and a pane that empties is closed unless it
/// is the only one.
__gshared Document*[] docs;
/// Ditto.
__gshared Column*[] columns;

/// The pane taking the keyboard. Every action below acts on its front tab. Never
/// null once ui_init has run, and always a pane still in `columns`.
__gshared Pane* focused;

/// Scratch for laying a line of panes out: the weights copied out of the grid and
/// the pixel sizes they come to. One pair for the row of columns, one reused
/// column by column for the panes down each. All only ever grow.
__gshared int[] colWeights;
/// Ditto.
__gshared int[] colSizes;
/// Ditto.
__gshared int[] paneWeights;
/// Ditto.
__gshared int[] paneSizes;

/// Narrowest a pane may be dragged, in pixels: enough that the offset column and a
/// few bytes stay legible.
enum int PANE_MIN = 180;

/// Shortest a pane may be dragged, in pixels: enough for its tab strip and a row
/// or two of bytes, so it stays recognisably a pane rather than a stray strip.
enum int PANE_MIN_H = 120;

/// Scratch buffers are numbered in creation order: "untitled", "untitled 2"...
__gshared uint untitled;

/// Omnibar state, and the candidate rows handed to it. Like the tab strip's, the
/// row storage is rebuilt each frame into an array that only ever grows.
__gshared Omnibar omni;
/// Ditto.
__gshared OmniItem[] omniItems;

/// Whether the box was up at the end of the last frame, so ui_frame can spot the
/// frame it goes up on and take the menubar's dropdown down with it.
__gshared bool omniWasShown;

/// The pane and tab each switcher row stands for, parallel to `omniItems` while
/// the switcher is the mode showing. A row's id indexes this.
struct OmniTab
{
    Pane* pane;
    size_t tab;
}
/// Ditto.
__gshared OmniTab[] omniTabs;

/// The pane taking the keyboard, the view it has in front, and the document that
/// view is showing: `pane` for the tabs, `view` for the caret and what is on
/// screen, `doc` for the bytes themselves.
ref Pane pane()
{
    return *focused;
}
/// Ditto.
ref View view()
{
    return *focused.views[focused.current];
}
/// Ditto.
ref Document doc()
{
    return *view().doc;
}

/// Find `p` in the grid: which column it is in, and how far down that column.
///
/// The one place the grid is searched by pointer, so nothing else has to carry
/// indices about.
/// Returns: True when the pane is in the grid, with `ci` and `pi` filled in.
bool ui_locate(const(Pane)* p, out size_t ci, out size_t pi)
{
    foreach (size_t i, Column* c; columns)
    {
        foreach (size_t j, Pane* q; c.panes)
        {
            if (q is p)
            {
                ci = i;
                pi = j;
                return true;
            }
        }
    }
    return false;
}

/// Panes in the whole grid, counted across every column.
size_t ui_pane_count()
{
    size_t n;
    foreach (Column* c; columns)
        n += c.panes.length;
    return n;
}

/// The `n`th pane in reading order - columns left to right, panes top to bottom
/// within each - or null when there are not that many. This is the order Ctrl+1..9
/// and the next/previous pane commands count in.
Pane* ui_pane_nth(size_t n)
{
    foreach (Column* c; columns)
    {
        if (n < c.panes.length)
            return c.panes[n];
        n -= c.panes.length;
    }
    return null;
}

/// Ditto, the other way: where `p` falls in that order, or -1 when it is not in
/// the grid at all.
ptrdiff_t ui_pane_index(const(Pane)* p)
{
    ptrdiff_t at;
    foreach (Column* c; columns)
    {
        foreach (Pane* q; c.panes)
        {
            if (q is p)
                return at;
            ++at;
        }
    }
    return -1;
}

/// The main window, for parenting the native Open dialog. main sets it up front.
__gshared SDL_Window* uiWindow;

/// Colour behind the hex grid. Dark on purpose: the byte colours - the dimmed
/// padding zeros above all - are picked to read against something near black,
/// and lose most of their contrast on a mid grey.
enum mu_Color CANVAS = mu_Color(0, 0, 0, 255);

/// Wash behind a bookmarked byte in the grid. Amber, nothing hex_classify hands
/// out being near it, so a mark reads as a mark rather than as one more class of
/// byte, and a wash rather than a foreground so a marked run comes out as a band
/// the eye catches.
///
/// Kept this dark for BOOKMARK_TEXT's sake: the obvious bright amber leaves white
/// sitting on it at under 2:1, where at this depth white lands around 6.6:1.
///
/// This is the one bookmark colour the panel is told; where the amber has to come
/// back at full strength - a run's outline, a minimap cell - the panel lifts it
/// there itself. See hex_wash_lift.
enum mu_Color BOOKMARK_WASH = mu_Color(125, 85, 22, 255);

/// Colour a bookmarked byte's glyphs are drawn in, over BOOKMARK_WASH: the one
/// place a mark overrules hex_classify. Inside a run the user marked by hand,
/// standing out is worth more than what class the byte falls in.
enum mu_Color BOOKMARK_TEXT = mu_Color(255, 255, 255, 255);

/// A byte that differs from the one at the same offset in the document it is
/// being compared against.
enum mu_Color DIFF_CHANGED = mu_Color(255, 95, 95, 255);

/// A byte past the end of that document: here, but with nothing to compare it
/// against. Green, so a file that is simply longer than the other reads as a tail
/// of additions rather than as a wall of changes.
enum mu_Color DIFF_ADDED = mu_Color(120, 230, 140, 255);

/// How much of its brightness a matching byte keeps while a comparison is up, in
/// percent.
///
/// Dimming rather than flattening the matches to one grey, the way a diff over
/// *text* does: hex_classify's colouring is how the structure of a binary is read
/// at all, and dropping it would leave the untouched 99% of a patched file
/// unreadable.
enum int DIFF_MATCH_KEEP = 42;

/// Ditto: `c` at DIFF_MATCH_KEEP percent, alpha untouched.
mu_Color diff_dim(mu_Color c)
{
    return mu_Color(
        cast(ubyte)(c.r * DIFF_MATCH_KEEP / 100),
        cast(ubyte)(c.g * DIFF_MATCH_KEEP / 100),
        cast(ubyte)(c.b * DIFF_MATCH_KEEP / 100),
        c.a);
}

/// Apply the application's own style over ddui's defaults. Call once after
/// mu_init, before the first frame.
///
/// ddui leaves MU_COLOR_PANELBG fully transparent, so the hex panel would take the
/// window's grey; now that the renderer honours alpha, the canvas has to be asked
/// for outright.
public void ui_style(mu_Context* ctx)
{
    ctx.style.colors[MU_COLOR_PANELBG] = CANVAS;
}

/// Last thing the application had to say, shown at the right of the status bar
/// until something replaces it: a find that came up empty, a bookmark set, a
/// copied inspector reading - keystrokes whose result would otherwise be invisible.
__gshared char[96] statusText;
/// Ditto.
__gshared size_t statusLen;

/// Ditto. Formatted into a fixed buffer, so keep the message short; anything
/// that does not fit is dropped rather than half-shown.
void ui_status(Args...)(string fmt, Args args)
{
    try
        statusLen = sformat(statusText, fmt, args).length;
    catch (Exception e)
        statusLen = 0;
}

/// Minimap toolbar toggle (int for mu_checkbox); pushed onto hex.minimap.
__gshared int minimapOn = 1;

/// Path the async Open dialog picked, waiting for the next frame to consume it.
/// Written by the dialog callback (possibly off-thread), read on the main thread,
/// so the ready flag is atomic and orders the buffer write against the read.
__gshared char[4096] pendingPath;
shared bool pendingReady;

/// Whether that path was asked for by "Compare With..." rather than by Open, and
/// the view it is to be compared against.
///
/// Only the main thread touches these, the dialog callback knowing nothing about
/// what raised it. The view is checked against the grid before use: the dialog is
/// not modal, so its tab can be closed while it is up.
__gshared bool pendingCompare;
/// Ditto.
__gshared View* compareFrom;

/// Ditto, for the async Save As dialog. The callback does no GC work, so the
/// chosen path is stashed here and the actual write happens on the main thread.
__gshared char[4096] pendingSavePath;
shared bool pendingSaveReady;

/// The editor the open Save As dialog was raised for. Tabs can be switched while a
/// non-modal dialog is up, so the destination is matched back to the document that
/// asked rather than to whatever is in front when it returns - saving one file's
/// bytes under another's name would lose both.
__gshared IDocumentEditor pendingSaveTarget;

/// Hand the UI the window handle before the first frame. Also opens the first
/// tab, an empty editable scratch buffer, so a file can be built from scratch
/// before anything is ever opened.
public void ui_init(SDL_Window* window)
{
    uiWindow = window;
    ui_new_tab();
}

/// Open a fresh scratch document in a new tab and bring it to the front: a
/// zero-length in-memory buffer, editable from the outset, which gets a name the
/// first time it is saved.
public void ui_new_tab()
{
    ++untitled;

    Document* d = new Document;
    d.editor = spawnEditor(); // no document: a zero-length, in-memory buffer
    d.title  = untitled == 1 ? "untitled" : format("untitled %u", untitled);
    docs ~= d;

    View* v = new View;
    v.doc = d;
    wireView(v);

    // The very first tab has no pane to go in yet, ui_init opening it before
    // anything has laid the window out.
    if (columns.length == 0)
    {
        Column* c = new Column;
        c.panes ~= newPane();
        columns ~= c;
        focused = c.panes[0];
    }

    Pane* p = focused;
    p.views ~= v; // .length updated
    p.current = p.views.length - 1; // @suppress(dscanner.suspicious.length_subtraction)
    v.hex.takeFocus = true; // ready to take bytes without a click first
}

/// A fresh pane with no tabs in it. Callers fill in `views` before the next frame.
Pane* newPane()
{
    Pane* p = new Pane;

    // The strip caps this pane's own canvas, so the active tab takes the grid's
    // colour rather than the window's. ui_style cannot do it: panes come and go
    // long after it has run.
    p.tabs.content = CANVAS;
    return p;
}

/// Bring the tab at `index` to the front of the focused pane. Out-of-range
/// indices are ignored, so a stale index from a strip built before a close
/// cannot strand the panel.
public void ui_select_tab(size_t index)
{
    ui_select_tab_in(focused, index);
}

/// Ditto, in a given pane - which also becomes the focused one, since bringing a
/// tab forward is asking to work in it.
void ui_select_tab_in(Pane* p, size_t index)
{
    if (p is null || index >= p.views.length)
        return;
    focused = p;
    p.current = index;
    p.views[index].hex.takeFocus = true; // typing follows the tab that came forward
}

/// Step `delta` tabs along from the current one, wrapping at either end.
public void ui_cycle_tab(int delta)
{
    Pane* p = focused;
    if (p.views.length <= 1)
        return;

    long count = cast(long) p.views.length;
    long at = (cast(long) p.current + delta) % count;
    if (at < 0)
        at += count;
    ui_select_tab(cast(size_t) at);
}

/// Close the tab at `index`, resolving unsaved edits first (the document is
/// brought to the front for the prompt, and a cancel leaves it open).
///
/// It is the view that closes. The document behind it only goes when nothing else
/// is looking at it, so closing one half of a split leaves the file open in the
/// other half - and has nothing to prompt about.
public void ui_close_tab(size_t index)
{
    ui_close_tab_in(focused, index);
}

/// Ditto, in a given pane, held by pointer: the prompt below can bring another
/// pane forward and a Save As raised from it can run a frame's worth of work, so
/// this has to stay the pane that was asked about.
void ui_close_tab_in(Pane* p, size_t index)
{
    if (p is null || index >= p.views.length)
        return;

    Document* d = p.views[index].doc;
    bool last = ui_view_count(d) <= 1;
    if (last && ui_confirm_discard(d, "Close document") != Confirm.proceed)
        return;

    // Any comparison the tab was one side of is over. After the prompt, which can
    // still be cancelled and leave everything as it was.
    diff_unlink(p.views[index]);

    // The view is not wanted back: this is the one route where a tab leaves a pane
    // for nowhere rather than for another pane.
    cast(void) ui_take_view(p, index);
    if (last)
        ui_drop_document(d);

    if (p.views.length == 0)
    {
        // An empty pane goes and the grid closes over it - unless it is the last
        // one, in which case the window itself is what is being shut.
        if (ui_pane_count() > 1)
        {
            ui_drop_pane(p);
            return;
        }

        // Out of tabs in the last pane: quit through SDL's own queue, so it meets
        // the same route as the window close button. That lands next frame and the
        // rest of this one still has a panel to draw, hence the scratch buffer -
        // which has no edits, so it cannot hold the quit up.
        ui_new_tab();
        SDL_Event quit; // .init zeroes the union
        quit.type = SDL_EVENT_QUIT;
        SDL_PushEvent(&quit);
        return;
    }

    p.views[p.current].hex.takeFocus = true; // ready to type in
}

/// How many views, in any pane, are currently showing `d`. Closing the last of
/// them is what closes the document itself.
size_t ui_view_count(const(Document)* d)
{
    size_t n;
    foreach (Column* c; columns)
        foreach (Pane* p; c.panes)
            foreach (View* v; p.views)
                if (v.doc is d)
                    ++n;
    return n;
}

/// Close `d`'s editor and drop it from `docs`. Only for a document no view is
/// left showing: every View.doc still held by a pane has to stay valid.
void ui_drop_document(Document* d)
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
void ui_focus_document(const(Document)* d)
{
    foreach (Column* c; columns)
    {
        foreach (Pane* p; c.panes)
        {
            foreach (size_t j, View* v; p.views)
            {
                if (v.doc is d)
                {
                    ui_select_tab_in(p, j);
                    return;
                }
            }
        }
    }
}

/// Drop `p` from the grid, handing its share of the space to a neighbour so the
/// panes still fill the window between them. Its views go with it, so the caller
/// closes those first (ui_close_tab_in does).
///
/// The neighbour is the one before it in the same column, or the one after when the
/// pane closing is at the top, so the column's total weight is unchanged and
/// nothing outside it moves. A pane on its own takes the column with it, and the
/// same rule then applies one level up.
void ui_drop_pane(Pane* p)
{
    size_t ci, pi;
    if (ui_locate(p, ci, pi) == false || ui_pane_count() <= 1)
        return;

    Column* c = columns[ci];
    Pane* heir;

    if (c.panes.length > 1)
    {
        // Read the neighbour out before the removal shifts the indices under it:
        // it is the pane itself that has to be remembered, not where it sat.
        heir = c.panes[pi > 0 ? pi - 1 : pi + 1];
        heir.weight += p.weight;
        c.panes = c.panes[0 .. pi] ~ c.panes[pi + 1 .. $];
    }
    else
    {
        Column* into = columns[ci > 0 ? ci - 1 : ci + 1];
        into.weight += c.weight;
        columns = columns[0 .. ci] ~ columns[ci + 1 .. $];
        heir = into.panes[0];
    }

    // Only the pane that just went can have been the one taking keys, and the
    // neighbour that took its space is the natural place for them to land.
    if (focused is p)
    {
        focused = heir;
        focused.views[focused.current].hex.takeFocus = true;
    }
}

/// A second view of whatever the focused pane has in front: the same document at
/// the same offset, ready to go in a pane of its own.
///
/// The same document rather than a copy - one editor, one undo history, one set of
/// bookmarks - so an edit made in either pane shows up in both. What they do not
/// share is the looking: the new view carries the old one's caret and scroll
/// position as a starting point and then moves on its own.
View* ui_split_view()
{
    View* src = pane.views[pane.current];

    View* v = new View;
    v.doc = src.doc;
    v.hex = hex_split(src.hex); // its own scratch buffers, the same place in the file
    wireView(v);                // and its own hooks, pointing at itself
    v.hex.takeFocus = true;
    return v;
}

/// Pair `base` and `against` up as the two sides of a comparison: `base` is the
/// document already open, `against` the one opened to compare with it and the
/// only one of the two that shows it (see Diff).
///
/// Either view already comparing something is taken out of that pairing first: a
/// view has one counterpart, because it has one set of colours to say so with.
/// Comparing a view with itself is not a comparison and is refused.
void diff_link(View* a, View* b)
{
    if (a is null || b is null || a is b)
        return;

    diff_unlink(a);
    diff_unlink(b);

    Diff* d = new Diff;
    d.base    = a;
    d.against = b;
    a.diff = d;
    b.diff = d;

    // The next frame each draws fills in the cached block and the peer size; the
    // scroll comes across now so the pairing opens lined up rather than a frame
    // later.
    hex_set_top_offset(b.hex, hex_top_offset(a.hex));
    a.topSeen  = hex_top_offset(a.hex);
    b.topSeen  = a.topSeen;
    b.topForced = true; // and if b is the shorter, its clamp is not a lead
}

/// Take `v` out of whatever comparison it is in, and the other side with it: a
/// comparison with one side left is not one. Safe on a view that is not in one.
///
/// Called wherever a view stops being what it was - closed, or handed a different
/// document - since the colours would otherwise go on claiming a counterpart that
/// is gone or no longer the one being compared.
void diff_unlink(View* v)
{
    if (v is null || v.diff is null)
        return;

    Diff* d = v.diff;
    foreach (View* side; [ d.base, d.against ])
    {
        if (side is null)
            continue;
        side.diff    = null;
        side.peerLen = 0; // nothing to compare against; drop the stale block
    }
}

/// Split the focused pane in two side by side: a second pane opens to the right
/// of its column, in a new column of its own, and takes the keyboard.
public void ui_split()
{
    ui_split_pane(ui_split_view());
}

/// Ditto, with the view the new pane opens on given: a second look at the same
/// document for a plain split, the file being compared against for a comparison.
void ui_split_pane(View* v)
{
    size_t ci, pi;
    if (ui_locate(focused, ci, pi) == false)
        return;

    Pane* p = newPane();
    p.views ~= v;

    // A column of one, taking half the width of the column it came out of, so the
    // rest of the window is left as it was. Splitting a column with panes stacked
    // in it puts the new column alongside the whole stack rather than reaching into
    // it, which is what keeps the grid two deep.
    Column* c = new Column;
    c.panes ~= p;
    c.weight = columns[ci].weight / 2;
    columns[ci].weight -= c.weight;

    columns = columns[0 .. ci + 1] ~ c ~ columns[ci + 1 .. $];
    focused = p;
}

/// Split the focused pane in two, one above the other: a second pane opens
/// directly below it in the same column, and takes the keyboard.
///
/// The column keeps its width, so the split is felt only within it and the panes
/// either side stay where they are.
public void ui_split_down()
{
    size_t ci, pi;
    if (ui_locate(focused, ci, pi) == false)
        return;

    Pane* p = newPane();
    p.views ~= ui_split_view();

    Column* c = columns[ci];
    p.weight = c.panes[pi].weight / 2;
    c.panes[pi].weight -= p.weight;

    c.panes = c.panes[0 .. pi + 1] ~ p ~ c.panes[pi + 1 .. $];
    focused = p;
}

/// Close the focused pane, tab by tab, so each document still gets its say about
/// unsaved changes. A cancelled prompt stops the whole thing where it stands.
/// The last pane cannot be closed: there would be nothing left to draw.
public void ui_close_pane()
{
    if (ui_pane_count() <= 1)
    {
        ui_status("the last pane cannot be closed");
        return;
    }

    Pane* p = focused;
    for (;;)
    {
        // Looked up again each round: the last tab closing takes this pane out of
        // the grid altogether, which is the loop's way out.
        size_t ci, pi;
        if (ui_locate(p, ci, pi) == false)
            return; // gone, which is what was asked for

        size_t before = p.views.length;
        ui_close_tab_in(p, p.current);
        if (p.views.length == before) // a prompt was cancelled: leave it open
            return;
    }
}

/// Move the keyboard to the pane at `index`, counted in the order ui_pane_nth lays
/// out. Out of range does nothing, so Ctrl+9 on a two-pane window is ignored.
public void ui_focus_pane(size_t index)
{
    Pane* p = ui_pane_nth(index);
    if (p is null)
        return;
    focused = p;
    p.views[p.current].hex.takeFocus = true;
}

/// Step `delta` panes along from the focused one, wrapping at either end.
public void ui_cycle_pane(int delta)
{
    long count = cast(long) ui_pane_count();
    if (count <= 1)
        return;

    long at = (ui_pane_index(focused) + delta) % count;
    if (at < 0)
        at += count;
    ui_focus_pane(cast(size_t) at);
}

/// Close the tab on screen. The Ctrl+W and File > Close Tab route.
public void ui_close_current_tab()
{
    ui_close_tab(pane.current);
}

/// The title text last handed to SDL, NUL-terminated, and its length. Kept so
/// the per-frame refresh can tell when nothing has changed and skip the call.
__gshared char[512] titleShown;
__gshared size_t titleShownLen;

/// Keep the window title naming the document in front, with a marker while it has
/// unsaved edits. Called every frame, so the text is composed into a stack buffer
/// and compared: a steady document costs a memcmp rather than a round trip to the
/// window manager.
void ui_window_title()
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

/// `s` cut back to at most `max` bytes, on a UTF-8 boundary so it never ends in
/// half a character (which the renderer draws as a replacement glyph, or refuses
/// outright). Bytes rather than characters, since what runs out is a fixed buffer.
string ui_clip(string s, size_t max)
{
    if (s.length <= max)
        return s;

    size_t cut = max;
    while (cut > 0 && (s[cut] & 0xc0) == 0x80) // the cut landed mid-character
        --cut;
    return s[0 .. cut];
}

unittest
{
    assert(ui_clip("short", 32) == "short");
    assert(ui_clip("exactly8", 8) == "exactly8");
    assert(ui_clip("truncate me", 8) == "truncate");

    // A cut landing inside the two-byte "é" takes the whole character out.
    assert(ui_clip("abécd", 3) == "ab");
    assert(ui_clip("abécd", 4) == "abé");
    assert(ui_clip("é", 1) == "");
}

/// Compose "name * - vddhx" into `buf`, which must have room for the fixed parts,
/// and return the slice written. A name too long for it is cut back.
char[] ui_title_text(char[] buf, string name, bool dirty)
{
    enum string DIRTY  = " *";
    enum string SUFFIX = " - vddhx";
    assert(buf.length > DIRTY.length + SUFFIX.length);

    name = ui_clip(name, buf.length - DIRTY.length - SUFFIX.length);

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
extern (C) void ui_on_file_picked(void* user, const(char*)* fileList, int filter) nothrow
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

/// Nudge the event loop into drawing a frame. It sleeps between events, so a change
/// made from anywhere but an event - the dialog callbacks, which SDL answers on its
/// own thread - would sit unseen until the next keystroke. Pushing to SDL's queue
/// is safe from any thread, and the loop ignores the event itself.
void ui_wakeup() nothrow
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
ubyte[] hexRead(long pos, ubyte[] buf, void* user)
{
    IDocumentEditor ed = cast(IDocumentEditor) user;
    return ed.view(pos, buf);
}

/// ddui-side colour scheme: every byte classified the way the panel would have
/// anyway, dimmed or called out where a comparison is up. `user` is the View in
/// hex.colorUser, the comparison belonging to the bytes being drawn rather than to
/// whichever document happens to be in front.
///
/// A mark takes the byte white, outranking the comparison: a marked run is the one
/// thing on screen the user put there by hand. Nothing is lost either way, a
/// differing byte inside a run keeping the wash hexBack puts behind it.
///
/// Only the reporting side of a comparison is coloured by it; see Diff.
mu_Color hexColor(size_t offset, ubyte value, void* user)
{
    View* v = cast(View*) user;
    if (v is null)
        return hex_classify(offset, value, null);

    if (bookmark_has(v.doc.marks, cast(long) offset))
        return BOOKMARK_TEXT;

    if (diff_reports(v))
    {
        if (cast(long) offset >= v.peerSize)
            return DIFF_ADDED;

        // A byte the counterpart cannot produce - a read come up short on a file
        // being written from under us - is not a difference anyone can act on.
        ubyte other;
        if (diff_peer_byte(v, offset, other) && other != value)
            return DIFF_CHANGED;
        return diff_dim(hex_classify(offset, value, null));
    }

    return hex_classify(offset, value, null);
}

/// Background hook for the grid: a wash behind the bookmarked bytes, nothing behind
/// the rest. `user` is the View in hex.backUser, for the same reason hexColor takes
/// one. The panel puts the selection over whatever comes back, so a mark under it
/// is hidden until the caret moves off - the selection being where the user is now.
mu_Color hexBack(size_t offset, ubyte value, void* user)
{
    View* v = cast(View*) user;
    if (v is null)
        return mu_Color(0, 0, 0, 0);

    return bookmark_has(v.doc.marks, cast(long) offset)
        ? BOOKMARK_WASH : mu_Color(0, 0, 0, 0);
}

/// Ditto asked of a whole segment at a time: whether any byte in it is marked.
/// bookmark_hits answers off the run list, so a mark of a few bytes shows on the
/// ribbon of a document far too large to have been sampled closely enough to find
/// it.
///
/// Answers in the same colour hexBack does, deliberately: the panel probes this one
/// byte at a time as well, to place a run's outline, and two bytes of one mark have
/// to come back matching or every cell is drawn boxed in on its own.
mu_Color hexBackSpan(long at, long length, void* user)
{
    View* v = cast(View*) user;
    if (v is null)
        return mu_Color(0, 0, 0, 0);

    return bookmark_hits(v.doc.marks, at, length)
        ? BOOKMARK_WASH : mu_Color(0, 0, 0, 0);
}

/// The counterpart's byte at `offset`, through the view's one-block cache, so
/// walking a screenful in order costs a read or two of the other document rather
/// than one per byte. See View.peerBuf for why it is dropped every frame.
/// Returns: False when the counterpart has no byte there to compare against.
bool diff_peer_byte(View* v, size_t offset, out ubyte value)
{
    if (v.peerLen == 0 || offset < v.peerStart || offset - v.peerStart >= v.peerLen)
    {
        IDocumentEditor ed = diff_peer(v).doc.editor;
        if (ed is null)
            return false;

        if (v.peerBuf.length < DIFF_BLOCK)
            v.peerBuf.length = DIFF_BLOCK;

        // Aligned down, so a screen crossing a boundary settles into the next block
        // rather than re-reading from wherever the last byte landed.
        size_t start = offset - (offset % DIFF_BLOCK);
        ubyte[] got = ed.view(cast(long) start, v.peerBuf);
        v.peerStart = start;
        v.peerLen   = got.length;

        if (offset - start >= v.peerLen)
            return false;
    }

    value = v.peerBuf[offset - v.peerStart];
    return true;
}

/// How much of the counterpart is pulled in at a time. A screenful of bytes is a
/// couple of thousand at most, so one block covers a frame with room to spare.
enum size_t DIFF_BLOCK = 8 * 1024;

/// ddui-side write hooks: forward the panel's single-byte edits to the editor,
/// which holds them in its piece table, so these work even on a file opened
/// read-only. A rejected edit throws; swallow it with a log rather than unwinding
/// the frame.
///
/// `user` is the View that owns the panel, from hex.writeUser, which is what says
/// whose bytes are being edited - not necessarily the document in front, once
/// panels can sit side by side.
void hexReplace(long pos, ubyte value, void* user)
{
    View* v = cast(View*) user;
    try
        v.doc.editor.replace(pos, &value, 1);
    catch (Exception e)
        logWarn("replace failed: %s", e.msg);
}
/// Ditto.
void hexInsert(long pos, ubyte value, void* user)
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
void hexRemove(long pos, long len, void* user)
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
/// jump either way, so the panel's copy is refreshed before returning - the copy
/// belonging to the view that took the keystroke, which `user` names. Any other
/// view of the document picks the new size up from ui_frame next frame.
long hexUndo(void* user)
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
long hexRedo(void* user)
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
/// plus the size the panel starts from. Called on every new view and whenever one
/// is pointed at a different document.
///
/// By pointer, because that pointer is what the hooks above are handed back on
/// every call, long after this returns.
void wireView(View* v)
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
    v.hex.colorUser = cast(void*) v; // the view, not the document: it holds the
                                     // comparison as well as the way to the marks
    v.hex.backFn     = &hexBack;
    v.hex.backSpanFn = &hexBackSpan;
    v.hex.backUser   = cast(void*) v;
    v.hex.data      = null;
    v.hex.dataSize  = ed ? ed.size() : 0;
}

/// The pane a file is currently being dragged over, or null for none. Only ever
/// set while a drag is in flight over the window; see ui_drop_hover.
__gshared Pane* dropPane;

/// Colour a pane is picked out in while a file is held over it.
enum mu_Color DROP_EDGE = mu_Color(110, 170, 255, 255);
/// Ditto, the wash over the pane itself, translucent so the bytes read through.
enum mu_Color DROP_WASH = mu_Color(110, 170, 255, 40);
/// Thickness of the edge, in pixels.
enum int DROP_EDGE_W = 2;

/// The pane at a window coordinate, or null when the point is not in one (the
/// menubar, the status bar, a splitter between two panes).
Pane* ui_pane_at(int x, int y)
{
    foreach (Column* c; columns)
    {
        foreach (Pane* p; c.panes)
        {
            mu_Rect r = p.rect;
            if (x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h)
                return p;
        }
    }
    return null;
}

/// The pane a tab being dragged is over and what letting go there would do: join
/// that pane, or split it on one of its four sides. Null when the pointer is over
/// no pane at all, which is a drop that does nothing.
Pane* ui_drop_target(mu_Context* ctx, out SplitZone zone)
{
    Pane* onto = ui_pane_at(ctx.mouse_pos.x, ctx.mouse_pos.y);
    zone = onto ? split_zone(onto.rect, tab_bar_height(ctx), ctx.mouse_pos)
                : SplitZone.centre;
    return onto;
}

/// The shape a drop on `p` would fill, for showing where it lands before the user
/// commits: the pane itself for a drop that joins it, half of it for one that
/// splits it, and half the column when a sideways split reaches around a whole
/// stack - which is what ui_split_into does with it.
mu_Rect ui_drop_rect(Pane* p, SplitZone zone)
{
    mu_Rect r = p.rect;
    if (zone == SplitZone.left || zone == SplitZone.right)
    {
        size_t ci, pi;
        if (ui_locate(p, ci, pi) && columns[ci].panes.length > 1)
            r = columns[ci].rect;
    }
    return split_zone_rect(r, zone);
}

/// A file is being dragged over the window: mark the pane under the pointer so
/// the user can see where it would land before letting go. Called for every
/// position report SDL sends while the drag is in flight.
public void ui_drop_hover(int x, int y)
{
    dropPane = ui_pane_at(x, y);
}

/// The drag is over, dropped or not: stop marking anything.
public void ui_drop_clear()
{
    dropPane = null;
}

/// Open a dropped file in the pane it was dropped on rather than the one with the
/// keyboard, dropping being a pointing gesture; that pane takes the focus with the
/// file. A drop that misses every pane falls back to the focused one.
public void ui_drop_file(string path, int x, int y)
{
    Pane* at = ui_pane_at(x, y);
    if (at)
        focused = at;
    ui_drop_clear();
    ui_open(path);
}

/// Put up the native Open dialog. It runs async: ui_on_file_picked stashes the
/// chosen path and the next frame opens it. Null filters means "all files", and
/// the trailing false keeps it single-select.
public void ui_open_dialog()
{
    SDL_ShowOpenFileDialog(&ui_on_file_picked, null, uiWindow, null, 0, null, false);
}

/// Put up the Open dialog to pick a file to compare the front tab against. The
/// path comes back the same way an Open's does; pendingCompare is what tells the
/// two apart when it lands.
public void ui_compare_dialog()
{
    pendingCompare = true;
    compareFrom    = pane.views[pane.current];
    SDL_ShowOpenFileDialog(&ui_on_file_picked, null, uiWindow, null, 0, null, false);
}

/// Open `path` beside the tab the comparison was started from and pair the two
/// up, byte for byte.
///
/// The file gets a pane of its own to the right rather than a tab in the pane it is
/// being compared with, the whole point being to see both at once. The pane is only
/// made once the bytes are known to be there.
///
/// Public because it is the whole action with the dialog taken off the front: what
/// the scripted driver calls, and what a command line naming two files would reach
/// for.
public void ui_compare_with(string path)
{
    // The dialog is not modal, so the tab this was started from may have been
    // closed or dragged elsewhere meanwhile; the front tab of the focused pane is
    // the honest fallback.
    View* left = compareFrom;
    compareFrom = null;
    if (left is null || ui_view_pane(left) is null)
        left = pane.views[pane.current];

    Document* d = ui_load(path);
    if (d is null)
        return;

    View* right = new View;
    right.doc = d;
    wireView(right);
    right.hex.active = true;

    // Beside the pane holding the left side, which is not necessarily the focused
    // one once the dialog has been up and the user has clicked elsewhere.
    focused = ui_view_pane(left);
    ui_split_pane(right);
    diff_link(left, right);

    ui_status("comparing %s with %s", left.doc.title, right.doc.title);
    logInfo("comparing %s with %s", left.doc.title, path);
}

/// End the comparison the front tab is part of, on both sides. Does nothing when
/// it is not in one.
public void ui_compare_stop()
{
    View* v = pane.views[pane.current];
    if (v.diff is null)
    {
        ui_status("not comparing");
        return;
    }

    ui_status("comparison ended");
    diff_unlink(v);
}

/// The pane `v` is a tab of, or null when it is not in the grid at all (a view
/// closed while a dialog was up). The check that a View* held across frames is
/// still a view of something.
Pane* ui_view_pane(const(View)* v)
{
    foreach (Column* c; columns)
        foreach (Pane* p; c.panes)
            foreach (View* q; p.views)
                if (q is v)
                    return p;
    return null;
}

/// Open `path` through a fresh ddhx editor and give it a tab.
///
/// The file lands in a new tab, unless the one in front is an untouched scratch
/// buffer - the state the app starts in - which it takes over instead. On failure
/// nothing changes and the error is logged.
public bool ui_open(string path)
{
    Document* d = ui_load(path);
    if (d is null)
        return false;

    // The focused pane is where the user was working - or, on a drop, the pane the
    // file was let go over.
    Pane* p = focused;
    View* v = p.views[p.current];
    Document* scratch = v.doc;

    if (scratchEmpty(*scratch))
    {
        // It is the *view* that is reused: the scratch document only goes if this
        // was the last view of it, another pane showing the same one (the state a
        // fresh split leaves) still having bytes to draw.
        //
        // A different file in the same view, so any comparison it was part of was
        // about the bytes that just left.
        diff_unlink(v);
        v.doc = d;
        if (ui_view_count(scratch) == 0)
            ui_drop_document(scratch);
    }
    else
    {
        v = new View;
        v.doc = d;
        p.views ~= v; // .length updated
        p.current = p.views.length - 1; // @suppress(dscanner.suspicious.length_subtraction)
    }

    wireView(v); // picks the new editor up, on a fresh view and a reused one alike
    v.hex.baseAddress = 0;
    v.hex.active = true;    // show the caret right away on the first byte
    v.hex.takeFocus = true; // and let it take keys without a click first
    v.hex.cursor = 0;
    v.hex.anchor = 0;
    hex_reset_scroll(v.hex); // and scroll to the top so that first byte is visible
    logInfo("opened %s (%s bytes)", path, v.hex.dataSize);
    return true;
}

/// Build a document around `path`, or null when it cannot be opened (the error is
/// logged and put in the status bar, and nothing already open is disturbed).
///
/// Split out of ui_open because a comparison needs the file loaded without a tab
/// being found for it: the second document goes in a pane of its own rather than
/// wherever an Open would have landed. See ui_compare_with.
Document* ui_load(string path)
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
        // Both callers leave the window as it was, so a file picked from the Open
        // dialog that cannot be read would otherwise look like nothing happened.
        // Clipped because ui_status drops a message that overflows.
        ui_status("cannot open %s: %s", ui_clip(baseName(path), 32), ui_clip(e.msg, 44));
        return null;
    }

    Document* d = new Document;
    docs ~= d;
    d.editor = ed;
    d.path   = path; // in-place Save now has a target
    d.title  = baseName(path);
    return d;
}

/// Whether `d` is a scratch buffer nothing has been done to: no path, no edits
/// and no bytes. That is what a fresh tab (and the app itself) starts as, and
/// what an Open takes over instead of stacking a tab on top of it.
bool scratchEmpty(ref Document d)
{
    return d.path.length == 0 && d.editor &&
        d.editor.edited() == false && d.editor.size() == 0;
}

/// Write the open document's current contents to `path` and mark it saved.
///
/// Streams the edited view into a temp file alongside the target, then renames it
/// over atomically. The read-only source handle keeps referencing the original
/// inode across that, so the editor and its undo history survive without a reopen.
/// Returns false, and leaves the file untouched, if the write fails.
bool saveTo(ref Document d, string path)
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
extern (C) void ui_on_save_picked(void* user, const(char*)* fileList, int filter) nothrow
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

/// Save the open document. With a known path it writes in place and reports whether
/// that succeeded; with none it opens a native Save As dialog and returns false,
/// the write landing later on the main thread once a path is chosen.
public bool ui_save()
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
public void ui_save_as()
{
    pendingSaveTarget = doc.editor;
    SDL_ShowSaveFileDialog(&ui_on_save_picked, null, uiWindow, null, 0, null);
}

/// Write the document the Save As dialog was raised for to `dest` and adopt it
/// as that document's home, so a later in-place Save follows it. The document is
/// found again by the editor the dialog was opened for, not by tab index: both
/// can have moved while the dialog was up. A closed one drops the write.
void ui_save_pending(string dest)
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
enum COPY_MAX = 16 * 1024 * 1024;

/// Resolve the byte range Copy and Cut act on in `v`, clamped to its document. A
/// bare caret gives a single byte, matching what the status bar reports and what
/// Delete removes.
///
/// The view is a parameter because a selection is a property of a panel: with
/// several panes on screen, the one being copied out of is whichever has focus.
/// Returns: False when there is nothing to act on - no document, no caret placed
///          yet, or the caret parked past the last byte.
bool ui_selection(ref View v, out size_t low, out size_t high)
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
/// ui_paste reads the same shape back in.
/// Returns: Whether the bytes reached the clipboard, so ui_cut only removes what
///          it managed to copy.
public bool ui_copy()
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

    // A chunk at a time: the selection can be large, and only the bytes being
    // formatted need holding.
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

/// Copy the selected bytes, then remove them. The clipboard is written first and
/// the removal only follows a copy that took, so a failed copy leaves the bytes
/// where they are. A bare caret cuts the byte Delete would drop.
public void ui_cut()
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
/// semicolons and colons all separate bytes and a 0x prefix is skipped, so "de ad",
/// "DEAD" and "0xde, 0xad" land the same two. Each token must hold whole bytes;
/// anything else refuses the paste rather than guessing at a nibble.
///
/// Where the bytes land follows the panel's entry mode, the way typing does:
/// overwrite replaces at the caret (growing the document past EOF), insert splices.
/// A selection wider than one byte is what the paste replaces, in either mode.
public void ui_paste()
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
        // A selection is dropped first and the bytes spliced into the gap, the
        // entry mode only deciding how a bare caret takes them. The remove and the
        // insert are separate history entries, so undoing that takes two steps.
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

    // The document may have moved even on a failed insert-after-remove, so the
    // panel is refreshed either way.
    view.hex.dataSize = editor.size();
    hex_set_caret(view.hex, ok ? low + bytes.length : low);
    if (ok)
        logInfo("pasted %s byte(s) at %#x", bytes.length, low);
}

/// Parse clipboard text into the bytes it spells out. Returns null when the text
/// holds anything but separated runs of hex digit pairs, so an unrelated paste is
/// refused rather than half-applied. See ui_paste for the accepted shapes.
ubyte[] parseHexText(const(char)* text)
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
    assert(parseHexText("DEADBEEF")    == [ 0xde, 0xad, 0xbe, 0xef ]);
    assert(parseHexText("0xde, 0xAD")  == [ 0xde, 0xad ]); // C-ish source
    assert(parseHexText("de ad\nbe ef") == [ 0xde, 0xad, 0xbe, 0xef ]);
    assert(parseHexText("de:ad;be")    == [ 0xde, 0xad, 0xbe ]);
    assert(parseHexText("  ").length == 0);
    assert(parseHexText("").length == 0);
    assert(parseHexText("de a") is null);       // half a byte
    assert(parseHexText("dead beefs") is null); // stray letter past 'f'
    assert(parseHexText("hello") is null);
    assert(parseHexText("0x") is null);       // a prefix with no digits behind it
}

/// Outcome of the unsaved-changes prompt.
enum Confirm { proceed, cancel }

/// Button ids for the prompt, kept distinct from the unset -1 sentinel.
enum { btnSave = 1, btnDontSave = 2, btnCancel = 3 }

version (Screenshots)
{
    /// What a scripted run wants every unsaved-changes prompt answered with.
    /// `ask` (the .init) leaves the native box alone, so the live build under
    /// this buildType still behaves like the real one.
    public enum ConfirmAuto { ask, discard, keep }

    /// Set by the headless driver before it starts posing scenarios.
    public __gshared ConfirmAuto uiConfirmAuto;
}

/// Resolve unsaved edits in `d` before an action that would discard them (closing
/// the last view of it, or quitting). With no edits pending it proceeds silently;
/// otherwise it brings a view of that document to the front - so the prompt is
/// about what is on screen - and puts up a native Save / Don't Save / Cancel box
/// titled `title`.
/// Returns: Confirm.proceed when the caller may go ahead, Confirm.cancel when the
///          user backed out, a chosen save has yet to finish, or the prompt itself
///          failed (fail safe: never lose data on an error).
Confirm ui_confirm_discard(Document* d, const(char)* title)
{
    if (d is null)
        return Confirm.proceed;
    if ((d.editor && d.editor.edited()) == false)
        return Confirm.proceed;

    ui_focus_document(d);

    // The focus above still runs, so a scripted close leaves the same tab in
    // front a real one would; only the box itself is skipped. It is a native
    // window, and nothing in a headless run can click it.
    version (Screenshots)
        if (uiConfirmAuto != ConfirmAuto.ask)
            return uiConfirmAuto == ConfirmAuto.discard ? Confirm.proceed : Confirm.cancel;

    static immutable SDL_MessageBoxButtonData[3] buttons = [
        { SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT, btnSave,     "Save" },
        { cast(SDL_MessageBoxButtonFlags) 0,       btnDontSave, "Don't Save" },
        { SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT, btnCancel,   "Cancel" },
    ];
    // With several tabs open, "the document" is not enough to tell the user which
    // one they are about to lose.
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

/// Ask the user to resolve unsaved edits before quitting. True to go ahead; main
/// calls this on every quit route, so the window keeps running on Cancel. Every
/// open document is asked about in turn and the first cancel stops the quit.
/// Documents rather than tabs, so a file open in two panels is asked about once.
public bool ui_may_quit()
{
    foreach (Document* d; docs)
        if (ui_confirm_discard(d, "Quit vddhx") != Confirm.proceed)
            return false;
    return true;
}

/// One row of the omnibar's command list or shortcut sheet: what it is called,
/// the keys that reach it, and - for a command - the code ui_omni_run acts on.
struct Entry
{
    string label;
    string keys;
    int id = -1;

    /// Words the command answers to but is not called: what someone types when they
    /// know what they want and not what this application named it. Never shown, so
    /// they can be as generous as they need to be.
    ///
    /// Vocabulary first - "diff" finds Compare With, "vsplit" finds Split Pane
    /// Right, whichever editor the user came from - and translation later: a
    /// localised label would leave these English.
    string keywords;
}

/// Commands the omnibar's '>' mode offers. The menus' own actions, so anything
/// reachable by mouse is reachable by typing its name; ddhx's document-level
/// commands (go to offset, search, ...) join this table as ddhx exposes them.
enum
{
    CMD_NEW_TAB, CMD_OPEN, CMD_COMPARE, CMD_COMPARE_STOP, CMD_SAVE, CMD_SAVE_AS, CMD_CLOSE_TAB,
    CMD_CUT, CMD_COPY, CMD_PASTE, CMD_GOTO,
    CMD_FIND, CMD_FIND_NEXT, CMD_FIND_PREV, CMD_INSPECT,
    CMD_SKIP_NEXT, CMD_SKIP_PREV,
    CMD_MARK, CMD_MARK_NEXT, CMD_MARK_PREV, CMD_MARK_LIST, CMD_MARK_CLEAR,
    CMD_SPLIT, CMD_SPLIT_DOWN, CMD_CLOSE_PANE, CMD_PANE_NEXT, CMD_PANE_PREV,
    CMD_MINIMAP, CMD_ABOUT, CMD_QUIT,
}

/// Ditto.
immutable Entry[] COMMANDS = [
    Entry("New Tab",          "Ctrl+T",       CMD_NEW_TAB,      "create buffer"),
    Entry("Open File...",     "Ctrl+O",       CMD_OPEN,         "load edit read"),
    Entry("Compare With...",  "",             CMD_COMPARE,      "diff difference against versus changes"),
    Entry("Stop Comparing",   "",             CMD_COMPARE_STOP, "undiff end diff close comparison"),
    Entry("Save",             "Ctrl+S",       CMD_SAVE,         "write store commit"),
    Entry("Save As...",       "Ctrl+Shift+S", CMD_SAVE_AS,      "write export copy to"),
    Entry("Close Tab",        "Ctrl+W",       CMD_CLOSE_TAB,    "shut document"),
    Entry("Cut",              "Ctrl+X",       CMD_CUT,          "clipboard remove delete"),
    Entry("Copy",             "Ctrl+C",       CMD_COPY,         "clipboard yank"),
    Entry("Paste",            "Ctrl+V",       CMD_PASTE,        "clipboard insert put"),
    Entry("Go to Offset...",  "Ctrl+G",       CMD_GOTO,         "goto jump seek address position"),
    Entry("Find...",          "Ctrl+F",       CMD_FIND,         "search grep pattern bytes string"),
    Entry("Find Next",        "Ctrl+N",       CMD_FIND_NEXT,    "search again forward"),
    Entry("Find Previous",    "Ctrl+Shift+N", CMD_FIND_PREV,    "search back backward"),
    Entry("Inspect Bytes...", "Alt+I",        CMD_INSPECT,      "data types decode value integer float"),
    Entry("Skip Forward",     "Ctrl+Right",   CMD_SKIP_NEXT,    "run element next word"),
    Entry("Skip Back",        "Ctrl+Left",    CMD_SKIP_PREV,    "run element previous word"),
    Entry("Toggle Bookmark",  "Ctrl+B",       CMD_MARK,         "mark set flag"),
    Entry("Next Bookmark",    "]",            CMD_MARK_NEXT,    "mark forward"),
    Entry("Previous Bookmark","[",            CMD_MARK_PREV,    "mark back backward"),
    Entry("Bookmarks...",     "",             CMD_MARK_LIST,    "marks list show all"),
    Entry("Clear Bookmarks",  "",             CMD_MARK_CLEAR,   "marks remove delete none"),
    Entry("Split Pane Right", "Ctrl+\\",      CMD_SPLIT,        "vsplit vertical side window new"),
    Entry("Split Pane Down",  "Ctrl+Shift+\\",CMD_SPLIT_DOWN,   "hsplit horizontal below window new"),
    Entry("Close Pane",       "",             CMD_CLOSE_PANE,   "unsplit window remove"),
    Entry("Next Pane",        "",             CMD_PANE_NEXT,    "window forward switch"),
    Entry("Previous Pane",    "",             CMD_PANE_PREV,    "window back backward switch"),
    Entry("Toggle Minimap",   "",             CMD_MINIMAP,      "ribbon overview scrollbar sidebar"),
    Entry("About vddhx",      "",             CMD_ABOUT,        "version credits license help"),
    Entry("Quit",             "Ctrl+Q",       CMD_QUIT,         "exit leave"),
];

/// The head of the '?' sheet: the omnibar's own prefixes, which are as much a
/// shortcut as any chord and the only ones with nowhere else to be advertised. The
/// characters come from the omnibar's own enums, so the sheet cannot drift from
/// what the box answers to.
immutable Entry[] PREFIXES = [
    Entry("Omnibar: switch tab",             "(no prefix)"),
    Entry("Omnibar: run a command",          "" ~ OMNI_COMMAND),
    Entry("Omnibar: go to an offset",        "" ~ OMNI_ADDRESS),
    Entry("Omnibar: find a pattern",         "" ~ OMNI_FIND),
    Entry("Omnibar: inspect bytes at caret", "" ~ OMNI_INSPECT),
    Entry("Omnibar: list bookmarks",         "" ~ OMNI_BOOKMARK),
    Entry("Omnibar: this sheet",             "" ~ OMNI_HELP),
];

/// The rest of the '?' sheet: every key the application answers to, in the order
/// they come up - the omnibar, then the window, then the caret and the bytes under
/// it. Nothing here runs.
immutable Entry[] SHORTCUTS = [
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
public bool ui_omni_active()
{
    return omni_shown(omni);
}

/// Raise the omnibar on the mode `prefix` opens, or put it away when it is
/// already on that mode (see omni_toggle). The Ctrl+E and Ctrl+Shift+P route.
public void ui_omni_toggle(char prefix = 0)
{
    omni_toggle(omni, prefix);
    if (omni_shown(omni) == false)
        view.hex.takeFocus = true; // typing goes back to the bytes
}

/// Put the omnibar away, whatever it was showing. The Esc route.
public void ui_omni_close()
{
    if (omni_shown(omni) == false)
        return;
    omni_hide(omni);
    view.hex.takeFocus = true;
}

/// Fill the omnibar's row list for the mode it is currently in. Rebuilt every
/// frame: titles, dirty flags and the tab count all move under us.
const(OmniItem)[] ui_omni_items()
{
    rowUsed = 0; // this frame's rows start over the last frame's
    size_t n;
    void put(string label, string detail, int id, bool marked = false, bool pinned = false,
        string keywords = null)
    {
        if (n >= omniItems.length)
            omniItems.length = n + 16;
        omniItems[n++] = OmniItem(label, detail, keywords, id, marked, pinned);
    }

    final switch (omni_mode(omni))
    {
    case OmniMode.switcher:
        // One row per tab rather than per document: the switcher picks a panel to
        // go to, and two views of one file are two places to be. The path tells two
        // same-named files apart, so it is both the detail column and, through the
        // omnibar's matching, searchable.
        //
        // A row's id is its place in this list rather than a tab index, which means
        // nothing without the pane it counts within; omniTabs carries the pair back
        // for ui_omni_accept.
        size_t at;
        foreach (Column* c; columns)
        {
            foreach (Pane* p; c.panes)
            {
                foreach (size_t ti, View* v; p.views)
                {
                    if (at >= omniTabs.length)
                        omniTabs.length = at + 16;
                    omniTabs[at] = OmniTab(p, ti);
                    put(v.doc.title, v.doc.path.length ? v.doc.path : "not saved yet",
                        cast(int) at, v.doc.editor && v.doc.editor.edited());
                    ++at;
                }
            }
        }
        break;
    case OmniMode.command:
        foreach (ref immutable Entry e; COMMANDS)
            put(e.label, e.keys, e.id, false, false, e.keywords);
        break;
    case OmniMode.address:
        // One row, pinned: it is a readout of the offset being typed rather than
        // something to pick out of a list, so the query must not filter it away.
        string label, detail;
        ui_goto_preview(label, detail);
        put(label, detail, 0, false, true);
        break;
    case OmniMode.find:
        // Likewise a readout, of the bytes the pattern comes to. What it would find
        // is deliberately not looked up: this runs every frame.
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
        // The row's id is the mark's place in the list: an offset does not fit an
        // int on a document worth bookmarking.
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
Address ui_goto_target()
{
    return address_parse(omni_query(omni), cast(long) view.hex.cursor,
        cast(long) hex_total(view.hex));
}

/// Storage the omnibar's row text is composed into, and how much of it this frame
/// has taken. Rows that are computed rather than named - an offset readout, an
/// inspector reading - would otherwise allocate a string per row per frame, for
/// text nothing outlives the frame. It only ever grows.
__gshared char[] rowArena;
/// Ditto.
__gshared size_t rowUsed;

/// Park `text` in the arena and hand back a slice of it, good until the next
/// frame's rows are built. Compose into a stack buffer, then park it here.
string ui_row_text(const(char)[] text)
{
    if (rowUsed + text.length > rowArena.length)
        rowArena.length = (rowUsed + text.length) * 2 + 256;
    size_t at = rowUsed;
    rowArena[at .. at + text.length] = text;
    rowUsed += text.length;
    return cast(string) rowArena[at .. rowUsed];
}

/// Text for the ':' mode's one row: where the caret would land, or - while the text
/// is not an offset yet - the syntax it is waiting for.
void ui_goto_preview(out string label, out string detail)
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

    // The decimal count and how far in it lands, the whole point of "%50" being
    // not knowing the number.
    int percent = total ? cast(int)((a.pos * 100) / cast(long) total) : 0;
    if (a.clamped)
        detail = ui_row_text(sformat(buf,
            "%u, clamped to the document (%u bytes)", a.pos, total));
    else
        detail = ui_row_text(sformat(buf,
            "%u of %u bytes, %d%%", a.pos, total, percent));
}

/// The pattern the find box is currently spelling out, read out of its text.
///
/// Kept from one frame to the next: the preview row is built every frame the box is
/// up and ddhx's parser allocates, so the text only goes through it once it has
/// actually changed.
bool ui_find_needle(out Needle needle)
{
    const(char)[] query = omni_query(omni);
    if (query.length > findText.length) // too long to remember: read it every time
    {
        findTextLen = size_t.max;
        return search_parse(query, needle);
    }

    if (findTextLen != query.length || findText[0 .. findTextLen] != query)
    {
        findTextLen = query.length;
        findText[0 .. findTextLen] = query;
        findHave = search_parse(query, findNeedle);
    }
    needle = findNeedle;
    return findHave;
}

/// Text for the '/' mode's one row: the bytes the pattern comes to, so what is
/// about to be searched for is never a guess.
void ui_find_preview(out string label, out string detail)
{
    Needle needle;
    if (ui_find_needle(needle) == false)
    {
        label  = `pattern: text, "quoted text", utf8:text, 0xdeadbeef, x:de ad, ` ~
            `u16:255, i8:-1, f32:1.0, ?, *`;
        detail = "waiting for a pattern";
        return;
    }

    // The elements as bytes, with '??' for a one-byte wildcard and '**' for a run.
    // Long patterns are cut off here rather than in the row, which would elide the
    // tail anyway, so the arena's slice stays short.
    char[128] buf = void;
    size_t at;
    foreach (ushort element; needle.data[0 .. needle.length])
    {
        if (at + 3 > buf.length - 4) // @suppress(dscanner.suspicious.length_subtraction)
        {
            at += sformat(buf[at .. $], " ...").length;
            break;
        }
        if (at)
            buf[at++] = ' ';
        if (element == SEARCH_ANY || element == SEARCH_RUN)
        {
            buf[at .. at + 2] = element == SEARCH_ANY ? "??" : "**";
            at += 2;
        }
        else
            at += sformat(buf[at .. $], "%02x", cast(ubyte) element).length;
    }

    // A run stands for as many bytes as it takes, so the count is a floor rather
    // than the length, and saying so beats naming a number the search will not use.
    size_t least = search_least(needle);
    char[64] count = void;
    label  = ui_row_text(buf[0 .. at]);
    detail = ui_row_text(sformat(count, least == needle.length
        ? "%u byte(s), from the caret" : "%u byte(s) or more, from the caret",
        least));
}

/// One row of the '=' inspector: a type, and the byte order it is read in.
struct Inspect
{
    string label;
    InspectorType type;
    Endian endian;
}

/// The readings the '=' mode offers, little-endian first so the common ones are
/// on screen without scrolling, then the same types the other way round. Single
/// bytes have no byte order to argue about, so they appear once.
immutable Inspect[] INSPECT = [
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

/// Read the bytes the inspector works from: as many as its widest type needs, from
/// where the selection starts - the caret itself when there is no selection. A
/// short read near EOF is fine, formatInspector saying "N/A" for what no longer
/// fits.
ubyte[] ui_inspect_bytes(ubyte[] buf)
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
const(char)[] ui_inspect_value(int index, ubyte[] bytes, char[] buf)
{
    if (index < 0 || index >= INSPECT.length)
        return null;
    return formatInspector(buf, INSPECT[index].type, bytes, INSPECT[index].endian);
}

/// Act on the row the omnibar took, in the mode it was showing when the list was
/// built (which is not necessarily the mode its text spells out now: a prefix
/// typed this frame only reaches the list on the next one).
void ui_omni_accept(OmniMode mode, int id)
{
    final switch (mode)
    {
    case OmniMode.switcher:
        // The id indexes the flat list the rows were built from, which carries the
        // pane as well as the tab.
        if (id >= 0 && id < omniTabs.length)
            ui_select_tab_in(omniTabs[id].pane, omniTabs[id].tab); // takes focus itself
        break;
    case OmniMode.command:
        ui_omni_run(id);
        break;
    case OmniMode.address:
        // Parsed again rather than carried in the row's id, which is an int where
        // an offset is not. A half-typed offset just puts the box away.
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
        // Nothing to jump to: the reading itself is the answer, so it goes to the
        // clipboard.
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

/// The bytes a bookmark covers, as the detail column of its row: enough of them to
/// recognise what was marked, with the ASCII beside it and the run's length after
/// it when there is more than fits.
string ui_bookmark_bytes(ref const(Bookmark) mark)
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
__gshared Needle lastNeedle;
/// Ditto.
__gshared bool haveNeedle;

/// The pattern the find box last had read out of it, and the text it came from, so
/// the box's own frames do not put one query through the parser over and over. See
/// ui_find_needle.
__gshared Needle findNeedle;
/// Ditto.
__gshared bool findHave;
/// Ditto. size_t.max for "nothing remembered", which no query length can be.
__gshared size_t findTextLen = size_t.max;
/// Ditto. As long as the omnibar's own buffer, so a query it holds fits here.
__gshared char[192] findText;

/// Look through `v`'s document for the last pattern from `from`, in whichever
/// direction, and put that view's selection on what turns up. Reports through the
/// status bar either way: a search that found nothing has to say so, or it reads
/// as a dropped keystroke.
void ui_find_step(ref View v, bool backward, long from)
{
    if (haveNeedle == false)
    {
        ui_status("no pattern to find yet");
        return;
    }
    if (v.doc.editor is null)
        return;

    // The length comes back from the search rather than off the needle: a '*' runs
    // for whatever the document held, so only the match knows how much to select.
    size_t length;
    long at = search_find(lastNeedle, from, cast(long) hex_total(v.hex),
        backward, length, &hexRead, cast(void*) v.doc.editor);
    if (at < 0)
    {
        ui_status("not found");
        return;
    }

    ui_select_range(v, cast(size_t) at, length);
    ui_status("found at %#x", at);
}

/// Repeat the last search from where the caret is. The step off the caret is
/// what keeps a repeat moving instead of finding the same match again.
public void ui_find_repeat(bool backward)
{
    long from = cast(long) view.hex.cursor + (backward ? -1 : 1);
    ui_find_step(view, backward, from);
}

/// Move past the run of identical elements at the caret, the way ddhx's skip-back
/// and skip-forward do, landing on the first element either side that holds
/// something else. A run reaching the end of the document goes there rather than
/// leaving the key looking dropped.
///
/// The element is the byte under a bare caret and the whole of the selection when
/// there is one, which is how a table of records is walked a record at a time. What
/// is landed on stays selected so the walk can be repeated - ddhx drops the
/// selection there, but a chord that cannot be pressed twice is half a movement.
public void ui_skip_element(bool backward)
{
    if (doc.editor is null)
        return;

    long total = cast(long) hex_total(view.hex);
    if (total <= 0)
        return;

    // Taken from the selection's low end, the way ddhx takes it, so both directions
    // step in the same lane. A selection can outlive the bytes it covered (a delete
    // under it), hence the clamp.
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
    // Nothing ahead of the append slot, so a forward skip from there has nowhere to
    // go; backward still walks the run behind it.
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
void ui_select_range(ref View v, size_t start, size_t len)
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
/// when nothing is selected: a field or a header is worth coming back to, a lone
/// byte of it rarely is.
public void ui_mark_toggle()
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
public void ui_mark_step(int dir)
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
void ui_mark_select(ref View v, ptrdiff_t index)
{
    ui_select_range(v, cast(size_t) v.doc.marks[index].at,
        cast(size_t) v.doc.marks[index].length);
}

/// Run one command from the '>' list. Everything here is an entry point the
/// menubar already calls, so a command and its menu item cannot drift apart.
void ui_omni_run(int id)
{
    switch (id)
    {
    case CMD_NEW_TAB:   ui_new_tab();          break;
    case CMD_OPEN:      ui_open_dialog();      break;
    case CMD_COMPARE:   ui_compare_dialog();   break;
    case CMD_COMPARE_STOP: ui_compare_stop();  break;
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
    case CMD_SPLIT_DOWN: ui_split_down();      break;
    case CMD_CLOSE_PANE: ui_close_pane();      break;
    case CMD_PANE_NEXT:  ui_cycle_pane(1);     break;
    case CMD_PANE_PREV:  ui_cycle_pane(-1);    break;
    case CMD_MARK_CLEAR:
        ui_status("cleared %u bookmark(s)", doc.marks.length);
        doc.marks = null;
        break;
    // Back into the box on another prefix, which reopens next frame and grabs the
    // keyboard, so the panel must not be handed focus on the way out.
    case CMD_GOTO:      omni_show(omni, OMNI_ADDRESS);  return;
    case CMD_FIND:      omni_show(omni, OMNI_FIND);     return;
    case CMD_INSPECT:   omni_show(omni, OMNI_INSPECT);  return;
    case CMD_MARK_LIST: omni_show(omni, OMNI_BOOKMARK); return;
    case CMD_ABOUT:     about_open();          break;
    case CMD_QUIT:
        // Through SDL's own queue, so it meets the same unsaved-changes check as
        // every other quit route.
        SDL_Event quit; // .init zeroes the union
        quit.type = SDL_EVENT_QUIT;
        SDL_PushEvent(&quit);
        return;
    default:
        return;
    }
    view.hex.takeFocus = true; // whatever it was, the bytes take keys again after
}

/// True while something on screen moves on its own and the loop has to keep
/// drawing rather than sleeping until the next event. Nothing in the editor
/// proper animates (for now), so this is only ever the easter egg.
public bool ui_animating()
{
    return elite_animating();
}

/// Build one frame of UI. Call between mu_begin and mu_end.
public void ui_frame(mu_Context* ctx, int width, int height)
{
    // The menubar sits flush against the window's top and side edges. The body's
    // inset is fixed when mu_begin_window_ex pushes it, so the padding is zeroed
    // across that call and restored for the content below.
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

        // Rows in this window abut: ddui's gap between rows is painted in the
        // window's own colour, which stripes the chrome and the grid with pale
        // seams. Restored on the way out, so the About dialog keeps stock spacing.
        int spacing = ctx.style.spacing;
        ctx.style.spacing = 0;
        scope(exit) ctx.style.spacing = spacing;

        // Pick up a file the async Open dialog chose since the last frame.
        if (atomicLoad(pendingReady))
        {
            atomicStore(pendingReady, false);
            string picked = pendingPath.ptr.fromStringz.idup;
            if (pendingCompare)
            {
                pendingCompare = false;
                ui_compare_with(picked);
            }
            else
                cast(void) ui_open(picked);
        }

        // Likewise a Save As destination, adopted as the document's home so later
        // saves land in place without asking again.
        if (atomicLoad(pendingSaveReady))
        {
            atomicStore(pendingSaveReady, false);
            ui_save_pending(pendingSavePath.ptr.fromStringz.idup);
        }

        // The omnibar and a dropdown are both one-at-a-time overlays, and neither
        // can usefully sit over the other: ddui fronts an open menu every frame
        // (mu_begin_menu), so a menu left up covers the box for as long as both are
        // open. Whichever was raised last gets the window, checked either side of
        // the bar because this frame's click is what opens a menu.
        if (omni_shown(omni) && omniWasShown == false)
            ctx.menu_stack_len = 0;

        ui_menubar(ctx);

        if (ctx.menu_stack_len > 0 && omni_shown(omni))
            ui_omni_close();
        omniWasShown = omni_shown(omni);

        // The panes take the rest of the window, save a strip at the bottom for the
        // status bar.
        int statusH = ctx.text_height(ctx.style.font) + 6;
        ui_panes(ctx, statusH);

        // Edit mode, a dirty marker, caret offset and selection length, in the
        // strip ui_panes kept free above.
        static immutable int[1] srow = [ -1 ];
        mu_layout_row(ctx, 1, srow.ptr, statusH);
        mu_Rect sr = mu_layout_next(ctx);
        mu_draw_rect(ctx, sr, mu_Color(30, 30, 40, 255));
        char[160] statusbuf = void;
        size_t selLen = hex_total(view.hex) ?
            hex_sel_high(view.hex) - hex_sel_low(view.hex) + 1 : 0;
        string mode  = view.hex.insertMode ? "INS" : "OVR";
        string dirty = (doc.editor && doc.editor.edited()) ? " *" : "";
        // Name the counterpart while a comparison is up: without it the dimmed
        // bytes and the red ones are a state the window gives no other account of.
        View* other = diff_peer(&view());
        char[64] cmpbuf = void;
        const(char)[] cmp = other ?
            sformat(cmpbuf, "  vs %s", ui_clip(other.doc.title, 48)) : "";
        char[] status = sformat(statusbuf, "%s%s  offset %08x  selected %u byte(s)%s",
            mode, dirty, view.hex.cursor, selLen, cmp);
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

        // Last, so the title agrees with the status bar above rather than trailing
        // an edit by a frame.
        ui_window_title();

        mu_end_window(ctx);
    }

    // Help > About, as its own root container so it floats over the main window.
    about_frame(ctx, width, height);

    // What the About dialog is hiding, over the top of it.
    elite_frame(ctx, width, height);

    // The omnibar goes last, over everything. The mode is read before the box runs,
    // so accepting acts on the list that was actually shown rather than on one a
    // prefix typed this same frame would have swapped in.
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
/// A close can take a whole pane out of the grid, leaving the loops below walking
/// arrays that moved under them. So the strips only report, and the one action a
/// frame can carry is applied once the loops are done - still this frame.
struct TabRequest
{
    Pane* pane;
    TabAction action;
    int index;
    int target;
}

/// A tab dragged clean out of its strip, belonging to no pane while it is in the
/// air: where it came from, which item of that strip it is, and where the pointer
/// has it. Drawn once every pane is down, so it passes over them all rather than
/// being clipped to the lane it left.
struct TabGhost
{
    Pane* pane; // null while nothing is in the air
    int index;
    mu_Rect rect;
}

/// Lay the grid out across the window and draw every pane in it.
///
/// A row of columns, splitters between them, sharing the width by weight; each
/// column then shares its height out over the panes stacked in it the same way.
/// The grid takes the whole window below the toolbar bar `statusH` pixels at the
/// bottom, which the status bar then lands in.
void ui_panes(mu_Context* ctx, int statusH)
{
    size_t n = columns.length;

    // One full-width row for the lot, then every column and splitter placed inside
    // it by hand: ddui hands an absolute rect back without advancing its own
    // layout, which is what lets a column be pinned to a computed rect.
    static immutable int[1] full = [ -1 ];
    mu_layout_row(ctx, 1, full.ptr, -(statusH + ctx.style.spacing + 1));
    mu_Rect grid = mu_layout_next(ctx);

    int bars  = cast(int)(n - 1) * SPLIT_WIDTH;
    int avail = mu_max(0, grid.w - bars);

    if (colWeights.length < n) colWeights.length = n;
    if (colSizes.length   < n) colSizes.length   = n;
    foreach (size_t i, Column* c; columns)
        colWeights[i] = c.weight;
    split_layout(colWeights[0 .. n], avail, colSizes[0 .. n]);

    TabRequest req = { action: TabAction.none };
    TabGhost ghost;

    int x = grid.x;
    foreach (size_t i, Column* c; columns)
    {
        mu_Rect r = mu_Rect(x, grid.y, colSizes[i], grid.h);
        x += r.w;

        // Everything a column draws is scoped under its own identity, and every
        // pane under the pane's, so the widgets inside can use plain constant names
        // and still come out unique - ddui seeds every id it hashes with the top of
        // the id stack, containers included. That is what keeps two panes from
        // sharing a scroll offset, and the two splitter axes from sharing a grab.
        //
        // What is hashed is the pointer's value, the bytes at `&c`, not the array
        // slot it was read from, which moves whenever the grid grows.
        mu_push_id(ctx, &c, (Column*).sizeof);
        scope(exit) mu_pop_id(ctx);

        ui_column(ctx, c, r, req, ghost);

        // A splitter between each pair, dragged to trade width across it. The
        // weights are written back through the scratch the layout was built from,
        // so the columns redraw at the new sizes on the next frame.
        if (i + 1 < n)
        {
            mu_Rect sr = mu_Rect(x, grid.y, SPLIT_WIDTH, grid.h);
            x += SPLIT_WIDTH;
            int dx = split_bar_x(ctx, "vbar", sr);
            if (dx && split_resize(colWeights[0 .. n], i, dx, avail, PANE_MIN))
                foreach (size_t j, Column* q; columns)
                    q.weight = colWeights[j];
        }
    }

    // A file held over the window picks out the pane it would land in. After the
    // loop so it washes over the panel rather than under it: a hex panel is a ddui
    // panel, not a root container, so anything added later paints on top.
    //
    // The pane is looked up rather than trusted: a drag can be in flight while the
    // window carries on working, and its pane may have closed since.
    if (dropPane && ui_pane_index(dropPane) >= 0)
        ui_mark_pane(ctx, dropPane.rect);

    // A tab in the air between panes: the pane it would land in first, then the tab
    // over the top of everything - here rather than in the strip it came from,
    // which clips to its own lane.
    if (ghost.pane)
    {
        Pane* src = ghost.pane;
        SplitZone zone;
        Pane* onto = ui_drop_target(ctx, zone);
        // Back over its own pane is the drag being called off, so nothing is marked
        // - unless it is against an edge, which splits the tab out and is a real
        // destination.
        if (onto && (onto !is src ||
                    (zone != SplitZone.centre && src.views.length > 1)))
            ui_mark_pane(ctx, ui_drop_rect(onto, zone));
        if (ghost.index >= 0 && ghost.index < src.items.length)
            tab_ghost(ctx, src.tabs, src.items[ghost.index], ghost.rect);
    }

    // Every pane has drawn, so where each is scrolled to is settled: carry that
    // across the comparisons before anything can rearrange the grid.
    ui_sync_diffs();

    // The loops are done with the grid, so a strip's request is safe to carry out
    // even where it drops the pane that asked.
    switch (req.action)
    {
    case TabAction.select: ui_select_tab_in(req.pane, req.index); break;
    case TabAction.close:  ui_close_tab_in(req.pane, req.index);  break;
    case TabAction.add:    focused = req.pane; ui_new_tab();      break;
    case TabAction.move:   ui_move_tab(req.pane, req.index, req.target); break;
    // Let go outside its own strip, it goes to whichever pane the pointer is over,
    // into it or into a new pane splitting it. Released over nothing - a splitter,
    // the status bar - it stays put, which is the way out of an accidental drag.
    case TabAction.detach:
        SplitZone zone;
        Pane* onto = ui_drop_target(ctx, zone);
        ui_split_into(req.pane, req.index, onto, zone);
        break;
    default:
    }
}

/// Put both halves of every comparison back on the same offset.
///
/// Two files are compared by reading across the window, so the panes have to hold
/// the same offset on the same line. Which one leads is whichever the user just
/// moved, told from the offset each was left at when it last drew: everything that
/// scrolls a panel goes through its own topRow, so there is nothing to hook into
/// but the result.
///
/// Only front tabs are read, a background view not having drawn and so not having
/// moved. It is still written to, so a comparison whose other half is behind a tab
/// is lined up already when that tab comes forward.
///
/// Called once every pane has drawn. Both sides moving in one frame is not
/// something a user can do, so the first found leading is enough.
void ui_sync_diffs()
{
    foreach (Column* c; columns)
    {
        foreach (Pane* p; c.panes)
        {
            View* v = p.views[p.current];
            if (v.diff is null)
                continue;

            long top = hex_top_offset(v.hex);
            bool forced = v.topForced;
            v.topForced = false;

            if (top == v.topSeen)
                continue; // this side stayed put; it is not the one leading

            // It went where it was put, but not as far: a panel stops at its own
            // last screenful, so the shorter file sits there while the longer one
            // goes on. That is the end of the file rather than this side taking the
            // lead, which would have it hauling the longer pane back up every frame.
            if (forced && top < v.topSeen)
            {
                v.topSeen = top;
                continue;
            }

            View* peer = diff_peer(v);
            hex_set_top_offset(peer.hex, top);
            peer.topSeen  = top;
            peer.topForced = true;
            v.topSeen = top;
        }
    }
}

/// Lay one column's panes out down `r` and draw each one.
///
/// The same arithmetic as the row of columns above, one axis over: the height is
/// shared by weight, a splitter sits between each pair, and dragging one trades
/// height across that boundary alone.
void ui_column(mu_Context* ctx, Column* c, mu_Rect r, ref TabRequest req,
    ref TabGhost ghost)
{
    size_t n = c.panes.length;

    int bars  = cast(int)(n - 1) * SPLIT_WIDTH;
    int avail = mu_max(0, r.h - bars);

    if (paneWeights.length < n) paneWeights.length = n;
    if (paneSizes.length   < n) paneSizes.length   = n;
    foreach (size_t i, Pane* p; c.panes)
        paneWeights[i] = p.weight;
    split_layout(paneWeights[0 .. n], avail, paneSizes[0 .. n]);

    c.rect = r; // for the drop preview; see Column.rect

    int y = r.y;
    foreach (size_t i, Pane* p; c.panes)
    {
        mu_Rect pr = mu_Rect(r.x, y, r.w, paneSizes[i]);
        y += pr.h;
        p.rect = pr; // for the out-of-frame hit test; see Pane.rect

        // Clicking anywhere in a pane moves the keyboard to it, so the menus, the
        // omnibar and every chord act on the pane last worked in. The panel inside
        // takes ddui's own focus from the same press; this is the application's
        // notion of where the user is, alongside it.
        if (ctx.mouse_pressed == MU_MOUSE_LEFT && mu_mouse_over(ctx, pr))
            focused = p;

        mu_push_id(ctx, &p, (Pane*).sizeof); // see ui_panes for why the pointer
        scope(exit) mu_pop_id(ctx);

        mu_layout_set_next(ctx, pr, 0);
        mu_layout_begin_column(ctx);
        ui_pane(ctx, p, req);
        mu_layout_end_column(ctx);

        mu_Rect out_;
        int outTab;
        if (tab_drag_out(p.tabs, out_, outTab))
            ghost = TabGhost(p, outTab, out_);

        if (i + 1 < n)
        {
            mu_Rect sr = mu_Rect(r.x, y, r.w, SPLIT_WIDTH);
            y += SPLIT_WIDTH;
            int dy = split_bar_y(ctx, "hbar", sr);
            if (dy && split_resize(paneWeights[0 .. n], i, dy, avail, PANE_MIN_H))
                foreach (size_t j, Pane* q; c.panes)
                    q.weight = paneWeights[j];
        }
    }
}

/// Pick a pane out as somewhere a drag would land: a wash over it and an edge
/// around it. Shared by the two things that can be dropped into one, a file from
/// outside the window and a tab from another pane.
void ui_mark_pane(mu_Context* ctx, mu_Rect r)
{
    mu_draw_rect(ctx, r, DROP_WASH);
    mu_draw_rect(ctx, mu_Rect(r.x, r.y, r.w, DROP_EDGE_W), DROP_EDGE);
    mu_draw_rect(ctx, mu_Rect(r.x, r.y + r.h - DROP_EDGE_W, r.w, DROP_EDGE_W), DROP_EDGE);
    mu_draw_rect(ctx, mu_Rect(r.x, r.y, DROP_EDGE_W, r.h), DROP_EDGE);
    mu_draw_rect(ctx, mu_Rect(r.x + r.w - DROP_EDGE_W, r.y, DROP_EDGE_W, r.h), DROP_EDGE);
}

/// Draw one pane: its tab strip, then the hex panel filling what is left of the
/// column it was given.
///
/// One tab per view, named after the document it shows and carrying that document's
/// unsaved-changes dot, so two views of one file are two tabs named the same. The
/// item slice is rebuilt every frame, titles and dirty flags both moving under us.
/// What the strip reports goes into `req` rather than happening here; see
/// TabRequest.
void ui_pane(mu_Context* ctx, Pane* p, ref TabRequest req)
{
    if (p.items.length < p.views.length)
        p.items.length = p.views.length;
    foreach (size_t i, View* v; p.views)
        p.items[i] = TabItem(v.doc.title, v.doc.editor && v.doc.editor.edited());

    // Only the pane taking keys lights its accent, so with several panes open it
    // is never a guess which one a keystroke lands in.
    p.tabs.unfocused = p !is focused;

    int at, target;
    TabAction action = tab_bar(ctx, "tabs", p.tabs,
        p.items[0 .. p.views.length], cast(int) p.current, at, target);
    if (action != TabAction.none)
        req = TabRequest(p, action, at, target);

    View* v = p.views[p.current];
    v.hex.minimap = minimapOn != 0;

    // The panel keeps its copy of the size live within a frame; this keeps it
    // authoritative across them, and across panes, where an edit made in one is a
    // size change the other has yet to hear about.
    if (v.doc.editor)
        v.hex.dataSize = v.doc.editor.size();

    // The same for the document this one is being compared against, which is a
    // whole document the panel knows nothing about: its size for the colours to
    // tell a changed byte from one this side simply has more of, and its cached
    // block dropped so the frame reads it afresh. Both are one call a frame, and
    // between them they mean an edit in either pane shows up in the colours.
    //
    // Only the reporting side needs any of it: the other is drawn as an ordinary
    // view and never asks what the bytes beside it are, so it never allocates a
    // block or reads the other document at all.
    if (diff_reports(v))
    {
        IDocumentEditor peer = diff_peer(v).doc.editor;
        v.peerSize = peer ? peer.size() : 0;
        v.peerLen  = 0;
    }

    // The panel fills the rest of the column, so nothing is reserved below it:
    // the status bar is the window's, not this pane's. The name is a constant
    // because ui_panes has this pane's id pushed: see the scope it sets up there.
    // Check return with `& MU_RES_CHANGE`
    cast(void) hex_view(ctx, "hex", v.hex, render_font_mono(), 0);
}

/// Reorder the tab strip: take the view at `from` and put it at `to`, shifting
/// whatever it passes over the other way. The drag route, so the strip the
/// pointer leaves behind is the order that sticks.
void ui_move_tab(Pane* p, size_t from, size_t to)
{
    if (p is null || from >= p.views.length || to >= p.views.length || from == to)
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

/// Hand the view at `index` in pane `src` over to pane `dst`, where it joins the
/// end of the strip and comes to the front: the drag-between-panes route.
///
/// The view goes across whole - caret, scroll position, document - so what was on
/// screen in the old pane appears in the new one. A pane emptied by the move is
/// closed, and the destination takes the keyboard either way. A null `dst`, let go
/// over a splitter or the status bar, is no move at all.
void ui_move_view(Pane* src, size_t index, Pane* dst)
{
    if (src is null || dst is null || src is dst || index >= src.views.length)
        return;

    View* v = ui_take_view(src, index);

    dst.views ~= v; // .length updated
    dst.current = dst.views.length - 1; // @suppress(dscanner.suspicious.length_subtraction)
    v.hex.takeFocus = true;

    // The pane it came from may have nothing left in it. Panes are named by
    // pointer, so the destination is unaffected by the grid closing over it.
    if (src.views.length == 0 && ui_pane_count() > 1)
        ui_drop_pane(src);

    focused = dst;
}

/// Ditto, but the view lands in a pane of its own beside `dst` rather than in
/// `dst` itself: the drag-to-split route, where a tab let go against a pane's
/// edge divides that pane instead of joining it.
///
/// `zone` says which edge, and so where the new pane goes: above or below `dst` in
/// its own column, or in a new column to one side. The sideways case reaches around
/// the whole column, exactly as ui_split does, the grid being two levels deep -
/// ui_drop_rect shows that before the user lets go.
///
/// A tab dropped on the edge of its own pane splits off from it, which is how one is
/// pulled into a split without visiting another pane first; a pane's last tab has
/// nothing to split away from and stays put.
void ui_split_into(Pane* src, size_t index, Pane* dst, SplitZone zone)
{
    if (src is null || dst is null || index >= src.views.length)
        return;
    if (zone == SplitZone.centre)
    {
        ui_move_view(src, index, dst);
        return;
    }
    if (src is dst && src.views.length < 2)
        return;

    // Settled before anything moves: a destination somehow not in the grid must
    // leave the view where it is rather than in a pane nothing draws.
    size_t ci, pi;
    if (ui_locate(dst, ci, pi) == false)
        return;

    Pane* p = newPane();
    p.views ~= ui_take_view(src, index);
    p.views[0].hex.takeFocus = true;

    if (zone == SplitZone.up || zone == SplitZone.down)
    {
        // Half of the pane being dropped on, so the column's total is unchanged
        // and nothing outside it moves.
        Column* c = columns[ci];
        p.weight = dst.weight / 2;
        dst.weight -= p.weight;

        size_t at = zone == SplitZone.up ? pi : pi + 1;
        c.panes = c.panes[0 .. at] ~ p ~ c.panes[at .. $];
    }
    else
    {
        Column* c = new Column;
        c.panes ~= p;
        c.weight = columns[ci].weight / 2;
        columns[ci].weight -= c.weight;

        size_t at = zone == SplitZone.left ? ci : ci + 1;
        columns = columns[0 .. at] ~ c ~ columns[at .. $];
    }

    // After the insertion, whose indices were read from the grid as it stood.
    if (src.views.length == 0 && ui_pane_count() > 1)
        ui_drop_pane(src);

    focused = p;
}

/// Take the view at `index` out of `p`, leaving the front tab on whatever is
/// nearest what it was showing: a tab taken from the left of it shifts it down, and
/// taking the front one keeps the index, which now names its right-hand neighbour.
///
/// The pane may be left with nothing in it, which is for the caller to deal with -
/// it has somewhere to put the view and this does not.
View* ui_take_view(Pane* p, size_t index)
{
    View* v = p.views[index];
    p.views = p.views[0 .. index] ~ p.views[index + 1 .. $];
    if (index < p.current)
        --p.current;
    if (p.views.length && p.current >= p.views.length)
        p.current = p.views.length - 1; // @suppress(dscanner.suspicious.length_subtraction)
    return v;
}

/// Where the tab at `at` ends up once the one at `from` is moved to `to`. The
/// moved tab lands on `to` itself; everything between the two shifts one place
/// the other way, and everything outside that span stays where it is.
size_t tab_reindex(size_t at, size_t from, size_t to)
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

    foreach (size_t i; 0 .. 4)
        assert(tab_reindex(i, 2, 2) == i);
}

/// Draw the top menubar, on ddui's native one: it packs the titles left to right
/// and handles the dropdowns and outside-click dismissal itself.
void ui_menubar(mu_Context* ctx)
{
    mu_begin_menubar(ctx);

    // ddui recomputes a dropdown item's height and text inset from style.padding per
    // item, where the bar title width and the popup's body margin are baked in
    // during mu_begin_menu. So bumping padding around the mu_menu_item calls alone
    // loosens the rows and leaves the frame untouched.
    int basePadding = ctx.style.padding;
    int itemPadding = basePadding + 4;

    // A dropdown takes its width from style.menu_width alone, so a label and a
    // right-aligned shortcut overlap once they outgrow the stock 160px (as
    // "Save As..." and Ctrl+Shift+S do). Measuring the widest pair beats pinning a
    // pixel count that a change of font would quietly break again.
    int itemWidth(const(char)* label, const(char)* shortcut)
    {
        // One padding inset each side, plus two more as the gap between the label
        // and the shortcut, so they never touch.
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
        // The pair reads as one thing, so the end of a comparison sits with its
        // start rather than being hunted for in another menu.
        if (mu_menu_item_ex(ctx, "Compare With...", "",        0, 0)) ui_compare_dialog();
        if (mu_menu_item_ex(ctx, "Stop Comparing",  "",        0, 0)) ui_compare_stop();
        mu_menu_separator(ctx);
        if (mu_menu_item_ex(ctx, "Save",       "Ctrl+S",       0, 0)) ui_save();
        if (mu_menu_item_ex(ctx, "Save As...", "Ctrl+Shift+S", 0, 0)) ui_save_as();
        mu_menu_separator(ctx);
        if (mu_menu_item_ex(ctx, "Close Tab",  "Ctrl+W",       0, 0)) ui_close_current_tab();
        // Through SDL's own queue, so main stays the single owner of the loop flag.
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

    if (mu_begin_menu(ctx, "View"))
    {
        ctx.style.padding = itemPadding;
        // No native checkmark on a ddui menu item, so the on/off state rides in the
        // shortcut column instead.
        if (mu_menu_item_ex(ctx, "Minimap", minimapOn ? "On" : "Off", 0, 0))
            minimapOn = minimapOn ? 0 : 1;
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
