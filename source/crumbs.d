/// Prototype breadcrumb strip built on ddui's drawing primitives.
///
/// Kept local to vddhx for now, the way the tab strip in tabbar.d is.
/// Authors: dd86k <dd@dax.moe>
module crumbs;

import ddui;
import uitext : ui_elide;

/// What sits between one component and the one inside it. Callers compose their
/// trail with this and the strip reads it back to tell the components apart.
enum string CRUMB_SEP = " / ";

private:

enum mu_Color CRUMB_DIM  = mu_Color(130, 130, 145, 255); // the way in
enum mu_Color CRUMB_LAST = mu_Color(190, 190, 205, 255); // where the caret is
enum string   CRUMB_CUT  = "... ";                       // components dropped

enum int CRUMB_PAD   = 2; // above and below the text
enum int CRUMB_INSET = 4; // either end of the strip

public:

/// Height the strip takes, for a caller measuring a column before laying it out.
int crumb_bar_height(mu_Context* ctx)
{
    return ctx.text_height(ctx.style.font) + CRUMB_PAD * 2;
}

/// Draw a breadcrumb strip across the width it is given, taking a layout row of
/// its own the way tab_bar does.
///
/// `trail` is the whole path, outermost first ("PNG / IDAT / length"), and its
/// innermost component is drawn brighter: that is the one the caller is asking
/// about, the rest being how it was reached.
///
/// Too long for the strip, the trail loses components from the root end and says
/// so with a leading ellipsis - the outermost is both the least specific and the
/// easiest to recover, being what the whole document is. A lone component with no
/// room left is cut short rather than dropped: an empty strip reads as a document
/// nothing was parsed in, which is a different thing to say.
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

    // Whole components go before any one of them is cut short, so what is left is
    // still something the user can read off rather than a truncated root.
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
    // What the strip puts on screen at a given width: the text of every draw in
    // order, and none of it may cross the strip's own edges.
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

    // A window keeps the rect it was created with, so each width needs a container
    // of its own or the second one is drawn at the first one's size.
    int seq;
    // Widths in glyphs of room, so the insets can be retuned without every case
    // below having to be worked out again.
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
                strip = cmd.rect.rect; // the background, drawn before any text
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

    // Room for all 18 of its glyphs: the whole trail, in two draws reading as one.
    assert(drawn("PNG / IHDR / width", 18) == "PNG / IHDR / width");

    // Tightening the strip drops components from the root end, innermost last.
    assert(drawn("PNG / IHDR / width", 17) == "... IHDR / width");
    assert(drawn("PNG / IHDR / width", 12) == "... width");

    // With nothing left to drop the last component is cut short instead. The stub
    // face charges a glyph per byte, so the 3-byte ellipsis costs three of them.
    assert(drawn("signature", 8) == "signa\xe2\x80\xa6");

    // Nothing to say draws the strip and stops, leaving a background and no text.
    assert(drawn("", 40) == "");
}
