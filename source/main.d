/// Main loop.
module main;

import core.time : MonoTime, Duration, nsecs;
import std.format : format;
import std.string : fromStringz, toStringz;
import ddlogger;
import bindbc.sdl;
import about : VERSION, COMPILER, HOMEPAGE, LICENSE;
import ddui;
import elevate : ELEVATE_ARG, elevate_helper;
import icon : icon_apply;
import loader;
import logging : logging_init, logging_sdl;
import input : input_event;
import render;
import ui;
import preferences : prefs_load;
version (Screenshots) import screenshots;
version (FrameStats) import framestats;

private enum VERSION_TEXT =
    "vddhx " ~ VERSION ~ "\n" ~
    "Built with " ~ COMPILER ~ "\n" ~
    "License: " ~ LICENSE ~ "\n" ~
    HOMEPAGE ~ "\n";

private enum HELP =
    "Graphical hex editor\n" ~
    "\n" ~
    "Usage: vddhx [OPTIONS] [FILE...]\n" ~
    "\n" ~
    "Options:\n" ~
    "  --console     Windows: attach a console for logs\n" ~
    "  --verbose     Log debugging messages\n" ~
    "  --trace       Log everything, SDL's verbose messages included\n" ~
    "  -h, --help    Print this help and exit\n" ~
    "  --version     Print version information and exit\n";

int main(string[] args)
{
    // Elevated helper (elevate.d): one open, no window.
    if (args.length > 1 && args[1] == ELEVATE_ARG)
        return elevate_helper(args[2 .. $]);

    bool console;
    LogLevel loglevel = LogLevel.info;
    string[] paths;
    foreach (string arg; args[1 .. $])
    {
        switch (arg)
        {
        case "-h", "--help":    return cli_print(HELP);
        case "--version":       return cli_print(VERSION_TEXT);
        case "--console":       console = true; break;
        case "--verbose":       loglevel = LogLevel.debugging; break;
        case "--trace":         loglevel = LogLevel.trace; break;
        default:                paths ~= arg;
        }
    }

    version (Windows)
    {
        // GUI subsystem has no stderr; attach a console only on request.
        if (console && console_attach())
            logAddAppender(new ConsoleAppender());
    }
    else
        logAddAppender(new ConsoleAppender());

    // Don't let screenshot runs rotate out a real session's log.
    bool logfile = true;
    version (Screenshots)
    {
        import std.algorithm.searching : canFind;
        logfile = args.canFind("--screenshot") == false;
    }
    logging_init(loglevel, logfile);

    // Dynamic config: no SDL_*/TTF_* call before this, screenshot driver included.
    if (loader_init() == false)
        return 1;
    scope(exit) loader_quit();
    logging_sdl(loglevel);

    version (Screenshots)
    {
        if (args.canFind("--screenshot"))
            return screenshot_run(args);
    }

    if (SDL_Init(SDL_INIT_VIDEO) == false)
        return fatal(null, format("SDL_Init: %s", SDL_GetError().fromStringz));
    scope(exit) SDL_Quit();
    logInfo("video driver: %s", SDL_GetCurrentVideoDriver().fromStringz);

    SDL_Window* window = SDL_CreateWindow("vddhx", 800, 600, SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY);
    if (window is null)
        return fatal(null, format("SDL_CreateWindow: %s", SDL_GetError().fromStringz));
    scope(exit) SDL_DestroyWindow(window);

    icon_apply(window);

    if (SDL_SetWindowMinimumSize(window, 640, 480) == false)
        return fatal(window, format("SDL_SetWindowMinimumSize: %s", SDL_GetError().fromStringz));

    SDL_Renderer* renderer = render_create(window);
    if (renderer is null)
        return fatal(window, format("SDL_CreateRenderer: %s", SDL_GetError().fromStringz));
    scope(exit) SDL_DestroyRenderer(renderer);

    // Cap the loop to the display refresh instead of a manual frame delay.
    if (SDL_SetRenderVSync(renderer, SDL_RENDERER_VSYNC_ADAPTIVE) == false)
    {
        logInfo("SDL_SetRenderVSync(SDL_RENDERER_VSYNC_ADAPTIVE) -> false, falling back to 1");
        if (SDL_SetRenderVSync(renderer, 1) == false)
            logInfo("no vsync on this renderer: %s", SDL_GetError().fromStringz);
    }

    string reason = render_init(renderer);
    if (reason.length)
        return fatal(window, reason);
    scope(exit) render_quit();
    render_set_density(SDL_GetWindowPixelDensity(window));

    SDL_StartTextInput(window);

    // mu_Context is (or was?) too large for the default MSVC stack, which is 1 MiB.
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
    ctx.style.font  = render_font_ui();
    ctx.get_clipboard = &clipboardGet;  // omnibar Ctrl+C/X/V
    ctx.set_clipboard = &clipboardSet;
    ui_style(ctx);

    // Before ui_init: the first tab uses the defaults.
    prefs_load();
    ui_zoom(0);
    ui_fonts(false);

    // Window is the parent for native file dialogs.
    ui_init(window);

    // One tab per path; the first reuses the initial blank tab. Failures are
    // skipped (ui_open logs them).
    foreach (string path; paths)
        ui_open(path);

    logDebugging("Starting loop");

    // Frames to draw after input. A click opening a popup or moving focus takes
    // effect a frame later, so 1 isn't enough.
    enum FRAMES_PER_INPUT = 3;

    bool running = true;
    int frames = FRAMES_PER_INPUT; // draw the first frame
    Duration interval = frameInterval(window);
    MonoTime frameStart;
    bool skipped;
    version (Screenshots) bool wantShot;
    while (running)
    {
        // Idle: block in SDL instead of redrawing identical frames. All screen
        // changes arrive as events (file dialogs push via ui_wakeup). null leaves
        // the event queued for the drain below. While ui_animating, run on vsync.
        if (frames <= 0 && ui_animating() == false && SDL_WaitEvent(null) == false)
        {
            // Only fails on error; retrying would busy-loop.
            logCritical("SDL_WaitEvent: %s", SDL_GetError().fromStringz);
            break;
        }

        // Nothing presented last frame, so no vsync wait happened: throttle to the
        // refresh rate here. Before the drain so events during the wait make it in.
        if (skipped)
        {
            Duration left = interval - (MonoTime.currTime - frameStart);
            if (left > Duration.zero)
                SDL_DelayPrecise(left.total!"nsecs");
        }

        SDL_Event event = void;
        while (SDL_PollEvent(&event))
        {
            frames = FRAMES_PER_INPUT;
            version (FrameStats) stats_event();

            switch (event.type)
            {
            case SDL_EVENT_QUIT:
                // All quit routes (window close, File > Quit, Ctrl+Q) go through this check.
                if (ui_may_quit())
                    running = false;
                break;
            case SDL_EVENT_WINDOW_FIRST: .. case SDL_EVENT_WINDOW_LAST:
            case SDL_EVENT_RENDER_TARGETS_RESET, SDL_EVENT_RENDER_DEVICE_RESET:
                // Back buffer is stale or lost.
                mu_invalidate(ctx);
                if (event.type == SDL_EVENT_WINDOW_DISPLAY_CHANGED)
                    interval = frameInterval(window);
                if (event.type == SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED)
                    render_set_density(SDL_GetWindowPixelDensity(window));
                break;
            default:
                version (Screenshots)
                {
                    if (shotChord(event))
                    {
                        wantShot = true;
                        mu_invalidate(ctx);
                        break;
                    }
                }
                input_event(ctx, event);
            }
        }

        int width, height;
        SDL_GetWindowSize(window, &width, &height);
        frameStart = MonoTime.currTime;
        version (FrameStats) stats_begin();
        mu_begin(ctx);
        ui_frame(ctx, width, height);
        mu_end(ctx);
        version (FrameStats) stats_end(Phase.build);

        bool dirty = mu_frame_dirty(ctx);
        skipped = dirty == false;
        version (FrameStats) stats_dirty(ctx, dirty);
        if (dirty == false)
        {
            --frames;
            version (FrameStats) stats_frame_done();
            continue;
        }

        SDL_SetRenderDrawColor(renderer, 30, 30, 46, 255);
        SDL_RenderClear(renderer);
        render_commands(renderer, ctx);
        version (FrameStats) stats_end(Phase.render);

        // Capture from the finished backbuffer, before presenting.
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
        version (FrameStats)
        {
            stats_end(Phase.present);
            stats_frame_done();
        }
        --frames;
    }

    return 0;
}

/// Display refresh interval, 60 Hz if unknown.
Duration frameInterval(SDL_Window* window)
{
    const(SDL_DisplayMode)* mode = SDL_GetCurrentDisplayMode(SDL_GetDisplayForWindow(window));
    float hz = mode && mode.refresh_rate > 0 ? mode.refresh_rate : 60;
    return nsecs(cast(long)(1_000_000_000 / hz));
}

// No window or console (desktop launch) to report startup failures, so use
// SDL's message box, which uses platform fonts.
private int fatal(SDL_Window* window, string message)
{
    logCritical("%s", message);
    SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "vddhx", message.toStringz, window);
    return 1;
}

/// ddui clipboard hooks for the omnibar (hex panel has its own in ui.d).
/// SDL returns an owned copy but ddui expects a borrowed pointer, hence the
/// static buffer. Overlong text is cut on a UTF-8 boundary.
extern (C) private const(char)* clipboardGet(mu_Context* ctx) nothrow
{
    __gshared char[4096] buffer;

    char* text = SDL_GetClipboardText(); // empty string if none
    if (text is null)
        return null;
    scope(exit) SDL_free(text);

    size_t n;
    while (text[n] && n + 1 < buffer.length)
    {
        buffer[n] = text[n];
        ++n;
    }
    if (text[n]) // truncated: back off partial character
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

// Ctrl+Shift+F12 captures the frame; avoids PrintScreen and Linux's
// Ctrl+Alt+F* VT switch. Checked before input_event so it always works.
version (Screenshots)
private bool shotChord(ref const(SDL_Event) event)
{
    return event.type == SDL_EVENT_KEY_DOWN && event.key.key == SDLK_F12 &&
        event.key.mod & SDL_KMOD_CTRL && event.key.mod & SDL_KMOD_SHIFT;
}

version (Windows)
private bool console_attach()
{
    import core.sys.windows.windef : FALSE;
    import core.sys.windows.wincon : AttachConsole, AllocConsole, ATTACH_PARENT_PROCESS;
    import std.stdio : stdout, stderr;

    // Alloc for shortcut launches with no parent console.
    if (AttachConsole(ATTACH_PARENT_PROCESS) == FALSE && AllocConsole() == FALSE)
        return false;
    try
    {
        stdout.reopen("CONOUT$", "w");
        stderr.reopen("CONOUT$", "w");
    }
    catch (Exception)
        return false;
    return true;
}

// GUI subsystem has no stdout, this tries attach the console on Windows before printing.
private int cli_print(string text)
{
    import std.stdio : write;

    version (Windows)
    {
        if (console_attach() == false)
            return 1;
    }
    write(text);
    return 0;
}
