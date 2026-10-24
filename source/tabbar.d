/// Prototype tab strip on ddui's control primitives.
/// Authors: dd86k <dd@dax.moe>
module tabbar;

import core.stdc.string : strlen;
import std.format : sformat;
import std.math : abs;
import ddui;
import uitext : ui_elide;

/// Tab display data, rebuilt by the caller each frame.
struct TabItem
{
    /// Elided when too narrow.
    string label;
    /// Unsaved: close box shows a dot until hovered.
    bool modified;
    /// Views open on this tab's document. Shown when > 1 so shared tabs (same
    /// editor, undo, bookmarks) aren't mistaken for separate copies.
    int views;
    /// Job progress 0-100, drawn as a bar under the label. -1: none.
    int progress = -1;
    /// Edits refused: padlock before the label.
    bool locked;
}

/// Persistent strip state (scroll, drag). Keep across frames.
struct TabBar
{
    /// Tabs shrink to this, then the strip scrolls.
    int minWidth = 120;
    int maxWidth = 220;

    /// Background under the strip; the active tab uses it to blend in.
    /// Transparent: window background.
    mu_Color content;

    /// Mute the active tab's accent: only the focused strip is lit.
    bool unfocused;

    /// Text left of the first tab (pane number), empty for none. Accent-lit while
    /// focused.
    string badge;

    private:

    // Hovered tab and its rect, -1 for none. See tab_hover.
    int hovered = -1;
    mu_Rect hoverRect;

    // Scroll offset when tabs overflow.
    int scrollX;

    // Slot widths this frame, in display order. Used by three passes; measured
    // once since text_width is costly. Only grows.
    int[] slots;

    // Tab under a pressed left button, -1 if none.
    int held = -1;

    // Press position (drag threshold) and grab offset within the tab, so it
    // doesn't jump. Both axes: dragging down into another pane mustn't shift it.
    mu_Vec2 heldAt;
    int grabDX;
    int grabDY;

    // Set once past the drag threshold.
    bool dragging;

    // Dragged out of the strip; caller draws and places it. See tab_drag_out.
    bool detached;

    // Dragged tab rect, window coordinates.
    mu_Rect ghost;
}

enum TabAction
{
    none,
    select, /// Bring `index` to front.
    close,  /// Close box or middle click.
    add,    /// + button.
    move,   /// Move from `index` to `target`.
    detach, /// Dragged out and released; caller decides where.
}

// The active tab uses the window body colour so it joins the content.
private enum mu_Color TAB_IDLE    = mu_Color( 38,  38,  44, 255);
private enum mu_Color TAB_HOVER   = mu_Color( 60,  60,  70, 255);
private enum mu_Color TAB_ACCENT  = mu_Color(110, 170, 255, 255); // active tab top edge
private enum mu_Color TAB_DIM     = mu_Color(170, 170, 185, 255); // inactive label/icon
private enum mu_Color TAB_CLOSEBG = mu_Color( 90,  90, 105, 255); // hovered close box

private enum int TAB_LIFT     = 3; // inactive tab offset from strip top
private enum int TAB_ACCENT_H = 2;
private enum int TAB_HEADROOM = 4; // above content, clear of the accent
private enum int TAB_DOT      = 6;
private enum int TAB_GAP      = 3; // between tabs
private enum int TAB_PAD      = 4; // added to style.padding
private enum int TAB_INSET    = 4; // left of first tab
private enum int TAB_BAR_H    = 3; // progress bar height
private enum int TAB_LOCK_W   = 8; // padlock body width

// Drag threshold, so hand jitter on click doesn't reorder.
private enum int TAB_DRAG_MIN = 4;

/// Strip height: menubar height plus accent headroom and inactive tab lift.
int tab_bar_height(mu_Context* ctx)
{
    return ctx.style.size.y + ctx.style.padding * 2 + TAB_HEADROOM + TAB_LIFT;
}

/// Draw and handle a tab strip. `selected`: active tab (-1 for none), `bar`:
/// persistent state.
///
/// Takes its own layout row. Tabs are sized to labels within
/// [minWidth, maxWidth]; on overflow they share evenly, then scroll past
/// minWidth, keeping `selected` visible.
///
/// Dragging reorders: TabAction.move is returned per neighbour passed; the
/// caller must apply it, since the next frame lays out from the new items.
/// Returns: The action (one per frame), with `index` the tab (else -1) and
///          `target` the destination for a move.
TabAction tab_bar(mu_Context* ctx, const(char)* name, ref TabBar bar,
    const(TabItem)[] items, int selected, out int index, out int target)
{
    index  = -1;
    target = -1;
    TabAction action;

    // Release ends any drag. Checked first so a strip emptied mid-drag can't keep
    // a tab held. Release outside hands the tab over, reported once count is known.
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

    // Before the early return: an empty pane still shows its number.
    int badgeW = tab_badge(ctx, bar, strip, th, font);

    // Reset every frame so a closed or scrolled-away tab isn't reported.
    bar.hovered = -1;

    if (items.length == 0)
        return action;

    // Scope ids under `name` so strips don't collide.
    mu_push_id(ctx, name, cast(int) strlen(name));
    scope(exit) mu_pop_id(ctx);

    // + pinned right; tabs share the lane left of it, inset from the edge.
    int newW = h; // square
    mu_Rect newR = mu_Rect(strip.x + strip.w - newW, strip.y, newW, h);
    int laneX = strip.x + TAB_INSET + badgeW;
    mu_Rect lane = mu_Rect(laneX, strip.y, strip.x + strip.w - newW - laneX, h);

    int closeW = th;         // one glyph high square
    int inset  = pad + TAB_PAD; // tab insets

    // Natural widths; on overflow, even share floored at minWidth, then scroll.
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

    if (bar.held >= count) // tabs closed under the held one
        bar.held = -1;

    // Measured from the press point so slow drags still trigger; settled before
    // drawing so the tab lifts on the same frame. Either axis: tabs can be dragged
    // down into a pane below.
    if (bar.held >= 0 && bar.dragging == false &&
        (abs(ctx.mouse_pos.x - bar.heldAt.x) >= TAB_DRAG_MIN ||
         abs(ctx.mouse_pos.y - bar.heldAt.y) >= TAB_DRAG_MIN))
        bar.dragging = true;

    // Minimal scroll to keep the selected tab fully visible.
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
    mu_Rect dragRect;   // for the second pass
    bool dragHeld;
    foreach (size_t i, ref const(TabItem) it; items)
    {
        // Slot includes the gap after the tab.
        int w = slots[i];
        mu_Rect r = mu_Rect(x, lane.y, w - TAB_GAP, h);
        x += w;

        // Dragged tab is painted last at the pointer, so don't cull it by slot.
        bool floating = bar.dragging && bar.held == cast(int) i;
        if (floating == false && (r.x + r.w <= lane.x || r.x >= lane.x + lane.w))
            continue; // scrolled out

        // Ids for the body and close box.
        int[2] key = [ cast(int) i, 0 ];
        mu_Id id = mu_get_id(ctx, key.ptr, key.sizeof);
        key[1] = 1;
        mu_Id cid = mu_get_id(ctx, key.ptr, key.sizeof);

        mu_Rect closeR = tab_close_rect(r, closeW);

        // Body first: the later call keeps hover on the box when both match.
        mu_update_control(ctx, id, r, 0);
        mu_update_control(ctx, cid, closeR, 0);

        bool bodyHot  = ctx.hover == id;
        bool closeHot = ctx.hover == cid;

        if (bodyHot || closeHot)
        {
            bar.hovered = cast(int) i;
            bar.hoverRect = r;
        }

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
                // A press may start a drag; the threshold above decides.
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
            continue; // painted last
        }
        tab_paint(ctx, bar, it, r, cast(int) i == selected, bodyHot, closeHot,
            closeW, inset, th, font);
    }

    // Report the move as soon as it passes a neighbour, so the strip always shows
    // the order it would drop into.
    if (bar.dragging && bar.held >= 0 && bar.held < count)
    {
        int from = bar.held; // still this frame's order
        int w = slots[from] - TAB_GAP;

        bar.detached = tab_inside(strip, ctx.mouse_pos) == false;

        if (bar.detached)
        {
            // Detached: follows the pointer on both axes; the caller draws it outside
            // our clip.
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
                bar.held = to; // caller reorders
            }
            bar.ghost = mu_Rect(floatX, lane.y, w, h);
            if (dragHeld)
                tab_paint(ctx, bar, items[from], bar.ghost, true, true, false,
                    closeW, inset, th, font);
        }
    }
    mu_pop_clip_rect(ctx);

    // Released outside the strip. Reported last so no click is also claimed.
    if (handed >= 0 && handed < count)
    {
        action = TabAction.detach;
        index  = handed;
    }

    // + button, outside the lane clip so scrolling never hides it.
    mu_Id nid = mu_get_id(ctx, "+".ptr, 1);
    mu_update_control(ctx, nid, newR, 0);
    if (ctx.mouse_pressed == MU_MOUSE_LEFT && ctx.focus == nid)
    {
        action = TabAction.add;
        index  = -1;
    }
    if (ctx.hover == nid)
        mu_draw_rect(ctx, newR, TAB_HOVER);
    mu_Rect plusR = mu_Rect(newR.x, newR.y + TAB_HEADROOM, newR.w, newR.h - TAB_HEADROOM);
    mu_draw_control_text(ctx, "+", plusR, MU_COLOR_TEXT, MU_OPT_ALIGNCENTER);

    return action;
}

/// Hovered tab (`index` into the items) and its rect in window coordinates.
/// False while dragging.
bool tab_hover(ref const(TabBar) bar, out int index, out mu_Rect r)
{
    index = bar.hovered;
    r = bar.hoverRect;
    return bar.hovered >= 0 && bar.dragging == false;
}

/// Whether a tab is dragged out of the strip: `index` into the items, `r` at
/// the pointer (window coordinates). While true, the caller owning the strips
/// must draw it and pick the drop target.
bool tab_drag_out(ref const(TabBar) bar, out mu_Rect r, out int index)
{
    r = bar.ghost;
    index = bar.held;
    return bar.detached && bar.held >= 0;
}

/// Paint a dragged-out tab at `r` (as reported by tab_drag_out), as active and
/// hovered. Call under a clip that admits it; the source strip's clip won't.
void tab_ghost(mu_Context* ctx, ref const(TabBar) bar, ref const(TabItem) it, mu_Rect r)
{
    mu_Font font = ctx.style.font;
    int th = ctx.text_height(font);
    tab_paint(ctx, bar, it, r, true, true, false,
        th, ctx.style.padding + TAB_PAD, th, font);
}

private:

// Draw the pane number at the strip's left; returns its width (0 if no badge).
// A label, not a control.
int tab_badge(mu_Context* ctx, ref const(TabBar) bar, mu_Rect strip, int th, mu_Font font)
{
    if (bar.badge.length == 0)
        return 0;

    int tw = ctx.text_width(font, bar.badge.ptr, cast(int) bar.badge.length);
    mu_draw_text(ctx, font, bar.badge,
        mu_Vec2(strip.x + TAB_INSET + TAB_PAD, strip.y + TAB_HEADROOM + (strip.h - TAB_HEADROOM - th) / 2),
        bar.unfocused ? TAB_DIM : TAB_ACCENT);
    return tw + TAB_PAD * 2 + TAB_INSET;
}

// View count for a shared document, empty if only one. Into `buf`: needed
// twice per frame (measure, draw), no heap.
const(char)[] tab_tag(ref const(TabItem) it, return ref char[8] buf)
{
    if (it.views <= 1)
        return null;
    return sformat(buf, "x%d", it.views);
}

// Plain hit test; mu_mouse_over also checks clip and hover root, which don't
// apply to a pointer that left.
bool tab_inside(mu_Rect r, mu_Vec2 p)
{
    return p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h;
}

unittest
{
    static immutable mu_Rect r = mu_Rect(10, 20, 100, 30);
    assert(tab_inside(r, mu_Vec2(10, 20)));   // top-left
    assert(tab_inside(r, mu_Vec2(60, 35)));
    assert(tab_inside(r, mu_Vec2(109, 49)));  // last pixel
    assert(tab_inside(r, mu_Vec2(110, 35)) == false); // past right
    assert(tab_inside(r, mu_Vec2(60, 50))  == false); // past bottom
    assert(tab_inside(r, mu_Vec2(9, 35))   == false);
    assert(tab_inside(r, mu_Vec2(60, 19))  == false);
}

// Requested tab width: label, close box, insets and gap, clamped to bounds.
// Close box room is always reserved so labels don't shift on hover.
int tab_width(mu_Context* ctx, ref const(TabBar) bar, ref const(TabItem) it,
    int closeW, int inset)
{
    int tw = it.label.length ?
        ctx.text_width(ctx.style.font, it.label.ptr, cast(int) it.label.length) : 0;
    char[8] tagbuf = void;
    const(char)[] tag = tab_tag(it, tagbuf);
    if (tag.length)
        tw += ctx.text_width(ctx.style.font, tag.ptr, cast(int) tag.length) + inset;
    if (it.locked)
        tw += TAB_LOCK_W + inset;
    return mu_clamp(tw + closeW + inset * 2 + TAB_GAP, bar.minWidth, bar.maxWidth);
}

// Target index for the tab dragged to `centre`. `from`: its index, `widths`:
// slots in display order, `originX`: left edge they start from.
//
// The dragged tab is excluded from the layout, otherwise moving it shifts
// the slots and tabs of unequal widths oscillate.
int tab_drop_index(const(int)[] widths, int from, int originX, int centre)
{
    int index;
    int x = originX;
    foreach (size_t i, int w; widths)
    {
        if (cast(int) i == from)
            continue; // skip its own gap
        if (x + w / 2 >= centre)
            break;    // middle still to the right
        x += w;
        ++index;
    }
    return index;
}

unittest
{
    // First of three dragged right: moves past each middle.
    static immutable int[3] even = [ 100, 100, 100 ];
    assert(tab_drop_index(even, 0, 0,  40) == 0);
    assert(tab_drop_index(even, 0, 0,  49) == 0); // short of the middle
    assert(tab_drop_index(even, 0, 0,  60) == 1);
    assert(tab_drop_index(even, 0, 0, 160) == 2);
    assert(tab_drop_index(even, 0, 0, 999) == 2); // clamped

    // Last one dragged left, mirrored.
    assert(tab_drop_index(even, 2, 0, 160) == 2);
    assert(tab_drop_index(even, 2, 0, 140) == 1);
    assert(tab_drop_index(even, 2, 0,  40) == 0);
    assert(tab_drop_index(even, 2, 0, -99) == 0);

    // Middle one, either way.
    assert(tab_drop_index(even, 1, 0, 120) == 1);
    assert(tab_drop_index(even, 1, 0, 160) == 2);
    assert(tab_drop_index(even, 1, 0,  40) == 0);

    // Scroll and inset via originX.
    assert(tab_drop_index(even, 0, 500, 540) == 0);
    assert(tab_drop_index(even, 0, 500, 560) == 1);
    assert(tab_drop_index(even, 0, -50, 10) == 1); // scrolled 50

    // Uneven widths: the oscillation case. Stable once past the wide tab's
    // middle (100 either way).
    static immutable int[2] wideFirst  = [ 200, 90 ];
    static immutable int[2] narrowFirst = [ 90, 200 ];
    assert(tab_drop_index(wideFirst,   1, 0, 190) == 1);
    assert(tab_drop_index(wideFirst,   1, 0,  90) == 0); // steps in front
    assert(tab_drop_index(narrowFirst, 0, 0,  90) == 0); // stays
    assert(tab_drop_index(narrowFirst, 0, 0, 110) == 1); // back only past the middle

    // Single tab.
    static immutable int[1] one = [ 100 ];
    assert(tab_drop_index(one, 0, 0, 0)    == 0);
    assert(tab_drop_index(one, 0, 0, 5000) == 0);
}

// Clamp a dragged tab's left edge. `wanted`: from the pointer, `lane`: visible
// strip (excluding +), `originX`: lane minus scroll, `total`: sum of slots.
//
// Stops at the last slot position so it doesn't drift away from the row, or
// at the lane edge if the row overflows.
int tab_float_x(int wanted, mu_Rect lane, int originX, int total, int slotW)
{
    int lo = mu_max(lane.x, originX);
    int hi = mu_min(lane.x + lane.w - (slotW - TAB_GAP), originX + total - slotW);
    return mu_clamp(wanted, lo, mu_max(lo, hi));
}

unittest
{
    // Short row in a wide lane: stops at the last slot (200).
    static immutable mu_Rect wide = mu_Rect(0, 0, 800, 20);
    assert(tab_float_x(150,  wide, 0, 300, 100) == 150); // in the row
    assert(tab_float_x(200,  wide, 0, 300, 100) == 200); // last slot
    assert(tab_float_x(400,  wide, 0, 300, 100) == 200); // clamped
    assert(tab_float_x(9999, wide, 0, 300, 100) == 200);
    assert(tab_float_x(-50,  wide, 0, 300, 100) == 0);   // left end

    // Lane inset on both ends.
    static immutable mu_Rect inset = mu_Rect(40, 0, 800, 20);
    assert(tab_float_x(20,  inset, 40, 300, 100) == 40);
    assert(tab_float_x(400, inset, 40, 300, 100) == 240); // 40 + 300 - 100

    // Row wider than lane: stops at the lane edge.
    static immutable mu_Rect tight = mu_Rect(0, 0, 250, 20);
    assert(tab_float_x(400, tight, 0, 900, 100) == 153); // 250 - (100 - TAB_GAP)
    assert(tab_float_x(100, tight, 0, 900, 100) == 100); // in lane

    // Scrolled 200: left stop is the lane edge.
    assert(tab_float_x(-300, tight, -200, 900, 100) == 0);
    assert(tab_float_x(50,   tight, -200, 900, 100) == 50);

    // Lane narrower than a tab: no inverted range.
    static immutable mu_Rect sliver = mu_Rect(10, 0, 20, 20);
    assert(tab_float_x(500, sliver, 10, 300, 100) == 10);
}

// Padlock TAB_LOCK_W wide at `x`, centred on a `th` line at `y`. Drawn with
// rects; the UI font may lack a glyph.
void tab_lock(mu_Context* ctx, int x, int y, int th, mu_Color ink)
{
    enum int BODY_H = 6, SHACKLE_H = 4, STROKE = 2;
    int top = y + (th - BODY_H - SHACKLE_H) / 2;
    mu_draw_rect(ctx, mu_Rect(x + 1, top, TAB_LOCK_W - 2, STROKE), ink);
    mu_draw_rect(ctx, mu_Rect(x + 1, top, STROKE, SHACKLE_H), ink);
    mu_draw_rect(ctx, mu_Rect(x + TAB_LOCK_W - 1 - STROKE, top, STROKE, SHACKLE_H), ink);
    mu_draw_rect(ctx, mu_Rect(x, top + SHACKLE_H, TAB_LOCK_W, BODY_H), ink);
}

// Flush right; an inset would waste label room.
mu_Rect tab_close_rect(mu_Rect r, int closeW)
{
    return mu_Rect(r.x + r.w - closeW,
        r.y + TAB_HEADROOM + (r.h - TAB_HEADROOM - closeW) / 2, closeW, closeW);
}

// Paint one tab. Separate so the dragged tab can be drawn last, on top.
void tab_paint(mu_Context* ctx, ref const(TabBar) bar, ref const(TabItem) it,
    mu_Rect r, bool active, bool bodyHot, bool closeHot,
    int closeW, int inset, int th, mu_Font font)
{
    mu_Rect closeR = tab_close_rect(r, closeW);

    // Active: full height, body colour. Others: lower and darker.
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
    // Same baseline for all tabs so labels don't jump.
    int textY = r.y + TAB_HEADROOM + (r.h - TAB_HEADROOM - th) / 2;

    if (it.locked && textW > TAB_LOCK_W + inset)
    {
        tab_lock(ctx, textX, textY, th, ink);
        textX += TAB_LOCK_W + inset;
        textW -= TAB_LOCK_W + inset;
    }

    // View count, dropped if it would force eliding the label (even-share layout
    // may give less than tab_width asked).
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

    // Full tab width; a short label would make it too small.
    if (it.progress >= 0)
    {
        int barX = r.x + inset;
        int barW = closeR.x + closeR.w - barX;
        int y = mu_min(textY + th + 1, r.y + r.h - TAB_BAR_H);
        mu_draw_rect(ctx, mu_Rect(barX, y, barW, TAB_BAR_H), TAB_CLOSEBG);
        mu_draw_rect(ctx, mu_Rect(barX, y, barW * mu_min(it.progress, 100) / 100, TAB_BAR_H),
            TAB_ACCENT);
    }

    if (it.modified && closeHot == false)
    {
        // Dot in place of the X, swapped on hover.
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

