/// Main loop.
module main;

import std.string : fromStringz;
import ddlogger;
import bindbc.sdl;
import ddui;
import hexview;
import icon : icon_apply;
import loader;
import omnibar : OMNI_COMMAND, OMNI_ADDRESS, OMNI_FIND, OMNI_INSPECT,
    OMNI_KEY_UP, OMNI_KEY_DOWN;
import render;
import ui;
version (Screenshots) import screenshots;

int main(string[] args)
{
    // Ideally, should be logging to a file (appdata etc.),
    // but this is a stopgap to see if loader loads proper
    logAddAppender(new ConsoleAppender());
    logSetLevel(LogLevel.debugging);

    // Under the dynamic configuration nothing may touch SDL_* or TTF_* before
    // this, the screenshot driver included.
    if (loader_init() == false)
        return 1;
    scope(exit) loader_quit();

    version (Screenshots)
    {
        import std.algorithm.searching : canFind;
        if (args.canFind("--screenshot"))
            return screenshot_run(args);
    }

    if (SDL_Init(SDL_INIT_VIDEO) == false)
    {
        logCritical("SDL_Init: %s", SDL_GetError().fromStringz);
        return 1;
    }
    scope(exit) SDL_Quit();

    SDL_Window* window = SDL_CreateWindow("vddhx", 800, 600, SDL_WINDOW_RESIZABLE);
    if (window is null)
    {
        logCritical("SDL_CreateWindow: %s", SDL_GetError().fromStringz);
        return 1;
    }
    scope(exit) SDL_DestroyWindow(window);

    icon_apply(window);

    if (SDL_SetWindowMinimumSize(window, 640, 480) == false)
    {
        logCritical("SDL_SetWindowMinimumSize: %s", SDL_GetError().fromStringz);
        return 1;
    }

    SDL_Renderer* renderer = SDL_CreateRenderer(window, null);
    if (renderer is null)
    {
        logCritical("SDL_CreateRenderer: %s", SDL_GetError().fromStringz);
        return 1;
    }
    scope(exit) SDL_DestroyRenderer(renderer);

    // Cap the loop to the display refresh instead of a manual frame delay.
    if (SDL_SetRenderVSync(renderer, SDL_RENDERER_VSYNC_ADAPTIVE) == false)
    {
        logInfo("SDL_SetRenderVSync(SDL_RENDERER_VSYNC_ADAPTIVE) -> false, falling back to 1");
        SDL_SetRenderVSync(renderer, 1); // fall back to plain vsync
    }

    if (render_init(renderer) == false)
    {
        logCritical("render_init: %s", SDL_GetError().fromStringz);
        return 1;
    }
    scope(exit) render_quit();

    SDL_StartTextInput(window);

    // Allocated because otherwise mu_Context does not fit in the default
    // MSVC stack size :)
    import core.stdc.stdlib : malloc;
    mu_Context *ctx = cast(mu_Context*) malloc(mu_Context.sizeof);
    if (ctx == null)
    {
        import core.stdc.string : strerror;
        import core.stdc.errno : errno;
        logCritical("malloc: %s", strerror(errno).fromStringz);
        return 1;
    }
    
    // Set up the ddui context
    mu_init(ctx);
    ctx.text_width  = &render_text_width;
    ctx.text_height = &render_text_height;
    ctx.style.font  = render_font_ui(); // TTF_Font* handle carried on every text command
    ctx.get_clipboard = &clipboardGet;  // so the omnibar's box takes Ctrl+C / X / V
    ctx.set_clipboard = &clipboardSet;
    ui_style(ctx);

    // Give the UI the window so File > Open can parent its native dialog to it.
    ui_init(window);

    // One tab each, the first taking over the blank one we start on. A failure
    // just leaves the tab out (ui_open logs the reason).
    foreach (string path; args[1 .. $])
        ui_open(path);

    logDebugging("Starting loop");

    // Frames still owed to the last input. One is not enough: a click that opens a
    // popup or moves focus lands on the frame after the one that read it.
    enum FRAMES_PER_INPUT = 3;

    bool running = true;
    int frames = FRAMES_PER_INPUT; // the first frame is owed to nothing: draw it
    version (Screenshots) bool wantShot;
    while (running)
    {
        // Idle: sleep in SDL rather than rebuild an identical frame on every
        // display refresh. Everything that changes the screen arrives as an event,
        // the async file dialogs pushing their own (ui_wakeup) from their thread.
        // The null leaves the event in the queue for the drain below.
        //
        // ui_animating is the one thing that can owe a frame to nothing: while it
        // holds, the loop free-runs on vsync.
        if (frames <= 0 && ui_animating() == false && SDL_WaitEvent(null) == false)
        {
            // Only ever false on error, and a broken queue does not heal: going
            // back to sleep on it would spin the loop at full speed instead.
            logCritical("SDL_WaitEvent: %s", SDL_GetError().fromStringz);
            break;
        }

        SDL_Event event = void;
        while (SDL_PollEvent(&event))
        {
            frames = FRAMES_PER_INPUT;
            switch (event.type)
            {
            case SDL_EVENT_QUIT:
                // Single choke point for every quit route: the File > Quit menu
                // and Ctrl+Q push this too, so all three meet the same check.
                if (ui_may_quit())
                    running = false;
                break;
            case SDL_EVENT_MOUSE_MOTION:
                mu_input_mousemove(ctx, cast(int) event.motion.x, cast(int) event.motion.y);
                break;
            case SDL_EVENT_MOUSE_WHEEL:
                mu_input_scroll(ctx, 0, cast(int)(event.wheel.y * -30));
                break;
            case SDL_EVENT_TEXT_INPUT:
                // Bookmarks step on the bare brackets, as they do in ddhx, bound
                // to the character typed rather than a keycode: outside US ANSI
                // they are rarely a key of their own (fr-ca puts them behind
                // AltGr, whose unshifted keycode is not a bracket at all), and
                // this is what the layout actually produced. The omnibar is a text
                // box, so it keeps its own brackets.
                if (ui_omni_active() == false && event.text.text && event.text.text[0] && event.text.text[1] == 0)
                {
                    if (event.text.text[0] == ']')
                    {
                        ui_mark_step(1);
                        break;
                    }
                    if (event.text.text[0] == '[')
                    {
                        ui_mark_step(-1);
                        break;
                    }
                }
                mu_input_text(ctx, event.text.text);
                break;
            case SDL_EVENT_DROP_POSITION:
                // Light up the pane being pointed at, so where the file would land
                // is visible before the button comes up.
                ui_drop_hover(cast(int) event.drop.x, cast(int) event.drop.y);
                break;
            case SDL_EVENT_DROP_BEGIN, SDL_EVENT_DROP_COMPLETE:
                ui_drop_clear();
                break;
            case SDL_EVENT_DROP_FILE:
                // SDL3 owns the path string (no free), so copy it before it goes.
                if (event.drop.data)
                    ui_drop_file(event.drop.data.fromStringz.idup,
                        cast(int) event.drop.x, cast(int) event.drop.y);
                break;
            case SDL_EVENT_MOUSE_BUTTON_DOWN, SDL_EVENT_MOUSE_BUTTON_UP:
                int btn = mouseButton(event.button.button);
                if (btn == 0)
                    break;
                int x = cast(int) event.button.x, y = cast(int) event.button.y;
                if (event.type == SDL_EVENT_MOUSE_BUTTON_DOWN)
                    mu_input_mousedown(ctx, x, y, btn);
                else
                    mu_input_mouseup(ctx, x, y, btn);
                break;
            case SDL_EVENT_KEY_DOWN, SDL_EVENT_KEY_UP:
                version (Screenshots)
                {
                    // Ctrl+Shift+F12 grabs the current frame, dodging both
                    // desktop PrintScreen capture and the Linux Ctrl+Alt+F*
                    // terminal switch. First of everything, so a frame can be
                    // captured whatever else has the keyboard.
                    if (event.type == SDL_EVENT_KEY_DOWN &&
                        event.key.key == SDLK_F12 &&
                        event.key.mod & SDL_KMOD_CTRL &&
                        event.key.mod & SDL_KMOD_SHIFT)
                    {
                        wantShot = true;
                        break;
                    }
                }
                // The omnibar next: Ctrl+E raises it on the tab switcher, one key
                // per prefixed mode raises it straight on that one, and each key
                // puts away the mode it opens. Ctrl+G, Ctrl+F and Alt+I are what
                // ddhx binds goto, find and the inspector to.
                if (event.type == SDL_EVENT_KEY_DOWN && event.key.mod & SDL_KMOD_CTRL)
                {
                    if (event.key.key == SDLK_E)
                    {
                        ui_omni_toggle();
                        break;
                    }
                    if (event.key.key == SDLK_P && event.key.mod & SDL_KMOD_SHIFT)
                    {
                        ui_omni_toggle(OMNI_COMMAND);
                        break;
                    }
                    if (event.key.key == SDLK_G)
                    {
                        ui_omni_toggle(OMNI_ADDRESS);
                        break;
                    }
                    if (event.key.key == SDLK_F)
                    {
                        ui_omni_toggle(OMNI_FIND);
                        break;
                    }
                }
                if (event.type == SDL_EVENT_KEY_DOWN && event.key.mod & SDL_KMOD_ALT &&
                    event.key.key == SDLK_I)
                {
                    ui_omni_toggle(OMNI_INSPECT);
                    break;
                }
                // While it is up it owns the keyboard, its keys going through
                // ddui's text-editing map rather than the panel's, whose chords
                // and hex digits would fight what is being typed.
                if (ui_omni_active())
                {
                    if (event.type == SDL_EVENT_KEY_DOWN && event.key.key == SDLK_ESCAPE)
                    {
                        ui_omni_close();
                        break;
                    }
                    int okey = omniKey(event.key.key);
                    if (okey == 0)
                        break;
                    if (event.type == SDL_EVENT_KEY_DOWN)
                        mu_input_keydown(ctx, okey);
                    else
                        mu_input_keyup(ctx, okey);
                    break;
                }
                // Menu chords: the File and Edit entries, keyed the way every GUI
                // toolkit keys them.
                if (event.type == SDL_EVENT_KEY_DOWN && event.key.mod & SDL_KMOD_CTRL)
                {
                    // Through SDL's queue rather than ending the loop here, so it
                    // meets the same unsaved-changes check as the other routes.
                    if (event.key.key == SDLK_Q)
                    {
                        SDL_Event quit; // .init zeroes the union
                        quit.type = SDL_EVENT_QUIT;
                        SDL_PushEvent(&quit);
                        break;
                    }
                    if (event.key.key == SDLK_O)
                    {
                        ui_open_dialog();
                        break;
                    }
                    // Ctrl+Tab is caught here so it never reaches ddui as a focus
                    // step.
                    if (event.key.key == SDLK_T)
                    {
                        ui_new_tab();
                        break;
                    }
                    if (event.key.key == SDLK_W)
                    {
                        ui_close_current_tab();
                        break;
                    }
                    if (event.key.key == SDLK_TAB)
                    {
                        ui_cycle_tab(event.key.mod & SDL_KMOD_SHIFT ? -1 : 1);
                        break;
                    }
                    // Ctrl+\ is what VS Code splits with, Shift stacking the new
                    // pane under the old one instead of alongside; Ctrl+1..9 is
                    // the editor-group binding rather than the browser tab one.
                    // On a layout that puts backslash behind AltGr neither fires,
                    // and the omnibar's "Split Pane Right" / "Down" are the route
                    // that always works.
                    if (event.key.key == SDLK_BACKSLASH)
                    {
                        if (event.key.mod & SDL_KMOD_SHIFT)
                            ui_split_down();
                        else
                            ui_split();
                        break;
                    }
                    if (event.key.key >= SDLK_1 && event.key.key <= SDLK_9)
                    {
                        ui_focus_pane(event.key.key - SDLK_1);
                        break;
                    }
                    // Shift forces the Save As dialog; plain Ctrl+S writes in
                    // place, falling back to the dialog when there is no path yet.
                    if (event.key.key == SDLK_S)
                    {
                        if (event.key.mod & SDL_KMOD_SHIFT)
                            ui_save_as();
                        else
                            ui_save();
                        break;
                    }
                    if (event.key.key == SDLK_X)
                    {
                        ui_cut();
                        break;
                    }
                    if (event.key.key == SDLK_C)
                    {
                        ui_copy();
                        break;
                    }
                    if (event.key.key == SDLK_V)
                    {
                        ui_paste();
                        break;
                    }
                    if (event.key.key == SDLK_N)
                    {
                        ui_find_repeat((event.key.mod & SDL_KMOD_SHIFT) != 0);
                        break;
                    }
                    if (event.key.key == SDLK_B)
                    {
                        ui_mark_toggle();
                        break;
                    }
                    // ddhx's skip-back / skip-forward, caught here so the arrow
                    // never reaches the panel, which would step one nibble.
                    if (event.key.key == SDLK_LEFT || event.key.key == SDLK_RIGHT)
                    {
                        ui_skip_element(event.key.key == SDLK_LEFT);
                        break;
                    }
                }
                int key = muiKey(event.key.key);
                if (key == 0)
                    break;
                if (event.type == SDL_EVENT_KEY_DOWN)
                    mu_input_keydown(ctx, key);
                else
                    mu_input_keyup(ctx, key);
                break;
            default:
            }
        }

        int width, height;
        SDL_GetWindowSize(window, &width, &height);
        mu_begin(ctx);
        ui_frame(ctx, width, height);
        mu_end(ctx);

        SDL_SetRenderDrawColor(renderer, 30, 30, 46, 255);
        SDL_RenderClear(renderer);
        render_commands(renderer, ctx);

        // Capture from the finished backbuffer, before present.
        version (Screenshots)
        {
            if (wantShot)
            {
                wantShot = false;
                enum SHOT = SCREENSHOT_DIR ~ "/vddhx.bmp";
                if (screenshot_mkdir(SCREENSHOT_DIR) == false)
                    logWarn("screenshot: cannot create " ~ SCREENSHOT_DIR);
                else if (screenshot_save(renderer, SHOT))
                    logInfo("screenshot: wrote " ~ SHOT);
                else
                    logWarn("screenshot: %s", SDL_GetError().fromStringz);
            }
        }

        SDL_RenderPresent(renderer);
        --frames;
    }

    return 0;
}

/// Map an SDL3 keycode for the omnibar's text box (0 if unmapped).
///
/// The panel's map below sends arrows and paging keys as HEX_KEY_* bits, several
/// of which collide with ddui's editing keys (HEX_KEY_HOME shares a bit with
/// MU_KEY_DELETE): right for the grid, wrong for a text box.
///
/// Copy / cut / paste / select-all are mapped from the bare letters, ddui only
/// honouring those bits while Ctrl is held.
private int omniKey(SDL_KeyCode key)
{
    switch (key)
    {
    case SDLK_RETURN, SDLK_KP_ENTER: return MU_KEY_RETURN;
    case SDLK_BACKSPACE:             return MU_KEY_BACKSPACE;
    case SDLK_LSHIFT, SDLK_RSHIFT:   return MU_KEY_SHIFT;
    case SDLK_LCTRL, SDLK_RCTRL:     return MU_KEY_CTRL;
    case SDLK_LALT, SDLK_RALT:       return MU_KEY_ALT;
    case SDLK_LEFT:                  return MU_KEY_LEFT;
    case SDLK_RIGHT:                 return MU_KEY_RIGHT;
    case SDLK_HOME:                  return MU_KEY_HOME;
    case SDLK_END:                   return MU_KEY_END;
    case SDLK_DELETE:                return MU_KEY_DELETE;
    case SDLK_C:                     return MU_KEY_COPY;      // with Ctrl
    case SDLK_X:                     return MU_KEY_CUT;       // ditto
    case SDLK_V:                     return MU_KEY_PASTE;     // ditto
    case SDLK_A:                     return MU_KEY_SELECTALL; // ditto
    case SDLK_UP:                    return OMNI_KEY_UP;
    case SDLK_DOWN:                  return OMNI_KEY_DOWN;
    default:                         return 0;
    }
}

/// ddui clipboard hooks, for the omnibar's text box (the hex panel does its own
/// in ui.d, bytes not being text). SDL hands out a copy the caller frees while
/// ddui expects a borrowed pointer, hence the static buffer; text too long for it
/// is cut back on a UTF-8 boundary so a paste never carries half a character.
extern (C) private const(char)* clipboardGet(mu_Context* ctx) nothrow
{
    __gshared char[4096] buffer;

    char* text = SDL_GetClipboardText(); // an empty string when there is nothing
    if (text is null)
        return null;
    scope(exit) SDL_free(text);

    size_t n;
    while (text[n] && n + 1 < buffer.length)
    {
        buffer[n] = text[n];
        ++n;
    }
    if (text[n]) // cut short: step back off any partial character
        while (n > 0 && (buffer[n] & 0xc0) == 0x80)
            --n;
    buffer[n] = 0;
    return buffer.ptr;
}

/// Ditto.
extern (C) private void clipboardSet(mu_Context* ctx, const(char)* str) nothrow
{
    SDL_SetClipboardText(str);
}

/// Map an SDL3 mouse button to a ddui mouse flag (0 if unmapped).
private int mouseButton(SDL_MouseButton button)
{
    switch (button)
    {
    case SDL_BUTTON_LEFT:   return MU_MOUSE_LEFT;
    case SDL_BUTTON_RIGHT:  return MU_MOUSE_RIGHT;
    case SDL_BUTTON_MIDDLE: return MU_MOUSE_MIDDLE;
    default:                return 0;
    }
}

/// Map an SDL3 keycode to ddui key flags (0 if unmapped). Modifiers come from
/// their own keycodes rather than the event's mod mask, so each physical key
/// toggles its bit symmetrically: on a modifier's key-up SDL3 reports the mask
/// with that bit already cleared, which left the bit stuck held in ddui. ddui
/// reads that held state itself, so Shift+Right needs only the arrow here.
private int muiKey(SDL_KeyCode key)
{
    switch (key)
    {
    case SDLK_RETURN, SDLK_KP_ENTER: return MU_KEY_RETURN;
    case SDLK_BACKSPACE:             return MU_KEY_BACKSPACE;
    case SDLK_TAB:                   return MU_KEY_TAB;
    case SDLK_LSHIFT, SDLK_RSHIFT:   return MU_KEY_SHIFT;
    case SDLK_LCTRL, SDLK_RCTRL:     return MU_KEY_CTRL;
    case SDLK_LALT, SDLK_RALT:       return MU_KEY_ALT;
    case SDLK_LEFT:                  return HEX_KEY_LEFT;
    case SDLK_RIGHT:                 return HEX_KEY_RIGHT;
    case SDLK_UP:                    return HEX_KEY_UP;
    case SDLK_DOWN:                  return HEX_KEY_DOWN;
    case SDLK_HOME:                  return HEX_KEY_HOME;
    case SDLK_END:                   return HEX_KEY_END;
    case SDLK_PAGEUP:                return HEX_KEY_PGUP;
    case SDLK_PAGEDOWN:              return HEX_KEY_PGDN;
    case SDLK_INSERT:                return HEX_KEY_INS;
    case SDLK_DELETE:                return HEX_KEY_DEL;
    case SDLK_Z:                     return HEX_KEY_UNDO; // undo when Ctrl is held
    case SDLK_Y:                     return HEX_KEY_REDO; // redo when Ctrl is held
    default:                         return 0;
    }
}
