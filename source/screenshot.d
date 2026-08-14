/// Debug-only frame capture. Compiled in only under `version (Screenshot)`
/// (see the "screenshot" buildType in dub.sdl): `dub build -b screenshot`.
///
/// Two entry points share one capture primitive:
///   - screenshot_save: dump the current renderer backbuffer to a BMP. main
///     calls this live when Ctrl+Shift+F12 is pressed.
///   - screenshot_run: a headless, scripted driver (offscreen SDL) that renders
///     canned UI states and captures each, so visual regressions can be checked
///     without a display. Convert the BMPs with `ffmpeg -y -i x.bmp x.png`.
///     Adding `--readme` runs one posed scenario instead of the regression set,
///     which is where assets/screenshot.png comes from.
/// Authors: dd
module screenshot;

version (Screenshot):

import core.stdc.string : strncmp, strlen;
import bindbc.sdl;
import ddui;
import hexview : HEX_KEY_HOME, HEX_KEY_END, HEX_KEY_DEL, HEX_KEY_UNDO, HEX_KEY_REDO,
    HEX_KEY_LEFT, HEX_KEY_RIGHT, HEX_KEY_UP, HEX_KEY_DOWN;
import omnibar : OMNI_COMMAND, OMNI_ADDRESS, OMNI_FIND, OMNI_INSPECT,
    OMNI_BOOKMARK, OMNI_HELP, OMNI_KEY_DOWN;
import render;
import ui;

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

/// Headless capture of a few UI states. Run with SDL_VIDEODRIVER=offscreen:
/// `SDL_VIDEODRIVER=offscreen dub run -b screenshot -- --screenshot`.
int screenshot_run(string[] args)
{
    // `--readme` asks for the one showcase frame the project page uses instead of
    // the regression scenarios: a wider window, real files, and a state posed to
    // be looked at rather than diffed against a previous run.
    import std.algorithm.searching : canFind;
    const bool readme = args.canFind("--readme");
    const int W = readme ? 1280 : 800;
    const int H = readme ?  800 : 600;

    if (SDL_Init(SDL_INIT_VIDEO) == false)
        return 1;
    scope(exit) SDL_Quit();

    SDL_Window* window = SDL_CreateWindow("vddhx-shot", W, H, 0);
    if (window is null)
        return 1;
    scope(exit) SDL_DestroyWindow(window);

    SDL_Renderer* renderer = SDL_CreateRenderer(window, null);
    if (renderer is null)
        return 1;
    scope(exit) SDL_DestroyRenderer(renderer);

    if (render_init(renderer) == false)
        return 1;
    scope(exit) render_quit();

    static mu_Context ctx; // ~4 MB; keep it off the stack
    mu_init(&ctx);
    ctx.text_width  = &render_text_width;
    ctx.text_height = &render_text_height;
    ctx.style.font  = render_font_ui();
    ui_style(&ctx);

    // Wire up the editor so scripted editing scenarios have a document to write
    // to; the live app does this in main before the loop.
    ui_init(window);

    // Build one UI frame from the current input state.
    void frame() { mu_begin(&ctx); ui_frame(&ctx, W, H); mu_end(&ctx); }

    // Locate a drawn label so scripted clicks do not hardcode layout maths.
    // Iterate in z-index order with mu_get_next_command and pull the string out
    // of the per-frame arena; the command only carries an offset into it.
    mu_Vec2 find(const(char)* label)
    {
        mu_Command* cmd;
        while (mu_get_next_command(&ctx, &cmd))
            if (cmd.type == MU_COMMAND_TEXT &&
                strncmp(mu_command_text(&ctx, cmd), label, cast(int) strlen(label)) == 0)
                return cmd.text.pos;
        return mu_Vec2(-1, -1);
    }

    // Two move frames: hover_root lags input by a frame, so the control under
    // the cursor only registers hover on the second.
    void click(int x, int y)
    {
        mu_input_mousemove(&ctx, x, y); frame(); frame();
        mu_input_mousedown(&ctx, x, y, MU_MOUSE_LEFT); frame();
        mu_input_mouseup(&ctx, x, y, MU_MOUSE_LEFT); frame();
    }

    // Press one mapped key for a frame (down, render, up).
    void tap(int key) { mu_input_keydown(&ctx, key); frame(); mu_input_keyup(&ctx, key); }

    // Hold `mod` down across one press of `key`, for chords like Ctrl+Z.
    void chord(int mod, int key)
    {
        mu_input_keydown(&ctx, mod);
        mu_input_keydown(&ctx, key); frame(); mu_input_keyup(&ctx, key);
        mu_input_keyup(&ctx, mod);
    }

    // Render the current command list and write it out.
    bool shot(const(char)* path)
    {
        SDL_SetRenderDrawColor(renderer, 30, 30, 46, 255);
        SDL_RenderClear(renderer);
        render_commands(renderer, &ctx);
        return screenshot_save(renderer, path);
    }

    // The showcase frame, off the repo's own files (run it from the repo root):
    // a binary on the left for the byte-class colours, with a bookmark and a
    // selection on it, text on the right in a pane of its own, and the omnibar
    // open over the pair of them mid-query.
    //
    // Both extra tabs go in the left pane: the box floats over the middle of the
    // window, which is where the right pane's strip is, and a tab nobody can see
    // shows nothing off. The keyboard is handed back to the left pane at the end
    // (without clicking into it, which would drop the selection) so the status
    // bar reads off the pane the shot is about.
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
        shot("shot-readme.bmp");
        return 0;
    }

    // Scenario 0 (debug): open a multi-row file so offsets past 0x0F appear.
    ui_open("/tmp/mid.bin");
    frame();
    shot("shot-rows.bmp");

    // Scenario 1: fresh startup.
    frame();
    shot("shot-startup.bmp");

    // Scenario 2: File menu open (the state the z-order bug broke).
    mu_Vec2 file = find("File");
    click(file.x + 3, file.y + 3);
    frame(); frame(); // let the autosizing popup settle
    shot("shot-menu.bmp");

    // Scenario 3: modal editing. Click into the grid to focus it, then type hex
    // digits and capture the bytes the panel now shows. The click has to clear
    // the File dropdown scenario 2 left open, which covers the left ~200px, so
    // it lands to the right of it (and dismisses it on the way).
    click(400, 160);
    mu_input_text(&ctx, "deadbeefcafe");
    frame();
    shot("shot-edit.bmp");

    // Scenario 4: overwrite and delete. Home to the row start, overwrite the first
    // byte in place, then Delete the byte now under the caret.
    tap(HEX_KEY_HOME);
    mu_input_text(&ctx, "42");
    frame();
    tap(HEX_KEY_DEL);
    shot("shot-edit-ovr.bmp");

    // Scenario 5: history. Ctrl+Z rolls the edits back, Ctrl+Y rolls them forward.
    chord(MU_KEY_CTRL, HEX_KEY_UNDO);
    shot("shot-undo.bmp");
    chord(MU_KEY_CTRL, HEX_KEY_REDO);
    shot("shot-redo.bmp");

    // Scenario 6: nibble caret. End to the append slot, then type a lone hex digit
    // so a half-built byte sits under the caret; the caret should box only its low
    // nibble (the digit the next keypress lands in). A Left tap then walks the
    // caret back one nibble onto the same byte's high digit.
    tap(HEX_KEY_HOME);
    mu_input_text(&ctx, "a");
    frame();
    shot("shot-nibble-low.bmp");
    tap(HEX_KEY_LEFT);
    shot("shot-nibble-high.bmp");

    // Scenario 7: clipboard round-trip. Select the first four bytes (Home, then
    // Right three times with Shift held so the anchor stays put), copy them, jump
    // to EOF with Ctrl+End and paste: the same four bytes should reappear there.
    tap(HEX_KEY_HOME);
    mu_input_keydown(&ctx, MU_KEY_SHIFT);
    tap(HEX_KEY_RIGHT); tap(HEX_KEY_RIGHT); tap(HEX_KEY_RIGHT);
    mu_input_keyup(&ctx, MU_KEY_SHIFT);
    frame();
    shot("shot-clip-sel.bmp");
    ui_copy();
    chord(MU_KEY_CTRL, HEX_KEY_END);
    ui_paste();
    frame();
    shot("shot-clip-paste.bmp");

    // Same four bytes pasted onto a bare caret mid-document: OVR is on, so they
    // overwrite the head of row 0x10 in place and the document keeps its size.
    chord(MU_KEY_CTRL, HEX_KEY_HOME);
    tap(HEX_KEY_DOWN);
    ui_paste();
    frame();
    shot("shot-clip-ovr.bmp");

    // And onto a two-byte selection (the pair at 0x24, Shift+Right once): the
    // selection goes and the four bytes take its place, growing the document by
    // the two bytes of difference.
    tap(HEX_KEY_DOWN);
    mu_input_keydown(&ctx, MU_KEY_SHIFT);
    tap(HEX_KEY_RIGHT);
    mu_input_keyup(&ctx, MU_KEY_SHIFT);
    ui_paste();
    frame();
    shot("shot-clip-replace.bmp");

    // Scenario 8: cut. Take back the four bytes just pasted at 0x24 and drop them
    // onto the clipboard and out of the document; the row closes over the gap and
    // the caret lands where they were. The previous paste left the caret at 0x28,
    // and an unshifted Left walks a nibble at a time while editing, so eight taps
    // step the four bytes back to 0x24; the shifted Rights that follow move whole
    // bytes, selecting the run. Pasting after the cut lands the bytes back at that
    // same offset, though on a bare caret in OVR mode they overwrite the four that
    // closed the gap rather than restoring what was there before the cut.
    foreach (i; 0 .. 8) tap(HEX_KEY_LEFT);
    mu_input_keydown(&ctx, MU_KEY_SHIFT);
    tap(HEX_KEY_RIGHT); tap(HEX_KEY_RIGHT); tap(HEX_KEY_RIGHT);
    mu_input_keyup(&ctx, MU_KEY_SHIFT);
    ui_cut();
    frame();
    shot("shot-clip-cut.bmp");
    ui_paste();
    frame();
    shot("shot-clip-cut-undone.bmp");

    // Scenario 9: Help > About. Walk the menu the way a user would, so the
    // dialog is captured with the placement the menu route gives it.
    mu_Vec2 help = find("Help");
    click(help.x + 3, help.y + 3);
    frame(); frame();
    mu_Vec2 about = find("About");
    click(about.x + 3, about.y + 3);
    frame();
    shot("shot-about.bmp");

    // And again with the cursor on the homepage link, which should light up and
    // underline it.
    mu_Vec2 link = find("https://");
    mu_input_mousemove(&ctx, link.x + 3, link.y + 3); frame(); frame();
    shot("shot-about-link.bmp");

    // Scenario 10: tabs. Close the dialog, then open a second file and add a
    // scratch buffer: the strip should show three tabs, the first carrying the
    // unsaved dot the scenarios above earned it, the scratch in front.
    mu_Vec2 close = find("Close");
    click(close.x + 3, close.y + 3);
    ui_open("/tmp/other.bin");
    ui_new_tab();
    frame();
    shot("shot-tabs.bmp");

    // Clicking a tab brings its document back, bytes, caret and all.
    mu_Vec2 tab = find("mid.bin");
    click(tab.x + 3, tab.y + 3);
    frame();
    shot("shot-tabs-select.bmp");

    // Dragging a tab sideways reorders the strip. The press picks mid.bin up (and
    // selects it, as a plain click would); each move past a neighbour's middle
    // reports one step, so the two moves below walk it from the front of the
    // strip to the back, and the release just lets go of what is already there.
    //
    // The tab is lifted out and drawn from the pointer while this is going on, so
    // the middle shot catches it overlapping the tab it has just swapped with.
    mu_Vec2 grab = find("mid.bin");
    int grabY = grab.y + 3;
    mu_input_mousemove(&ctx, grab.x + 3, grabY); frame(); frame();
    mu_input_mousedown(&ctx, grab.x + 3, grabY, MU_MOUSE_LEFT); frame();
    mu_input_mousemove(&ctx, grab.x + 43, grabY); frame(); frame();
    shot("shot-tabs-drag.bmp");
    // Yanked well past the last tab, into the bare strip a short row leaves in a
    // wide window: the tab stops on the last slot instead of following the
    // pointer out there, so it never comes away from the row it is landing in.
    mu_input_mousemove(&ctx, grab.x + 500, grabY); frame(); frame();
    shot("shot-tabs-drag2.bmp");
    mu_input_mouseup(&ctx, grab.x + 500, grabY, MU_MOUSE_LEFT); frame(); frame();
    shot("shot-tabs-dropped.bmp");

    // Middle-clicking one closes it: the shortest route through the close path
    // without guessing where inside the tab its close box sits. other.bin has no
    // unsaved edits, so it goes without a prompt (which would need a display).
    mu_Vec2 other = find("other.bin");
    mu_input_mousemove(&ctx, other.x + 3, other.y + 3); frame(); frame();
    mu_input_mousedown(&ctx, other.x + 3, other.y + 3, MU_MOUSE_MIDDLE); frame();
    mu_input_mouseup(&ctx, other.x + 3, other.y + 3, MU_MOUSE_MIDDLE); frame();
    shot("shot-tabs-closed.bmp");

    // Scenario 10d: panes. Splitting puts a second pane beside the first, showing
    // the same document at the same offset through a view of its own. The two
    // then move apart: scrolling the new one leaves the old one where it was, and
    // only the focused pane lights its tab accent.
    ui_split();
    frame(); frame();
    shot("shot-pane-split.bmp");

    // Walk the right-hand pane a long way down. The left one is looking at the
    // same bytes through its own caret and scroll position, so it must not move.
    foreach (i; 0 .. 24) tap(HEX_KEY_DOWN);
    frame();
    shot("shot-pane-apart.bmp");

    // An edit in one pane is an edit to the document, so it shows in both. Type
    // over the byte under the right-hand caret and the left pane redraws with it.
    mu_input_text(&ctx, "ff");
    frame(); frame();
    shot("shot-pane-shared-edit.bmp");

    // A third pane, then the splitters dragged: the boundary between the first
    // two moves right, taking width from the second.
    ui_split();
    frame(); frame();
    shot("shot-pane-three.bmp");

    // Dragging the first splitter right takes width from the pane on its right
    // and gives it to the one on its left; the third pane is not on that boundary
    // and does not move. Three panes at weights 500/250/250 over 788px of room
    // put that boundary at x=394, so the bar spans 394..400.
    mu_input_mousemove(&ctx, 397, 300); frame(); frame();
    mu_input_mousedown(&ctx, 397, 300, MU_MOUSE_LEFT); frame();
    mu_input_mousemove(&ctx, 500, 300); frame(); frame();
    shot("shot-pane-resize.bmp");
    mu_input_mouseup(&ctx, 500, 300, MU_MOUSE_LEFT); frame();

    // Clicking into a pane is what moves the keyboard to it: the accent on the
    // left pane's tab lights and the right one's goes dim.
    click(60, 300);
    frame();
    shot("shot-pane-focus.bmp");

    // A file dragged over the window picks out the pane under the pointer, and
    // dropping it opens it there rather than in whichever pane had the keyboard.
    // The focus is on the left pane after the click above, so a drop aimed at the
    // rightmost one is only in the right place if the coordinates are honoured.
    ui_drop_hover(700, 300);
    frame();
    shot("shot-drop-hover.bmp");

    ui_drop_file("/tmp/other.bin", 700, 300);
    frame(); frame();
    shot("shot-drop-landed.bmp");

    // A tab dragged out of its own strip and into another pane. other.bin sits in
    // the rightmost pane after the drop above; press its tab, pull the pointer
    // left across the window, and it comes out of the strip - drawn over the
    // panes it crosses, with the pane it would land in picked out.
    //
    // Aimed at the middle of the leftmost pane, since the outer third of a pane
    // each way is the zone that splits it rather than joins it (see split_zone):
    // this is the joining gesture, so it has to land in the middle band.
    mu_Vec2 leaving = find("othe");
    int leavingY = leaving.y + 3;
    mu_input_mousemove(&ctx, leaving.x + 3, leavingY); frame(); frame();
    mu_input_mousedown(&ctx, leaving.x + 3, leavingY, MU_MOUSE_LEFT); frame();
    mu_input_mousemove(&ctx, 250, 300); frame(); frame();
    shot("shot-tab-detached.bmp");

    // Letting go over the leftmost pane hands the tab to it: the view goes across
    // whole, caret and all, and the destination takes the keyboard.
    mu_input_mouseup(&ctx, 250, 300, MU_MOUSE_LEFT); frame(); frame();
    shot("shot-tab-handed-over.bmp");

    // Dragging out a pane's *last* tab leaves that pane with nothing to show, so
    // the row shuts over it and its width goes to a neighbour. The rightmost pane
    // is down to one tab after the handover above; its strip sits around x=630.
    mu_input_mousemove(&ctx, 630, leavingY); frame(); frame();
    mu_input_mousedown(&ctx, 630, leavingY, MU_MOUSE_LEFT); frame();
    mu_input_mousemove(&ctx, 250, 300); frame(); frame();
    mu_input_mouseup(&ctx, 250, 300, MU_MOUSE_LEFT); frame(); frame();
    shot("shot-pane-emptied.bmp");

    // The same drag aimed at the top third of a pane instead: that is a split, so
    // the preview covers the half the newcomer would take rather than the whole
    // pane, and letting go there puts it in a pane of its own above the one it
    // was dropped on. The left pane holds several tabs after the handovers above,
    // so this pulls one of them up out of its own pane.
    mu_Vec2 upper = find("mid.");
    int upperY = upper.y + 3;
    mu_input_mousemove(&ctx, upper.x + 3, upperY); frame(); frame();
    mu_input_mousedown(&ctx, upper.x + 3, upperY, MU_MOUSE_LEFT); frame();
    mu_input_mousemove(&ctx, 250, 120); frame(); frame();
    shot("shot-tab-split-hover.bmp");

    mu_input_mouseup(&ctx, 250, 120, MU_MOUSE_LEFT); frame(); frame();
    shot("shot-tab-split-done.bmp");

    // Put it back the way the scenarios below expect: the pane made by the split
    // goes, and its height returns to the pane under it.
    ui_close_pane();
    frame(); frame();

    // Dragging a tab down over its own pane's grid must not drag the selection
    // with it. The panel is handed focus when its tab is picked (so typing lands
    // in the bytes after a tab switch), which put it in reach of a drag it never
    // started. Give this pane the keyboard so the status bar is reporting its
    // caret, then pull the front tab down across the grid: the offset has to read
    // the same in both shots. It used to sweep out a 208-byte selection.
    //
    // The pull is straight down, which also covers the drag threshold: measured
    // on x alone, this gesture lifted nothing at all.
    click(100, 150);
    frame();
    shot("shot-tab-drag-caret.bmp");

    mu_input_mousemove(&ctx, 330, 49); frame(); frame();
    mu_input_mousedown(&ctx, 330, 49, MU_MOUSE_LEFT); frame();
    mu_input_mousemove(&ctx, 330, 300); frame(); frame();
    shot("shot-tab-drag-held.bmp");
    // Back to the middle of the pane before letting go: dropped against an edge
    // this would split the tab out into a pane of its own, and what is being
    // checked here is a gesture that changes nothing.
    mu_input_mousemove(&ctx, 250, 300); frame(); frame();
    mu_input_mouseup(&ctx, 250, 300, MU_MOUSE_LEFT); frame(); frame();

    // Scenario 10e: splitting the other way. The new pane goes under the focused
    // one inside its own column, so the column keeps its width and the panes
    // beside it do not move at all - which is the whole difference from the
    // split above.
    ui_split_down();
    frame(); frame();
    shot("shot-pane-split-down.bmp");

    // The two stacked panes are separate views of one document, so walking the
    // lower one leaves the upper where it was, the same as side by side. Its
    // strip is dim until it is clicked into: only the focused pane lights up,
    // wherever in the grid it sits.
    foreach (i; 0 .. 12) tap(HEX_KEY_DOWN);
    frame();
    shot("shot-pane-stacked-apart.bmp");

    // The bar between them is a splitter like any other, dragged up and down
    // instead of left and right. The column runs from under the toolbar to the
    // status bar, so two even panes put the boundary near the middle of the
    // window; the click aims at the bar and the drag lifts it, taking height from
    // the pane above and giving it to the one below.
    enum int STACK_X = 100, STACK_Y = 308;
    mu_input_mousemove(&ctx, STACK_X, STACK_Y); frame(); frame();
    mu_input_mousedown(&ctx, STACK_X, STACK_Y, MU_MOUSE_LEFT); frame();
    mu_input_mousemove(&ctx, STACK_X, STACK_Y - 120); frame(); frame();
    shot("shot-pane-stack-resize.bmp");
    mu_input_mouseup(&ctx, STACK_X, STACK_Y - 120, MU_MOUSE_LEFT); frame(); frame();

    // Put the stack away again: the pane below closes, the one above takes its
    // height back, and the window is left as the scenarios after this expect it.
    // Its view shares a document with the pane it came from, so nothing is being
    // lost and no prompt is raised.
    ui_close_pane();
    frame(); frame();
    shot("shot-pane-stack-closed.bmp");

    // The sideways half of the drag-to-split gesture: a tab let go against a
    // pane's left edge takes a column of its own beside it, so the preview is the
    // left half of the pane rather than its top half, and the panes end up side
    // by side instead of stacked. The left pane still has several tabs, so one of
    // them can be pulled out of it into the space it is being dropped over.
    mu_Vec2 sideways = find("other");
    int sidewaysY = sideways.y + 3;
    mu_input_mousemove(&ctx, sideways.x + 3, sidewaysY); frame(); frame();
    mu_input_mousedown(&ctx, sideways.x + 3, sidewaysY, MU_MOUSE_LEFT); frame();
    mu_input_mousemove(&ctx, 480, 300); frame(); frame();
    shot("shot-tab-split-side-hover.bmp");

    mu_input_mouseup(&ctx, 480, 300, MU_MOUSE_LEFT); frame(); frame();
    shot("shot-tab-split-side-done.bmp");

    // And away again, leaving the two panes the scenarios below expect.
    ui_close_pane();
    frame(); frame();

    // Scenario 11: the omnibar. Ctrl+E is a main-loop chord, so the scripted
    // driver calls the entry point that key does, then types into the box the
    // way SDL's text input would. The list is matched against the query as it
    // stood when the frame began, so a frame typing and a frame showing the
    // result are two different frames.
    ui_omni_toggle();
    frame();
    shot("shot-omni.bmp");

    mu_input_text(&ctx, "mid");
    frame(); frame();
    shot("shot-omni-filter.bmp");

    // Down walks the list; with one match left it wraps back onto it.
    tap(OMNI_KEY_DOWN);
    shot("shot-omni-down.bmp");

    // The two prefixed modes. Toggling to a mode the box is not in switches it
    // rather than closing, so these two calls swap the list under the same box.
    ui_omni_toggle(OMNI_COMMAND);
    frame(); frame();
    shot("shot-omni-command.bmp");

    // The unshown aliases: "diff" is not a word on any row, and it should still
    // bring "Compare With..." up - reading as its own label, with no sign of the
    // term that found it.
    mu_input_text(&ctx, "diff");
    frame(); frame();
    shot("shot-omni-alias.bmp");

    ui_omni_toggle(OMNI_HELP);
    frame(); frame();
    shot("shot-omni-help.bmp");

    // Enter takes the highlighted row: the shortcut sheet has nothing to run, so
    // this is the route that just puts the box away and hands the bytes back.
    tap(MU_KEY_RETURN);
    frame();
    shot("shot-omni-closed.bmp");

    // And the switcher doing its job: name a tab, take it, and the panel behind
    // is showing that document with the strip following.
    ui_omni_toggle();
    frame();
    mu_input_text(&ctx, "unt");
    frame(); frame();
    tap(MU_KEY_RETURN);
    frame();
    shot("shot-omni-switched.bmp");

    // Scenario 12: ':' reads an offset instead of filtering a list, so its one
    // row is a live readout of where Enter would land. Back on mid.bin for it,
    // since a jump wants a document with somewhere to jump to.
    ui_omni_toggle();
    frame();
    mu_input_text(&ctx, "mid");
    frame(); frame();
    tap(MU_KEY_RETURN);
    frame();

    ui_omni_toggle(OMNI_ADDRESS);
    frame(); frame();
    shot("shot-omni-goto-empty.bmp"); // nothing typed yet: the syntax it wants

    mu_input_text(&ctx, "0x40");
    frame(); frame();
    shot("shot-omni-goto.bmp");

    tap(MU_KEY_RETURN);
    frame();
    shot("shot-omni-goto-done.bmp"); // caret on 0x40, the view scrolled onto it

    // Relative and percentage forms, from where that jump left the caret.
    ui_omni_toggle(OMNI_ADDRESS);
    frame();
    mu_input_text(&ctx, "+16");
    frame(); frame();
    shot("shot-omni-goto-relative.bmp");
    ui_omni_close();
    frame();

    ui_omni_toggle(OMNI_ADDRESS);
    frame();
    mu_input_text(&ctx, "%50");
    frame(); frame();
    shot("shot-omni-goto-percent.bmp");
    ui_omni_close();
    frame();

    // Scenario 13: find. The document is random bytes, so the scenario writes
    // its own needle first: caret to the top, four bytes typed over what is
    // there, then the caret sent to the far end so the search has to walk the
    // whole document (and wrap) to come back to them.
    chord(MU_KEY_CTRL, HEX_KEY_HOME);
    mu_input_text(&ctx, "cafebabe");
    frame();
    chord(MU_KEY_CTRL, HEX_KEY_END);
    frame();

    ui_omni_toggle(OMNI_FIND);
    frame();
    mu_input_text(&ctx, "0xcafebabe");
    frame(); frame();
    shot("shot-omni-find.bmp"); // the bytes the pattern comes to, before running it
    tap(MU_KEY_RETURN);
    frame();
    shot("shot-omni-find-hit.bmp"); // match selected, scrolled onto, reported below

    // A pattern that is nowhere in the document says so rather than going quiet.
    ui_omni_toggle(OMNI_FIND);
    frame();
    mu_input_text(&ctx, "no such text here");
    frame(); frame();
    tap(MU_KEY_RETURN);
    frame();
    shot("shot-omni-find-miss.bmp");

    // Scenario 14: the inspector. Every reading of the bytes at the caret, both
    // byte orders, filterable by typing part of a type name.
    ui_omni_toggle(OMNI_INSPECT);
    frame(); frame();
    shot("shot-omni-inspect.bmp");
    mu_input_text(&ctx, "32");
    frame(); frame();
    shot("shot-omni-inspect-filter.bmp");
    ui_omni_close();
    frame();

    // Scenario 15: bookmarks. Mark the byte under the caret, step down two rows,
    // select four bytes and mark the run, then list them; the panel washes every
    // byte of both, grid and minimap. The marked run is drawn under the selection
    // that set it, so shot-mark-range shows it only once the caret has moved on.
    ui_mark_toggle();
    frame();
    shot("shot-mark-set.bmp");
    tap(HEX_KEY_DOWN); tap(HEX_KEY_DOWN);
    chord(MU_KEY_SHIFT, HEX_KEY_RIGHT);
    chord(MU_KEY_SHIFT, HEX_KEY_RIGHT);
    chord(MU_KEY_SHIFT, HEX_KEY_RIGHT);
    ui_mark_toggle();
    frame();
    shot("shot-mark-range.bmp");
    ui_omni_toggle(OMNI_BOOKMARK);
    frame(); frame();
    shot("shot-omni-marks.bmp");
    tap(MU_KEY_RETURN);
    frame();
    shot("shot-omni-marks-jump.bmp");

    // A command that puts the box back up on another prefix, rather than doing
    // something and going away: the palette's own route into the inspector.
    ui_omni_toggle(OMNI_COMMAND);
    frame();
    mu_input_text(&ctx, "inspect");
    frame(); frame();
    tap(MU_KEY_RETURN);
    frame(); frame();
    shot("shot-omni-command-reopen.bmp");
    ui_omni_close();
    frame();

    // Clearing them the way a user would reach it: by name, out of the command
    // list. An empty list then says what sets one.
    ui_omni_toggle(OMNI_COMMAND);
    frame();
    mu_input_text(&ctx, "clear book");
    frame(); frame();
    tap(MU_KEY_RETURN);
    frame();
    ui_omni_toggle(OMNI_BOOKMARK);
    frame(); frame();
    shot("shot-omni-marks-empty.bmp");
    ui_omni_close();
    frame();

    // Scenario 16: skipping a run. The document is random bytes, so the scenario
    // lays a run of its own first: eight zero bytes over the head of row 0, typed
    // in OVR mode. Ctrl+Left / Ctrl+Right are main-loop chords, so the driver
    // calls the entry point they reach.
    chord(MU_KEY_CTRL, HEX_KEY_HOME);
    mu_input_text(&ctx, "0000000000000000");
    frame();
    chord(MU_KEY_CTRL, HEX_KEY_HOME);
    frame();
    shot("shot-skip-run.bmp");  // caret at 0x00, on the head of the run
    ui_skip_element(false);
    frame();
    shot("shot-skip-fwd.bmp");  // crossed the zeroes: caret on 0x08
    ui_skip_element(true);
    frame();
    shot("shot-skip-back.bmp"); // back onto 0x07, the last byte of the run
    ui_skip_element(true);
    frame();
    shot("shot-skip-back2.bmp"); // and across the whole run to 0x00

    // With a selection the element is the whole of it: three identical four-byte
    // records typed over the head of row 0x10, then the first of them selected.
    // The skip crosses the run a record at a time and keeps the selection, so it
    // lands on the random bytes at 0x1c - not on 0x14, which reads the same.
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
    shot("shot-skip-sel.bmp");      // cafe0001 selected at 0x10
    ui_skip_element(false);
    frame();
    shot("shot-skip-sel-fwd.bmp");  // past the whole run, selection carried along
    ui_skip_element(true);
    frame();
    shot("shot-skip-sel-back.bmp"); // and back onto the last record of it

    // A click anywhere outside puts it away without taking a row, the way every
    // quick-open box behaves: here, into the grid it was floating over.
    ui_omni_toggle();
    frame();
    click(400, 400);
    frame();
    shot("shot-omni-dismissed.bmp");

    // Scenario 17: comparing two documents. A pair of fixtures rather than the
    // documents above, which by now carry a scenario's worth of edits: the point
    // to see is a mostly-matching file with a few bytes changed, which is what a
    // comparison is for and what the tint has to make obvious. diff-b.bin is
    // diff-a.bin with a handful of bytes overwritten and a tail added.
    //
    // The two panes should not look alike. diff-a.bin was already open, so it goes
    // on drawing as an ordinary view at full brightness; diff-b.bin is the one
    // opened against it and carries the whole comparison - dimmed where the two
    // agree, red where they do not. Both land on the same offset.
    ui_open("/tmp/diff-a.bin");
    frame();
    ui_compare_with("/tmp/diff-b.bin");
    frame();
    shot("shot-diff.bmp");

    // Scrolling one side carries the other: the sync runs off what each pane was
    // left at, so a wheel over either pane moves both. Both should still show the
    // same offsets against each other afterwards.
    mu_input_mousemove(&ctx, 300, 300); // over the pane diff-b.bin opened in
    frame();
    mu_input_scroll(&ctx, 0, 200);
    frame(); frame();
    shot("shot-diff-scrolled.bmp");

    // On past the end of the shorter file. diff-b.bin is the longer, so it leads
    // and diff-a.bin runs out first: the left pane stops at its own last
    // screenful and stays there (rather than hauling the right one back up with
    // it every frame), while the right carries on into bytes it alone has, which
    // read as added rather than as a wall of changes.
    // The follower is a frame behind while a scroll is in flight: a panel drains
    // the wheel at the top of a frame and the sync runs at the bottom of it, so
    // the other side shows the new position on the next one. A wheel notch at a
    // time that is a frame, but a scripted burst of a screenful per frame leaves
    // the two visibly apart, so let go and let them settle - which is also the
    // check that they do.
    foreach (i; 0 .. 10)
    {
        mu_input_scroll(&ctx, 0, 600);
        frame();
    }
    frame(); frame(); frame();
    shot("shot-diff-tail.bmp");

    // Closing one side ends the comparison rather than leaving the other half
    // colouring against a document that is gone. diff-a.bin was never tinted, so
    // what there is to see here is its pane back to the width it had, the
    // counterpart gone from the status bar, and no comparison left to scroll it.
    // diff-b.bin has no edits, so nothing prompts.
    ui_close_current_tab(); // the focused pane is the one the comparison opened
    frame(); frame();
    shot("shot-diff-closed.bmp");

    // Scenario 19: the easter egg. Last of the set, because it leaves two
    // dialogs stacked and both of them own a control the label search would
    // find first. The version line in the About dialog looks like a label and
    // is not one; clicking it launches the ship.
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
    shot("shot-elite.bmp");

    return 0;
}
