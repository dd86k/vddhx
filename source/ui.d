/// Main UI: documents, views, pane grid, menus, and commands.
module ui;

import core.atomic : atomicLoad, atomicStore;
import core.time : Duration, MonoTime, msecs;
import std.ascii : toLower;
import std.string : fromStringz, toStringz, strip;
import bindbc.sdl;
import ddlogger;
import ddui;
import ddhx.document : DocCaps, FileDocument, IDocument, OFlags;
import ddhx.editor : IDocumentEditor;
import ddhx.editor.piecev4 : PieceV4DocumentEditor;
import about : about_open, about_frame;
import settings : settings_page;
import preferences : prefs, prefs_save, WriteMode, FONT_SIZE_MAX, FONT_SIZE_MIN;
import elite : elite_frame, elite_animating;
import address : Address, address_parse;
import edit : EditRequest, edit_parse, edit_range;
import bookmarks;
import crumbs;
import disks : DISKS_LISTED, Disk, disks_list, disks_size;
import elevate : Elevated, elevate_denied, elevate_poll, elevate_request;
import hexview;
import structure;
import structures.png : PngStructure, png_detect;
import theme : theme_edge, theme_role;
import uitext : ui_elide;
import omnibar;
import search;
import patterns : PatternRange;
import split;
import tabbar;
import worker : BackgroundWorker, worker_pump, worker_wake;
import ddhx.inspector : InspectorType, inspector_rows, byteSize, formatInspector;
import ddhx.charset : Charset, charsets, ASCII;
import std.system : Endian;
import render : render_font_mono, render_font_spec, render_font_ui, render_set_font,
    render_set_size;
import std.array : Appender, appender;
import std.format : format, sformat, formattedWrite;
import std.path : baseName;

// NOTE: Use ref locals once DMD 2.111 is the minimum; until then, pointers.

private:

/// An open document: the editor and the file path. Viewing state lives in
/// View, so a document can be open in several panes.
///
/// Per-document state (marks, structure, endian, charset) belongs to the bytes,
/// so it's shared by every view of the file.
struct Document
{
    /// Owns the bytes and undo history; panels only read through it.
    IDocumentEditor editor;

    /// Bumped on every byte change, for view caches. See HexView.revision.
    uint revision;

    /// Empty for a scratch buffer. Set on Open and first Save As; Save writes here.
    string path;

    /// Tab text: base name, or "untitled".
    string title;

    /// Refuse edits until ui_toggle_readonly. Disks and devices open this way
    /// since writes go straight to the device.
    bool restricted;

    /// Bookmarks, sorted. Shifted by panel edits (bookmark_shift).
    /// NOTE: Undo/redo doesn't shift them (the editor reports no move distance),
    /// so marks can drift after undoing an insert.
    Bookmark[] marks;

    /// Structure overlay, bound by detectStructure if the format is known;
    /// otherwise unbound and bytes are coloured by class.
    StructureCache structure;

    /// Structure parser read-ahead; length is capacity.
    ubyte[] structureBuf;
    /// Document offset of structureBuf[0].
    long structureStart;
    /// Valid bytes in structureBuf.
    size_t structureLen;
    /// Revision at fill; a mismatch forces a reread.
    uint structureRev;

    /// Byte order for the inspector and find scalars (`u16:`, `f32:`, `utf16:`).
    /// Structures specify their own per field.
    Endian endian = Endian.littleEndian;

    /// Background find/skip; null until first used. Edits are refused while it
    /// runs, since matches would shift.
    BackgroundWorker job;
    /// View that started the job; locked until done.
    View* jobView;
    /// Other document the job reads (a diff's peer), or null. Edits to it are
    /// refused too.
    Document* jobPeer;

    /// Text lane charset. Find patterns specify their own encoding.
    immutable(Charset)* charset = &ASCII;

    /// Read-only placeholder behind the settings tab, so it behaves like any tab.
    /// Edit/save/split commands check ui_on_settings.
    bool settingsPage;
}

/// A view onto a document: caret, selection, scroll, entry mode. Separate from
/// Document so one file can be open in several panes. Created by splitting.
struct View
{
    /// Never null while in a pane.
    Document* doc;

    /// Caret active from the start so a blank panel accepts typing.
    HexView hex = { active: true };

    /// Comparison this view is in, or null. See diff_peer.
    Diff* diff;

    /// Read-ahead of the peer's bytes for the colour hook (asked in offset order).
    /// Dropped each frame in ui_pane instead of invalidated: the peer can change
    /// in ways that don't pass through here.
    ubyte[] peerBuf;
    /// Document offset of peerBuf[0].
    size_t peerStart;
    /// Valid bytes; 0 means empty.
    size_t peerLen;

    /// Peer size, read once a frame; bytes past it are additions.
    long peerSize;

    /// Scroll position at last draw, to detect user scrolling. Only the side that
    /// moved drives the other; see ui_sync_diffs.
    long topSeen;

    /// Breadcrumb buffer, passed to the panel as a slice; must outlive the frame.
    char[128] crumbs = void;

    /// Position was set by the peer, not the user. Distinguishes a clamped
    /// follow (shorter file at its end) from a user scroll, else the panes fight.
    bool topForced;
}

/// Two views compared byte for byte, offset-aligned.
///
/// Pairs views, not documents, so one file can be compared against two others.
/// A view is in at most one Diff. `base` keeps its normal colours; only
/// `against` is tinted and reads the peer's bytes.
///
/// NOTE: Strictly offset-aligned (byte n vs n), wrong after an insertion.
/// Content alignment would need rows without offsets, which conflicts with
/// row = offset / columns everywhere else. A separate feature.
struct Diff
{
    /// View the diff was started from; normal colours.
    View* base;

    /// View opened against it; carries the colouring. Never `base`.
    View* against;
}

/// The other view in `v`'s diff, or null.
View* diff_peer(View* v)
{
    if (v is null || v.diff is null)
        return null;
    return v.diff.base is v ? v.diff.against : v.diff.base;
}

/// Whether `v` is the coloured side.
bool diff_reports(View* v)
{
    return v.diff && v.diff.against is v;
}

/// A tab strip over a hex panel. Placement is the grid's; see Column.
struct Pane
{
    /// Tabbed views, in strip order. Never empty while in the grid.
    View*[] views;

    /// Index of the visible view.
    size_t current;

    TabBar tabs;

    /// Strip items, rebuilt per frame; only grows.
    TabItem[] items;

    /// Relative height share within the column.
    int weight = SPLIT_WEIGHT;

    /// Last drawn rect, for hit tests outside a frame (SDL drop events only carry
    /// a window coordinate).
    mu_Rect rect;
}

/// A grid column: panes stacked over a shared width.
///
/// Two levels only (columns, then panes), no tree: covers editor-style splits
/// with flat arithmetic (split.d) and no single-child interior nodes.
struct Column
{
    /// Top to bottom. Never empty while in `columns`.
    Pane*[] panes;

    /// Relative width share.
    int weight = SPLIT_WEIGHT;

    /// Last drawn rect, for previewing a sideways split.
    mu_Rect rect;
}

/// All documents, views and columns.
///
/// Held by pointer: panel callbacks keep Document*/View* across frames, and
/// panes are referenced by pointer so splits and closes can't redirect them.
/// Never empty: startup opens a scratch buffer, closing the last tab leaves a
/// fresh one, and an emptied pane closes unless it's the only one.
__gshared Document*[] docs;
/// Ditto.
__gshared Column*[] columns;

/// Pane with keyboard focus; actions apply to its front tab. Always valid after
/// ui_init.
__gshared Pane* focused;

/// Layout scratch: weights and pixel sizes for columns, and for panes (reused
/// per column). Only grows.
__gshared int[] colWeights;
/// Ditto.
__gshared int[] colSizes;
/// Ditto.
__gshared int[] paneWeights;
/// Ditto.
__gshared int[] paneSizes;

/// Minimum pane width when dragging: offsets and a few bytes stay legible.
enum int PANE_MIN = 180;

/// Minimum pane height when dragging: tab strip and a row or two.
enum int PANE_MIN_H = 120;

/// Scratch buffer counter: "untitled", "untitled 2"...
__gshared uint untitled;

/// Omnibar state and rows (rebuilt per frame, only grows).
__gshared Omnibar omni;
/// Ditto.
__gshared OmniItem[] omniItems;

/// Omnibar was open last frame, to close the menu on the frame it opens.
__gshared bool omniWasShown;

/// Pane and tab per switcher row, parallel to `omniItems`. Indexed by row id.
struct OmniTab
{
    Pane* pane;
    size_t tab;
}
/// Ditto.
__gshared OmniTab[] omniTabs;

/// Tab tooltip state: hovered tab, rect, and since when. Tabs show base names;
/// the tip shows the full path.
///
/// Reported by ui_pane per strip, settled by ui_panes after all draw.
struct TabTip
{
    Pane* pane;
    int index = -1;
    mu_Rect rect;
    MonoTime since;
    bool seen;
}
/// Ditto.
__gshared TabTip tip;

/// Hover delay before the path tooltip; long enough to cross the strip.
enum Duration TIP_DELAY = msecs(500);

/// Field tooltip state: hovered view and byte. Follows the pointer (no rect).
/// Found after drawing via HexView.hoverByte, since only one panel can hold
/// the pointer.
struct SpanTip
{
    View* view;
    long at = -1;
    MonoTime since;
}
/// Ditto.
__gshared SpanTip spanTip;

/// Window size this frame, for things placed outside ddui's layout. See ui_tip.
__gshared int winW;
/// Ditto.
__gshared int winH;

/// Bookmark being named: its document and start offset (not index, since edits
/// while the box is open renumber the list).
struct MarkPrompt
{
    Document* doc;
    long at;
}
/// Ditto.
__gshared MarkPrompt markPrompt;

/// Which question the prompt is answering; OmniMode.prompt doesn't say.
enum PromptKind
{
    markName,
    columns,
    charset,
    address,
    openDevice,
    write,
    select,
}
/// Ditto. Only valid while the box is in OmniMode.prompt.
__gshared PromptKind promptKind;

/// Focused pane, its front view, and that view's document.
ref Pane focusedPane()
{
    return *focused;
}
/// Ditto.
ref View focusedView()
{
    return *focused.views[focused.current];
}
/// Ditto.
ref Document focusedDoc()
{
    return *focusedView().doc;
}

/// Find `p` in the grid.
/// Returns: True if found, with `ci` (column) and `pi` (pane) set.
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

/// Total panes across all columns.
size_t ui_pane_count()
{
    size_t n;
    foreach (Column* c; columns)
        n += c.panes.length;
    return n;
}

/// `n`th pane in reading order (columns left to right, panes top to bottom),
/// or null. Used by Ctrl+1..9 and next/previous pane.
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

/// Ditto, reversed: `p`'s index, or -1.
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

/// Main window, parent for native dialogs. Set by main.
__gshared SDL_Window* uiWindow;

/// Grid background. Near black: byte colours (dim zeros especially) are tuned
/// for it.
enum mu_Color CANVAS = mu_Color(0, 0, 0, 255);

/// Bookmark wash. Amber, which no byte class uses. Dark so white text stays
/// readable (~6.6:1 vs <2:1 for bright amber). The panel brightens it for
/// outlines and the minimap (hex_wash_lift).
enum mu_Color BOOKMARK_WASH = mu_Color(125, 85, 22, 255);

/// Bookmarked glyph colour; overrides hex_classify inside marks.
enum mu_Color BOOKMARK_TEXT = mu_Color(255, 255, 255, 255);

/// Byte differs from the peer.
enum mu_Color DIFF_CHANGED = mu_Color(255, 95, 95, 255);

/// Byte past the peer's end. Green so a longer file reads as additions.
enum mu_Color DIFF_ADDED = mu_Color(120, 230, 140, 255);

/// Brightness kept by matching bytes in a diff, percent. Dimmed, not greyed,
/// so the class colours stay readable.
enum int DIFF_MATCH_KEEP = 42;

/// Ditto: `c` dimmed, alpha kept.
mu_Color diff_dim(mu_Color c)
{
    return mu_Color(
        cast(ubyte)(c.r * DIFF_MATCH_KEEP / 100),
        cast(ubyte)(c.g * DIFF_MATCH_KEEP / 100),
        cast(ubyte)(c.b * DIFF_MATCH_KEEP / 100),
        c.a);
}

/// Apply app style over ddui defaults. Call once after mu_init.
/// ddui's MU_COLOR_PANELBG is transparent, so set the canvas explicitly.
public void ui_style(mu_Context* ctx)
{
    ctx.style.colors[MU_COLOR_PANELBG] = CANVAS;
}

/// Status message, replacing the readout until the next key or click (empty
/// find, bookmark set, copied value). Covers the readout instead of sharing
/// the row, since windows are often narrow.
__gshared char[96] statusText;
/// Ditto.
__gshared size_t statusLen;

/// Ditto. Fixed buffer; long messages are truncated.
void ui_status(Args...)(string fmt, Args args)
{
    // NOTE: sformat throws if the message doesn't fit ("comparing %s with %s"
    //       tripped it).
    static struct Sink
    {
        void put(scope const(char)[] s)
        {
            size_t room = statusText.length - statusLen;
            size_t n = s.length < room ? s.length : room;
            statusText[statusLen .. statusLen + n] = s[0 .. n];
            statusLen += n;
        }
    }
    statusLen = 0;
    Sink sink;
    try
        formattedWrite(sink, fmt, args);
    catch (Exception e)
        statusLen = 0;
}

/// Clear the message. Called by the event loop on every key/button press,
/// before dispatch, so a key can still post its own message.
public void ui_status_dismiss()
{
    statusLen = 0;
}

/// Path from the async Open dialog, consumed next frame. The callback may run
/// off-thread; the atomic flag orders the buffer write.
__gshared char[4096] pendingPath;
shared bool pendingReady;

/// What the pending path is for. Main thread only.
enum Pick
{
    open,      /// Open in a tab.
    compare,   /// Diff against compareFrom.
    marksLoad, /// Load bookmarks into marksFrom.
    marksSave, /// Save the bookmarks of marksFrom.
    font,      /// Set as the UI font.
    monofont,  /// Set as the hex panel font.
}
/// Ditto.
__gshared Pick pendingPick;
/// View "Compare With..." was raised from. Validate before use: the dialog
/// isn't modal.
__gshared View* compareFrom;
/// Ditto for the bookmark dialogs.
__gshared Document* marksFrom;

/// Ditto for Save As. The callback does no GC work; the write happens on the
/// main thread.
__gshared char[4096] pendingSavePath;
shared bool pendingSaveReady;

/// Editor the Save As was raised for. Tabs may switch while the dialog is
/// open, so save to this, not the front document.
__gshared IDocumentEditor pendingSaveTarget;

/// Set the window before the first frame. Also opens the first tab, an empty
/// editable scratch buffer.
public void ui_init(SDL_Window* window)
{
    uiWindow = window;
    worker_wake = &ui_wakeup;
    ui_new_tab();
}

/// Open a new scratch document (empty, in-memory, editable) in a new tab.
public void ui_new_tab()
{
    ++untitled;

    Document* d = newDocument();
    d.editor = new PieceV4DocumentEditor(true); // in-memory, empty
    d.title  = untitled == 1 ? "untitled" : format("untitled %u", untitled);

    View* v = newView(d);
    wireView(v);

    // First tab: no pane exists yet.
    if (columns.length == 0)
    {
        Column* c = new Column;
        c.panes ~= newPane();
        columns ~= c;
        focused = c.panes[0];
    }

    Pane* p = focused;
    p.views ~= v;
    p.current = p.views.length - 1; // @suppress(dscanner.suspicious.length_subtraction)
    v.hex.takeFocus = true; // take typing without a click
}

/// New document from the saved defaults, added to `docs`.
Document* newDocument()
{
    Document* d = new Document;
    d.charset = prefs.charset;
    d.endian  = prefs.endian;
    docs ~= d;
    return d;
}

/// New view of `d`. Splits copy instead; see ui_split_view.
View* newView(Document* d)
{
    View* v = new View;
    v.doc = d;
    v.hex.autoColumns = prefs.columns == 0;
    if (prefs.columns)
        v.hex.columns = prefs.columns;
    v.hex.insertMode = prefs.writemode == WriteMode.insert;
    v.hex.offsetBase = prefs.address;
    return v;
}

/// Empty pane; fill `views` before the next frame.
Pane* newPane()
{
    Pane* p = new Pane;

    // Active tab blends into the grid canvas. Per pane since ui_style runs once.
    p.tabs.content = CANVAS;
    return p;
}

/// Bring tab `index` of the focused pane to front. Out of range is ignored
/// (stale index after a close).
public void ui_select_tab(size_t index)
{
    ui_select_tab_in(focused, index);
}

/// Ditto in `p`, which also gets focus.
void ui_select_tab_in(Pane* p, size_t index)
{
    if (p is null || index >= p.views.length)
        return;
    focused = p;
    p.current = index;
    p.views[index].hex.takeFocus = true; // typing follows the tab
}

/// Step `delta` tabs, wrapping.
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

/// Close tab `index`, prompting for unsaved edits first (cancel keeps it).
/// Closes the view; the document closes only with its last view.
public void ui_close_tab(size_t index)
{
    ui_close_tab_in(focused, index);
}

/// Ditto in `p`. By pointer: the prompt or Save As may change focus.
void ui_close_tab_in(Pane* p, size_t index)
{
    if (p is null || index >= p.views.length)
        return;

    Document* d = p.views[index].doc;
    bool last = ui_view_count(d) <= 1;
    if (last && ui_confirm_discard(d, "Close document") != Confirm.proceed)
        return;

    // End any diff. After the prompt, which may cancel.
    diff_unlink(p.views[index]);

    // No view left for the job. The document may live on elsewhere.
    if (d.jobView is p.views[index])
    {
        d.job.abandon();
        d.jobView = null;
        d.jobPeer = null;
    }

    // The only route where a view leaves to nowhere.
    cast(void) ui_take_view(p, index);
    if (last)
        ui_drop_document(d);

    if (p.views.length == 0)
    {
        // Close the emptied pane, unless it's the last.
        if (ui_pane_count() > 1)
        {
            ui_drop_pane(p);
            return;
        }

        // Last pane emptied: open a scratch buffer. Closing a tab isn't quitting
        // (that's ui_may_quit).
        ui_new_tab();
        return;
    }

    p.views[p.current].hex.takeFocus = true;
}

/// Views of `d` across all panes.
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

/// Close `d`'s editor and remove it. Only when no view shows it.
void ui_drop_document(Document* d)
{
    if (d.job)
        d.job.abandon(); // before the editor goes
    foreach (Document* other; docs)
    {
        if (other.jobPeer !is d || other is d)
            continue;
        other.job.abandon(); // reads this editor too
        other.jobView = null;
        other.jobPeer = null;
    }
    if (d.editor)
    {
        IDocument[] held = (cast(PieceV4DocumentEditor) d.editor).documents();
        d.editor.close();
        foreach (IDocument doc; held)
            doc.close();
        d.editor = null;
    }
    foreach (size_t i, Document* other; docs)
    {
        if (other !is d)
            continue;
        docs = docs[0 .. i] ~ docs[i + 1 .. $];
        return;
    }
}

/// Bring a view of `d` to front, so a prompt matches the screen. No-op if none.
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

/// Remove `p` from the grid, giving its space to a neighbour. Close its views
/// first (ui_close_tab_in does).
///
/// The neighbour is the one above, or below if at the top, so the column total
/// is unchanged. A lone pane removes its column, same rule one level up.
void ui_drop_pane(Pane* p)
{
    size_t ci, pi;
    if (ui_locate(p, ci, pi) == false || ui_pane_count() <= 1)
        return;

    Column* c = columns[ci];
    Pane* heir;

    if (c.panes.length > 1)
    {
        // Take the neighbour pointer before removal shifts indices.
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

    // Focus moves to the neighbour that took the space.
    if (focused is p)
    {
        focused = heir;
        focused.views[focused.current].hex.takeFocus = true;
    }
}

/// New view of the focused document at the same position, for a split. Same
/// editor, undo and bookmarks; caret and scroll diverge after.
View* ui_split_view()
{
    View* src = focusedPane.views[focusedPane.current];

    View* v = new View;
    v.doc = src.doc;
    v.hex = hex_split(src.hex); // own scratch, same position
    wireView(v); // own hooks
    v.hex.takeFocus = true;
    return v;
}

/// Pair views in a diff: `base` already open, `against` opened to compare and
/// the coloured side (see Diff). Existing pairings are dropped first (one peer
/// per view). Self-comparison is refused.
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

    // Sync scroll now so they open aligned; caches fill on next draw.
    hex_set_top_offset(b.hex, hex_top_offset(a.hex));
    a.topSeen  = hex_top_offset(a.hex);
    b.topSeen  = a.topSeen;
    b.topForced = true; // if b is shorter, its clamp isn't a user scroll
}

/// End `v`'s diff, for both sides. Safe if not in one. Call when a view closes
/// or changes document.
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
        side.peerLen = 0; // drop the stale block
    }
}

/// Split the focused pane: a new column to its right, focused.
public void ui_split()
{
    if (ui_on_settings())
        return;
    ui_split_pane(ui_split_view());
}

/// Ditto, opening on `v` (same document for a split, the other file for a
/// diff).
void ui_split_pane(View* v)
{
    size_t ci, pi;
    if (ui_locate(focused, ci, pi) == false)
        return;

    Pane* p = newPane();
    p.views ~= v;

    // New single-pane column taking half the source column's width. Splits beside
    // the whole stack, keeping the grid two levels.
    Column* c = new Column;
    c.panes ~= p;
    c.weight = columns[ci].weight / 2;
    columns[ci].weight -= c.weight;

    columns = columns[0 .. ci + 1] ~ c ~ columns[ci + 1 .. $];
    focused = p;
}

/// Split the focused pane vertically: a new pane below in the same column,
/// focused. Column width is unchanged.
public void ui_split_down()
{
    if (ui_on_settings())
        return;
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

/// Close the focused pane tab by tab, with unsaved prompts; a cancel stops.
/// The last pane can't be closed.
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
        // Re-locate each round: closing the last tab removes the pane.
        size_t ci, pi;
        if (ui_locate(p, ci, pi) == false)
            return; // gone, done

        size_t before = p.views.length;
        ui_close_tab_in(p, p.current);
        if (p.views.length == before) // cancelled
            return;
    }
}

/// Focus pane `index` (ui_pane_nth order). Out of range is ignored.
public void ui_focus_pane(size_t index)
{
    Pane* p = ui_pane_nth(index);
    if (p is null)
        return;
    focused = p;
    p.views[p.current].hex.takeFocus = true;
}

/// Step `delta` panes, wrapping.
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

/// Close the visible tab (Ctrl+W, File > Close Tab).
public void ui_close_current_tab()
{
    ui_close_tab(focusedPane.current);
}

/// Last title sent to SDL, to skip unchanged updates.
__gshared char[512] titleShown;
__gshared size_t titleShownLen;

/// Update the window title (document name, unsaved marker). Called per frame;
/// composed on the stack and compared, so unchanged titles skip SDL.
void ui_window_title()
{
    if (uiWindow is null)
        return;

    char[512] buf = void;
    Document* doc = &focusedDoc();
    char[] text = ui_title_text(buf, doc.title, doc.editor && doc.editor.edited());
    if (text.length == titleShownLen && text == titleShown[0 .. titleShownLen])
        return;

    titleShown[0 .. text.length] = text;
    titleShown[text.length] = 0; // C string
    titleShownLen = text.length;
    SDL_SetWindowTitle(uiWindow, titleShown.ptr);
}

/// `s` truncated to `max` bytes on a UTF-8 boundary.
string ui_clip(string s, size_t max)
{
    if (s.length <= max)
        return s;

    size_t cut = max;
    while (cut > 0 && (s[cut] & 0xc0) == 0x80) // mid-character
        --cut;
    return s[0 .. cut];
}

unittest
{
    assert(ui_clip("short", 32) == "short");
    assert(ui_clip("exactly8", 8) == "exactly8");
    assert(ui_clip("truncate me", 8) == "truncate");

    // Cut inside "é" drops it.
    assert(ui_clip("abécd", 3) == "ab");
    assert(ui_clip("abécd", 4) == "abé");
    assert(ui_clip("é", 1) == "");
}

/// Small numbers as strings, from a table (called per frame, no allocation).
/// "-" past the table.
string ui_ordinal(ptrdiff_t n)
{
    static immutable string[64] NUMBERS = ()
    {
        string[64] t;
        foreach (int i; 0 .. 64)
            t[i] = format("%d", i);
        return t;
    }();

    return n >= 0 && n < NUMBERS.length ? NUMBERS[n] : "-";
}

unittest
{
    assert(ui_ordinal(1) == "1");
    assert(ui_ordinal(12) == "12");
    assert(ui_ordinal(63) == "63");
    assert(ui_ordinal(64) == "-");
    assert(ui_ordinal(-1) == "-");
}

/// "name * - vddhx" into `buf` (must fit the fixed parts); long names are cut.
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

    // 32-byte buffer, 10 fixed: names cut to 22.
    assert(ui_title_text(buf, "123456789012345678901234", false) ==
        "1234567890123456789012 - vddhx");
    // Exactly 22 with "é" last: no cut.
    assert(ui_title_text(buf, "12345678901234567890é", false) ==
        "12345678901234567890é - vddhx");
    // One over, cut inside "é": dropped.
    assert(ui_title_text(buf, "123456789012345678901é", false) ==
        "123456789012345678901 - vddhx");
}

/// SDL Open dialog callback, possibly off-thread: no GC. Copies the path and
/// flags it for ui_frame. `fileList`: null on error, empty on cancel.
extern (C) void ui_on_file_picked(void* user, const(char*)* fileList, int filter) nothrow
{
    if (fileList is null || *fileList is null)
        return;
    const(char)* path = *fileList; // single-select
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

/// Wake the event loop for a frame. For changes made outside events (dialog
/// callbacks on SDL's thread). Thread-safe.
void ui_wakeup() nothrow
{
    SDL_Event wake; // .init zeroes the union
    wake.type = SDL_EVENT_USER;
    SDL_PushEvent(&wake);
}

/// Panel byte source: reads via the editor in hex.readUser. Takes the editor,
/// not the view, since search uses it too (ui_find_step).
ubyte[] hexRead(long pos, ubyte[] buf, void* user)
{
    IDocumentEditor ed = cast(IDocumentEditor) user;
    return ed.view(pos, buf);
}

/// Panel colour hook: class colour, dimmed or highlighted in a diff. `user` is
/// the View (hex.colorUser): the diff belongs to the drawn view.
///
/// Marks override the diff colour (white text); the diff still shows via the
/// wash. Only the reporting side is diff-coloured; see Diff.
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

        // Short peer read (file changing underneath): not a difference.
        ubyte other;
        if (diff_peer_byte(v, offset, other) && other != value)
            return DIFF_CHANGED;
        return diff_dim(byteColor(v, offset, value));
    }

    return byteColor(v, offset, value);
}

/// Byte role: structure field role, else the classifier's. Shared by grid
/// colours and breadcrumbs so they agree. `shade` is set on alternating
/// same-role fields; classifier bytes are never shaded.
StructureRole byteRole(View* v, size_t offset, ubyte value, out bool shade)
{
    // Containers (`none`) fall through to the classifier.
    StructureSpan span;
    if (structure_at(v.doc.structure, cast(long) offset, span) && span.role != StructureRole.none)
    {
        shade = span.shade;
        return span.role;
    }
    // Document charset, matching the text lane.
    return structure_classify(value, v.doc.charset);
}

/// Ditto, as a colour.
mu_Color byteColor(View* v, size_t offset, ubyte value)
{
    bool shade;
    return theme_role(byteRole(v, offset, value, shade), shade);
}

/// Panel structure hook: span `level` levels in from the outermost at `pos`,
/// for borders. `user` is the View. The structure is per document, parsed once.
bool hexSpan(long pos, int level, ref HexSpan span, void* user)
{
    View* v = cast(View*) user;
    if (v is null || v.doc is null)
        return false;

    StructureSpan found;
    if (structure_level(v.doc.structure, pos, level, found) == false)
        return false;

    span.start  = found.at;
    span.length = found.length;
    span.edge   = theme_edge(level);
    return true;
}

/// Structure trail at `at`, outermost first ("IDAT / length"), into `buf` (per
/// frame). Unnamed containers are skipped.
/// Returns: Slice of `buf`, empty if uncovered.
const(char)[] structureLabel(Document* doc, long at, char[] buf)
{
    StructureSpan inner;
    if (structure_at(doc.structure, at, inner) == false)
        return null;

    size_t n;
    for (int level; level <= inner.depth; ++level)
    {
        StructureSpan s;
        if (structure_level(doc.structure, at, level, s) == false || s.name.length == 0)
            continue;

        if (n && n + SEP.length <= buf.length)
        {
            buf[n .. n + SEP.length] = SEP;
            n += SEP.length;
        }

        size_t take = s.name.length;
        if (n + take > buf.length)
            take = buf.length - n;
        buf[n .. n + take] = s.name[0 .. take];
        n += take;
    }
    return buf[0 .. n];
}

immutable string SEP = " / ";

/// Max '#' list rows. Listing forces an eager parse, so cap it rather than
/// parse a large container end to end.
enum size_t STRUCT_ROWS = 2048;

/// Trail for `spans[i]` ("IDAT / length") via parent links.
const(char)[] spanLabel(const(StructureSpan)[] spans, size_t i, char[] buf)
{
    ptrdiff_t[16] chain = void; // deeper than STRUCTURE_MAX_DEPTH
    size_t depth;
    for (ptrdiff_t at = i; at >= 0 && depth < chain.length; at = spans[at].parent)
        chain[depth++] = at;

    size_t n;
    foreach_reverse (ptrdiff_t at; chain[0 .. depth])
    {
        string name = spans[at].name;
        if (name.length == 0)
            continue;

        if (n && n + SEP.length <= buf.length)
        {
            buf[n .. n + SEP.length] = SEP;
            n += SEP.length;
        }

        size_t take = name.length;
        if (n + take > buf.length)
            take = buf.length - n;
        buf[n .. n + take] = name[0 .. take];
        n += take;
    }
    return buf[0 .. n];
}

/// Breadcrumb trail: format, then the caret's span path ("PNG / IDAT /
/// length"). Uncovered bytes end with their class ("PNG / control", or
/// "control" without a structure). The format stays at the root so the strip
/// always shows the document was parsed.
const(char)[] viewCrumbs(View* v)
{
    char[64] pathbuf = void;
    const(char)[] path = structureLabel(v.doc, cast(long) v.hex.cursor, pathbuf);

    ubyte value;
    if (path.length == 0 && viewByte(v, v.hex.cursor, value))
        path = structure_role_name(structure_classify(value, v.doc.charset));

    string format = structure_name(v.doc.structure);
    if (format.length == 0)
        return path.length ? sformat(v.crumbs, "%s", path) : null;
    return path.length ?
        sformat(v.crumbs, "%s%s%s", format, SEP, path) :
        sformat(v.crumbs, "%s", format);
}

/// Byte at `at`. Read failures are a miss: exceptions in a frame would crash
/// the window.
/// Returns: false past the end or on an empty document.
bool viewByte(View* v, size_t at, out ubyte value)
{
    if (v.doc.editor is null || cast(long) at >= v.doc.editor.size())
        return false;

    if (const(ubyte)[] cached = hex_cached(v.hex, at, 1))
    {
        value = cached[0];
        return true;
    }

    ubyte[1] one = void;
    ubyte[] got;
    try got = v.doc.editor.view(cast(long) at, one);
    catch (Exception e)
        return false;

    if (got.length == 0)
        return false;
    value = got[0];
    return true;
}

/// Structure byte source for `d`; read failures become short reads (runs in a
/// frame).
StructureReadFn documentReader(Document* d)
{
    return delegate(long at, ubyte[] buf)
    {
        if (at < 0 || buf.length == 0)
            return buf[0 .. 0];

        try
            return structureBuffered(d, at, buf);
        catch (Exception e)
            return buf[0 .. 0];
    };
}

/// Structure read-ahead size.
enum size_t STRUCTURE_BLOCK = 64 * 1024;

/// Read `buf` from `doc`'s structure buffer, refilling from `at` on a miss.
/// Larger requests go to the editor directly.
/// Throws: Editor read errors.
ubyte[] structureBuffered(Document* doc, long at, ubyte[] buf)
{
    if (buf.length > STRUCTURE_BLOCK)
        return doc.editor.view(at, buf);

    bool fresh = doc.structureRev == doc.revision && doc.structureLen > 0 &&
        at >= doc.structureStart && at - doc.structureStart < doc.structureLen;
    // Past the end of a full buffer: refill. Past a short buffer: EOF, serve short.
    if (fresh && at + buf.length > doc.structureStart + doc.structureLen &&
        doc.structureLen == STRUCTURE_BLOCK)
        fresh = false;

    if (fresh == false)
    {
        if (doc.structureBuf.length < STRUCTURE_BLOCK)
            doc.structureBuf.length = STRUCTURE_BLOCK;
        doc.structureLen = 0; // nothing valid after a throw
        ubyte[] got = doc.editor.view(at, doc.structureBuf);
        doc.structureStart = at;
        doc.structureLen   = got.length;
        doc.structureRev   = doc.revision;
    }

    size_t from = cast(size_t)(at - doc.structureStart);
    if (from >= doc.structureLen)
        return buf[0 .. 0];
    size_t n = doc.structureLen - from < buf.length ? doc.structureLen - from : buf.length;
    return buf[0 .. n] = doc.structureBuf[from .. from + n];
}

/// Bind a structure if the header matches a known format. Once, on open.
void detectStructure(Document* d)
{
    if (d.editor is null)
        return;

    ubyte[64] head = void;
    ubyte[] got;
    try
        got = structureBuffered(d, 0, head); // warms the buffer for the parse
    catch (Exception e)
        return;

    // TODO: Table of detectors.
    if (png_detect(got))
    {
        d.structure = structure_bind(new PngStructure(), documentReader(d), d.editor.size());
        return;
    }
}

/// Invalidate spans after an edit at `pos` and update the size. Cheap per
/// keystroke: truncates, reparse happens lazily on draw.
void structureEdited(Document* doc, long pos)
{
    if (pos < 0)
        pos = 0;
    structure_resize(doc.structure, doc.editor.size());
    structure_invalidate(doc.structure, pos);
}

/// Panel background hook: bookmark wash. `user` is the View. The selection
/// draws over it.
mu_Color hexBack(size_t offset, ubyte value, void* user)
{
    View* v = cast(View*) user;
    if (v is null)
        return mu_Color(0, 0, 0, 0);

    return bookmark_has(v.doc.marks, cast(long) offset) ? BOOKMARK_WASH : mu_Color(0, 0, 0, 0);
}

/// Ditto for a span: whether any byte is marked (bookmark_hits, so tiny marks
/// show on huge files). Same colour as hexBack: the panel also probes it
/// per byte for outlines, which must match to join.
mu_Color hexBackSpan(long at, long length, void* user)
{
    View* v = cast(View*) user;
    if (v is null)
        return mu_Color(0, 0, 0, 0);

    return bookmark_hits(v.doc.marks, at, length)
        ? BOOKMARK_WASH : mu_Color(0, 0, 0, 0);
}

/// Peer byte at `offset`, through the view's block cache (see View.peerBuf).
/// Returns: False if the peer has no byte there.
bool diff_peer_byte(View* v, size_t offset, out ubyte value)
{
    if (v.peerLen == 0 || offset < v.peerStart || offset - v.peerStart >= v.peerLen)
    {
        IDocumentEditor ed = diff_peer(v).doc.editor;
        if (ed is null)
            return false;

        if (v.peerBuf.length < DIFF_BLOCK)
            v.peerBuf.length = DIFF_BLOCK;

        // Align down so screens crossing a boundary don't reread.
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

/// Peer read block; a screen is a few thousand bytes at most.
enum size_t DIFF_BLOCK = 8 * 1024;

/// Panel write hooks: forward edits to the editor's piece table (works on
/// read-only files too). Rejected edits are logged, not thrown. `user` is the
/// panel's View, not necessarily the front document.
void hexReplace(long pos, ubyte value, void* user)
{
    View* v = cast(View*) user;
    try
    {
        v.doc.editor.replace(pos, &value, 1);
        ++v.doc.revision;
        structureEdited(v.doc, pos);
    }
    catch (Exception e)
        logError("replace failed: %s", e.msg);
}
/// Ditto.
void hexInsert(long pos, ubyte value, void* user)
{
    View* v = cast(View*) user;
    try
    {
        v.doc.editor.insert(pos, &value, 1);
        ++v.doc.revision;
        bookmark_shift(v.doc.marks, pos, 1); // bytes after moved up
        structureEdited(v.doc, pos);
    }
    catch (Exception e)
        logError("insert failed: %s", e.msg);
}
/// Ditto.
void hexRemove(long pos, long len, void* user)
{
    View* v = cast(View*) user;
    try
    {
        v.doc.editor.remove(pos, len);
        ++v.doc.revision;
        bookmark_shift(v.doc.marks, pos, -len);
        structureEdited(v.doc, pos);
    }
    catch (Exception e)
        logError("remove failed: %s", e.msg);
}

/// Panel history hooks: undo/redo and return the change position for the
/// caret. Updates `user`'s view size; other views update in ui_frame.
long hexUndo(void* user)
{
    View* v = cast(View*) user;
    long at = -1;
    try
        at = v.doc.editor.undo();
    catch (Exception e)
        logError("undo failed: %s", e.msg);
    ++v.doc.revision;
    v.hex.dataSize = v.doc.editor.size();
    structureEdited(v.doc, at);
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
        logError("redo failed: %s", e.msg);
    ++v.doc.revision;
    v.hex.dataSize = v.doc.editor.size();
    structureEdited(v.doc, at);
    return at;
}

/// Connect a view's panel to its document: hooks and initial size. Call for
/// new views and on document change. Hooks get `v` back, so it must stay valid.
void wireView(View* v)
{
    IDocumentEditor ed = v.doc.editor;
    v.hex.readFn    = &hexRead;
    v.hex.readUser  = cast(void*) ed;
    v.hex.revision  = &v.doc.revision;
    v.hex.replaceFn = &hexReplace;
    v.hex.insertFn  = &hexInsert;
    v.hex.removeFn  = &hexRemove;
    v.hex.undoFn    = &hexUndo;
    v.hex.redoFn    = &hexRedo;
    v.hex.writeUser = cast(void*) v;
    v.hex.colorFn   = &hexColor;
    v.hex.colorUser = cast(void*) v; // the view: holds the diff and marks
    v.hex.backFn     = &hexBack;
    v.hex.backSpanFn = &hexBackSpan;
    v.hex.backUser   = cast(void*) v;
    v.hex.spanFn     = &hexSpan;
    v.hex.spanUser   = cast(void*) v;
    v.hex.data      = null;
    v.hex.dataSize  = ed ? ed.size() : 0;
}

/// Pane under an in-flight file drag, or null. See ui_drop_hover.
__gshared Pane* dropPane;

/// Focused pane outline, same accent as tabs and omnibar. Faint so it doesn't
/// compete with the bytes.
enum mu_Color FOCUS_EDGE = mu_Color(110, 170, 255, 130);
/// Ditto, width.
enum int FOCUS_EDGE_W = 2;

/// Tooltip background, lighter than the strip so it reads as floating.
enum mu_Color TIP_BACK = mu_Color(48, 48, 58, 255);
enum mu_Color TIP_EDGE = mu_Color(80, 80, 95, 255);
enum mu_Color TIP_TEXT = mu_Color(215, 215, 225, 255);
/// Text inset.
enum int TIP_PAD = 5;
/// Gap below the tab.
enum int TIP_DROP = 2;
/// Window edge margin.
enum int TIP_MARGIN = 4;

/// Edge of the pane a file or tab is dragged over.
enum mu_Color DROP_EDGE = mu_Color(110, 170, 255, 255);
/// Ditto, translucent pane wash.
enum mu_Color DROP_WASH = mu_Color(110, 170, 255, 40);
/// Ditto, edge width.
enum int DROP_EDGE_W = 2;

/// Pane at a window coordinate, or null (menubar, status bar, splitter).
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

/// Pane under a dragged tab and the drop zone (join or split side). Null if
/// none.
Pane* ui_drop_target(mu_Context* ctx, out SplitZone zone)
{
    Pane* onto = ui_pane_at(ctx.mouse_pos.x, ctx.mouse_pos.y);
    zone = onto ? split_zone(onto.rect, tab_bar_height(ctx), ctx.mouse_pos)
                : SplitZone.centre;
    return onto;
}

/// Preview rect for a drop: the pane (join), half of it (split), or half the
/// column for a sideways split (see ui_split_into).
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

/// File drag over the window: highlight the pane under the pointer. Called per
/// SDL position update.
public void ui_drop_hover(int x, int y)
{
    dropPane = ui_pane_at(x, y);
}

/// Drag ended: clear the highlight.
public void ui_drop_clear()
{
    dropPane = null;
}

/// Open a dropped file in the pane it was dropped on (which takes focus), or
/// the focused pane if none. Opens a new view even if the file is open
/// elsewhere.
public void ui_drop_file(string path, int x, int y)
{
    Pane* at = ui_pane_at(x, y);
    if (at)
        focused = at;
    ui_drop_clear();
    cast(void)ui_open(path, true);
}

// All native file dialogs go through here so scripted runs can answer them.
void ui_file_dialog(SDL_DialogFileCallback picked, bool save,
    const(SDL_DialogFileFilter)[] filters = null)
{
    version (Screenshots)
    {
        if (uiPickAuto.length)
        {
            const(char)*[2] list = [ uiPickAuto.toStringz, null ];
            picked(null, list.ptr, 0);
            return;
        }
    }
    if (save)
        SDL_ShowSaveFileDialog(picked, null, uiWindow, null, 0, null);
    else
        SDL_ShowOpenFileDialog(picked, null, uiWindow, filters.ptr, cast(int) filters.length,
            null, false);
}

/// Native Open dialog, async: ui_on_file_picked stores the path, the next frame
/// opens it.
public void ui_open_dialog()
{
    pendingPick = Pick.open;
    ui_file_dialog(&ui_on_file_picked, false);
}

/// Open dialog for "Compare With...".
public void ui_compare_dialog()
{
    if (ui_on_settings())
        return;
    pendingPick = Pick.compare;
    compareFrom    = focusedPane.views[focusedPane.current];
    ui_file_dialog(&ui_on_file_picked, false);
}

/// Open `path` in a new pane right of the starting tab and diff the two. The
/// pane is created only after the file opens. Public for the scripted driver
/// and a future two-file command line.
public void ui_compare_with(string path)
{
    // The source tab may be gone (non-modal dialog); fall back to the front tab.
    View* left = compareFrom;
    compareFrom = null;
    if (left is null || ui_view_pane(left) is null)
        left = focusedPane.views[focusedPane.current];

    Document* d = ui_load(path);
    if (d is null)
        return;

    View* right = newView(d);
    wireView(right);
    right.hex.active = true;

    // Beside the source's pane, which may not be focused anymore.
    focused = ui_view_pane(left);
    ui_split_pane(right);
    diff_link(left, right);

    ui_status("comparing %s with %s", left.doc.title, right.doc.title);
    logInfo("comparing %s with %s", left.doc.title, path);
}

/// End the front tab's diff, if any.
public void ui_compare_stop()
{
    View* v = focusedPane.views[focusedPane.current];
    if (v.diff is null)
    {
        ui_status("not comparing");
        return;
    }

    ui_status("comparison ended");
    diff_unlink(v);
}

/// ddhx diff-next/diff-prev: move the caret to the start of the next (or
/// previous) run of bytes differing from the peer. Either side of a diff works.
public void ui_diff_step(bool backward)
{
    if (ui_on_settings())
        return;
    View* v = &focusedView();
    View* peer = diff_peer(v);
    if (peer is null)
    {
        ui_status("not comparing");
        return;
    }
    IDocumentEditor mine = v.doc.editor, theirs = peer.doc.editor;
    if (mine is null || theirs is null || ui_refuse_busy(v.doc) || ui_refuse_busy(peer.doc))
        return;

    long from = cast(long) v.hex.cursor;
    long size = mine.size(), peerSize = theirs.size();
    long at = -1;
    ui_job(v, (ref SearchContext ctx) {
        at = search_diff(from, size, peerSize, backward, &hexRead, cast(void*) theirs, ctx);
    }, (View* w) {
        if (at < 0)
        {
            ui_status("no more differences");
            return;
        }
        hex_set_caret(w.hex, cast(size_t) at);
        ui_status("difference at %s", ui_offset(at));
    }, peer.doc);
}

/// Pane holding `v`, or null (closed while a dialog was open). Validates a
/// View* kept across frames.
Pane* ui_view_pane(const(View)* v)
{
    foreach (Column* c; columns)
        foreach (Pane* p; c.panes)
            foreach (View* q; p.views)
                if (q is v)
                    return p;
    return null;
}

/// Open `path` in a tab of the focused pane. Replaces an untouched scratch tab;
/// on failure nothing changes (logged).
///
/// Already-open files are shown, not reopened. `here` forces a view in the
/// focused pane (drops). Always one document, possibly several views.
public bool ui_open(string path, bool here = false)
{
    Document* d = ui_load(path, true);
    if (d is null)
        return false;
    return ui_show(d, here);
}

/// Ditto, for a loaded document.
bool ui_show(Document* doc, bool here)
{
    // Only one settings tab.
    if (doc.settingsPage)
    {
        ui_focus_document(doc);
        return true;
    }

    // Focused pane, or the drop target.
    Pane* p = focused;

    if (ui_view_count(doc) > 0)
    {
        // Already in this pane: switch to it.
        foreach (size_t i, View* q; p.views)
        {
            if (q.doc is doc)
            {
                ui_select_tab_in(p, i);
                ui_status("%s is already open here", ui_clip(doc.title, 48));
                return true;
            }
        }

        if (here == false)
        {
            ui_focus_document(doc);
            Pane* at = focused;
            ui_status("%s is already open in pane %d",
                ui_clip(doc.title, 40), cast(int)(ui_pane_index(at) + 1));
            return true;
        }
    }

    View* v = p.views[p.current];
    Document* scratch = v.doc;

    if (scratchEmpty(*scratch))
    {
        // Reuse the view; the scratch document goes only if this was its last view.
        // New document, so any diff is over.
        diff_unlink(v);
        v.doc = doc;
        if (ui_view_count(scratch) == 0)
            ui_drop_document(scratch);
    }
    else
    {
        v = newView(doc);
        p.views ~= v;
        p.current = p.views.length - 1; // @suppress(dscanner.suspicious.length_subtraction)
    }

    wireView(v); // new editor
    v.hex.baseAddress = 0;
    v.hex.active = true;    // caret on the first byte
    v.hex.takeFocus = true; // take keys without a click
    v.hex.cursor = 0;
    v.hex.anchor = 0;
    hex_reset_scroll(v.hex); // first byte visible
    logInfo("opened %s (%s bytes)", doc.path, v.hex.dataSize);
    return true;
}

/// Open document for `path`, or null. Paths are normalised, so relative and
/// absolute forms match.
Document* ui_find_document(string path)
{
    string want = ui_path_key(path);
    if (want.length == 0)
        return null;
    foreach (Document* d; docs)
        if (d.path.length && ui_path_key(d.path) == want)
            return d;
    return null;
}

/// Path comparison key: absolute and normalised. Symlinks and case aren't
/// resolved, since that needs the filesystem and deleted files would differ.
string ui_path_key(string path)
{
    import std.path : absolutePath, buildNormalizedPath;
    try
        return buildNormalizedPath(absolutePath(path));
    catch (Exception)
        return path;
}

/// Load `path` as a document, or null on failure (logged, status bar; nothing
/// else changes). Already-open files return the existing document: two
/// documents on one file would have separate editors, undo and bookmarks, and
/// the last save would win.
///
/// Separate from ui_open since a diff loads without picking a tab (see
/// ui_compare_with). `elevate`: on a permission error, request an elevated open
/// (delivered later via ui_elevated) and return null.
Document* ui_load(string path, bool elevate = false)
{
    if (Document* open = ui_find_document(path))
        return open;

    try
    {
        // Shared, like ddhx: Windows refuses exclusive opens of held devices.
        return ui_adopt(path, new FileDocument(path, OFlags.read | OFlags.exists | OFlags.share));
    }
    catch (Exception e)
    {
        if (elevate && elevate_denied(e))
        {
            ui_elevate(path, false);
            return null;
        }
        logError("open failed: %s", e.msg);
        // Report it, else a failed open looks like nothing happened. Clipped to fit
        // ui_status.
        ui_status("cannot open %s: %s", ui_clip(baseName(path), 32), ui_clip(e.msg, 44));
        return null;
    }
}

/// New document over `src`, opened at `path`.
Document* ui_adopt(string path, IDocument src)
{
    IDocumentEditor ed = new PieceV4DocumentEditor(true);
    ed.open(src);

    Document* d = newDocument();
    d.editor = ed;
    d.path   = path; // Save target
    d.title  = baseName(path);
    d.restricted = ui_fixed(d) || prefs.writemode == WriteMode.readonly;
    detectStructure(d);
    return d;
}

/// Whether `d` is a disk or device, saved in place (renaming over it would
/// replace the node).
bool ui_fixed(Document* d)
{
    IDocument src = d.editor ? d.editor.document() : null;
    return src && (src.caps() & DocCaps.replace) == 0;
}

/// Untouched scratch buffer (no path, edits or bytes); Open replaces it.
bool scratchEmpty(ref Document d)
{
    return d.settingsPage == false && d.path.length == 0 && d.editor &&
        d.editor.edited() == false && d.editor.size() == 0;
}

/// Save to `path` and mark saved. Writes a temp file beside it, then renames
/// atomically; the source handle keeps the old inode, so the editor and undo
/// survive. Returns false (file untouched) on failure.
///
/// Disks and devices write in place to their own path; another path gets a
/// copy, leaving the edits pending.
bool saveTo(ref Document d, string path)
{
    import std.stdio : File;
    import std.file : rename, exists, remove, isFile;

    if (d.editor is null)
        return false;

    bool fixed = ui_fixed(&d);
    if (fixed && path == d.path)
        return saveInPlace(d);

    // Renaming over a device node replaces the node.
    try
    {
        if (exists(path) && isFile(path) == false)
        {
            ui_status("%s is not a regular file", ui_clip(baseName(path), 40));
            return false;
        }
    }
    catch (Exception) {} // let the write report it

    IDocumentEditor editor = d.editor;
    long docsize = editor.size();
    string tmp = path ~ ".vddhx-tmp"; // same directory: atomic rename
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
                if (chunk.length == 0) // avoid spinning
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
        catch (Exception) {} // best effort; report the original error
        logError("save failed: %s", e.msg);
        return false;
    }

    if (fixed == false)
        editor.markSaved();
    logInfo("saved %s (%s bytes)", path, docsize);
    return true;
}

/// Write `d`'s edits in place through its own handle (the only one with write
/// access after an elevated reopen).
bool saveInPlace(ref Document d)
{
    import ddhx.editor.base : PieceInfo;
    import std.algorithm.comparison : min;

    FileDocument src = cast(FileDocument) d.editor.document();
    if (src is null || src.writable() == false)
    {
        ui_status("%s is read-only; turn off Edit > Read-Only first", ui_clip(d.title, 32));
        return false;
    }

    IDocumentEditor editor = d.editor;
    try
    {
        // Read before preserving: preserving buffers displaced pieces but keeps their
        // positions.
        PieceInfo[] pieces = editor.dirtyPieceInfos(true);
        bool preserved = editor.prepareInplaceSave();
        ubyte[] buf = new ubyte[64 * 1024];
        foreach (ref PieceInfo piece; pieces)
        {
            for (long off; off < piece.size; off += buf.length)
            {
                size_t len = cast(size_t) min(piece.size - off, buf.length);
                long at = piece.logicalPos + off;
                src.writeAt(at, editor.view(at, buf[0 .. len]));
            }
        }
        src.flush();
        if (preserved)
            editor.markSaved();
        else
            editor.open(src); // history referenced overwritten data
    }
    catch (Exception e)
    {
        logError("save failed: %s", e.msg);
        ui_status("cannot save %s: %s", ui_clip(d.title, 32), ui_clip(e.msg, 44));
        return false;
    }
    logInfo("saved %s in place", d.path);
    return true;
}

/// Save As callback, possibly off-thread: copies the path for the next frame.
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

/// Toggle read-only. Enabling just blocks edits; disabling on a disk without
/// write access reopens it writable first (nothing lost: no edits got through).
public void ui_toggle_readonly()
{
    if (ui_on_settings())
        return;
    Document* doc = &focusedDoc();
    if (doc.restricted == false)
    {
        doc.restricted = true;
        ui_status("%s is read-only", ui_clip(doc.title, 40));
        return;
    }
    if (ui_refuse_busy(doc))
        return;

    // Files save by replacing, so they never need a writable handle.
    FileDocument src = cast(FileDocument) doc.editor.document();
    if (ui_fixed(doc) && src && src.writable() == false)
    {
        FileDocument rw;
        try
            rw = new FileDocument(doc.path, OFlags.readWrite | OFlags.exists | OFlags.share);
        catch (Exception e)
        {
            if (elevate_denied(e))
            {
                ui_elevate(doc.path, true);
                return;
            }
            logError("read-only off: %s", e.msg);
            ui_status("cannot open %s for writing: %s", ui_clip(doc.title, 32), ui_clip(e.msg, 44));
            return;
        }
        ui_swap_source(doc, rw);
    }

    doc.restricted = false;
    ui_status(ui_fixed(doc) ? "%s is editable; Save writes into it directly" : "%s is editable",
        ui_clip(doc.title, 40));
}

/// Request an elevated open of `path`; handled in ui_elevated.
void ui_elevate(string path, bool write)
{
    if (elevate_request(path, write, &ui_wakeup) == false)
    {
        ui_status("a permission prompt is already up");
        return;
    }
    ui_status("asking for permission to %s %s", write ? "write" : "open",
        ui_clip(baseName(path), 40));
}

/// Handle an elevated open: a new tab, or write access for the requesting
/// document. Unwanted handles are closed.
void ui_elevated(ref Elevated answer)
{
    if (answer.error.length)
    {
        logError("elevated open of %s: %s", answer.path, answer.error);
        ui_status("cannot open %s: %s", ui_clip(baseName(answer.path), 32),
            ui_clip(answer.error, 44));
        return;
    }

    OFlags flags = OFlags.exists | (answer.write ? OFlags.readWrite : OFlags.read);
    FileDocument src;
    try
        src = new FileDocument(answer.handle, flags, answer.path);
    catch (Exception e)
    {
        ui_status("cannot open %s: %s", ui_clip(baseName(answer.path), 32), ui_clip(e.msg, 44));
        return;
    }

    Document* d = ui_find_document(answer.path);
    if (answer.write)
    {
        // The tab may have closed or been edited during the prompt.
        if (d is null || d.restricted == false || ui_busy(d))
        {
            src.close();
            return;
        }
        ui_swap_source(d, src);
        d.restricted = false;
        ui_status("%s is editable; Save writes into it directly", ui_clip(d.title, 40));
        return;
    }

    if (d) // opened another way meanwhile
    {
        src.close();
        cast(void) ui_show(d, false);
        return;
    }
    try
        d = ui_adopt(answer.path, src);
    catch (Exception e)
    {
        src.close();
        ui_status("cannot open %s: %s", ui_clip(baseName(answer.path), 32), ui_clip(e.msg, 44));
        return;
    }
    cast(void) ui_show(d, false);
}

/// Point `d`'s editor at `src`, a new handle to the same bytes.
void ui_swap_source(Document* doc, IDocument src)
{
    IDocument old = doc.editor.document();
    doc.editor.open(src);
    if (old)
        old.close();
}

/// Full redraw requested by ui_refresh, done in ui_frame.
__gshared bool redrawWanted;

/// Reread the shown bytes through the held handles and redraw everything, like
/// ddhx's refresh (Ctrl+L). Edits and undo stay.
/// NOTE: Misses size changes and files replaced on disk. A reload command would
///       need a new handle and a fresh editor.
public void ui_refresh()
{
    redrawWanted = true;
    foreach (Document* d; docs)
    {
        if (d.editor is null)
            continue;
        ++d.revision;
        structureEdited(d, 0);
    }
}

/// Save the focused document. With a path: write, return success. Without:
/// open Save As and return false (written later).
public bool ui_save()
{
    if (ui_on_settings())
        return false;
    Document doc = focusedDoc();
    if (doc.path.length)
        return saveTo(doc, doc.path);

    ui_save_as();
    return false;
}

/// Save As dialog, async: ui_on_save_picked stores the path, the next frame
/// writes and adopts it.
public void ui_save_as()
{
    if (ui_on_settings())
        return;
    pendingSaveTarget = focusedDoc.editor;
    ui_file_dialog(&ui_on_save_picked, true);
}

/// Write the Save As target document to `dest` and adopt the path. Found by
/// editor, not tab index, since tabs may move. Dropped if it was closed.
void ui_save_pending(string dest)
{
    foreach (Document* d; docs)
    {
        if (d.editor !is pendingSaveTarget)
            continue;

        // Refuse saving onto a file open in another tab: two documents on one path
        // (separate undo, bookmarks) and its unsaved edits would conflict.
        Document* held = ui_find_document(dest);
        if (held && held !is d)
        {
            ui_status("%s is open in another tab; close it first",
                ui_clip(baseName(dest), 40));
            logWarn("save as: %s is already open as another document", dest);
            return;
        }

        // Disk copies are snapshots; the tab stays on the disk.
        if (saveTo(*d, dest) && ui_fixed(d) == false)
        {
            d.path  = dest;
            d.title = baseName(dest);
        }
        return;
    }
    logWarn("save as: the document was closed before a destination was chosen");
}

/// Copy size limit; hex text is 3 chars per byte (~48 MB). Larger is refused.
enum COPY_MAX = 16 * 1024 * 1024;

/// Copy/Cut range in `v`, clamped. A bare caret is one byte (like Delete).
/// Returns: False if nothing to act on (no document, no caret, caret past the
///          end).
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

/// Copy the selection as lowercase hex text, wrapped at the column count:
/// ---
/// de ad be ef ...
/// ---
/// ui_paste reads it back.
/// Returns: Whether it reached the clipboard (ui_cut only removes on success).
public bool ui_copy()
{
    if (ui_on_settings())
        return false;
    return copySelection(false);
}

/// Copy the selection as the text lane shows it (unmapped bytes as dots).
/// Unwrapped. Lossy, so ui_paste only accepts hex.
public bool ui_copy_text()
{
    if (ui_on_settings())
        return false;
    return copySelection(true);
}

/// Ditto. `asText` selects the format.
bool copySelection(bool asText)
{
    size_t low, high;
    if (ui_selection(focusedView, low, high) == false)
        return false;

    size_t len = high - low + 1;
    if (len > COPY_MAX)
    {
        logWarn("copy refused: %s bytes selected, over the %s byte limit", len, COPY_MAX);
        return false;
    }

    static immutable string digits = "0123456789abcdef";
    int cols = focusedView.hex.columns > 0 ? focusedView.hex.columns : 16;
    Appender!(char[]) text = appender!(char[]);
    text.reserve(len * 3 + 1); // terminator; glyphs can be 3 bytes

    // Chunked: selections can be large.
    ubyte[64 * 1024] buffer = void;
    size_t done;
    while (done < len)
    {
        size_t want = len - done;
        if (want > buffer.length) want = buffer.length;
        ubyte[] chunk = focusedDoc.editor.view(cast(long)(low + done), buffer[0 .. want]);
        if (chunk.length == 0)
            break; // avoid spinning
        foreach (i, ubyte b; chunk)
        {
            if (asText)
            {
                // Document charset, as drawn.
                const(char)[] glyph = focusedDoc.charset.glyph(b);
                if (glyph.length)
                    text.put(glyph);
                else
                    text.put('.');
                continue;
            }
            size_t at = done + i;
            if (at)
                text.put(at % cols == 0 ? '\n' : ' '); // rows like the panel
            text.put(digits[b >> 4]);
            text.put(digits[b & 0x0f]);
        }
        done += chunk.length;
    }
    text.put('\0'); // C string

    if (SDL_SetClipboardText(text.data.ptr) == false)
    {
        logError("copy failed: %s", SDL_GetError().fromStringz);
        return false;
    }
    logDebugging("copied %s byte(s) from %#x%s", done, low, asText ? " as text" : "");
    // Report characters, so the user can tell the copy happened.
    if (asText)
        ui_status("Copied %s character%s", done, done == 1 ? "" : "s");
    return true;
}

/// Copy, then remove the bytes only if the copy succeeded. A bare caret cuts
/// one byte.
public void ui_cut()
{
    if (ui_on_settings())
        return;
    cutSelection(false);
}

/// Cut, putting the text form on the clipboard (Ctrl+Shift+C plus removal).
/// Can't be pasted back; see ui_copy_text.
public void ui_cut_text()
{
    if (ui_on_settings())
        return;
    cutSelection(true);
}

/// Ditto.
void cutSelection(bool asText)
{
    Document* doc = &focusedDoc();
    View* view = &focusedView();
    if (ui_refuse_edit(doc))
        return;
    size_t low, high;
    if (ui_selection(*view, low, high) == false)
        return;
    if (copySelection(asText) == false)
        return;

    try
        doc.editor.remove(cast(long) low, cast(long)(high - low + 1));
    catch (Exception e)
    {
        logError("cut failed: %s", e.msg);
        return;
    }
    ++doc.revision;
    structureEdited(doc, cast(long) low);
    bookmark_shift(doc.marks, cast(long) low, -cast(long)(high - low + 1));

    view.hex.dataSize = doc.editor.size();
    hex_set_caret(view.hex, low); // caret at the gap
}

/// Paste hex text at the caret.
///
/// Accepts ui_copy's format and variants: whitespace, commas, semicolons and
/// colons separate; 0x prefixes are skipped ("de ad", "DEAD", "0xde, 0xad").
/// Tokens must be whole bytes, else the paste is refused.
///
/// Overwrite replaces (growing past EOF), insert splices. A multi-byte
/// selection is replaced in either mode.
public void ui_paste()
{
    if (ui_on_settings())
        return;
    Document* doc = &focusedDoc();
    View* view = &focusedView();
    if (doc.editor is null || ui_refuse_edit(doc))
        return;

    char* clip = SDL_GetClipboardText(); // caller frees; empty string on failure
    if (clip is null)
    {
        logError("paste failed: %s", SDL_GetError().fromStringz);
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
    if (low > total) low = total;   // stale caret after an outside change
    if (high > total) high = total;
    long pos = cast(long) low;

    bool ok;
    try
    {
        // Remove the selection, then insert. Two history entries, so two undos.
        bool replacing = high > low;
        if (replacing)
        {
            long cut = cast(long)(high - low + 1);
            if (high >= total) cut = cast(long) total - pos; // exclude the append slot
            if (cut > 0)
            {
                editor.remove(pos, cut);
                bookmark_shift(doc.marks, pos, -cut);
            }
            else replacing = false;
        }
        // Past EOF: append regardless of mode.
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
        logError("paste failed: %s", e.msg);

    // Refresh even on failure; the remove may have happened.
    ++doc.revision;
    structureEdited(doc, pos);
    view.hex.dataSize = editor.size();
    hex_set_caret(view.hex, ok ? low + bytes.length : low);
    if (ok)
        logDebugging("pasted %s byte(s) at %#x", bytes.length, low);
}

/// Parse clipboard hex text. Null unless the whole text is separated hex pairs
/// (no partial pastes). Formats: see ui_paste.
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

        // Optional 0x, then digit pairs.
        if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X') && hex_nibble(p[2]) >= 0)
            p += 2;

        size_t pairs;
        while (hex_nibble(*p) >= 0)
        {
            int hi = hex_nibble(*p++);
            int lo = hex_nibble(*p);
            if (lo < 0)
                return null; // lone digit
            ++p;
            bytes.put(cast(ubyte)((hi << 4) | lo));
            ++pairs;
        }
        if (pairs == 0)
            return null; // not a hex dump
    }
    return bytes.data;
}

unittest
{
    assert(parseHexText("de ad be ef") == [ 0xde, 0xad, 0xbe, 0xef ]);
    assert(parseHexText("DEADBEEF")    == [ 0xde, 0xad, 0xbe, 0xef ]);
    assert(parseHexText("0xde, 0xAD")  == [ 0xde, 0xad ]); // C-style
    assert(parseHexText("de ad\nbe ef") == [ 0xde, 0xad, 0xbe, 0xef ]);
    assert(parseHexText("de:ad;be")    == [ 0xde, 0xad, 0xbe ]);
    assert(parseHexText("  ").length == 0);
    assert(parseHexText("").length == 0);
    assert(parseHexText("de a") is null);       // half a byte
    assert(parseHexText("dead beefs") is null); // past 'f'
    assert(parseHexText("hello") is null);
    assert(parseHexText("0x") is null);       // prefix only
}

/// Undo or redo (`redo`) on the focused document, caret following. For menu and
/// omnibar routes, which take focus from the panel; uses the panel's hooks.
public void ui_undo(bool redo)
{
    if (ui_on_settings())
        return;
    Document *doc = &focusedDoc();
    if (doc.editor is null || ui_refuse_edit(doc))
        return;

    View *view = &focusedView();
    void* user = cast(void*) view;
    long at = redo ? hexRedo(user) : hexUndo(user);
    if (at < 0)
    {
        ui_status(redo ? "nothing to redo" : "nothing to undo");
        return;
    }
    hex_set_caret(view.hex, cast(size_t) at);
}

/// Unsaved-changes prompt result.
enum Confirm { proceed, cancel }

/// Prompt button ids, distinct from the -1 sentinel.
enum { btnSave = 1, btnDontSave = 2, btnCancel = 3 }

version (Screenshots)
{
    /// Scripted answer for unsaved-changes prompts. `ask` (default) shows the
    /// native box.
    public enum ConfirmAuto { ask, discard, keep }

    /// Set by the headless driver.
    public __gshared ConfirmAuto uiConfirmAuto;

    /// Scripted answer for file dialogs, via their callbacks. Empty: native dialog.
    public __gshared string uiPickAuto;
}

/// Resolve unsaved edits in `doc` before discarding (last view closed, quit).
/// No edits: proceed. Otherwise bring it to front and show Save / Don't Save /
/// Cancel titled `title`.
/// Returns: Confirm.proceed to continue; Confirm.cancel on cancel, pending
///          save, or prompt failure (fail safe).
Confirm ui_confirm_discard(Document* doc, const(char)* title)
{
    if (doc is null)
        return Confirm.proceed;
    if ((doc.editor && doc.editor.edited()) == false)
        return Confirm.proceed;

    ui_focus_document(doc);

    // Focus still changes, matching a real run; only the native box is skipped.
    version (Screenshots)
        if (uiConfirmAuto != ConfirmAuto.ask)
            return uiConfirmAuto == ConfirmAuto.discard ? Confirm.proceed : Confirm.cancel;

    static immutable SDL_MessageBoxButtonData[3] buttons = [
        { SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT, btnSave,     "Save" },
        { cast(SDL_MessageBoxButtonFlags) 0,       btnDontSave, "Don't Save" },
        { SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT, btnCancel,   "Cancel" },
    ];
    // Name the document; there may be several tabs.
    string message = format("%s has unsaved changes.", doc.title);
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
    default:          return Confirm.cancel; // Cancel, or closed
    }
}

/// Resolve unsaved edits before quitting; true to proceed. Called on every quit
/// route. Asks per document (not tab); the first cancel stops.
public bool ui_may_quit()
{
    foreach (Document* d; docs)
        if (ui_confirm_discard(d, "Quit vddhx") != Confirm.proceed)
            return false;
    return true;
}

/// Omnibar command or shortcut sheet row: name, keys, and command code.
struct Entry
{
    string label;
    string keys;
    int id = -1;

    /// Hidden search terms: names from other editors ("diff", "vsplit"). Kept
    /// English if labels get translated.
    string keywords;
}

/// Disk listing only where disks_list supports it; else a typed path.
enum string OPEN_DEVICE_LABEL = DISKS_LISTED ? "Open Disk..." : "Open Path...";

/// Omnibar '>' commands: the menu actions. ddhx document commands join as
/// ddhx exposes them.
enum
{
    CMD_NEW_TAB, CMD_OPEN, CMD_OPEN_DEVICE, CMD_COMPARE, CMD_COMPARE_STOP, CMD_DIFF_NEXT, CMD_DIFF_PREV,
    CMD_SAVE, CMD_SAVE_AS,
    CMD_CLOSE_TAB, CMD_READONLY, CMD_REFRESH,
    CMD_UNDO, CMD_REDO, CMD_CUT, CMD_CUT_TEXT, CMD_COPY, CMD_COPY_TEXT, CMD_PASTE,
    CMD_REPLACE, CMD_INSERT, CMD_REPLACE_RANGE, CMD_INSERT_RANGE, CMD_GOTO, CMD_SELECT_RANGE,
    CMD_FIND, CMD_FIND_BACK, CMD_FIND_NEXT, CMD_FIND_PREV, CMD_MARK_ALL, CMD_INSPECT, CMD_STRUCTURE,
    CMD_SKIP_NEXT, CMD_SKIP_PREV, CMD_SKIP_SEL_NEXT, CMD_SKIP_SEL_PREV,
    CMD_MARK, CMD_MARK_NAME, CMD_MARK_NEXT, CMD_MARK_PREV, CMD_MARK_LIST, CMD_MARK_CLEAR,
    CMD_MARK_LOAD, CMD_MARK_SAVE,
    CMD_SPLIT, CMD_SPLIT_DOWN, CMD_CLOSE_PANE, CMD_PANE_NEXT, CMD_PANE_PREV,
    CMD_ZOOM_IN, CMD_ZOOM_OUT, CMD_ZOOM_RESET,
    CMD_MINIMAP, CMD_CRUMBS, CMD_ENDIAN, CMD_COLUMNS, CMD_CHARSET, CMD_ADDRESS,
    CMD_SETTINGS, CMD_KEYS, CMD_ABOUT, CMD_QUIT,
}

/// Ditto.
immutable Entry[] COMMANDS = [
    Entry("New Tab",          "Ctrl+T",       CMD_NEW_TAB,      "create buffer"),
    Entry("Open File...",     "Ctrl+O",       CMD_OPEN,         "load edit read"),
    Entry(OPEN_DEVICE_LABEL,  "",             CMD_OPEN_DEVICE,  "disk drive device volume partition physical raw block path type"),
    Entry("Compare With...",  "",             CMD_COMPARE,      "diff difference against versus changes"),
    Entry("Stop Comparing",   "",             CMD_COMPARE_STOP, "undiff end diff close comparison"),
    Entry("Next Difference",  "}",            CMD_DIFF_NEXT,    "diff compare change hunk forward"),
    Entry("Previous Difference","{",          CMD_DIFF_PREV,    "diff compare change hunk back backward"),
    Entry("Save",             "Ctrl+S",       CMD_SAVE,         "write store commit"),
    Entry("Save As...",       "Ctrl+Shift+S", CMD_SAVE_AS,      "write export copy to"),
    Entry("Close Tab",        "Ctrl+W",       CMD_CLOSE_TAB,    "shut document"),
    Entry("Toggle Read-Only", "",             CMD_READONLY,     "readonly lock unlock writable allow editing restricted protect elevate admin root"),
    Entry("Refresh",          "Ctrl+L",       CMD_REFRESH,      "reread redraw repaint disk changed outside"),
    Entry("Undo",             "Ctrl+Z",       CMD_UNDO,         "back revert history step"),
    Entry("Redo",             "Ctrl+Y",       CMD_REDO,         "forward again history step"),
    Entry("Cut",              "Ctrl+X",       CMD_CUT,          "clipboard remove delete"),
    Entry("Cut as Text",      "Ctrl+Shift+X", CMD_CUT_TEXT,     "clipboard remove delete ascii string chars characters column lane"),
    Entry("Copy",             "Ctrl+C",       CMD_COPY,         "clipboard yank hex"),
    Entry("Copy as Text",     "Ctrl+Shift+C", CMD_COPY_TEXT,    "clipboard yank ascii string chars characters column lane"),
    Entry("Paste",            "Ctrl+V",       CMD_PASTE,        "clipboard insert put"),
    Entry("Replace...",       "",             CMD_REPLACE,      "fill overwrite pattern stamp repeat"),
    Entry("Insert...",        "",             CMD_INSERT,       "add splice pattern repeat"),
    Entry("Replace Range...", "",             CMD_REPLACE_RANGE,"fill overwrite pattern stamp repeat span"),
    Entry("Insert Range...",  "",             CMD_INSERT_RANGE, "add splice pattern repeat span"),
    Entry("Go to Offset...",  "Ctrl+G",       CMD_GOTO,         "goto jump seek address position"),
    Entry("Find...",          "Ctrl+F",       CMD_FIND,         "search grep pattern bytes string"),
    Entry("Find Backward...", "Ctrl+Shift+F", CMD_FIND_BACK,    "search grep pattern back backward reverse"),
    Entry("Find Next",        "Ctrl+N",       CMD_FIND_NEXT,    "search again forward"),
    Entry("Find Previous",    "Ctrl+Shift+N", CMD_FIND_PREV,    "search back backward"),
    Entry("Bookmark All Matches...","",       CMD_MARK_ALL,     "find search mark every each highlight count occurrences"),
    Entry("Inspect Bytes...", "Alt+I",        CMD_INSPECT,      "data types decode value integer float"),
    Entry("Go to Field...",   "",             CMD_STRUCTURE,    "structure layout chunk record section symbol header"),
    Entry("Skip Forward",     "Ctrl+Right",   CMD_SKIP_NEXT,    "run element next word"),
    Entry("Skip Back",        "Ctrl+Left",    CMD_SKIP_PREV,    "run element previous word"),
    Entry("Select Run Forward","Ctrl+Shift+Right", CMD_SKIP_SEL_NEXT, "skip selection extend next padding"),
    Entry("Select Run Back",  "Ctrl+Shift+Left",  CMD_SKIP_SEL_PREV, "skip selection extend previous padding"),
    Entry("Select Range...",  "",             CMD_SELECT_RANGE, "selection mark span offset length start end"),
    Entry("Toggle Bookmark",  "Ctrl+B",       CMD_MARK,         "mark set flag"),
    Entry("Name Bookmark...", "Ctrl+Shift+B", CMD_MARK_NAME,    "mark label rename annotate tag comment field"),
    Entry("Next Bookmark",    "]",            CMD_MARK_NEXT,    "mark forward"),
    Entry("Previous Bookmark","[",            CMD_MARK_PREV,    "mark back backward"),
    Entry("Bookmarks...",     "",             CMD_MARK_LIST,    "marks list show all"),
    Entry("Clear Bookmarks",  "",             CMD_MARK_CLEAR,   "marks remove delete none"),
    Entry("Load Bookmarks...","",             CMD_MARK_LOAD,    "marks open import read file ddhx"),
    Entry("Save Bookmarks...","",             CMD_MARK_SAVE,    "marks write export file ddhx"),
    Entry("Split Pane Right", "Ctrl+\\",      CMD_SPLIT,        "vsplit vertical side view new second"),
    Entry("Split Pane Down",  "Ctrl+Shift+\\",CMD_SPLIT_DOWN,   "hsplit horizontal below view new second"),
    Entry("Close Pane",       "",             CMD_CLOSE_PANE,   "unsplit remove"),
    Entry("Next Pane",        "",             CMD_PANE_NEXT,    "forward switch go"),
    Entry("Previous Pane",    "",             CMD_PANE_PREV,    "back backward switch go"),
    Entry("Zoom In",          "Ctrl+=",       CMD_ZOOM_IN,      "font text size bigger larger increase magnify"),
    Entry("Zoom Out",         "Ctrl+-",       CMD_ZOOM_OUT,     "font text size smaller decrease shrink"),
    Entry("Reset Zoom",       "Ctrl+0",       CMD_ZOOM_RESET,   "font text size default normal actual restore"),
    Entry("Toggle Minimap",   "",             CMD_MINIMAP,      "ribbon overview scrollbar sidebar"),
    Entry("Toggle Breadcrumbs","",            CMD_CRUMBS,       "crumbs path field structure format layout trail"),
    Entry("Toggle Byte Order","",             CMD_ENDIAN,       "endian endianness little big le be swap order inspector pattern"),
    Entry("Columns...",       "",             CMD_COLUMNS,      "width row bytes per line wrap 8 16 24 32 auto fit resize"),
    Entry("Character Set...", "",             CMD_CHARSET,      "charset encoding text lane ascii cp437 ibm dos oem ebcdic mainframe mac roman latin1 iso 8859 win1252 windows"),
    Entry("Offset Format...", "",             CMD_ADDRESS,      "address offsets base radix hex hexadecimal dec decimal oct octal"),
    Entry("Settings",         "",             CMD_SETTINGS,     "preferences options configure defaults rc vddhxrc"),
    Entry("Keyboard Shortcuts...", "",        CMD_KEYS,          "keys chords bindings help cheat sheet"),
    Entry("About vddhx",      "",             CMD_ABOUT,        "version credits license help"),
    Entry("Quit",             "Ctrl+Q",       CMD_QUIT,         "exit leave"),
];

/// '?' sheet head: omnibar prefixes, from the omnibar's enums so they can't
/// drift.
immutable Entry[] PREFIXES = [
    Entry("Omnibar: go to an open view",     "(no prefix)"),
    Entry("Omnibar: run a command",          "" ~ OMNI_COMMAND),
    Entry("Omnibar: go to an offset",        "" ~ OMNI_ADDRESS),
    Entry("Omnibar: find a pattern",         "" ~ OMNI_FIND),
    Entry("Omnibar: inspect bytes at caret", "" ~ OMNI_INSPECT),
    Entry("Omnibar: list bookmarks",         "" ~ OMNI_BOOKMARK),
    Entry("Omnibar: go to a field",          "" ~ OMNI_STRUCTURE),
    Entry("Omnibar: this sheet",             "" ~ OMNI_HELP),
    Entry("Omnibar: fill in the row's word", "Tab"),
];

/// '?' sheet: all shortcuts (omnibar, window, caret and bytes). Display only.
immutable Entry[] SHORTCUTS = [
    Entry("Omnibar",                        "Ctrl+E"),
    Entry("Omnibar, on commands",           "Ctrl+Shift+P"),
    Entry("Omnibar, on an offset",          "Ctrl+G"),
    Entry("Take a row / bring it here",     "Enter / Shift+Enter"),
    Entry("Close the omnibar",              "Esc"),
    Entry("New tab",                        "Ctrl+T"),
    Entry("Open file",                      "Ctrl+O"),
    Entry("Save",                           "Ctrl+S"),
    Entry("Save as",                        "Ctrl+Shift+S"),
    Entry("Close tab",                      "Ctrl+W"),
    Entry("Redraw screen",                  "Ctrl+L"),
    Entry("Next / previous tab",            "Ctrl+Tab / Ctrl+Shift+Tab"),
    Entry("Split the pane",                 "Ctrl+\\"),
    Entry("Go to pane 1, 2, 3...",          "Ctrl+1 .. Ctrl+9"),
    Entry("Go to tab 1, 2, 3...",           "Alt+1 .. Alt+9"),
    Entry("Quit",                           "Ctrl+Q"),
    Entry("Find",                           "Ctrl+F"),
    Entry("Find backward",                  "Ctrl+Shift+F"),
    Entry("Find the other way, in the box", "Shift+Enter"),
    Entry("Find next / previous",           "Ctrl+N / Ctrl+Shift+N"),
    Entry("Inspect bytes at the caret",     "Alt+I"),
    Entry("Text size bigger / smaller",     "Ctrl+= / Ctrl+-"),
    Entry("Text size back to the setting",  "Ctrl+0"),
    Entry("Toggle bookmark",                "Ctrl+B"),
    Entry("Name the bookmark at the caret", "Ctrl+Shift+B"),
    Entry("Next / previous bookmark",       "] / ["),
    Entry("Cut / copy / paste bytes",       "Ctrl+X / C / V"),
    Entry("Cut / copy the selection as text", "Ctrl+Shift+X / Ctrl+Shift+C"),
    Entry("Undo / redo",                    "Ctrl+Z / Ctrl+Y"),
    Entry("Move the caret",                 "Arrows"),
    Entry("Skip the run under the caret",   "Ctrl+Left / Ctrl+Right"),
    Entry("Select that run instead",        "Ctrl+Shift+Left / Ctrl+Shift+Right"),
    Entry("Extend the selection",           "Shift+Arrows"),
    Entry("Row start / row end",            "Home / End"),
    Entry("File start / file end",          "Ctrl+Home / Ctrl+End"),
    Entry("Page up / page down",            "PgUp / PgDn"),
    Entry("Overwrite or insert",            "Insert"),
    Entry("Delete a byte, back / forward",  "Backspace / Delete"),
    Entry("Type a byte",                    "0-9 a-f"),
];

/// Whether the omnibar has the keyboard; main checks before routing keys.
public bool ui_omni_active()
{
    return omni_shown(omni);
}

/// Toggle the omnibar on `prefix`'s mode (see omni_toggle). Ctrl+E,
/// Ctrl+Shift+P.
public void ui_omni_toggle(char prefix = 0)
{
    findGoal = FindGoal.next;
    omni_toggle(omni, prefix);
    if (omni_shown(omni) == false)
        focusedView.hex.takeFocus = true; // typing returns to the bytes
}

/// Open the omnibar on `prefix`'s mode without toggling. For menu items, so a
/// second click doesn't close it.
public void ui_omni_open(char prefix)
{
    findGoal = FindGoal.next;
    omni_show(omni, prefix);
}

/// Close the omnibar (Esc).
public void ui_omni_close()
{
    if (omni_shown(omni) == false)
        return;
    omni_hide(omni);
    focusedView.hex.takeFocus = true;
}

/// Omnibar rows for the current mode, rebuilt per frame.
const(OmniItem)[] ui_omni_items()
{
    rowUsed = 0; // reuse the arena
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
        // One row per view (one file in two panes is two places). Detail shows the
        // pane number (what Ctrl+1..9 takes) when split, else the path; the path is
        // matched either way. Row ids index omniTabs (pane + tab).
        size_t at;
        bool split = ui_pane_count() > 1;
        foreach (Column* c; columns)
        {
            foreach (Pane* p; c.panes)
            {
                foreach (size_t ti, View* v; p.views)
                {
                    if (at >= omniTabs.length)
                        omniTabs.length = at + 16;
                    omniTabs[at] = OmniTab(p, ti);

                    string path = v.doc.path.length ? v.doc.path : "not saved yet";
                    string detail = path;
                    if (split)
                    {
                        char[32] where = void;
                        size_t used = sformat(where, "pane %s",
                            ui_ordinal(ui_pane_index(p) + 1)).length;
                        // Mark the current tab.
                        if (p is focused && ti == p.current)
                            used += sformat(where[used .. $], "  here").length;
                        detail = ui_row_text(where[0 .. used]);
                    }

                    put(v.doc.title, detail, cast(int) at,
                        v.doc.editor && v.doc.editor.edited(), false, path);
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
        // Pinned readout of the offset; not filtered.
        string label, detail;
        ui_goto_preview(label, detail);
        put(label, detail, 0, false, true);
        break;
    case OmniMode.find:
        // Pinned readout of the pattern bytes. No search per frame.
        string flabel, fdetail;
        if (ui_find_preview(flabel, fdetail))
        {
            put(flabel, fdetail, FIND_RUN, false, true);
            break;
        }
        // No pattern yet: list prefixes, narrowed as typed. After a prefix, the
        // readout's "not yet" row stands instead.
        const(char)[] word = ui_find_word();
        if (search_prefixed(word))
        {
            put(flabel, fdetail, FIND_RUN, false, true);
            break;
        }
        // Pinned: matched by prefix here; the box's fuzzy ranking would misorder them.
        foreach (int i; 0 .. cast(int) SEARCH_PREFIXES.length)
            if (ui_find_offers(SEARCH_PREFIXES[i].text, word))
                put(SEARCH_PREFIXES[i].text, SEARCH_PREFIXES[i].what, i, false, true);
        if (n == 0)
            put("no prefix starts with that", "Esc to give up on it", FIND_RUN, false, true);
        break;
    case OmniMode.inspect:
        ubyte[8] raw = void;
        ubyte[] bytes = ui_inspect_bytes(raw);
        char[64] value = void;
        foreach (int i; 0 .. cast(int) INSPECT.length)
            put(ui_inspect_row(i).label,
                ui_row_text(ui_inspect_value(i, bytes, value)), i);
        break;
    case OmniMode.bookmark:
        if (focusedDoc.marks.length == 0)
        {
            put("no bookmarks in this document", "Ctrl+B marks the selection",
                -1, false, true);
            break;
        }
        // Row id is the list index (offsets overflow int).
        foreach (size_t i, ref Bookmark mark; focusedDoc.marks)
        {
            char[48] head = void;
            size_t used = sformat(head, "%s", ui_offset(mark.at, true)).length;
            if (mark.length > 1)
                used += sformat(head[used .. $], " .. %s",
                    ui_offset(mark.at + mark.length - 1, true)).length;
            string bytes = ui_bookmark_bytes(mark);
            if (mark.name.length == 0)
            {
                put(ui_row_text(head[0 .. used]), bytes, cast(int) i);
                continue;
            }
            // Named marks show the name, with the address in the detail; both searchable
            // ("@magic", "@1f40").
            char[128] detail = void;
            put(mark.name,
                ui_row_text(sformat(detail, "%s  %s", ui_offset(mark.at, true), bytes)),
                cast(int) i, false, false, ui_row_text(head[0 .. used]));
        }
        break;
    case OmniMode.structure:
        bool whole;
        const(StructureSpan)[] spans = structure_spans(focusedDoc.structure, STRUCT_ROWS, whole);
        if (spans.length == 0)
        {
            put(structure_name(focusedDoc.structure).length ?
                    "nothing parsed in this document" : "no structure for this document",
                "PNG is the only format read so far", -1, false, true);
            break;
        }
        // Role as a hidden keyword ("#checksum" finds CRC); the colour already shows
        // it.
        foreach (size_t i, ref const(StructureSpan) s; spans)
        {
            char[128] path = void;
            char[64] where = void;
            put(ui_row_text(spanLabel(spans, i, path)),
                ui_row_text(sformat(where, "%s  %d byte%s", ui_offset(s.at, true), s.length,
                    s.length == 1 ? "" : "s")),
                cast(int) i, false, false, structure_role_name(s.role));
        }
        // Truncated: say so. Unpinned, so it sorts last and filters out with typing.
        if (whole == false)
        {
            const(StructureSpan) last = spans[$ - 1];
            char[64] far = void;
            put(ui_row_text(sformat(far, "%d fields, and more past %s",
                    spans.length, ui_offset(last.at + last.length, true))), null, -1);
        }
        break;
    case OmniMode.prompt:
        // Rows by prompt kind.
        final switch (promptKind)
        {
        case PromptKind.markName:
            string plabel, pdetail;
            ui_mark_name_preview(plabel, pdetail);
            put(plabel, pdetail, 0, false, true);
            break;
        case PromptKind.columns:
            ui_columns_rows(&put);
            break;
        case PromptKind.charset:
            ui_charset_rows(&put);
            break;
        case PromptKind.address:
            ui_address_rows(&put);
            break;
        case PromptKind.openDevice:
            ui_device_rows(&put);
            break;
        case PromptKind.write:
            string wlabel, wdetail;
            ui_write_preview(wlabel, wdetail);
            put(wlabel, wdetail, 0, false, true);
            break;
        case PromptKind.select:
            string slabel, sdetail;
            ui_select_preview(slabel, sdetail);
            put(slabel, sdetail, 0, false, true);
            break;
        }
        break;
    case OmniMode.help:
        // Prefixes, then chords; stable sort keeps the order unfiltered.
        foreach (ref immutable Entry e; PREFIXES)
            put(e.label, e.keys, e.id);
        foreach (ref immutable Entry e; SHORTCUTS)
            put(e.label, e.keys, e.id);
        break;
    }
    return omniItems[0 .. n];
}

/// Caret state before a '#' browse, restored if it's cancelled. One at a time
/// (the box has the keyboard).
struct Preview
{
    View* view;
    size_t cursor;
    size_t anchor;
    long topRow;

    /// Caret as last set by the preview. If it differs when the box closes, the
    /// user moved it (e.g. clicked the grid): keep it.
    size_t setCursor;
    size_t setAnchor;

    bool active;
}
/// Ditto.
__gshared Preview preview;

/// Move the caret along the '#' list as rows are highlighted; Enter confirms.
/// Centred below the box, since a minimal reveal would land under it.
void ui_struct_preview(OmniMode mode)
{
    if (mode != OmniMode.structure || ui_omni_active() == false)
    {
        ui_preview_restore(); // mode changed or box closed
        return;
    }

    if (preview.active == false)
    {
        View* v = focused.views[focused.current];
        preview = Preview(v, v.hex.cursor, v.hex.anchor, hex_top(v.hex),
            v.hex.cursor, v.hex.anchor, true);
    }

    int id = omni_current(omni);
    bool whole;
    const(StructureSpan)[] spans = structure_spans(focusedDoc.structure, STRUCT_ROWS, whole);
    if (id < 0 || id >= spans.length || spans[id].length <= 0)
        return;

    mu_Rect box = omni_rect(omni);
    ui_select_range(focusedView, cast(size_t) spans[id].at, cast(size_t) spans[id].length);
    hex_center(focusedView.hex, cast(size_t) spans[id].at, box.y + box.h);
    preview.setCursor = focusedView.hex.cursor;
    preview.setAnchor = focusedView.hex.anchor;
}

/// Restore the caret from before the browse, unless moved since. No-op without
/// a browse.
void ui_preview_restore()
{
    if (preview.active == false)
        return;

    View* v = preview.view;
    if (v.hex.cursor == preview.setCursor && v.hex.anchor == preview.setAnchor)
    {
        v.hex.cursor = preview.cursor;
        v.hex.anchor = preview.anchor;
        hex_set_top(v.hex, preview.topRow);
    }
    preview = Preview.init;
}

/// Ditto, keeping the browse position (row taken).
void ui_preview_drop()
{
    preview = Preview.init;
}

/// Offset the ':' text resolves to against the focused document (see address).
Address ui_goto_target()
{
    return address_parse(omni_query(omni), cast(long) focusedView.hex.cursor,
        cast(long) hex_total(focusedView.hex));
}

/// Arena for computed row text (readouts, inspector values), avoiding per-row
/// allocations each frame. Only grows.
__gshared char[] rowArena;
/// Ditto.
__gshared size_t rowUsed;

/// Copy `text` into the arena; valid until the next frame's rows.
string ui_row_text(const(char)[] text)
{
    if (rowUsed + text.length > rowArena.length)
        rowArena.length = (rowUsed + text.length) * 2 + 256;
    size_t at = rowUsed;
    rowArena[at .. at + text.length] = text;
    rowUsed += text.length;
    return cast(string) rowArena[at .. rowUsed];
}

/// ':' row text: target offset, or the syntax hint while invalid.
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
    size_t total = hex_total(focusedView.hex);
    label = ui_row_text(sformat(buf, "Go to %s", ui_offset(a.pos, true)));

    // Show the absolute offset and percentage.
    int percent = total ? cast(int)((a.pos * 100) / cast(long) total) : 0;
    if (a.clamped)
        detail = ui_row_text(sformat(buf,
            "%u, clamped to the document (%u bytes)", a.pos, total));
    else
        detail = ui_row_text(sformat(buf,
            "%u of %u bytes, %d%%", a.pos, total, percent));
}

/// The find box's parsed pattern. Cached across frames since the parser
/// allocates; reparsed only when the text changes.
bool ui_find_needle(out Needle needle)
{
    const(char)[] query = omni_query(omni);
    if (query.length > findText.length) // too long to cache
    {
        findTextLen = size_t.max;
        return search_parse(query, needle, focusedDoc.endian);
    }

    // Byte order affects the result: reparse on change.
    if (findTextLen != query.length || findEndian != focusedDoc.endian
        || findText[0 .. findTextLen] != query)
    {
        findTextLen = query.length;
        findEndian  = focusedDoc.endian;
        findText[0 .. findTextLen] = query;
        findHave = search_parse(query, findNeedle, findEndian);
    }
    needle = findNeedle;
    return findHave;
}

/// Row id for "run the search" (readout and notices). Other '/' ids index
/// SEARCH_PREFIXES; must not overlap.
enum int FIND_RUN = -1;

/// First query token, which must carry the prefix.
const(char)[] ui_find_word()
{
    const(char)[] query = omni_query(omni);
    size_t end;
    while (end < query.length && query[end] != ' ' && query[end] != '\t')
        ++end;
    return query[0 .. end];
}

/// Whether prefix `text` starts with the partial `word`, case-insensitively.
/// ddhx only accepts lowercase, which the row inserts.
bool ui_find_offers(const(char)[] text, const(char)[] word)
{
    if (word.length > text.length)
        return false;
    foreach (size_t i, char c; word)
        if (toLower(c) != text[i])
            return false;
    return true;
}

/// '/' readout: the pattern's bytes.
/// Returns: false if no pattern yet; `label`/`detail` then hold the notice.
bool ui_find_preview(out string label, out string detail)
{
    Needle needle;
    if (ui_find_needle(needle) == false)
    {
        // Name the prefix being typed; ddhx's parser doesn't say where it failed.
        immutable(SearchPrefix)* pfx = search_prefix_of(ui_find_word());
        label  = "not a pattern yet";
        detail = pfx ? pfx.what : "a pattern opens with what it is";
        return false;
    }

    // Bytes, '??' for any byte, '**' for a run, [min..max] for ranges. Truncated
    // here to keep the arena slice short.
    char[128] buf = void;
    size_t at;
    foreach (ushort element; needle.data[0 .. needle.length])
    {
        if (element == SEARCH_RANGE_TAIL)
            continue;
        char[48] word = void;
        const(char)[] text;
        if (element == SEARCH_ANY)
            text = "??";
        else if (element == SEARCH_RUN)
            text = "**";
        else if (element >= SEARCH_RANGE)
        {
            const(PatternRange)* range = &needle.ranges[element - SEARCH_RANGE];
            text = range.signed
                ? sformat(word, "[%d..%d]", cast(long) range.min, cast(long) range.max)
                : sformat(word, "[%u..%u]", range.min, range.max);
        }
        else
            text = sformat(word, "%02x", cast(ubyte) element);

        if (at + 1 + text.length > buf.length - 4) // @suppress(dscanner.suspicious.length_subtraction)
        {
            at += sformat(buf[at .. $], " ...").length;
            break;
        }
        if (at)
            buf[at++] = ' ';
        buf[at .. at + text.length] = text;
        at += text.length;
    }

    // With runs the count is a minimum; say so.
    size_t least = search_least(needle);
    char[64] count = void;
    label  = ui_row_text(buf[0 .. at]);
    string where = FIND_WHERE[findGoal];
    detail = ui_row_text(sformat(count, least == needle.length
        ? "%u byte(s), %s" : "%u byte(s) or more, %s", least, where));
    return true;
}

/// '=' row: a type and its byte order.
struct Inspect
{
    string label;
    InspectorType type;
    Endian endian;
}

/// '=' rows: single bytes once, other types in both orders. Both orders always
/// listed; the document setting only picks which comes first (ui_inspect_row).
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

/// INSPECT layout: singles, then one block per order, so a half can be indexed.
enum size_t INSPECT_SINGLES = 2;
enum size_t INSPECT_ORDERED = (INSPECT.length - INSPECT_SINGLES) / 2;
static assert(INSPECT.length == INSPECT_SINGLES + 2 * INSPECT_ORDERED);

/// Toggle the document's byte order. No message: the status bar shows it.
public void ui_endian_toggle()
{
    if (ui_on_settings())
        return;
    focusedDoc.endian = focusedDoc.endian == Endian.littleEndian
        ? Endian.bigEndian : Endian.littleEndian;
}

/// Show the settings tab, in the focused pane unless already open.
public void ui_settings_open()
{
    foreach (Document* d; docs)
    {
        if (d.settingsPage)
        {
            ui_focus_document(d);
            return;
        }
    }

    Document* d = newDocument();
    d.editor = new PieceV4DocumentEditor(true);
    d.title  = "Settings";
    d.restricted   = true;
    d.settingsPage = true;

    Pane* p = focused;
    p.views ~= newView(d);
    p.current = p.views.length - 1; // @suppress(dscanner.suspicious.length_subtraction)
}

/// Whether the focused tab is the settings page.
bool ui_on_settings()
{
    return focusedDoc.settingsPage;
}

/// Toggle window chrome; saved immediately like all settings.
public void ui_toggle_minimap()
{
    prefs.minimap = prefs.minimap == false;
    cast(void) prefs_save();
}
/// Ditto.
public void ui_toggle_crumbs()
{
    prefs.crumbs = prefs.crumbs == false;
    cast(void) prefs_save();
}

/// Font settings wait for the next frame start, see ui_fonts.
private __gshared bool fontsPending, fontsSave;

/// Apply prefs.font and prefs.monofont at the next frame start, then save
/// them if `save`. A saved font that fails to open is put back.
public void ui_fonts(bool save)
{
    fontsPending = true;
    fontsSave |= save;
    ui_wakeup();
}

/// Font picker for the UI (`mono` false) or hex panel font.
public void ui_font_dialog(bool mono)
{
    static immutable SDL_DialogFileFilter[1] filter = [
        SDL_DialogFileFilter("Fonts", "ttf;otf;ttc"),
    ];
    pendingPick = mono ? Pick.monofont : Pick.font;
    ui_file_dialog(&ui_on_file_picked, false, filter);
}

/// Open the pending font settings, see ui_fonts.
private void ui_fonts_apply()
{
    if (fontsPending == false)
        return;
    fontsPending = false;

    string*[2] specs = [ &prefs.font, &prefs.monofont ];
    foreach (size_t i, string* spec; specs)
    {
        bool mono = i == 1;
        if (render_set_font(mono, *spec))
            continue;
        ui_status("%s font not found: %s", mono ? "hex" : "UI", *spec);
        // Keep the file's value at startup: the font may come back.
        if (fontsSave)
            *spec = render_font_spec(mono);
    }

    if (fontsSave)
        cast(void) prefs_save();
    fontsSave = false;
}

/// Session zoom in points, on top of the saved text size.
private __gshared int zoom;

/// Grow (1) or shrink (-1) the text a point for this session, or go back to
/// the saved size (0). Also applies a changed saved size.
public void ui_zoom(int step)
{
    int pt = step ? prefs.fontsize + zoom + step : prefs.fontsize;
    if (pt < FONT_SIZE_MIN) pt = FONT_SIZE_MIN;
    if (pt > FONT_SIZE_MAX) pt = FONT_SIZE_MAX;
    zoom = pt - prefs.fontsize;
    render_set_size(pt);
    if (step)
        ui_status("text size %d pt", pt);
}

/// Set the document's charset (shared by its views). No message: the lane
/// header shows it.
public void ui_charset_set(immutable(Charset)* set)
{
    focusedDoc.charset = set;
}

/// Set the focused view's offset base. Per view like columns, splits inherit
/// it. No message: the menu and the lane headers show it.
public void ui_address_set(HexBase base)
{
    focusedView.hex.offsetBase = base;
}

/// Offset for labels and messages, formatted with `%s` in a view's base. Text
/// stays valid Go to input: 0x for hex, a leading zero for octal, so decimal
/// is never zero-padded.
struct Offset
{
    long at;        /// Document offset.
    HexBase base;   /// Base to print in.
    bool pad;       /// Zero-pad hex and octal to 8 digits.

    /// Write the text to `sink`.
    void toString(scope void delegate(const(char)[]) sink) const
    {
        import std.format : formattedWrite;
        final switch (base)
        {
        case HexBase.hex: sink.formattedWrite(pad ? "0x%08x" : "0x%x", at); break;
        case HexBase.dec: sink.formattedWrite("%d", at);                    break;
        case HexBase.oct: sink.formattedWrite(pad ? "0%08o" : "0%o", at);   break;
        }
    }
}

unittest
{
    char[32] buf = void;
    assert(sformat(buf, "%s", Offset(0x1f, HexBase.hex, true)) == "0x0000001f");
    assert(sformat(buf, "%s", Offset(0x1f, HexBase.hex)) == "0x1f");
    assert(sformat(buf, "%s", Offset(31, HexBase.dec, true)) == "31");
    assert(sformat(buf, "%s", Offset(31, HexBase.oct)) == "037");
    assert(sformat(buf, "%s", Offset(31, HexBase.oct, true)) == "000000037");
    assert(address_parse("037", 0, 64).pos == 31); // round-trips through Go to
}

/// `at` in the focused view's offset base, see Offset. `pad` for list rows.
Offset ui_offset(long at, bool pad = false)
{
    return Offset(at, focusedView.hex.offsetBase, pad);
}

/// Panel text lane hook; bound per frame in ui_pane to the document.
const(char)[] ui_charset_text(ubyte value, void* user)
{
    return (cast(const(Document)*) user).charset.glyph(value);
}

/// Set the focused view's bytes per row; 0 fits the pane. Per view (splits may
/// differ); splits inherit it.
/// Returns: False if out of range, view unchanged.
public bool ui_columns_set(int cols)
{
    if (cols < 0 || cols > HEX_COLUMNS_MAX)
        return false;

    focusedView.hex.autoColumns = cols == 0;
    if (cols > 0)
        focusedView.hex.columns = cols;
    return true;
}

/// Focused view's columns, 0 when auto.
int ui_columns()
{
    return focusedView.hex.autoColumns ? 0 : focusedView.hex.columns;
}

/// Width text for prompt rows. Arena-backed; see ui_columns_label for the
/// menu's copy.
string ui_columns_name(int cols)
{
    if (cols == 0)
        return "auto";

    char[8] buf = void;
    return ui_row_text(sformat(buf, "%d", cols));
}

/// Width text for the menu's shortcut column. Own buffer (the arena is reset
/// each frame), NUL-terminated for ddui.
const(char)* ui_columns_label()
{
    if (focusedView.hex.autoColumns)
        return "auto";

    __gshared char[8] buf;
    size_t n = sformat(buf[0 .. $ - 1], "%d", focusedView.hex.columns).length;
    buf[n] = 0;
    return buf.ptr;
}

/// Parse a columns prompt answer: a decimal count, or ddhx's auto keywords.
/// Decimal only, like ddhx's `columns`. Blank is invalid.
/// Returns: False if invalid, `cols` untouched.
bool ui_columns_parse(const(char)[] typed, out int cols)
{
    import std.conv : ConvException, to;

    const(char)[] text = strip(typed);
    if (text.length == 0)
        return false;

    // ddhx accepts both; "autoresize" is its option name.
    if (text == "auto" || text == "autoresize")
        return true; // auto is 0

    try
        cols = to!int(text);
    catch (ConvException)
        return false;

    return cols >= 0 && cols <= HEX_COLUMNS_MAX;
}

unittest
{
    int cols;
    assert(ui_columns_parse("16", cols) && cols == 16);
    assert(ui_columns_parse("  32  ", cols) && cols == 32);
    assert(ui_columns_parse("1", cols) && cols == 1);

    // Auto is 0, both names.
    cols = 99;
    assert(ui_columns_parse("auto", cols) && cols == 0);
    cols = 99;
    assert(ui_columns_parse("autoresize", cols) && cols == 0);
    // Typed zero too, like ddhx.
    assert(ui_columns_parse("0", cols) && cols == 0);

    assert(ui_columns_parse("", cols) == false);
    assert(ui_columns_parse("   ", cols) == false);
    assert(ui_columns_parse("wide", cols) == false);
    assert(ui_columns_parse("16 bytes", cols) == false);
    assert(ui_columns_parse("0x10", cols) == false); // decimal only
    assert(ui_columns_parse("-8", cols) == false);
    assert(ui_columns_parse("257", cols) == false);  // over HEX_COLUMNS_MAX
    assert(ui_columns_parse("999999999999", cols) == false); // over int
}

/// Inspector row at `index`, the document's order first.
ref immutable(Inspect) ui_inspect_row(int index)
{
    size_t at = index;
    if (focusedDoc.endian == Endian.bigEndian && at >= INSPECT_SINGLES)
        at = at < INSPECT_SINGLES + INSPECT_ORDERED ? at + INSPECT_ORDERED : at - INSPECT_ORDERED;
    return INSPECT[at];
}

/// Bytes for the inspector (widest type), from the selection start. Short reads
/// near EOF are fine (formatInspector shows "N/A").
ubyte[] ui_inspect_bytes(ubyte[] buf)
{
    if (focusedDoc.editor is null)
        return null;
    long total = cast(long) hex_total(focusedView.hex);
    long at = cast(long) hex_sel_low(focusedView.hex);
    if (at >= total)
        return null;
    // Whole only: a short read near EOF must come from the editor.
    if (const(ubyte)[] cached = hex_cached(focusedView.hex, cast(size_t) at, buf.length))
    {
        buf[] = cached[];
        return buf;
    }
    return focusedDoc.editor.view(at, buf);
}

/// Format one inspector row's value into `buf`.
const(char)[] ui_inspect_value(int index, ubyte[] bytes, char[] buf)
{
    if (index < 0 || index >= INSPECT.length)
        return null;
    immutable(Inspect) row = ui_inspect_row(index);
    return formatInspector(buf, row.type, bytes, row.endian);
}

/// Complete the highlighted row into the query (currently only '/' prefixes):
/// replaces the partial word, keeps the rest, box stays open. Tab always; Enter
/// falls back to running on other rows.
/// Returns: false if nothing to complete.
bool ui_omni_complete(OmniMode mode, int id)
{
    if (mode != OmniMode.find || id < 0 || id >= cast(int) SEARCH_PREFIXES.length)
        return false;

    // Own buffer: the tail slices the box text omni_refill overwrites. Sized for a
    // full box plus the longest prefix (sformat throws instead of truncating);
    // omni_refill trims.
    char[256] line = void;
    const(char)[] rest = omni_query(omni)[ui_find_word().length .. $];
    omni_refill(omni, sformat(line, "%s%s", SEARCH_PREFIXES[id].text, rest));
    return true;
}

/// Act on the taken row, in the mode its list was built for (a prefix typed
/// this frame only takes effect next frame). `transfer`: Shift, "bring here" in
/// the switcher, the other direction in find.
void ui_omni_accept(OmniMode mode, int id, bool transfer = false)
{
    final switch (mode)
    {
    case OmniMode.switcher:
        // Id indexes omniTabs (pane + tab).
        if (id < 0 || id >= omniTabs.length)
            break;
        Pane* from = omniTabs[id].pane;
        size_t tab = omniTabs[id].tab;
        // Transfer into the same pane is a plain jump.
        if (transfer && from !is focused)
            ui_move_view(from, tab, focused); // takes focus, like the jump
        else
            ui_select_tab_in(from, tab);
        break;
    case OmniMode.command:
        ui_omni_run(id);
        break;
    case OmniMode.address:
        // Reparse (offsets don't fit the int id). Invalid input just closes.
        Address a = ui_goto_target();
        if (a.ok)
        {
            hex_set_caret(focusedView.hex, cast(size_t) a.pos); // scrolls to it
            logDebugging("went to %#x", a.pos);
        }
        focusedView.hex.takeFocus = true;
        break;
    case OmniMode.find:
        // Prefix rows complete, like Tab.
        if (ui_omni_complete(mode, id))
            break;
        // Remember the pattern for Find Next. Search starts past the caret so repeats
        // advance.
        Needle needle;
        if (ui_find_needle(needle))
        {
            lastNeedle = needle;
            haveNeedle = true;
            final switch (ui_find_goal(transfer))
            {
            case FindGoal.next:
                ui_find_step(focusedView, false, cast(long) focusedView.hex.cursor + 1);
                break;
            case FindGoal.back:
                ui_find_step(focusedView, true, cast(long) hex_sel_low(focusedView.hex) - 1);
                break;
            case FindGoal.markAll:
                ui_mark_all();
                break;
            }
        }
        findGoal = FindGoal.next;
        focusedView.hex.takeFocus = true;
        break;
    case OmniMode.inspect:
        // No target: copy the value to the clipboard.
        ubyte[8] raw = void;
        char[64] buf = void;
        const(char)[] value = ui_inspect_value(id, ui_inspect_bytes(raw), buf);
        if (value.length && id >= 0)
        {
            char[80] clip = void;
            size_t n = sformat(clip, "%s\0", value).length;
            if (SDL_SetClipboardText(clip.ptr))
                ui_status("copied %s", ui_inspect_row(id).label);
            else
                logError("copy failed: %s", SDL_GetError().fromStringz);
        }
        focusedView.hex.takeFocus = true;
        break;
    case OmniMode.bookmark:
        if (id >= 0 && id < focusedDoc.marks.length)
            ui_mark_select(focusedView, id);
        focusedView.hex.takeFocus = true;
        break;
    case OmniMode.structure:
        // Id indexes the cached spans; no edits happened since the list was built.
        bool whole;
        const(StructureSpan)[] spans = structure_spans(focusedDoc.structure, STRUCT_ROWS, whole);
        if (id >= 0 && id < spans.length && spans[id].length > 0)
        {
            // Select the field, so the status bar shows its length.
            ui_select_range(focusedView, cast(size_t) spans[id].at, cast(size_t) spans[id].length);
            logDebugging("went to %s at %#x", spans[id].name, spans[id].at);
        }
        focusedView.hex.takeFocus = true;
        break;
    case OmniMode.prompt:
        // Name prompt: the text. Settings: the row (already previewed).
        final switch (promptKind)
        {
        case PromptKind.markName: ui_mark_name_commit(omni_query(omni)); break;
        case PromptKind.columns:  ui_columns_commit(id);                 break;
        case PromptKind.charset:
            if (id >= 0 && id < charsets.length)
                ui_charset_set(charsets[id]);
            break;
        case PromptKind.address:
            if (id >= 0 && id <= HexBase.max)
                ui_address_set(cast(HexBase) id);
            break;
        case PromptKind.openDevice:
            ui_device_commit(id);
            return; // opened tab has focus
        case PromptKind.write:    ui_write_commit(omni_query(omni));   break;
        case PromptKind.select:   ui_select_commit(omni_query(omni));  break;
        }
        focusedView.hex.takeFocus = true;
        break;
    case OmniMode.help:
        focusedView.hex.takeFocus = true; // read-only sheet
        break;
    }
}

/// Bookmark row detail: leading bytes in hex and text, plus the length if
/// longer.
string ui_bookmark_bytes(ref const(Bookmark) mark)
{
    if (focusedDoc.editor is null)
        return null;

    ubyte[8] raw = void;
    ubyte[] bytes = focusedDoc.editor.view(mark.at, raw);
    if (bytes.length == 0)
        return "past the end of the document";
    if (bytes.length > mark.length)
        bytes = bytes[0 .. cast(size_t) mark.length];

    // 8 bytes hex, the same as text (glyphs up to 3 bytes), then the length.
    char[96] buf = void;
    size_t n;
    foreach (ubyte b; bytes)
        n += sformat(buf[n .. $], "%02x ", b).length;
    foreach (ubyte b; bytes)
    {
        const(char)[] glyph = focusedDoc.charset.glyph(b);
        if (glyph.length == 0)
            glyph = ".";
        buf[n .. n + glyph.length] = glyph;
        n += glyph.length;
    }
    if (mark.length > bytes.length)
        n += sformat(buf[n .. $], "  (%d bytes)", mark.length).length;
    return ui_row_text(buf[0 .. n]);
}

/// Last searched pattern, for Find Next after the box closes.
__gshared Needle lastNeedle;
/// Ditto.
__gshared bool haveNeedle;

/// Find box parse cache, so frames don't reparse the same query. See
/// ui_find_needle.
__gshared Needle findNeedle;
/// Ditto.
__gshared bool findHave;
/// Ditto. size_t.max: nothing cached.
__gshared size_t findTextLen = size_t.max;
/// Ditto. Same size as the omnibar buffer.
__gshared char[192] findText;
/// Ditto, byte order used.
__gshared Endian findEndian;

/// Whether a job is walking `d` (edits refused).
bool ui_busy(const(Document)* d)
{
    if (d.job && d.job.busy)
        return true;
    foreach (const(Document)* other; docs)
        if (other.jobPeer is d && other.job && other.job.busy)
            return true;
    return false;
}

/// Whether `v` is waiting on its document's job.
bool ui_locked(const(View)* v)
{
    return ui_busy(v.doc) && v.doc.jobView is v;
}

/// Refuse an edit or second job on a busy document, with a message.
/// Returns: true if refused.
bool ui_refuse_busy(const(Document)* d)
{
    if (ui_busy(d) == false)
        return false;
    ui_status("busy searching %s, Esc cancels", ui_clip(d.title, 32));
    return true;
}

/// Ditto for edits, also refused on restricted documents.
bool ui_refuse_edit(const(Document)* d)
{
    if (ui_refuse_busy(d))
        return true;
    if (d.restricted == false)
        return false;
    ui_status("%s is read-only; turn off Edit > Read-Only", ui_clip(d.title, 32));
    return true;
}

/// Tab progress for `v`, -1 if none.
int ui_job_progress(const(View)* v)
{
    if (ui_locked(v) == false)
        return -1;
    return v.doc.job.progress;
}

/// Run `walk` on `v`'s document on a worker, then `land(v)` on the UI thread.
/// `v` is locked and edits refused until then, on `peer` too if the walk reads
/// it. Cancelled, failed or orphaned walks don't land.
void ui_job(View* v, void delegate(ref SearchContext) walk, void delegate(View*) land,
    Document* peer = null)
{
    Document* d = v.doc;
    if (d.job is null)
        d.job = new BackgroundWorker;
    BackgroundWorker job = d.job;

    SearchContext* ctx = search_context(&hexRead, cast(void*) d.editor);
    ctx.cancel   = job.cancelToken();
    ctx.progress = (int percent) { job.reportProgress(percent); };

    job.doWork   = (BackgroundWorker) { walk(*ctx); };
    job.workDone = (bool cancelled, Exception error) {
        d.jobView = null;
        d.jobPeer = null;
        if (error)
        {
            logError("search failed: %s", error.msg);
            ui_status("search failed: %s", ui_clip(error.msg, 44));
        }
        else if (cancelled)
            ui_status("search cancelled");
        else if (v.doc is d)
            land(v);
    };
    d.jobView  = v;
    d.jobPeer  = peer !is d ? peer : null;
    job.run();
}

/// Whether any job is running.
public bool ui_jobs_busy()
{
    foreach (const(Document)* d; docs)
        if (ui_busy(d))
            return true;
    return false;
}

/// Cancel the focused view's job.
/// Returns: false if none, so the key can do something else.
public bool ui_job_cancel()
{
    if (ui_locked(&focusedView()) == false)
        return false;
    focusedDoc.job.cancel();
    return true;
}

/// Search `v`'s document for the last pattern from `from` and select the match.
/// Always reports in the status bar; silence would look like a dropped key.
void ui_find_step(ref View v, bool backward, long from)
{
    if (haveNeedle == false)
    {
        ui_status("no pattern to find yet");
        return;
    }
    if (v.doc.editor is null || ui_refuse_busy(v.doc))
        return;

    // Copy: the box may change the pattern meanwhile. Match length comes from the
    // search since '*' varies.
    Needle needle = lastNeedle;
    long size = cast(long) hex_total(v.hex);
    long at = -1;
    size_t length;
    ui_job(&v, (ref SearchContext ctx) {
        at = search_find(needle, from, size, backward, length, ctx);
    }, (View* w) {
        if (at < 0)
        {
            ui_status("not found");
            return;
        }
        ui_select_range(*w, cast(size_t) at, length);
        ui_status("found at %s", ui_offset(at));
    });
}

/// Most matches ui_mark_all bookmarks in one go.
enum size_t MARK_ALL_MAX = 100_000;

/// What Enter in the find box does with the pattern.
enum FindGoal
{
    next,    /// Find forward from the caret
    back,    /// Find backward from the caret
    markAll, /// Bookmark every match
}

/// Find box readout per goal. The tag says the direction, so this says how to flip it.
immutable string[FindGoal.max + 1] FIND_WHERE = [
    "Shift+Enter goes back",
    "Shift+Enter goes forward",
    "bookmarks every match",
];

/// Find box tag per goal, shown at the right end of the box.
immutable string[FindGoal.max + 1] FIND_TAG = [ "forward", "backward", "bookmark all" ];

/// Find box goal. Back to next on any other opening.
__gshared FindGoal findGoal;

/// Goal Enter takes, `shift` swapping next and back.
FindGoal ui_find_goal(bool shift)
{
    if (shift == false || findGoal == FindGoal.markAll)
        return findGoal;
    return findGoal == FindGoal.next ? FindGoal.back : FindGoal.next;
}

/// Open the find box for `goal`.
void ui_find_prompt(FindGoal goal)
{
    if (ui_on_settings())
        return;
    omni_show(omni, OMNI_FIND);
    findGoal = goal;
}

/// Open the find box to search backward from the caret.
public void ui_find_back_prompt()
{
    ui_find_prompt(FindGoal.back);
}

/// Toggle the find box searching backward. Ctrl+Shift+F.
public void ui_find_back_toggle()
{
    if (omni_shown(omni) && omni_mode(omni) == OmniMode.find && findGoal == FindGoal.back)
        ui_omni_close();
    else
        ui_find_back_prompt();
}

/// Open the find box to bookmark every match of the typed pattern.
public void ui_mark_all_prompt()
{
    ui_find_prompt(FindGoal.markAll);
}

/// Bookmark every match of the last pattern in the focused document. Marks
/// land together once the walk is done, so cancelling adds none.
void ui_mark_all()
{
    View* v = &focusedView();
    if (v.doc.editor is null || ui_refuse_busy(v.doc))
        return;

    Needle needle = lastNeedle;
    long size = cast(long) hex_total(v.hex);
    Bookmark[] hits;
    bool full;
    ui_job(v, (ref SearchContext ctx) {
        search_all(needle, size, (long at, size_t length) {
            if (hits.length == MARK_ALL_MAX)
            {
                full = true;
                return false;
            }
            hits ~= Bookmark(at, cast(long) length);
            return true;
        }, ctx);
    }, (View* w) {
        if (hits.length == 0)
        {
            ui_status("not found");
            return;
        }
        bookmark_add_all(w.doc.marks, hits);
        ui_status(full ? "bookmarked the first %u matches" : "bookmarked %u match(es)",
            hits.length);
    });
}

/// Repeat the last search from the caret, offset so it doesn't refind the same
/// match.
public void ui_find_repeat(bool backward)
{
    if (ui_on_settings())
        return;
    // The caret is on the match's last byte; going back from it would refind it.
    long from = backward
        ? cast(long) hex_sel_low(focusedView.hex) - 1
        : cast(long) focusedView.hex.cursor + 1;
    ui_find_step(focusedView, backward, from);
}

/// ddhx skip-back/forward: move past the run of identical elements at the
/// caret. Goes to the document edge if nothing differs.
///
/// The element is the caret byte, or the selection (walks records). The landed
/// element stays selected so it repeats (ddhx drops it).
///
/// `select` (Shift) keeps the anchor and selects the crossed bytes. It compares
/// byte-wise from the first unselected byte; comparing from where the last
/// press stopped would stall on its own run.
public void ui_skip_element(bool backward, bool select = false)
{
    if (ui_on_settings())
        return;
    if (focusedDoc.editor is null || ui_refuse_busy(&focusedDoc()))
        return;

    long total = cast(long) hex_total(focusedView.hex);
    if (total <= 0)
        return;

    long from, len = 1;
    if (select)
    {
        from = cast(long) focusedView.hex.cursor + (backward ? -1 : 1);
        if (from < 0)
            return;
    }
    else
    {
        // From the selection's low end, like ddhx. Clamped: the selection may outlive
        // deleted bytes.
        from = cast(long) hex_sel_low(focusedView.hex);
        long high = cast(long) hex_sel_high(focusedView.hex);
        if (high >= total)
            high = total - 1;
        if (high >= from)
            len = high - from + 1;
        if (len > cast(long) SEARCH_ELEMENT_MAX)
        {
            ui_status("selection too long to skip over (max %u bytes)", SEARCH_ELEMENT_MAX);
            return;
        }
    }
    // Nothing after the append slot; backward still works.
    if (from >= total && backward == false)
        return;

    long at = -1;
    ui_job(&focusedView(), (ref SearchContext ctx) {
        at = search_skip(from, len, total, backward, ctx);
    }, (View* v) {
        if (at < 0)
            return;
        if (select)
            hex_extend_caret(v.hex, cast(size_t) skipRunEnd(v, from, at, backward, total));
        else if (len > 1)
            ui_select_range(*v, cast(size_t) at, cast(size_t) len);
        else
            hex_set_caret(v.hex, cast(size_t) at);
    });
}

/// Far end of the crossed run, given the landing `at`: one before it (that byte
/// ended the run), unless the walk hit the document edge, where `at` is the
/// run's last byte. Read back to tell which.
long skipRunEnd(View* v, long from, long at, bool backward, long total)
{
    if (from >= total) // append slot: the run was taken from here
        from = total - 1;

    ubyte ended, here;
    if (viewByte(v, cast(size_t) at, ended) && viewByte(v, cast(size_t) from, here)
        && ended == here)
        return at;
    return backward ? at + 1 : at - 1;
}

/// Select `len` bytes at `start` and scroll to it. Caret on the last byte so
/// Shift+arrows extend from there.
void ui_select_range(ref View v, size_t start, size_t len)
{
    hex_set_caret(v.hex, start); // clamps, activates, scrolls
    if (len > 1)
    {
        size_t total = hex_total(v.hex);
        size_t end = start + len - 1;
        if (end >= total && total)
            end = total - 1;
        v.hex.cursor = end;
    }
}

/// Toggle a bookmark over the selection, or the caret byte.
public void ui_mark_toggle()
{
    if (ui_on_settings())
        return;
    long at  = cast(long) hex_sel_low(focusedView.hex);
    long len = cast(long) hex_sel_high(focusedView.hex) - at + 1;

    bool set = bookmark_toggle(focusedDoc.marks, at, len);
    if (len > 1)
        ui_status(set ? "bookmarked %s, %d byte(s)" : "cleared %s, %d byte(s)",
            ui_offset(at), len);
    else
        ui_status(set ? "bookmark set at %s" : "bookmark cleared at %s", ui_offset(at));
}

/// Name the bookmark at the caret, creating one over the selection if needed.
public void ui_mark_name()
{
    if (ui_on_settings())
        return;
    long at = cast(long) hex_sel_low(focusedView.hex);
    if (bookmark_has(focusedDoc.marks, at) == false)
    {
        long len = cast(long) hex_sel_high(focusedView.hex) - at + 1;
        bookmark_toggle(focusedDoc.marks, at, len);
    }

    ptrdiff_t index = bookmark_find(focusedDoc.marks, at);
    if (index < 0)
    {
        ui_status("nothing to name at %s", ui_offset(at));
        return;
    }

    // The run may start before the caret; key on its start.
    markPrompt = MarkPrompt(&focusedDoc(), focusedDoc.marks[index].at);
    promptKind = PromptKind.markName;
    omni_prompt(omni, "name this run of bytes", focusedDoc.marks[index].name);
}

/// Prompt for columns. A prompt, not a cycle, so any count can be typed;
/// common widths are listed.
public void ui_columns_prompt()
{
    if (ui_on_settings())
        return;
    settingPreview = SettingPreview(&focusedView(), &focusedDoc(), focusedView.hex.columns,
        focusedView.hex.autoColumns, focusedDoc.charset, focusedView.hex.offsetBase, true);
    promptKind = PromptKind.columns;
    omni_prompt(omni, "count, or auto to fit the pane");
    omni_select(omni, ui_columns_index(ui_columns()));
}

/// Prompt for the text lane charset. Closed list; typing narrows it.
public void ui_charset_prompt()
{
    if (ui_on_settings())
        return;
    settingPreview = SettingPreview(&focusedView(), &focusedDoc(), focusedView.hex.columns,
        focusedView.hex.autoColumns, focusedDoc.charset, focusedView.hex.offsetBase, true);
    promptKind = PromptKind.charset;
    omni_prompt(omni, "ascii, cp437, ebcdic037, macroman, latin1, win1252");
    // Rows follow ddhx's list order.
    omni_select(omni, ui_charset_index(focusedDoc.charset));
}

/// Prompt for the offset base. Closed list, ddhx's names.
public void ui_address_prompt()
{
    if (ui_on_settings())
        return;
    settingPreview = SettingPreview(&focusedView(), &focusedDoc(), focusedView.hex.columns,
        focusedView.hex.autoColumns, focusedDoc.charset, focusedView.hex.offsetBase, true);
    promptKind = PromptKind.address;
    omni_prompt(omni, "hex, dec, oct");
    omni_select(omni, focusedView.hex.offsetBase);
}

/// Prompt for a disk or a typed path; for devices the native dialog doesn't
/// show.
public void ui_open_device_prompt()
{
    deviceRows = disks_list();
    deviceLabels.length = deviceRows.length;
    deviceDetails.length = deviceRows.length;
    foreach (size_t i, ref const(Disk) disk; deviceRows)
    {
        string name = disk.name.length ? disk.name : baseName(disk.path);
        deviceLabels[i] = disk.part ? "    " ~ name : name;
        deviceDetails[i] = disk.size ? disk.path ~ "  " ~ disks_size(disk.size) : disk.path;
    }
    promptKind = PromptKind.openDevice;
    omni_prompt(omni, DISKS_LISTED ? "pick a disk, or type a path" : "type a path to open");
}

/// Disks found by ui_open_device_prompt, kept while the box is open.
__gshared Disk[] deviceRows;
/// Ditto, row text.
__gshared string[] deviceLabels, deviceDetails;

/// Disk rows, plus the typed text as a path row once it looks like one.
void ui_device_rows(scope void delegate(string, string, int, bool, bool, string) put)
{
    import std.string : indexOfAny;

    const(char)[] query = omni_query(omni);
    if (query.indexOfAny(`/\:`) >= 0)
        put(ui_row_text(query), "open this path", cast(int) deviceRows.length, false, true, null);
    foreach (size_t i, ref const(Disk) disk; deviceRows)
        put(deviceLabels[i], deviceDetails[i], cast(int) i, false, false, disk.path);
}

/// Open disk row `id`, or the typed path for the row after the last disk.
void ui_device_commit(int id)
{
    if (id >= 0 && id < deviceRows.length)
        cast(void) ui_open(deviceRows[id].path);
    else if (id == deviceRows.length)
        cast(void) ui_open(omni_query(omni).idup);
    focusedView.hex.takeFocus = true;
}

/// Suggested widths (0 = auto). Others are typed.
immutable int[5] COLUMN_SUGGESTED = [ 8, 16, 24, 32, 0 ];

/// Suggested widths plus the current one if not among them; ascending, auto
/// last. The current width needs a row since the highlight opens on it and
/// browsing applies rows.
/// Returns: Entries filled in `offered`.
size_t ui_columns_offered(int current, out int[COLUMN_SUGGESTED.length + 1] offered)
{
    size_t n;
    bool placed = current == 0; // auto is already listed, last

    foreach (int cols; COLUMN_SUGGESTED)
    {
        if (placed == false && (cols == 0 || cols >= current))
        {
            if (cols != current)
                offered[n++] = current;
            placed = true;
        }
        offered[n++] = cols;
    }
    return n;
}

unittest
{
    int[COLUMN_SUGGESTED.length + 1] got;

    // Suggested width: list unchanged.
    assert(ui_columns_offered(16, got) == 5);
    assert(got[0 .. 5] == [ 8, 16, 24, 32, 0 ]);
    assert(ui_columns_offered(0, got) == 5);   // auto
    assert(got[0 .. 5] == [ 8, 16, 24, 32, 0 ]);
    assert(ui_columns_offered(8, got) == 5);   // first
    assert(got[0 .. 5] == [ 8, 16, 24, 32, 0 ]);

    // Others are inserted in order.
    assert(ui_columns_offered(48, got) == 6);
    assert(got[0 .. 6] == [ 8, 16, 24, 32, 48, 0 ]); // before auto
    assert(ui_columns_offered(10, got) == 6);
    assert(got[0 .. 6] == [ 8, 10, 16, 24, 32, 0 ]);
    assert(ui_columns_offered(1, got) == 6);
    assert(got[0 .. 6] == [ 1, 8, 16, 24, 32, 0 ]); // first

    // Highlight index.
    assert(ui_columns_index(16) == 1);
    assert(ui_columns_index(0) == 4);
    assert(ui_columns_index(48) == 4);
    assert(ui_columns_index(10) == 1);
}

/// Columns when the prompt opened (before browsing), else the current width.
int ui_columns_baseline()
{
    if (settingPreview.active)
        return settingPreview.autoColumns ? 0 : settingPreview.columns;
    return ui_columns();
}

/// Ditto for the charset prompt.
immutable(Charset)* ui_charset_baseline()
{
    return settingPreview.active ? settingPreview.charset : focusedDoc.charset;
}

/// Index in ddhx's charset list (row order).
int ui_charset_index(immutable(Charset)* set)
{
    foreach (size_t i, immutable(Charset)* s; charsets)
        if (s == set)
            return cast(int) i;
    return 0;
}

/// Index in the offered widths, for the initial highlight.
int ui_columns_index(int current)
{
    int[COLUMN_SUGGESTED.length + 1] offered = void;
    size_t n = ui_columns_offered(current, offered);
    foreach (size_t i; 0 .. n)
        if (offered[i] == current)
            return cast(int) i;
    return 0;
}

/// Columns prompt rows: offered widths, plus a pinned readout when the typed
/// text matches none.
void ui_columns_rows(scope void delegate(string, string, int, bool, bool, string) put)
{
    // Use the opening width, else rows reshuffle while browsing.
    int current = ui_columns_baseline();
    int[COLUMN_SUGGESTED.length + 1] offered = void;
    size_t n = ui_columns_offered(current, offered);

    const(char)[] query = omni_query(omni);
    int typed;
    if (ui_columns_parse(query, typed))
    {
        bool listed;
        foreach (size_t i; 0 .. n)
            if (offered[i] == typed)
                listed = true;
        if (listed == false)
        {
            char[64] buf = void;
            put(ui_columns_name(typed),
                ui_row_text(sformat(buf, "%d bytes to the row", typed)),
                typed, false, true, null);
        }
    }
    else if (query.length)
    {
        // Everything else is filtered out; an empty list looks unresponsive.
        put("not a column count", "a number up to 256, or auto", -1, false, true, null);
    }

    foreach (size_t i; 0 .. n)
    {
        int cols = offered[i];
        string detail = cols == 0 ? "fit the row to the pane" : null;
        if (cols == current)
            detail = cols == 0 ? "current, fitting the pane" : "current";
        put(ui_columns_name(cols), detail, cols, false, false,
            cols == 0 ? "fit resize pane window" : null);
    }
}

/// Charset rows: ddhx names, full name as detail ("code page", "roman" match).
void ui_charset_rows(scope void delegate(string, string, int, bool, bool, string) put)
{
    immutable(Charset)* current = ui_charset_baseline();
    foreach (size_t i, immutable(Charset)* set; charsets)
    {
        string detail = set.name;
        if (set == current)
            detail = ui_row_text(detail ~ "  -  current");
        put(set.id, detail, cast(int) i, false, false, null);
    }
}

/// Offset base prompt rows, in HexBase order.
void ui_address_rows(scope void delegate(string, string, int, bool, bool, string) put)
{
    HexBase current = settingPreview.active ? settingPreview.offsetBase : focusedView.hex.offsetBase;
    import std.traits : EnumMembers;
    foreach (HexBase base; EnumMembers!HexBase)
    {
        string detail = ui_address_name(base);
        if (base == current)
            detail = ui_row_text(detail ~ "  -  current");
        put(ui_address_label(base), detail, base, false, false, null);
    }
}

/// Short name of `base`, as in ddhx's `address`. A literal, so NUL-terminated.
string ui_address_label(HexBase base)
{
    final switch (base)
    {
    case HexBase.hex: return "hex";
    case HexBase.dec: return "dec";
    case HexBase.oct: return "oct";
    }
}

/// Full name of `base`.
string ui_address_name(HexBase base)
{
    final switch (base)
    {
    case HexBase.hex: return "Hexadecimal";
    case HexBase.dec: return "Decimal";
    case HexBase.oct: return "Octal";
    }
}

/// Settings before browsing, restored on cancel. Like Preview, for settings
/// that preview on the grid.
struct SettingPreview
{
    View* view;
    Document* doc;
    int columns;
    bool autoColumns;
    immutable(Charset)* charset;
    HexBase offsetBase;
    bool active;
}
/// Ditto.
__gshared SettingPreview settingPreview;

/// Apply the highlighted row while browsing; reverted by ui_setting_restore
/// unless taken.
void ui_setting_preview(OmniMode mode)
{
    if (mode != OmniMode.prompt || ui_omni_active() == false
        || promptKind == PromptKind.markName || promptKind == PromptKind.openDevice
        || promptKind == PromptKind.write || promptKind == PromptKind.select)
    {
        ui_setting_restore(); // box moved on or another question
        return;
    }
    if (settingPreview.active == false)
        return;

    // Preview on arrow keys only: while typing, the list re-ranks every key and
    // lags a frame, so previews would strobe. Show the original until Enter.
    if (omni_query(omni).length)
    {
        ui_setting_rewind();
        return;
    }

    int id = omni_current(omni);
    if (id < 0)
        return; // no row: keep the last preview

    if (promptKind == PromptKind.columns)
        cast(void) ui_columns_set(id);
    else if (promptKind == PromptKind.address)
    {
        if (id <= HexBase.max)
            ui_address_set(cast(HexBase) id);
    }
    else if (id < charsets.length)
        ui_charset_set(charsets[id]);
}

/// Revert the settings to their opening values, keeping the browse.
void ui_setting_rewind()
{
    if (settingPreview.active == false)
        return;

    // Use the captured view/document; still valid since the box has the keyboard.
    settingPreview.view.hex.columns = settingPreview.columns;
    settingPreview.view.hex.autoColumns = settingPreview.autoColumns;
    settingPreview.doc.charset = settingPreview.charset;
    settingPreview.view.hex.offsetBase = settingPreview.offsetBase;
}

/// Ditto, ending the browse.
void ui_setting_restore()
{
    ui_setting_rewind();
    settingPreview = SettingPreview.init;
}

/// Ditto, keeping the browse result (row taken).
void ui_setting_drop()
{
    settingPreview = SettingPreview.init;
}

/// Apply the columns prompt answer; `id` is the width.
void ui_columns_commit(int id)
{
    if (id < 0) // the invalid-input row
        return;
    if (ui_columns_set(id) == false)
        ui_status("columns: %d is past the %d the grid draws", id, HEX_COLUMNS_MAX);
}

/// Naming prompt row: the run being named and the effect of the typed text.
void ui_mark_name_preview(out string label, out string detail)
{
    Document* d = markPrompt.doc;
    ptrdiff_t index = d !is null ? bookmark_find(d.marks, markPrompt.at) : -1;
    if (index < 0)
    {
        label  = "the bookmark is gone";
        detail = "Esc to close";
        return;
    }

    const(Bookmark) mark = d.marks[index];
    char[96] buf = void;
    label = ui_row_text(sformat(buf, "Name %s, %d byte(s)", ui_offset(mark.at, true), mark.length));

    const(char)[] typed = omni_query(omni);
    if (typed.length == 0)
        detail = mark.name.length ? "empty: clear the name" : "type a name, Enter to set";
    else
        detail = ui_row_text(sformat(buf, `set to "%s"`, ui_clip(cast(string) typed, 48)));
}

/// Apply the name. Empty removes the name.
void ui_mark_name_commit(const(char)[] typed)
{
    Document* d = markPrompt.doc;
    if (d is null)
        return;

    string name = ui_mark_name_clean(typed);
    if (bookmark_rename(d.marks, markPrompt.at, name) == false)
    {
        ui_status("the bookmark at %s is gone", ui_offset(markPrompt.at));
        return;
    }
    if (name.length)
        ui_status(`bookmark at %s named "%s"`, ui_offset(markPrompt.at), ui_clip(name, 48));
    else
        ui_status("bookmark at %s unnamed", ui_offset(markPrompt.at));
}

/// Name cleanup: trim, and drop tabs and newlines (names are single-line).
string ui_mark_name_clean(const(char)[] typed)
{
    const(char)[] text = strip(typed);
    if (text.length == 0)
        return null;

    char[] name = new char[text.length];
    foreach (size_t i, char c; text)
        name[i] = c == '\t' || c == '\n' || c == '\r' ? ' ' : c;
    return cast(string) name;
}

/// Pattern write being typed: target view, kind, and the selection it opened
/// on. A multi-byte selection stands in for the range, as in ddhx.
struct WritePrompt
{
    View* view;
    bool insert;    /// patternInsert, else patternReplace.
    bool ranged;    /// -range form: text starts with a range.
    bool selected;  /// Multi-byte selection; `high` is valid.
    long low, high;
}
/// Ditto.
__gshared WritePrompt writePrompt;

/// Last parse of the write prompt, reused while the text is unchanged.
__gshared string writeText;
/// Ditto.
__gshared bool writeParsed;
/// Ditto.
__gshared string writeError;
/// Ditto.
__gshared EditRequest writeReq;

/// Prompt for a pattern write (ddhx's replace, insert, and -range forms).
public void ui_write_prompt(bool insert, bool ranged)
{
    if (ui_on_settings())
        return;
    View* v = &focusedView();
    if (v.doc.editor is null || ui_refuse_edit(v.doc))
        return;

    long total = cast(long) hex_total(v.hex);
    long low   = v.hex.active ? cast(long) hex_sel_low(v.hex) : 0;
    long high  = v.hex.active ? cast(long) hex_sel_high(v.hex) : 0;
    if (low > total) low = total;
    if (high >= total) high = total - 1; // exclude the append slot
    writePrompt = WritePrompt(v, insert, ranged, high > low, low, high);
    writeParsed = false;

    string hint;
    if (writePrompt.selected)
        hint = "pattern for the selection: x:00, utf8:abc, u16:1";
    else if (ranged)
        hint = "range then pattern: 0x100:+16 x:00";
    else
        hint = "pattern, written once at the caret: x:00, utf8:abc";
    promptKind = PromptKind.write;
    omni_prompt(omni, hint);
}

/// Parse `typed` into `req` for the write prompt, filling in the selection or
/// caret when no range is typed. Returns: null, or what's wrong.
string ui_write_parse(const(char)[] typed, out EditRequest req)
{
    if (writeParsed && writeText == typed)
    {
        req = writeReq;
        return writeError;
    }

    WritePrompt* w = &writePrompt;
    bool ranged = w.ranged && w.selected == false;
    writeError = edit_parse(typed, ranged, w.view.doc.endian, w.low,
        w.view.doc.editor.size(), writeReq);
    if (writeError is null && ranged == false)
    {
        writeReq.start  = w.low;
        writeReq.length = w.selected ? w.high - w.low + 1 : writeReq.data.length;
    }
    writeText   = typed.idup;
    writeParsed = true;
    req = writeReq;
    return writeError;
}

/// Write prompt row: what Enter writes where, or what's wrong.
void ui_write_preview(out string label, out string detail)
{
    WritePrompt* w = &writePrompt;
    string verb = w.insert ? "Insert" : "Replace";
    char[96] buf = void;

    EditRequest req;
    string error = ui_write_parse(omni_query(omni), req);
    if (error)
    {
        if (w.selected)
            label = ui_row_text(sformat(buf, "%s selection %s, %d byte(s)", verb, ui_offset(w.low, true),
                w.high - w.low + 1));
        else if (w.ranged)
            label = verb;
        else
            label = ui_row_text(sformat(buf, "%s at %s", verb, ui_offset(w.low, true)));
        detail = ui_row_text(error);
        return;
    }

    label = ui_row_text(sformat(buf, "%s %d byte(s) at %s", verb, req.length, ui_offset(req.start, true)));

    // Leading pattern bytes, like bookmark rows.
    static immutable string digits = "0123456789abcdef";
    enum SHOWN = 8;
    char[SHOWN * 3 + 3] hex = void;
    size_t n;
    foreach (size_t i, ubyte b; req.data[0 .. req.data.length < SHOWN ? $ : SHOWN])
    {
        if (i) hex[n++] = ' ';
        hex[n++] = digits[b >> 4];
        hex[n++] = digits[b & 0x0f];
    }
    if (req.data.length > SHOWN)
    {
        hex[n .. n + 4] = " ...";
        n += 4;
    }
    detail = ui_row_text(sformat(buf, "%s, repeated", hex[0 .. n]));
}

/// Apply the write prompt's `typed` text. Selects what was written.
void ui_write_commit(const(char)[] typed)
{
    WritePrompt* w = &writePrompt;
    View* v = w.view;
    Document* d = v.doc;
    string verb = w.insert ? "insert" : "replace";

    EditRequest req;
    string error = ui_write_parse(typed, req);
    if (error)
    {
        ui_status("%s: %s", verb, error);
        return;
    }
    if (ui_refuse_edit(d))
        return;

    try
    {
        if (w.insert)
            d.editor.patternInsert(req.start, req.length, req.data.ptr, req.data.length);
        else
            d.editor.patternReplace(req.start, req.length, req.data.ptr, req.data.length);
    }
    catch (Exception e)
    {
        logError("%s failed: %s", verb, e.msg);
        return;
    }
    if (w.insert)
        bookmark_shift(d.marks, req.start, req.length);
    ++d.revision;
    structureEdited(d, req.start);

    v.hex.dataSize = d.editor.size();
    ui_select_range(*v, cast(size_t) req.start, cast(size_t) req.length);
    logDebugging("%s: %d byte(s) at %#x", verb, req.length, req.start);
}

/// Range selection being typed (ddhx's select): target view, its caret, and
/// the last parse, reused while the text is unchanged.
struct SelectPrompt
{
    View* view;
    long cursor;    /// Caret when opened, what `.` stands for.
    string text;
    bool parsed;
    string error;
    long start, length;
}
/// Ditto.
__gshared SelectPrompt selectPrompt;

/// Prompt for a range to select, like ddhx's select.
public void ui_select_prompt()
{
    if (ui_on_settings())
        return;
    View* v = &focusedView();
    if (v.doc.editor is null || ui_refuse_busy(v.doc))
        return;

    selectPrompt = SelectPrompt(v, cast(long) v.hex.cursor);
    promptKind = PromptKind.select;
    omni_prompt(omni, "range: 0x100:0x1ff, 0x100:+16, 16, .:$");
}

/// Parse `typed` into `start` and `length`, the end clamped to the last byte.
/// Returns: null, or what's wrong.
string ui_select_parse(const(char)[] typed, out long start, out long length)
{
    SelectPrompt* s = &selectPrompt;
    if (s.parsed == false || s.text != typed)
    {
        s.text   = typed.idup;
        s.parsed = true;
        s.error  = ui_select_resolve(strip(s.text), s.cursor, s.view.doc.editor.size(),
            s.start, s.length);
    }
    start  = s.start;
    length = s.length;
    return s.error;
}

/// Resolve range `text` against `cursor` and the document `size`.
/// Returns: null, or what's wrong.
string ui_select_resolve(string text, long cursor, long size, ref long start, ref long length)
{
    if (size == 0)
        return "the document is empty";
    if (text.length == 0)
        return "type a range";

    EditRequest req;
    string error = edit_range(text, cursor, size, req);
    if (error)
        return error;
    if (req.start >= size)
        return "range starts past the end";
    start  = req.start;
    length = req.start + req.length > size ? size - req.start : req.length;
    return null;
}

/// Select prompt row: what Enter selects, or what's wrong.
void ui_select_preview(out string label, out string detail)
{
    long start, length;
    string error = ui_select_parse(omni_query(omni), start, length);
    if (error)
    {
        label  = "Select";
        detail = ui_row_text(error);
        return;
    }
    char[96] buf = void;
    label  = ui_row_text(sformat(buf, "Select %d byte(s) at %s", length, ui_offset(start, true)));
    detail = ui_row_text(sformat(buf, "to %s", ui_offset(start + length - 1, true)));
}

/// Select the range in `typed`, caret on its last byte.
void ui_select_commit(const(char)[] typed)
{
    long start, length;
    string error = ui_select_parse(typed, start, length);
    if (error)
    {
        ui_status("select: %s", error);
        return;
    }
    if (ui_refuse_busy(selectPrompt.view.doc))
        return;
    ui_select_range(*selectPrompt.view, cast(size_t) start, cast(size_t) length);
}

/// Jump to the next/previous bookmark (wrapping) and select it.
public void ui_mark_step(int dir)
{
    if (ui_on_settings())
        return;
    ptrdiff_t index = bookmark_step(focusedDoc.marks, cast(long) hex_sel_low(focusedView.hex), dir);
    if (index < 0)
    {
        ui_status("no bookmarks in this document");
        return;
    }
    ui_mark_select(focusedView, index);
}

/// Clear all bookmarks on the focused document.
public void ui_mark_clear()
{
    if (ui_on_settings())
        return;
    ui_status("cleared %u bookmark(s)", focusedDoc.marks.length);
    focusedDoc.marks = null;
}

/// Open dialog for loading a bookmark file into the focused document.
public void ui_marks_load_dialog()
{
    if (ui_on_settings())
        return;
    pendingPick = Pick.marksLoad;
    marksFrom   = &focusedDoc();
    ui_file_dialog(&ui_on_file_picked, false);
}

/// Save dialog for the focused document's bookmarks.
public void ui_marks_save_dialog()
{
    if (ui_on_settings())
        return;
    if (focusedDoc.marks.length == 0)
    {
        ui_status("no bookmarks to save");
        return;
    }
    pendingPick = Pick.marksSave;
    marksFrom   = &focusedDoc();
    ui_file_dialog(&ui_on_file_picked, true);
}

/// Document a bookmark dialog was raised for, or null if its tab closed since.
Document* ui_marks_target()
{
    Document* d = marksFrom;
    marksFrom = null;
    foreach (Document* open; docs)
    {
        if (open is d)
            return d;
    }
    ui_status("the document is gone");
    return null;
}

/// Add the bookmarks in file `path` to the dialog's document. All or nothing.
void ui_marks_load(string path)
{
    import std.file : getSize, readText;

    Document* d = ui_marks_target();
    if (d is null)
        return;

    // Far past any real list (100000 marks is ~2 MiB). Stops reading a binary.
    enum ulong MARKS_FILE_MAX = 64 * 1024 * 1024;
    string text;
    try
    {
        if (getSize(path) > MARKS_FILE_MAX)
        {
            ui_status("%s is too large for a bookmark file", ui_clip(baseName(path), 40));
            return;
        }
        text = readText(path);
    }
    catch (Exception e)
    {
        logError("bookmarks: cannot read %s: %s", path, e.msg);
        ui_status("cannot read %s: %s", ui_clip(baseName(path), 32), ui_clip(e.msg, 44));
        return;
    }

    Bookmark[] runs;
    size_t line;
    string error = bookmark_parse(text, runs, line);
    if (error)
    {
        logWarn("bookmarks: %s:%u: %s", path, line, error);
        ui_status("%s, line %u: %s", ui_clip(baseName(path), 32), line, error);
        return;
    }

    bookmark_add_all(d.marks, runs);
    ui_status("loaded %u bookmark(s) from %s", runs.length, ui_clip(baseName(path), 40));
}

/// Write the dialog's document bookmarks to `path`, replacing it.
void ui_marks_save(string path)
{
    import std.file : write;

    Document* d = ui_marks_target();
    if (d is null)
        return;

    try write(path, bookmark_format(d.marks));
    catch (Exception e)
    {
        logError("bookmarks: cannot write %s: %s", path, e.msg);
        ui_status("cannot save %s: %s", ui_clip(baseName(path), 32), ui_clip(e.msg, 44));
        return;
    }
    ui_status("saved %u bookmark(s) to %s", d.marks.length, ui_clip(baseName(path), 40));
}

/// Select bookmark `index` in `v`.
void ui_mark_select(ref View v, ptrdiff_t index)
{
    ui_select_range(v, cast(size_t) v.doc.marks[index].at,
        cast(size_t) v.doc.marks[index].length);
}

/// Run a '>' command. All are menu entry points, so they can't diverge.
void ui_omni_run(int id)
{
    switch (id) {
    case CMD_NEW_TAB:   ui_new_tab();          break;
    case CMD_OPEN:      ui_open_dialog();      break;
    case CMD_READONLY:  ui_toggle_readonly();  break;
    case CMD_REFRESH:   ui_refresh();          break;
    case CMD_COMPARE:   ui_compare_dialog();   break;
    case CMD_COMPARE_STOP: ui_compare_stop();  break;
    case CMD_DIFF_NEXT: ui_diff_step(false);   break;
    case CMD_DIFF_PREV: ui_diff_step(true);    break;
    case CMD_SAVE:      cast(void)ui_save();             break;
    case CMD_SAVE_AS:   ui_save_as();          break;
    case CMD_CLOSE_TAB: ui_close_current_tab(); break;
    case CMD_UNDO:      ui_undo(false);        break;
    case CMD_REDO:      ui_undo(true);         break;
    case CMD_CUT:       ui_cut();              break;
    case CMD_CUT_TEXT:  ui_cut_text();         break;
    case CMD_COPY:      cast(void)ui_copy();             break;
    case CMD_COPY_TEXT: cast(void)ui_copy_text();        break;
    case CMD_PASTE:     ui_paste();            break;
    case CMD_ZOOM_IN:   ui_zoom(1);            break;
    case CMD_ZOOM_OUT:  ui_zoom(-1);           break;
    case CMD_ZOOM_RESET: ui_zoom(0);           break;
    case CMD_MINIMAP:   ui_toggle_minimap();   break;
    case CMD_CRUMBS:    ui_toggle_crumbs();    break;
    case CMD_ENDIAN:    ui_endian_toggle();    break;
    case CMD_FIND_NEXT: ui_find_repeat(false); break;
    case CMD_FIND_PREV: ui_find_repeat(true);  break;
    case CMD_SKIP_NEXT: ui_skip_element(false); break;
    case CMD_SKIP_PREV: ui_skip_element(true);  break;
    case CMD_SKIP_SEL_NEXT: ui_skip_element(false, true); break;
    case CMD_SKIP_SEL_PREV: ui_skip_element(true, true);  break;
    case CMD_MARK:      ui_mark_toggle();      break;
    case CMD_MARK_NEXT: ui_mark_step(1);       break;
    case CMD_MARK_PREV: ui_mark_step(-1);      break;
    case CMD_SPLIT:      ui_split();           break;
    case CMD_SPLIT_DOWN: ui_split_down();      break;
    case CMD_CLOSE_PANE: ui_close_pane();      break;
    case CMD_PANE_NEXT:  ui_cycle_pane(1);     break;
    case CMD_PANE_PREV:  ui_cycle_pane(-1);    break;
    case CMD_MARK_CLEAR: ui_mark_clear();      break;
    case CMD_MARK_LOAD:  ui_marks_load_dialog(); break;
    case CMD_MARK_SAVE:  ui_marks_save_dialog(); break;
    // Reopens the box in another mode next frame; don't give the panel focus.
    case CMD_GOTO:      ui_omni_open(OMNI_ADDRESS);  return;
    case CMD_FIND:      ui_omni_open(OMNI_FIND);     return;
    case CMD_FIND_BACK: ui_find_back_prompt();       return;
    case CMD_MARK_ALL:  ui_mark_all_prompt();        return;
    case CMD_INSPECT:   ui_omni_open(OMNI_INSPECT);  return;
    case CMD_MARK_LIST: ui_omni_open(OMNI_BOOKMARK); return;
    case CMD_STRUCTURE: ui_omni_open(OMNI_STRUCTURE); return;
    case CMD_MARK_NAME: ui_mark_name();              return;
    case CMD_COLUMNS:   ui_columns_prompt();         return;
    case CMD_CHARSET:   ui_charset_prompt();         return;
    case CMD_ADDRESS:   ui_address_prompt();         return;
    case CMD_OPEN_DEVICE: ui_open_device_prompt();   return;
    case CMD_REPLACE:       ui_write_prompt(false, false); return;
    case CMD_INSERT:        ui_write_prompt(true, false);  return;
    case CMD_REPLACE_RANGE: ui_write_prompt(false, true);  return;
    case CMD_INSERT_RANGE:  ui_write_prompt(true, true);   return;
    case CMD_SELECT_RANGE:  ui_select_prompt();            return;
    case CMD_KEYS:      ui_omni_open(OMNI_HELP);     return;
    case CMD_SETTINGS:  ui_settings_open();    break;
    case CMD_ABOUT:     about_open();          break;
    case CMD_QUIT:
        // Via SDL's queue, for the unsaved-changes check.
        SDL_Event quit; // .init zeroes the union
        quit.type = SDL_EVENT_QUIT;
        SDL_PushEvent(&quit);
        return;
    default:
        return;
    }
    focusedView.hex.takeFocus = true; // back to the bytes
}

/// Whether something animates and the loop must keep drawing.
public bool ui_animating()
{
    return elite_animating() || ui_tip_pending() || hex_edge_scrolling();
}

/// Build one UI frame, between mu_begin and mu_end.
public void ui_frame(mu_Context* ctx, int width, int height)
{
    winW = width;
    winH = height;
    if (redrawWanted)
    {
        redrawWanted = false;
        mu_invalidate(ctx);
    }

    // Menubar flush with the window edges: zero padding across
    // mu_begin_window_ex (it fixes the body inset), restore after.
    int padding = ctx.style.padding;
    ctx.style.padding = 0;

    // Before any draw command: queued text holds the face.
    ui_fonts_apply();
    ctx.style.font = render_font_ui();

    // ddui only clamps vertical scroll; pin x.
    mu_get_container(ctx, "vddhx").scroll.x = 0;

    int opened = mu_begin_window_ex(ctx, "vddhx",
        mu_Rect(0, 0, width, height),
        MU_OPT_NOTITLE | MU_OPT_NORESIZE | MU_OPT_NOCLOSE);

    ctx.style.padding = padding;

    if (opened)
    {
        // Fill the client area.
        mu_Container* win = mu_get_current_container(ctx);
        win.rect = mu_Rect(0, 0, width, height);

        // No row gaps: ddui paints them in the window colour, striping the chrome.
        // Restored after so the About dialog keeps default spacing.
        int spacing = ctx.style.spacing;
        ctx.style.spacing = 0;
        scope(exit) ctx.style.spacing = spacing;

        // Before the panes so job results show this frame.
        worker_pump();

        // File chosen in the Open dialog.
        if (atomicLoad(pendingReady))
        {
            atomicStore(pendingReady, false);
            string picked = pendingPath.ptr.fromStringz.idup;
            Pick pick = pendingPick;
            pendingPick = Pick.open;
            final switch (pick)
            {
            case Pick.open:      cast(void) ui_open(picked); break;
            case Pick.compare:   ui_compare_with(picked); break;
            case Pick.marksLoad: ui_marks_load(picked); break;
            case Pick.marksSave: ui_marks_save(picked); break;
            case Pick.font:      prefs.font = picked;     ui_fonts(true); break;
            case Pick.monofont:  prefs.monofont = picked; ui_fonts(true); break;
            }
        }

        Elevated answer;
        if (elevate_poll(answer))
            ui_elevated(answer);

        // Save As destination.
        if (atomicLoad(pendingSaveReady))
        {
            atomicStore(pendingSaveReady, false);
            ui_save_pending(pendingSavePath.ptr.fromStringz.idup);
        }

        // Omnibar and menus are exclusive overlays (ddui raises open menus every
        // frame). The most recently opened wins; checked on both sides of the bar
        // since this frame's click opens menus.
        if (omni_shown(omni) && omniWasShown == false)
            ctx.menu_stack_len = 0;

        ui_menubar(ctx);

        if (ctx.menu_stack_len > 0 && omni_shown(omni))
            ui_omni_close();
        omniWasShown = omni_shown(omni);

        // Panes fill the window above the status bar.
        int statusH = ctx.text_height(ctx.style.font) + 6;
        ui_panes(ctx, statusH);

        // Status bar: only what isn't shown elsewhere (document and dirty state: title
        // and tab; pane: strip number; tab: strip; structure: breadcrumbs). Keep it
        // short so it stays readable in narrow windows.
        //
        // Fixed-width fields first (offset, entry mode, byte order) so they stay put.
        static immutable int[1] srow = [ -1 ];
        mu_layout_row(ctx, 1, srow.ptr, statusH);
        mu_Rect sr = mu_layout_next(ctx);
        mu_draw_rect(ctx, sr, mu_Color(30, 30, 40, 255));

        int th = ctx.text_height(ctx.style.font);
        int ty = sr.y + (sr.h - th) / 2;

        if (statusLen)
        {
            mu_draw_text(ctx, ctx.style.font, cast(string) statusText[0 .. statusLen],
                mu_Vec2(sr.x + 4, ty), mu_Color(200, 200, 150, 255));
        }
        else if (ui_on_settings() == false) // no caret
        {
            size_t selLen = hex_total(focusedView.hex) ?
                hex_sel_high(focusedView.hex) - hex_sel_low(focusedView.hex) + 1 : 0;
            // Bookmark name at the caret; shown only here.
            ptrdiff_t mark = bookmark_find(focusedDoc.marks, cast(long) focusedView.hex.cursor);
            char[64] markbuf = void;
            const(char)[] marked = mark >= 0 && focusedDoc.marks[mark].name.length ?
                sformat(markbuf, "  [%s]", ui_clip(focusedDoc.marks[mark].name, 40)) : "";

            // Selection length, only when more than one byte.
            char[32] selbuf = void;
            const(char)[] selected = selLen > 1 ?
                sformat(selbuf, "  (%u selected)", selLen) : "";

            // Same base as the offset column.
            static immutable string[3] OFFSET_SPECS = [ "%08x", "%08d", "%08o" ];
            char[24] offbuf = void;
            const(char)[] offset = sformat(offbuf, OFFSET_SPECS[focusedView.hex.offsetBase],
                focusedView.hex.cursor);

            char[256] statusbuf = void;
            char[] status = sformat(statusbuf, "offset %s  %s  %s%s%s",
                offset, focusedView.hex.insertMode ? "INS" : "OVR",
                focusedDoc.endian == Endian.bigEndian ? "BE" : "LE", selected, marked);
            mu_draw_text(ctx, ctx.style.font, cast(string) status,
                mu_Vec2(sr.x + 4, ty), mu_Color(170, 170, 185, 255));
        }

        // Last, so the title matches this frame's edits.
        ui_window_title();

        mu_end_window(ctx);
    }

    // Floats over the main window.
    about_frame(ctx, width, height);

    // Easter egg, over About.
    elite_frame(ctx, width, height);

    // Omnibar last, on top. Mode read before the box runs so accept acts on the
    // list that was shown.
    OmniMode mode = omni_mode(omni);
    int chosen;
    const(OmniItem)[] rows = ui_omni_active() ? ui_omni_items() : null;
    omni_tag(omni, mode == OmniMode.find ? FIND_TAG[findGoal] : null);
    final switch (omni_frame(ctx, omni, rows, width, height, chosen))
    {
    case OmniAction.none:     ui_struct_preview(mode);
                              ui_setting_preview(mode);           break;
    // Complete keeps the box open; the '#' preview continues.
    case OmniAction.complete: cast(void) ui_omni_complete(mode, chosen);
                              ui_struct_preview(mode);
                              ui_setting_preview(mode);           break;
    // Accept commits the preview; ui_omni_accept handles non-preview routes.
    case OmniAction.accept:   ui_preview_drop(); ui_setting_drop();
                              ui_omni_accept(mode, chosen);       break;
    case OmniAction.transfer: ui_preview_drop(); ui_setting_drop();
                              ui_omni_accept(mode, chosen, true); break;
    case OmniAction.dismiss:  ui_preview_restore(); ui_setting_restore();
                              focusedView.hex.takeFocus = true;          break;
    }
}

/// Tab strip action, applied after all panes draw: a close can remove a pane
/// mid-loop.
struct TabRequest
{
    Pane* pane;
    TabAction action;
    int index;
    int target;
}

/// Tab dragged out of its strip: source pane, item, pointer rect. Drawn after
/// all panes, unclipped.
struct TabGhost
{
    Pane* pane; // null when no drag
    int index;
    mu_Rect rect;
}

/// Lay out and draw the grid: columns by weight with splitters, then panes per
/// column. Fills the window except `statusH` at the bottom.
void ui_panes(mu_Context* ctx, int statusH)
{
    size_t n = columns.length;

    // One full row, then columns placed manually: ddui returns absolute rects
    // without advancing layout.
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

        // Scope ids per column and pane so inner widgets can use constant names
        // (separate scroll and splitter state). Hashes the pointer value, not the
        // array slot, which moves.
        mu_push_id(ctx, &c, (Column*).sizeof);
        scope(exit) mu_pop_id(ctx);

        ui_column(ctx, c, r, req, ghost);

        // Splitters; new weights apply next frame.
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

    // Focus outline after all panes (painted on top). Only with several panes.
    if (ui_pane_count() > 1 && ui_pane_index(focused) >= 0)
        ui_outline(ctx, focused.rect, FOCUS_EDGE, FOCUS_EDGE_W);

    // Drop target highlight, after the loop so it paints over the panel. Validate
    // the pane: it may have closed during the drag.
    if (dropPane && ui_pane_index(dropPane) >= 0)
        ui_mark_pane(ctx, dropPane.rect);

    // Tab drag: target highlight, then the tab on top, unclipped.
    if (ghost.pane)
    {
        Pane* src = ghost.pane;
        SplitZone zone;
        Pane* onto = ui_drop_target(ctx, zone);
        // Back over its own pane cancels, unless on an edge with other tabs (split).
        if (onto && (onto !is src ||
                    (zone != SplitZone.centre && src.views.length > 1)))
            ui_mark_pane(ctx, ui_drop_rect(onto, zone));
        if (ghost.index >= 0 && ghost.index < src.items.length)
            tab_ghost(ctx, src.tabs, src.items[ghost.index], ghost.rect);
    }

    // No strip reported a hover: clear.
    if (tip.seen == false)
        tip = TabTip.init;
    tip.seen = false;
    ui_tip(ctx);

    // Byte hover is read from the panels, not reported.
    ui_span_tip(ctx);

    // Sync diff scroll now that panes have drawn, before the grid changes.
    ui_sync_diffs();

    // Apply the strip request now that loops are done.
    switch (req.action)
    {
    case TabAction.select: ui_select_tab_in(req.pane, req.index); break;
    case TabAction.close:  ui_close_tab_in(req.pane, req.index);  break;
    case TabAction.add:    focused = req.pane; ui_new_tab();      break;
    case TabAction.move:   ui_move_tab(req.pane, req.index, req.target); break;
    // Released outside its strip: join or split the pane under the pointer.
    // Over nothing (splitter, status bar): cancelled.
    case TabAction.detach:
        SplitZone zone;
        Pane* onto = ui_drop_target(ctx, zone);
        ui_split_into(req.pane, req.index, onto, zone);
        break;
    default:
    }
}

/// Keep both sides of each diff at the same offset. The leader is whichever
/// moved since last draw (compared to topSeen; scrolling has no hook).
///
/// Only front tabs are read (background views didn't move), but background
/// peers are written so they're aligned when shown. Called after all panes
/// draw. Only one side can move per frame.
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
                continue; // didn't move

            // Clamped at its end (shorter file): not a lead, else it would drag the
            // longer pane back every frame.
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

/// Lay out and draw a column's panes; same as ui_panes on the other axis.
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

    c.rect = r; // see Column.rect

    int y = r.y;
    foreach (size_t i, Pane* p; c.panes)
    {
        mu_Rect pr = mu_Rect(r.x, y, r.w, paneSizes[i]);
        y += pr.h;
        p.rect = pr; // see Pane.rect

        // Clicking a pane focuses it for menus, omnibar and chords (alongside ddui's
        // own focus).
        if (ctx.mouse_pressed == MU_MOUSE_LEFT && mu_mouse_over(ctx, pr))
            focused = p;

        mu_push_id(ctx, &p, (Pane*).sizeof); // see ui_panes
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

/// Drop target highlight (wash and edge), for file and tab drops.
void ui_mark_pane(mu_Context* ctx, mu_Rect r)
{
    mu_draw_rect(ctx, r, DROP_WASH);
    ui_outline(ctx, r, DROP_EDGE, DROP_EDGE_W);
}

/// Whether a tooltip delay is pending. Public since the loop sleeps when idle
/// and nothing would wake it when the delay ends.
public bool ui_tip_pending()
{
    MonoTime now = MonoTime.currTime;
    if (tip.pane !is null && now - tip.since < TIP_DELAY)
        return true;
    return spanTip.view !is null && now - spanTip.since < TIP_DELAY;
}

/// Tab tooltip: full path after the hover delay. Drawn from ui_panes after all
/// panes, unclipped.
void ui_tip(mu_Context* ctx)
{
    if (tip.pane is null || ui_tip_pending())
        return;
    // The grid may have changed since the hover was reported.
    if (ui_pane_index(tip.pane) < 0 || tip.index >= tip.pane.views.length)
        return;

    Document* d = tip.pane.views[tip.index].doc;
    string full = d.path.length ? d.path : "not saved yet";

    mu_Font font = ctx.style.font;
    int th = ctx.text_height(font);
    // Elide to the window width.
    char[512] scratch = void;
    string text = ui_elide(ctx, full, winW - TIP_PAD * 2 - TIP_MARGIN * 2, scratch);
    if (text.length == 0)
        return;

    int tw = ctx.text_width(font, text.ptr, cast(int) text.length);
    mu_Rect r = mu_Rect(tip.rect.x, tip.rect.y + tip.rect.h + TIP_DROP,
        tw + TIP_PAD * 2, th + TIP_PAD * 2);

    // Clamp inside the window (right-edge tabs, bottom panes).
    r.x = mu_clamp(r.x, TIP_MARGIN, mu_max(TIP_MARGIN, winW - TIP_MARGIN - r.w));
    if (r.y + r.h > winH - TIP_MARGIN)
        r.y = tip.rect.y - TIP_DROP - r.h;

    mu_draw_rect(ctx, r, TIP_BACK);
    ui_outline(ctx, r, TIP_EDGE, 1);
    mu_draw_text(ctx, font, text, mu_Vec2(r.x + TIP_PAD, r.y + TIP_PAD), TIP_TEXT);
}

/// Field tooltip: structure name of the byte under the pointer after the hover
/// delay. Found via the panels (see SpanTip); only with a structure. Moving to
/// another byte restarts the delay instead of following live.
void ui_span_tip(mu_Context* ctx)
{
    // Front views only: background views keep a stale hoverByte.
    View* over;
    foreach (Column* c; columns)
        foreach (Pane* p; c.panes)
        {
            if (p.current >= p.views.length)
                continue;
            View* v = p.views[p.current];
            if (v.hex.hoverByte >= 0)
                over = v;
        }

    if (over is null)
    {
        spanTip = SpanTip.init;
        return;
    }

    if (over !is spanTip.view || over.hex.hoverByte != spanTip.at)
    {
        spanTip.view  = over;
        spanTip.at    = over.hex.hoverByte;
        spanTip.since = MonoTime.currTime;
        return;
    }

    if (MonoTime.currTime - spanTip.since < TIP_DELAY)
        return;

    char[64] pathbuf = void;
    const(char)[] path = structureLabel(over.doc, spanTip.at, pathbuf);
    if (path.length == 0)
        return;

    mu_Font font = ctx.style.font;
    int th = ctx.text_height(font);
    int tw = ctx.text_width(font, path.ptr, cast(int) path.length);

    // Below-right of the pointer, clear of the cursor.
    mu_Rect r = mu_Rect(ctx.mouse_pos.x + TIP_DROP, ctx.mouse_pos.y + th,
        tw + TIP_PAD * 2, th + TIP_PAD * 2);
    r.x = mu_clamp(r.x, TIP_MARGIN, mu_max(TIP_MARGIN, winW - TIP_MARGIN - r.w));
    if (r.y + r.h > winH - TIP_MARGIN)
        r.y = ctx.mouse_pos.y - TIP_DROP - r.h;

    mu_draw_rect(ctx, r, TIP_BACK);
    ui_outline(ctx, r, TIP_EDGE, 1);
    mu_draw_text(ctx, font, cast(string) path,
        mu_Vec2(r.x + TIP_PAD, r.y + TIP_PAD), TIP_TEXT);
}

/// Rect outline, `w` px, drawn inside.
void ui_outline(mu_Context* ctx, mu_Rect r, mu_Color c, int w)
{
    mu_draw_rect(ctx, mu_Rect(r.x, r.y, r.w, w), c);
    mu_draw_rect(ctx, mu_Rect(r.x, r.y + r.h - w, r.w, w), c);
    mu_draw_rect(ctx, mu_Rect(r.x, r.y, w, r.h), c);
    mu_draw_rect(ctx, mu_Rect(r.x + r.w - w, r.y, w, r.h), c);
}

/// Draw a pane: tab strip, then the hex panel. One tab per view (two views of a
/// file are two same-named tabs); items rebuilt per frame. Strip actions go to
/// `req`; see TabRequest.
void ui_pane(mu_Context* ctx, Pane* p, ref TabRequest req)
{
    if (p.items.length < p.views.length)
        p.items.length = p.views.length;
    foreach (size_t i, View* v; p.views)
        p.items[i] = TabItem(v.doc.title, v.doc.editor && v.doc.editor.edited(),
            cast(int) ui_view_count(v.doc), ui_job_progress(v),
            v.doc.restricted && v.doc.settingsPage == false); // nothing to unlock

    // Only the focused pane lights its accent.
    p.tabs.unfocused = p !is focused;

    // Pane number for Ctrl+1..9, only with several panes.
    p.tabs.badge = ui_pane_count() > 1 ? ui_ordinal(ui_pane_index(p) + 1) : null;

    int at, target;
    TabAction action = tab_bar(ctx, "tabs", p.tabs,
        p.items[0 .. p.views.length], cast(int) p.current, at, target);
    if (action != TabAction.none)
        req = TabRequest(p, action, at, target);

    int hoverAt;
    mu_Rect hoverRect;
    if (tab_hover(p.tabs, hoverAt, hoverRect))
    {
        // New tab restarts the delay; the same tab keeps counting.
        if (tip.pane !is p || tip.index != hoverAt)
        {
            tip.pane  = p;
            tip.index = hoverAt;
            tip.since = MonoTime.currTime;
        }
        tip.rect = hoverRect;
        tip.seen = true;
    }

    View* v = p.views[p.current];
    if (v.doc.settingsPage)
    {
        settings_page(ctx);
        return;
    }

    v.hex.minimap = prefs.minimap;

    // Charset is per document; rebind each frame so moved tabs follow.
    v.hex.textFn    = &ui_charset_text;
    v.hex.textUser  = cast(void*) v.doc;
    v.hex.textLabel = v.doc.charset.id;

    // Other views of a busy document stay readable; only the waiting view is
    // locked (its caret is about to move).
    v.hex.readOnly = ui_busy(v.doc) || v.doc.restricted;
    v.hex.locked   = ui_locked(v);
    if (ui_fixed(v.doc))
        v.hex.insertMode = false; // fixed size

    // Breadcrumbs under the tabs, above the grid (like VS Code). Always shown,
    // even unparsed, so the grid doesn't shift.
    if (prefs.crumbs)
        crumb_bar(ctx, cast(string) viewCrumbs(v), CANVAS);

    // The editor's size is authoritative across frames and panes.
    if (v.doc.editor)
        v.hex.dataSize = v.doc.editor.size();

    // For the reporting side: peer size (changed vs added) and drop the peer
    // block, so edits in either pane show. The other side never reads the peer.
    if (diff_reports(v))
    {
        IDocumentEditor peer = diff_peer(v).doc.editor;
        v.peerSize = peer ? peer.size() : 0;
        v.peerLen  = 0;
    }

    // Fills the column; the status bar is the window's. Constant name: ui_panes
    // pushed the pane id. Returns MU_RES_CHANGE on selection change.
    cast(void) hex_view(ctx, "hex", v.hex, render_font_mono(), 0);
}

/// Move tab `from` to `to`, shifting those in between (drag reorder).
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

/// Move view `index` from `src` to the end of `dst` and show it (drag between
/// panes). Caret, scroll and document come along. An emptied `src` closes; `dst`
/// takes focus. Null `dst` (splitter, status bar) does nothing.
void ui_move_view(Pane* src, size_t index, Pane* dst)
{
    if (src is null || dst is null || src is dst || index >= src.views.length)
        return;

    View* v = ui_take_view(src, index);

    dst.views ~= v;
    dst.current = dst.views.length - 1; // @suppress(dscanner.suspicious.length_subtraction)
    v.hex.takeFocus = true;

    // Close an emptied source; panes are pointers, so `dst` is unaffected.
    if (src.views.length == 0 && ui_pane_count() > 1)
        ui_drop_pane(src);

    focused = dst;
}

/// Ditto, into a new pane beside `dst` (drag to an edge). `zone` picks the
/// side: above/below in the column, or a new column (around the whole column,
/// like ui_split; previewed by ui_drop_rect). Works on its own pane; a pane's
/// last tab can't split off.
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

    // Validate before moving anything.
    size_t ci, pi;
    if (ui_locate(dst, ci, pi) == false)
        return;

    Pane* p = newPane();
    p.views ~= ui_take_view(src, index);
    p.views[0].hex.takeFocus = true;

    if (zone == SplitZone.up || zone == SplitZone.down)
    {
        // Half of `dst`, so the column total is unchanged.
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

    // After insertion: indices were read before.
    if (src.views.length == 0 && ui_pane_count() > 1)
        ui_drop_pane(src);

    focused = p;
}

/// Remove view `index` from `p`, keeping the front tab nearest its old
/// position. May leave `p` empty; the caller handles it.
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

/// New index of tab `at` after moving `from` to `to`.
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
    // [A B C D], A to 2: B and C shift down, D unchanged.
    assert(tab_reindex(0, 0, 2) == 2); // moved tab
    assert(tab_reindex(1, 0, 2) == 0);
    assert(tab_reindex(2, 0, 2) == 1);
    assert(tab_reindex(3, 0, 2) == 3);

    // [A B C D], D to 1: B and C shift up, A unchanged.
    assert(tab_reindex(3, 3, 1) == 1);
    assert(tab_reindex(1, 3, 1) == 2);
    assert(tab_reindex(2, 3, 1) == 3);
    assert(tab_reindex(0, 3, 1) == 0);

    // Single-step swaps (slow drags).
    assert(tab_reindex(0, 0, 1) == 1);
    assert(tab_reindex(1, 0, 1) == 0);
    assert(tab_reindex(2, 0, 1) == 2);

    foreach (size_t i; 0 .. 4)
        assert(tab_reindex(i, 2, 2) == i);
}

/// Menubar, using ddui's native menus.
void ui_menubar(mu_Context* ctx)
{
    mu_begin_menubar(ctx);

    // ddui computes item height and inset from style.padding per item, but bar
    // width and popup margin at mu_begin_menu, so padding only around items
    // loosens rows without changing the frame.
    int basePadding = ctx.style.padding;
    int itemPadding = basePadding + 4;

    // Dropdown width is style.menu_width only; the stock 160px overlaps labels and
    // shortcuts ("Save As..." / Ctrl+Shift+S). Measured over the command table,
    // since all items come from it.
    int itemWidth(const(char)* label, const(char)* shortcut)
    {
        // Padding each side plus a two-padding gap.
        return ctx.text_width(ctx.style.font, label, -1) +
               ctx.text_width(ctx.style.font, shortcut, -1) + itemPadding * 4;
    }
    int baseMenuWidth = ctx.style.menu_width;
    int menuWidth = baseMenuWidth;
    foreach (ref immutable Entry e; COMMANDS)
        menuWidth = mu_max(menuWidth, itemWidth(e.label.ptr, e.keys.ptr));
    ctx.style.menu_width = menuWidth;
    scope(exit) ctx.style.menu_width = baseMenuWidth;

    if (mu_begin_menu(ctx, "File"))
    {
        ctx.style.padding = itemPadding;
        // Ellipsis: opens a dialog first.
        if (mu_menu_item_ex(ctx, "New Tab",    "Ctrl+T",       0, 0)) ui_new_tab();
        if (mu_menu_item_ex(ctx, "Open...",    "Ctrl+O",       0, 0)) ui_open_dialog();
        if (mu_menu_item_ex(ctx, OPEN_DEVICE_LABEL.ptr, "",    0, 0)) ui_open_device_prompt();
        mu_menu_separator(ctx);
        if (mu_menu_item_ex(ctx, "Compare With...", "",        0, 0)) ui_compare_dialog();
        if (mu_menu_item_ex(ctx, "Stop Comparing",  "",        0, 0)) ui_compare_stop();
        if (mu_menu_item_ex(ctx, "Next Difference", "}",       0, 0)) ui_diff_step(false);
        if (mu_menu_item_ex(ctx, "Previous Difference", "{",   0, 0)) ui_diff_step(true);
        mu_menu_separator(ctx);
        if (mu_menu_item_ex(ctx, "Save",       "Ctrl+S",       0, 0)) cast(void)ui_save();
        if (mu_menu_item_ex(ctx, "Save As...", "Ctrl+Shift+S", 0, 0)) ui_save_as();
        if (mu_menu_item_ex(ctx, "Refresh",    "Ctrl+L",       0, 0)) ui_refresh();
        mu_menu_separator(ctx);
        if (mu_menu_item_ex(ctx, "Close Tab",  "Ctrl+W",       0, 0)) ui_close_current_tab();
        // Via SDL's queue; main owns the loop flag.
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
        if (mu_menu_item_ex(ctx, "Read-Only", focusedDoc.restricted ? "On" : "Off", 0, 0)) ui_toggle_readonly();
        mu_menu_separator(ctx);
        if (mu_menu_item_ex(ctx, "Undo",  "Ctrl+Z", 0, 0)) ui_undo(false);
        if (mu_menu_item_ex(ctx, "Redo",  "Ctrl+Y", 0, 0)) ui_undo(true);
        mu_menu_separator(ctx);
        if (mu_menu_item_ex(ctx, "Cut",   "Ctrl+X", 0, 0)) ui_cut();
        if (mu_menu_item_ex(ctx, "Cut as Text", "Ctrl+Shift+X", 0, 0)) ui_cut_text();
        if (mu_menu_item_ex(ctx, "Copy",  "Ctrl+C", 0, 0)) cast(void)ui_copy();
        if (mu_menu_item_ex(ctx, "Copy as Text", "Ctrl+Shift+C", 0, 0)) cast(void)ui_copy_text();
        if (mu_menu_item_ex(ctx, "Paste", "Ctrl+V", 0, 0)) ui_paste();
        mu_menu_separator(ctx);
        if (mu_menu_item_ex(ctx, "Settings", "", 0, 0)) ui_settings_open();
        ctx.style.padding = basePadding;
        mu_end_menu(ctx);
    }

    // Omnibar-opening items get the ellipsis too (they prompt for input).
    if (mu_begin_menu(ctx, "Search"))
    {
        ctx.style.padding = itemPadding;
        if (mu_menu_item_ex(ctx, "Find...",       "Ctrl+F",       0, 0)) ui_omni_open(OMNI_FIND);
        if (mu_menu_item_ex(ctx, "Find Backward...", "Ctrl+Shift+F", 0, 0)) ui_find_back_prompt();
        if (mu_menu_item_ex(ctx, "Find Next",     "Ctrl+N",       0, 0)) ui_find_repeat(false);
        if (mu_menu_item_ex(ctx, "Find Previous", "Ctrl+Shift+N", 0, 0)) ui_find_repeat(true);
        if (mu_menu_item_ex(ctx, "Bookmark All Matches...", "", 0, 0)) ui_mark_all_prompt();
        mu_menu_separator(ctx);
        if (mu_menu_item_ex(ctx, "Go to Offset...", "Ctrl+G",     0, 0)) ui_omni_open(OMNI_ADDRESS);
        if (mu_menu_item_ex(ctx, "Go to Field...",  "",           0, 0)) ui_omni_open(OMNI_STRUCTURE);
        mu_menu_separator(ctx);
        if (mu_menu_item_ex(ctx, "Skip Forward",  "Ctrl+Right",   0, 0)) ui_skip_element(false);
        if (mu_menu_item_ex(ctx, "Skip Back",     "Ctrl+Left",    0, 0)) ui_skip_element(true);
        if (mu_menu_item_ex(ctx, "Select Run Forward", "Ctrl+Shift+Right", 0, 0)) ui_skip_element(false, true);
        if (mu_menu_item_ex(ctx, "Select Run Back",    "Ctrl+Shift+Left",  0, 0)) ui_skip_element(true, true);
        if (mu_menu_item_ex(ctx, "Select Range...",    "",                 0, 0)) ui_select_prompt();
        ctx.style.padding = basePadding;
        mu_end_menu(ctx);
    }

    if (mu_begin_menu(ctx, "Bookmarks"))
    {
        ctx.style.padding = itemPadding;
        if (mu_menu_item_ex(ctx, "Toggle Bookmark",   "Ctrl+B", 0, 0)) ui_mark_toggle();
        if (mu_menu_item_ex(ctx, "Name Bookmark...",  "Ctrl+Shift+B", 0, 0)) ui_mark_name();
        if (mu_menu_item_ex(ctx, "Next Bookmark",     "]",      0, 0)) ui_mark_step(1);
        if (mu_menu_item_ex(ctx, "Previous Bookmark", "[",      0, 0)) ui_mark_step(-1);
        mu_menu_separator(ctx);
        if (mu_menu_item_ex(ctx, "List Bookmarks...", "",       0, 0)) ui_omni_open(OMNI_BOOKMARK);
        if (mu_menu_item_ex(ctx, "Clear Bookmarks",   "",       0, 0)) ui_mark_clear();
        mu_menu_separator(ctx);
        if (mu_menu_item_ex(ctx, "Load Bookmarks...", "",       0, 0)) ui_marks_load_dialog();
        if (mu_menu_item_ex(ctx, "Save Bookmarks...", "",       0, 0)) ui_marks_save_dialog();
        ctx.style.padding = basePadding;
        mu_end_menu(ctx);
    }

    if (mu_begin_menu(ctx, "View"))
    {
        ctx.style.padding = itemPadding;
        if (mu_menu_item_ex(ctx, "Inspect Bytes...", "Alt+I", 0, 0)) ui_omni_open(OMNI_INSPECT);
        // Value in the shortcut column, like the toggles below.
        if (mu_menu_item_ex(ctx, "Byte Order", focusedDoc.endian == Endian.bigEndian ? "Big" : "Little", 0, 0))
            ui_endian_toggle();
        // Prompts (ellipsis), with the current value in the shortcut column.
        if (mu_menu_item_ex(ctx, "Columns...", ui_columns_label(), 0, 0))
            ui_columns_prompt();
        if (mu_menu_item_ex(ctx, "Character Set...", focusedDoc.charset.id.ptr, 0, 0))
            ui_charset_prompt();
        if (mu_menu_item_ex(ctx, "Offset Format...", ui_address_label(focusedView.hex.offsetBase).ptr, 0, 0))
            ui_address_prompt();
        mu_menu_separator(ctx);
        // No checkmarks in ddui; state goes in the shortcut column.
        if (mu_menu_item_ex(ctx, "Minimap", prefs.minimap ? "On" : "Off", 0, 0))
            ui_toggle_minimap();
        if (mu_menu_item_ex(ctx, "Breadcrumbs", prefs.crumbs ? "On" : "Off", 0, 0))
            ui_toggle_crumbs();
        mu_menu_separator(ctx);
        if (mu_menu_item_ex(ctx, "Zoom In",    "Ctrl+=", 0, 0)) ui_zoom(1);
        if (mu_menu_item_ex(ctx, "Zoom Out",   "Ctrl+-", 0, 0)) ui_zoom(-1);
        if (mu_menu_item_ex(ctx, "Reset Zoom", "Ctrl+0", 0, 0)) ui_zoom(0);
        ctx.style.padding = basePadding;
        mu_end_menu(ctx);
    }

    if (mu_begin_menu(ctx, "Help"))
    {
        ctx.style.padding = itemPadding;
        if (mu_menu_item(ctx, "Keyboard Shortcuts...")) ui_omni_open(OMNI_HELP);
        mu_menu_separator(ctx);
        if (mu_menu_item(ctx, "About")) about_open();
        ctx.style.padding = basePadding;
        mu_end_menu(ctx);
    }

    mu_end_menubar(ctx);
}

version (Screenshots)
{
    /// State read back by the key driver (keys.d).
    public struct Probe
    {
        bool omni;
        OmniMode mode;
        string query;
        size_t panes, pane, tabs, tab, docs, marks;
        size_t cursor, anchor;
        long size;
        string path;
        bool edited;
    }

    /// Ditto.
    public Probe ui_probe()
    {
        Probe p;
        p.omni   = omni_shown(omni);
        p.mode   = omni_mode(omni);
        p.query  = omni_query(omni).idup;
        p.panes  = ui_pane_count();
        p.pane   = ui_pane_index(focused);
        p.tabs   = focusedPane.views.length;
        p.tab    = focusedPane.current;
        p.docs   = docs.length;
        p.marks  = focusedDoc.marks.length;
        p.cursor = focusedView.hex.cursor;
        p.anchor = focusedView.hex.anchor;
        p.size   = focusedDoc.editor.size();
        p.path   = focusedDoc.path;
        p.edited = focusedDoc.editor.edited();
        return p;
    }

    /// Byte at `at` as the focused view last drew it, or -1 if outside its cache.
    public int ui_peek(size_t at)
    {
        const(ubyte)[] b = hex_cached(focusedView.hex, at, 1);
        return b.length ? b[0] : -1;
    }
}
