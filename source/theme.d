/// Colours by role, in one place.
///
/// Every colour the grid puts on a byte comes through here, the byte classes included:
/// what the plain uncoloured view does is a mapping like any other rather than a
/// hardcoded scheme sitting beside the layout system. A theme file, when there is one,
/// replaces the tables below and nothing else.
///
/// Roles that cover a lot of bytes at once - data, text, padding - are deliberately the
/// quiet ones, and the vivid colours are spent on the fields that appear once or twice
/// in a record. A colour repeated over half the screen stops being information.
/// Authors: dd86k <dd@dax.moe>
module theme;

import ddui;

import layout;

/// Colour the glyphs of a byte covered by `role`. LayoutRole.none has no colour of its
/// own: it means nothing claimed the byte, which is the caller's cue to classify it.
///
/// `shade` is the alternating bit off the span (see LayoutSpan.shade) and answers the
/// same hue a step off, which is what tells IHDR's three scalars apart. A step rather
/// than a colour of its own: a palette handed out per field runs dry on a format with
/// more fields than colours, and says something where there is nothing to say.
mu_Color theme_role(LayoutRole role, bool shade = false)
{
    mu_Color c = theme_base(role);
    return shade && c.a ? theme_shade(c) : c;
}

/// The same colour a step off in luminance, away from whichever end it sits nearer.
///
/// Dark roles brighten and bright ones darken, so neither twin walks into the panel
/// background or washes out; a fixed direction would sink `zero` and `reserved`, which
/// start close to the background already.
private mu_Color theme_shade(mu_Color c)
{
    enum STEP = 52; // ~20%, the least that reads as a different field at glyph size

    int lum = (c.r * 30 + c.g * 59 + c.b * 11) / 100;
    int d = lum >= 128 ? -STEP : STEP;
    return mu_Color(
        cast(ubyte) clamp8(c.r + d),
        cast(ubyte) clamp8(c.g + d),
        cast(ubyte) clamp8(c.b + d),
        c.a);
}

private int clamp8(int v)
{
    return v < 0 ? 0 : (v > 255 ? 255 : v);
}

private mu_Color theme_base(LayoutRole role)
{
    switch (role) with (LayoutRole) {
    case zero:       return mu_Color(90, 90, 100, 255);    // charcoal
    case printable:  return mu_Color(220, 220, 220, 255);  // off-white
    case whitespace: return mu_Color(120, 170, 200, 255);  // steel blue
    case control:    return mu_Color(200, 130, 90, 255);   // burnt orange (darker)
    case high:       return mu_Color(150, 190, 130, 255);  // sage green

    case magic:      return mu_Color(240, 205, 115, 255);  // gold
    case length:     return mu_Color(120, 195, 235, 255);  // sky blue
    case offset:     return mu_Color(150, 170, 255, 255);  // periwinkle (light purple)
    case count:      return mu_Color(105, 210, 185, 255);  // teal
    case flags:      return mu_Color(215, 150, 230, 255);  // orchid (bright rich purple)
    case scalar:     return mu_Color(205, 215, 230, 255);  // pale blue-grey
    case text:       return mu_Color(185, 225, 160, 255);  // light green
    case timestamp:  return mu_Color(245, 175, 125, 255);  // peach
    case checksum:   return mu_Color(155, 155, 180, 255);  // lavender grey
    case reserved:   return mu_Color(105, 105, 120, 255);  // slate grey
    case data:       return mu_Color(165, 170, 185, 255);  // light slate

    default:         return mu_Color(0, 0, 0, 0);          // transparent
    }
}

/// Colour a structure border is drawn in, `level` levels in from the outermost span.
///
/// Neutral on purpose, and the only thing here that is. Every hue in the table above is
/// spoken for by a role, and the blues by the caret, the selection and the focused
/// pane's edge; a border tinted into either family reads as one of them. Grey is the
/// one thing left that says "chrome" - it is what the offset column is drawn in - so a
/// record's box groups the bytes without claiming to mean anything about them.
mu_Color theme_edge(int level)
{
    return level <= 0 ?
        mu_Color(165, 168, 180, 220) :  // light grey: the record, all that is drawn today
        mu_Color(120, 122, 132, 170);   // mid grey: anything nested inside it, quieter
}

unittest
{
    // Every role but `none` answers with something visible, or a byte would come out
    // invisible against the panel.
    foreach (LayoutRole role; LayoutRole.min .. cast(LayoutRole)(LayoutRole.max + 1))
    {
        mu_Color c = theme_role(role);
        assert((role == LayoutRole.none) == (c.a == 0));
    }

    // The classifier roles keep the colours the grid has always drawn them in: the
    // panel's own hex_classify is what an uncoloured view uses, and a byte no layout
    // covers must not change colour for having been named through here instead.
    import hexview : hex_classify;
    foreach (ubyte value; [0x00, 'A', '\n', 0x01, 0x7f, 0x80, 0xff])
        assert(theme_role(layout_classify(value)) == hex_classify(0, value, null));

    assert(theme_edge(0) != theme_edge(1));

    // The shade is a different colour from the one it alternates with, keeps the alpha,
    // and moves away from whichever end the role sits nearer.
    foreach (LayoutRole role; LayoutRole.min .. cast(LayoutRole)(LayoutRole.max + 1))
    {
        if (role == LayoutRole.none)
            continue;
        mu_Color base = theme_role(role);
        mu_Color alt  = theme_role(role, true);
        assert(base != alt);
        assert(base.a == alt.a);
    }

    assert(theme_role(LayoutRole.printable, true).r < theme_role(LayoutRole.printable).r);
    assert(theme_role(LayoutRole.reserved, true).r > theme_role(LayoutRole.reserved).r);
}
