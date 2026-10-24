/// Prototype menubar widgets on ddui's popup primitives.
/// TODO: Move into ddui (mu_begin_menu / mu_menu_item / mu_end_menu).
/// Authors: dd86k <dd@dax.moe>
module menu;

import core.stdc.string : strlen;
import ddui;

// One shared popup ("!menu"), moved under the active trigger. 0 when closed.
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

    mu_draw_control_frame(ctx, id, r, MU_COLOR_BUTTON, 0);
    mu_draw_control_text(ctx, label, r, MU_COLOR_TEXT, 0);

    // Clicking another trigger closes this menu via the popup's outside-click.
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
