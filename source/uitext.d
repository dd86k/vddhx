/// Text helpers shared by the hand-built widgets.
///
/// The tab strip and the omnibar both lay their own text out inside a fixed
/// box, so both need the same "make it fit" primitive. It lives here rather
/// than in either of them, so neither has to reach into the other.
/// Authors: dd
module uitext;

import ddui;

/// Fit `label` into `maxW` pixels, cutting it back to an ellipsis when it does
/// not fit. The cut lands on a UTF-8 boundary, so a multi-byte character is never
/// split down the middle. Returns `label` itself when it already fits, a slice of
/// `buf` when it had to be cut, and null when not even one character and the
/// ellipsis would fit.
string ui_elide(mu_Context* ctx, string label, int maxW, char[] buf)
{
    enum string ELLIPSIS = "…"; // …

    if (label.length == 0)
        return label;

    mu_Font font = ctx.style.font;
    if (ctx.text_width(font, label.ptr, cast(int) label.length) <= maxW)
        return label;

    int ew = ctx.text_width(font, ELLIPSIS.ptr, cast(int) ELLIPSIS.length);
    size_t n = label.length;
    if (n > buf.length - ELLIPSIS.length)
        n = buf.length - ELLIPSIS.length;
    while (n > 0)
    {
        if (ctx.text_width(font, label.ptr, cast(int) n) + ew <= maxW)
            break;
        --n;
        while (n > 0 && (label[n] & 0xc0) == 0x80) // step back onto a lead byte
            --n;
    }
    if (n == 0)
        return null;

    buf[0 .. n] = label[0 .. n];
    buf[n .. n + ELLIPSIS.length] = ELLIPSIS[];
    return cast(string) buf[0 .. n + ELLIPSIS.length];
}

unittest
{
    import core.stdc.stdlib : malloc, free;
    import core.stdc.string : strlen;

    // A stub face: every byte one unit wide, so a pixel budget reads as a byte
    // count. The ellipsis is three bytes of UTF-8, hence three units.
    extern (C) int width(mu_Font font, const(char)* str, int len)
    {
        return len < 0 ? cast(int) strlen(str) : len;
    }
    extern (C) int height(mu_Font font) { return 10; }

    mu_Context* ctx = cast(mu_Context*) malloc(mu_Context.sizeof); // ~4 MB
    assert(ctx);
    scope(exit) free(ctx);
    mu_init(ctx);
    ctx.text_width  = &width;
    ctx.text_height = &height;

    char[32] buf = void;
    assert(ui_elide(ctx, "", 40, buf) == "");
    assert(ui_elide(ctx, "readme.txt", 40, buf) == "readme.txt"); // fits, untouched
    assert(ui_elide(ctx, "readme.txt", 10, buf) == "readme.txt"); // exactly fits
    assert(ui_elide(ctx, "readme.txt", 9, buf) == "readme…");     // 6 + the 3-byte …
    assert(ui_elide(ctx, "readme.txt", 4, buf) == "r…");
    assert(ui_elide(ctx, "readme.txt", 3, buf) is null);          // no room for a character
    assert(ui_elide(ctx, "readme.txt", 0, buf) is null);

    // The cut never lands inside a character: "é" is two bytes, and a budget of
    // 5 pays for exactly two label bytes plus the ellipsis - which would split
    // it - so the whole pair goes instead.
    assert(ui_elide(ctx, "aébbbb", 6, buf) == "aé…");
    assert(ui_elide(ctx, "aébbbb", 5, buf) == "a…");
}
