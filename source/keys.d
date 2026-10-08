/// Key binding checks: synthetic SDL events through input_event, so the routing
/// in input.d is exercised rather than stepped around. Run with
/// `SDL_VIDEODRIVER=offscreen dub run -b screenshots -- --screenshot --keys`.
///
/// Events carry keycodes, so SDL's own scancode-to-keycode translation (the
/// keyboard layout) is outside of what this can see.
module keys;

version (Screenshots):

import std.file : exists, read, remove, write;
import std.path : buildPath;
import std.string : toStringz;
import bindbc.sdl;
import ddlogger;
import ddui;
import input : input_event;
import omnibar : OmniMode;
import ui;

private __gshared mu_Context* ctx;
private __gshared void delegate() frame;
private __gshared int failures;

/// Run every check against `path`, a file of at least a few rows.
/// Returns: 0 when every check held, 1 otherwise.
int keys_run(mu_Context* context, void delegate() framer, string path)
{
    ctx = context;
    frame = framer;

    ui_open(path);
    frame(); frame();
    Probe p = ui_probe();
    expect(p.tabs == 1 && p.cursor == 0, "starts on one tab, caret at 0");

    keys_omnibar();
    keys_tabs();
    keys_panes();
    keys_caret();
    keys_edit();
    keys_marks();

    Files files = keys_files();
    keys_open(files);
    keys_navigate();
    keys_write(files);
    uiPickAuto = null;

    keys_quit();

    if (failures)
    {
        logCritical("keys: %d check(s) failed", failures);
        return 1;
    }
    logInfo("keys: all checks held");
    return 0;
}

private:

void expect(bool ok, string what, size_t line = __LINE__)
{
    if (ok)
        return;
    logCritical("keys.d(%d): %s", line, what);
    ++failures;
}

void key(SDL_Keycode code, SDL_Keymod mod, bool down)
{
    SDL_Event event; // .init zeroes the union
    event.type = down ? SDL_EVENT_KEY_DOWN : SDL_EVENT_KEY_UP;
    event.key.key  = code;
    event.key.mod  = mod;
    event.key.down = down;
    input_event(ctx, event);
}

struct Modifier { SDL_Keymod mask; SDL_Keycode code; }

immutable Modifier[] MODIFIERS = [
    Modifier(SDL_KMOD_LCTRL,  SDLK_LCTRL),
    Modifier(SDL_KMOD_LSHIFT, SDLK_LSHIFT),
    Modifier(SDL_KMOD_LALT,   SDLK_LALT),
];

// The way SDL delivers a chord: each modifier key arrives as its own event first,
// the mask growing as they go down and shrinking (already without the key being
// released) as they come up. muiKey leans on that symmetry, so a shortcut taken
// here would hide the bug class this exists for.
void press(SDL_Keycode code, uint mod = SDL_KMOD_NONE)
{
    SDL_Keymod held;
    foreach (ref immutable Modifier m; MODIFIERS)
    {
        if ((mod & m.mask) == 0)
            continue;
        held |= m.mask;
        key(m.code, held, true);
    }
    key(code, held, true);
    frame();
    key(code, held, false);
    foreach_reverse (ref immutable Modifier m; MODIFIERS)
    {
        if ((mod & m.mask) == 0)
            continue;
        held &= ~m.mask;
        key(m.code, held, false);
    }
    frame();
}

void type(string text)
{
    SDL_Event event;
    event.type = SDL_EVENT_TEXT_INPUT;
    event.text.text = text.toStringz;
    input_event(ctx, event);
    frame(); frame();
}

enum SDL_Keymod CTRL  = SDL_KMOD_LCTRL;
enum SDL_Keymod SHIFT = SDL_KMOD_LSHIFT;
enum SDL_Keymod ALT   = SDL_KMOD_LALT;

void keys_omnibar()
{
    press(SDLK_E, CTRL);
    Probe p = ui_probe();
    expect(p.omni && p.mode == OmniMode.switcher, "Ctrl+E raises the switcher");
    press(SDLK_E, CTRL);
    expect(ui_probe().omni == false, "Ctrl+E again puts it away");

    press(SDLK_P, CTRL | SHIFT);
    p = ui_probe();
    expect(p.omni && p.mode == OmniMode.command, "Ctrl+Shift+P raises commands");
    press(SDLK_ESCAPE);
    expect(ui_probe().omni == false, "Esc closes the omnibar");

    press(SDLK_G, CTRL);
    expect(ui_probe().mode == OmniMode.address, "Ctrl+G raises goto");
    press(SDLK_F, CTRL);
    p = ui_probe();
    expect(p.omni && p.mode == OmniMode.find, "Ctrl+F over goto switches to find");
    press(SDLK_ESCAPE);

    press(SDLK_I, ALT);
    p = ui_probe();
    expect(p.omni && p.mode == OmniMode.inspect, "Alt+I raises the inspector");
    press(SDLK_ESCAPE);

    // The box owns the keyboard: Ctrl+T would otherwise open a tab, the brackets
    // step bookmarks, and Tab walk ddui's focus off the query.
    press(SDLK_F, CTRL);
    type("utf1");
    expect(ui_probe().query == "utf1", "text reaches the find box");
    press(SDLK_BACKSPACE);
    expect(ui_probe().query == "utf", "Backspace edits the query");
    press(SDLK_TAB);
    p = ui_probe();
    expect(p.omni && p.query.length > "utf".length, "Tab completes the find word");
    size_t tabs = p.tabs;
    type("[");
    expect(ui_probe().query[$ - 1] == '[', "brackets are text in the box");
    press(SDLK_ESCAPE);
    expect(ui_probe().tabs == tabs, "nothing leaked into the panel");
}

void keys_tabs()
{
    Probe p = ui_probe();
    size_t tabs = p.tabs;
    press(SDLK_T, CTRL);
    p = ui_probe();
    expect(p.tabs == tabs + 1 && p.tab == tabs, "Ctrl+T opens a tab and selects it");

    press(SDLK_TAB, CTRL);
    expect(ui_probe().tab == 0, "Ctrl+Tab wraps to the first tab");
    press(SDLK_TAB, CTRL | SHIFT);
    expect(ui_probe().tab == tabs, "Ctrl+Shift+Tab wraps back to the last");
    press(SDLK_1, ALT);
    expect(ui_probe().tab == 0, "Alt+1 selects the first tab");
    press(SDLK_2, ALT);
    expect(ui_probe().tab == 1, "Alt+2 selects the second tab");

    press(SDLK_W, CTRL);
    expect(ui_probe().tabs == tabs, "Ctrl+W closes the tab");
    press(SDLK_1, ALT);
}

void keys_panes()
{
    press(SDLK_BACKSLASH, CTRL);
    Probe p = ui_probe();
    expect(p.panes == 2 && p.pane == 1, "Ctrl+\\ splits right, focusing the new pane");
    press(SDLK_BACKSLASH, CTRL | SHIFT);
    p = ui_probe();
    expect(p.panes == 3, "Ctrl+Shift+\\ splits down");
    press(SDLK_1, CTRL);
    expect(ui_probe().pane == 0, "Ctrl+1 focuses the first pane");
    press(SDLK_3, CTRL);
    expect(ui_probe().pane == 2, "Ctrl+3 focuses the third pane");

    // Closing views until each extra pane empties out of the grid.
    while (ui_probe().panes > 1)
    {
        press(SDLK_2, CTRL);
        press(SDLK_W, CTRL);
    }
    expect(ui_probe().pane == 0, "back to one pane");
}

void keys_caret()
{
    press(SDLK_HOME, CTRL);
    Probe p = ui_probe();
    expect(p.cursor == 0, "Ctrl+Home goes to the top");
    // Editable, so Right walks nibbles the way typing does.
    press(SDLK_RIGHT);
    expect(ui_probe().cursor == 0, "Right steps to the low nibble");
    press(SDLK_RIGHT);
    expect(ui_probe().cursor == 1, "...then onto the next byte");
    press(SDLK_LEFT);
    press(SDLK_DOWN);
    p = ui_probe();
    expect(p.cursor > 1 && p.anchor == p.cursor, "Down steps a row, no selection");
    size_t row = p.cursor;

    press(SDLK_RIGHT, SHIFT);
    p = ui_probe();
    expect(p.cursor == row + 1 && p.anchor == row, "Shift+Right extends the selection");
    press(SDLK_LEFT);
    p = ui_probe();
    expect(p.anchor == p.cursor, "a bare arrow drops the selection");
    press(SDLK_UP);
    press(SDLK_HOME);
    expect(ui_probe().cursor == 0, "Home goes to the row start");
}

void keys_edit()
{
    press(SDLK_HOME, CTRL);
    Probe before = ui_probe();
    type("f");
    type("f");
    Probe p = ui_probe();
    expect(p.cursor == 1, "two hex digits fill a byte and move on");
    press(SDLK_Z, CTRL);
    expect(ui_probe().cursor == 0, "Ctrl+Z undoes the byte");
    press(SDLK_Y, CTRL);
    expect(ui_probe().cursor == 1, "Ctrl+Y redoes it");
    press(SDLK_Z, CTRL);
    expect(ui_probe().size == before.size, "size untouched by an overwrite");

    press(SDLK_INSERT);
    type("0");
    type("0");
    expect(ui_probe().size == before.size + 1, "Insert switches to inserting");
    press(SDLK_BACKSPACE);
    expect(ui_probe().size == before.size, "Backspace removes the byte");
    press(SDLK_INSERT);
}

void keys_marks()
{
    press(SDLK_HOME, CTRL);
    press(SDLK_DOWN);
    size_t at = ui_probe().cursor;
    press(SDLK_B, CTRL);
    expect(ui_probe().marks == 1, "Ctrl+B sets a bookmark");
    press(SDLK_HOME, CTRL);
    type("]");
    expect(ui_probe().cursor == at, "] steps to the next bookmark");
    press(SDLK_B, CTRL);
    expect(ui_probe().marks == 0, "Ctrl+B again clears it");
}

void keys_quit()
{
    SDL_FlushEvent(SDL_EVENT_QUIT);
    press(SDLK_Q, CTRL);
    expect(SDL_HasEvent(SDL_EVENT_QUIT), "Ctrl+Q queues a quit");
    SDL_FlushEvent(SDL_EVENT_QUIT);
}

/// `nav` is zeros but for a needle at NEEDLE_A and NEEDLE_B, so finds and skips
/// have known answers; `drop` and `edit` are copies of it to open beside, `saved`
/// a destination that does not exist yet.
struct Files
{
    string nav, drop, edit, saved, fresh;
}

enum size_t NAV_SIZE = 0x1000;
enum size_t NEEDLE_A = 0x100;
enum size_t NEEDLE_B = 0x300;

Files keys_files()
{
    import std.file : mkdirRecurse, tempDir;

    string dir = buildPath(tempDir, "vddhx-keys");
    mkdirRecurse(dir);

    ubyte[] bytes = new ubyte[NAV_SIZE];
    static immutable ubyte[4] NEEDLE = [ 0xca, 0xfe, 0xba, 0xbe ];
    bytes[NEEDLE_A .. NEEDLE_A + 4] = NEEDLE;
    bytes[NEEDLE_B .. NEEDLE_B + 4] = NEEDLE;

    Files f;
    f.nav   = buildPath(dir, "nav.bin");
    f.drop  = buildPath(dir, "drop.bin");
    f.edit  = buildPath(dir, "edit.bin");
    f.saved = buildPath(dir, "saved.bin");
    f.fresh = buildPath(dir, "fresh.bin");
    write(f.nav, bytes);
    write(f.drop, bytes);
    write(f.edit, bytes);
    foreach (string gone; [ f.saved, f.fresh ])
        if (exists(gone))
            remove(gone);
    return f;
}

void keys_open(ref const(Files) f)
{
    size_t docs = ui_probe().docs;

    SDL_Event event;
    event.type = SDL_EVENT_DROP_FILE;
    event.drop.x = 400;
    event.drop.y = 300;
    event.drop.data = f.drop.toStringz;
    input_event(ctx, event);
    frame(); frame();
    Probe p = ui_probe();
    expect(p.path == f.drop && p.docs == docs + 1, "a dropped file opens");

    uiPickAuto = f.nav;
    press(SDLK_O, CTRL);
    frame();
    p = ui_probe();
    expect(p.path == f.nav && p.docs == docs + 2 && p.size == NAV_SIZE, "Ctrl+O opens the picked file");
    press(SDLK_O, CTRL);
    frame();
    p = ui_probe();
    expect(p.path == f.nav && p.docs == docs + 2, "opening it again reuses its document");
}

void keys_navigate()
{
    void goto_(string where)
    {
        press(SDLK_G, CTRL);
        type(where);
        press(SDLK_RETURN);
    }

    goto_("0x40");
    expect(ui_probe().cursor == 0x40, "Ctrl+G goes to an offset");
    goto_("+0x10");
    expect(ui_probe().cursor == 0x50, "...or relative to the caret");

    press(SDLK_END, CTRL);
    expect(ui_probe().cursor == NAV_SIZE, "Ctrl+End goes to the append slot");
    press(SDLK_HOME, CTRL);
    press(SDLK_END);
    size_t cols = ui_probe().cursor + 1;
    expect(cols > 1, "End goes to the row end");
    press(SDLK_PAGEDOWN);
    size_t page = ui_probe().cursor;
    expect(page > cols && page % cols == cols - 1, "PgDn goes down a page, same column");
    press(SDLK_PAGEUP);
    expect(ui_probe().cursor == cols - 1, "PgUp comes back");

    press(SDLK_HOME, CTRL);
    press(SDLK_RIGHT, CTRL);
    expect(ui_probe().cursor == NEEDLE_A, "Ctrl+Right skips the run of zeros");
    press(SDLK_LEFT, CTRL);
    expect(ui_probe().cursor < NEEDLE_A, "Ctrl+Left skips back");

    // Matches are selected; where the caret sits in one is the panel's business.
    size_t low() { Probe p = ui_probe(); return p.cursor < p.anchor ? p.cursor : p.anchor; }
    press(SDLK_HOME, CTRL);
    press(SDLK_F, CTRL);
    type("0xcafebabe");
    press(SDLK_RETURN);
    expect(ui_probe().omni == false && low() == NEEDLE_A, "Ctrl+F finds the first match");
    press(SDLK_N, CTRL);
    expect(low() == NEEDLE_B, "Ctrl+N finds the next");
    press(SDLK_N, CTRL);
    expect(low() == NEEDLE_A, "...wrapping round the end");
    press(SDLK_N, CTRL | SHIFT);
    expect(low() == NEEDLE_B, "Ctrl+Shift+N goes back, wrapping round the top");
}

void keys_write(ref const(Files) f)
{
    uiPickAuto = f.edit;
    press(SDLK_O, CTRL);
    frame();
    press(SDLK_HOME, CTRL);
    type("a");
    type("b");
    expect(ui_probe().edited, "typing marks the document edited");
    press(SDLK_S, CTRL);
    ubyte[] disk = cast(ubyte[]) read(f.edit);
    expect(disk.length == NAV_SIZE && disk[0] == 0xab, "Ctrl+S writes in place");
    expect(ui_probe().edited == false, "...and leaves it clean");

    press(SDLK_INSERT);
    type("c");
    type("d");
    press(SDLK_INSERT);
    press(SDLK_S, CTRL);
    disk = cast(ubyte[]) read(f.edit);
    expect(disk.length == NAV_SIZE + 1 && disk[1] == 0xcd, "an insert saves grown");

    uiPickAuto = f.saved;
    press(SDLK_S, CTRL | SHIFT);
    frame();
    expect(exists(f.saved) && read(f.saved) == disk, "Ctrl+Shift+S writes the copy");
    expect(ui_probe().path == f.saved, "...and the document moves to it");

    // A scratch buffer has nowhere to save in place, so Ctrl+S asks.
    press(SDLK_T, CTRL);
    type("1");
    type("2");
    uiPickAuto = f.fresh;
    press(SDLK_S, CTRL);
    frame();
    expect(exists(f.fresh) && cast(ubyte[]) read(f.fresh) == [ cast(ubyte) 0x12 ], "Ctrl+S on a scratch buffer saves as");
    expect(ui_probe().path == f.fresh, "...and the tab adopts the path");
}
