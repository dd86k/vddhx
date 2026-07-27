/// Main loop.
module main;

import std.string : fromStringz;
import ddlogger;
import bindbc.sdl;
import ddui;
import hexview;
import render;
import ui;
version (Screenshot) import screenshot;

void main(string[] args)
{
    version (Screenshot)
    {
        import std.algorithm.searching : canFind;
        if (args.canFind("--screenshot"))
            return cast(void) screenshot_run(args);
    }

    logAddAppender(new ConsoleAppender());
    logSetLevel(LogLevel.debugging);

    if (SDL_Init(SDL_INIT_VIDEO) == false)
    {
        logCritical("SDL_Init: ", SDL_GetError().fromStringz);
        return;
    }
    scope(exit) SDL_Quit();

    SDL_Window* window = SDL_CreateWindow("vddhx", 800, 600, SDL_WINDOW_RESIZABLE);
    if (window is null)
    {
        logCritical("SDL_CreateWindow: ", SDL_GetError().fromStringz);
        return;
    }
    scope(exit) SDL_DestroyWindow(window);

    if (SDL_SetWindowMinimumSize(window, 640, 480) == false)
    {
        logCritical("SDL_SetWindowMinimumSize: ", SDL_GetError().fromStringz);
        return;
    }

    SDL_Renderer* renderer = SDL_CreateRenderer(window, null);
    if (renderer is null)
    {
        logCritical("SDL_CreateRenderer: ", SDL_GetError().fromStringz);
        return;
    }
    scope(exit) SDL_DestroyRenderer(renderer);

    // Cap the loop to the display refresh instead of a manual frame delay.
    if (SDL_SetRenderVSync(renderer, SDL_RENDERER_VSYNC_ADAPTIVE) == false)
    {
        logInfo("SDL_SetRenderVSync(SDL_RENDERER_VSYNC_ADAPTIVE) -> false, falling back to 1");
        SDL_SetRenderVSync(renderer, 1); // fall back to plain vsync
    }

    // Bring up SDL3_ttf, the text engine, and the font faces.
    if (render_init(renderer) == false)
    {
        logCritical("render_init: ", SDL_GetError().fromStringz);
        return;
    }
    scope(exit) render_quit();

    // Enable keyboard text input (for future textboxes; harmless for buttons).
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
        return;
    }
    
    // Set up the ddui context and its text-measuring callbacks.
    mu_init(ctx);
    ctx.text_width  = &render_text_width;
    ctx.text_height = &render_text_height;
    ctx.style.font  = render_font_ui(); // TTF_Font* handle carried on every text command

    // Give the UI the window so File > Open can parent its native dialog to it.
    ui_init(window);

    // Open the file named on the command line, if any. With no argument we start
    // on a blank panel rather than viewing our own executable. A failure here
    // just leaves the panel empty (ui_open logs the reason).
    if (args.length > 1)
        ui_open(args[1]);

    logDebugging("Starting loop");

    bool running = true;
    version (Screenshot) bool wantShot;
    while (running)
    {
        SDL_Event event = void;
        while (SDL_PollEvent(&event))
        {
            switch (event.type)
            {
            case SDL_EVENT_QUIT:
                // Single choke point for every quit route (window close, the
                // File > Quit menu and Ctrl+Q both push this). Let the UI clear
                // any unsaved changes before the loop ends.
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
                mu_input_text(ctx, event.text.text);
                break;
            case SDL_EVENT_DROP_FILE:
                // A file was dropped onto the window: open it. SDL3 owns the
                // path string (no free), so copy it before it goes away.
                if (event.drop.data)
                    ui_open(event.drop.data.fromStringz.idup);
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
                // Menu chords: the File and Edit entries, keyed the way every GUI
                // toolkit keys them. SDL sends no text-input event for a Ctrl
                // chord, so the panel never sees these as typed hex digits;
                // swallow them here either way.
                if (event.type == SDL_EVENT_KEY_DOWN && event.key.mod & SDL_KMOD_CTRL)
                {
                    // Quit goes through SDL's own event queue rather than ending
                    // the loop here, so it meets the same unsaved-changes check as
                    // the window close button and the File > Quit entry.
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
                }
                version (Screenshot)
                {
                    // Ctrl+Shift+F12 grabs the current frame. Chosen to dodge
                    // both desktop-environment PrintScreen capture and the Linux
                    // Ctrl+Alt+F* virtual-terminal switch.
                    if (event.type == SDL_EVENT_KEY_DOWN &&
                        event.key.key == SDLK_F12 &&
                        event.key.mod & SDL_KMOD_CTRL &&
                        event.key.mod & SDL_KMOD_SHIFT)
                    {
                        wantShot = true;
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

        // Build this frame's UI.
        int width, height;
        SDL_GetWindowSize(window, &width, &height);
        mu_begin(ctx);
        ui_frame(ctx, width, height);
        mu_end(ctx);

        // Draw it.
        SDL_SetRenderDrawColor(renderer, 30, 30, 46, 255);
        SDL_RenderClear(renderer);
        render_commands(renderer, ctx);

        // Capture from the finished backbuffer, before present.
        version (Screenshot)
        {
            if (wantShot)
            {
                wantShot = false;
                if (screenshot_save(renderer, "vddhx.bmp"))
                    logInfo("screenshot: wrote vddhx.bmp");
                else
                    logWarn("screenshot: %s", SDL_GetError().fromStringz);
            }
        }

        SDL_RenderPresent(renderer);
    }
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

/// Map an SDL3 keycode to ddui key flags (0 if unmapped). Modifiers are mapped
/// from their own keycodes rather than the event's mod mask, so each physical
/// key toggles its bit symmetrically on down/up. Deriving MU_KEY_SHIFT from the
/// mod mask instead left the bit stuck: on a modifier's own key-up, SDL3 reports
/// the mask with that bit already cleared, so no key-up ever reached ddui and
/// key_down kept the modifier held. ddui reads the held state from key_down, so
/// a chord like Shift+Right needs only the arrow keycode here.
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
