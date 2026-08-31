/// Text helpers shared by the hand-built widgets.
/// Authors: dd86k <dd@dax.moe>
module uitext;

import ddui;

/// Fit `label` into `maxW` pixels, cutting it back to an ellipsis on a UTF-8
/// boundary when it does not fit.
/// Returns: `label` when it already fits, a slice of `buf` when it had to be cut,
///          null when not even one character plus the ellipsis would fit.
string ui_elide(mu_Context* ctx, string label, int maxW, char[] buf)
{
    enum string ELLIPSIS = "…";

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

    // Stub face: one unit per byte, so a pixel budget reads as a byte count
    // (the ellipsis being three of them).
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
    assert(ui_elide(ctx, "readme.txt", 40, buf) == "readme.txt");
    assert(ui_elide(ctx, "readme.txt", 10, buf) == "readme.txt");
    assert(ui_elide(ctx, "readme.txt", 9, buf) == "readme…"); // 6 + the 3-byte …
    assert(ui_elide(ctx, "readme.txt", 4, buf) == "r…");
    assert(ui_elide(ctx, "readme.txt", 3, buf) is null);
    assert(ui_elide(ctx, "readme.txt", 0, buf) is null);

    // A budget of 5 pays for two label bytes plus the ellipsis, which would split
    // the two-byte "é", so the whole pair goes instead.
    assert(ui_elide(ctx, "aébbbb", 6, buf) == "aé…");
    assert(ui_elide(ctx, "aébbbb", 5, buf) == "a…");
}
