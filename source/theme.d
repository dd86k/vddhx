/// Colours by role, including byte classes. A theme file replaces these tables.
///
/// High-coverage roles (data, text, padding) are muted on purpose; vivid
/// colours go to rare fields. Keep it that way.
/// Authors: dd86k <dd@dax.moe>
module theme;

import ddui;

import structure;

/// Glyph colour for `role`. StructureRole.none has no colour: the caller
/// classifies the byte instead.
///
/// `shade` (see StructureSpan.shade) shifts luminance to separate adjacent
/// fields. A shift, not a per-field palette, which would run out of colours.
mu_Color theme_role(StructureRole role, bool shade = false)
{
    mu_Color c = theme_base(role);
    return shade && c.a ? theme_shade(c) : c;
}

/// Shift luminance toward the middle: dark brightens, bright darkens. A fixed
/// direction would sink `zero` and `reserved` into the background.
private mu_Color theme_shade(mu_Color c)
{
    enum STEP = 52; // ~20%, smallest visible difference at glyph size

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

private mu_Color theme_base(StructureRole role)
{
    switch (role) with (StructureRole) {
    case zero:       return mu_Color(90, 90, 100, 255);    // charcoal
    case printable:  return mu_Color(220, 220, 220, 255);  // off-white
    case whitespace: return mu_Color(120, 170, 200, 255);  // steel blue
    case control:    return mu_Color(200, 130, 90, 255);   // burnt orange
    case unmapped:   return mu_Color(150, 190, 130, 255);  // sage green

    case magic:      return mu_Color(240, 205, 115, 255);  // gold
    case length:     return mu_Color(120, 195, 235, 255);  // sky blue
    case offset:     return mu_Color(150, 170, 255, 255);  // periwinkle
    case count:      return mu_Color(105, 210, 185, 255);  // teal
    case flags:      return mu_Color(215, 150, 230, 255);  // orchid
    case scalar:     return mu_Color(205, 215, 230, 255);  // pale blue-grey
    case text:       return mu_Color(185, 225, 160, 255);  // light green
    case timestamp:  return mu_Color(245, 175, 125, 255);  // peach
    case checksum:   return mu_Color(155, 155, 180, 255);  // lavender grey
    case reserved:   return mu_Color(105, 105, 120, 255);  // slate grey
    case data:       return mu_Color(165, 170, 185, 255);  // light slate

    default:         return mu_Color(0, 0, 0, 0);          // transparent
    }
}

/// Border colour for a structure `level` levels deep.
///
/// Grey on purpose: role hues and the selection/caret/focus blues are all
/// taken, and grey reads as chrome (like the offset column).
mu_Color theme_edge(int level)
{
    return level <= 0 ?
        mu_Color(165, 168, 180, 220) :  // light grey: record
        mu_Color(120, 122, 132, 170);   // mid grey: nested
}

unittest
{
    // Every role but `none` must be visible against the panel.
    foreach (StructureRole role; StructureRole.min .. cast(StructureRole)(StructureRole.max + 1))
    {
        mu_Color c = theme_role(role);
        assert((role == StructureRole.none) == (c.a == 0));
    }

    // Classifier roles must match hex_classify's colours (which reads ASCII), so
    // unclaimed bytes look the same either way.
    import hexview : hex_classify;
    import ddhx.charset : ASCII;
    foreach (ubyte value; [0x00, 'A', '\n', 0x01, 0x7f, 0x80, 0xff])
        assert(theme_role(structure_classify(value, &ASCII))
            == hex_classify(0, value, null));

    assert(theme_edge(0) != theme_edge(1));

    // Shade differs, keeps alpha, and moves away from the nearer end.
    foreach (StructureRole role; StructureRole.min .. cast(StructureRole)(StructureRole.max + 1))
    {
        if (role == StructureRole.none)
            continue;
        mu_Color base = theme_role(role);
        mu_Color alt  = theme_role(role, true);
        assert(base != alt);
        assert(base.a == alt.a);
    }

    assert(theme_role(StructureRole.printable, true).r < theme_role(StructureRole.printable).r);
    assert(theme_role(StructureRole.reserved, true).r > theme_role(StructureRole.reserved).r);
}
