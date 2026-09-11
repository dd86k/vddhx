/// Omnibar: one box that finds everything.
///
/// A floating input over the window, with a list of rows under it that narrows
/// as you type; Enter takes the highlighted row. The first character picks what
/// the list holds, the way a certain editor's quick-open does it:
///
///   (nothing)  the open documents, to switch tab
///   >          commands, the actions the menus carry
///   :          an offset to go to, ddhx's own goto syntax
///   /          a pattern to find in the document
///   =          the bytes at the caret, read as every type they could be
///   @          the document's bookmarks
///   #          the fields the layout found, to go to one
///   ?          the shortcut sheet, there to be read rather than run
///
/// A mode whose answer is computed rather than picked hands in a single pinned
/// row instead of a list: the query never filters it out, so the caller can keep
/// rewriting it into a live preview of what taking it would do.
///
/// One mode has no prefix to reach it by: omni_prompt raises the box on a question
/// the caller asked (naming a bookmark), where the text is an answer rather than a
/// search and every character of it is the user's, first one included.
///
/// The widget owns the box, the matching and the selection; the caller owns the
/// rows, asking omni_mode what the box is after and rebuilding the candidates for
/// that mode each frame. Those rows are matched against the query as it stood at
/// the start of the frame, since the box only reads this frame's keystrokes when
/// it draws, leaving the list one frame behind the text.
/// Authors: dd86k <dd@dax.moe>
module omnibar;

import ddui;
import uitext : ui_elide;

/// Extra ddui key bits for the omnibar's list, which main.d maps the arrows and
/// paging keys onto.
/// ddui's own MU_KEY_* stop at (1 << 14) and the hex panel's carry on to
/// (1 << 17), so these sit above both: the two never take keys in the same frame,
/// but distinct bits mean a mapping mistake cannot quietly mean something else.
enum
{
    OMNI_KEY_UP   = (1 << 18),
    OMNI_KEY_DOWN = (1 << 19),
    OMNI_KEY_PAGEUP   = (1 << 20),
    OMNI_KEY_PAGEDOWN = (1 << 21),
}

/// The character that opens each mode, typed as the first thing in the box.
enum char OMNI_COMMAND = '>';
/// Ditto.
enum char OMNI_ADDRESS = ':';
/// Ditto.
enum char OMNI_FIND    = '/';
/// Ditto.
enum char OMNI_INSPECT = '=';
/// Ditto.
enum char OMNI_BOOKMARK = '@';
/// Ditto.
enum char OMNI_STRUCTURE = '#';
/// Ditto.
enum char OMNI_HELP    = '?';

/// What the box is currently searching, as told by its first character.
enum OmniMode
{
    switcher, /// No prefix: whatever the caller offers by default (the open tabs).
    command,  /// '>': runnable actions.
    address,  /// ':': a document offset, read out of the query itself.
    find,     /// '/': a byte pattern, likewise read out of the query.
    inspect,  /// '=': the bytes at the caret, one row per type.
    bookmark, /// '@': the document's bookmarks.
    /// '#': the layout's fields. Apart from the bookmarks for the same reason the
    /// spans are dropped on an edit and the marks are not: one is what the user said
    /// about those bytes, the other what a parser concluded from them.
    structure,
    help,     /// '?': the shortcut sheet.
    prompt,   /// No prefix, raised by omni_prompt: free text answering a question.
}

/// What the user did to the box this frame.
enum OmniAction
{
    none,    /// Still open, nothing settled.
    accept,  /// A row was taken (Enter, or a click on it). The box has closed.
    /// Ditto, with Shift held: "take this row, and bring it to me" rather than
    /// "go to it". The box only reports which it was; what the difference means -
    /// or that there is none - is the caller's to decide, mode by mode.
    transfer,
    dismiss, /// The box lost focus and closed without taking anything.
}

/// One row. The caller fills a slice of these each frame for the current mode.
struct OmniItem
{
    /// Primary text, left-aligned. Elided when the row is too narrow for it.
    string label;
    /// Secondary text, right-aligned and dimmed: a path, a shortcut, a hint.
    /// Also matched against the query, though it ranks below a label match.
    string detail;
    /// Extra terms the row answers to, matched but never drawn: the words a user
    /// reaches for that are not what the row is called ("diff" for a row labelled
    /// "Compare With..."). Ranked with the detail column, below a label match, so
    /// an alias only decides between rows that would otherwise not be there at all.
    ///
    /// Kept apart from the label so the two can differ in kind: a translated list
    /// would keep its English aliases here and go on answering to them.
    string keywords;
    /// Handed back to the caller when the row is accepted; its meaning is the
    /// caller's (a tab index, a command code). -1 for a row that does nothing.
    int id = -1;
    /// Draw the unsaved-changes dot, as the tab strip does.
    bool marked;
    /// A row the query never filters out, sorted above the rest, for a mode whose
    /// answer is computed rather than picked.
    bool pinned;
}

/// Persistent omnibar state; keep one across frames.
struct Omnibar
{
    /// Rows on screen at most. Past this the list scrolls under the selection.
    int maxRows = 10;
    /// Width the box asks for, held back when the window is narrower.
    int width = 560;
    /// Pixels between the window's top edge and the box.
    int top = 12;

    private:

    // The container's open flag follows this every frame.
    bool shown;
    // Raised by omni_prompt: the text is an answer, not a query.
    bool prompting;
    // Set the frame the box is raised, so it takes the keyboard without a click.
    bool focusWanted;
    // The query, NUL-terminated, prefix character and all. ddui's textbox owns the
    // editing; this is where it keeps the text.
    char[TEXT_MAX] text = 0;
    // Highlighted row, and the first row on screen when the list overflows.
    int selected;
    int scroll;
    // Rows that matched, best first, and their scores. Only ever grown, so a
    // steady list costs no allocation once it has been drawn once.
    OmniItem[] matches;
    int[] scores;
}

/// Whether the box is up. main.d asks this to know who owns the keyboard.
bool omni_shown(ref const(Omnibar) o)
{
    return o.shown;
}

/// Raise the box, empty but for `prefix` (0 for the default mode).
void omni_show(ref Omnibar o, char prefix = 0)
{
    o.shown = true;
    o.prompting = false;
    o.focusWanted = true;
    o.selected = 0;
    o.scroll = 0;
    o.text[0] = prefix;
    o.text[prefix ? 1 : 0] = 0;
}

/// Raise the box on a question of the caller's, with `seed` already typed into it
/// (the name a bookmark carries, so renaming starts from it rather than from
/// nothing). The caller recognises the mode as OmniMode.prompt, hands in the one
/// pinned row that reads back what taking the answer would do, and reads the answer
/// off omni_query when the row is accepted.
void omni_prompt(ref Omnibar o, const(char)[] seed = null)
{
    omni_show(o);
    o.prompting = true;

    size_t n = seed.length < o.text.length ? seed.length : o.text.length - 1;
    o.text[0 .. n] = seed[0 .. n];
    o.text[n] = 0;
}

/// Put the box away, keeping nothing but the text (the next omni_show clears it).
void omni_hide(ref Omnibar o)
{
    o.shown = false;
}

/// Raise the box on `prefix`'s mode, or put it away when it is already showing
/// that mode. So the key that opens a mode closes it, while the key for another
/// mode switches to it rather than closing the box out from under the user.
void omni_toggle(ref Omnibar o, char prefix = 0)
{
    if (o.shown && omni_mode(o) == omni_prefix_mode(prefix))
        omni_hide(o);
    else
        omni_show(o, prefix);
}

/// What the box is searching, from the character it starts with - unless it was
/// raised on a question, which no character of the answer can change.
OmniMode omni_mode(ref const(Omnibar) o)
{
    return o.prompting ? OmniMode.prompt : omni_prefix_mode(o.text[0]);
}

/// The text being searched for: everything past the mode's prefix character, with
/// the blanks after it dropped so ": 20" finds what ":20" does.
///
/// For the modes that compute their row from the query, and for acting on a row
/// once it is taken; the box does its own matching, so a list mode has no reason
/// to read this. The slice is into the box's own buffer, good until the next
/// keystroke reaches it.
const(char)[] omni_query(ref const(Omnibar) o)
{
    // A prompt's text is taken whole: it is a name the user typed, and trimming it
    // would be this box deciding what a name may start with.
    size_t at;
    if (o.prompting == false)
    {
        at = omni_prefix_mode(o.text[0]) == OmniMode.switcher ? 0 : 1;
        while (at < o.text.length && o.text[at] == ' ')
            ++at;
    }
    size_t end = at;
    while (end < o.text.length && o.text[end])
        ++end;
    return o.text[at .. end];
}

/// Draw the box and drive it. Call once per frame from the frame builder, after
/// the main window is ended, so it lands as its own root container on top.
///
/// `items` are the candidate rows for the mode omni_mode reports, in natural
/// order; they are matched against the query, ranked, and the best drawn under the
/// box, the selection holding inside the list as it grows and shrinks.
/// Returns: What the user did this frame - only one row can be taken per frame -
///          with `chosen` the accepted row's id, else -1.
OmniAction omni_frame(mu_Context* ctx, ref Omnibar o, const(OmniItem)[] items,
    int width, int height, out int chosen)
{
    chosen = -1;

    // The container outlives a hidden box, so its open flag is what decides
    // whether ddui draws it: keep the two in step every frame.
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
    // With nothing matched the list keeps one row's room for the notice: a box
    // collapsing to the input alone reads as broken rather than as an answer.
    int visible = count ? mu_min(count, o.maxRows) : 1;

    int w = mu_clamp(width - MARGIN * 2, MIN_WIDTH, o.width);
    int h = pad * 2 + boxH + ctx.style.spacing + visible * rowH;

    // Placed every frame: the list grows and shrinks as the query narrows it, and
    // the window can be resized under it.
    cnt.rect = mu_Rect((width - w) / 2, o.top, w, h);
    if (o.focusWanted)
        mu_bring_to_front(ctx, cnt);

    if (mu_begin_window_ex(ctx, TITLE, cnt.rect,
            MU_OPT_NOTITLE | MU_OPT_NORESIZE | MU_OPT_NOSCROLL | MU_OPT_CLOSED) == 0)
        return OmniAction.none;

    static immutable int[1] full = [ -1 ];

    // The query box's id is taken by hand rather than through mu_textbox so focus
    // can be handed to it the frame the omnibar opens - before mu_update_control,
    // which is what keeps ddui from dropping that focus at frame end.
    mu_layout_row(ctx, 1, full.ptr, boxH);
    mu_Rect box = mu_layout_next(ctx);
    mu_Id qid = mu_get_id(ctx, QUERY.ptr, cast(int) QUERY.length);
    bool raised = o.focusWanted;
    if (raised)
    {
        o.focusWanted = false;
        mu_set_focus(ctx, qid);
    }
    int res = mu_textbox_raw(ctx, o.text.ptr, cast(int) o.text.length, qid, box, 0);
    // A box raised by a mouse click - a menu item - runs first on the frame of that
    // very click, and ddui hands focus away from a control pressed outside of. The
    // dismissal below would then read the opening click as the user clicking away,
    // so the box would blink and be gone. The click that opened it is not a click
    // outside it.
    if (raised && ctx.focus != qid)
        mu_set_focus(ctx, qid);
    if (res & MU_RES_CHANGE)
    {
        // Next frame's list is a different list, so put the highlight back on its
        // best row rather than on whatever index it held.
        o.selected = 0;
        o.scroll   = 0;
    }

    // The prefix sheet would be an answer to a question nobody asked while the box
    // is holding a prompt; that row's own text says what is wanted there.
    if (o.text[0] == 0 && o.prompting == false)
        mu_draw_text(ctx, font, HINT,
            mu_Vec2(box.x + pad + HINT_INSET, box.y + (box.h - th) / 2), OMNI_HINT);

    // Hold the selection inside a list that shrank under it, then step it. Up and
    // down wrap, so a short list is a ring rather than a dead end.
    if (o.selected >= count)
        o.selected = count ? count - 1 : 0;
    if (count && ctx.key_pressed & (OMNI_KEY_UP | OMNI_KEY_DOWN))
    {
        int step = (ctx.key_pressed & OMNI_KEY_UP) ? count - 1 : 1;
        o.selected = (o.selected + step) % count;
    }
    // Paging clamps where the arrows wrap: a page is a distance rather than a
    // step, and landing at the far end of the list from running off one edge
    // reads as the list having jumped rather than moved.
    if (count && ctx.key_pressed & (OMNI_KEY_PAGEUP | OMNI_KEY_PAGEDOWN))
    {
        int step = (ctx.key_pressed & OMNI_KEY_PAGEUP) ? -visible : visible;
        o.selected = mu_clamp(o.selected + step, 0, count - 1);
    }
    // Scroll the least that brings the selection back into view.
    if (o.scroll > o.selected)
        o.scroll = o.selected;
    if (o.scroll < o.selected - visible + 1)
        o.scroll = o.selected - visible + 1;
    o.scroll = mu_clamp(o.scroll, 0, mu_max(0, count - visible));

    mu_layout_row(ctx, 1, full.ptr, visible * rowH);
    mu_Rect list = mu_layout_next(ctx);
    mu_draw_rect(ctx, list, OMNI_LIST);

    // Room for the position indicator, and only when the list runs past its
    // window: under a list shown whole a bar would say nothing.
    int barW = count > visible ? BAR_W + BAR_INSET * 2 : 0;

    // Shift decides which of the two takings it is, read at the moment the row goes
    // rather than stored: the same modifier answers for Enter and for a click, so
    // the pointer is not the second-class way in.
    OmniAction taken = (ctx.key_down & MU_KEY_SHIFT) ? OmniAction.transfer : OmniAction.accept;
    OmniAction action = (res & MU_RES_SUBMIT) && count ? taken : OmniAction.none;

    if (count == 0)
    {
        mu_draw_text(ctx, font, EMPTY,
            mu_Vec2(list.x + ROW_INSET, list.y + (rowH - th) / 2), OMNI_HINT);
    }
    else foreach (int k; 0 .. visible)
    {
        int i = o.scroll + k;
        mu_Rect r = mu_Rect(list.x, list.y + k * rowH, list.w, rowH);

        // A row is a control only so it can be hovered and clicked.
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

        // The text stops short of the bar, so a long label elides rather than
        // running under it; the row itself stays full width to click and highlight.
        omni_row(ctx, rows[i], mu_Rect(r.x, r.y, r.w - barW, r.h));
    }

    if (barW)
        omni_scrollbar(ctx, mu_Rect(list.x + list.w - BAR_INSET - BAR_W, list.y,
            BAR_W, list.h), o.scroll, visible, count);

    // Anything that takes focus from the query box - a click on the grid behind, a
    // menu - means the user is done with the omnibar. Enter clears the focus
    // itself, so that route is settled above.
    if (action == OmniAction.none && ctx.focus != qid)
        action = OmniAction.dismiss;

    if (action != OmniAction.none)
    {
        if (action != OmniAction.dismiss)
            chosen = rows[o.selected].id;
        omni_hide(o);
    }

    mu_end_window(ctx);
    return action;
}

private:

/// Window title, and the key ddui pools the container under. Never drawn: the
/// window is raised with MU_OPT_NOTITLE.
enum string TITLE = "omnibar";
/// Id string for the query box, scoped under the window.
enum string QUERY = "query";

/// Placeholder, and what stands in for the list when nothing matched.
enum string HINT  = "tabs   >  commands   :  go to   /  find   =  inspect   @  bookmarks   ?  keys";
/// Ditto.
enum string EMPTY = "no matches";

/// Query buffer size. Long enough for any path a switcher search would spell out.
enum size_t TEXT_MAX = 192;

// The window frame itself is ddui's own; these dress what sits inside it.
enum mu_Color OMNI_LIST      = mu_Color( 30,  30,  38, 255); // bed behind the rows
enum mu_Color OMNI_ROW_SEL   = mu_Color( 52,  72, 110, 255);
enum mu_Color OMNI_ROW_HOVER = mu_Color( 62,  62,  74, 255);
enum mu_Color OMNI_ACCENT    = mu_Color(110, 170, 255, 255); // selected row's edge, unsaved dot
enum mu_Color OMNI_DIM       = mu_Color(150, 150, 165, 255); // detail column
enum mu_Color OMNI_HINT      = mu_Color(120, 120, 135, 255); // placeholder, empty notice
enum mu_Color OMNI_BAR_TRACK = mu_Color( 44,  44,  54, 255);
enum mu_Color OMNI_BAR_THUMB = mu_Color( 90, 110, 150, 255);

enum int MARGIN     = 40; // pixels kept clear either side of the box
enum int MIN_WIDTH  = 240;
enum int BOX_PAD    = 6;  // query box height either side of one text line
enum int ROW_PAD    = 4;  // ditto, per list row
enum int ROW_INSET  = 10; // a row's left and right insets
enum int ROW_GAP    = 10; // kept clear between the label and what follows it
enum int ACCENT_W   = 2;  // width of the selected row's left edge
enum int ROW_DOT    = 6;  // side of the unsaved-changes dot
enum int HINT_INSET = 4;  // placeholder's offset past the caret
enum int BAR_W      = 3;  // position indicator's width
enum int BAR_INSET  = 3;  // kept clear either side of it
enum int BAR_MIN    = 12; // shortest thumb, so a long list still shows one
/// Fraction of a row the detail column may take before it is elided too.
enum int DETAIL_SHARE = 2;

/// The mode a prefix character opens.
OmniMode omni_prefix_mode(char prefix)
{
    switch (prefix)
    {
    case OMNI_COMMAND: return OmniMode.command;
    case OMNI_ADDRESS: return OmniMode.address;
    case OMNI_FIND:    return OmniMode.find;
    case OMNI_INSPECT: return OmniMode.inspect;
    case OMNI_BOOKMARK: return OmniMode.bookmark;
    case OMNI_STRUCTURE: return OmniMode.structure;
    case OMNI_HELP:    return OmniMode.help;
    default:           return OmniMode.switcher;
    }
}

/// Cut `items` down to what matches the query, best match first. Equal scores
/// keep the caller's order, so an unfiltered list reads in its natural order.
/// Returns: A slice of the box's own storage, live until the next call.
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
            score = int.max; // stays, and stays on top, whatever was typed
        else
        {
            score = omni_score(it.label, query);
            // A hit in the detail column counts too - typing a directory should
            // find the file under it - but at half weight, so a name match
            // outranks it. Aliases are weighed the same way, being there to find a
            // row its own name would have hidden, not to reorder the ones it found.
            int alt = omni_score(it.detail, query);
            if (alt > 0 && alt / 2 > score)
                score = alt / 2;
            int key = omni_score(it.keywords, query);
            if (key > 0 && key / 2 > score)
                score = key / 2;
        }
        if (score < 0)
            continue;

        // Insertion sort: the lists are a handful of rows, and it is stable.
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

/// Score `text` against `query`: how well the query's characters, in that order
/// but not necessarily together, pick their way through the text. Higher is
/// better; -1 drops the row, and an empty query matches everything flatly.
///
/// Runs of adjacent characters and matches at the start of a word count for most,
/// which is what makes "sa" find "Save As..." ahead of "Close Tab". Case folding
/// is ASCII-only, this ranking file names and command labels.
int omni_score(const(char)[] text, const(char)[] query)
{
    if (query.length == 0)
        return 0;
    if (text.length == 0)
        return -1;

    int score;
    size_t at;
    bool run; // the previous query character matched the character just before
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

enum int RUN_BONUS  = 4; // matched right after the previous match
enum int WORD_BONUS = 6; // matched at the start of a word

/// Ditto.
char omni_lower(char c)
{
    return c >= 'A' && c <= 'Z' ? cast(char)(c + 32) : c;
}

/// Whether `c` ends a word, so the character after it starts one.
bool omni_boundary(char c)
{
    return c == ' ' || c == '_' || c == '-' || c == '.' ||
           c == '/' || c == '\\';
}

unittest
{
    assert(omni_score("main.d", "") == 0);       // an empty query keeps everything
    assert(omni_score("", "x") == -1);           // and an empty row can hold nothing
    assert(omni_score("main.d", "md") > 0);      // a subsequence, not a substring
    assert(omni_score("main.d", "dm") == -1);    // but in order
    assert(omni_score("main.d", "xyz") == -1);
    assert(omni_score("README", "rd") > 0);      // case folded both ways
    assert(omni_score("readme", "RD") > 0);

    // Adjacent beats scattered, and a word start beats mid-word.
    assert(omni_score("readme", "rea") > omni_score("readme", "rdm"));
    assert(omni_score("Save As...", "sa") > omni_score("Close Tab", "sa"));
    assert(omni_score("save.bin", "s") > omni_score("class", "s"));
}

/// The unshown aliases: a row is found by a word it does not carry, without that
/// word being able to push it past a row actually named for what was typed.
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

    // An alias only reaches its own row: "hsplit" says nothing about the others.
    type("hsplit");
    got = omni_filter(o, rows);
    assert(got.length == 1);
    assert(got[0].id == 3);

    // A row named for the query wins over one that only answers to it as an alias:
    // "Search Marks" is called that, "Find..." merely answers to "search".
    type("search");
    got = omni_filter(o, rows);
    assert(got.length == 2);
    assert(got[0].id == 4); // named for it
    assert(got[1].id == 2); // only aliased to it

    // Aliases are searched, never shown: the row still reads as its label.
    type("diff");
    got = omni_filter(o, rows);
    assert(got[0].label == "Compare With...");

    // A row with no aliases is unaffected by the extra pass.
    static immutable OmniItem[] bare = [ OmniItem("Quit", "Ctrl+Q", null, 9) ];
    type("quit");
    got = omni_filter(o, bare);
    assert(got.length == 1);
    type("zzz");
    assert(omni_filter(o, bare).length == 0);
}

/// Where the visible rows sit in the whole list: a thumb as tall a fraction of the
/// track as `visible` is of `count`, at the scroll's place along it. Read only - the
/// list is driven by the arrows, so there is nothing here to grab.
void omni_scrollbar(mu_Context* ctx, mu_Rect track, int scroll, int visible, int count)
{
    mu_draw_rect(ctx, track, OMNI_BAR_TRACK);

    // Floored, so a list of hundreds still leaves something to see.
    int thumbH = mu_clamp(visible * track.h / count, BAR_MIN, track.h);
    int travel = track.h - thumbH;
    int last   = count - visible;
    int y = track.y + (last > 0 ? scroll * travel / last : 0);
    mu_draw_rect(ctx, mu_Rect(track.x, y, track.w, thumbH), OMNI_BAR_THUMB);
}

/// Draw one row's text: the label on the left, elided to what is left after the
/// detail column and the unsaved dot have taken their room from the right.
void omni_row(mu_Context* ctx, ref const(OmniItem) it, mu_Rect r)
{
    mu_Font font = ctx.style.font;
    int th = ctx.text_height(font);
    int y  = r.y + (r.h - th) / 2;
    int right = r.x + r.w - ROW_INSET;

    // The detail is the first to give way, being context: a long path would
    // otherwise crowd out the name the user is actually reading.
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
