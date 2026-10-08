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
import input : input_event;
import render;
import ui;
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
    "  -h, --help    Print this help and exit\n" ~
    "  --version     Print version information and exit\n";

int main(string[] args)
{
    // The elevated copy elevate.d starts: one open, no window.
    if (args.length > 1 && args[1] == ELEVATE_ARG)
        return elevate_helper(args[2 .. $]);

    bool console;
    string[] paths;
    foreach (string arg; args[1 .. $])
    {
        switch (arg)
        {
        case "-h", "--help":    return cli_print(HELP);
        case "--version":       return cli_print(VERSION_TEXT);
        case "--console":       console = true; break;
        default:                paths ~= arg;
        }
    }

    // Ideally, should be logging to a file (appdata etc.),
    // but this is a stopgap to see if loader loads proper
    version (Windows)
    {
        // The GUI subsystem starts without stderr; only borrow a console on request.
        if (console && console_attach())
            logAddAppender(new ConsoleAppender());
    }
    else
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
        return fatal(null, format("SDL_Init: %s", SDL_GetError().fromStringz));
    scope(exit) SDL_Quit();

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
    foreach (string path; paths)
        ui_open(path);

    logDebugging("Starting loop");

    // Frames still owed to the last input. One is not enough: a click that opens a
    // popup or moves focus lands on the frame after the one that read it.
    enum FRAMES_PER_INPUT = 3;

    bool running = true;
    int frames = FRAMES_PER_INPUT; // the first frame is owed to nothing: draw it
    Duration interval = frameInterval(window);
    MonoTime frameStart;
    bool skipped;
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

        // Nothing was presented last frame, so nothing waited on vsync: hold the
        // loop to the refresh rate, or motion would build frames nobody sees.
        // Before the drain, so whatever arrives while waiting makes this frame.
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
                // Single choke point for every quit route: the File > Quit menu
                // and Ctrl+Q push this too, so all three meet the same check.
                if (ui_may_quit())
                    running = false;
                break;
            case SDL_EVENT_WINDOW_FIRST: .. case SDL_EVENT_WINDOW_LAST:
            case SDL_EVENT_RENDER_TARGETS_RESET, SDL_EVENT_RENDER_DEVICE_RESET:
                // The back buffer is stale or gone, whatever ddui thinks of it.
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
        version (FrameStats)
        {
            stats_end(Phase.present);
            stats_frame_done();
        }
        --frames;
    }

    return 0;
}

/// One refresh of the display the window is on, 60 Hz when it will not say.
Duration frameInterval(SDL_Window* window)
{
    const(SDL_DisplayMode)* mode = SDL_GetCurrentDisplayMode(SDL_GetDisplayForWindow(window));
    float hz = mode && mode.refresh_rate > 0 ? mode.refresh_rate : 60;
    return nsecs(cast(long)(1_000_000_000 / hz));
}

// Startup gives out before there is a window to draw the reason into, and a
// desktop launcher has no console to leave it on: SDL's box is the only surface
// left, and it is drawn by the platform rather than by the fonts we just failed
// to find.
private int fatal(SDL_Window* window, string message)
{
    logCritical("%s", message);
    SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "vddhx", message.toStringz, window);
    return 1;
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

// Ctrl+Shift+F12 grabs the current frame, dodging both desktop PrintScreen
// capture and the Linux Ctrl+Alt+F* terminal switch. Ahead of input_event, so a
// frame can be captured whatever else has the keyboard.
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

    // Allocating covers a shortcut launch, where there is no parent console.
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

// The Windows GUI subsystem starts with no stdout to print to.
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
