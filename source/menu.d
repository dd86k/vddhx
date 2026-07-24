/// Prototype menubar widgets built on ddui's popup primitives.
///
/// ddui has no native menubar, but a menu is just a trigger button that opens
/// a popup positioned directly below it, which is exactly what mu_dropdown_ex
/// already does. These helpers reuse that pattern for a horizontal bar of
/// action menus. Kept local to vddhx for now; candidates for promotion into
/// ddui itself (as mu_begin_menu / mu_menu_item / mu_end_menu).
/// Authors: dd
module menu;

import core.stdc.string : strlen;
import ddui;

// Only one top-level menu is ever open at a time, so every menu shares a single
// popup container ("!menu") that is repositioned under whichever trigger is
// active. openMenu holds that trigger's id (0 when the bar is closed).
private __gshared mu_Id openMenu;

/// Begin a top-level menu in a menubar row.
///
/// Lay the triggers out with mu_layout_row first, then call this once per menu.
/// Returns: nonzero while this menu's dropdown is open. When it is, add items
/// with menu_item and finish with menu_end (same begin/end rule as popups).
int menu_begin(mu_Context* ctx, const(char)* label)
{
    mu_Id id = mu_get_id(ctx, label, cast(int) strlen(label));
    mu_Rect r = mu_layout_next(ctx);
    mu_update_control(ctx, id, r, 0);

    // Draw the trigger as a flat button.
    mu_draw_control_frame(ctx, id, r, MU_COLOR_BUTTON, 0);
    mu_draw_control_text(ctx, label, r, MU_COLOR_TEXT, 0);

    // Open on click. Clicking a different trigger closes the current menu via
    // the popup's own outside-click handling, so switching menus with a click
    // needs no extra bookkeeping.
    if (ctx.mouse_pressed == MU_MOUSE_LEFT && ctx.focus == id)
    {
        openMenu = id;
        mu_Container* cnt = mu_get_container(ctx, "!menu");
        cnt.rect = mu_Rect(r.x, r.y + r.h, 1, 1); // AUTOSIZE grows w/h to fit
        cnt.open = 1;
        ctx.hover_root = ctx.next_hover_root = cnt;
        mu_bring_to_front(ctx, cnt);
    }

    // Only the active menu fills the shared popup container.
    if (openMenu != id)
        return 0;

    int open = mu_begin_popup(ctx, "!menu");
    if (open == 0)
        openMenu = 0; // dismissed by an outside click
    return open;
}

/// Finish a menu opened with menu_begin. Call only when it returned nonzero.
void menu_end(mu_Context* ctx)
{
    mu_end_popup(ctx);
}

/// A clickable row inside an open menu. Returns nonzero when chosen, and closes
/// the menu so the caller can act on the selection.
int menu_item(mu_Context* ctx, const(char)* label)
{
    if (mu_button(ctx, label) == 0)
        return 0;

    mu_get_current_container(ctx).open = 0; // close after choosing
    openMenu = 0;
    return 1;
}
