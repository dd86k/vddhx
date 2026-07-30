/// Debug-only frame capture. Compiled in only under `version (Screenshot)`
/// (see the "screenshot" buildType in dub.sdl): `dub build -b screenshot`.
///
/// Two entry points share one capture primitive:
///   - screenshot_save: dump the current renderer backbuffer to a BMP. main
///     calls this live when Ctrl+Shift+F12 is pressed.
///   - screenshot_run: a headless, scripted driver (offscreen SDL) that renders
///     canned UI states and captures each, so visual regressions can be checked
///     without a display. Convert the BMPs with `ffmpeg -y -i x.bmp x.png`.
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
    enum int W = 800, H = 600;

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

    // Render the current command list and write it out.
    bool shot(const(char)* path)
    {
        SDL_SetRenderDrawColor(renderer, 30, 30, 46, 255);
        SDL_RenderClear(renderer);
        render_commands(renderer, &ctx);
        return screenshot_save(renderer, path);
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

    // Press one mapped key for a frame (down, render, up).
    void tap(int key) { mu_input_keydown(&ctx, key); frame(); mu_input_keyup(&ctx, key); }

    // Hold `mod` down across one press of `key`, for chords like Ctrl+Z.
    void chord(int mod, int key)
    {
        mu_input_keydown(&ctx, mod);
        mu_input_keydown(&ctx, key); frame(); mu_input_keyup(&ctx, key);
        mu_input_keyup(&ctx, mod);
    }

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
    mu_input_mousemove(&ctx, grab.x + 143, grabY); frame(); frame();
    shot("shot-tabs-drag2.bmp");
    mu_input_mouseup(&ctx, grab.x + 143, grabY, MU_MOUSE_LEFT); frame(); frame();
    shot("shot-tabs-dropped.bmp");

    // Middle-clicking one closes it: the shortest route through the close path
    // without guessing where inside the tab its close box sits. other.bin has no
    // unsaved edits, so it goes without a prompt (which would need a display).
    mu_Vec2 other = find("other.bin");
    mu_input_mousemove(&ctx, other.x + 3, other.y + 3); frame(); frame();
    mu_input_mousedown(&ctx, other.x + 3, other.y + 3, MU_MOUSE_MIDDLE); frame();
    mu_input_mouseup(&ctx, other.x + 3, other.y + 3, MU_MOUSE_MIDDLE); frame();
    shot("shot-tabs-closed.bmp");

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
    // select four bytes and mark the run, then list them; the panel tints every
    // byte of both, grid and minimap.
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

    return 0;
}
