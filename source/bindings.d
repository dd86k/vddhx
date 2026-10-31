/// Key bindings: chords to commands, set by .vddhxrc's `bind KEY COMMAND` and
/// `unbind KEY` lines, with ddhx's key and command names.
///
/// Like ddhx, unbinding a key restores its default command if it has one, so a
/// default key can be moved to another command but never left unbound.
/// Authors: dd86k <dd@dax.moe>
module bindings;

import bindbc.sdl;
import ui;

/// Chord modifier bits.
enum : ubyte
{
    MOD_CTRL  = 1,  /// Either Ctrl.
    MOD_ALT   = 2,  /// Either Alt.
    MOD_SHIFT = 4,  /// Either Shift.
}

/// A key with modifiers, or a typed character.
struct Chord
{
    uint key;   /// SDL keycode, or the code point when `text` is set.
    ubyte mods; /// MOD_* bits, zero for text.
    /// Matched on the typed character, so it follows the keyboard layout
    /// (brackets behind AltGr). Plain punctuation and non-ASCII keys.
    bool text;
}

/// Bindable command: rc name, command code, default keys in rc syntax
/// (space-separated).
struct Command
{
    /// Command name, akin to ddhx: "replace".
    string name;
    /// CMD_* command ID.
    int id;
    /// Text representation of the shortcut.
    string keys;
    /// If set, also runs while the omnibar has the keyboard.
    bool global;
    /// Pretty name label used in omnibar, null to take the '>' command's.
    string label;
}

/// All bindable commands, in list order. Names are ddhx's where it has the
/// command. Caret moves come last.
immutable Command[] BINDABLE = [
    Command("omnibar",          CMD_OMNIBAR,        "ctrl+e",               true,  "Omnibar"),
    Command("menu",             CMD_MENU,           "ctrl+shift+p",         true,  "Omnibar, on Commands"),
    Command("new-tab",          CMD_NEW_TAB,        "ctrl+t"),
    Command("open",             CMD_OPEN,           "ctrl+o"),
    Command("open-device",      CMD_OPEN_DEVICE,    ""),
    Command("save",             CMD_SAVE,           "ctrl+s"),
    Command("save-as",          CMD_SAVE_AS,        "ctrl+shift+s"),
    Command("close-tab",        CMD_CLOSE_TAB,      "ctrl+w"),
    Command("tab-next",         CMD_TAB_NEXT,       "ctrl+tab",             false, "Next Tab"),
    Command("tab-prev",         CMD_TAB_PREV,       "ctrl+shift+tab",       false, "Previous Tab"),
    Command("toggle-readonly",  CMD_READONLY,       ""),
    Command("refresh",          CMD_REFRESH,        "ctrl+l"),
    Command("diff-file",        CMD_COMPARE,        ""),
    Command("diff-stop",        CMD_COMPARE_STOP,   ""),
    Command("diff-next",        CMD_DIFF_NEXT,      "}"),
    Command("diff-prev",        CMD_DIFF_PREV,      "{"),
    Command("undo",             CMD_UNDO,           "ctrl+z"),
    Command("redo",             CMD_REDO,           "ctrl+y ctrl+shift+z"),
    Command("cut",              CMD_CUT,            "ctrl+x"),
    Command("cut-text",         CMD_CUT_TEXT,       "ctrl+shift+x"),
    Command("copy",             CMD_COPY,           "ctrl+c"),
    Command("copy-text",        CMD_COPY_TEXT,      "ctrl+shift+c"),
    Command("paste",            CMD_PASTE,          "ctrl+v"),
    Command("replace",          CMD_REPLACE,        ""),
    Command("insert",           CMD_INSERT,         ""),
    Command("replace-range",    CMD_REPLACE_RANGE,  ""),
    Command("insert-range",     CMD_INSERT_RANGE,   ""),
    Command("goto",             CMD_GOTO,           "ctrl+g",               true),
    Command("goto-field",       CMD_STRUCTURE,      ""),
    Command("find",             CMD_FIND,           "ctrl+f",               true),
    Command("find-back",        CMD_FIND_BACK,      "ctrl+shift+f",         true),
    Command("find-next",        CMD_FIND_NEXT,      "ctrl+n"),
    Command("find-prev",        CMD_FIND_PREV,      "ctrl+shift+n"),
    Command("find-bookmark",    CMD_MARK_ALL,       ""),
    Command("toggle-inspector", CMD_INSPECT,        "alt+i",                true),
    Command("bookmark-toggle",  CMD_MARK,           "ctrl+b"),
    Command("bookmark-name",    CMD_MARK_NAME,      "ctrl+shift+b"),
    Command("bookmark-next",    CMD_MARK_NEXT,      "]"),
    Command("bookmark-prev",    CMD_MARK_PREV,      "["),
    Command("bookmark-list",    CMD_MARK_LIST,      ""),
    Command("bookmark-clear",   CMD_MARK_CLEAR,     ""),
    Command("bookmark-load",    CMD_MARK_LOAD,      ""),
    Command("bookmark-save",    CMD_MARK_SAVE,      ""),
    Command("split",            CMD_SPLIT,          "ctrl+\\"),
    Command("split-down",       CMD_SPLIT_DOWN,     "ctrl+shift+\\"),
    Command("pane-close",       CMD_CLOSE_PANE,     ""),
    Command("pane-next",        CMD_PANE_NEXT,      ""),
    Command("pane-prev",        CMD_PANE_PREV,      ""),
    // Ctrl+Shift+= is Ctrl++ on US layouts. Keypad keys arrive as their main ones.
    Command("zoom-in",          CMD_ZOOM_IN,        "ctrl+= ctrl+shift+= ctrl++", true),
    Command("zoom-out",         CMD_ZOOM_OUT,       "ctrl+-",               true),
    Command("zoom-reset",       CMD_ZOOM_RESET,     "ctrl+0",               true),
    Command("toggle-minimap",   CMD_MINIMAP,        ""),
    Command("toggle-breadcrumbs", CMD_CRUMBS,       ""),
    Command("toggle-endian",    CMD_ENDIAN,         ""),
    Command("columns",          CMD_COLUMNS,        ""),
    Command("charset",          CMD_CHARSET,        ""),
    Command("address",          CMD_ADDRESS,        ""),
    Command("settings",         CMD_SETTINGS,       ""),
    Command("shortcuts",        CMD_KEYS,           ""),
    Command("about",            CMD_ABOUT,          ""),
    Command("quit",             CMD_QUIT,           "ctrl+q"),
    Command("left",             CMD_LEFT,           "left-arrow",           false, "Move Left"),
    Command("right",            CMD_RIGHT,          "right-arrow",          false, "Move Right"),
    Command("up",               CMD_UP,             "up-arrow",             false, "Move Up a Row"),
    Command("down",             CMD_DOWN,           "down-arrow",           false, "Move Down a Row"),
    Command("home",             CMD_HOME,           "home",                 false, "Go to Row Start"),
    Command("end",              CMD_END,            "end",                  false, "Go to Row End"),
    Command("top",              CMD_TOP,            "ctrl+home",            false, "Go to File Start"),
    Command("bottom",           CMD_BOTTOM,         "ctrl+end",             false, "Go to File End"),
    Command("page-up",          CMD_PAGE_UP,        "page-up",              false, "Page Up"),
    Command("page-down",        CMD_PAGE_DOWN,      "page-down",            false, "Page Down"),
    Command("view-up",          CMD_VIEW_UP,        "ctrl+up-arrow",        false, "Scroll Up a Row"),
    Command("view-down",        CMD_VIEW_DOWN,      "ctrl+down-arrow",      false, "Scroll Down a Row"),
    Command("skip-front",       CMD_SKIP_NEXT,      "ctrl+right-arrow"),
    Command("skip-back",        CMD_SKIP_PREV,      "ctrl+left-arrow"),
    Command("select-left",      CMD_SELECT_LEFT,    "shift+left-arrow",     false, "Select Left"),
    Command("select-right",     CMD_SELECT_RIGHT,   "shift+right-arrow",    false, "Select Right"),
    Command("select-up",        CMD_SELECT_UP,      "shift+up-arrow",       false, "Select Up a Row"),
    Command("select-down",      CMD_SELECT_DOWN,    "shift+down-arrow",     false, "Select Down a Row"),
    Command("select-home",      CMD_SELECT_HOME,    "shift+home",           false, "Select to Row Start"),
    Command("select-end",       CMD_SELECT_END,     "shift+end",            false, "Select to Row End"),
    Command("select-top",       CMD_SELECT_TOP,     "ctrl+shift+home",      false, "Select to File Start"),
    Command("select-bottom",    CMD_SELECT_BOTTOM,  "ctrl+shift+end",       false, "Select to File End"),
    Command("select-page-up",   CMD_SELECT_PAGE_UP, "shift+page-up",        false, "Select a Page Up"),
    Command("select-page-down", CMD_SELECT_PAGE_DOWN, "shift+page-down",    false, "Select a Page Down"),
    Command("select-skip-front", CMD_SKIP_SEL_NEXT, "ctrl+shift+right-arrow"),
    Command("select-skip-back", CMD_SKIP_SEL_PREV,  "ctrl+shift+left-arrow"),
    Command("select",           CMD_SELECT_RANGE,   ""),
];

/// Load the default bindings, dropping all others.
void bind_defaults()
{
    keymap = null;
    foreach (ref immutable Command c; BINDABLE)
        foreach (Chord chord; bind_default_chords(c))
            keymap[chord] = c.id;
    bind_rebuild();
}

/// Parse `spec` in ddhx's syntax ("ctrl+shift+s", "page-up", "]") into `c`.
/// Returns: False if it names no key.
bool bind_parse(string spec, out Chord c)
{
    import std.ascii : isAlphaNum, isPrintable;
    static import std.ascii;
    import std.uni : toLower;
    import std.algorithm.searching : startsWith;
    import std.utf : decode, UTFException;

    // Modifiers in any order, like ddhx. A lone "+" is the key.
    ubyte mods;
    string rest = spec;
    for (;;)
    {
        string low = toLower(rest);
        if (low.startsWith("ctrl+") && rest.length > 5)
        {
            mods |= MOD_CTRL;
            rest = rest[5 .. $];
        }
        else if (low.startsWith("alt+") && rest.length > 4)
        {
            mods |= MOD_ALT;
            rest = rest[4 .. $];
        }
        else if (low.startsWith("shift+") && rest.length > 6)
        {
            mods |= MOD_SHIFT;
            rest = rest[6 .. $];
        }
        else
            break;
    }
    if (rest.length == 0)
        return false;

    string name = toLower(rest);
    foreach (ref immutable KeyName k; KEY_NAMES)
    {
        if (k.name == name)
        {
            c = Chord(k.key, mods);
            return true;
        }
    }

    dchar ch;
    size_t i;
    try
        ch = decode(rest, i);
    catch (UTFException)
        return false;
    if (i != rest.length)
        return false; // more than one character

    if (ch < 0x80)
    {
        if (isPrintable(cast(char) ch) == false)
            return false;
        ch = std.ascii.toLower(cast(char) ch); // "H" is "h", as in ddhx
        // Letters and digits are keys. Plain punctuation is matched as typed.
        if (isAlphaNum(cast(char) ch) || ch == ' ' || mods)
            c = Chord(ch, mods);
        else
            c = Chord(ch, 0, true);
        return true;
    }
    c = mods ? Chord(ch, mods) : Chord(ch, 0, true);
    return true;
}

/// `c` in rc syntax, e.g. "ctrl+shift+s".
string bind_name(Chord c)
{
    import std.conv : to;

    string s;
    if (c.mods & MOD_CTRL)  s ~= "ctrl+";
    if (c.mods & MOD_ALT)   s ~= "alt+";
    if (c.mods & MOD_SHIFT) s ~= "shift+";
    if (c.text == false)
        foreach (ref immutable KeyName k; KEY_NAMES)
            if (k.key == c.key)
                return s ~ k.name;
    return s ~ to!string(cast(dchar) c.key);
}

/// `c` for display, e.g. "Ctrl+Shift+S".
string bind_label(Chord c)
{
    import std.ascii : toUpper;
    import std.conv : to;

    string s;
    if (c.mods & MOD_CTRL)  s ~= "Ctrl+";
    if (c.mods & MOD_ALT)   s ~= "Alt+";
    if (c.mods & MOD_SHIFT) s ~= "Shift+";
    if (c.text == false)
        foreach (ref immutable KeyName k; KEY_NAMES)
            if (k.key == c.key)
                return s ~ k.label;
    dchar ch = cast(dchar) c.key;
    return s ~ to!string(ch < 0x80 ? cast(dchar) toUpper(cast(char) ch) : ch);
}

/// Chord for an SDL key event, keypad keys folded into their main ones.
Chord bind_chord(SDL_Keycode key, SDL_Keymod mod)
{
    ubyte mods;
    if (mod & SDL_KMOD_CTRL)  mods |= MOD_CTRL;
    if (mod & SDL_KMOD_ALT)   mods |= MOD_ALT;
    if (mod & SDL_KMOD_SHIFT) mods |= MOD_SHIFT;

    switch (key)
    {
    case SDLK_KP_ENTER:  key = SDLK_RETURN; break;
    case SDLK_KP_PLUS:   key = SDLK_PLUS;   break;
    case SDLK_KP_MINUS:  key = SDLK_MINUS;  break;
    case SDLK_KP_EQUALS: key = SDLK_EQUALS; break;
    case SDLK_KP_0:      key = SDLK_0;      break;
    case SDLK_KP_1: .. case SDLK_KP_9:
        key = cast(SDL_Keycode)(SDLK_1 + (key - SDLK_KP_1));
        break;
    default:
    }
    return Chord(key, mods);
}

/// Command bound to `c`, or -1.
int bind_find(Chord c)
{
    if (const(int)* id = c in active())
        return *id;
    return -1;
}

/// Whether command `id` also runs while the omnibar has the keyboard.
bool bind_global(int id)
{
    ptrdiff_t i = bind_index(id);
    return i >= 0 && BINDABLE[i].global;
}

/// rc name of command `id`, or null.
string bind_command_name(int id)
{
    ptrdiff_t i = bind_index(id);
    return i >= 0 ? BINDABLE[i].name : null;
}

/// List label of command `id`.
string bind_command_label(int id)
{
    ptrdiff_t i = bind_index(id);
    if (i >= 0 && BINDABLE[i].label)
        return BINDABLE[i].label;
    foreach (ref immutable Entry e; COMMANDS)
        if (e.id == id)
            return e.label;
    return null;
}

/// First key of command `id` for display, empty if unbound. NUL-terminated.
string bind_keys(int id)
{
    if (firstKeys is null)
        bind_defaults();
    return id >= 0 && id < firstKeys.length ? firstKeys[id] : "";
}

/// Ditto, all keys joined with commas.
string bind_keys_all(int id)
{
    if (firstKeys is null)
        bind_defaults();
    return id >= 0 && id < allKeys.length ? allKeys[id] : "";
}

/// Apply rc line `bind KEY COMMAND`. Returns: False for an unknown key or
/// command.
bool bind_key(string key, string command)
{
    Chord c;
    if (bind_parse(key, c) == false)
        return false;
    int id = bind_command_id(command);
    if (id < 0)
        return false;
    active()[c] = id;
    bind_rebuild();
    return true;
}

/// Apply rc line `unbind KEY`: back to its default command, else unbound.
/// Returns: False for an unknown key.
bool unbind_key(string key)
{
    Chord c;
    if (bind_parse(key, c) == false)
        return false;
    bind_unset(c);
    bind_rebuild();
    return true;
}

/// Whether `bind KEY COMMAND` (`command` non-null) or `unbind KEY` would apply.
bool bind_valid(string key, string command)
{
    Chord c;
    if (bind_parse(key, c) == false)
        return false;
    return command is null || bind_command_id(command) >= 0;
}

/// Command whose next key press is captured as a new key (Settings), or -1.
int bind_capturing()
{
    return captureId;
}

/// Start capturing a key for command `id`, -1 to stop.
void bind_capture(int id)
{
    captureId = id;
}

/// Bind `c` to the command being captured and stop capturing.
/// Returns: Command `c` ran before, or -1.
int bind_capture_take(Chord c)
{
    int was = bind_find(c);
    if (captureId >= 0)
    {
        active()[c] = captureId;
        captureId = -1;
        bind_edit();
    }
    return was;
}

/// Give command `id` back its default keys and drop the others it has.
void bind_reset(int id)
{
    Chord[] mine;
    foreach (Chord c, int to; active())
        if (to == id)
            mine ~= c;
    foreach (Chord c; mine)
        bind_unset(c);
    ptrdiff_t i = bind_index(id);
    if (i >= 0)
        foreach (Chord c; bind_default_chords(BINDABLE[i]))
            active()[c] = id;
    bind_edit();
}

/// Reset all commands to their default keys.
void bind_reset_all()
{
    bind_defaults();
    bind_edit();
}

/// Whether bindings were edited (Settings) since loading, so the rc's bind
/// lines need rewriting.
bool bind_edited()
{
    return edited;
}

/// Whether bindings were edited since the last call. For Settings to save.
bool bind_changed()
{
    bool was = changed;
    changed = false;
    return was;
}

/// rc lines for the bindings that differ from the defaults, in list order.
string[] bind_lines()
{
    import std.algorithm.sorting : sort;

    string[] lines;
    foreach (ref immutable Command cmd; BINDABLE)
    {
        Chord[] defs = bind_default_chords(cmd);
        string[] names;
        foreach (Chord c, int id; active())
        {
            if (id != cmd.id)
                continue;
            bool isDefault;
            foreach (Chord d; defs)
                if (d == c)
                    isDefault = true;
            if (isDefault == false)
                names ~= bind_name(c);
        }
        sort(names);
        foreach (string n; names)
            lines ~= "bind " ~ bind_quote(n) ~ " " ~ cmd.name;
    }
    return lines;
}

private:

/// Key with an rc name and a display label.
struct KeyName
{
    string name;    /// rc name, ddhx's.
    uint key;       /// SDL keycode.
    string label;   /// Display label.
}

/// Named keys. Esc stays the omnibar's and the job cancel's.
immutable KeyName[] KEY_NAMES = [
    KeyName("left-arrow",  SDLK_LEFT,      "Left"),
    KeyName("right-arrow", SDLK_RIGHT,     "Right"),
    KeyName("up-arrow",    SDLK_UP,        "Up"),
    KeyName("down-arrow",  SDLK_DOWN,      "Down"),
    KeyName("home",        SDLK_HOME,      "Home"),
    KeyName("end",         SDLK_END,       "End"),
    KeyName("page-up",     SDLK_PAGEUP,    "PgUp"),
    KeyName("page-down",   SDLK_PAGEDOWN,  "PgDn"),
    KeyName("insert",      SDLK_INSERT,    "Insert"),
    KeyName("delete",      SDLK_DELETE,    "Delete"),
    KeyName("tab",         SDLK_TAB,       "Tab"),
    KeyName("backspace",   SDLK_BACKSPACE, "Backspace"),
    KeyName("enter",       SDLK_RETURN,    "Enter"),
    KeyName("spacebar",    SDLK_SPACE,     "Space"),
    KeyName("f1",          SDLK_F1,        "F1"),
    KeyName("f2",          SDLK_F2,        "F2"),
    KeyName("f3",          SDLK_F3,        "F3"),
    KeyName("f4",          SDLK_F4,        "F4"),
    KeyName("f5",          SDLK_F5,        "F5"),
    KeyName("f6",          SDLK_F6,        "F6"),
    KeyName("f7",          SDLK_F7,        "F7"),
    KeyName("f8",          SDLK_F8,        "F8"),
    KeyName("f9",          SDLK_F9,        "F9"),
    KeyName("f10",         SDLK_F10,       "F10"),
    KeyName("f11",         SDLK_F11,       "F11"),
    KeyName("f12",         SDLK_F12,       "F12"),
];

/// Active bindings.
__gshared int[Chord] keymap;
/// bind_keys and bind_keys_all text by command code, NUL-terminated.
__gshared string[] firstKeys, allKeys;
/// See bind_capturing.
__gshared int captureId = -1;
/// See bind_edited and bind_changed.
__gshared bool edited, changed;

/// Active bindings, the defaults until something loads them.
ref int[Chord] active()
{
    if (firstKeys is null)
        bind_defaults();
    return keymap;
}

/// Index of command `id` in BINDABLE, or -1.
ptrdiff_t bind_index(int id)
{
    foreach (size_t i, ref immutable Command c; BINDABLE)
        if (c.id == id)
            return i;
    return -1;
}

/// Code of the command named `name`, or -1.
int bind_command_id(string name)
{
    foreach (ref immutable Command c; BINDABLE)
        if (c.name == name)
            return c.id;
    return -1;
}

/// Default chords of `c`. The table is checked by a unittest.
Chord[] bind_default_chords(ref immutable Command c)
{
    import std.array : split;

    Chord[] chords;
    foreach (string spec; split(c.keys))
    {
        Chord chord;
        if (bind_parse(spec, chord))
            chords ~= chord;
    }
    return chords;
}

/// Unbind `c`, restoring its default command if it has one.
void bind_unset(Chord c)
{
    foreach (ref immutable Command cmd; BINDABLE)
    {
        foreach (Chord d; bind_default_chords(cmd))
        {
            if (d == c)
            {
                active()[c] = cmd.id;
                return;
            }
        }
    }
    active().remove(c);
}

/// Mark an edit from Settings.
void bind_edit()
{
    edited = true;
    changed = true;
    bind_rebuild();
}

/// `name` as one rc argument: quoted if it has a quote or starts a comment.
string bind_quote(string name)
{
    if (name == "\"" || name == "'" || name == "#")
        return name == "'" ? `"'"` : "'" ~ name ~ "'";
    return name;
}

/// Refresh the key labels: defaults first, then the rest by name.
void bind_rebuild()
{
    import std.algorithm.sorting : sort;
    import std.array : join;

    firstKeys = new string[CMD_COUNT];
    allKeys = new string[CMD_COUNT];
    foreach (ref immutable Command cmd; BINDABLE)
    {
        Chord[] defs = bind_default_chords(cmd);
        string[] labels;
        foreach (Chord d; defs)
            if (bind_find(d) == cmd.id)
                labels ~= bind_label(d);
        string[] extra;
        foreach (Chord c, int id; active())
        {
            if (id != cmd.id)
                continue;
            bool isDefault;
            foreach (Chord d; defs)
                if (d == c)
                    isDefault = true;
            if (isDefault == false)
                extra ~= bind_label(c);
        }
        sort(extra);
        labels ~= extra;
        firstKeys[cmd.id] = labels.length ? (labels[0] ~ '\0')[0 .. $ - 1] : "";
        allKeys[cmd.id] = labels.length ? (join(labels, ", ") ~ '\0')[0 .. $ - 1] : "";
    }
}

unittest
{
    // Every default parses, every '>' command is bindable, names are unique.
    foreach (size_t i, ref immutable Command c; BINDABLE)
    {
        import std.array : split;
        assert(bind_default_chords(c).length == split(c.keys).length, c.name);
        assert(bind_command_label(c.id).length, c.name);
        foreach (ref immutable Command d; BINDABLE[i + 1 .. $])
            assert(c.name != d.name && c.id != d.id, c.name);
    }
    foreach (ref immutable Entry e; COMMANDS)
        assert(bind_index(e.id) >= 0, e.label);
}

unittest
{
    Chord c;
    assert(bind_parse("ctrl+shift+s", c) && c == Chord(SDLK_S, MOD_CTRL | MOD_SHIFT));
    assert(bind_parse("Shift+Ctrl+S", c) && c == Chord(SDLK_S, MOD_CTRL | MOD_SHIFT));
    assert(bind_parse("H", c) && c == Chord(SDLK_H, 0));
    assert(bind_parse("page-up", c) && c == Chord(SDLK_PAGEUP, 0));
    assert(bind_parse("]", c) && c == Chord(']', 0, true));
    assert(bind_parse("ctrl++", c) && c == Chord(SDLK_PLUS, MOD_CTRL));
    assert(bind_parse("ctrl+\\", c) && c == Chord(SDLK_BACKSLASH, MOD_CTRL));
    assert(bind_parse("€", c) && c == Chord('€', 0, true));
    assert(bind_parse("ctrl+", c) == false);
    assert(bind_parse("ab", c) == false);
    assert(bind_parse("escape", c) == false);

    assert(bind_name(Chord(SDLK_PAGEUP, MOD_CTRL)) == "ctrl+page-up");
    assert(bind_label(Chord(SDLK_S, MOD_CTRL | MOD_SHIFT)) == "Ctrl+Shift+S");
    assert(bind_label(Chord(']', 0, true)) == "]");
    assert(bind_chord(SDLK_KP_PLUS, SDL_KMOD_LCTRL) == Chord(SDLK_PLUS, MOD_CTRL));
}

unittest
{
    bind_defaults();
    Chord ctrlB = Chord(SDLK_B, MOD_CTRL);
    assert(bind_find(ctrlB) == CMD_MARK);
    assert(bind_keys(CMD_REDO) == "Ctrl+Y");
    assert(bind_keys_all(CMD_REDO) == "Ctrl+Y, Ctrl+Shift+Z");

    // ddhx: unbind restores a default key, drops any other.
    assert(bind_key("ctrl+b", "left"));
    assert(bind_key("h", "left"));
    assert(bind_find(ctrlB) == CMD_LEFT);
    assert(bind_keys(CMD_MARK) == "");
    assert(unbind_key("ctrl+b") && bind_find(ctrlB) == CMD_MARK);
    assert(unbind_key("h") && bind_find(Chord(SDLK_H, 0)) == -1);
    assert(bind_key("h", "nope") == false);
    assert(bind_key("ctrl+b", "left"));
    assert(bind_key("h", "left"));
    assert(bind_lines() == [ "bind ctrl+b left", "bind h left" ]);

    // Reset gives the command its defaults back, wherever they went.
    bind_reset(CMD_MARK);
    assert(bind_find(ctrlB) == CMD_MARK);
    assert(bind_lines() == [ "bind h left" ]);
    bind_reset(CMD_LEFT);
    assert(bind_lines().length == 0);

    bind_capture(CMD_MARK_NEXT);
    assert(bind_capture_take(Chord('#', 0, true)) == -1);
    assert(bind_capturing() == -1);
    assert(bind_lines() == [ "bind '#' bookmark-next" ]);
    assert(bind_edited() && bind_changed() && bind_changed() == false);
    bind_defaults();
}
