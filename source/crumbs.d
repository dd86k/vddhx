/// Breadcrumbs strip on ddui's drawing primitives.
/// Authors: dd86k <dd@dax.moe>
module crumbs;

import ddui;
import uitext : ui_elide;

/// Component separator. Callers join with it, the strip splits on it.
enum string CRUMB_SEP = " / ";

private:

enum mu_Color CRUMB_DIM  = mu_Color(130, 130, 145, 255); // ancestors
enum mu_Color CRUMB_LAST = mu_Color(190, 190, 205, 255); // innermost
enum string   CRUMB_CUT  = "... ";                       // shown when components are dropped

enum int CRUMB_PAD   = 2; // above and below text
enum int CRUMB_INSET = 4; // both ends

public:

/// Height the strip takes, for a caller measuring a column before laying it out.
int crumb_bar_height(mu_Context* ctx)
{
    return ctx.text_height(ctx.style.font) + CRUMB_PAD * 2;
}

/// Draw a breadcrumb strip in its own layout row, like tab_bar.
///
/// `trail` is outermost first ("PNG / IDAT / length"). The last component is
/// highlighted. If too long, components are dropped from the root end behind
/// an ellipsis. A lone component is truncated and never dropped.
/// An empty strip would mean nothing was parsed.
void crumb_bar(mu_Context* ctx, string trail, mu_Color back)
{
    import std.string : indexOf, lastIndexOf;

    mu_Font font = ctx.style.font;
    int fill = -1;
    mu_layout_row(ctx, 1, &fill, crumb_bar_height(ctx));
    mu_Rect r = mu_layout_next(ctx);

    mu_draw_rect(ctx, r, back);
    if (trail.length == 0)
        return;

    int x = r.x + CRUMB_INSET;
    int y = r.y + CRUMB_PAD;
    int endX = r.x + r.w - CRUMB_INSET;
    int cutW = ctx.text_width(font, CRUMB_CUT.ptr, cast(int) CRUMB_CUT.length);

    // Drop whole components before truncating any.
    size_t from;
    bool cut;
    while (x + (cut ? cutW : 0) +
           ctx.text_width(font, trail.ptr + from, cast(int)(trail.length - from)) > endX)
    {
        ptrdiff_t sep = trail[from .. $].indexOf(CRUMB_SEP);
        if (sep < 0)
            break;
        from += sep + CRUMB_SEP.length;
        cut = true;
    }

    if (cut)
    {
        mu_draw_text(ctx, font, CRUMB_CUT, mu_Vec2(x, y), CRUMB_DIM);
        x += cutW;
    }

    string rest = trail[from .. $];
    ptrdiff_t last = rest.lastIndexOf(CRUMB_SEP);
    if (last >= 0)
    {
        size_t head = last + CRUMB_SEP.length;
        mu_draw_text(ctx, font, rest.ptr, cast(int) head, mu_Vec2(x, y), CRUMB_DIM);
        x += ctx.text_width(font, rest.ptr, cast(int) head);
        rest = rest[head .. $];
    }

    char[128] buf = void;
    string tail = ui_elide(ctx, rest, endX - x, buf);
    if (tail.length)
        mu_draw_text(ctx, font, tail, mu_Vec2(x, y), CRUMB_LAST);
}

unittest
{
    // Returns the drawn text. No draw may cross the strip edges.
    enum int CW = 8;
    static extern (C) int width(mu_Font f, const(char)* s, int len)
    {
        import core.stdc.string : strlen;
        return (len < 0 ? cast(int) strlen(s) : len) * CW;
    }
    static extern (C) int height(mu_Font f) { return 16; }

    static mu_Context ctx;
    mu_init(&ctx);
    ctx.text_width    = &width;
    ctx.text_height   = &height;
    ctx.style.padding = 0;
    ctx.style.spacing = 0;

    // Windows keep their creation rect, so each width needs its own container.
    int seq;
    // Widths in glyphs so insets can change without redoing the cases.
    string drawn(string trail, int glyphs)
    {
        import std.format : sformat;

        int paneW = CRUMB_INSET * 2 + glyphs * CW;
        char[8] name = void;
        sformat(name, "w%d\0", ++seq);

        mu_begin(&ctx);
        if (mu_begin_window_ex(&ctx, name.ptr, mu_Rect(0, 0, paneW, 400),
                MU_OPT_NOTITLE | MU_OPT_NORESIZE | MU_OPT_NOSCROLL | MU_OPT_NOFRAME))
        {
            crumb_bar(&ctx, trail, mu_Color(0, 0, 0, 255));
            mu_end_window(&ctx);
        }
        mu_end(&ctx);

        string text;
        mu_Rect strip;
        mu_Command* cmd;
        while (mu_get_next_command(&ctx, &cmd))
        {
            if (cmd.type == MU_COMMAND_RECT)
                strip = cmd.rect.rect; // background, drawn first
            if (cmd.type != MU_COMMAND_TEXT)
                continue;
            const(char)* s = mu_command_text(&ctx, cmd);
            int w = width(null, s, -1);
            assert(cmd.text.pos.x >= strip.x);
            assert(cmd.text.pos.x + w <= strip.x + strip.w);
            text ~= cast(string) s[0 .. w / CW].idup;
        }
        return text;
    }

    // Fits exactly; drawn in two parts.
    assert(drawn("PNG / IHDR / width", 18) == "PNG / IHDR / width");

    // Drops from the root end first.
    assert(drawn("PNG / IHDR / width", 17) == "... IHDR / width");
    assert(drawn("PNG / IHDR / width", 12) == "... width");

    // Last component left is truncated. Stub font "..." costs 3 chars.
    assert(drawn("signature", 8) == "signa\xe2\x80\xa6");

    // Empty: background only.
    assert(drawn("", 40) == "");
}
