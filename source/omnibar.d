/// Omnibar: floating quick-open box with a filtered list; Enter takes the
/// highlighted row. The first character selects the mode:
///
///   (nothing)  open documents (tab switcher)
///   >          commands
///   :          go to offset (ddhx goto syntax)
///   /          find pattern
///   =          inspect bytes at caret position
///   @          bookmarks
///   #          structure fields
///   ?          shortcut sheet (read-only)
///
/// Computed modes hand in a single pinned row (never filtered) and rewrite it
/// as a live preview. Callers with their own matching pin all rows; '/' does
/// this for prefixes, and omni_refill writes the chosen one back.
///
/// omni_prompt opens a prefix-less mode for caller questions (bookmark name,
/// columns); the whole text is the answer. Its hint replaces the prefix sheet.
///
/// The widget owns the box, matching and selection; the caller rebuilds rows
/// for omni_mode each frame. Rows are matched against the query from the start
/// of the frame, so the list lags the text by one frame.
/// Authors: dd86k <dd@dax.moe>
module omnibar;

import ddui;
import uitext : ui_elide;

/// List navigation key bits, mapped by main.d. Above MU_KEY_* (to 1 << 14) and
/// HEX_KEY_* (to 1 << 17) so a mapping mistake can't alias.
enum
{
    OMNI_KEY_UP   = (1 << 18),      // @suppress(dscanner.style.undocumented_declaration)
    OMNI_KEY_DOWN = (1 << 19),      // @suppress(dscanner.style.undocumented_declaration)
    OMNI_KEY_PAGEUP   = (1 << 20),  // @suppress(dscanner.style.undocumented_declaration)
    OMNI_KEY_PAGEDOWN = (1 << 21),  // @suppress(dscanner.style.undocumented_declaration)
}

// Mode prefix characters.
enum char OMNI_COMMAND = '>';   // @suppress(dscanner.style.undocumented_declaration)
enum char OMNI_ADDRESS = ':';   // @suppress(dscanner.style.undocumented_declaration)
enum char OMNI_FIND    = '/';   // @suppress(dscanner.style.undocumented_declaration)
enum char OMNI_INSPECT = '=';   // @suppress(dscanner.style.undocumented_declaration)
enum char OMNI_BOOKMARK = '@';  // @suppress(dscanner.style.undocumented_declaration)
enum char OMNI_STRUCTURE = '#'; // @suppress(dscanner.style.undocumented_declaration)
enum char OMNI_HELP    = '?';   // @suppress(dscanner.style.undocumented_declaration)

/// Current mode, from the first character.
enum OmniMode
{
    switcher,   /// No prefix: caller's default (open tabs).
    command,    /// '>': run a command
    address,    /// ':': offset, parsed from the query.
    find,       /// '/': pattern, parsed from the query.
    inspect,    /// '=': one row per type.
    bookmark,   /// '@': bookmark list
    structure,  /// '#': structure list (of fields)
    help,       /// '?': help list
    prompt,     /// Raised by omni_prompt: free-text answer from user.
}

/// User action in response to omnibar.
enum OmniAction
{
    none,    /// Still open.
    accept,  /// Row taken (Enter or click); box closed.
    /// Tab: fill the row into the query (omni_refill), keep the box up. Ignored by
    /// modes without completion; never closes the box (unlike ddui focus nav).
    complete,
    /// Shift+accept: "bring it here" instead of "go to it". Meaning is per mode.
    transfer,
    dismiss, /// Lost focus, closed without taking anything.
}

/// One row; the caller fills these each frame.
struct OmniItem
{
    /// Left-aligned, elided.
    string label;
    /// Right-aligned, dimmed (path, shortcut, hint). Matched, ranked below label.
    string detail;
    /// Hidden aliases ("diff" for "Compare With..."), ranked like `detail`.
    /// Separate from the label so translations can keep English aliases.
    string keywords;
    /// Returned on accept (tab index, command code). -1: no action.
    int id = -1;
    /// Unsaved-changes dot.
    bool marked;
    /// Never filtered, sorted first. For computed modes.
    bool pinned;
}

/// Persistent state; keep across frames.
struct Omnibar
{
    /// Max visible rows; the list scrolls past this.
    int maxRows = 10;
    /// Preferred width, shrunk for narrow windows.
    int width = 560;
    /// Offset from the window top.
    int top = 12;

    private:

    // Synced to the container's open flag every frame.
    bool shown;
    // Set by omni_prompt: text is an answer, not a query.
    bool prompting;
    // Placeholder for an empty prompt; empty for none.
    string hint;
    // Dimmed word at the box's right end, set per frame by omni_tag. Empty for none.
    string tag;
    // Take focus on the frame it opens.
    bool focusWanted;
    // Text was written behind ddui; move its caret to the end.
    bool recaret;
    // Query including prefix, NUL-terminated. Edited by ddui's textbox.
    char[TEXT_MAX] text = 0;
    // Highlighted row and first visible row. Scroll follows selection moves, but
    // the wheel doesn't move the selection.
    int selected;
    int scroll;
    // Sub-row wheel remainder, so slow wheels still advance.
    int wheelAccum;
    // Matches, best first, and scores. Only grows, so steady lists don't allocate.
    OmniItem[] matches;
    int[] scores;
    // Highlighted id and box rect as of the last draw. See omni_current, omni_rect.
    int current = -1;
    mu_Rect rect;
}

/// Whether the box is open (and owns the keyboard).
bool omni_shown(ref const(Omnibar) o)
{
    return o.shown;
}

/// Open the box with `prefix` (0: default mode).
void omni_show(ref Omnibar o, char prefix = 0)
{
    o.shown = true;
    o.prompting = false;
    o.tag = null;
    o.focusWanted = true;
    o.recaret = true;
    o.selected = 0;
    o.scroll = 0;
    o.wheelAccum = 0;
    o.text[0] = prefix;
    o.text[prefix ? 1 : 0] = 0;
}

/// Open the box for a caller question, prefilled with `seed` (e.g. the current
/// bookmark name). The caller handles OmniMode.prompt rows and reads the answer
/// via omni_query or the accepted id.
///
/// `hint`: placeholder when empty, replacing the prefix sheet. Empty for none.
void omni_prompt(ref Omnibar o, string hint = null, const(char)[] seed = null)
{
    omni_show(o);
    o.prompting = true;
    o.hint = hint;

    // o.text is fixed-size, subtraction is safe.
    size_t n = seed.length < o.text.length ? seed.length : o.text.length - 1; // @suppress(dscanner.suspicious.length_subtraction)
    o.text[0 .. n] = seed[0 .. n];
    o.text[n] = 0;
}

/// Show `tag` at the right end of the query box (e.g. the find direction), hidden
/// when the query runs into it. Null for none.
void omni_tag(ref Omnibar o, string tag)
{
    o.tag = tag;
}

/// Start the highlight on `index` (for lists whose current value is a row).
/// Indexes the caller's rows as given; typing resets to the best match.
void omni_select(ref Omnibar o, int index)
{
    o.selected = index > 0 ? index : 0;
    o.scroll = 0;
}

/// Close the box; text is kept until the next omni_show.
void omni_hide(ref Omnibar o)
{
    o.shown = false;
    o.current = -1;
}

/// Set the query (after the prefix), keep the box open, caret at the end. For
/// completion modes, after taking a row closed the box.
/// `query` must not slice the box's text (omni_query does); copy it first.
void omni_refill(ref Omnibar o, const(char)[] query)
{
    o.shown = true;
    o.focusWanted = true;
    o.recaret = true;
    o.selected = 0;
    o.scroll = 0;
    o.wheelAccum = 0;

    size_t at = omni_start(o);
    size_t n = query.length;
    if (n > o.text.length - at - 1)
        n = o.text.length - at - 1;
    o.text[at .. at + n] = query[0 .. n];
    o.text[at + n] = 0;
}

/// Highlighted row id, for modes that preview as the list is walked ('#').
/// Set by omni_frame.
/// Returns: -1 when closed or empty.
int omni_current(ref const(Omnibar) o)
{
    return o.current;
}

/// Last drawn rect; empty when closed.
mu_Rect omni_rect(ref const(Omnibar) o)
{
    return o.shown ? o.rect : mu_Rect.init;
}

/// Open `prefix`'s mode, or close if already in it. Another mode's key switches.
void omni_toggle(ref Omnibar o, char prefix = 0)
{
    if (o.shown && omni_mode(o) == omni_prefix_mode(prefix))
        omni_hide(o);
    else
        omni_show(o, prefix);
}

/// Mode from the first character; prompts can't be changed by typing.
OmniMode omni_mode(ref const(Omnibar) o)
{
    return o.prompting ? OmniMode.prompt : omni_prefix_mode(o.text[0]);
}

/// Query after the prefix, leading blanks stripped (": 20" == ":20"). For
/// computed modes and acting on taken rows. Slices the box's buffer; valid until
/// the next keystroke.
const(char)[] omni_query(ref const(Omnibar) o)
{
    // Prompt text is kept as typed.
    size_t at = omni_start(o);
    if (o.prompting == false)
        while (at < o.text.length && o.text[at] == ' ')
            ++at;
    size_t end = at;
    while (end < o.text.length && o.text[end])
        ++end;
    return o.text[at .. end];
}

/// Draw and handle the box. Call once per frame after the main window ends, so
/// it's a root container on top.
///
/// `items`: rows for omni_mode, in natural order; filtered and ranked here.
/// Returns: The action (one per frame), with `chosen` the accepted id, else -1.
OmniAction omni_frame(mu_Context* ctx, ref Omnibar o, const(OmniItem)[] items,
    int width, int height, out int chosen)
{
    chosen = -1;

    // The container outlives the hidden box; sync its open flag.
    mu_Container* cnt = mu_get_container(ctx, TITLE);
    cnt.open = o.shown;
    if (o.shown == false)
        return OmniAction.none;

    const(OmniItem)[] rows = omni_filter(o, items);
    int count = cast(int) rows.length;

    mu_Font font = ctx.style.font;
    int pad  = ctx.style.padding;
    int th   = ctx.text_height(font);
    int boxH = th + BOX_PAD * 2;
    int rowH = th + ROW_PAD * 2;
    // Keep one row for the "no matches" notice so the box doesn't look broken.
    int visible = count ? mu_min(count, o.maxRows) : 1;

    // Apply last frame's wheel as whole rows before the window opens: ddui folds
    // the scroll offset into the layout and would shift the box for a frame.
    if (cnt.scroll.y != 0)
    {
        o.wheelAccum += cnt.scroll.y;
        cnt.scroll.y = 0;
    }
    cnt.scroll.x = 0; // no horizontal scroll; ddui doesn't clamp x
    int wheelRows = o.wheelAccum / rowH;
    if (wheelRows != 0)
    {
        o.scroll += wheelRows;
        o.wheelAccum -= wheelRows * rowH;
    }

    int w = mu_clamp(width - MARGIN * 2, MIN_WIDTH, o.width);
    int h = pad * 2 + boxH + ctx.style.spacing + visible * rowH;

    // Every frame: list size and window size change.
    cnt.rect = mu_Rect((width - w) / 2, o.top, w, h);
    o.rect = cnt.rect;
    if (o.focusWanted)
        mu_bring_to_front(ctx, cnt);

    if (mu_begin_window_ex(ctx, TITLE, cnt.rect,
            MU_OPT_NOTITLE | MU_OPT_NORESIZE | MU_OPT_NOSCROLL | MU_OPT_CLOSED) == 0)
        return OmniAction.none;

    static immutable int[1] full = [ -1 ];

    // Id taken manually (not via mu_textbox) so focus can be set on the opening
    // frame, before mu_update_control.
    mu_layout_row(ctx, 1, full.ptr, boxH);
    mu_Rect box = mu_layout_next(ctx);
    mu_Id qid = mu_get_id(ctx, QUERY.ptr, cast(int) QUERY.length);
    // ddui only repositions the caret on focus change; move it after external
    // writes.
    if (o.recaret)
    {
        o.recaret = false;
        ctx.caret_id = qid;
        ctx.caret = ctx.select_anchor = omni_textlen(o);
    }
    bool raised = o.focusWanted;
    if (raised)
    {
        o.focusWanted = false;
        mu_set_focus(ctx, qid);
    }
    int res = mu_textbox_raw(ctx, o.text.ptr, cast(int) o.text.length, qid, box, 0);
    // Opened by a click (menu item): ddui drops focus from controls clicked
    // outside, which would read as a dismissal below and close the box instantly.
    if (raised && ctx.focus != qid)
        mu_set_focus(ctx, qid);
    if (res & MU_RES_CHANGE)
    {
        // New list: reset the highlight to the best row.
        o.selected = 0;
        o.scroll   = 0;
        o.wheelAccum = 0;
    }

    // Prompts show their own hint instead of the prefix sheet.
    string hint = o.prompting ? o.hint : HINT;
    if (o.text[0] == 0 && hint.length)
        mu_draw_text(ctx, font, hint,
            mu_Vec2(box.x + pad + HINT_INSET, box.y + (box.h - th) / 2), OMNI_HINT);
    if (o.tag.length)
    {
        int tw = ctx.text_width(font, o.tag.ptr, cast(int) o.tag.length);
        int qw = ctx.text_width(font, o.text.ptr, cast(int) omni_textlen(o));
        if (pad + qw + ROW_GAP + tw + pad <= box.w)
            mu_draw_text(ctx, font, o.tag,
                mu_Vec2(box.x + box.w - pad - tw, box.y + (box.h - th) / 2), OMNI_DIM);
    }

    // Clamp the selection to a shrunken list, then step. Arrows wrap.
    if (o.selected >= count)
        o.selected = count ? count - 1 : 0;
    bool moved;
    if (count && ctx.key_pressed & (OMNI_KEY_UP | OMNI_KEY_DOWN))
    {
        int step = (ctx.key_pressed & OMNI_KEY_UP) ? count - 1 : 1;
        o.selected = (o.selected + step) % count;
        moved = true;
    }
    // Paging clamps instead of wrapping.
    if (count && ctx.key_pressed & (OMNI_KEY_PAGEUP | OMNI_KEY_PAGEDOWN))
    {
        int step = (ctx.key_pressed & OMNI_KEY_PAGEUP) ? -visible : visible;
        o.selected = mu_clamp(o.selected + step, 0, count - 1);
        moved = true;
    }
    o.current = count ? rows[o.selected].id : -1;

    mu_layout_row(ctx, 1, full.ptr, visible * rowH);
    mu_Rect list = mu_layout_next(ctx);
    mu_draw_rect(ctx, list, OMNI_LIST);

    // NOSCROLL box isn't a wheel target; set it manually while hovered so the
    // grid below doesn't scroll. Applied at frame end, read above.
    if (mu_mouse_over(ctx, cnt.body_))
        ctx.scroll_target = cnt;

    // Scroll minimally to follow the selection, only when it moved; wheel
    // scrolling is left alone.
    if (moved)
    {
        if (o.scroll > o.selected)
            o.scroll = o.selected;
        if (o.scroll < o.selected - visible + 1)
            o.scroll = o.selected - visible + 1;
    }
    o.scroll = mu_clamp(o.scroll, 0, mu_max(0, count - visible));

    // Scrollbar room only when the list overflows.
    int barW = count > visible ? BAR_W + BAR_INSET * 2 : 0;

    // Shift chooses accept vs transfer, for Enter and click alike.
    OmniAction taken = (ctx.key_down & MU_KEY_SHIFT) ? OmniAction.transfer : OmniAction.accept;
    OmniAction action = (res & MU_RES_SUBMIT) && count ? taken : OmniAction.none;

    // Swallow Tab: ddui focus nav would leave the box and dismiss it.
    if (ctx.key_pressed & MU_KEY_TAB)
    {
        ctx.key_pressed &= ~MU_KEY_TAB;
        if (count && action == OmniAction.none)
            action = OmniAction.complete;
    }

    if (count == 0)
    {
        mu_draw_text(ctx, font, EMPTY,
            mu_Vec2(list.x + ROW_INSET, list.y + (rowH - th) / 2), OMNI_HINT);
    }
    else foreach (int k; 0 .. visible)
    {
        int i = o.scroll + k;
        mu_Rect r = mu_Rect(list.x, list.y + k * rowH, list.w, rowH);

        // Control only for hover and click.
        mu_Id rid = mu_get_id(ctx, &i, i.sizeof);
        mu_update_control(ctx, rid, r, 0);
        if (ctx.mouse_pressed == MU_MOUSE_LEFT && ctx.focus == rid)
        {
            o.selected = i;
            action = taken;
        }

        bool active = i == o.selected;
        if (active)
        {
            mu_draw_rect(ctx, r, OMNI_ROW_SEL);
            mu_draw_rect(ctx, mu_Rect(r.x, r.y, ACCENT_W, r.h), OMNI_ACCENT);
        }
        else if (ctx.hover == rid)
            mu_draw_rect(ctx, r, OMNI_ROW_HOVER);

        // Text stops before the scrollbar; the row stays full width for clicks.
        omni_row(ctx, rows[i], mu_Rect(r.x, r.y, r.w - barW, r.h));
    }

    if (barW)
        omni_scrollbar(ctx, mu_Rect(list.x + list.w - BAR_INSET - BAR_W, list.y,
            BAR_W, list.h), o.scroll, visible, count);

    // Losing focus (click elsewhere, menu) dismisses. Enter is handled above.
    if (action == OmniAction.none && ctx.focus != qid)
        action = OmniAction.dismiss;

    if (action != OmniAction.none)
    {
        if (action != OmniAction.dismiss)
            chosen = rows[o.selected].id;
        // Complete keeps the box open.
        if (action != OmniAction.complete)
            omni_hide(o);
    }

    mu_end_window(ctx);
    return action;
}

private:

/// Window title and container key. Not drawn (MU_OPT_NOTITLE).
enum string TITLE = "omnibar";
/// Query box id, scoped under the window.
enum string QUERY = "query";

/// Placeholder, also shown when nothing matches.
enum string HINT  = "tabs   >  commands   :  go to   /  find   =  inspect   @  bookmarks   ?  keys";
enum string EMPTY = "no matches";

/// Query buffer size; fits long paths.
enum size_t TEXT_MAX = 192;

enum mu_Color OMNI_LIST      = mu_Color( 30,  30,  38, 255); // list background
enum mu_Color OMNI_ROW_SEL   = mu_Color( 52,  72, 110, 255);
enum mu_Color OMNI_ROW_HOVER = mu_Color( 62,  62,  74, 255);
enum mu_Color OMNI_ACCENT    = mu_Color(110, 170, 255, 255); // selected row edge, unsaved dot
enum mu_Color OMNI_DIM       = mu_Color(150, 150, 165, 255); // detail column
enum mu_Color OMNI_HINT      = mu_Color(120, 120, 135, 255); // placeholder, empty notice
enum mu_Color OMNI_BAR_TRACK = mu_Color( 44,  44,  54, 255);
enum mu_Color OMNI_BAR_THUMB = mu_Color( 90, 110, 150, 255);

enum int MARGIN     = 40; // either side of the box
enum int MIN_WIDTH  = 240;
enum int BOX_PAD    = 6;    /// query box padding around one line
enum int ROW_PAD    = 4;    /// per list row
enum int ROW_INSET  = 10;   /// row left/right inset
enum int ROW_GAP    = 10;   /// between label and detail
enum int ACCENT_W   = 2;    /// selected row left edge
enum int ROW_DOT    = 6;    /// unsaved dot size
enum int HINT_INSET = 4;    /// placeholder offset past the caret
enum int BAR_W      = 3;    /// scrollbar width
enum int BAR_INSET  = 3;    /// either side of the scrollbar
enum int BAR_MIN    = 12;   /// min thumb height
enum int DETAIL_SHARE = 2;  /// Detail column may take up to 1/n of the row before eliding.

/// Query start: past the prefix, if the mode has one.
size_t omni_start(ref const(Omnibar) o)
{
    if (o.prompting)
        return 0;
    return omni_prefix_mode(o.text[0]) == OmniMode.switcher ? 0 : 1;
}

/// Text length up to the terminator.
size_t omni_textlen(ref const(Omnibar) o)
{
    size_t n;
    while (n < o.text.length && o.text[n])
        ++n;
    return n;
}

/// The mode a prefix character opens.
OmniMode omni_prefix_mode(char prefix)
{
    switch (prefix)
    {
    case OMNI_COMMAND:      return OmniMode.command;
    case OMNI_ADDRESS:      return OmniMode.address;
    case OMNI_FIND:         return OmniMode.find;
    case OMNI_INSPECT:      return OmniMode.inspect;
    case OMNI_BOOKMARK:     return OmniMode.bookmark;
    case OMNI_STRUCTURE:    return OmniMode.structure;
    case OMNI_HELP:         return OmniMode.help;
    default:                return OmniMode.switcher;
    }
}

/// Filter `items` by the query, best first; stable for equal scores.
/// Returns: A slice of the box's storage, valid until the next call.
const(OmniItem)[] omni_filter(ref Omnibar o, const(OmniItem)[] items)
{
    const(char)[] query = omni_query(o);
    if (o.matches.length < items.length)
    {
        o.matches.length = items.length;
        o.scores.length  = items.length;
    }

    size_t n;
    foreach (ref const(OmniItem) it; items)
    {
        int score = void;
        if (it.pinned)
            score = int.max; // always kept, on top
        else
        {
            score = omni_score(it.label, query);
            // Detail and alias hits count at half weight, so label matches rank first.
            int alt = omni_score(it.detail, query);
            if (alt > 0 && alt / 2 > score)
                score = alt / 2;
            int key = omni_score(it.keywords, query);
            if (key > 0 && key / 2 > score)
                score = key / 2;
        }
        if (score < 0)
            continue;

        // Insertion sort: lists are small, and it's stable.
        size_t at = n;
        while (at > 0 && o.scores[at - 1] < score)
        {
            o.scores[at]  = o.scores[at - 1];
            o.matches[at] = o.matches[at - 1];
            --at;
        }
        o.scores[at]  = score;
        o.matches[at] = it;
        ++n;
    }
    return o.matches[0 .. n];
}

/// Fuzzy subsequence score of `query` in `text`. Higher is better; -1 drops it;
/// an empty query scores 0 for everything.
///
/// Adjacent runs and word starts score highest ("sa" ranks "Save As..." above
/// "Close Tab"). ASCII case folding only.
int omni_score(const(char)[] text, const(char)[] query)
{
    if (query.length == 0)
        return 0;
    if (text.length == 0)
        return -1;

    int score;
    size_t at;
    bool run; // previous query char matched the previous text char
    foreach (char q; query)
    {
        char want = omni_lower(q);
        while (at < text.length && omni_lower(text[at]) != want)
        {
            ++at;
            run = false;
        }
        if (at >= text.length)
            return -1;

        ++score;
        if (run)
            score += RUN_BONUS;
        if (at == 0 || omni_boundary(text[at - 1]))
            score += WORD_BONUS;
        ++at;
        run = true;
    }
    return score;
}

enum int RUN_BONUS  = 4; // adjacent to the previous match
enum int WORD_BONUS = 6; // word start

char omni_lower(char c)
{
    return c >= 'A' && c <= 'Z' ? cast(char)(c + 32) : c;
}

/// Whether the character after `c` starts a word.
bool omni_boundary(char c)
{
    return c == ' ' || c == '_' || c == '-' || c == '.' ||
           c == '/' || c == '\\';
}

unittest
{
    assert(omni_score("main.d", "") == 0);       // empty query keeps everything
    assert(omni_score("", "x") == -1);           // empty row matches nothing
    assert(omni_score("main.d", "md") > 0);      // subsequence
    assert(omni_score("main.d", "dm") == -1);    // in order
    assert(omni_score("main.d", "xyz") == -1);
    assert(omni_score("README", "rd") > 0);      // case-insensitive
    assert(omni_score("readme", "RD") > 0);

    // Adjacent beats scattered; word start beats mid-word.
    assert(omni_score("readme", "rea") > omni_score("readme", "rdm"));
    assert(omni_score("Save As...", "sa") > omni_score("Close Tab", "sa"));
    assert(omni_score("save.bin", "s") > omni_score("class", "s"));
}

/// Aliases find rows but don't outrank rows named for the query.
unittest
{
    static immutable OmniItem[] rows = [
        OmniItem("Compare With...", "",       "diff against", 1),
        OmniItem("Find...",         "Ctrl+F", "search",       2),
        OmniItem("Split Pane Down", "",       "hsplit",       3),
        OmniItem("Search Marks",    "",       "",             4),
    ];

    Omnibar o;
    void type(string q)
    {
        o.text[0 .. q.length] = q;
        o.text[q.length] = 0;
    }

    type("diff");
    const(OmniItem)[] got = omni_filter(o, rows);
    assert(got.length == 1);
    assert(got[0].id == 1);

    // Alias matches only its row.
    type("hsplit");
    got = omni_filter(o, rows);
    assert(got.length == 1);
    assert(got[0].id == 3);

    // Label match ("Search Marks") beats alias match ("Find...").
    type("search");
    got = omni_filter(o, rows);
    assert(got.length == 2);
    assert(got[0].id == 4); // label
    assert(got[1].id == 2); // alias

    // Aliases aren't shown.
    type("diff");
    got = omni_filter(o, rows);
    assert(got[0].label == "Compare With...");

    // No aliases: unaffected.
    static immutable OmniItem[] bare = [ OmniItem("Quit", "Ctrl+Q", null, 9) ];
    type("quit");
    got = omni_filter(o, bare);
    assert(got.length == 1);
    type("zzz");
    assert(omni_filter(o, bare).length == 0);
}

/// Read-only scrollbar (the list is keyboard-driven).
void omni_scrollbar(mu_Context* ctx, mu_Rect track, int scroll, int visible, int count)
{
    mu_draw_rect(ctx, track, OMNI_BAR_TRACK);

    // Min height so long lists still show a thumb.
    int thumbH = mu_clamp(visible * track.h / count, BAR_MIN, track.h);
    int travel = track.h - thumbH;
    int last   = count - visible;
    int y = track.y + (last > 0 ? scroll * travel / last : 0);
    mu_draw_rect(ctx, mu_Rect(track.x, y, track.w, thumbH), OMNI_BAR_THUMB);
}

/// Draw a row: label left, elided after the detail column and dot.
void omni_row(mu_Context* ctx, ref const(OmniItem) it, mu_Rect r)
{
    mu_Font font = ctx.style.font;
    int th = ctx.text_height(font);
    int y  = r.y + (r.h - th) / 2;
    int right = r.x + r.w - ROW_INSET;

    // Detail is elided first so long paths don't crowd out the label.
    char[256] dscratch = void;
    string detail = ui_elide(ctx, it.detail, r.w / DETAIL_SHARE, dscratch);
    int detailW = detail.length ?
        ctx.text_width(font, detail.ptr, cast(int) detail.length) : 0;
    if (detailW)
    {
        mu_draw_text(ctx, font, detail, mu_Vec2(right - detailW, y), OMNI_DIM);
        right -= detailW + ROW_GAP;
    }

    if (it.marked)
    {
        mu_draw_rect(ctx, mu_Rect(right - ROW_DOT, y + (th - ROW_DOT) / 2,
            ROW_DOT, ROW_DOT), OMNI_ACCENT);
        right -= ROW_DOT + ROW_GAP;
    }

    char[256] lscratch = void;
    int labelX = r.x + ROW_INSET;
    string label = ui_elide(ctx, it.label, right - labelX, lscratch);
    if (label.length)
        mu_draw_text(ctx, font, label, mu_Vec2(labelX, y),
            ctx.style.colors[MU_COLOR_TEXT]);
}
