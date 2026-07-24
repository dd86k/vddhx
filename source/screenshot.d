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
import hexview : HEX_KEY_HOME, HEX_KEY_DEL, HEX_KEY_UNDO, HEX_KEY_REDO,
    HEX_KEY_LEFT, HEX_KEY_RIGHT;
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
    mu_Vec2 find(const(char)* label)
    {
        foreach (ref mu_Command cmd; mu_command_range(&ctx))
            if (cmd.type == MU_COMMAND_TEXT &&
                strncmp(cmd.text.str.ptr, label, cast(int) strlen(label)) == 0)
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

    return 0;
}
