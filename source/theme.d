/// Colors by role (bytes, structure fields, UI), set by ddhx's `color` schemes.
///
/// High-coverage roles (data, text, padding) are muted on purpose; vivid
/// colors go to rare fields. Keep it that way.
/// Authors: dd86k <dd@dax.moe>
module theme;

import std.algorithm.sorting : sort;
import std.array : array, split, join;
import std.ascii : isAlphaNum, isHexDigit;
import std.conv : to;
import std.file : readText, exists, SpanMode, dirEntries, isDir, mkdirRecurse,
    rename, write;
import std.format : format;
import std.path : baseName, stripExtension, buildPath, dirName;
import std.string : lineSplitter, strip, indexOf;

import crumbs : CrumbColors;
import ddlogger;
import ddui;
import hexview : HexColors;
import omnibar : OmniColors;
import os.path : getUserConfigFolder;
import split : SplitColors;
import structure;
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

/// Scheme name, label and dark theme colors. A side with alpha 0 isn't drawn,
/// in any theme, so a color for it is refused.
struct SchemeInfo
{
    string name;    /// rc name, ddhx's where it has the scheme.
    string label;   /// Settings label.
    mu_Color fg;    /// Glyph, outline, or thumb.
    mu_Color bg;    /// Wash, face, or track.
}

/// All schemes, in Scheme order. Their colors are the dark theme.
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
    // and the minimap (hex_wash_edge).
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

/// Glyph, outline or thumb color of `s`: its override, else the theme's.
mu_Color theme_fg(Scheme s)
{
    return custom[s][0].a ? custom[s][0] : base[s][0];
}

/// Wash, face or track color of `s`, alpha 0 if it has none.
mu_Color theme_bg(Scheme s)
{
    return custom[s][1].a ? custom[s][1] : base[s][1];
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
    c.canvas    = theme_bg(Scheme.ui_canvas);
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

/// Apply rc line `color SCHEME COLOR` as an override if `apply`, else only
/// check it. Returns: False for an unknown scheme or a bad color.
bool theme_color(string scheme, string spec, bool apply)
{
    ptrdiff_t i = theme_index(scheme);
    if (i < 0)
        return false;
    mu_Color[2] c;
    if (theme_parse(cast(Scheme) i, spec, c) == false)
        return false;
    if (apply)
    {
        custom[i] = c;
        ++stamp;
    }
    return true;
}

/// Whether a color line overrides `s`, so theme edits don't show.
bool theme_overridden(Scheme s)
{
    return custom[s][0].a || custom[s][1].a;
}

/// Set `s` in the theme being edited, `spec` in rc syntax. An empty side
/// takes the base theme's. False if `spec` is bad or the theme is built-in.
bool theme_set(Scheme s, string spec)
{
    mu_Color[2] c;
    if (editable == false || theme_parse(s, spec, c) == false)
        return false;
    foreach (size_t side; 0 .. 2)
        base[s][side] = c[side].a ? c[side] : THEMES[parent].colors[s][side];
    changed = true;
    ++stamp;
    return true;
}

/// Colors of `s` as drawn, in rc syntax with both sides.
string theme_spec(Scheme s)
{
    string fg = SCHEMES[s].fg.a ? theme_name(theme_fg(s)) : null;
    string bg = SCHEMES[s].bg.a ? theme_name(theme_bg(s)) : null;
    return bg.length ? fg ~ ":" ~ bg : fg;
}

/// Give `s` the base theme's colors, in the theme being edited.
void theme_reset(Scheme s)
{
    if (editable == false)
        return;
    base[s] = THEMES[parent].colors[s];
    changed = true;
    ++stamp;
}

/// Give every scheme the base theme's colors, in the theme being edited.
void theme_reset_all()
{
    if (editable == false)
        return;
    base = THEMES[parent].colors;
    changed = true;
    ++stamp;
}

/// Back to the default theme without overrides, nothing edited.
void theme_defaults()
{
    theme_builtin(0);
    custom = custom.init;
    changed = false;
    ++stamp;
}

/// Switch to theme `name`, built-in or a user file, keeping overrides. A bad
/// file line is logged and skipped. False if there is no such theme.
bool theme_use(string name)
{
    ptrdiff_t i = theme_find(name);
    if (i >= 0)
    {
        theme_builtin(i);
        return true;
    }

    string path = theme_path(name);
    if (path is null)
        return false;
    string text;
    try
        text = readText(path);
    catch (Exception)
        return false;

    fileLines = text.lineSplitter.array;
    theme_read(fileLines, path, base, parent);
    active = name;
    editable = true;
    changed = false;
    ++stamp;
    return true;
}

/// Whether theme `name` exists, built-in or as a user file.
bool theme_exists(string name)
{
    if (theme_find(name) >= 0)
        return true;
    string path = theme_path(name);
    return path !is null && exists(path);
}

/// Name of the theme in use.
string theme_current()
{
    return active;
}

/// Name of the built-in theme the one in use starts from.
string theme_parent()
{
    return THEMES[parent].name;
}

/// Whether the theme in use is a user file, which Settings may edit.
bool theme_editable()
{
    return editable;
}

/// File of the theme in use, null for a built-in one.
string theme_file()
{
    return editable ? theme_path(active) : null;
}

/// Changes whenever any color does.
uint theme_stamp()
{
    return stamp;
}

/// Whether the edited theme changed since the last call. For Settings to save.
bool theme_changed()
{
    bool was = changed;
    changed = false;
    return was;
}

/// Write the edited theme to its file, in place: comments and bad lines stay.
/// Errors are logged. Returns: False if not written.
bool theme_save()
{
    string path = theme_file();
    if (path is null)
        return false;
    fileLines = theme_merge(fileLines, theme_lines());
    return theme_write(path, fileLines);
}

/// Save the theme in use as user theme `name` and switch to it. Overrides
/// stay out of the copy. Returns: Null, or why it failed.
string theme_copy(string name)
{
    if (theme_name_ok(name) == false)
        return "Use letters, digits, - and _ only.";
    if (theme_exists(name))
        return "A theme by that name exists.";
    string path = theme_path(name);
    if (path is null)
        return "No config folder found.";

    string[] text = editable ? theme_merge(fileLines, theme_lines()) : theme_merge(null, null);
    if (theme_write(path, text) == false)
        return "Could not write the file.";
    fileLines = text;
    active = name;
    editable = true;
    theme_scan();
    return null;
}

/// Built-in theme names, then user themes found by the last theme_scan.
const(string)[] theme_list()
{
    if (scanned == false)
        theme_scan();
    return listed;
}

/// Look for user theme files again.
void theme_scan()
{
    scanned = true;
    string[] users;
    string dir = theme_dir();
    try
    {
        if (dir !is null && exists(dir) && isDir(dir))
        {
            foreach (string path; dirEntries(dir, "*" ~ THEME_EXT, SpanMode.shallow))
            {
                string name = stripExtension(baseName(path));
                if (theme_name_ok(name) && theme_find(name) < 0)
                    users ~= name;
            }
        }
    }
    catch (Exception e)
        logWarn("%s: %s", dir, e.msg);
    sort(users);
    listed = theme_names() ~ users;
}

/// Built-in theme: name and the colors of every scheme.
struct ThemeInfo
{
    string name;    /// rc name.
    /// Foreground then background, by scheme. Alpha 0 where SCHEMES has it.
    mu_Color[2][SCHEMES.length] colors;
}

/// Built-in themes. The first is the default.
immutable ThemeInfo[] THEMES = [
    ThemeInfo("dark", theme_initial()),
    ThemeInfo("light", theme_table(LIGHT)),
];

private:

/// User theme file extension.
enum string THEME_EXT = ".theme";

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

/// One scheme's colors in a built-in theme table.
struct ThemeEntry
{
    Scheme scheme;  /// Scheme set.
    mu_Color fg;    /// Foreground, unset if SCHEMES has none.
    mu_Color bg;    /// Background, ditto.
}

/// Opaque color.
mu_Color rgb(ubyte r, ubyte g, ubyte b)
{
    return mu_Color(r, g, b, 255);
}

/// Light theme. Every scheme is set: dark colors would vanish on white.
immutable ThemeEntry[] LIGHT = [
    ThemeEntry(Scheme.normal,       rgb( 40,  40,  40)),
    ThemeEntry(Scheme.zero,         rgb(175, 175, 185)),
    ThemeEntry(Scheme.whitespace,   rgb( 30, 110, 160)),
    ThemeEntry(Scheme.control,      rgb(175,  85,  30)),
    ThemeEntry(Scheme.unmapped,     rgb( 60, 130,  50)),
    ThemeEntry(Scheme.cursor,       rgb( 30, 100, 210)),
    ThemeEntry(Scheme.mirror,       rgb( 30, 100, 210)),
    ThemeEntry(Scheme.selection,    mu_Color.init, rgb(180, 210, 250)),
    ThemeEntry(Scheme.bookmark,     rgb( 40,  30,   0), rgb(250, 220, 150)),
    ThemeEntry(Scheme.diff_changed, rgb(205,  30,  30)),
    ThemeEntry(Scheme.diff_missing, rgb( 20, 140,  50)),
    ThemeEntry(Scheme.offset,       rgb(120, 120, 130)),
    ThemeEntry(Scheme.header,       rgb(130, 130, 140)),
    ThemeEntry(Scheme.scrollbar,    rgb(160, 170, 190), rgb(235, 235, 240)),
    ThemeEntry(Scheme.minimap_view, rgb( 60, 100, 170), rgb(120, 150, 210)),

    ThemeEntry(Scheme.structure_magic,      rgb(170, 120,   0)),
    ThemeEntry(Scheme.structure_length,     rgb( 20, 120, 170)),
    ThemeEntry(Scheme.structure_offset,     rgb( 60,  80, 200)),
    ThemeEntry(Scheme.structure_count,      rgb(  0, 130, 110)),
    ThemeEntry(Scheme.structure_flags,      rgb(150,  60, 170)),
    ThemeEntry(Scheme.structure_scalar,     rgb( 70,  80, 100)),
    ThemeEntry(Scheme.structure_text,       rgb( 60, 130,  40)),
    ThemeEntry(Scheme.structure_timestamp,  rgb(190,  90,  30)),
    ThemeEntry(Scheme.structure_checksum,   rgb(100, 100, 130)),
    ThemeEntry(Scheme.structure_reserved,   rgb(150, 150, 160)),
    ThemeEntry(Scheme.structure_data,       rgb( 90,  95, 110)),
    ThemeEntry(Scheme.structure_edge,        rgb(100, 104, 116)),
    ThemeEntry(Scheme.structure_edge_nested, rgb(150, 152, 162)),

    ThemeEntry(Scheme.ui_canvas,          mu_Color.init, rgb(255, 255, 255)),
    ThemeEntry(Scheme.ui_window,          rgb( 30,  30,  30), rgb(243, 243, 243)),
    ThemeEntry(Scheme.ui_title,           rgb( 30,  30,  30), rgb(221, 221, 221)),
    ThemeEntry(Scheme.ui_border,          rgb(200, 200, 200)),
    ThemeEntry(Scheme.ui_button,          mu_Color.init, rgb(225, 225, 225)),
    ThemeEntry(Scheme.ui_button_hover,    mu_Color.init, rgb(210, 210, 210)),
    ThemeEntry(Scheme.ui_button_focus,    mu_Color.init, rgb(195, 195, 195)),
    ThemeEntry(Scheme.ui_input,           mu_Color.init, rgb(240, 240, 240)),
    ThemeEntry(Scheme.ui_input_hover,     mu_Color.init, rgb(233, 233, 233)),
    ThemeEntry(Scheme.ui_input_focus,     mu_Color.init, rgb(226, 226, 226)),
    ThemeEntry(Scheme.ui_scrollbar,       rgb(190, 190, 190), rgb(235, 235, 235)),
    ThemeEntry(Scheme.ui_text_selection,  mu_Color.init, rgb(173, 214, 255)),
    ThemeEntry(Scheme.ui_accent,          rgb(  0, 110, 210)),
    ThemeEntry(Scheme.ui_link_hover,      rgb(  0,  80, 160)),
    ThemeEntry(Scheme.ui_tab,             rgb( 90,  90, 100), rgb(228, 228, 232)),
    ThemeEntry(Scheme.ui_tab_hover,       mu_Color.init, rgb(240, 240, 244)),
    ThemeEntry(Scheme.ui_tab_close,       mu_Color.init, rgb(200, 200, 208)),
    ThemeEntry(Scheme.ui_splitter,        mu_Color.init, rgb(215, 215, 222)),
    ThemeEntry(Scheme.ui_splitter_hover,  mu_Color.init, rgb(180, 180, 192)),
    ThemeEntry(Scheme.ui_tooltip,         rgb( 30,  30,  30), rgb(250, 250, 250)),
    ThemeEntry(Scheme.ui_tooltip_border,  rgb(180, 180, 190)),
    ThemeEntry(Scheme.ui_status,          rgb( 70,  70,  80), rgb(230, 230, 236)),
    ThemeEntry(Scheme.ui_status_message,  rgb(120,  90,   0)),
    ThemeEntry(Scheme.ui_breadcrumb,      rgb(120, 120, 130)),
    ThemeEntry(Scheme.ui_breadcrumb_last, rgb( 40,  40,  50)),
    ThemeEntry(Scheme.ui_list,            mu_Color.init, rgb(250, 250, 252)),
    ThemeEntry(Scheme.ui_list_selected,   mu_Color.init, rgb(205, 225, 250)),
    ThemeEntry(Scheme.ui_list_hover,      mu_Color.init, rgb(232, 232, 238)),
    ThemeEntry(Scheme.ui_list_detail,     rgb(110, 110, 120)),
    ThemeEntry(Scheme.ui_hint,            rgb(140, 140, 150)),
    ThemeEntry(Scheme.ui_list_scrollbar,  rgb(170, 180, 200), rgb(230, 230, 236)),
];

/// Theme colors by scheme: foreground, then background.
__gshared mu_Color[2][SCHEMES.length] base = theme_initial();
/// Overrides from color lines, alpha 0 where unset.
__gshared mu_Color[2][SCHEMES.length] custom;
/// Name of the theme in use.
__gshared string active = "dark";
/// Built-in theme the one in use starts from, in THEMES.
__gshared size_t parent;
/// The theme in use is a user file.
__gshared bool editable;
/// Lines of that file, kept so saving preserves comments.
__gshared string[] fileLines;
/// Edited in Settings since the last theme_changed.
__gshared bool changed;
/// Theme names for Settings, see theme_list.
__gshared string[] listed;
/// User themes were looked for.
__gshared bool scanned;
/// Bumped on every color change, see theme_stamp.
__gshared uint stamp;

/// Dark theme colors of every scheme, from SCHEMES.
mu_Color[2][SCHEMES.length] theme_initial()
{
    mu_Color[2][SCHEMES.length] c;
    foreach (size_t i, ref immutable SchemeInfo info; SCHEMES)
        c[i] = [ info.fg, info.bg ];
    return c;
}

/// Colors from a full table of `entries`. Every scheme must be there once,
/// with the sides SCHEMES draws.
mu_Color[2][SCHEMES.length] theme_table(immutable(ThemeEntry)[] entries)
{
    mu_Color[2][SCHEMES.length] c;
    bool[SCHEMES.length] seen;
    foreach (ref immutable ThemeEntry e; entries)
    {
        assert(seen[e.scheme] == false, SCHEMES[e.scheme].name ~ " twice");
        assert((e.fg.a != 0) == (SCHEMES[e.scheme].fg.a != 0), SCHEMES[e.scheme].name ~ " fg");
        assert((e.bg.a != 0) == (SCHEMES[e.scheme].bg.a != 0), SCHEMES[e.scheme].name ~ " bg");
        seen[e.scheme] = true;
        c[e.scheme] = [ e.fg, e.bg ];
    }
    foreach (size_t i, bool b; seen)
        assert(b, SCHEMES[i].name ~ " missing");
    return c;
}

/// Built-in theme names.
string[] theme_names()
{
    string[] names;
    foreach (ref immutable ThemeInfo t; THEMES)
        names ~= t.name;
    return names;
}

/// Use built-in theme `i`.
void theme_builtin(size_t i)
{
    base = THEMES[i].colors;
    parent = i;
    active = THEMES[i].name;
    editable = false;
    fileLines = null;
    ++stamp;
}

/// Index of built-in theme `name` in THEMES, or -1.
ptrdiff_t theme_find(string name)
{
    foreach (size_t i, ref immutable ThemeInfo t; THEMES)
        if (t.name == name)
            return i;
    return -1;
}

/// User theme folder, or null.
string theme_dir()
{
    string dir = getUserConfigFolder();
    return dir ? buildPath(dir, "vddhx", "themes") : null;
}

/// File of user theme `name`, or null if the name or folder is bad.
string theme_path(string name)
{
    string dir = theme_dir();
    if (dir is null || theme_name_ok(name) == false)
        return null;
    return buildPath(dir, name ~ THEME_EXT);
}

/// Whether `name` is fit for a file name: letters, digits, - and _.
bool theme_name_ok(string name)
{
    if (name.length == 0 || name.length > 64)
        return false;
    foreach (char c; name)
        if (isAlphaNum(c) == false && c != '-' && c != '_')
            return false;
    return true;
}

/// Words of a theme file line, null for blank lines and comments.
string[] theme_words(string line)
{
    string text = strip(line);
    return text.length && text[0] != '#' ? split(text) : null;
}

/// Theme file `text` into `colors`, over its `base` theme (default the first),
/// setting `from` to it. Bad lines are logged.
void theme_read(const(string)[] text, string path,
    ref mu_Color[2][SCHEMES.length] colors, ref size_t from)
{
    from = 0;
    foreach (string line; text)
    {
        string[] w = theme_words(line);
        if (w.length == 2 && w[0] == "base" && theme_find(w[1]) >= 0)
            from = theme_find(w[1]);
    }

    colors = THEMES[from].colors;
    foreach (size_t i, string line; text)
    {
        string[] w = theme_words(line);
        if (w.length == 0)
            continue;
        if (w.length == 2 && w[0] == "base" && theme_find(w[1]) >= 0)
            continue;
        mu_Color[2] c;
        ptrdiff_t s = w.length == 3 && w[0] == "color" ? theme_index(w[1]) : -1;
        if (s < 0 || theme_parse(cast(Scheme) s, w[2], c) == false)
        {
            logWarn("%s:%u: ignored: %s", path, i + 1, line);
            continue;
        }
        foreach (size_t side; 0 .. 2)
            if (c[side].a)
                colors[s][side] = c[side];
    }
}

/// Theme file color lines for the sides that differ from the base theme.
string[] theme_lines()
{
    string[] lines;
    foreach (size_t i, ref immutable SchemeInfo info; SCHEMES)
    {
        string fg = theme_diff(cast(Scheme) i, 0);
        string bg = theme_diff(cast(Scheme) i, 1);
        if (fg.length || bg.length)
            lines ~= "color " ~ info.name ~ " " ~ (bg.length ? fg ~ ":" ~ bg : fg);
    }
    return lines;
}

/// Side of `s` for theme_lines, null if it matches the base theme.
string theme_diff(Scheme s, size_t side)
{
    mu_Color c = base[s][side];
    return c == THEMES[parent].colors[s][side] ? null : theme_name(c);
}

/// `text` with its `base` and valid color lines swapped for the current ones,
/// where the first of them was (else at the end).
string[] theme_merge(const(string)[] text, string[] colors)
{
    string[] res;
    bool placed;
    foreach (string line; text)
    {
        string[] w = theme_words(line);
        mu_Color[2] c;
        bool owned = (w.length == 2 && w[0] == "base") ||
            (w.length == 3 && w[0] == "color" && theme_index(w[1]) >= 0 &&
             theme_parse(cast(Scheme) theme_index(w[1]), w[2], c));
        if (owned == false)
        {
            res ~= line;
            continue;
        }
        if (placed)
            continue;
        res ~= "base " ~ THEMES[parent].name;
        res ~= colors;
        placed = true;
    }
    if (placed == false)
    {
        res ~= "base " ~ THEMES[parent].name;
        res ~= colors;
    }
    return res;
}

/// Write `text` to `path` via a temp file. Errors are logged.
bool theme_write(string path, const(string)[] text)
{
    try
    {
        mkdirRecurse(dirName(path));
        string tmp = path ~ ".tmp";
        write(tmp, join(text, "\n") ~ "\n");
        rename(tmp, path);
    }
    catch (Exception e)
    {
        logError("%s: %s", path, e.msg);
        return false;
    }
    return true;
}

/// Index of scheme `name`, or -1.
ptrdiff_t theme_index(string name)
{
    foreach (size_t i, ref immutable SchemeInfo info; SCHEMES)
        if (info.name == name)
            return i;
    return -1;
}

/// Parse ddhx's FG:BG into `c` for scheme `s`. A side empty or `default` is
/// left unset (alpha 0). False on a bad color, or one for a side `s` doesn't draw.
bool theme_parse(Scheme s, string spec, out mu_Color[2] c)
{
    if (spec.length == 0)
        return false;
    ptrdiff_t i = indexOf(spec, ':');
    string fg = i >= 0 ? spec[0 .. i] : spec;
    string bg = i >= 0 ? spec[i + 1 .. $] : null;
    return theme_part(fg, SCHEMES[s].fg.a != 0, c[0]) &&
        theme_part(bg, SCHEMES[s].bg.a != 0, c[1]);
}

/// One side of FG:BG into `c`, unset when empty. False if bad or not `drawn`.
bool theme_part(string text, bool drawn, out mu_Color c)
{
    if (text.length == 0 || text == "default")
        return true;
    if (drawn == false)
        return false;
    return theme_value(text, c);
}

/// Color name or `#rrggbb` into `c`. False if neither.
bool theme_value(string text, out mu_Color c)
{
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
    foreach (ref immutable NamedColor n; PALETTE)
        if (n.color == c)
            return n.name;
    return format("#%02x%02x%02x", c.r, c.g, c.b);
}

unittest
{
    scope (exit) theme_defaults();

    assert(theme_color("zero", "red", true));
    assert(theme_fg(Scheme.zero) == mu_Color(205, 49, 49, 255));
    assert(theme_overridden(Scheme.zero));
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

    assert(theme_spec(Scheme.bookmark) == "white:#102030");
    assert(theme_spec(Scheme.selection) == ":#30548c");

    assert(theme_color("zero", "default", true));
    assert(theme_fg(Scheme.zero) == SCHEMES[Scheme.zero].fg);
    assert(theme_overridden(Scheme.zero) == false);

    // UI schemes reach the widgets.
    assert(theme_color("ui-accent", "red", true));
    assert(theme_tabs().accent == mu_Color(205, 49, 49, 255));
    assert(theme_split().held == mu_Color(205, 49, 49, 255));
    assert(theme_color("ui-button", "red", false) == false);
}

unittest
{
    scope (exit) theme_defaults();

    assert(theme_current() == "dark");
    assert(theme_use("light"));
    assert(theme_current() == "light");
    assert(theme_bg(Scheme.ui_canvas) == mu_Color(255, 255, 255, 255));
    assert(theme_use("../light") == false);
    assert(theme_exists("dark"));

    // Overrides win over the theme and survive a switch.
    assert(theme_color("bookmark", ":red", true));
    assert(theme_use("dark"));
    assert(theme_bg(Scheme.bookmark) == mu_Color(205, 49, 49, 255));
    assert(theme_fg(Scheme.bookmark) == SCHEMES[Scheme.bookmark].fg);

    // Built-in themes can't be edited.
    assert(theme_set(Scheme.zero, "red") == false);
    assert(theme_changed() == false);
}

unittest
{
    scope (exit) theme_defaults();

    // A user theme file, minus the disk: base theme, then color lines.
    string[] text = [
        "# mine",
        "color zero red",
        "base light",
        "color zero blue:green",
        "color selection :#102030",
        "color nope red",
    ];
    theme_read(text, "test", base, parent);
    fileLines = text;
    editable = true;
    assert(parent == 1);
    assert(base[Scheme.zero][0] == mu_Color(205, 49, 49, 255)); // bad line skipped
    assert(base[Scheme.selection][1] == mu_Color(0x10, 0x20, 0x30, 255));
    assert(base[Scheme.normal] == THEMES[1].colors[Scheme.normal]);

    // Edits: an empty side takes the base theme's, Reset drops the line.
    assert(theme_set(Scheme.cursor, "white"));
    assert(theme_set(Scheme.bookmark, ":"));
    assert(theme_changed());
    theme_reset(Scheme.selection);
    assert(theme_lines() == [ "color zero red", "color cursor white" ]);

    // Saving keeps comments and bad lines, in place.
    assert(theme_merge(fileLines, theme_lines()) == [
        "# mine",
        "base light",
        "color zero red",
        "color cursor white",
        "color zero blue:green",
        "color nope red",
    ]);
    assert(theme_merge(null, null) == [ "base light" ]);

    assert(theme_name_ok("my-theme_2"));
    assert(theme_name_ok("") == false);
    assert(theme_name_ok("a/b") == false);
    assert(theme_name_ok("a.b") == false);
}

version (Posix) unittest
{
    import std.file : exists, readText, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.process : environment;

    // A user theme on disk: copy, edit, save, reload, list.
    string home = buildPath(tempDir(), "vddhx-theme-test");
    string old = environment.get("XDG_CONFIG_HOME");
    environment["XDG_CONFIG_HOME"] = home;
    scope (exit)
    {
        if (old is null)
            environment.remove("XDG_CONFIG_HOME");
        else
            environment["XDG_CONFIG_HOME"] = old;
        if (exists(home))
            rmdirRecurse(home);
        theme_defaults();
        theme_scan();
    }

    assert(theme_use("light"));
    assert(theme_copy("mine") is null);
    assert(theme_copy("mine") !is null); // taken
    assert(theme_copy("dark") !is null); // built-in
    assert(theme_current() == "mine" && theme_editable());
    assert(theme_set(Scheme.zero, "red"));
    assert(theme_save());
    assert(readText(theme_file()) == "base light\ncolor zero red\n");

    assert(theme_use("dark"));
    assert(theme_fg(Scheme.zero) == SCHEMES[Scheme.zero].fg);
    assert(theme_use("mine"));
    assert(theme_parent() == "light");
    assert(theme_fg(Scheme.zero) == mu_Color(205, 49, 49, 255));
    assert(theme_bg(Scheme.ui_canvas) == mu_Color(255, 255, 255, 255));
    assert(theme_list() == [ "dark", "light", "mine" ]);
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
