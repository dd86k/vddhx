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
    HEX_KEY_LEFT, HEX_KEY_RIGHT, HEX_KEY_DOWN;
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

    // Scenario 3: modal editing on the blank panel. Click into the grid to focus
    // it, then type hex digits to build a file from scratch (insert at EOF), and
    // capture the bytes the panel now shows.
    click(100, 140);
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

    return 0;
}
