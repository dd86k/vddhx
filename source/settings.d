/// Settings tab: categories on the left, saved on every change.
///
/// Saved settings only. Per-view setup (columns, charset, byte order) lives in
/// the View menu, where it previews on the grid.
/// Authors: dd86k <dd@dax.moe>
module settings;

import std.system : Endian;
import ddui;
import ddhx.charset : Charset, charsets;
import preferences;

private enum int CATEGORY_W = 120;
private enum int LABEL_W = 120;
private enum int FIELD_W = 260;

private enum Category { defaults, appearance }
private static immutable string[] CATEGORY_NAMES = [ "Defaults", "Appearance" ];

private __gshared Category category;

/// Fill the rest of the pane with the page, where the hex panel would go.
void settings_page(mu_Context* ctx)
{
    static immutable int[2] split = [ CATEGORY_W, -1 ];
    mu_layout_row(ctx, 2, split.ptr, -1);

    // ui_frame packs rows tight for the grid; add spacing inside the panels only.
    int spacing = ctx.style.spacing;

    mu_begin_panel(ctx, "!categories");
    ctx.style.spacing = 4;
    static immutable int[1] full = [ -1 ];
    mu_layout_row(ctx, 1, full.ptr, 0);
    foreach (size_t i, string name; CATEGORY_NAMES)
        if (settings_category(ctx, name, category == i))
            category = cast(Category) i;
    ctx.style.spacing = spacing;
    mu_end_panel(ctx);

    mu_begin_panel(ctx, "!page");
    ctx.style.spacing = 4;
    final switch (category)
    {
    case Category.defaults:   settings_defaults(ctx);   break;
    case Category.appearance: settings_appearance(ctx); break;
    }
    ctx.style.spacing = spacing;
    mu_end_panel(ctx);
}

private:

bool settings_category(mu_Context* ctx, string name, bool selected)
{
    mu_Id id = mu_get_id(ctx, name.ptr, name.length);
    mu_Rect r = mu_layout_next(ctx);
    mu_update_control(ctx, id, r, 0);
    // Flat unless selected or hovered.
    if (selected)
        mu_draw_rect(ctx, r, ctx.style.colors[MU_COLOR_BUTTONFOCUS]);
    else if (ctx.hover == id)
        mu_draw_rect(ctx, r, ctx.style.colors[MU_COLOR_BUTTONHOVER]);
    mu_draw_control_text(ctx, name, r, MU_COLOR_TEXT, 0);
    return ctx.mouse_pressed == MU_MOUSE_LEFT && ctx.focus == id;
}

void settings_note(Args...)(mu_Context* ctx, string fmt, Args args)
{
    import std.format : sformat;
    char[512] buf = void;
    const(char)[] text = sformat(buf, fmt, args);
    static immutable int[1] full = [ -1 ];
    mu_layout_row(ctx, 1, full.ptr, 0);
    mu_text(ctx, cast(string) text);
}

void settings_label(mu_Context* ctx, string label)
{
    static immutable int[2] row = [ LABEL_W, FIELD_W ];
    mu_layout_row(ctx, 2, row.ptr, 0);
    mu_label(ctx, label);
}

// Shows the current value until edited; input is committed on Enter or blur,
// so typing "24" doesn't save "2" first.
struct ColumnsBox
{
    char[16] buf;
    bool editing;
}

bool settings_columns(mu_Context* ctx, ref ColumnsBox box, string key, int current, out int cols)
{
    import std.format : sformat;

    mu_Id id = mu_get_id(ctx, key.ptr, key.length);
    if (ctx.focus != id && box.editing == false)
    {
        char[] text = current ? sformat(box.buf[0 .. $ - 1], "%d", current)
                              : sformat(box.buf[0 .. $ - 1], "auto");
        box.buf[text.length] = 0;
    }

    int res = mu_textbox_raw(ctx, box.buf.ptr, cast(int) box.buf.length, id, mu_layout_next(ctx), 0);
    if (res & MU_RES_CHANGE)
        box.editing = true;
    bool done = (res & MU_RES_SUBMIT) || (box.editing && ctx.focus != id);
    if (done == false)
        return false;
    box.editing = false;

    import core.stdc.string : strlen;
    Prefs parsed;
    if (prefs_set(parsed, "columns", cast(string) box.buf[0 .. strlen(box.buf.ptr)]) == false)
        return false; // next frame restores the current value
    cols = parsed.columns;
    return true;
}

bool settings_charset(mu_Context* ctx, ref int index, immutable(Charset)* current)
{
    __gshared const(char)*[] names;
    if (names is null)
    {
        names = new const(char)*[charsets.length];
        foreach (size_t i, immutable(Charset)* set; charsets)
            names[i] = set.name.ptr; // literals, so NUL-terminated
    }

    foreach (size_t i, immutable(Charset)* set; charsets)
        if (set == current)
            index = cast(int) i;
    return (mu_dropdown(ctx, &index, names.ptr, cast(int) names.length) & MU_RES_CHANGE) != 0;
}

bool settings_endian(mu_Context* ctx, ref int index, Endian current)
{
    static immutable const(char)*[2] names = [ "Little-endian", "Big-endian" ];
    index = current == Endian.bigEndian;
    return (mu_dropdown(ctx, &index, names.ptr, cast(int) names.length) & MU_RES_CHANGE) != 0;
}

bool settings_writemode(mu_Context* ctx, ref int index, WriteMode current)
{
    static immutable const(char)*[3] names = [ "Overwrite", "Insert", "Read-only" ];
    index = current;
    return (mu_dropdown(ctx, &index, names.ptr, cast(int) names.length) & MU_RES_CHANGE) != 0;
}


void settings_defaults(mu_Context* ctx)
{
    // Separate statics: dropdowns are identified by their index's address.
    __gshared ColumnsBox columns;
    __gshared int charset, endian, writemode;

    settings_note(ctx, "What new tabs start with.");

    bool changed;

    int cols;
    settings_label(ctx, "Columns");
    if (settings_columns(ctx, columns, "default-columns", prefs.columns, cols))
    {
        prefs.columns = cols;
        changed = true;
    }

    settings_label(ctx, "Character set");
    if (settings_charset(ctx, charset, prefs.charset))
    {
        prefs.charset = charsets[charset];
        changed = true;
    }

    settings_label(ctx, "Byte order");
    if (settings_endian(ctx, endian, prefs.endian))
    {
        prefs.endian = endian ? Endian.bigEndian : Endian.littleEndian;
        changed = true;
    }

    settings_label(ctx, "Write mode");
    if (settings_writemode(ctx, writemode, prefs.writemode))
    {
        prefs.writemode = cast(WriteMode) writemode;
        changed = true;
    }

    settings_saved(ctx, changed);
}

void settings_appearance(mu_Context* ctx)
{
    __gshared int minimap, crumbs;

    bool changed;

    settings_label(ctx, "");
    minimap = prefs.minimap;
    if (mu_checkbox(ctx, "Minimap", &minimap) & MU_RES_CHANGE)
    {
        prefs.minimap = minimap != 0;
        changed = true;
    }

    settings_label(ctx, "");
    crumbs = prefs.crumbs;
    if (mu_checkbox(ctx, "Breadcrumbs", &crumbs) & MU_RES_CHANGE)
    {
        prefs.crumbs = crumbs != 0;
        changed = true;
    }

    settings_saved(ctx, changed);
}

// Saves on change, then shows the file path (only place it's shown).
void settings_saved(mu_Context* ctx, bool changed)
{
    __gshared bool failed;

    if (changed)
        failed = prefs_save() == false;

    string path = prefs_path();
    if (failed)
        settings_note(ctx, "Could not save to %s", path);
    else if (path)
        settings_note(ctx, "Saved to %s", path);
    else
        settings_note(ctx, "No config folder found; changes last until exit.");
}
