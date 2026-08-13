/// Help > About dialog: who wrote this, where it lives, and what built it.
/// Authors: dd
module about;

import std.format : format;
import std.string : toStringz;
import bindbc.sdl : SDL_OpenURL, SDL_GetVersion,
    SDL_VERSIONNUM_MAJOR, SDL_VERSIONNUM_MINOR, SDL_VERSIONNUM_MICRO;
import ddlogger;
import ddui;

/// Application version. Single source of truth: dub.sdl deliberately carries no
/// version field, since dub derives package versions from git tags.
enum VERSION = "0.1.0";

/// Author line, matching dub.sdl's authors/copyright fields.
enum AUTHOR = "dd <dd@dax.moe>";

/// Project homepage, opened in the desktop browser from the dialog.
enum HOMEPAGE = "https://github.com/dd86k/vddhx";

/// Compiler that built this binary, e.g. "LDC (frontend 2.111)".
///
/// __VENDOR__ names the compiler and __VERSION__ its D frontend version, encoded
/// as major*1000 + minor (2111 is 2.111). Neither reports the compiler's own
/// patch level, nor LDC's 1.x versioning, so the frontend number is what we can
/// honestly show.
enum COMPILER = __VENDOR__ ~ " (frontend " ~ frontendVersion(__VERSION__) ~ ")";

/// Render __VERSION__'s packed form as a dotted version. CTFE-evaluated.
private string frontendVersion(uint v)
{
    return format("%u.%03u", v / 1000, v % 1000);
}

/// The SDL actually in use, e.g. "3.4.12".
///
/// Reported at runtime rather than from bindbc-sdl's compile-time version: the
/// default build opens whichever SDL3 the system has (source/loader.d), and the
/// bindings are deliberately held at their 3.2.0 baseline (see dub.sdl), so the
/// two rarely agree and only the runtime one says what is running.
///
/// Only valid once SDL is loaded, which it is by the time any dialog is drawn.
/// Cached because the number cannot change while the process runs.
private string sdlVersion()
{
    static string cached;
    if (cached is null)
    {
        // SDL packs its version as major*1000000 + minor*1000 + patch.
        int v = SDL_GetVersion();
        cached = format("%d.%d.%d", SDL_VERSIONNUM_MAJOR(v), SDL_VERSIONNUM_MINOR(v),
            SDL_VERSIONNUM_MICRO(v));
    }
    return cached;
}

/// Window title, and the key ddui pools the dialog's container under.
private enum TITLE = "About vddhx";

// Dialog size in pixels; it is centred on the window each time it is opened.
private enum int WIDTH  = 460;
private enum int HEIGHT = 214;

// Link text, idle and hovered/focused.
private enum mu_Color LINK_COLOR = mu_Color(110, 170, 255, 255);
private enum mu_Color LINK_HOVER = mu_Color(160, 205, 255, 255);

/// Set when the menu asks for the dialog, consumed by the next about_frame.
/// Deferred because opening it means placing its container against the current
/// window size, which only the frame call knows.
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

    static immutable int[1] full = [ -1 ];
    mu_layout_row(ctx, 1, full.ptr, 0);
    mu_label(ctx, "vddhx " ~ VERSION);
    mu_label(ctx, "Visual DDHX, a hex editor.");

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
    mu_label(ctx, "Compiler");
    mu_label(ctx, COMPILER);
    mu_label(ctx, "SDL");
    mu_label(ctx, sdlVersion());

    // Close button pushed to the right edge: the first cell eats all the width
    // but the button's own, leaving it flush with the dialog's right side.
    static immutable int[2] closerow = [ -90, -1 ];
    mu_layout_row(ctx, 2, closerow.ptr, 0);
    mu_label(ctx, "");
    if (mu_button(ctx, "Close"))
        mu_get_current_container(ctx).open = 0;

    mu_end_window(ctx);
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
