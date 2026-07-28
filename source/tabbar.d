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

/// Persistent strip state; keep one across frames. The scroll offset lives here.
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

    private:

    // Pixels the strip is scrolled right by when the tabs overflow it. Owned by
    // tab_bar, which keeps the selected tab inside the visible lane.
    int scrollX;
}

/// What the user did to the strip this frame.
enum TabAction
{
    none,   /// Nothing was clicked.
    select, /// The tab at the reported index was clicked: bring it to the front.
    close,  /// Its close box was clicked (or the tab middle-clicked): close it.
    add,    /// The trailing + button: open a new tab.
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

/// Draw and drive a strip of tabs.
///
/// Consumes one layout row of its own, the height of a menubar so the two line
/// up when stacked. Tabs are sized to their labels within [minWidth, maxWidth];
/// when the row does not fit they all drop to one even share, and past minWidth
/// the strip scrolls, keeping the selected tab in view. Only one thing can be
/// clicked per frame, so a single action comes back.
/// Params:
///     ctx = ddui context.
///     name = Stable id string, unique among sibling widgets.
///     bar = Strip state, persisted across frames by the caller.
///     items = One entry per tab, in display order.
///     selected = Index of the active tab, or -1 for none.
///     index = Set to the tab an action refers to, else -1.
/// Returns: What the user did this frame.
TabAction tab_bar(mu_Context* ctx, const(char)* name, ref TabBar bar,
    const(TabItem)[] items, int selected, out int index)
{
    index = -1;
    TabAction action;

    mu_Font font = ctx.style.font;
    int pad = ctx.style.padding;
    int th  = ctx.text_height(font);
    int h   = ctx.style.size.y + pad * 2; // mu_begin_menubar's height

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
    int total;
    foreach (ref const(TabItem) it; items)
        total += tab_width(ctx, bar, it, closeW, inset);
    int even;
    if (total > lane.w)
    {
        even  = mu_max(bar.minWidth, lane.w / count);
        total = even * count;
    }

    int width(size_t i)
    {
        return even ? even : tab_width(ctx, bar, items[i], closeW, inset);
    }

    // Follow the selection: scroll the least that brings its tab fully into the
    // lane, so switching tabs by keyboard never leaves the caret's file off screen.
    if (selected >= 0 && selected < count)
    {
        int x0;
        foreach (i; 0 .. selected)
            x0 += width(i);
        int x1 = x0 + width(selected);
        if (bar.scrollX > x0)
            bar.scrollX = x0;
        if (bar.scrollX < x1 - lane.w)
            bar.scrollX = x1 - lane.w;
    }
    bar.scrollX = mu_clamp(bar.scrollX, 0, mu_max(0, total - lane.w));

    mu_push_clip_rect(ctx, lane);
    int x = lane.x - bar.scrollX;
    foreach (size_t i, ref const(TabItem) it; items)
    {
        // The slot a tab advances by carries the gap to its neighbour; the tab
        // itself is what is left of it, so the strip shows between the two.
        int w = width(i);
        mu_Rect r = mu_Rect(x, lane.y, w - TAB_GAP, h);
        x += w;
        if (r.x + r.w <= lane.x || r.x >= lane.x + lane.w)
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
            }
        }
        else if (ctx.mouse_pressed == MU_MOUSE_MIDDLE &&
                 (ctx.focus == id || ctx.focus == cid))
        {
            // Middle click closes, the way every tabbed application does it.
            action = TabAction.close;
            index  = cast(int) i;
        }

        // The active tab runs the strip's full height in the body's own colour,
        // so it reads as standing in front and joined to the content below; the
        // others sit lower and darker, a pixel apart.
        bool active = cast(int) i == selected;
        mu_Color face = active ? (bar.content.a ? bar.content :
                                  ctx.style.colors[MU_COLOR_WINDOWBG]) :
                        bodyHot || closeHot ? TAB_HOVER : TAB_IDLE;
        int top = active ? 0 : TAB_LIFT;
        mu_draw_rect(ctx, mu_Rect(r.x, r.y + top, r.w, r.h - top), face);
        if (active)
            mu_draw_rect(ctx, mu_Rect(r.x, r.y, r.w, TAB_ACCENT_H), TAB_ACCENT);

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
            // Unsaved: a dot sits where the X would, and hovering swaps them, so
            // the state is visible without the row filling up with crosses.
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
    mu_pop_clip_rect(ctx);

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

private:

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

