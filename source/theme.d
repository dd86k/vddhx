/// Colors by role (bytes, structure fields, UI), set by ddhx's `color` schemes.
///
/// High-coverage roles (data, text, padding) are muted on purpose; vivid
/// colors go to rare fields. Keep it that way.
/// Authors: dd86k <dd@dax.moe>
module theme;

import ddui;

import structure;
import crumbs : CrumbColors;
import hexview : HexColors;
import omnibar : OmniColors;
import split : SplitColors;
import tabbar : TabColors;

/// Glyph color for `role`. StructureRole.none has no color: the caller
/// classifies the byte instead.
///
/// `shade` (see StructureSpan.shade) shifts luminance to separate adjacent
/// fields. A shift, not a per-field palette, which would run out of colors.
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
    case zero:       return theme_fg(Scheme.zero);
    case printable:  return theme_fg(Scheme.normal);
    case whitespace: return theme_fg(Scheme.whitespace);
    case control:    return theme_fg(Scheme.control);
    case unmapped:   return theme_fg(Scheme.unmapped);

    case magic:      return theme_fg(Scheme.structure_magic);
    case length:     return theme_fg(Scheme.structure_length);
    case offset:     return theme_fg(Scheme.structure_offset);
    case count:      return theme_fg(Scheme.structure_count);
    case flags:      return theme_fg(Scheme.structure_flags);
    case scalar:     return theme_fg(Scheme.structure_scalar);
    case text:       return theme_fg(Scheme.structure_text);
    case timestamp:  return theme_fg(Scheme.structure_timestamp);
    case checksum:   return theme_fg(Scheme.structure_checksum);
    case reserved:   return theme_fg(Scheme.structure_reserved);
    case data:       return theme_fg(Scheme.structure_data);

    default:         return mu_Color(0, 0, 0, 0);          // transparent
    }
}

/// Border color for a structure `level` levels deep, translucent.
mu_Color theme_edge(int level)
{
    return level <= 0 ?
        theme_alpha(theme_fg(Scheme.structure_edge), 220) :
        theme_alpha(theme_fg(Scheme.structure_edge_nested), 170);
}

/// `c` with alpha `a`.
mu_Color theme_alpha(mu_Color c, ubyte a)
{
    c.a = a;
    return c;
}

/// Color scheme, set by .vddhxrc's `color SCHEME COLOR` like ddhx. ddhx's
/// schemes (its `normal` split into the byte classes), then the rest of the
/// Hex View group, then the UI group (from SCHEME_UI).
enum Scheme
{
    normal,         /// Printable bytes.
    zero,           /// Zero bytes.
    whitespace,     /// Whitespace bytes.
    control,        /// Control bytes.
    unmapped,       /// Bytes the charset has no character for.
    cursor,         /// Caret, hex lane.
    mirror,         /// Caret, text lane.
    selection,      /// Selection wash.
    bookmark,       /// Bookmarked bytes: glyph and wash.
    diff_changed,   /// Byte differs from the peer.
    diff_missing,   /// Byte past the peer's end.
    offset,         /// Offset column.
    header,         /// Lane headers.
    scrollbar,      /// Scrollbar thumb and track, minimap backdrop.
    minimap_view,   /// Minimap view marker: outline and wash.

    structure_magic,        /// Structure field roles, see StructureRole.
    structure_length,       /// Ditto.
    structure_offset,       /// Ditto.
    structure_count,        /// Ditto.
    structure_flags,        /// Ditto.
    structure_scalar,       /// Ditto.
    structure_text,         /// Ditto.
    structure_timestamp,    /// Ditto.
    structure_checksum,     /// Ditto.
    structure_reserved,     /// Ditto.
    structure_data,         /// Ditto.
    structure_edge,         /// Record border.
    structure_edge_nested,  /// Nested field border.

    ui_canvas,          /// Panel background, under the grid.
    ui_window,          /// Text and window body.
    ui_title,           /// Title text and bar, tab strip.
    ui_border,          /// Control border.
    ui_button,          /// Button.
    ui_button_hover,    /// Ditto, hovered.
    ui_button_focus,    /// Ditto, pressed.
    ui_input,           /// Text box, check box.
    ui_input_hover,     /// Ditto, hovered.
    ui_input_focus,     /// Ditto, focused.
    ui_scrollbar,       /// Scrollbar thumb and track.
    ui_text_selection,  /// Selected text in a text box.
    ui_accent,          /// Focus, active tab, drop target, links.
    ui_link_hover,      /// Hovered link.
    ui_tab,             /// Inactive tab label and face.
    ui_tab_hover,       /// Hovered tab.
    ui_tab_close,       /// Hovered close box, progress track.
    ui_splitter,        /// Pane splitter.
    ui_splitter_hover,  /// Ditto, hovered.
    ui_tooltip,         /// Tooltip text and face.
    ui_tooltip_border,  /// Tooltip border.
    ui_status,          /// Status bar text and face.
    ui_status_message,  /// Status bar message.
    ui_breadcrumb,      /// Breadcrumb ancestors.
    ui_breadcrumb_last, /// Innermost breadcrumb.
    ui_list,            /// Omnibar list.
    ui_list_selected,   /// Ditto, selected row.
    ui_list_hover,      /// Ditto, hovered row.
    ui_list_detail,     /// Ditto, detail column.
    ui_hint,            /// Placeholder text, empty notice.
    ui_list_scrollbar,  /// Omnibar scrollbar thumb and track.
}

/// First scheme of the UI group.
enum Scheme SCHEME_UI = Scheme.ui_canvas;

/// Scheme name, label and default colors. A part with alpha 0 isn't drawn,
/// so a color for it is refused.
struct SchemeInfo
{
    string name;    /// rc name, ddhx's where it has the scheme.
    string label;   /// Settings label.
    mu_Color fg;    /// Glyph, outline, or thumb.
    mu_Color bg;    /// Wash, face, or track.
}

/// All schemes, in Scheme order.
immutable SchemeInfo[] SCHEMES = [
    SchemeInfo("normal",       "Printable",    mu_Color(220, 220, 220, 255)),   // off-white
    SchemeInfo("zero",         "Zero",         mu_Color(90, 90, 100, 255)),     // charcoal
    SchemeInfo("whitespace",   "Whitespace",   mu_Color(120, 170, 200, 255)),   // steel blue
    SchemeInfo("control",      "Control",      mu_Color(200, 130, 90, 255)),    // burnt orange
    SchemeInfo("unmapped",     "Unmapped",     mu_Color(150, 190, 130, 255)),   // sage green
    SchemeInfo("cursor",       "Caret",        HexColors.init.caret),
    SchemeInfo("mirror",       "Caret (text)", HexColors.init.mirror),
    SchemeInfo("selection",    "Selection",    mu_Color.init, HexColors.init.selection),
    // Amber wash, which no byte class uses. Dark so white text stays readable
    // (~6.6:1 vs <2:1 for bright amber). The panel brightens it for outlines
    // and the minimap (hex_wash_lift).
    SchemeInfo("bookmark",     "Bookmark",
        mu_Color(255, 255, 255, 255), mu_Color(125, 85, 22, 255)),
    SchemeInfo("diff-changed", "Diff changed", mu_Color(255, 95, 95, 255)),
    // Green so a longer file reads as additions.
    SchemeInfo("diff-missing", "Diff missing", mu_Color(120, 230, 140, 255)),
    SchemeInfo("offset",       "Offset column", HexColors.init.offset),
    SchemeInfo("header",       "Column header", HexColors.init.header),
    SchemeInfo("scrollbar",    "Scrollbar",    HexColors.init.thumb, HexColors.init.track),
    SchemeInfo("minimap-view", "Minimap view", HexColors.init.view, HexColors.init.viewWash),

    SchemeInfo("structure-magic",     "Magic field",     mu_Color(240, 205, 115, 255)), // gold
    SchemeInfo("structure-length",    "Length field",    mu_Color(120, 195, 235, 255)), // sky blue
    SchemeInfo("structure-offset",    "Offset field",    mu_Color(150, 170, 255, 255)), // periwinkle
    SchemeInfo("structure-count",     "Count field",     mu_Color(105, 210, 185, 255)), // teal
    SchemeInfo("structure-flags",     "Flags field",     mu_Color(215, 150, 230, 255)), // orchid
    SchemeInfo("structure-scalar",    "Scalar field",    mu_Color(205, 215, 230, 255)), // pale blue-gray
    SchemeInfo("structure-text",      "Text field",      mu_Color(185, 225, 160, 255)), // light green
    SchemeInfo("structure-timestamp", "Timestamp field", mu_Color(245, 175, 125, 255)), // peach
    SchemeInfo("structure-checksum",  "Checksum field",  mu_Color(155, 155, 180, 255)), // lavender gray
    SchemeInfo("structure-reserved",  "Reserved field",  mu_Color(105, 105, 120, 255)), // slate gray
    SchemeInfo("structure-data",      "Data field",      mu_Color(165, 170, 185, 255)), // light slate
    // Gray: role hues and the selection, caret and focus blues are all taken,
    // and gray reads as chrome (like the offset column).
    SchemeInfo("structure-edge",        "Field border",          mu_Color(165, 168, 180, 255)),
    SchemeInfo("structure-edge-nested", "Field border (nested)", mu_Color(120, 122, 132, 255)),

    // Black: byte colors (dim zeros especially) are tuned for it.
    SchemeInfo("ui-canvas",          "Canvas",          mu_Color.init, mu_Color(0, 0, 0, 255)),
    SchemeInfo("ui-window",          "Window",
        mu_Color(230, 230, 230, 255), mu_Color(50, 50, 50, 255)),
    SchemeInfo("ui-title",           "Title bar",
        mu_Color(240, 240, 240, 255), mu_Color(25, 25, 25, 255)),
    SchemeInfo("ui-border",          "Border",          mu_Color(25, 25, 25, 255)),
    SchemeInfo("ui-button",          "Button",          mu_Color.init, mu_Color(75, 75, 75, 255)),
    SchemeInfo("ui-button-hover",    "Button hover",    mu_Color.init, mu_Color(95, 95, 95, 255)),
    SchemeInfo("ui-button-focus",    "Button pressed",  mu_Color.init, mu_Color(115, 115, 115, 255)),
    SchemeInfo("ui-input",           "Input",           mu_Color.init, mu_Color(30, 30, 30, 255)),
    SchemeInfo("ui-input-hover",     "Input hover",     mu_Color.init, mu_Color(35, 35, 35, 255)),
    SchemeInfo("ui-input-focus",     "Input focus",     mu_Color.init, mu_Color(40, 40, 40, 255)),
    SchemeInfo("ui-scrollbar",       "Scrollbar",
        mu_Color(30, 30, 30, 255), mu_Color(43, 43, 43, 255)),
    SchemeInfo("ui-text-selection",  "Text selection",  mu_Color.init, mu_Color(60, 90, 160, 255)),
    SchemeInfo("ui-accent",          "Accent",          TabColors.init.accent),
    SchemeInfo("ui-link-hover",      "Link hover",      mu_Color(160, 205, 255, 255)),
    SchemeInfo("ui-tab",             "Tab",             TabColors.init.dim, TabColors.init.idle),
    SchemeInfo("ui-tab-hover",       "Tab hover",       mu_Color.init, TabColors.init.hover),
    SchemeInfo("ui-tab-close",       "Tab close",       mu_Color.init, TabColors.init.close),
    SchemeInfo("ui-splitter",        "Splitter",        mu_Color.init, SplitColors.init.idle),
    SchemeInfo("ui-splitter-hover",  "Splitter hover",  mu_Color.init, SplitColors.init.hover),
    SchemeInfo("ui-tooltip",         "Tooltip",
        mu_Color(215, 215, 225, 255), mu_Color(48, 48, 58, 255)),
    SchemeInfo("ui-tooltip-border",  "Tooltip border",  mu_Color(80, 80, 95, 255)),
    SchemeInfo("ui-status",          "Status bar",
        mu_Color(170, 170, 185, 255), mu_Color(30, 30, 40, 255)),
    SchemeInfo("ui-status-message",  "Status message",  mu_Color(200, 200, 150, 255)),
    SchemeInfo("ui-breadcrumb",      "Breadcrumb",      CrumbColors.init.dim),
    SchemeInfo("ui-breadcrumb-last", "Breadcrumb (last)", CrumbColors.init.last),
    SchemeInfo("ui-list",            "List",            mu_Color.init, OmniColors.init.list),
    SchemeInfo("ui-list-selected",   "List selected",   mu_Color.init, OmniColors.init.selected),
    SchemeInfo("ui-list-hover",      "List hover",      mu_Color.init, OmniColors.init.hover),
    SchemeInfo("ui-list-detail",     "List detail",     OmniColors.init.detail),
    SchemeInfo("ui-hint",            "Hint",            OmniColors.init.hint),
    SchemeInfo("ui-list-scrollbar",  "List scrollbar",  OmniColors.init.thumb, OmniColors.init.track),
];
static assert(SCHEMES.length == Scheme.max + 1);

/// Glyph or outline color of `s`.
mu_Color theme_fg(Scheme s)
{
    return colors[s][0];
}

/// Wash color of `s`, alpha 0 if it has none.
mu_Color theme_bg(Scheme s)
{
    return colors[s][1];
}

/// Hex view colors other than the bytes'.
HexColors theme_hex()
{
    HexColors c;
    c.selection = theme_bg(Scheme.selection);
    c.caret     = theme_fg(Scheme.cursor);
    c.mirror    = theme_fg(Scheme.mirror);
    c.offset    = theme_fg(Scheme.offset);
    c.header    = theme_fg(Scheme.header);
    c.thumb     = theme_fg(Scheme.scrollbar);
    c.track     = theme_bg(Scheme.scrollbar);
    c.view      = theme_fg(Scheme.minimap_view);
    c.viewWash  = theme_bg(Scheme.minimap_view);
    return c;
}

/// Tab strip colors.
TabColors theme_tabs()
{
    TabColors c;
    c.idle   = theme_bg(Scheme.ui_tab);
    c.hover  = theme_bg(Scheme.ui_tab_hover);
    c.accent = theme_fg(Scheme.ui_accent);
    c.dim    = theme_fg(Scheme.ui_tab);
    c.close  = theme_bg(Scheme.ui_tab_close);
    return c;
}

/// Splitter colors.
SplitColors theme_split()
{
    SplitColors c;
    c.idle  = theme_bg(Scheme.ui_splitter);
    c.hover = theme_bg(Scheme.ui_splitter_hover);
    c.held  = theme_fg(Scheme.ui_accent);
    return c;
}

/// Breadcrumb colors.
CrumbColors theme_crumbs()
{
    CrumbColors c;
    c.dim  = theme_fg(Scheme.ui_breadcrumb);
    c.last = theme_fg(Scheme.ui_breadcrumb_last);
    return c;
}

/// Omnibar colors.
OmniColors theme_omni()
{
    OmniColors c;
    c.list     = theme_bg(Scheme.ui_list);
    c.selected = theme_bg(Scheme.ui_list_selected);
    c.hover    = theme_bg(Scheme.ui_list_hover);
    c.accent   = theme_fg(Scheme.ui_accent);
    c.detail   = theme_fg(Scheme.ui_list_detail);
    c.hint     = theme_fg(Scheme.ui_hint);
    c.thumb    = theme_fg(Scheme.ui_list_scrollbar);
    c.track    = theme_bg(Scheme.ui_list_scrollbar);
    return c;
}

/// Fill ddui's style colors.
void theme_style(ref mu_Color[MU_COLOR_MAX] c)
{
    c[MU_COLOR_TEXT]        = theme_fg(Scheme.ui_window);
    c[MU_COLOR_BORDER]      = theme_fg(Scheme.ui_border);
    c[MU_COLOR_WINDOWBG]    = theme_bg(Scheme.ui_window);
    c[MU_COLOR_TITLEBG]     = theme_bg(Scheme.ui_title);
    c[MU_COLOR_TITLETEXT]   = theme_fg(Scheme.ui_title);
    c[MU_COLOR_PANELBG]     = theme_bg(Scheme.ui_canvas);
    c[MU_COLOR_BUTTON]      = theme_bg(Scheme.ui_button);
    c[MU_COLOR_BUTTONHOVER] = theme_bg(Scheme.ui_button_hover);
    c[MU_COLOR_BUTTONFOCUS] = theme_bg(Scheme.ui_button_focus);
    c[MU_COLOR_BASE]        = theme_bg(Scheme.ui_input);
    c[MU_COLOR_BASEHOVER]   = theme_bg(Scheme.ui_input_hover);
    c[MU_COLOR_BASEFOCUS]   = theme_bg(Scheme.ui_input_focus);
    c[MU_COLOR_SCROLLBASE]  = theme_bg(Scheme.ui_scrollbar);
    c[MU_COLOR_SCROLLTHUMB] = theme_fg(Scheme.ui_scrollbar);
    c[MU_COLOR_SELECTION]   = theme_bg(Scheme.ui_text_selection);
}

/// Apply rc line `color SCHEME COLOR` if `apply`, else only check it.
/// Returns: False for an unknown scheme or a bad color.
bool theme_color(string scheme, string spec, bool apply)
{
    ptrdiff_t i = theme_index(scheme);
    if (i < 0)
        return false;
    mu_Color[2] c;
    if (theme_parse(cast(Scheme) i, spec, c) == false)
        return false;
    if (apply)
        colors[i] = c;
    return true;
}

/// Set `s` from Settings, `spec` in rc syntax. False if `spec` is bad.
bool theme_set(Scheme s, string spec)
{
    mu_Color[2] c;
    if (theme_parse(s, spec, c) == false)
        return false;
    colors[s] = c;
    theme_edit();
    return true;
}

/// Colors of `s` in rc syntax, default parts included.
string theme_spec(Scheme s)
{
    return theme_text(s, true);
}

/// Give `s` its default colors.
void theme_reset(Scheme s)
{
    colors[s] = [ SCHEMES[s].fg, SCHEMES[s].bg ];
    theme_edit();
}

/// Reset every scheme.
void theme_reset_all()
{
    theme_defaults();
    theme_edit();
}

/// Load the default colors, dropping all others.
void theme_defaults()
{
    colors = theme_initial();
}

/// Whether colors were edited (Settings) since loading, so the rc's color
/// lines need rewriting.
bool theme_edited()
{
    return edited;
}

/// Whether colors were edited since the last call. For Settings to save.
bool theme_changed()
{
    bool was = changed;
    changed = false;
    return was;
}

/// rc lines for the schemes that differ from the defaults, in Scheme order.
string[] theme_lines()
{
    string[] lines;
    foreach (size_t i, ref immutable SchemeInfo info; SCHEMES)
    {
        string text = theme_text(cast(Scheme) i, false);
        if (text.length)
            lines ~= "color " ~ info.name ~ " " ~ text;
    }
    return lines;
}

private:

/// Named color, ddhx's terminal names.
struct NamedColor
{
    string name;    /// ddhx name.
    mu_Color color; /// RGB for it.
}

/// ddhx's 16 color names. RGB from VS Code's dark terminal palette.
immutable NamedColor[] PALETTE = [
    NamedColor("black",         mu_Color(  0,   0,   0, 255)),
    NamedColor("red",           mu_Color(205,  49,  49, 255)),
    NamedColor("green",         mu_Color( 13, 188, 121, 255)),
    NamedColor("yellow",        mu_Color(229, 229,  16, 255)),
    NamedColor("blue",          mu_Color( 36, 114, 200, 255)),
    NamedColor("purple",        mu_Color(188,  63, 188, 255)),
    NamedColor("aqua",          mu_Color( 17, 168, 205, 255)),
    NamedColor("lightgray",     mu_Color(204, 204, 204, 255)),
    NamedColor("gray",          mu_Color(118, 118, 118, 255)),
    NamedColor("brightred",     mu_Color(241,  76,  76, 255)),
    NamedColor("brightgreen",   mu_Color( 35, 209, 139, 255)),
    NamedColor("brightyellow",  mu_Color(245, 245,  67, 255)),
    NamedColor("brightblue",    mu_Color( 59, 142, 234, 255)),
    NamedColor("brightpurple",  mu_Color(214, 112, 214, 255)),
    NamedColor("brightaqua",    mu_Color( 41, 184, 219, 255)),
    NamedColor("white",         mu_Color(255, 255, 255, 255)),
];

/// Current colors by scheme: glyph or outline, then wash.
__gshared mu_Color[2][SCHEMES.length] colors = theme_initial();

/// Edited in Settings: since loading, and since the last theme_changed.
__gshared bool edited, changed;

/// Default colors of every scheme.
mu_Color[2][SCHEMES.length] theme_initial()
{
    mu_Color[2][SCHEMES.length] c;
    foreach (size_t i, ref immutable SchemeInfo info; SCHEMES)
        c[i] = [ info.fg, info.bg ];
    return c;
}

/// Mark an edit from Settings.
void theme_edit()
{
    edited = true;
    changed = true;
}

/// Index of scheme `name`, or -1.
ptrdiff_t theme_index(string name)
{
    foreach (size_t i, ref immutable SchemeInfo info; SCHEMES)
        if (info.name == name)
            return i;
    return -1;
}

/// Parse ddhx's FG:BG into `c` for scheme `s`. Either side may be empty or
/// `default`. False on a bad color, or one for a part `s` doesn't draw.
bool theme_parse(Scheme s, string spec, out mu_Color[2] c)
{
    import std.string : indexOf;

    if (spec.length == 0)
        return false;
    ptrdiff_t i = indexOf(spec, ':');
    string fg = i >= 0 ? spec[0 .. i] : spec;
    string bg = i >= 0 ? spec[i + 1 .. $] : null;
    return theme_part(fg, SCHEMES[s].fg, c[0]) && theme_part(bg, SCHEMES[s].bg, c[1]);
}

/// One side of FG:BG into `c`, `def` when empty. False if bad or not drawn.
bool theme_part(string text, mu_Color def, out mu_Color c)
{
    c = def;
    if (text.length == 0 || text == "default")
        return true;
    if (def.a == 0)
        return false;
    return theme_value(text, c);
}

/// Color name or `#rrggbb` into `c`. False if neither.
bool theme_value(string text, out mu_Color c)
{
    import std.ascii : isHexDigit;
    import std.conv : to;

    foreach (ref immutable NamedColor n; PALETTE)
    {
        if (n.name == text)
        {
            c = n.color;
            return true;
        }
    }

    if (text.length != 7 || text[0] != '#')
        return false;
    foreach (char ch; text[1 .. $])
        if (isHexDigit(ch) == false)
            return false;
    c = mu_Color(
        to!ubyte(text[1 .. 3], 16),
        to!ubyte(text[3 .. 5], 16),
        to!ubyte(text[5 .. 7], 16),
        255);
    return true;
}

/// Palette name of `c`, else `#rrggbb`.
string theme_name(mu_Color c)
{
    import std.format : format;

    foreach (ref immutable NamedColor n; PALETTE)
        if (n.color == c)
            return n.name;
    return format("#%02x%02x%02x", c.r, c.g, c.b);
}

/// Colors of `s` as FG:BG, leaving out default parts unless `all`. Parts `s`
/// doesn't draw are always left out.
string theme_text(Scheme s, bool all)
{
    string fg = theme_side(colors[s][0], SCHEMES[s].fg, all);
    string bg = theme_side(colors[s][1], SCHEMES[s].bg, all);
    return bg.length ? fg ~ ":" ~ bg : fg;
}

/// One side for theme_text.
string theme_side(mu_Color c, mu_Color def, bool all)
{
    if (def.a == 0 || (all == false && c == def))
        return null;
    return theme_name(c);
}

unittest
{
    scope (exit) theme_defaults();

    assert(theme_color("zero", "red", true));
    assert(theme_fg(Scheme.zero) == mu_Color(205, 49, 49, 255));
    assert(theme_color("bookmark", ":#102030", true));
    assert(theme_fg(Scheme.bookmark) == SCHEMES[Scheme.bookmark].fg);
    assert(theme_bg(Scheme.bookmark) == mu_Color(0x10, 0x20, 0x30, 255));
    assert(theme_color("diff-changed", "#FFaa00:", true));
    assert(theme_fg(Scheme.diff_changed) == mu_Color(255, 170, 0, 255));

    // Parts a scheme doesn't draw, bad colors and schemes.
    assert(theme_color("zero", "red:blue", false) == false);
    assert(theme_color("selection", "blue", false) == false);
    assert(theme_color("selection", ":blue", false));
    assert(theme_color("cursor", "invert", false) == false);
    assert(theme_color("zero", "#12345", false) == false);
    assert(theme_color("zero", "#12345g", false) == false);
    assert(theme_color("zero", "", false) == false);
    assert(theme_color("nope", "red", false) == false);

    // Only changed parts are written.
    assert(theme_lines() == [
        "color zero red",
        "color bookmark :#102030",
        "color diff-changed #ffaa00",
    ]);
    assert(theme_spec(Scheme.bookmark) == "white:#102030");
    assert(theme_spec(Scheme.selection) == ":#30548c");

    assert(theme_color("zero", "default", true));
    assert(theme_fg(Scheme.zero) == SCHEMES[Scheme.zero].fg);

    // UI schemes reach the widgets.
    assert(theme_color("ui-accent", "red", true));
    assert(theme_tabs().accent == mu_Color(205, 49, 49, 255));
    assert(theme_split().held == mu_Color(205, 49, 49, 255));
    assert(theme_color("ui-button", "red", false) == false);
}


unittest
{
    // Every role but `none` must be visible against the panel.
    foreach (StructureRole role; StructureRole.min .. cast(StructureRole)(StructureRole.max + 1))
    {
        mu_Color c = theme_role(role);
        assert((role == StructureRole.none) == (c.a == 0));
    }

    // Classifier roles must match hex_classify's colors (which reads ASCII), so
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
