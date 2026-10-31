/// Settings tab: categories on the left, saved on every change.
///
/// Saved settings only. Per-view setup (columns, charset, byte order) lives in
/// the View menu, where it previews on the grid. Keys edits the bindings,
/// saved as .vddhxrc bind lines.
/// Authors: dd86k <dd@dax.moe>
module settings;

import std.system : Endian;
import ddui;
import ddhx.charset : Charset, charsets;
import preferences;
import bindings;
import hexview : HexBase;
import ui : ui_font_dialog, ui_fonts, ui_zoom;

private enum int CATEGORY_W = 120;
private enum int LABEL_W = 120;
private enum int FIELD_W = 260;
private enum int BROWSE_W = 80;
private enum int CLEAR_W = 60;
private enum int COMMAND_W = 180;
private enum int KEYS_W = 220;

private enum Category { defaults, appearance, keys }
private static immutable string[] CATEGORY_NAMES = [ "Defaults", "Appearance", "Keys" ];

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
    case Category.keys:       settings_keys(ctx);       break;
    }
    // Leaving the page stops a key capture.
    if (category != Category.keys)
        bind_capture(-1);
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
struct ValueBox
{
    char[16] buf;
    bool editing;
}

/// Text box for one saved key, true when a valid value was committed to prefs.
bool settings_value(mu_Context* ctx, ref ValueBox box, string key)
{
    import core.stdc.string : strlen;

    mu_Id id = mu_get_id(ctx, key.ptr, key.length);
    if (ctx.focus != id && box.editing == false)
    {
        string text = prefs_get(prefs, key);
        size_t n = text.length < box.buf.length ? text.length : box.buf.length - 1;
        box.buf[0 .. n] = text[0 .. n];
        box.buf[n] = 0;
    }

    int res = mu_textbox_raw(ctx, box.buf.ptr, cast(int) box.buf.length, id, mu_layout_next(ctx), 0);
    if (res & MU_RES_CHANGE)
        box.editing = true;
    bool done = (res & MU_RES_SUBMIT) || (box.editing && ctx.focus != id);
    if (done == false)
        return false;
    box.editing = false;

    // Invalid input: the next frame restores the current value.
    return prefs_set(prefs, key, cast(string) box.buf[0 .. strlen(box.buf.ptr)]);
}

// Font setting box, committed like ValueBox. Paths need the room.
struct FontBox
{
    char[1024] buf;
    bool editing;
}

/// Font row for the UI or hex panel (`mono`): text box, Browse, Clear.
void settings_font(mu_Context* ctx, ref FontBox box, string label, bool mono)
{
    import core.stdc.string : strlen;

    static immutable int[4] row = [ LABEL_W, FIELD_W, BROWSE_W, CLEAR_W ];
    mu_layout_row(ctx, 4, row.ptr, 0);
    mu_label(ctx, label);

    string* spec = mono ? &prefs.monofont : &prefs.font;
    mu_Id id = mu_get_id(ctx, &box, box.sizeof);
    if (ctx.focus != id && box.editing == false)
    {
        size_t n = spec.length < box.buf.length ? spec.length : box.buf.length - 1;
        box.buf[0 .. n] = (*spec)[0 .. n];
        box.buf[n] = 0;
    }

    int res = mu_textbox_raw(ctx, box.buf.ptr, cast(int) box.buf.length, id, mu_layout_next(ctx), 0);
    if (res & MU_RES_CHANGE)
        box.editing = true;
    if ((res & MU_RES_SUBMIT) || (box.editing && ctx.focus != id))
    {
        box.editing = false;
        import std.string : strip;
        *spec = strip(box.buf[0 .. strlen(box.buf.ptr)]).idup;
        ui_fonts(true);
    }

    mu_push_id(ctx, &box, box.sizeof);
    if (mu_button(ctx, "Browse..."))
        ui_font_dialog(mono);
    // Drop a pending edit too, or the blur commits it next frame.
    if (mu_button(ctx, "Clear"))
    {
        box.editing = false;
        *spec = null;
        ui_fonts(true);
    }
    mu_pop_id(ctx);
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

/// Offset base dropdown, true on change.
bool settings_address(mu_Context* ctx, ref int index, HexBase current)
{
    static immutable const(char)*[3] names = [ "Hexadecimal", "Decimal", "Octal" ];
    index = current;
    return (mu_dropdown(ctx, &index, names.ptr, cast(int) names.length) & MU_RES_CHANGE) != 0;
}


void settings_defaults(mu_Context* ctx)
{
    // Separate statics: dropdowns are identified by their index's address.
    __gshared ValueBox columns;
    __gshared int charset, endian, writemode, address;

    settings_note(ctx, "What new tabs start with.");

    bool changed;

    settings_label(ctx, "Columns");
    if (settings_value(ctx, columns, "columns"))
        changed = true;

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

    settings_label(ctx, "Offsets");
    if (settings_address(ctx, address, prefs.address))
    {
        prefs.address = cast(HexBase) address;
        changed = true;
    }

    settings_saved(ctx, changed);
}

void settings_appearance(mu_Context* ctx)
{
    __gshared int minimap, crumbs;
    __gshared ValueBox fontsize;
    __gshared FontBox font, monofont;

    bool changed;

    settings_label(ctx, "Text size");
    if (settings_value(ctx, fontsize, "fontsize"))
    {
        ui_zoom(0);
        changed = true;
    }

    settings_font(ctx, font, "UI font", false);
    settings_font(ctx, monofont, "Hex font", true);
    settings_note(ctx, "A font file or name, empty for the default.");

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

/// Keys page: each command's keys, Add to capture one more, Reset for its
/// defaults.
void settings_keys(mu_Context* ctx)
{
    settings_note(ctx, "To bind a key: Add, then press it (Esc cancels). Same as `bind KEY COMMAND`.");
    settings_note(ctx, "A default key can only move to another command. Reset brings it back.");

    static immutable int[1] one = [ BROWSE_W ];
    mu_layout_row(ctx, 1, one.ptr, 0);
    if (mu_button(ctx, "Reset All"))
    {
        bind_capture(-1);
        bind_reset_all();
    }

    static immutable int[4] row = [ COMMAND_W, KEYS_W, CLEAR_W, CLEAR_W ];
    int capture = bind_capturing();
    foreach (ref immutable Command c; BINDABLE)
    {
        mu_layout_row(ctx, 4, row.ptr, 0);
        mu_label(ctx, bind_command_label(c.id));
        mu_label(ctx, capture == c.id ? "Press a key..." : bind_keys_all(c.id));
        mu_push_id(ctx, c.name.ptr, cast(int) c.name.length);
        if (mu_button(ctx, capture == c.id ? "Cancel" : "Add"))
            bind_capture(capture == c.id ? -1 : c.id);
        if (mu_button(ctx, "Reset"))
        {
            bind_capture(-1);
            bind_reset(c.id);
        }
        mu_pop_id(ctx);
    }

    settings_saved(ctx, bind_changed());
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
