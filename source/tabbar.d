/// Prototype tab strip built on ddui's control primitives.
///
/// ddui has no tab widget, but a tab is little more than a button owning a slice
/// of a strip: laid out by hand, drawn so the active one merges into the content
/// below, and carrying its own close box. These helpers keep that in one place.
/// Kept local to vddhx for now, the way the menubar prototype in menu.d was
/// before ddui grew one of its own.
/// Authors: dd
module tabbar;

import core.stdc.string : strlen;
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
}

/// Persistent strip state; keep one across frames. The scroll offset and the
/// in-progress drag live here.
struct TabBar
{
    /// Width a tab shrinks to before the strip scrolls instead of shrinking more.
    int minWidth = 90;
    /// Width a tab grows to at most, so one long name cannot eat the whole strip.
    int maxWidth = 220;

    /// Colour of whatever the strip sits on top of, which the active tab takes
    /// so the two read as one surface. Left transparent (the default), the
    /// window background is used, which is right when the strip sits on a plain
    /// window and wrong when it caps a panel with a canvas of its own.
    mu_Color content;

    /// Mute the active tab's accent edge. For a strip that is not the one taking
    /// keys: with several side by side, every one of them has a tab in front, and
    /// only the lit accent says which of those the keyboard is actually in.
    bool unfocused;

    private:

    // Pixels the strip is scrolled right by when the tabs overflow it. Owned by
    // tab_bar, which keeps the selected tab inside the visible lane.
    int scrollX;

    // Each tab's slot width this frame, in display order. Measuring a label costs
    // a text_width call and three passes want the answer (the scroll follow, the
    // drop index and the draw loop), so it is measured once into storage that
    // only ever grows.
    int[] slots;

    // The tab the left button went down on, or -1 when nothing is held. Set on
    // the press and cleared on the release, whether or not it turned into a drag.
    int held = -1;

    // Where the pointer was when the button went down, against which the drag
    // threshold is measured, and the grab point inside the tab, so a tab picked
    // up by its right edge does not jump under the pointer. Both axes: a tab
    // pulled straight down out of its strip - the way one moves between panes
    // stacked vertically - never shifts by a pixel horizontally.
    mu_Vec2 heldAt;
    // Ditto.
    int grabDX;
    // Ditto.
    int grabDY;

    // Whether the pointer has moved far enough for this to be a drag rather than
    // a click. Until it has, the tab stays in its slot.
    bool dragging;

    // Whether the drag has left this strip altogether. The tab is then on its way
    // somewhere the strip knows nothing about, so it stops reordering, stops
    // painting the tab itself, and leaves both to the caller. See tab_drag_out.
    bool detached;

    // Where the dragged tab currently is, in window coordinates. Within the strip
    // this is its slot on the row; once detached it is wherever the pointer has
    // taken it.
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

// Tab colours. The active tab takes the window body's own colour from the style,
// so it reads as joined to the content below; these are the rest of the palette.
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
// becomes a drag of it. Without a threshold every click would jitter the order
// by a pixel of hand shake on the way back up.
private enum int TAB_DRAG_MIN = 4;

/// Height one strip takes, which is a menubar's so the two line up when stacked.
///
/// For a caller that has to reason about where a strip sits before or after it is
/// drawn - what part of a pane is strip and what part is content, say.
int tab_bar_height(mu_Context* ctx)
{
    return ctx.style.size.y + ctx.style.padding * 2;
}

/// Draw and drive a strip of tabs.
///
/// Consumes one layout row of its own, the height of a menubar so the two line
/// up when stacked. Tabs are sized to their labels within [minWidth, maxWidth];
/// when the row does not fit they all drop to one even share, and past minWidth
/// the strip scrolls, keeping the selected tab in view. Only one thing can be
/// clicked per frame, so a single action comes back.
///
/// A tab dragged sideways reorders the strip: it lifts out and follows the
/// pointer, and TabAction.move comes back each time it passes a neighbour, one
/// step at a time. The strip assumes the caller carries the move out, since the
/// next frame's items are what it lays out against.
/// Params:
///     ctx = ddui context.
///     name = Stable id string, unique among sibling widgets.
///     bar = Strip state, persisted across frames by the caller.
///     items = One entry per tab, in display order.
///     selected = Index of the active tab, or -1 for none.
///     index = Set to the tab an action refers to, else -1. For a move, the tab
///             being dragged, which is where it is coming from.
///     target = For a move, the index it is going to. -1 for everything else.
/// Returns: What the user did this frame.
TabAction tab_bar(mu_Context* ctx, const(char)* name, ref TabBar bar,
    const(TabItem)[] items, int selected, out int index, out int target)
{
    index  = -1;
    target = -1;
    TabAction action;

    // A release ends any drag, wherever the pointer let go. First of everything,
    // so a strip that empties out mid-drag cannot leave a tab held: the press
    // that starts the next drag would otherwise read as a continuation of it.
    //
    // Letting go outside the strip is the tab being handed over, so what was held
    // is remembered across the reset and reported once the tab count is known.
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

    if (items.length == 0)
        return action;

    // Ids are scoped under `name`, so two strips in one window cannot collide.
    mu_push_id(ctx, name, cast(int) strlen(name));
    scope(exit) mu_pop_id(ctx);

    // The + button is pinned to the right end; the tabs share the lane left of
    // it, starting a little in from the window edge so the first tab is not
    // welded to it.
    int newW = h; // square
    mu_Rect newR = mu_Rect(strip.x + strip.w - newW, strip.y, newW, h);
    mu_Rect lane = mu_Rect(strip.x + TAB_INSET, strip.y, strip.w - newW - TAB_INSET, h);

    int closeW = th;         // the close box: a square one glyph high
    int inset  = pad + TAB_PAD; // a tab's own left, middle and right insets

    // Natural width first; if the row overflows, every tab takes one even share
    // instead, floored at minWidth so a tab never shrinks to a sliver. Whatever
    // is still over the lane is reached by scrolling.
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

    // Past the threshold the held tab becomes a dragged one. Measured from where
    // the button went down rather than frame to frame, so a slow drag crosses it
    // just the same. Settled before the draw loop, so the tab lifts out on the
    // very frame the pointer takes it rather than the one after.
    //
    // Either axis counts. Reordering only cares about sideways travel, but a tab
    // is also dragged out of its strip - straight down, into a pane below it -
    // and going by x alone left that gesture doing nothing at all.
    if (bar.held >= 0 && bar.dragging == false &&
        (abs(ctx.mouse_pos.x - bar.heldAt.x) >= TAB_DRAG_MIN ||
         abs(ctx.mouse_pos.y - bar.heldAt.y) >= TAB_DRAG_MIN))
        bar.dragging = true;

    // Follow the selection: scroll the least that brings its tab fully into the
    // lane, so switching tabs by keyboard never leaves the caret's file off screen.
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
        // The slot a tab advances by carries the gap to its neighbour; the tab
        // itself is what is left of it, so the strip shows between the two.
        int w = slots[i];
        mu_Rect r = mu_Rect(x, lane.y, w - TAB_GAP, h);
        x += w;

        // A tab being dragged is painted last, over the others, from wherever
        // the pointer has it rather than from its slot - so it is not culled on
        // its slot either, which can be off the lane mid-swap.
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

        // Body first, close box second: the box sits inside the body, and the
        // later call is the one that leaves hover on the box when both match.
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
                // The press is also where a drag would start from. Which it is
                // only shows once the pointer moves, so take hold of the tab now
                // and let the threshold below decide.
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
            // Middle click closes, the way every tabbed application does it.
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

        // Has the pointer carried the tab clean out of this strip? Then it is on
        // its way to another one, and nothing here can say where: the strip stops
        // reordering, stops drawing it, and hands both jobs to the caller.
        bar.detached = tab_inside(strip, ctx.mouse_pos) == false;

        if (bar.detached)
        {
            // Free of the row now, so it follows the pointer in both axes and can
            // be seen to have left. Drawn by the caller, outside this strip's
            // clip, which the tab could not escape from in here.
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

/// Whether a tab is currently being dragged out of `bar`'s strip, and if so
/// which one and where the pointer has it.
///
/// For a caller that owns several strips: while this holds, the tab belongs to
/// neither the strip it came from nor any it has reached, so somebody above them
/// both has to draw it and work out where it would land. `r` comes back in window
/// coordinates and `index` names the item in the same slice the strip was handed.
/// Returns: True while a tab is out; false whenever the drag is inside its own
///          strip, or when nothing is being dragged at all.
bool tab_drag_out(ref const(TabBar) bar, out mu_Rect r, out int index)
{
    r = bar.ghost;
    index = bar.held;
    return bar.detached && bar.held >= 0;
}

/// Paint a dragged-out tab at `r`, for the caller drawing what tab_drag_out
/// reported. Drawn as an active, hovered tab, so it reads as the thing in hand.
///
/// Call it where the tab should land in the paint order - after everything it is
/// meant to sit over - and under a clip that admits it: the strip it came from
/// clips to its own lane, which is the one place this must not be drawn.
void tab_ghost(mu_Context* ctx, ref const(TabBar) bar, ref const(TabItem) it, mu_Rect r)
{
    mu_Font font = ctx.style.font;
    int th = ctx.text_height(font);
    tab_paint(ctx, bar, it, r, true, true, false,
        th, ctx.style.padding + TAB_PAD, th, font);
}

private:

// Whether `p` is inside `r`. The strip's own hit test, for deciding a drag has
// left it: ddui's mu_mouse_over is no use here, since it also asks whether the
// pointer is inside the current clip and hover root, and the whole question is
// about a pointer that has gone somewhere else.
bool tab_inside(mu_Rect r, mu_Vec2 p)
{
    return p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h;
}

unittest
{
    static immutable mu_Rect r = mu_Rect(10, 20, 100, 30);
    assert(tab_inside(r, mu_Vec2(10, 20)));   // top-left corner is in
    assert(tab_inside(r, mu_Vec2(60, 35)));   // the middle
    assert(tab_inside(r, mu_Vec2(109, 49)));  // last pixel in
    assert(tab_inside(r, mu_Vec2(110, 35)) == false); // one past the right edge
    assert(tab_inside(r, mu_Vec2(60, 50))  == false); // one past the bottom
    assert(tab_inside(r, mu_Vec2(9, 35))   == false);
    assert(tab_inside(r, mu_Vec2(60, 19))  == false);
}

// Width one tab asks for: its label, the close box, the three insets around them
// (one each side, one between) and the gap to the next tab, held between the
// strip's two bounds. Room for the close box is kept whether or not this tab is
// currently drawing one, so a label never shifts under the pointer.
int tab_width(mu_Context* ctx, ref const(TabBar) bar, ref const(TabItem) it,
    int closeW, int inset)
{
    int tw = it.label.length ?
        ctx.text_width(ctx.style.font, it.label.ptr, cast(int) it.label.length) : 0;
    return mu_clamp(tw + closeW + inset * 3 + TAB_GAP, bar.minWidth, bar.maxWidth);
}

// Where a tab dragged to `centre` belongs in the strip.
//
// The other tabs are laid out from `originX` as if the dragged one were not
// there, and the answer is how many of them the centre has got past. Measuring
// against a layout the dragged tab is absent from is what makes this stable:
// were it laid out with the others, moving it would move the very slots the next
// frame decides against, and a tab wider or narrower than its neighbour would
// swap back and forth on a pointer holding still.
// Params:
//     widths = Every tab's slot width, in display order.
//     from = The tab being dragged, which is left out of the layout.
//     originX = Left edge the strip is laid out from, in `centre`'s own space.
//     centre = Where the middle of the dragged tab has got to.
// Returns: The index it should be moved to, which is `from` when it has not
//          passed anything.
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
    // Three even tabs. Dragging the first one right: it holds its place until it
    // is past the middle of the second, then takes one step per neighbour.
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
    // A narrow tab dragged left past a wide one, and the answer holding once it
    // has moved - the wide tab's middle is 100 either way round.
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

// Where a dragged tab's left edge is allowed to be.
//
// The pointer can wander anywhere in the strip, but the tab should not follow it
// off the row: with a few short tabs in a wide window most of the lane is bare,
// and a tab floating out in it has visibly come away from the row it is being
// dropped into. So it stops where its slot would be were it last in the strip -
// or at the lane's own edge when the tabs overflow and that comes first, since
// then the far end is somewhere the lane has to be scrolled to reach.
// Params:
//     wanted = Where the pointer would put the tab's left edge.
//     lane = The visible strip, the + button excluded.
//     originX = Left edge the slots are laid out from: the lane less the scroll.
//     total = Every slot width added up, so the row's full extent.
//     slotW = The dragged tab's own slot width.
// Returns: The left edge to draw it at.
int tab_float_x(int wanted, mu_Rect lane, int originX, int total, int slotW)
{
    int lo = mu_max(lane.x, originX);
    int hi = mu_min(lane.x + lane.w - (slotW - TAB_GAP), originX + total - slotW);
    return mu_clamp(wanted, lo, mu_max(lo, hi));
}

unittest
{
    // A wide lane with a short row in it: the tab stops on the last slot rather
    // than carrying on into the bare strip past it. Three 100px slots from 0, so
    // the last one starts at 200.
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

    // A lane too narrow to hold one tab still gives a usable answer rather than
    // an inverted range.
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
    // reads as standing in front and joined to the content below; the others sit
    // lower and darker, a pixel apart.
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
    if (textW > 0)
    {
        char[256] scratch = void;
        string label = ui_elide(ctx, it.label, textW, scratch);
        if (label.length)
            mu_draw_text(ctx, font, label,
                mu_Vec2(textX, r.y + top + (r.h - top - th) / 2), ink);
    }

    if (it.modified && closeHot == false)
    {
        // Unsaved: a dot sits where the X would, and hovering swaps them, so the
        // state is visible without the row filling up with crosses.
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

