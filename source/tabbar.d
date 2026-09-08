/// Prototype tab strip built on ddui's control primitives.
///
/// Kept local to vddhx for now, the way the menubar prototype in menu.d is.
/// Authors: dd86k <dd@dax.moe>
module tabbar;

import core.stdc.string : strlen;
import std.format : sformat;
import std.math : abs;
import ddui;
import uitext : ui_elide;

/// One tab's presentation. The strip is drawn from a slice of these, which the
/// caller rebuilds each frame from whatever it has open.
struct TabItem
{
    /// Text on the tab, elided with an ellipsis when the tab is too narrow.
    string label;
    /// Unsaved changes: the close box shows a dot until it is hovered.
    bool modified;
    /// How many views the document behind this tab has open in all. Above one the
    /// tab says so: without it, two tabs named the same are indistinguishable from
    /// two copies of a file, when in truth they share an editor, an undo history
    /// and a set of bookmarks.
    int views;
}

/// Persistent strip state; keep one across frames. The scroll offset and the
/// in-progress drag live here.
struct TabBar
{
    /// Width a tab shrinks to before the strip scrolls instead of shrinking more.
    int minWidth = 90;
    /// Width a tab grows to at most, so one long name cannot eat the whole strip.
    int maxWidth = 220;

    /// Colour of whatever the strip sits on top of, which the active tab takes so
    /// the two read as one surface. Left transparent, the window background is
    /// used, which is wrong when the strip caps a panel with a canvas of its own.
    mu_Color content;

    /// Mute the active tab's accent edge, for a strip that is not the one taking
    /// keys: with several side by side, only the lit accent says which of their
    /// front tabs the keyboard is in.
    bool unfocused;

    /// Short text drawn left of the first tab, empty for none: the pane's ordinal,
    /// so the key that jumps to a pane by number is a thing to read rather than to
    /// count out. Lit with the accent while the strip has the keyboard.
    string badge;

    private:

    // Pixels the strip is scrolled right by when the tabs overflow it.
    int scrollX;

    // Each tab's slot width this frame, in display order. Three passes want the
    // answer (the scroll follow, the drop index and the draw loop) and measuring a
    // label is a text_width call, so it is measured once into storage that only
    // ever grows.
    int[] slots;

    // The tab the left button went down on, or -1 when nothing is held.
    int held = -1;

    // Where the pointer was when the button went down, against which the drag
    // threshold is measured, and the grab point inside the tab, so a tab picked up
    // by its right edge does not jump under the pointer. Both axes, since a tab
    // pulled straight down into another pane must not shift sideways.
    mu_Vec2 heldAt;
    int grabDX;
    int grabDY;

    // Until the pointer has moved far enough for a drag, the tab stays in its slot.
    bool dragging;

    // The drag has left this strip altogether, so it stops reordering, stops
    // painting the tab, and leaves both to the caller. See tab_drag_out.
    bool detached;

    // Where the dragged tab is, in window coordinates: its slot on the row, or
    // wherever the pointer has taken it once detached.
    mu_Rect ghost;
}

/// What the user did to the strip this frame.
enum TabAction
{
    none,   /// Nothing was clicked.
    select, /// The tab at the reported index was clicked: bring it to the front.
    close,  /// Its close box was clicked (or the tab middle-clicked): close it.
    add,    /// The trailing + button: open a new tab.
    move,   /// A tab was dragged: move it from the reported index to `target`.
    detach, /// A tab was dragged out of the strip and let go: it is leaving, and
            /// where it goes is for the caller to decide from the pointer.
}

// The active tab takes the window body's own colour from the style, so it reads
// as joined to the content below; these are the rest of the palette.
private enum mu_Color TAB_IDLE    = mu_Color( 38,  38,  44, 255);
private enum mu_Color TAB_HOVER   = mu_Color( 60,  60,  70, 255);
private enum mu_Color TAB_ACCENT  = mu_Color(110, 170, 255, 255); // active tab's top edge
private enum mu_Color TAB_DIM     = mu_Color(170, 170, 185, 255); // inactive label / icon
private enum mu_Color TAB_CLOSEBG = mu_Color( 90,  90, 105, 255); // hovered close box

private enum int TAB_LIFT     = 3; // pixels an inactive tab sits below the strip top
private enum int TAB_ACCENT_H = 2; // thickness of the active tab's accent edge
private enum int TAB_DOT      = 6; // side of the unsaved-changes dot
private enum int TAB_GAP      = 3; // strip colour showing between two tabs
private enum int TAB_PAD      = 2; // added to style.padding for a tab's own insets
private enum int TAB_INSET    = 4; // strip colour left of the first tab

// Pixels the pointer must travel with the button down before a click on a tab
// becomes a drag. Without a threshold every click would jitter the order by a
// pixel of hand shake on the way back up.
private enum int TAB_DRAG_MIN = 4;

/// Height one strip takes, which is a menubar's so the two line up when stacked.
/// For a caller reasoning about where a strip sits before it is drawn.
int tab_bar_height(mu_Context* ctx)
{
    return ctx.style.size.y + ctx.style.padding * 2;
}

/// Draw and drive a strip of tabs from `items`, in display order, `selected`
/// being the active one (-1 for none) and `bar` state the caller persists.
///
/// Consumes one layout row of its own. Tabs are sized to their labels within
/// [minWidth, maxWidth]; when the row does not fit they all drop to one even
/// share, and past minWidth the strip scrolls, keeping the selected tab in view.
///
/// A tab dragged sideways reorders the strip: TabAction.move comes back each time
/// it passes a neighbour, one step at a time, and the caller is assumed to carry
/// the move out, since the next frame's items are what the strip lays out against.
/// Returns: What the user did this frame - only one thing can be clicked per
///          frame - with `index` the tab it refers to (else -1) and, for a move,
///          `target` the index it is going to.
TabAction tab_bar(mu_Context* ctx, const(char)* name, ref TabBar bar,
    const(TabItem)[] items, int selected, out int index, out int target)
{
    index  = -1;
    target = -1;
    TabAction action;

    // A release ends any drag, wherever the pointer let go. First of everything,
    // so a strip that empties out mid-drag cannot leave a tab held. Letting go
    // outside the strip hands the tab over, so what was held is remembered across
    // the reset and reported once the tab count is known.
    int handed = -1;
    if ((ctx.mouse_down & MU_MOUSE_LEFT) == 0)
    {
        if (bar.dragging && bar.detached && bar.held >= 0)
            handed = bar.held;
        bar.held = -1;
        bar.dragging = false;
        bar.detached = false;
    }

    mu_Font font = ctx.style.font;
    int pad = ctx.style.padding;
    int th  = ctx.text_height(font);
    int h   = tab_bar_height(ctx);

    int fill = -1;
    mu_layout_row(ctx, 1, &fill, h);
    mu_Rect strip = mu_layout_next(ctx);
    mu_draw_rect(ctx, strip, ctx.style.colors[MU_COLOR_TITLEBG]);

    // Before the early return below: a pane is still that pane's number when its
    // strip has nothing to show.
    int badgeW = tab_badge(ctx, bar, strip, th, font);

    if (items.length == 0)
        return action;

    // Ids are scoped under `name`, so two strips in one window cannot collide.
    mu_push_id(ctx, name, cast(int) strlen(name));
    scope(exit) mu_pop_id(ctx);

    // The + button is pinned to the right end; the tabs share the lane left of it,
    // starting a little in so the first tab is not welded to the window edge.
    int newW = h; // square
    mu_Rect newR = mu_Rect(strip.x + strip.w - newW, strip.y, newW, h);
    int laneX = strip.x + TAB_INSET + badgeW;
    mu_Rect lane = mu_Rect(laneX, strip.y, strip.x + strip.w - newW - laneX, h);

    int closeW = th;         // the close box: a square one glyph high
    int inset  = pad + TAB_PAD; // a tab's own left, middle and right insets

    // Natural width first; if the row overflows, every tab takes one even share
    // instead, floored at minWidth, and whatever is still over is scrolled to.
    int count = cast(int) items.length;
    if (bar.slots.length < count)
        bar.slots.length = count;
    int total;
    foreach (size_t i, ref const(TabItem) it; items)
    {
        bar.slots[i] = tab_width(ctx, bar, it, closeW, inset);
        total += bar.slots[i];
    }
    if (total > lane.w)
    {
        int even = mu_max(bar.minWidth, lane.w / count);
        bar.slots[0 .. count] = even;
        total = even * count;
    }
    const(int)[] slots = bar.slots[0 .. count];

    if (bar.held >= count) // tabs closed under a held one
        bar.held = -1;

    // Measured from where the button went down rather than frame to frame, so a
    // slow drag crosses the threshold just the same, and settled before the draw
    // loop so the tab lifts out on the frame the pointer takes it.
    //
    // Either axis counts: reordering only cares about sideways travel, but a tab
    // is also dragged straight down out of its strip into a pane below it.
    if (bar.held >= 0 && bar.dragging == false &&
        (abs(ctx.mouse_pos.x - bar.heldAt.x) >= TAB_DRAG_MIN ||
         abs(ctx.mouse_pos.y - bar.heldAt.y) >= TAB_DRAG_MIN))
        bar.dragging = true;

    // Scroll the least that brings the selected tab fully into the lane, so
    // switching by keyboard never leaves the caret's file off screen.
    if (selected >= 0 && selected < count)
    {
        int x0;
        foreach (i; 0 .. selected)
            x0 += slots[i];
        int x1 = x0 + slots[selected];
        if (bar.scrollX > x0)
            bar.scrollX = x0;
        if (bar.scrollX < x1 - lane.w)
            bar.scrollX = x1 - lane.w;
    }
    bar.scrollX = mu_clamp(bar.scrollX, 0, mu_max(0, total - lane.w));

    mu_push_clip_rect(ctx, lane);
    int origin = lane.x - bar.scrollX;
    int x = origin;
    mu_Rect dragRect;   // the dragged tab's slot, kept for the second pass
    bool dragHeld;      // whether there is one to draw
    foreach (size_t i, ref const(TabItem) it; items)
    {
        // The slot carries the gap to the next tab, the tab itself being what is
        // left of it, so the strip shows between the two.
        int w = slots[i];
        mu_Rect r = mu_Rect(x, lane.y, w - TAB_GAP, h);
        x += w;

        // A dragged tab is painted last from wherever the pointer has it, so it is
        // not culled on its slot either, which can be off the lane mid-swap.
        bool floating = bar.dragging && bar.held == cast(int) i;
        if (floating == false && (r.x + r.w <= lane.x || r.x >= lane.x + lane.w))
            continue; // scrolled out of sight: nothing to draw or hit-test

        // Two ids per tab: the body and the close box inside it.
        int[2] key = [ cast(int) i, 0 ];
        mu_Id id = mu_get_id(ctx, key.ptr, key.sizeof);
        key[1] = 1;
        mu_Id cid = mu_get_id(ctx, key.ptr, key.sizeof);

        mu_Rect closeR = mu_Rect(r.x + r.w - inset - closeW,
            r.y + (h - closeW) / 2, closeW, closeW);

        // Body first: the box sits inside it, and the later call is the one that
        // leaves hover on the box when both match.
        mu_update_control(ctx, id, r, 0);
        mu_update_control(ctx, cid, closeR, 0);

        bool bodyHot  = ctx.hover == id;
        bool closeHot = ctx.hover == cid;

        if (ctx.mouse_pressed == MU_MOUSE_LEFT)
        {
            if (ctx.focus == cid)
            {
                action = TabAction.close;
                index  = cast(int) i;
            }
            else if (ctx.focus == id)
            {
                action = TabAction.select;
                index  = cast(int) i;
                // The press is also where a drag would start from, so take hold of
                // the tab now and let the threshold above decide which it was.
                bar.held     = cast(int) i;
                bar.heldAt   = ctx.mouse_pos;
                bar.grabDX   = ctx.mouse_pos.x - r.x;
                bar.grabDY   = ctx.mouse_pos.y - r.y;
                bar.dragging = false;
                bar.detached = false;
            }
        }
        else if (ctx.mouse_pressed == MU_MOUSE_MIDDLE &&
                 (ctx.focus == id || ctx.focus == cid))
        {
            action = TabAction.close;
            index  = cast(int) i;
        }

        if (floating)
        {
            dragRect = r;
            dragHeld = true;
            continue; // painted below, once every other tab is down
        }
        tab_paint(ctx, bar, it, r, cast(int) i == selected, bodyHot, closeHot,
            closeW, inset, th, font);
    }

    // Where the dragged tab has got to, and which slot that puts it in. The move
    // is reported the moment it passes a neighbour, so the strip the user sees is
    // always the order they would get by letting go.
    if (bar.dragging && bar.held >= 0 && bar.held < count)
    {
        int from = bar.held; // `items` is still in this frame's order
        int w = slots[from] - TAB_GAP;

        bar.detached = tab_inside(strip, ctx.mouse_pos) == false;

        if (bar.detached)
        {
            // Free of the row, so it follows the pointer in both axes. Drawn by
            // the caller, outside a clip the tab could not escape from in here.
            bar.ghost = mu_Rect(ctx.mouse_pos.x - bar.grabDX,
                ctx.mouse_pos.y - bar.grabDY, w, h);
        }
        else
        {
            int floatX = tab_float_x(ctx.mouse_pos.x - bar.grabDX,
                lane, origin, total, slots[from]);
            int to = tab_drop_index(slots, from, origin, floatX + w / 2);
            if (to != from)
            {
                action = TabAction.move;
                index  = from;
                target = to;
                bar.held = to; // the caller reorders; next frame lays out the result
            }
            bar.ghost = mu_Rect(floatX, lane.y, w, h);
            if (dragHeld)
                tab_paint(ctx, bar, items[from], bar.ghost, true, true, false,
                    closeW, inset, th, font);
        }
    }
    mu_pop_clip_rect(ctx);

    // A tab let go outside the strip. Reported after everything else, so a strip
    // losing its tab cannot also claim a click this frame.
    if (handed >= 0 && handed < count)
    {
        action = TabAction.detach;
        index  = handed;
    }

    // Trailing + button, outside the lane's clip so scrolling never hides it.
    mu_Id nid = mu_get_id(ctx, "+".ptr, 1);
    mu_update_control(ctx, nid, newR, 0);
    if (ctx.mouse_pressed == MU_MOUSE_LEFT && ctx.focus == nid)
    {
        action = TabAction.add;
        index  = -1;
    }
    if (ctx.hover == nid)
        mu_draw_rect(ctx, newR, TAB_HOVER);
    mu_draw_control_text(ctx, "+", newR, MU_COLOR_TEXT, MU_OPT_ALIGNCENTER);

    return action;
}

/// Whether a tab is being dragged out of `bar`'s strip, and if so which one
/// (`index`, into the slice the strip was handed) and where the pointer has it
/// (`r`, in window coordinates).
///
/// For a caller that owns several strips: while this holds, the tab belongs to
/// neither the strip it came from nor any it has reached, so somebody above them
/// both has to draw it and work out where it would land.
bool tab_drag_out(ref const(TabBar) bar, out mu_Rect r, out int index)
{
    r = bar.ghost;
    index = bar.held;
    return bar.detached && bar.held >= 0;
}

/// Paint a dragged-out tab at `r`, for the caller drawing what tab_drag_out
/// reported. Drawn as an active, hovered tab, so it reads as the thing in hand.
///
/// Call it where the tab should land in the paint order, under a clip that admits
/// it: the strip it came from clips to its own lane, which will not.
void tab_ghost(mu_Context* ctx, ref const(TabBar) bar, ref const(TabItem) it, mu_Rect r)
{
    mu_Font font = ctx.style.font;
    int th = ctx.text_height(font);
    tab_paint(ctx, bar, it, r, true, true, false,
        th, ctx.style.padding + TAB_PAD, th, font);
}

private:

// Draw the pane ordinal at the strip's left end and report how much width it took,
// nothing and zero when the strip carries no badge (one pane needs no number).
//
// Not a control: it is a label saying where this pane is in the order the jump keys
// count, and clicking a pane is what clicking its panel already does.
int tab_badge(mu_Context* ctx, ref const(TabBar) bar, mu_Rect strip, int th, mu_Font font)
{
    if (bar.badge.length == 0)
        return 0;

    int tw = ctx.text_width(font, bar.badge.ptr, cast(int) bar.badge.length);
    mu_draw_text(ctx, font, bar.badge,
        mu_Vec2(strip.x + TAB_INSET + TAB_PAD, strip.y + (strip.h - th) / 2),
        bar.unfocused ? TAB_DIM : TAB_ACCENT);
    return tw + TAB_PAD * 2 + TAB_INSET;
}

// The count drawn on a tab whose document has views elsewhere, empty for a document
// with only this one. Formatted into the caller's buffer, since it is wanted twice a
// frame - once to reserve the room, once to draw it - and neither wants a heap.
const(char)[] tab_tag(ref const(TabItem) it, return ref char[8] buf)
{
    if (it.views <= 1)
        return null;
    return sformat(buf, "x%d", it.views);
}

// The strip's own hit test, for deciding a drag has left it: ddui's mu_mouse_over
// also asks whether the pointer is inside the current clip and hover root, and the
// whole question here is about a pointer that has gone somewhere else.
bool tab_inside(mu_Rect r, mu_Vec2 p)
{
    return p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h;
}

unittest
{
    static immutable mu_Rect r = mu_Rect(10, 20, 100, 30);
    assert(tab_inside(r, mu_Vec2(10, 20)));   // top-left corner
    assert(tab_inside(r, mu_Vec2(60, 35)));
    assert(tab_inside(r, mu_Vec2(109, 49)));  // last pixel in
    assert(tab_inside(r, mu_Vec2(110, 35)) == false); // one past the right edge
    assert(tab_inside(r, mu_Vec2(60, 50))  == false); // one past the bottom
    assert(tab_inside(r, mu_Vec2(9, 35))   == false);
    assert(tab_inside(r, mu_Vec2(60, 19))  == false);
}

// Width one tab asks for: its label, the close box, the three insets around them
// and the gap to the next tab, held between the strip's two bounds. Room for the
// close box is kept whether or not it is drawn, so a label never shifts under the
// pointer.
int tab_width(mu_Context* ctx, ref const(TabBar) bar, ref const(TabItem) it,
    int closeW, int inset)
{
    int tw = it.label.length ?
        ctx.text_width(ctx.style.font, it.label.ptr, cast(int) it.label.length) : 0;
    char[8] tagbuf = void;
    const(char)[] tag = tab_tag(it, tagbuf);
    if (tag.length)
        tw += ctx.text_width(ctx.style.font, tag.ptr, cast(int) tag.length) + inset;
    return mu_clamp(tw + closeW + inset * 3 + TAB_GAP, bar.minWidth, bar.maxWidth);
}

// Where the tab dragged to `centre` belongs in the strip, `from` being the one it
// is, `widths` every slot in display order and `originX` the left edge they are
// laid out from (in `centre`'s own space).
//
// The dragged tab is left out of that layout, which is what makes the answer
// stable: laid out with the others, moving it would move the very slots the next
// frame decides against, and a tab wider or narrower than its neighbour would swap
// back and forth on a pointer holding still.
int tab_drop_index(const(int)[] widths, int from, int originX, int centre)
{
    int index;
    int x = originX;
    foreach (size_t i, int w; widths)
    {
        if (cast(int) i == from)
            continue; // the gap it came out of is not a place to land
        if (x + w / 2 >= centre)
            break;    // this one's middle is still to the right: gone far enough
        x += w;
        ++index;
    }
    return index;
}

unittest
{
    // Dragging the first of three right: it holds its place until past the middle
    // of the second, then takes one step per neighbour.
    static immutable int[3] even = [ 100, 100, 100 ];
    assert(tab_drop_index(even, 0, 0,  40) == 0);
    assert(tab_drop_index(even, 0, 0,  49) == 0); // still short of the middle
    assert(tab_drop_index(even, 0, 0,  60) == 1);
    assert(tab_drop_index(even, 0, 0, 160) == 2);
    assert(tab_drop_index(even, 0, 0, 999) == 2); // past the end, clamped by the walk

    // ... and the last one left, the same thresholds mirrored.
    assert(tab_drop_index(even, 2, 0, 160) == 2);
    assert(tab_drop_index(even, 2, 0, 140) == 1);
    assert(tab_drop_index(even, 2, 0,  40) == 0);
    assert(tab_drop_index(even, 2, 0, -99) == 0);

    // The middle one, which can go either way.
    assert(tab_drop_index(even, 1, 0, 120) == 1);
    assert(tab_drop_index(even, 1, 0, 160) == 2);
    assert(tab_drop_index(even, 1, 0,  40) == 0);

    // The scroll offset and the lane inset both land in originX.
    assert(tab_drop_index(even, 0, 500, 540) == 0);
    assert(tab_drop_index(even, 0, 500, 560) == 1);
    assert(tab_drop_index(even, 0, -50, 10) == 1); // scrolled right by 50

    // Uneven widths: the case a layout including the dragged tab oscillates on.
    // The wide tab's middle is 100 either way round, so the answer holds once the
    // narrow one has passed it.
    static immutable int[2] wideFirst  = [ 200, 90 ];
    static immutable int[2] narrowFirst = [ 90, 200 ];
    assert(tab_drop_index(wideFirst,   1, 0, 190) == 1);
    assert(tab_drop_index(wideFirst,   1, 0,  90) == 0); // steps in front
    assert(tab_drop_index(narrowFirst, 0, 0,  90) == 0); // and stays there
    assert(tab_drop_index(narrowFirst, 0, 0, 110) == 1); // back only past the middle

    // One tab has nowhere to go.
    static immutable int[1] one = [ 100 ];
    assert(tab_drop_index(one, 0, 0, 0)    == 0);
    assert(tab_drop_index(one, 0, 0, 5000) == 0);
}

// Where a dragged tab's left edge is allowed to be: `wanted` is where the pointer
// would put it, `lane` the visible strip (the + button excluded), `originX` the
// lane less the scroll, `total` every slot added up.
//
// The pointer can wander anywhere in the strip, but a tab that followed it out
// into the bare part of a wide lane would visibly come away from the row it is
// being dropped into. So it stops where its slot would be were it last in the
// strip - or at the lane's edge when the tabs overflow and that comes first,
// the far end then being somewhere the lane has to scroll to reach.
int tab_float_x(int wanted, mu_Rect lane, int originX, int total, int slotW)
{
    int lo = mu_max(lane.x, originX);
    int hi = mu_min(lane.x + lane.w - (slotW - TAB_GAP), originX + total - slotW);
    return mu_clamp(wanted, lo, mu_max(lo, hi));
}

unittest
{
    // A short row in a wide lane: the tab stops on the last slot rather than
    // carrying on past it. Three 100px slots from 0, so that slot starts at 200.
    static immutable mu_Rect wide = mu_Rect(0, 0, 800, 20);
    assert(tab_float_x(150,  wide, 0, 300, 100) == 150); // inside the row, as asked
    assert(tab_float_x(200,  wide, 0, 300, 100) == 200); // exactly the last slot
    assert(tab_float_x(400,  wide, 0, 300, 100) == 200); // out in the bare strip
    assert(tab_float_x(9999, wide, 0, 300, 100) == 200);
    assert(tab_float_x(-50,  wide, 0, 300, 100) == 0);   // and off the left end

    // The lane's own inset is respected on both ends.
    static immutable mu_Rect inset = mu_Rect(40, 0, 800, 20);
    assert(tab_float_x(20,  inset, 40, 300, 100) == 40);
    assert(tab_float_x(400, inset, 40, 300, 100) == 240); // 40 + 300 - 100

    // A row wider than the lane: now the lane edge is what stops it, since the
    // row's far end is off screen until the strip scrolls to it.
    static immutable mu_Rect tight = mu_Rect(0, 0, 250, 20);
    assert(tab_float_x(400, tight, 0, 900, 100) == 153); // 250 - (100 - TAB_GAP)
    assert(tab_float_x(100, tight, 0, 900, 100) == 100); // still in the lane

    // Scrolled right by 200: the row starts off the left of the lane, so the left
    // stop is the lane edge rather than the row's own start.
    assert(tab_float_x(-300, tight, -200, 900, 100) == 0);
    assert(tab_float_x(50,   tight, -200, 900, 100) == 50);

    // A lane too narrow for one tab gives an answer rather than an inverted range.
    static immutable mu_Rect sliver = mu_Rect(10, 0, 20, 20);
    assert(tab_float_x(500, sliver, 10, 300, 100) == 10);
}

// Paint one tab in `r`. Split out of the strip's loop so a tab being dragged can
// be drawn from the pointer once every other tab is down, and so land on top.
void tab_paint(mu_Context* ctx, ref const(TabBar) bar, ref const(TabItem) it,
    mu_Rect r, bool active, bool bodyHot, bool closeHot,
    int closeW, int inset, int th, mu_Font font)
{
    int h = r.h;
    mu_Rect closeR = mu_Rect(r.x + r.w - inset - closeW,
        r.y + (h - closeW) / 2, closeW, closeW);

    // The active tab runs the strip's full height in the body's own colour, so it
    // reads as joined to the content below; the others sit lower and darker.
    mu_Color face = active ? (bar.content.a ? bar.content :
                              ctx.style.colors[MU_COLOR_WINDOWBG]) :
                    bodyHot || closeHot ? TAB_HOVER : TAB_IDLE;
    int top = active ? 0 : TAB_LIFT;
    mu_draw_rect(ctx, mu_Rect(r.x, r.y + top, r.w, r.h - top), face);
    if (active)
        mu_draw_rect(ctx, mu_Rect(r.x, r.y, r.w, TAB_ACCENT_H),
            bar.unfocused ? TAB_DIM : TAB_ACCENT);

    mu_Color ink = active ? ctx.style.colors[MU_COLOR_TEXT] : TAB_DIM;

    int textX = r.x + inset;
    int textW = closeR.x - inset - textX;
    int textY = r.y + top + (r.h - top - th) / 2;

    // The shared-views count, dropped when the label would have to be elided to fit
    // it: tab_width reserves the room, but a strip squeezed to even shares has less
    // than it asked for, and the name tells tabs apart where the count only hints.
    char[8] tagbuf = void;
    const(char)[] tag = tab_tag(it, tagbuf);
    if (tag.length && textW > 0)
    {
        int labelW = ctx.text_width(font, it.label.ptr, cast(int) it.label.length);
        int tagW = ctx.text_width(font, tag.ptr, cast(int) tag.length);
        if (labelW + inset + tagW <= textW)
        {
            mu_draw_text(ctx, font, cast(string) tag, mu_Vec2(closeR.x - inset - tagW, textY), TAB_DIM);
            textW -= tagW + inset;
        }
    }

    if (textW > 0)
    {
        char[256] scratch = void;
        string label = ui_elide(ctx, it.label, textW, scratch);
        if (label.length)
            mu_draw_text(ctx, font, label, mu_Vec2(textX, textY), ink);
    }

    if (it.modified && closeHot == false)
    {
        // A dot sits where the X would and hovering swaps them, so the state shows
        // without the row filling up with crosses.
        mu_draw_rect(ctx, mu_Rect(closeR.x + (closeR.w - TAB_DOT) / 2,
            closeR.y + (closeR.h - TAB_DOT) / 2, TAB_DOT, TAB_DOT), ink);
    }
    else if (active || bodyHot || closeHot)
    {
        if (closeHot)
            mu_draw_rect(ctx, closeR, TAB_CLOSEBG);
        mu_draw_icon(ctx, MU_ICON_CLOSE, closeR, ink);
    }
}

