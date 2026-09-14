/// Debug-only frame capture. Compiled in only under `version (Screenshots)`
/// (see the "screenshots" buildType in dub.sdl): `dub build -b screenshots`.
///
/// Everything written lands in the output directory, "screenshots" unless
/// `--outdir=PATH` says otherwise.
///
/// Two entry points share one capture primitive:
///   - screenshot_save: dump the current renderer backbuffer to a BMP. main
///     calls this live when Ctrl+Shift+F12 is pressed.
///   - screenshot_run: a headless, scripted driver (offscreen SDL) that renders
///     canned UI states and captures each, so visual regressions can be checked
///     without a display. It writes its own input files (see Fixtures), so a run
///     needs nothing but the executable. Convert the BMPs with
///     `rdmd tools/bmp2png.d x.bmp x.png` (or ffmpeg, if it is around).
///     Adding `--readme` runs one posed scenario instead of the regression set,
///     which is where assets/screenshot.png comes from.
/// Authors: dd86k <dd@dax.moe>
module screenshots;

version (Screenshots):

import core.stdc.string : strncmp, strlen;
import std.string : fromStringz;
import bindbc.sdl;
import ddlogger;
import ddui;
import hexview : HEX_KEY_HOME, HEX_KEY_END, HEX_KEY_DEL, HEX_KEY_UNDO, HEX_KEY_REDO,
    HEX_KEY_LEFT, HEX_KEY_RIGHT, HEX_KEY_UP, HEX_KEY_DOWN;
import omnibar : OMNI_COMMAND, OMNI_ADDRESS, OMNI_FIND, OMNI_INSPECT,
    OMNI_BOOKMARK, OMNI_STRUCTURE, OMNI_HELP, OMNI_KEY_DOWN;
import render;
import ui;

/// Default output directory, relative to the working directory.
enum SCREENSHOT_DIR = "screenshots";

/// Create the output directory if it is not already there. Never throws: the
/// live Ctrl+Shift+F12 path calls this from inside the event loop.
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

/// Read the renderer's current target into an SDL surface and write it as BMP.
/// Call after render_commands and before SDL_RenderPresent so the backbuffer
/// holds a complete frame (reading after present is undefined on many drivers).
bool screenshot_save(SDL_Renderer* renderer, const(char)* path)
{
    SDL_Surface* surface = SDL_RenderReadPixels(renderer, null);
    if (surface is null)
        return false;
    scope(exit) SDL_DestroySurface(surface);
    return SDL_SaveBMP(surface, path);
}

/// Paths to the scenarios' input files: `mid` is the multi-screen document most
/// of them work on, `other` a second name for tabs and panes to show, and
/// `diffB` is `diffA` with bytes overwritten and a tail added.
private struct Fixtures
{
    string mid, other, diffA, diffB;
}

/// Write the scenarios' input files and return their paths.
///
/// Made on the fly rather than committed so a run needs nothing but the
/// executable, and seeded rather than truly random so two runs produce the same
/// pixels - the whole point of the set is comparing one run against the last.
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

    // 0x1000 so the goto, find and scroll scenarios have somewhere to go: the
    // window holds about 0x210 bytes, so %50 and Ctrl+End are real jumps and a
    // find started at the end has to wrap to reach a needle written at the top.
    write(f.mid, noise(0x1000));
    write(f.other, noise(0x200));

    ubyte[] a = noise(0x800);
    ubyte[] b = a.dup;
    // Differences inside the first screenful, or diff.bmp is a wall of agreement.
    foreach (size_t at; [0x08, 0x09, 0x31, 0x32, 0x33, 0xa0, 0x155, 0x1f0, 0x1f1])
        b[at] = cast(ubyte) ~b[at];
    write(f.diffA, a);
    write(f.diffB, b ~ noise(0x400)); // the tail diffA does not have
    return f;
}

/// Run both sets, one child process each. They cannot share a process: the two
/// want different window sizes, and ui.d's module state (docs, columns, panes)
/// has no teardown, so the second set would start on whatever the first left
/// behind. Re-running the executable is the prototype's way out of both.
private int screenshot_all(string[] args)
{
    import std.algorithm.iteration : filter;
    import std.array : array;
    import std.file : thisExePath;
    import std.process : spawnProcess, wait;

    // Everything but the set selectors, which this adds back one at a time.
    string[] base = args[1 .. $]
        .filter!(a => a != "--all" && a != "--readme")
        .array;

    foreach (string set; ["", "--readme"])
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

/// Headless capture of a few UI states. Run with SDL_VIDEODRIVER=offscreen:
/// `SDL_VIDEODRIVER=offscreen dub run -b screenshots -- --screenshot`.
int screenshot_run(string[] args)
{
    // `--readme` poses one showcase frame for the project page instead of running
    // the regression scenarios: a wider window and real files. `--all` is both.
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
    // Each of these used to fail mute, and main threw the status away on top, so a
    // run that set nothing up looked exactly like one that wrote every shot.
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

    SDL_Renderer* renderer = SDL_CreateRenderer(window, null);
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

    static mu_Context ctx; // ~4 MB; keep it off the stack
    mu_init(&ctx);
    ctx.text_width  = &render_text_width;
    ctx.text_height = &render_text_height;
    ctx.style.font  = render_font_ui();
    ui_style(&ctx);

    ui_init(window);

    // Closing the last view of an edited document would otherwise reach for the
    // native Save / Don't Save box (and, on Save, the Save As dialog behind it),
    // which blocks a scripted run on a window nothing is there to click. This is
    // what lets scenarios close panes without balancing every edit first.
    uiConfirmAuto = ConfirmAuto.discard;

    void frame() { mu_begin(&ctx); ui_frame(&ctx, W, H); mu_end(&ctx); }

    // Locate a drawn label so scripted clicks do not hardcode layout maths. The
    // walk is in z-index order and the string lives in the per-frame arena, the
    // command carrying only an offset into it.
    mu_Vec2 find(const(char)* label)
    {
        mu_Command* cmd;
        while (mu_get_next_command(&ctx, &cmd))
            if (cmd.type == MU_COMMAND_TEXT &&
                strncmp(mu_command_text(&ctx, cmd), label, cast(int) strlen(label)) == 0)
                return cmd.text.pos;

        // Not (-1, -1): every caller adds 3 to it and clicks, and (2, 2) is the
        // File menubar, so a miss left a dropdown over every shot after it.
        import std.conv : text;
        import std.string : fromStringz;
        throw new Exception(text("no drawn label matching \"", label.fromStringz, '"'));
    }

    // Two move frames: hover_root lags input by a frame, so the control under
    // the cursor only registers hover on the second.
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

    // Every caller ignores the result, so a capture that fails has to say so here
    // or the run just comes up short of files.
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

    // The showcase frame, off the repo's own files (run it from the repo root).
    //
    // Both extra tabs go in the left pane: the box floats over the middle of the
    // window, where the right pane's strip is, and a tab nobody can see shows
    // nothing off. The keyboard goes back to the left pane at the end without
    // clicking into it, which would drop the selection.
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

    // Scenario 0 (debug): open a multi-row file so offsets past 0x0F appear.
    ui_open(fix.mid);
    frame();
    shot("rows.bmp");

    // Scenario 0b (debug): a PNG, which the layout system recognises, so the shot
    // carries the field colours and the borders round the signature and the first
    // chunks. Closed again straight away: every scenario after this one counts tabs.
    ui_open("assets/icon/vddhx-256.png");
    frame();
    shot("layout-png.bmp");

    // The pointer resting on a byte names the field it is in, the same way a tab names
    // its path. Real time has to pass, for the reason the tab tip scenario says.
    {
        import core.thread : Thread;
        import core.time : msecs;
        // Three settle frames, not the two a tab needs: the grid is a nested panel, so
        // hover_root takes the extra one to reach it, and the delay only starts
        // counting once the panel says the pointer is on a byte.
        mu_input_mousemove(&ctx, 240, 87);
        frame(); frame(); frame();
        Thread.sleep(600.msecs);
        frame();
        shot("layout-tip.bmp");
        mu_input_mousemove(&ctx, 0, 0);
        frame();
    }

    // The '#' list over the same document: what the layout found, flat, with the
    // trail in the label so a field reads as the chunk it belongs to. Enter selects
    // the whole span rather than dropping the caret on its head.
    ui_omni_toggle(OMNI_STRUCTURE);
    frame(); frame();
    shot("omni-struct.bmp");

    // Walking the list takes the caret with it, the field centred in what the box is
    // not covering rather than scrolled to just inside the panel - which would be
    // behind the box. Esc puts the browse back where it started.
    mu_input_text(&ctx, "idat");
    frame(); frame();
    foreach (i; 0 .. 4) // down to the chunk's crc, at the far end of its payload
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
    find("IHDR / width"); // the trail is what the query matched through
    shot("omni-struct-filter.bmp");
    tap(MU_KEY_RETURN);
    frame();
    shot("omni-struct-jump.bmp");

    ui_close_current_tab();
    frame();

    // Scenario 1: fresh startup.
    frame();
    shot("startup.bmp");

    // Scenario 2: File menu open (the state the z-order bug broke).
    mu_Vec2 file = find("File");
    click(file.x + 3, file.y + 3);
    frame(); frame(); // let the autosizing popup settle
    shot("menu.bmp");

    // Scenario 3: modal editing. The click has to clear the File dropdown scenario
    // 2 left open, which covers the left ~200px, so it lands to the right of it.
    click(400, 160);
    mu_input_text(&ctx, "deadbeefcafe");
    frame();
    shot("edit.bmp");

    // Scenario 4: overwrite the first byte in place, then Delete the one under the
    // caret.
    tap(HEX_KEY_HOME);
    mu_input_text(&ctx, "42");
    frame();
    tap(HEX_KEY_DEL);
    shot("edit-ovr.bmp");

    // Scenario 5: history. Ctrl+Z rolls the edits back, Ctrl+Y rolls them forward.
    chord(MU_KEY_CTRL, HEX_KEY_UNDO);
    shot("undo.bmp");
    chord(MU_KEY_CTRL, HEX_KEY_REDO);
    shot("redo.bmp");

    // Scenario 6: nibble caret. A lone hex digit leaves a half-built byte, whose
    // low nibble alone the caret should box; Left then walks back onto its high
    // digit.
    tap(HEX_KEY_HOME);
    mu_input_text(&ctx, "a");
    frame();
    shot("nibble-low.bmp");
    tap(HEX_KEY_LEFT);
    shot("nibble-high.bmp");

    // Scenario 7: clipboard round-trip. Copy the first four bytes and paste them
    // at EOF, where the same four should reappear.
    tap(HEX_KEY_HOME);
    mu_input_keydown(&ctx, MU_KEY_SHIFT);
    tap(HEX_KEY_RIGHT); tap(HEX_KEY_RIGHT); tap(HEX_KEY_RIGHT);
    mu_input_keyup(&ctx, MU_KEY_SHIFT);
    frame();
    shot("clip-sel.bmp");
    // The same four as the text lane draws them, non-printable bytes becoming dots.
    ui_copy_text();
    frame();
    shot("clip-text.bmp");
    ui_copy();
    chord(MU_KEY_CTRL, HEX_KEY_END);
    ui_paste();
    frame();
    shot("clip-paste.bmp");

    // Same four bytes pasted onto a bare caret mid-document: OVR is on, so they
    // overwrite the head of row 0x10 in place and the document keeps its size.
    chord(MU_KEY_CTRL, HEX_KEY_HOME);
    tap(HEX_KEY_DOWN);
    ui_paste();
    frame();
    shot("clip-ovr.bmp");

    // And onto a two-byte selection (the pair at 0x24, Shift+Right once): the
    // selection goes and the four bytes take its place, growing the document by
    // the two bytes of difference.
    tap(HEX_KEY_DOWN);
    mu_input_keydown(&ctx, MU_KEY_SHIFT);
    tap(HEX_KEY_RIGHT);
    mu_input_keyup(&ctx, MU_KEY_SHIFT);
    ui_paste();
    frame();
    shot("clip-replace.bmp");

    // Scenario 8: cut the four bytes just pasted at 0x24, the row closing over the
    // gap. The previous paste left the caret at 0x28 and an unshifted Left walks a
    // nibble at a time while editing, hence eight taps back to 0x24; the shifted
    // Rights move whole bytes. Pasting after the cut lands them at that same
    // offset, though on a bare caret in OVR mode they overwrite the four that
    // closed the gap rather than restoring what was there.
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

    // Scenario 9: Help > About. Walk the menu the way a user would, so the
    // dialog is captured with the placement the menu route gives it.
    mu_Vec2 help = find("Help");
    click(help.x + 3, help.y + 3);
    frame(); frame();
    mu_Vec2 about = find("About");
    click(about.x + 3, about.y + 3);
    frame();
    shot("about.bmp");

    // And again with the cursor on the homepage link, which should light up and
    // underline it.
    mu_Vec2 link = find("https://");
    mu_input_mousemove(&ctx, link.x + 3, link.y + 3); frame(); frame();
    shot("about-link.bmp");

    // Scenario 10: tabs. Three of them, the first carrying the unsaved dot the
    // scenarios above earned it, the scratch buffer in front.
    mu_Vec2 close = find("Close");
    click(close.x + 3, close.y + 3);
    ui_open(fix.other);
    ui_new_tab();
    frame();
    shot("tabs.bmp");

    // Clicking a tab brings its document back, bytes, caret and all.
    mu_Vec2 tab = find("mid.bin");
    click(tab.x + 3, tab.y + 3);
    frame();
    shot("tabs-select.bmp");

    // The pointer resting on a tab puts the document's full path up, which is what
    // the tab has no room for. Real time has to pass: the tip is on a delay, and a
    // scripted run draws its frames faster than a hand can hold still.
    {
        import core.thread : Thread;
        import core.time : msecs;
        mu_Vec2 rest = find("other.bin");
        mu_input_mousemove(&ctx, rest.x + 3, rest.y + 3); frame(); frame();
        Thread.sleep(600.msecs);
        frame();
        shot("tab-tip.bmp");
    }

    // Dragging a tab sideways reorders the strip, each move past a neighbour's
    // middle reporting one step, so the two moves below walk mid.bin from the
    // front of the strip to the back. The tab is drawn from the pointer while this
    // goes on, so the middle shot catches it overlapping what it just swapped with.
    mu_Vec2 grab = find("mid.bin");
    int grabY = grab.y + 3;
    mu_input_mousemove(&ctx, grab.x + 3, grabY); frame(); frame();
    mu_input_mousedown(&ctx, grab.x + 3, grabY, MU_MOUSE_LEFT); frame();
    mu_input_mousemove(&ctx, grab.x + 43, grabY); frame(); frame();
    shot("tabs-drag.bmp");
    // Yanked into the bare strip past the last tab: it stops on the last slot
    // rather than following the pointer out there.
    mu_input_mousemove(&ctx, grab.x + 500, grabY); frame(); frame();
    shot("tabs-drag2.bmp");
    mu_input_mouseup(&ctx, grab.x + 500, grabY, MU_MOUSE_LEFT); frame(); frame();
    shot("tabs-dropped.bmp");

    // Middle-clicking closes without guessing where the close box sits. other.bin
    // has no unsaved edits, so it goes without a prompt (which needs a display).
    mu_Vec2 other = find("other.bin");
    mu_input_mousemove(&ctx, other.x + 3, other.y + 3); frame(); frame();
    mu_input_mousedown(&ctx, other.x + 3, other.y + 3, MU_MOUSE_MIDDLE); frame();
    mu_input_mouseup(&ctx, other.x + 3, other.y + 3, MU_MOUSE_MIDDLE); frame();
    shot("tabs-closed.bmp");

    // Scenario 10d: panes. The second shows the same document through a view of
    // its own, and only the focused pane lights its tab accent.
    ui_split();
    frame(); frame();
    shot("pane-split.bmp");

    // Walking the right-hand pane down must not move the left one, which has its
    // own caret and scroll position on the same bytes.
    foreach (i; 0 .. 24) tap(HEX_KEY_DOWN);
    frame();
    shot("pane-apart.bmp");

    // An edit in one pane is an edit to the document, so both redraw with it.
    mu_input_text(&ctx, "ff");
    frame(); frame();
    shot("pane-shared-edit.bmp");

    ui_split();
    frame(); frame();
    shot("pane-three.bmp");

    // Dragging the first splitter right trades width between the two panes either
    // side of it, the third not being on that boundary. Three panes at weights
    // 500/250/250 over 788px put it at x=394, so the bar spans 394..400.
    mu_input_mousemove(&ctx, 397, 300); frame(); frame();
    mu_input_mousedown(&ctx, 397, 300, MU_MOUSE_LEFT); frame();
    mu_input_mousemove(&ctx, 500, 300); frame(); frame();
    shot("pane-resize.bmp");
    mu_input_mouseup(&ctx, 500, 300, MU_MOUSE_LEFT); frame();

    // Clicking into a pane is what moves the keyboard to it: the accent on the
    // left pane's tab lights and the right one's goes dim.
    click(60, 300);
    frame();
    shot("pane-focus.bmp");

    // A drop opens in the pane under the pointer rather than the one with the
    // keyboard, which after the click above is the left one - so a drop aimed at
    // the rightmost pane only lands there if the coordinates are honoured.
    ui_drop_hover(700, 300);
    frame();
    shot("drop-hover.bmp");

    ui_drop_file(fix.other, 700, 300);
    frame(); frame();
    shot("drop-landed.bmp");

    // A tab dragged out of its own strip into another pane, drawn over the panes it
    // crosses with the one it would land in picked out. other.bin sits in the
    // rightmost pane after the drop above.
    //
    // Aimed at the middle of the leftmost pane: the outer third each way splits it
    // rather than joins it (see split_zone), and this is the joining gesture.
    mu_Vec2 leaving = find("othe");
    int leavingY = leaving.y + 3;
    mu_input_mousemove(&ctx, leaving.x + 3, leavingY); frame(); frame();
    mu_input_mousedown(&ctx, leaving.x + 3, leavingY, MU_MOUSE_LEFT); frame();
    mu_input_mousemove(&ctx, 250, 300); frame(); frame();
    shot("tab-detached.bmp");

    // The view goes across whole, caret and all, and the destination takes the
    // keyboard.
    mu_input_mouseup(&ctx, 250, 300, MU_MOUSE_LEFT); frame(); frame();
    shot("tab-handed-over.bmp");

    // Dragging out a pane's *last* tab leaves that pane with nothing to show, so
    // the row shuts over it and its width goes to a neighbour. The rightmost pane
    // is down to one tab after the handover above; its strip sits around x=630.
    mu_input_mousemove(&ctx, 630, leavingY); frame(); frame();
    mu_input_mousedown(&ctx, 630, leavingY, MU_MOUSE_LEFT); frame();
    mu_input_mousemove(&ctx, 250, 300); frame(); frame();
    mu_input_mouseup(&ctx, 250, 300, MU_MOUSE_LEFT); frame(); frame();
    shot("pane-emptied.bmp");

    // The same drag aimed at the top third of a pane is a split, so the preview
    // covers only the half the newcomer would take and letting go puts it in a
    // pane of its own above.
    mu_Vec2 upper = find("mid.");
    int upperY = upper.y + 3;
    mu_input_mousemove(&ctx, upper.x + 3, upperY); frame(); frame();
    mu_input_mousedown(&ctx, upper.x + 3, upperY, MU_MOUSE_LEFT); frame();
    mu_input_mousemove(&ctx, 250, 120); frame(); frame();
    shot("tab-split-hover.bmp");

    mu_input_mouseup(&ctx, 250, 120, MU_MOUSE_LEFT); frame(); frame();
    shot("tab-split-done.bmp");

    // Put it back the way the scenarios below expect.
    ui_close_pane();
    frame(); frame();

    // Dragging a tab down over its own pane's grid must not drag the selection with
    // it: the panel is handed focus when its tab is picked, which put it in reach
    // of a drag it never started, and this used to sweep out a 208-byte selection.
    // The offset has to read the same in both shots.
    //
    // The pull is straight down, which also covers the drag threshold: measured on
    // x alone, this gesture lifted nothing at all.
    click(100, 150);
    frame();
    shot("tab-drag-caret.bmp");

    mu_input_mousemove(&ctx, 330, 49); frame(); frame();
    mu_input_mousedown(&ctx, 330, 49, MU_MOUSE_LEFT); frame();
    mu_input_mousemove(&ctx, 330, 300); frame(); frame();
    shot("tab-drag-held.bmp");
    // Back to the middle before letting go: dropped against an edge this would
    // split, and the gesture under test is one that changes nothing.
    mu_input_mousemove(&ctx, 250, 300); frame(); frame();
    mu_input_mouseup(&ctx, 250, 300, MU_MOUSE_LEFT); frame(); frame();

    // Scenario 10e: splitting the other way. The new pane goes under the focused
    // one inside its own column, so the panes beside it do not move at all.
    ui_split_down();
    frame(); frame();
    shot("pane-split-down.bmp");

    // Walking the lower pane leaves the upper where it was, the same as side by
    // side, and its strip stays dim until it is clicked into.
    foreach (i; 0 .. 12) tap(HEX_KEY_DOWN);
    frame();
    shot("pane-stacked-apart.bmp");

    // The bar between them is a splitter like any other, dragged up and down. The
    // column runs from under the toolbar to the status bar, so two even panes put
    // the boundary near the middle of the window.
    enum int STACK_X = 100, STACK_Y = 308;
    mu_input_mousemove(&ctx, STACK_X, STACK_Y); frame(); frame();
    mu_input_mousedown(&ctx, STACK_X, STACK_Y, MU_MOUSE_LEFT); frame();
    mu_input_mousemove(&ctx, STACK_X, STACK_Y - 120); frame(); frame();
    shot("pane-stack-resize.bmp");
    mu_input_mouseup(&ctx, STACK_X, STACK_Y - 120, MU_MOUSE_LEFT); frame(); frame();

    // Put the stack away again, leaving the window as the scenarios after this
    // expect it. The closing view shares its document, so nothing prompts.
    ui_close_pane();
    frame(); frame();
    shot("pane-stack-closed.bmp");

    // The sideways half of the drag-to-split gesture: let go against a pane's left
    // edge, the tab takes a column of its own beside it, so the preview is the left
    // half rather than the top and the panes end up side by side.
    mu_Vec2 sideways = find("other");
    int sidewaysY = sideways.y + 3;
    mu_input_mousemove(&ctx, sideways.x + 3, sidewaysY); frame(); frame();
    mu_input_mousedown(&ctx, sideways.x + 3, sidewaysY, MU_MOUSE_LEFT); frame();
    mu_input_mousemove(&ctx, 480, 300); frame(); frame();
    shot("tab-split-side-hover.bmp");

    mu_input_mouseup(&ctx, 480, 300, MU_MOUSE_LEFT); frame(); frame();
    shot("tab-split-side-done.bmp");

    // And away again, leaving the two panes the scenarios below expect.
    ui_close_pane();
    frame(); frame();

    // Scenario 11: the omnibar. Ctrl+E is a main-loop chord, so the driver calls
    // the entry point that key reaches. The list is matched against the query as it
    // stood when the frame began, so typing and showing the result are two frames.
    ui_omni_toggle();
    frame();
    shot("omni.bmp");

    mu_input_text(&ctx, "mid");
    frame(); frame();
    shot("omni-filter.bmp");

    // Down walks the list; with one match left it wraps back onto it.
    tap(OMNI_KEY_DOWN);
    shot("omni-down.bmp");

    // Toggling to a mode the box is not in switches it rather than closing, so
    // these calls swap the list under the same box.
    ui_omni_toggle(OMNI_COMMAND);
    frame(); frame();
    shot("omni-command.bmp");

    // "diff" is not a word on any row and should still bring "Compare With..." up,
    // reading as its own label with no sign of the term that found it.
    mu_input_text(&ctx, "diff");
    frame(); frame();
    shot("omni-alias.bmp");

    ui_omni_toggle(OMNI_HELP);
    frame(); frame();
    shot("omni-help.bmp");

    // The shortcut sheet has nothing to run, so Enter here is the route that just
    // puts the box away and hands the bytes back.
    tap(MU_KEY_RETURN);
    frame();
    shot("omni-closed.bmp");

    // The switcher: name a tab, take it, and the panel behind shows that document.
    ui_omni_toggle();
    frame();
    mu_input_text(&ctx, "unt");
    frame(); frame();
    tap(MU_KEY_RETURN);
    frame();
    shot("omni-switched.bmp");

    // Scenario 12: ':' reads an offset instead of filtering a list, so its one row
    // is a live readout of where Enter would land. Back on mid.bin for it.
    ui_omni_toggle();
    frame();
    mu_input_text(&ctx, "mid");
    frame(); frame();
    tap(MU_KEY_RETURN);
    frame();

    ui_omni_toggle(OMNI_ADDRESS);
    frame(); frame();
    shot("omni-goto-empty.bmp"); // nothing typed yet: the syntax it wants

    mu_input_text(&ctx, "0x40");
    frame(); frame();
    shot("omni-goto.bmp");

    tap(MU_KEY_RETURN);
    frame();
    shot("omni-goto-done.bmp"); // caret on 0x40, the view scrolled onto it

    // Relative and percentage forms, from where that jump left the caret.
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

    // Scenario 13: find. The document is random bytes, so the scenario writes its
    // own needle at the top, then sends the caret to the far end so the search has
    // to walk the whole document and wrap to come back to it.
    chord(MU_KEY_CTRL, HEX_KEY_HOME);
    mu_input_text(&ctx, "cafebabe");
    frame();
    chord(MU_KEY_CTRL, HEX_KEY_END);
    frame();

    ui_omni_toggle(OMNI_FIND);
    frame(); frame();
    shot("omni-find-words.bmp"); // nothing typed: the list is the vocabulary
    mu_input_text(&ctx, "u");
    frame(); frame();
    shot("omni-find-narrow.bmp"); // ...narrowed to the words that open with it
    mu_input_text(&ctx, "tf16:");
    frame(); frame();
    shot("omni-find-text.bmp"); // a prefix and nothing behind it yet

    // Enter on a word writes it into the box rather than running anything, and
    // leaves the caret behind it: what is typed next lands after the prefix.
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

    // Tab means the same, and only that: ddui would have walked the focus off the
    // query box, which the omnibar reads as being clicked away from.
    ui_omni_close();
    ui_omni_toggle(OMNI_FIND);
    frame();
    mu_input_text(&ctx, "utf1");
    frame(); frame();
    tap(MU_KEY_TAB);
    frame(); frame();
    shot("omni-find-tab.bmp");
    find("not a pattern yet"); // throws if the box closed on the keystroke

    ui_omni_close();
    ui_omni_toggle(OMNI_FIND);
    frame();
    mu_input_text(&ctx, "0xcafebabe");
    frame(); frame();
    shot("omni-find.bmp"); // the bytes the pattern comes to, before running it
    tap(MU_KEY_RETURN);
    frame();
    shot("omni-find-hit.bmp"); // match selected, scrolled onto, reported below

    // A pattern that is nowhere in the document says so rather than going quiet.
    ui_omni_toggle(OMNI_FIND);
    frame();
    mu_input_text(&ctx, "utf8:'no such text here'");
    frame(); frame();
    tap(MU_KEY_RETURN);
    frame();
    shot("omni-find-miss.bmp");

    // Scenario 14: the inspector, filterable by typing part of a type name.
    ui_omni_toggle(OMNI_INSPECT);
    frame(); frame();
    shot("omni-inspect.bmp");
    mu_input_text(&ctx, "32");
    frame(); frame();
    shot("omni-inspect-filter.bmp");
    ui_omni_close();
    frame();

    // The document's byte order brings its half of the list to the front; both
    // orders stay on it either way.
    ui_endian_toggle();
    ui_omni_toggle(OMNI_INSPECT);
    frame(); frame();
    shot("omni-inspect-big.bmp");
    ui_omni_close();
    ui_endian_toggle();
    frame();

    // Scenario 15: bookmarks, a single byte and then a four-byte run; the panel
    // washes every byte of both, grid and minimap. A marked run is drawn under the
    // selection that set it, so shot-mark-range shows it only after the caret moves.
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

    // Scenario 15b: naming the run the jump above landed on. The box comes up on a
    // prompt rather than a prefix, so the typing is the name; afterwards the status
    // bar carries it, and the '@' list reads as the name with the offset behind it.
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
    find("magic"); // the name is what the row is found by now
    ui_omni_close();
    frame();

    // A command that puts the box back up on another prefix, rather than doing
    // something and going away: the palette's own route into the inspector.
    ui_omni_toggle(OMNI_COMMAND);
    frame();
    mu_input_text(&ctx, "inspect");
    frame(); frame();
    tap(MU_KEY_RETURN);
    frame(); frame();
    shot("omni-command-reopen.bmp");
    ui_omni_close();
    frame();

    // Clearing them by name out of the command list; the empty list then says what
    // sets one.
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

    // Scenario 16: skipping a run. The document is random bytes, so the scenario
    // lays eight zeroes over the head of row 0 first. Ctrl+Left / Ctrl+Right are
    // main-loop chords, so the driver calls the entry point they reach.
    chord(MU_KEY_CTRL, HEX_KEY_HOME);
    mu_input_text(&ctx, "0000000000000000");
    frame();
    chord(MU_KEY_CTRL, HEX_KEY_HOME);
    frame();
    shot("skip-run.bmp");  // caret at 0x00, on the head of the run
    ui_skip_element(false);
    frame();
    shot("skip-fwd.bmp");  // crossed the zeroes: caret on 0x08
    ui_skip_element(true);
    frame();
    shot("skip-back.bmp"); // back onto 0x07, the last byte of the run
    ui_skip_element(true);
    frame();
    shot("skip-back2.bmp"); // and across the whole run to 0x00

    // The Shift half of the same chords covers the run rather than jumping it, so
    // the run itself ends up selected and the byte that ended it does not.
    ui_skip_element(false, true);
    frame();
    shot("skip-grow.bmp");  // 0x00-0x07 selected, the eight zeroes
    ui_skip_element(false, true);
    frame();
    shot("skip-grow2.bmp"); // and on over the run after them

    // Backward from just past the run: nothing differs below it, so the walk ends
    // on the document's own start rather than one byte above it.
    chord(MU_KEY_CTRL, HEX_KEY_HOME);
    foreach (i; 0 .. 16) tap(HEX_KEY_RIGHT); // a nibble each, so eight bytes
    frame();
    ui_skip_element(true, true);
    frame();
    shot("skip-grow-back.bmp"); // 0x00-0x08: the zeroes, plus the byte started on

    // With a selection the element is the whole of it: three identical four-byte
    // records at 0x10, the first selected. The skip crosses them a record at a time
    // and keeps the selection, landing on 0x1c - not 0x14, which reads the same.
    chord(MU_KEY_CTRL, HEX_KEY_HOME);
    tap(HEX_KEY_DOWN);
    mu_input_text(&ctx, "cafe0001cafe0001cafe0001");
    frame();
    chord(MU_KEY_CTRL, HEX_KEY_HOME); // back onto the head of the run
    tap(HEX_KEY_DOWN);
    mu_input_keydown(&ctx, MU_KEY_SHIFT);
    tap(HEX_KEY_RIGHT); tap(HEX_KEY_RIGHT); tap(HEX_KEY_RIGHT);
    mu_input_keyup(&ctx, MU_KEY_SHIFT);
    frame();
    shot("skip-sel.bmp");      // cafe0001 selected at 0x10
    ui_skip_element(false);
    frame();
    shot("skip-sel-fwd.bmp");  // past the whole run, selection carried along
    ui_skip_element(true);
    frame();
    shot("skip-sel-back.bmp"); // and back onto the last record of it

    // A click outside puts the box away without taking a row.
    ui_omni_toggle();
    frame();
    click(400, 400);
    frame();
    shot("omni-dismissed.bmp");

    // Scenario 17: comparing two documents. Its own fixtures rather than the
    // documents above, which by now carry a scenario's worth of edits: diff-b.bin
    // is diff-a.bin with a handful of bytes overwritten and a tail added.
    //
    // The two panes should not look alike. diff-a.bin was already open and goes on
    // drawing as an ordinary view; diff-b.bin is the one opened against it and
    // carries the comparison - dimmed where the two agree, red where they do not.
    ui_open(fix.diffA);
    frame();
    ui_compare_with(fix.diffB);
    frame();
    shot("diff.bmp");

    // Scrolling one side carries the other, so both should still show the same
    // offsets against each other afterwards.
    mu_input_mousemove(&ctx, 300, 300); // over the pane diff-b.bin opened in
    frame();
    mu_input_scroll(&ctx, 0, 200);
    frame(); frame();
    shot("diff-scrolled.bmp");

    // On past the end of the shorter file: diff-a.bin runs out first, so its pane
    // stops at its own last screenful rather than hauling the other back up with
    // it, while diff-b.bin carries on into bytes it alone has, which read as added
    // rather than as a wall of changes.
    //
    // The follower is a frame behind while a scroll is in flight (a panel drains
    // the wheel at the top of a frame, the sync runs at the bottom), so a scripted
    // burst leaves the two visibly apart: let go and let them settle, which is
    // also the check that they do.
    foreach (i; 0 .. 10)
    {
        mu_input_scroll(&ctx, 0, 600);
        frame();
    }
    frame(); frame(); frame();
    shot("diff-tail.bmp");

    // Closing one side ends the comparison rather than leaving the other colouring
    // against a document that is gone: diff-a.bin's pane goes back to the width it
    // had, with the counterpart gone from the status bar and nothing left to scroll
    // it. diff-b.bin has no edits, so nothing prompts.
    ui_close_current_tab(); // the focused pane is the one the comparison opened
    frame(); frame();
    shot("diff-closed.bmp");

    // Scenario 18: the menu items that raise the omnibar rather than act. Walked
    // with the mouse, which is the whole point: the box has to survive the click
    // that opened it, and every one of these used to blink and be gone the next
    // frame. One shot for the sheet, the rest checked by finding a row of the mode
    // they should have put up.
    static immutable string[3][6] raises = [
        [ "Help",      "Keyboard Shortcuts...", "Omnibar: this sheet" ],
        [ "Search",    "Find...",               "bytes as written" ],
        [ "Search",    "Go to Offset...",       "waiting for an offset" ],
        [ "View",      "Inspect Bytes...",      "u8" ],
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
        find(step[2].ptr); // throws when the box closed on itself again
        if (step[1] == "Keyboard Shortcuts...")
            shot("menu-keys.bmp");
        ui_omni_close();
        frame();
    }
    ui_mark_clear(); // Name Bookmark marked the caret to have something to name
    frame();

    // Scenario 19: the easter egg. Last of the set, since it leaves two dialogs
    // stacked and both own a control the label search would find first. The version
    // line in the About dialog looks like a label and is not one.
    mu_Vec2 helpMenu = find("Help");
    click(helpMenu.x + 3, helpMenu.y + 3);
    frame(); frame();
    mu_Vec2 aboutItem = find("About");
    click(aboutItem.x + 3, aboutItem.y + 3);
    frame();
    mu_Vec2 versionLine = find("vddhx ");
    click(versionLine.x + 3, versionLine.y + 3);
    // The ship tumbles a fixed step per frame under this build (see elite.d), so
    // running a second's worth of them poses it at three quarters rather than
    // nose-on, and does it identically on every run.
    foreach (i; 0 .. 90) frame();
    shot("elite.bmp");

    return 0;
}
