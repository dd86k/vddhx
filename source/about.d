/// Help > About dialog: who wrote this, where it lives, and what built it.
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
import hexview : hex_classify;

/// Application version. Single source of truth: dub.sdl carries no version
/// field, since dub derives package versions from git tags.
enum VERSION = "0.1.0";

enum AUTHOR = "dd <dd@dax.moe>";                    /// Matching dub.sdl's authors/copyright fields.
enum HOMEPAGE = "https://github.com/dd86k/vddhx";   /// Opened from the dialog.
enum LICENSE = "MIT";                               /// Matching dub.sdl and the LICENSE file.

/// Compiler that built this binary, e.g. "LDC (frontend 2.111)".
///
/// Neither __VENDOR__ nor __VERSION__ reports the compiler's own patch level, nor
/// LDC's 1.x versioning, so the frontend number is what we can honestly show.
enum COMPILER = __VENDOR__ ~ " (frontend " ~ frontendVersion(__VERSION__) ~ ")";

/// Render __VERSION__'s packed major*1000 + minor form as a dotted version.
private string frontendVersion(uint v)
{
    return format("%u.%03u", v / 1000, v % 1000);
}

/// The SDL actually in use, e.g. "3.4.12".
///
/// Runtime rather than bindbc-sdl's compile-time version: the default build opens
/// whichever SDL3 the system has and the bindings sit at their 3.2.0 baseline, so
/// the two rarely agree. Only valid once SDL is loaded.
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

/// Window title, and the key ddui pools the dialog's container under.
private enum TITLE = "About vddhx";

private enum int WIDTH  = 460;
private enum int HEIGHT = 246;

/// Side of the icon beside the heading.
private enum int MARK = 48;

private enum mu_Color LINK_COLOR = mu_Color(110, 170, 255, 255);
private enum mu_Color LINK_HOVER = mu_Color(160, 205, 255, 255);

// Deferred to the next about_frame, since opening the dialog means placing its
// container against the current window size, which only the frame call knows.
private __gshared bool wantOpen;

/// Request the dialog. Safe to call from anywhere in a frame (the menu handler).
void about_open()
{
    wantOpen = true;
}

/// Draw the dialog if it is open. Call once per frame from ui_frame, after the
/// main window is ended, so it lands as its own root container on top.
/// Params:
///     ctx = ddui context.
///     width = Current window width in pixels.
///     height = Current window height in pixels.
void about_frame(mu_Context* ctx, int width, int height)
{
    if (wantOpen)
    {
        wantOpen = false;
        // mu_get_container creates the container (open) on first use; the window
        // below asks with MU_OPT_CLOSED, which returns null until that happens,
        // so the dialog stays hidden until this point.
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
        // Stand aside: mu_end promotes whichever root container the mouse was
        // pressed on, so a dialog left open here would sit on top of what it
        // just launched.
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
            logWarn("SDL_OpenURL: %s", SDL_GetError().fromStringz);
        }
    }
    mu_label(ctx, "License");
    mu_label(ctx, LICENSE);
    mu_label(ctx, "Compiler");
    mu_label(ctx, COMPILER);
    mu_label(ctx, "SDL");
    mu_label(ctx, sdlVersion());

    // First cell eats all the width but the button's, pushing it flush right.
    static immutable int[2] closerow = [ -90, -1 ];
    mu_layout_row(ctx, 2, closerow.ptr, 0);
    mu_label(ctx, "");
    if (mu_button(ctx, "Close"))
        mu_get_current_container(ctx).open = 0;

    mu_end_window(ctx);
}

// The application icon's palette. The eight byte-class cells come from
// hex_classify itself, so the mark cannot drift from what the hex panel draws.
private enum mu_Color NUL    = hex_classify(0, 0x00, null);
private enum mu_Color PRINT  = hex_classify(0, 'A',  null);
private enum mu_Color WS     = hex_classify(0, '\n', null);
private enum mu_Color CTRL   = hex_classify(0, 0x01, null);
private enum mu_Color HIGH   = hex_classify(0, 0x80, null);
/// Not a byte class: the bookmark wash is a background tint, too dark to carry a
/// whole cell on its own.
private enum mu_Color ACCENT = mu_Color(230, 170, 60, 255);
/// ui.d's CANVAS is pure black, which would vanish into a dark dialog.
private enum mu_Color PLATE  = mu_Color(18, 18, 22, 255);

private immutable mu_Color[3][3] MARK_CELLS = [
    [HIGH,  PRINT,  CTRL],
    [PRINT, ACCENT, WS],
    [NUL,   NUL,    HIGH],
];

/// Draw the application icon into `box`.
///
/// Redrawn from tools/mkicon.d's geometry rather than loaded from assets/icon,
/// so the dialog looks right whether or not the icon files were ever installed.
/// Rasterising the real thing was measured at 28ms for a 256 - fine to spend
/// once in a build script, not on every launch - and at this size the difference
/// is the antialiasing alone.
private void about_mark(mu_Context* ctx, mu_Rect box)
{
    // mkicon.d's design space: plate inset 2 of 64, side 60, radius 13; cells 12
    // wide and 3 apart from 11, corners at 2.5.
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

/// Fill a rounded rectangle out of ddui's only shape.
///
/// One scanline at a time, except that consecutive rows sharing an inset collapse
/// into a single rect: a radius of r contributes at most r distinct insets per
/// corner, so the whole mark costs about sixty rects rather than one per row.
/// Unantialiased, which at a 2px cell radius is a single-pixel jag.
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

/// Horizontal inset of one scanline, 0 between the corner arcs.
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

/// A label that quietly answers to a click. Drawn exactly as mu_label draws it,
/// with no colour, underline or tab stop: whoever finds it went looking.
/// Returns: true on the frame it is left-clicked.
private bool about_secret(mu_Context* ctx, string text)
{
    mu_Id id = mu_get_id(ctx, text.ptr, text.length);
    mu_Rect r = mu_layout_next(ctx);
    mu_update_control(ctx, id, r, 0);
    mu_draw_control_text(ctx, text, r, MU_COLOR_TEXT, 0);
    return ctx.mouse_pressed == MU_MOUSE_LEFT && ctx.focus == id;
}

/// A clickable URL: link-coloured text, underlined while hovered or focused.
/// Returns: true when activated by a left click or the return key.
private bool about_link(mu_Context* ctx, string url)
{
    mu_Id id = mu_get_id(ctx, url.ptr, url.length);
    mu_Rect r = mu_layout_next(ctx);
    mu_update_control(ctx, id, r, MU_OPT_TABSTOP);

    bool submit = (ctx.mouse_pressed == MU_MOUSE_LEFT && ctx.focus == id) ||
                  (ctx.focus == id && (ctx.key_pressed & MU_KEY_RETURN) != 0);

    bool lit = ctx.hover == id || ctx.focus == id;
    mu_Color color = lit ? LINK_HOVER : LINK_COLOR;

    // Left-aligned and vertically centred in the cell, matching mu_label.
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
