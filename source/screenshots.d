/// Debug-only frame capture (`dub build -b screenshots`). Output goes to
/// "screenshots" or `--outdir=PATH`.
///
///   - screenshot_save: dump the backbuffer to BMP (live: Ctrl+Shift+F12).
///   - screenshot_run: headless scripted driver (offscreen SDL) capturing
///     canned UI states for regression checks. Generates its own fixtures.
///     Convert with `rdmd tools/bmp2png.d x.bmp x.png` (or ffmpeg).
///     `--readme`: the assets/screenshot.png pose instead.
///     `--keys`: key binding checks (keys.d), exit 1 on failure.
///     `--all`: every set.
/// Authors: dd86k <dd@dax.moe>
module screenshots;

version (Screenshots):

import core.stdc.string : strncmp, strlen;
import std.string : fromStringz;
import bindbc.sdl;
import ddlogger;
import ddui;
import hexview : HexBase, HEX_KEY_HOME, HEX_KEY_END, HEX_KEY_DEL, HEX_KEY_UNDO, HEX_KEY_REDO,
    HEX_KEY_LEFT, HEX_KEY_RIGHT, HEX_KEY_UP, HEX_KEY_DOWN;
import preferences : prefs;
import omnibar : OMNI_COMMAND, OMNI_ADDRESS, OMNI_FIND, OMNI_INSPECT,
    OMNI_BOOKMARK, OMNI_STRUCTURE, OMNI_HELP, OMNI_KEY_DOWN;
import render;
import ui;
import ddhx.charset : ASCII;
import keys : keys_run;

/// Relative to the working directory.
enum SCREENSHOT_DIR = "screenshots";

/// Create the output directory. Never throws (called from the event loop).
bool screenshot_mkdir(string dir)
{
    import std.file : exists, mkdirRecurse;
    if (exists(dir))
        return true;
    try
        mkdirRecurse(dir);
    catch (Exception)
        return false;
    return true;
}

/// Write the render target to BMP. Call after render_commands, before
/// SDL_RenderPresent (reading after present is undefined on many drivers).
bool screenshot_save(SDL_Renderer* renderer, const(char)* path)
{
    SDL_Surface* surface = SDL_RenderReadPixels(renderer, null);
    if (surface is null)
        return false;
    scope(exit) SDL_DestroySurface(surface);
    return SDL_SaveBMP(surface, path);
}

/// Fixture paths. `mid`: multi-screen document, `other`: second document,
/// `diffB`: `diffA` with overwritten bytes and a tail.
private struct Fixtures
{
    string mid, other, diffA, diffB;
}

/// Write the fixtures. Seeded PRNG so runs produce identical pixels.
private Fixtures screenshot_fixtures()
{
    import std.file : mkdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.random : Xorshift, uniform;

    string dir = buildPath(tempDir, "vddhx-shots");
    mkdirRecurse(dir);

    Xorshift rnd = Xorshift(0x5eed);
    ubyte[] noise(size_t n)
    {
        ubyte[] bytes = new ubyte[n];
        foreach (ref ubyte b; bytes)
            b = cast(ubyte) uniform(0, 256, rnd);
        return bytes;
    }

    Fixtures f;
    f.mid   = buildPath(dir, "mid.bin");
    f.other = buildPath(dir, "other.bin");
    f.diffA = buildPath(dir, "diff-a.bin");
    f.diffB = buildPath(dir, "diff-b.bin");

    // 0x1000: ~8 screens (0x210 visible), so %50, Ctrl+End and find wrap-around
    // actually move.
    write(f.mid, noise(0x1000));
    write(f.other, noise(0x200));

    ubyte[] a = noise(0x800);
    ubyte[] b = a.dup;
    // Differences within the first screen.
    foreach (size_t at; [0x08, 0x09, 0x31, 0x32, 0x33, 0xa0, 0x155, 0x1f0, 0x1f1])
        b[at] = cast(ubyte) ~b[at];
    write(f.diffA, a);
    write(f.diffB, b ~ noise(0x400)); // tail only in diffB
    return f;
}

/// Run each set in a child process: the readme needs another window size, and
/// ui.d's module state has no teardown.
private int screenshot_all(string[] args)
{
    import std.algorithm.iteration : filter;
    import std.array : array;
    import std.file : thisExePath;
    import std.process : spawnProcess, wait;

    // Strip set selectors; added back one at a time.
    string[] base = args[1 .. $]
        .filter!(a => a != "--all" && a != "--readme" && a != "--keys")
        .array;

    foreach (string set; ["", "--readme", "--keys"])
    {
        string[] argv = thisExePath ~ base;
        if (set.length)
            argv ~= set;
        int status = wait(spawnProcess(argv));
        if (status != 0)
        {
            logCritical("screenshot: %s set exited %d",
                set.length ? set : "--screenshot", status);
            return 1;
        }
    }
    return 0;
}

/// Headless capture:
/// `SDL_VIDEODRIVER=offscreen dub run -b screenshots -- --screenshot`.
int screenshot_run(string[] args)
{
    import std.algorithm.searching : canFind, startsWith;
    if (args.canFind("--all"))
        return screenshot_all(args);
    const bool readme = args.canFind("--readme");
    const int W = readme ? 1280 : 800;
    const int H = readme ?  800 : 600;

    string outdir = SCREENSHOT_DIR;
    foreach (string arg; args)
        if (arg.startsWith("--outdir="))
            outdir = arg["--outdir=".length .. $];
    // Report setup failures; a silent failure looks like a successful run.
    if (screenshot_mkdir(outdir) == false)
    {
        logCritical("screenshot: cannot create %s", outdir);
        return 1;
    }

    if (SDL_Init(SDL_INIT_VIDEO) == false)
    {
        logCritical("SDL_Init: %s", SDL_GetError().fromStringz);
        return 1;
    }
    scope(exit) SDL_Quit();

    SDL_Window* window = SDL_CreateWindow("vddhx-shot", W, H, 0);
    if (window is null)
    {
        logCritical("SDL_CreateWindow: %s", SDL_GetError().fromStringz);
        return 1;
    }
    scope(exit) SDL_DestroyWindow(window);

    SDL_Renderer* renderer = render_create(window);
    if (renderer is null)
    {
        logCritical("SDL_CreateRenderer: %s", SDL_GetError().fromStringz);
        return 1;
    }
    scope(exit) SDL_DestroyRenderer(renderer);

    string reason = render_init(renderer);
    if (reason.length)
    {
        logCritical("%s", reason);
        return 1;
    }
    scope(exit) render_quit();

    static mu_Context ctx; // ~4 MB, off the stack
    mu_init(&ctx);
    ctx.text_width  = &render_text_width;
    ctx.text_height = &render_text_height;
    ctx.style.font  = render_font_ui();
    ui_style(&ctx);

    ui_init(window);

    // Discard on close instead of the native Save prompt, which would block.
    uiConfirmAuto = ConfirmAuto.discard;

    // Wait out background walks so the shot shows the result.
    void frame()
    {
        import core.thread : Thread;
        import core.time : msecs;
        import worker : worker_pump;
        while (ui_jobs_busy())
        {
            Thread.sleep(1.msecs);
            worker_pump();
        }
        mu_begin(&ctx); ui_frame(&ctx, W, H); mu_end(&ctx);
    }

    // Find a drawn label so clicks don't hardcode layout. Walks z-order; text is in
    // the frame arena, referenced by offset.
    mu_Vec2 find(const(char)* label)
    {
        mu_Command* cmd;
        while (mu_get_next_command(&ctx, &cmd))
            if (cmd.type == MU_COMMAND_TEXT &&
                strncmp(mu_command_text(&ctx, cmd), label, cast(int) strlen(label)) == 0)
                return cmd.text.pos;

        // Throw, don't return a fallback: callers click at +3, and (2, 2) is the File
        // menu, which left a dropdown over every later shot.
        import std.conv : text;
        import std.string : fromStringz;
        throw new Exception(text("no drawn label matching \"", label.fromStringz, '"'));
    }

    // Two move frames: hover_root lags a frame.
    void click(int x, int y)
    {
        mu_input_mousemove(&ctx, x, y); frame(); frame();
        mu_input_mousedown(&ctx, x, y, MU_MOUSE_LEFT); frame();
        mu_input_mouseup(&ctx, x, y, MU_MOUSE_LEFT); frame();
    }

    void tap(int key) { mu_input_keydown(&ctx, key); frame(); mu_input_keyup(&ctx, key); }

    void chord(int mod, int key)
    {
        mu_input_keydown(&ctx, mod);
        mu_input_keydown(&ctx, key); frame(); mu_input_keyup(&ctx, key);
        mu_input_keyup(&ctx, mod);
    }

    // Report failures here; callers ignore the result.
    bool shot(string name)
    {
        import std.path : buildPath;
        import std.string : toStringz;
        SDL_SetRenderDrawColor(renderer, 30, 30, 46, 255);
        SDL_RenderClear(renderer);
        render_commands(renderer, &ctx);
        string path = buildPath(outdir, name);
        if (screenshot_save(renderer, path.toStringz))
            return true;
        logWarn("screenshot: %s: %s", path, SDL_GetError().fromStringz);
        return false;
    }

    // Readme pose, from the repo's files (run from the repo root). Extra tabs go
    // in the left pane since the omnibar covers the right pane's strip. Focus
    // returns to the left pane without a click, which would drop the selection.
    if (readme)
    {
        ui_open("vddhx");
        ui_open("source/ui.d");
        ui_select_tab(0);
        frame();

        foreach (i; 0 .. 3) tap(HEX_KEY_DOWN);
        ui_mark_toggle();
        foreach (i; 0 .. 2) tap(HEX_KEY_DOWN);
        tap(HEX_KEY_RIGHT); tap(HEX_KEY_RIGHT); tap(HEX_KEY_RIGHT);
        mu_input_keydown(&ctx, MU_KEY_SHIFT);
        foreach (i; 0 .. 5) tap(HEX_KEY_RIGHT);
        mu_input_keyup(&ctx, MU_KEY_SHIFT);
        frame();

        ui_split();
        ui_open("README.md");
        frame(); frame();
        ui_focus_pane(0);

        ui_omni_toggle(OMNI_COMMAND);
        frame();
        mu_input_text(&ctx, "book");
        frame(); frame();
        shot("readme.bmp");
        return 0;
    }

    Fixtures fix = screenshot_fixtures();

    if (args.canFind("--keys"))
        return keys_run(&ctx, &frame, fix.mid);

    // Scenario 0 (debug): multi-row file.
    ui_open(fix.mid);
    frame();
    shot("rows.bmp");

    // Scenario 0b (debug): PNG, for structure colours and borders. Closed after;
    // later scenarios count tabs.
    ui_open("assets/icon/vddhx-256.png");
    frame();
    shot("structure-png.bmp");

    // Hovering a byte shows its field. Needs real time (tooltip delay).
    {
        import core.thread : Thread;
        import core.time : msecs;
        // Three frames: the grid is a nested panel, so hover_root needs one more, and
        // the delay starts after.
        mu_input_mousemove(&ctx, 240, 87);
        frame(); frame(); frame();
        Thread.sleep(600.msecs);
        frame();
        shot("structure-tip.bmp");
        mu_input_mousemove(&ctx, 0, 0);
        frame();
    }

    // '#' list: flat fields with trails. Enter selects the whole span.
    ui_omni_toggle(OMNI_STRUCTURE);
    frame(); frame();
    shot("omni-struct.bmp");

    // The wheel scrolls the view, not the selection; an arrow key scrolls back to
    // the selection.
    mu_input_mousemove(&ctx, 400, 120);
    frame(); frame();
    foreach (i; 0 .. 4) // 30px notches: four rows
    {
        mu_input_scroll(&ctx, 0, 30);
        frame(); frame();
    }
    shot("omni-wheel.bmp");
    tap(OMNI_KEY_DOWN);
    frame(); frame();
    shot("omni-wheel-reveal.bmp");
    mu_input_mousemove(&ctx, 0, 0);
    frame();

    // Walking the list moves the caret, centred in the area the box doesn't cover.
    // Esc restores.
    mu_input_text(&ctx, "idat");
    frame(); frame();
    foreach (i; 0 .. 4) // to the chunk's crc
    {
        tap(OMNI_KEY_DOWN);
        frame(); frame();
    }
    shot("omni-struct-preview.bmp");
    ui_omni_close();
    frame(); frame();
    shot("omni-struct-restored.bmp");

    ui_omni_toggle(OMNI_STRUCTURE);
    frame(); frame();
    mu_input_text(&ctx, "ihdr wid");
    frame(); frame();
    find("IHDR / width"); // matched through the trail
    shot("omni-struct-filter.bmp");
    tap(MU_KEY_RETURN);
    frame();
    shot("omni-struct-jump.bmp");

    ui_close_current_tab();
    frame();

    // Scenario 1: fresh startup.
    frame();
    shot("startup.bmp");

    // Scenario 2: File menu open (z-order regression).
    mu_Vec2 file = find("File");
    click(file.x + 3, file.y + 3);
    frame(); frame(); // autosizing popup settles
    shot("menu.bmp");

    // Scenario 3: editing. Click right of the File dropdown (~200px) to close it.
    click(400, 160);
    mu_input_text(&ctx, "deadbeefcafe");
    frame();
    shot("edit.bmp");

    // Scenario 4: overwrite the first byte, then Delete.
    tap(HEX_KEY_HOME);
    mu_input_text(&ctx, "42");
    frame();
    tap(HEX_KEY_DEL);
    shot("edit-ovr.bmp");

    // Scenario 5: undo/redo.
    chord(MU_KEY_CTRL, HEX_KEY_UNDO);
    shot("undo.bmp");
    chord(MU_KEY_CTRL, HEX_KEY_REDO);
    shot("redo.bmp");

    // Scenario 6: nibble caret. One digit leaves a half byte, caret on the low
    // nibble; Left goes back to the high one.
    tap(HEX_KEY_HOME);
    mu_input_text(&ctx, "a");
    frame();
    shot("nibble-low.bmp");
    tap(HEX_KEY_LEFT);
    shot("nibble-high.bmp");

    // Scenario 7: copy four bytes, paste at EOF.
    tap(HEX_KEY_HOME);
    mu_input_keydown(&ctx, MU_KEY_SHIFT);
    tap(HEX_KEY_RIGHT); tap(HEX_KEY_RIGHT); tap(HEX_KEY_RIGHT);
    mu_input_keyup(&ctx, MU_KEY_SHIFT);
    frame();
    shot("clip-sel.bmp");
    // Text lane copy; non-printables become dots.
    ui_copy_text();
    frame();
    shot("clip-text.bmp");
    ui_copy();
    chord(MU_KEY_CTRL, HEX_KEY_END);
    ui_paste();
    frame();
    shot("clip-paste.bmp");

    // Paste on a bare caret, OVR: overwrites row 0x10's head, size unchanged.
    chord(MU_KEY_CTRL, HEX_KEY_HOME);
    tap(HEX_KEY_DOWN);
    ui_paste();
    frame();
    shot("clip-ovr.bmp");

    // Paste over a two-byte selection at 0x24: replaces it, document grows by 2.
    tap(HEX_KEY_DOWN);
    mu_input_keydown(&ctx, MU_KEY_SHIFT);
    tap(HEX_KEY_RIGHT);
    mu_input_keyup(&ctx, MU_KEY_SHIFT);
    ui_paste();
    frame();
    shot("clip-replace.bmp");

    // Scenario 8: cut the four bytes at 0x24. Caret is at 0x28; unshifted Left
    // moves a nibble while editing, hence 8 taps. Pasting back on a bare caret in
    // OVR overwrites instead of restoring.
    foreach (i; 0 .. 8) tap(HEX_KEY_LEFT);
    mu_input_keydown(&ctx, MU_KEY_SHIFT);
    tap(HEX_KEY_RIGHT); tap(HEX_KEY_RIGHT); tap(HEX_KEY_RIGHT);
    mu_input_keyup(&ctx, MU_KEY_SHIFT);
    ui_cut();
    frame();
    shot("clip-cut.bmp");
    ui_paste();
    frame();
    shot("clip-cut-undone.bmp");

    // Scenario 9: Help > About via the menu (menu placement).
    mu_Vec2 help = find("Help");
    click(help.x + 3, help.y + 3);
    frame(); frame();
    mu_Vec2 about = find("About");
    click(about.x + 3, about.y + 3);
    frame();
    shot("about.bmp");

    // Link hover: highlighted and underlined.
    mu_Vec2 link = find("https://");
    mu_input_mousemove(&ctx, link.x + 3, link.y + 3); frame(); frame();
    shot("about-link.bmp");

    // Scenario 10: three tabs; first has the unsaved dot, scratch in front.
    mu_Vec2 close = find("Close");
    click(close.x + 3, close.y + 3);

    // Scenario 9b: Edit > Settings, one shot per category.
    mu_Vec2 edit = find("Edit");
    click(edit.x + 3, edit.y + 3);
    frame(); frame();
    mu_Vec2 settingsItem = find("Settings");
    click(settingsItem.x + 3, settingsItem.y + 3);
    frame(); frame();
    shot("settings.bmp");
    foreach (string page; ["Appearance", "Defaults"])
    {
        mu_Vec2 at = find(page.ptr); // literals are NUL-terminated
        click(at.x + 3, at.y + 3);
        frame(); frame();
        shot(page == "Defaults" ? "settings-defaults.bmp" : "settings-appearance.bmp");
    }
    ui_close_current_tab();
    frame();
    ui_open(fix.other);
    ui_new_tab();
    frame();
    shot("tabs.bmp");

    // Clicking a tab restores its document, caret and all.
    mu_Vec2 tab = find("mid.bin");
    click(tab.x + 3, tab.y + 3);
    frame();
    shot("tabs-select.bmp");

    // Read-only shows on the tab.
    ui_toggle_readonly();
    frame();
    shot("tab-readonly.bmp");
    ui_toggle_readonly();

    // Tab hover shows the full path. Needs real time (tooltip delay).
    {
        import core.thread : Thread;
        import core.time : msecs;
        mu_Vec2 rest = find("other.bin");
        mu_input_mousemove(&ctx, rest.x + 3, rest.y + 3); frame(); frame();
        Thread.sleep(600.msecs);
        frame();
        shot("tab-tip.bmp");
    }

    // Drag reorders, one step per neighbour middle passed. The middle shot shows
    // the tab drawn at the pointer, overlapping.
    mu_Vec2 grab = find("mid.bin");
    int grabY = grab.y + 3;
    mu_input_mousemove(&ctx, grab.x + 3, grabY); frame(); frame();
    mu_input_mousedown(&ctx, grab.x + 3, grabY, MU_MOUSE_LEFT); frame();
    mu_input_mousemove(&ctx, grab.x + 43, grabY); frame(); frame();
    shot("tabs-drag.bmp");
    // Dragged past the last tab: stops at the last slot.
    mu_input_mousemove(&ctx, grab.x + 500, grabY); frame(); frame();
    shot("tabs-drag2.bmp");
    mu_input_mouseup(&ctx, grab.x + 500, grabY, MU_MOUSE_LEFT); frame(); frame();
    shot("tabs-dropped.bmp");

    // Middle-click closes. other.bin is unmodified, so no prompt.
    mu_Vec2 other = find("other.bin");
    mu_input_mousemove(&ctx, other.x + 3, other.y + 3); frame(); frame();
    mu_input_mousedown(&ctx, other.x + 3, other.y + 3, MU_MOUSE_MIDDLE); frame();
    mu_input_mouseup(&ctx, other.x + 3, other.y + 3, MU_MOUSE_MIDDLE); frame();
    shot("tabs-closed.bmp");

    // Scenario 10d: panes. Same document, separate view; only the focused pane's
    // accent is lit.
    ui_split();
    frame(); frame();
    shot("pane-split.bmp");

    // Moving in the right pane doesn't move the left.
    foreach (i; 0 .. 24) tap(HEX_KEY_DOWN);
    frame();
    shot("pane-apart.bmp");

    // Edits show in both panes.
    mu_input_text(&ctx, "ff");
    frame(); frame();
    shot("pane-shared-edit.bmp");

    ui_split();
    frame(); frame();
    shot("pane-three.bmp");

    // Drag the first splitter; the third pane is unaffected. Weights 500/250/250
    // over 788px: bar at 394..400.
    mu_input_mousemove(&ctx, 397, 300); frame(); frame();
    mu_input_mousedown(&ctx, 397, 300, MU_MOUSE_LEFT); frame();
    mu_input_mousemove(&ctx, 500, 300); frame(); frame();
    shot("pane-resize.bmp");
    mu_input_mouseup(&ctx, 500, 300, MU_MOUSE_LEFT); frame();

    // Clicking a pane focuses it.
    click(60, 300);
    frame();
    shot("pane-focus.bmp");

    // Drops go to the pane under the pointer, not the focused one (now the left).
    ui_drop_hover(700, 300);
    frame();
    shot("drop-hover.bmp");

    ui_drop_file(fix.other, 700, 300);
    frame(); frame();
    shot("drop-landed.bmp");

    // Drag a tab out into another pane, with the target highlighted. Aimed at the
    // leftmost pane's centre to join (outer thirds split, see split_zone).
    mu_Vec2 leaving = find("oth");
    int leavingY = leaving.y + 3;
    mu_input_mousemove(&ctx, leaving.x + 3, leavingY); frame(); frame();
    mu_input_mousedown(&ctx, leaving.x + 3, leavingY, MU_MOUSE_LEFT); frame();
    mu_input_mousemove(&ctx, 250, 300); frame(); frame();
    shot("tab-detached.bmp");

    // The view moves whole; the target takes focus.
    mu_input_mouseup(&ctx, 250, 300, MU_MOUSE_LEFT); frame(); frame();
    shot("tab-handed-over.bmp");

    // Dragging a pane's last tab out closes the pane; a neighbour takes its width.
    // The rightmost pane's strip is at x~630.
    mu_input_mousemove(&ctx, 630, leavingY); frame(); frame();
    mu_input_mousedown(&ctx, 630, leavingY, MU_MOUSE_LEFT); frame();
    mu_input_mousemove(&ctx, 250, 300); frame(); frame();
    mu_input_mouseup(&ctx, 250, 300, MU_MOUSE_LEFT); frame(); frame();
    shot("pane-emptied.bmp");

    // Dropped on the top third: split, preview covers the top half.
    mu_Vec2 upper = find("mid.");
    int upperY = upper.y + 3;
    mu_input_mousemove(&ctx, upper.x + 3, upperY); frame(); frame();
    mu_input_mousedown(&ctx, upper.x + 3, upperY, MU_MOUSE_LEFT); frame();
    mu_input_mousemove(&ctx, 250, 120); frame(); frame();
    shot("tab-split-hover.bmp");

    mu_input_mouseup(&ctx, 250, 120, MU_MOUSE_LEFT); frame(); frame();
    shot("tab-split-done.bmp");

    // Restore for later scenarios.
    ui_close_pane();
    frame(); frame();

    // Regression: dragging a tab down over its grid must not select bytes (it
    // used to select 208). Offsets must match in both shots. The straight-down
    // pull also covers the threshold, which used to check x only.
    click(100, 150);
    frame();
    shot("tab-drag-caret.bmp");

    mu_input_mousemove(&ctx, 330, 49); frame(); frame();
    mu_input_mousedown(&ctx, 330, 49, MU_MOUSE_LEFT); frame();
    mu_input_mousemove(&ctx, 330, 300); frame(); frame();
    shot("tab-drag-held.bmp");
    // Release in the middle; an edge would split.
    mu_input_mousemove(&ctx, 250, 300); frame(); frame();
    mu_input_mouseup(&ctx, 250, 300, MU_MOUSE_LEFT); frame(); frame();

    // Scenario 10e: split down. New pane below in the same column; others don't
    // move.
    ui_split_down();
    frame(); frame();
    shot("pane-split-down.bmp");

    // Lower pane moves alone; upper strip stays dim until clicked.
    foreach (i; 0 .. 12) tap(HEX_KEY_DOWN);
    frame();
    shot("pane-stacked-apart.bmp");

    // Drag the horizontal splitter. Two even panes: boundary near mid-window.
    enum int STACK_X = 100, STACK_Y = 308;
    mu_input_mousemove(&ctx, STACK_X, STACK_Y); frame(); frame();
    mu_input_mousedown(&ctx, STACK_X, STACK_Y, MU_MOUSE_LEFT); frame();
    mu_input_mousemove(&ctx, STACK_X, STACK_Y - 120); frame(); frame();
    shot("pane-stack-resize.bmp");
    mu_input_mouseup(&ctx, STACK_X, STACK_Y - 120, MU_MOUSE_LEFT); frame(); frame();

    // Restore. The closing view shares its document: no prompt.
    ui_close_pane();
    frame(); frame();
    shot("pane-stack-closed.bmp");

    // Drop on a pane's left edge: new column beside it, left-half preview.
    mu_Vec2 sideways = find("other");
    int sidewaysY = sideways.y + 3;
    mu_input_mousemove(&ctx, sideways.x + 3, sidewaysY); frame(); frame();
    mu_input_mousedown(&ctx, sideways.x + 3, sidewaysY, MU_MOUSE_LEFT); frame();
    mu_input_mousemove(&ctx, 480, 300); frame(); frame();
    shot("tab-split-side-hover.bmp");

    mu_input_mouseup(&ctx, 480, 300, MU_MOUSE_LEFT); frame(); frame();
    shot("tab-split-side-done.bmp");

    // Restore.
    ui_close_pane();
    frame(); frame();

    // Scenario 11: omnibar. Ctrl+E is handled in the main loop, so call the entry
    // point. The list lags the query by one frame.
    ui_omni_toggle();
    frame();
    shot("omni.bmp");

    mu_input_text(&ctx, "mid");
    frame(); frame();
    shot("omni-filter.bmp");

    // Down wraps on a single match.
    tap(OMNI_KEY_DOWN);
    shot("omni-down.bmp");

    // Toggling another mode switches instead of closing.
    ui_omni_toggle(OMNI_COMMAND);
    frame(); frame();
    shot("omni-command.bmp");

    // Alias "diff" finds "Compare With...", label shown unchanged.
    mu_input_text(&ctx, "diff");
    frame(); frame();
    shot("omni-alias.bmp");

    ui_omni_toggle(OMNI_HELP);
    frame(); frame();
    shot("omni-help.bmp");

    // Enter on the sheet just closes it.
    tap(MU_KEY_RETURN);
    frame();
    shot("omni-closed.bmp");

    // Switcher: pick a tab by name.
    ui_omni_toggle();
    frame();
    mu_input_text(&ctx, "unt");
    frame(); frame();
    tap(MU_KEY_RETURN);
    frame();
    shot("omni-switched.bmp");

    // Scenario 12: ':' shows a live readout of the target. On mid.bin.
    ui_omni_toggle();
    frame();
    mu_input_text(&ctx, "mid");
    frame(); frame();
    tap(MU_KEY_RETURN);
    frame();

    ui_omni_toggle(OMNI_ADDRESS);
    frame(); frame();
    shot("omni-goto-empty.bmp"); // syntax hint

    mu_input_text(&ctx, "0x40");
    frame(); frame();
    shot("omni-goto.bmp");

    tap(MU_KEY_RETURN);
    frame();
    shot("omni-goto-done.bmp"); // caret on 0x40, scrolled to

    // Relative and percent forms.
    ui_omni_toggle(OMNI_ADDRESS);
    frame();
    mu_input_text(&ctx, "+16");
    frame(); frame();
    shot("omni-goto-relative.bmp");
    ui_omni_close();
    frame();

    ui_omni_toggle(OMNI_ADDRESS);
    frame();
    mu_input_text(&ctx, "%50");
    frame(); frame();
    shot("omni-goto-percent.bmp");
    ui_omni_close();
    frame();

    // Scenario 13: find. Write a needle at the top, caret at the end, so the
    // search wraps.
    chord(MU_KEY_CTRL, HEX_KEY_HOME);
    mu_input_text(&ctx, "cafebabe");
    frame();
    chord(MU_KEY_CTRL, HEX_KEY_END);
    frame();

    ui_omni_toggle(OMNI_FIND);
    frame(); frame();
    shot("omni-find-words.bmp"); // prefix list
    mu_input_text(&ctx, "u");
    frame(); frame();
    shot("omni-find-narrow.bmp"); // narrowed
    mu_input_text(&ctx, "tf16:");
    frame(); frame();
    shot("omni-find-text.bmp"); // prefix only

    // Enter on a prefix fills it in, caret after it.
    ui_omni_close();
    ui_omni_toggle(OMNI_FIND);
    frame();
    mu_input_text(&ctx, "utf1");
    frame(); frame();
    tap(MU_KEY_RETURN);
    frame(); frame();
    mu_input_text(&ctx, "hi");
    frame(); frame();
    shot("omni-find-picked.bmp");

    // Same for Tab, without ddui moving focus away.
    ui_omni_close();
    ui_omni_toggle(OMNI_FIND);
    frame();
    mu_input_text(&ctx, "utf1");
    frame(); frame();
    tap(MU_KEY_TAB);
    frame(); frame();
    shot("omni-find-tab.bmp");
    find("not a pattern yet"); // throws if the box closed

    ui_omni_close();
    ui_omni_toggle(OMNI_FIND);
    frame();
    mu_input_text(&ctx, "0xcafebabe");
    frame(); frame();
    shot("omni-find.bmp"); // pattern bytes preview
    tap(MU_KEY_RETURN);
    frame();
    shot("omni-find-hit.bmp"); // match selected, scrolled to, reported

    // No match is reported.
    ui_omni_toggle(OMNI_FIND);
    frame();
    mu_input_text(&ctx, "utf8:'no such text here'");
    frame(); frame();
    tap(MU_KEY_RETURN);
    frame();
    shot("omni-find-miss.bmp");

    // Pattern write prompt: the row says what Enter writes, or what's wrong.
    tap(HEX_KEY_HOME); // drop the find hit's selection
    ui_write_prompt(false, true);
    frame();
    mu_input_text(&ctx, "0x40:0x7f x:de ad be ef");
    frame(); frame();
    shot("omni-write.bmp");
    ui_omni_close();
    ui_write_prompt(true, true);
    frame();
    mu_input_text(&ctx, "16 deadbeef");
    frame(); frame();
    shot("omni-write-bad.bmp");
    ui_omni_close();
    frame();

    // Scenario 14: inspector, filtered by type name.
    ui_omni_toggle(OMNI_INSPECT);
    frame(); frame();
    shot("omni-inspect.bmp");
    mu_input_text(&ctx, "32");
    frame(); frame();
    shot("omni-inspect-filter.bmp");
    ui_omni_close();
    frame();

    // The document's byte order sorts its half first; both are listed.
    ui_endian_toggle();
    ui_omni_toggle(OMNI_INSPECT);
    frame(); frame();
    shot("omni-inspect-big.bmp");
    ui_omni_close();
    ui_endian_toggle();
    frame();

    // Scenario 14b: columns and charset via the omnibar; restored to 16 columns
    // ASCII after. Random bytes make the charset difference visible.

    // Empty: placeholder, suggested widths, highlight on the current one; grid
    // unchanged.
    ui_columns_prompt();
    frame(); frame();
    shot("prompt-columns.bmp");

    // Walking the list previews on the grid (like '#').
    tap(OMNI_KEY_DOWN); tap(OMNI_KEY_DOWN);
    frame(); frame();
    shot("prompt-columns-browse.bmp");

    // Esc reverts. The revert happens at frame end and shot() takes the last
    // frame, so shots after a take or revert need an extra frame.
    ui_omni_close();
    frame(); frame();
    shot("columns-restored.bmp");

    // Typed width, read back in the pinned row. 48 overflows the pane and clips;
    // the other pane stays at 16 (per view).
    ui_columns_prompt();
    frame();
    mu_input_text(&ctx, "48");
    frame(); frame();
    find("48 bytes to the row");
    shot("prompt-columns-typed.bmp");
    tap(MU_KEY_RETURN);
    frame(); frame();
    shot("columns-48.bmp");

    // Sideways wheel reveals the clipped part, header follows; End brings the
    // caret in, Home goes back. The selection is restored for later scenarios.
    mu_input_mousemove(&ctx, 480, 300);
    frame(); frame();
    foreach (i; 0 .. 6)
    {
        mu_input_scroll(&ctx, 30, 0);
        frame(); frame();
    }
    shot("columns-48-wheel.bmp");
    tap(HEX_KEY_END);
    frame(); frame();
    shot("columns-48-end.bmp");
    tap(HEX_KEY_HOME);
    frame(); frame();
    shot("columns-48-home.bmp");
    mu_input_keydown(&ctx, MU_KEY_SHIFT);
    foreach (i; 0 .. 3)
        tap(HEX_KEY_RIGHT);
    mu_input_keyup(&ctx, MU_KEY_SHIFT);
    frame();

    // Invalid count is reported.
    ui_columns_prompt();
    frame();
    mu_input_text(&ctx, "wide");
    frame(); frame();
    find("not a column count");
    shot("prompt-columns-bad.bmp");
    ui_omni_close();
    frame();

    // "auto" by name.
    ui_columns_prompt();
    frame();
    mu_input_text(&ctx, "auto");
    frame(); frame();
    tap(MU_KEY_RETURN);
    frame(); frame();
    shot("columns-auto.bmp");

    // Charset: closed list, no typing. Walking it previews the text lane.
    ui_charset_prompt();
    frame(); frame();
    shot("prompt-charset.bmp");
    tap(OMNI_KEY_DOWN);
    frame(); frame();
    shot("prompt-charset-browse.bmp");
    tap(MU_KEY_RETURN);
    frame(); frame();
    shot("charset-cp437.bmp");

    // Typing matches short and full names.
    ui_charset_prompt();
    frame();
    mu_input_text(&ctx, "ebc");
    frame(); frame();
    find("ebcdic");
    tap(MU_KEY_RETURN);
    frame(); frame();
    shot("charset-ebcdic.bmp");

    // No chords for either; the command list is the keyboard route. find throws
    // if the row is missing.
    ui_omni_toggle(OMNI_COMMAND);
    frame();
    mu_input_text(&ctx, "set");
    frame(); frame();
    find("Character Set...");
    shot("omni-command-charset.bmp");
    ui_omni_close();
    frame();

    // Offset base: octal by browsing, then decimal by name. Lane headers and the
    // status bar follow. Left on decimal for the View menu shot.
    ui_address_prompt();
    frame(); frame();
    tap(OMNI_KEY_DOWN);
    tap(OMNI_KEY_DOWN);
    frame(); frame();
    shot("prompt-address-browse.bmp");
    tap(MU_KEY_RETURN);
    frame(); frame();
    shot("address-oct.bmp");
    ui_address_prompt();
    frame();
    mu_input_text(&ctx, "dec");
    frame(); frame();
    tap(MU_KEY_RETURN);
    frame(); frame();
    shot("address-dec.bmp");

    // View menu shows both values in the shortcut column. Non-default values, so a
    // hardcoded label would show.
    mu_Vec2 viewMenu = find("View");
    click(viewMenu.x + 3, viewMenu.y + 3);
    frame(); frame();
    shot("menu-view.bmp");
    // Close via an item; clicking outside would move the caret.
    mu_Vec2 inspectItem = find("Inspect Bytes...");
    click(inspectItem.x + 3, inspectItem.y + 3);
    frame(); frame();
    ui_omni_close();
    frame();

    ui_charset_set(&ASCII);
    ui_address_set(HexBase.hex);
    cast(void) ui_columns_set(16);
    // Move the pointer off the tab strip, or later shots show a hovered close box.
    mu_input_mousemove(&ctx, 400, 400);
    frame();

    // Text size: four points up, then back. Grid rows and lanes follow the face.
    foreach (int i; 0 .. 4)
        ui_zoom(1);
    frame(); frame();
    shot("zoom.bmp");
    ui_zoom(0);
    frame();

    // Fonts swap between frames: the UI takes the mono face, the hex font is
    // missing and stays.
    prefs.font = "assets/fonts/DejaVuSansMono.ttf";
    prefs.monofont = "No Such Font";
    ui_fonts(false);
    frame(); frame();
    shot("fonts.bmp");
    prefs.font = prefs.monofont = null;
    ui_fonts(false);
    frame();

    // Scenario 15: bookmarks, one byte then four, in grid and minimap. The mark is
    // under the selection, so shot-mark-range shows after the caret moves.
    ui_mark_toggle();
    frame();
    shot("mark-set.bmp");
    tap(HEX_KEY_DOWN); tap(HEX_KEY_DOWN);
    chord(MU_KEY_SHIFT, HEX_KEY_RIGHT);
    chord(MU_KEY_SHIFT, HEX_KEY_RIGHT);
    chord(MU_KEY_SHIFT, HEX_KEY_RIGHT);
    ui_mark_toggle();
    frame();
    shot("mark-range.bmp");
    ui_omni_toggle(OMNI_BOOKMARK);
    frame(); frame();
    shot("omni-marks.bmp");
    tap(MU_KEY_RETURN);
    frame();
    shot("omni-marks-jump.bmp");

    // Scenario 15b: name the bookmark via a prompt. The status bar and '@' list
    // show the name.
    ui_mark_name();
    frame(); frame();
    mu_input_text(&ctx, "magic");
    frame(); frame();
    shot("mark-name.bmp");
    tap(MU_KEY_RETURN);
    frame();
    shot("mark-named.bmp");
    ui_omni_toggle(OMNI_BOOKMARK);
    frame(); frame();
    shot("omni-marks-named.bmp");
    mu_input_text(&ctx, "mag");
    frame(); frame();
    find("magic"); // found by name
    ui_omni_close();
    frame();

    // A command that reopens the box in another mode (inspector).
    ui_omni_toggle(OMNI_COMMAND);
    frame();
    mu_input_text(&ctx, "inspect");
    frame(); frame();
    tap(MU_KEY_RETURN);
    frame(); frame();
    shot("omni-command-reopen.bmp");
    ui_omni_close();
    frame();

    // Clear all from the command list; the empty list shows a hint.
    ui_omni_toggle(OMNI_COMMAND);
    frame();
    mu_input_text(&ctx, "clear book");
    frame(); frame();
    tap(MU_KEY_RETURN);
    frame();
    ui_omni_toggle(OMNI_BOOKMARK);
    frame(); frame();
    shot("omni-marks-empty.bmp");
    ui_omni_close();
    frame();

    // Scenario 16: skip runs. Write eight zeroes at row 0. Ctrl+Left/Right are
    // main-loop chords, so call the entry point.
    chord(MU_KEY_CTRL, HEX_KEY_HOME);
    mu_input_text(&ctx, "0000000000000000");
    frame();
    chord(MU_KEY_CTRL, HEX_KEY_HOME);
    frame();
    shot("skip-run.bmp");  // caret at 0x00
    ui_skip_element(false);
    frame();
    shot("skip-fwd.bmp");  // past the zeroes: 0x08
    ui_skip_element(true);
    frame();
    shot("skip-back.bmp"); // 0x07, the run's last byte
    ui_skip_element(true);
    frame();
    shot("skip-back2.bmp"); // back to 0x00

    // Shift selects the run, not the byte after it.
    ui_skip_element(false, true);
    frame();
    shot("skip-grow.bmp");  // 0x00-0x07 selected
    ui_skip_element(false, true);
    frame();
    shot("skip-grow2.bmp"); // extends over the next run

    // Backward with nothing different below: ends at 0x00.
    chord(MU_KEY_CTRL, HEX_KEY_HOME);
    foreach (i; 0 .. 16) tap(HEX_KEY_RIGHT); // a nibble each: 8 bytes
    frame();
    ui_skip_element(true, true);
    frame();
    shot("skip-grow-back.bmp"); // 0x00-0x08

    // Selection is the element: three identical 4-byte records at 0x10, first
    // selected. Skips record-wise, keeps the selection, lands on 0x1c (not 0x14).
    chord(MU_KEY_CTRL, HEX_KEY_HOME);
    tap(HEX_KEY_DOWN);
    mu_input_text(&ctx, "cafe0001cafe0001cafe0001");
    frame();
    chord(MU_KEY_CTRL, HEX_KEY_HOME); // back to the run's head
    tap(HEX_KEY_DOWN);
    mu_input_keydown(&ctx, MU_KEY_SHIFT);
    tap(HEX_KEY_RIGHT); tap(HEX_KEY_RIGHT); tap(HEX_KEY_RIGHT);
    mu_input_keyup(&ctx, MU_KEY_SHIFT);
    frame();
    shot("skip-sel.bmp");      // cafe0001 at 0x10
    ui_skip_element(false);
    frame();
    shot("skip-sel-fwd.bmp");  // past the run, selection kept
    ui_skip_element(true);
    frame();
    shot("skip-sel-back.bmp"); // back onto the last record

    // Clicking outside closes without taking.
    ui_omni_toggle();
    frame();
    click(400, 400);
    frame();
    shot("omni-dismissed.bmp");

    // Scenario 17: diff, with fresh fixtures (diffB = diffA, some bytes changed,
    // plus a tail). diffA draws normally; diffB carries the colouring (dim where
    // equal, red where not).
    ui_open(fix.diffA);
    frame();
    ui_compare_with(fix.diffB);
    frame();
    shot("diff.bmp");

    // Scrolling one side scrolls the other; offsets must still line up.
    mu_input_mousemove(&ctx, 300, 300); // over diff-b.bin's pane
    frame();
    mu_input_scroll(&ctx, 0, 200);
    frame(); frame();
    shot("diff-scrolled.bmp");

    // Past the shorter file's end: diffA stops at its last screen, diffB
    // continues into added bytes. The follower lags a frame during scrolling, so
    // let them settle (also checks that they do).
    foreach (i; 0 .. 10)
    {
        mu_input_scroll(&ctx, 0, 600);
        frame();
    }
    frame(); frame(); frame();
    shot("diff-tail.bmp");

    // Closing one side ends the diff; diffA's pane returns to normal. diffB has no
    // edits: no prompt.
    ui_close_current_tab(); // focused pane is the diff's
    frame(); frame();
    shot("diff-closed.bmp");

    // Scenario 18: menu items that open the omnibar, clicked with the mouse
    // (regression: the box closed on the opening click). One shot for the sheet;
    // the rest check for a row of the expected mode.
    static immutable string[3][9] raises = [
        [ "Help",      "Keyboard Shortcuts...", "Omnibar: this sheet" ],
        [ "Search",    "Find...",               "bytes as written" ],
        [ "Search",    "Go to Offset...",       "waiting for an offset" ],
        [ "View",      "Inspect Bytes...",      "u8" ],
        [ "View",      "Columns...",            "fit the row to the pane" ],
        [ "View",      "Character Set...",      "IBM PC Code Page 437" ],
        [ "View",      "Offset Format...",      "Octal" ],
        [ "Bookmarks", "List Bookmarks...",     "no bookmarks in this document" ],
        [ "Bookmarks", "Name Bookmark...",      "type a name, Enter to set" ],
    ];
    foreach (ref immutable string[3] step; raises)
    {
        mu_Vec2 title = find(step[0].ptr);
        click(title.x + 3, title.y + 3);
        frame(); frame();
        mu_Vec2 item = find(step[1].ptr);
        click(item.x + 3, item.y + 3);
        frame(); frame();
        find(step[2].ptr); // throws if the box closed
        if (step[1] == "Keyboard Shortcuts...")
            shot("menu-keys.bmp");
        ui_omni_close();
        frame();
    }
    ui_mark_clear(); // Name Bookmark marked the caret
    frame();

    // Scenario 19: easter egg. Last: it leaves two dialogs stacked that confuse
    // find(). The About version line isn't a label.
    mu_Vec2 helpMenu = find("Help");
    click(helpMenu.x + 3, helpMenu.y + 3);
    frame(); frame();
    mu_Vec2 aboutItem = find("About");
    click(aboutItem.x + 3, aboutItem.y + 3);
    frame();
    mu_Vec2 versionLine = find("vddhx ");
    click(versionLine.x + 3, versionLine.y + 3);
    // Fixed step per frame (see elite.d): 90 frames pose it at three quarters,
    // reproducibly.
    foreach (i; 0 .. 90) frame();
    shot("elite.bmp");

    return 0;
}
