/// Help > About dialog.
/// Authors: dd86k <dd@dax.moe>
module about;

import std.format : format;
import std.math : sqrt;
import std.string : toStringz;
import bindbc.sdl : SDL_OpenURL, SDL_GetVersion,
    SDL_VERSIONNUM_MAJOR, SDL_VERSIONNUM_MINOR, SDL_VERSIONNUM_MICRO;
import ddlogger;
import ddui;
import elite : elite_open;
import logging : logging_folder;
import hexview : hex_classify;

/// Application version. Lives here only; dub.sdl has none (dub uses git tags).
enum VERSION = "0.1.1";

enum AUTHOR = "dd <dd@dax.moe>";                    // @suppress(dscanner.style.undocumented_declaration)
enum HOMEPAGE = "https://github.com/dd86k/vddhx";   // @suppress(dscanner.style.undocumented_declaration)
enum LICENSE = "MIT";                               // @suppress(dscanner.style.undocumented_declaration)

/// Compiler that built this binary, e.g. "LDC (frontend 2.111)".
/// NOTE: __VENDOR__/__VERSION__ don't give the compiler's own version (e.g.
/// LDC 1.x), only the frontend.
enum COMPILER = __VENDOR__ ~ " (frontend " ~ frontendVersion(__VERSION__) ~ ")";

/// Render __VERSION__ (major*1000 + minor) as a string: "2.111".
private string frontendVersion(uint v)
{
    return format("%u.%03u", v / 1000, v % 1000);
}

/// Runtime SDL version, e.g. "3.4.12". Not bindbc's (baseline 3.2.0). Only
/// valid after SDL is loaded.
private string sdlVersion()
{
    static string cached;
    if (cached is null)
    {
        int v = SDL_GetVersion();
        cached = format("%d.%d.%d", SDL_VERSIONNUM_MAJOR(v), SDL_VERSIONNUM_MINOR(v),
            SDL_VERSIONNUM_MICRO(v));
    }
    return cached;
}

/// Log folder for display; home shortened to ~ on Posix.
private string logsShown()
{
    static string cached;
    if (cached is null)
    {
        cached = logging_folder();
        version (Posix)
        {
            import os.path : getHomeFolder;
            string home = getHomeFolder();
            if (home.length && cached.length > home.length &&
                cached[0 .. home.length] == home && cached[home.length] == '/')
                cached = "~" ~ cached[home.length .. $];
        }
    }
    return cached;
}

/// `path` as a file:// URL for SDL_OpenURL.
private string fileUrl(string path)
{
    import std.algorithm.searching : canFind;
    import std.array : Appender;
    import std.ascii : isAlphaNum;

    Appender!string url;
    url.put("file://");
    version (Windows)
        url.put('/'); // file:///C:/...
    foreach (char c; path)
    {
        version (Windows)
        {
            if (c == '\\')
                c = '/';
        }
        if (isAlphaNum(c) || "-._~/:".canFind(c))
            url.put(c);
        else
            url.put(format("%%%02X", c)); // byte-wise, so UTF-8 encodes correctly
    }
    return url.data;
}

/// Window title, also the container key.
private enum TITLE = "About vddhx";

private enum int WIDTH  = 460;
private enum int HEIGHT = 270;

/// Icon size beside the heading.
private enum int MARK = 48;

private enum mu_Color LINK_COLOR = mu_Color(110, 170, 255, 255);
private enum mu_Color LINK_HOVER = mu_Color(160, 205, 255, 255);

// Deferred to the next about_frame: placement needs the window size.
private __gshared bool wantOpen;

/// Request the dialog. Safe anywhere in a frame.
void about_open()
{
    wantOpen = true;
}

/// Draw the dialog if open. Call once per frame from ui_frame, after the main
/// window ends, so it's a root container on top.
void about_frame(mu_Context* ctx, int width, int height)
{
    if (wantOpen)
    {
        wantOpen = false;
        // mu_get_container creates it open; until then the MU_OPT_CLOSED window below
        // gets null and stays hidden.
        mu_Container* cnt = mu_get_container(ctx, TITLE);
        cnt.rect = mu_Rect((width - WIDTH) / 2, (height - HEIGHT) / 2, WIDTH, HEIGHT);
        cnt.open = 1;
        mu_bring_to_front(ctx, cnt);
    }

    if (mu_begin_window_ex(ctx, TITLE, mu_Rect(0, 0, WIDTH, HEIGHT),
            MU_OPT_NORESIZE | MU_OPT_NOSCROLL | MU_OPT_CLOSED) == 0)
        return;

    static immutable int[2] heading = [ MARK, -1 ];
    mu_layout_row(ctx, 2, heading.ptr, MARK);
    about_mark(ctx, mu_layout_next(ctx));

    static immutable int[1] full = [ -1 ];
    mu_layout_begin_column(ctx);
    mu_layout_row(ctx, 1, full.ptr, 0);
    if (about_secret(ctx, "vddhx " ~ VERSION))
    {
        elite_open();
        // Close: mu_end raises the clicked root container, so the dialog would cover
        // what it just opened.
        mu_get_current_container(ctx).open = 0;
    }
    mu_label(ctx, "A graphical port of the ddhx hex editor.");
    mu_layout_end_column(ctx);

    // Label column wide enough for the longest caption, value column fills.
    static immutable int[2] fields = [ 92, -1 ];
    mu_layout_row(ctx, 2, fields.ptr, 0);
    mu_label(ctx, "Author");
    mu_label(ctx, AUTHOR);
    mu_label(ctx, "Homepage");
    if (about_link(ctx, HOMEPAGE))
    {
        if (SDL_OpenURL(HOMEPAGE.toStringz) == false)
        {
            import std.string : fromStringz;
            import bindbc.sdl : SDL_GetError;
            logError("SDL_OpenURL: %s", SDL_GetError().fromStringz);
        }
    }
    mu_label(ctx, "License");
    mu_label(ctx, LICENSE);
    mu_label(ctx, "Compiler");
    mu_label(ctx, COMPILER);
    mu_label(ctx, "SDL");
    mu_label(ctx, sdlVersion());
    mu_label(ctx, "Logs");
    if (string folder = logging_folder())
    {
        if (about_link(ctx, logsShown()) && SDL_OpenURL(fileUrl(folder).toStringz) == false)
        {
            import std.string : fromStringz;
            import bindbc.sdl : SDL_GetError;
            logError("SDL_OpenURL: %s", SDL_GetError().fromStringz);
        }
    }
    else
        mu_label(ctx, "not logging to a file");

    // Right-align the button.
    static immutable int[2] closerow = [ -90, -1 ];
    mu_layout_row(ctx, 2, closerow.ptr, 0);
    mu_label(ctx, "");
    if (mu_button(ctx, "Close"))
        mu_get_current_container(ctx).open = 0;

    mu_end_window(ctx);
}

// Icon palette. Byte-class colors come from hex_classify so they can't drift.
private enum mu_Color NUL    = hex_classify(0, 0x00, null);
private enum mu_Color PRINT  = hex_classify(0, 'A',  null);
private enum mu_Color WS     = hex_classify(0, '\n', null);
private enum mu_Color CTRL   = hex_classify(0, 0x01, null);
private enum mu_Color HIGH   = hex_classify(0, 0x80, null);
/// Not a byte class: the bookmark tint is too dark for a whole cell.
private enum mu_Color ACCENT = mu_Color(230, 170, 60, 255);
/// ui.d's CANVAS (black) would vanish in a dark dialog.
private enum mu_Color PLATE  = mu_Color(18, 18, 22, 255);

private immutable mu_Color[3][3] MARK_CELLS = [
    [HIGH,  PRINT,  CTRL],
    [PRINT, ACCENT, WS],
    [NUL,   NUL,    HIGH],
];

/// Draw the application icon into `box`, from tools/mkicon.d's geometry.
/// Rasterising the real one costs ~28ms at 256px, too slow for startup; the
/// only difference at this size is antialiasing.
private void about_mark(mu_Context* ctx, mu_Rect box)
{
    // mkicon.d units: plate inset 2 of 64, side 60, radius 13; cells 12 wide,
    // 3 apart from 11, radius 2.5.
    const int n = box.w < box.h ? box.w : box.h;
    const float u = n / 64.0f;
    const int ox = box.x + (box.w - n) / 2;
    const int oy = box.y + (box.h - n) / 2;

    int at(float v) { return cast(int)(v * u + 0.5f); }

    round_rect(ctx, mu_Rect(ox + at(2), oy + at(2), at(60), at(60)), 13 * u, PLATE);

    const int cw = at(12);
    foreach (int row, const mu_Color[3] line; MARK_CELLS)
        foreach (int col, mu_Color c; line)
        {
            round_rect(ctx, mu_Rect(ox + at(11 + col * 15), oy + at(11 + row * 15), cw, cw),
                2.5f * u, c);
        }
}

/// Fill a rounded rect with ddui rects. Rows with the same inset are merged,
/// so it costs ~r rects per corner. Not antialiased.
private void round_rect(mu_Context* ctx, mu_Rect r, float rad, mu_Color color)
{
    int runY, runInset = row_inset(0, r.h, rad);
    foreach (int y; 1 .. r.h)
    {
        const int inset = row_inset(y, r.h, rad);
        if (inset == runInset)
            continue;
        mu_draw_rect(ctx, mu_Rect(r.x + runInset, r.y + runY, r.w - 2 * runInset, y - runY), color);
        runInset = inset;
        runY = y;
    }
    mu_draw_rect(ctx, mu_Rect(r.x + runInset, r.y + runY, r.w - 2 * runInset, r.h - runY), color);
}

/// Scanline inset; 0 between the corner arcs.
private int row_inset(int y, int h, float rad)
{
    const float mid = y + 0.5f;
    float d = void;
    if (mid < rad)
        d = rad - mid;
    else if (mid > h - rad)
        d = mid - (h - rad);
    else
        return 0;
    return cast(int)(rad - sqrt(rad * rad - d * d) + 0.5f);
}

/// Hidden clickable label, drawn exactly like mu_label (no hint, no tab stop).
/// Returns: true on the frame it is left-clicked.
private bool about_secret(mu_Context* ctx, string text)
{
    mu_Id id = mu_get_id(ctx, text.ptr, text.length);
    mu_Rect r = mu_layout_next(ctx);
    mu_update_control(ctx, id, r, 0);
    mu_draw_control_text(ctx, text, r, MU_COLOR_TEXT, 0);
    return ctx.mouse_pressed == MU_MOUSE_LEFT && ctx.focus == id;
}

/// URL link: colored, underlined on hover/focus.
/// Returns: true on left click or Return.
private bool about_link(mu_Context* ctx, string url)
{
    mu_Id id = mu_get_id(ctx, url.ptr, url.length);
    mu_Rect r = mu_layout_next(ctx);
    mu_update_control(ctx, id, r, MU_OPT_TABSTOP);

    bool submit = (ctx.mouse_pressed == MU_MOUSE_LEFT && ctx.focus == id) ||
                  (ctx.focus == id && (ctx.key_pressed & MU_KEY_RETURN) != 0);

    bool lit = ctx.hover == id || ctx.focus == id;
    mu_Color color = lit ? LINK_HOVER : LINK_COLOR;

    // Left-aligned, vertically centered, like mu_label.
    mu_Font font = ctx.style.font;
    int th = ctx.text_height(font);
    mu_Vec2 pos = mu_Vec2(r.x + ctx.style.padding, r.y + (r.h - th) / 2);
    mu_draw_text(ctx, font, url, pos, color);
    if (lit)
    {
        int tw = ctx.text_width(font, url.ptr, cast(int) url.length);
        mu_draw_rect(ctx, mu_Rect(pos.x, pos.y + th - 1, tw, 1), color);
    }
    return submit;
}
