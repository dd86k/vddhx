/// UI layout for vddhx.
module ui;

import core.atomic : atomicLoad, atomicStore;
import std.string : fromStringz;
import bindbc.sdl;
import ddlogger;
import ddui;
import ddhx.document : FileDocument, IDocument;
import ddhx.editor : IDocumentEditor, spawnEditor;
import hexview;
import render : render_font_mono;
import std.stdio : writeln;
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

/// Open `path` through a fresh ddhx editor and point the panel at it. On failure
/// the panel is left untouched (the sample keeps showing) and the error logged.
void ui_open(string path)
{
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

    if (mu_begin_menu(ctx, "File"))
    {
        ctx.style.padding = itemPadding;
        // Native async file picker; ui_on_file_picked stashes the result for the
        // next frame to open. null filters means "all files", single-select.
        if (mu_menu_item(ctx, "Open"))
            SDL_ShowOpenFileDialog(&ui_on_file_picked, null, uiWindow, null, 0, null, false);
        if (mu_menu_item(ctx, "Save")) writeln("TODO: File > Save");
        if (mu_menu_item(ctx, "Quit")) writeln("TODO: File > Quit");
        ctx.style.padding = basePadding;
        mu_end_menu(ctx);
    }

    if (mu_begin_menu(ctx, "Edit"))
    {
        ctx.style.padding = itemPadding;
        if (mu_menu_item(ctx, "Copy"))  writeln("TODO: Edit > Copy");
        if (mu_menu_item(ctx, "Paste")) writeln("TODO: Edit > Paste");
        ctx.style.padding = basePadding;
        mu_end_menu(ctx);
    }

    if (mu_begin_menu(ctx, "Help"))
    {
        ctx.style.padding = itemPadding;
        if (mu_menu_item(ctx, "About")) writeln("TODO: Help > About");
        ctx.style.padding = basePadding;
        mu_end_menu(ctx);
    }

    mu_end_menubar(ctx);
}
