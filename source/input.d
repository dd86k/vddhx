/// SDL input events into ddui and the UI. All key bindings live here.
module input;

import std.string : fromStringz;
import bindbc.sdl;
import ddui;
import hexview;
import omnibar : OMNI_COMMAND, OMNI_ADDRESS, OMNI_FIND, OMNI_INSPECT,
    OMNI_KEY_UP, OMNI_KEY_DOWN, OMNI_KEY_PAGEUP, OMNI_KEY_PAGEDOWN;
import ui;

/// Route one input event (pointer, wheel, text, drops, keys). Others are the
/// main loop's.
void input_event(mu_Context* ctx, ref const(SDL_Event) event)
{
    // Dismiss the status message before dispatch, so the event can post its own.
    // Modifiers alone don't dismiss (Ctrl of Ctrl+F acts on the message).
    if ((event.type == SDL_EVENT_KEY_DOWN && modifierKey(event.key.key) == false) ||
        event.type == SDL_EVENT_MOUSE_BUTTON_DOWN)
        ui_status_dismiss();

    switch (event.type)
    {
    case SDL_EVENT_MOUSE_MOTION:
        mu_input_mousemove(ctx, cast(int) event.motion.x, cast(int) event.motion.y);
        break;
    case SDL_EVENT_MOUSE_WHEEL:
        // Shift+wheel scrolls sideways, for mice without tilt.
        if (SDL_GetModState() & SDL_KMOD_SHIFT)
            mu_input_scroll(ctx, cast(int)(event.wheel.y * -30), 0);
        else
            mu_input_scroll(ctx, cast(int)(event.wheel.x * 30), cast(int)(event.wheel.y * -30));
        break;
    case SDL_EVENT_TEXT_INPUT:
        // Brackets step bookmarks, like ddhx. Bound to the typed character, not the
        // keycode: on many layouts they're behind AltGr (e.g. fr-ca). The omnibar
        // keeps its brackets.
        if (ui_omni_active() == false && event.text.text && event.text.text[0] && event.text.text[1] == 0)
        {
            if (event.text.text[0] == ']')
            {
                ui_mark_step(1);
                break;
            }
            if (event.text.text[0] == '[')
            {
                ui_mark_step(-1);
                break;
            }
        }
        mu_input_text(ctx, event.text.text);
        break;
    case SDL_EVENT_DROP_POSITION:
        // Highlight the drop target pane.
        ui_drop_hover(cast(int) event.drop.x, cast(int) event.drop.y);
        break;
    case SDL_EVENT_DROP_BEGIN, SDL_EVENT_DROP_COMPLETE:
        ui_drop_clear();
        break;
    case SDL_EVENT_DROP_FILE:
        // SDL owns the string; copy it.
        if (event.drop.data)
            ui_drop_file(event.drop.data.fromStringz.idup,
                cast(int) event.drop.x, cast(int) event.drop.y);
        break;
    case SDL_EVENT_MOUSE_BUTTON_DOWN, SDL_EVENT_MOUSE_BUTTON_UP:
        int btn = mouseButton(event.button.button);
        if (btn == 0)
            break;
        int x = cast(int) event.button.x, y = cast(int) event.button.y;
        if (event.type == SDL_EVENT_MOUSE_BUTTON_DOWN)
            mu_input_mousedown(ctx, x, y, btn);
        else
            mu_input_mouseup(ctx, x, y, btn);
        break;
    case SDL_EVENT_KEY_DOWN, SDL_EVENT_KEY_UP:
        // Omnibar: Ctrl+E opens the tab switcher, other keys open their mode directly
        // and toggle it closed. Ctrl+G, Ctrl+F, Alt+I match ddhx.
        if (event.type == SDL_EVENT_KEY_DOWN && event.key.mod & SDL_KMOD_CTRL)
        {
            if (event.key.key == SDLK_E)
            {
                ui_omni_toggle();
                break;
            }
            if (event.key.key == SDLK_P && event.key.mod & SDL_KMOD_SHIFT)
            {
                ui_omni_toggle(OMNI_COMMAND);
                break;
            }
            if (event.key.key == SDLK_G)
            {
                ui_omni_toggle(OMNI_ADDRESS);
                break;
            }
            if (event.key.key == SDLK_F)
            {
                ui_omni_toggle(OMNI_FIND);
                break;
            }
            // Text size, any time. Plus too: some layouts have it unshifted.
            switch (event.key.key)
            {
            case SDLK_EQUALS, SDLK_PLUS, SDLK_KP_PLUS: ui_zoom(1);  return;
            case SDLK_MINUS, SDLK_KP_MINUS:            ui_zoom(-1); return;
            case SDLK_0, SDLK_KP_0:                    ui_zoom(0);  return;
            default:
            }
        }
        if (event.type == SDL_EVENT_KEY_DOWN && event.key.mod & SDL_KMOD_ALT &&
            event.key.key == SDLK_I)
        {
            ui_omni_toggle(OMNI_INSPECT);
            break;
        }
        // While open it owns the keyboard; panel chords and hex digits would interfere.
        if (ui_omni_active())
        {
            if (event.type == SDL_EVENT_KEY_DOWN && event.key.key == SDLK_ESCAPE)
            {
                ui_omni_close();
                break;
            }
            int okey = omniKey(event.key.key);
            if (okey == 0)
                break;
            if (event.type == SDL_EVENT_KEY_DOWN)
                mu_input_keydown(ctx, okey);
            else
                mu_input_keyup(ctx, okey);
            break;
        }
        // After the omnibar, which handles its own Escape.
        if (event.type == SDL_EVENT_KEY_DOWN && event.key.key == SDLK_ESCAPE &&
            ui_job_cancel())
            break;
        // Alt+1..9: tab in focused pane (Ctrl+1..9 is panes). After the omnibar,
        // which would take them as text.
        if (event.type == SDL_EVENT_KEY_DOWN && event.key.mod & SDL_KMOD_ALT &&
            event.key.key >= SDLK_1 && event.key.key <= SDLK_9)
        {
            ui_select_tab(event.key.key - SDLK_1);
            break;
        }
        // Menu shortcuts.
        if (event.type == SDL_EVENT_KEY_DOWN && event.key.mod & SDL_KMOD_CTRL)
        {
            // Push SDL_EVENT_QUIT so it goes through the unsaved-changes check.
            if (event.key.key == SDLK_Q)
            {
                SDL_Event quit; // .init zeroes the union
                quit.type = SDL_EVENT_QUIT;
                SDL_PushEvent(&quit);
                break;
            }
            if (event.key.key == SDLK_O)
            {
                ui_open_dialog();
                break;
            }
            // Handle Ctrl+Tab here so ddui doesn't take it as a focus step.
            if (event.key.key == SDLK_T)
            {
                ui_new_tab();
                break;
            }
            if (event.key.key == SDLK_W)
            {
                ui_close_current_tab();
                break;
            }
            if (event.key.key == SDLK_TAB)
            {
                ui_cycle_tab(event.key.mod & SDL_KMOD_SHIFT ? -1 : 1);
                break;
            }
            // Ctrl+\ splits (VS Code), Shift splits down; Ctrl+1..9 focuses panes.
            // Layouts with backslash behind AltGr can use the omnibar's split commands.
            if (event.key.key == SDLK_BACKSLASH)
            {
                if (event.key.mod & SDL_KMOD_SHIFT)
                    ui_split_down();
                else
                    ui_split();
                break;
            }
            if (event.key.key >= SDLK_1 && event.key.key <= SDLK_9)
            {
                ui_focus_pane(event.key.key - SDLK_1);
                break;
            }
            // Ctrl+S saves in place (dialog if no path); Shift forces Save As.
            if (event.key.key == SDLK_S)
            {
                if (event.key.mod & SDL_KMOD_SHIFT)
                    ui_save_as();
                else
                    ui_save();
                break;
            }
            if (event.key.key == SDLK_X)
            {
                if (event.key.mod & SDL_KMOD_SHIFT)
                    ui_cut_text();
                else
                    ui_cut();
                break;
            }
            // Shift copies the text lane. Handled here: Shift doesn't change the keycode,
            // so muiKey would give MU_KEY_COPY for both.
            if (event.key.key == SDLK_C)
            {
                if (event.key.mod & SDL_KMOD_SHIFT)
                    ui_copy_text();
                else
                    ui_copy();
                break;
            }
            if (event.key.key == SDLK_V)
            {
                ui_paste();
                break;
            }
            if (event.key.key == SDLK_N)
            {
                ui_find_repeat((event.key.mod & SDL_KMOD_SHIFT) != 0);
                break;
            }
            if (event.key.key == SDLK_B)
            {
                if (event.key.mod & SDL_KMOD_SHIFT)
                    ui_mark_name();
                else
                    ui_mark_toggle();
                break;
            }
            // ddhx skip back/forward; intercepted so the panel doesn't step a nibble.
            // Shift selects the skipped run.
            if (event.key.key == SDLK_LEFT || event.key.key == SDLK_RIGHT)
            {
                ui_skip_element(event.key.key == SDLK_LEFT, (event.key.mod & SDL_KMOD_SHIFT) != 0);
                break;
            }
        }
        int key = muiKey(event.key.key);
        if (key == 0)
            break;
        if (event.type == SDL_EVENT_KEY_DOWN)
            mu_input_keydown(ctx, key);
        else
            mu_input_keyup(ctx, key);
        break;
    default:
    }
}

/// Modifier and lock keys. Only used to decide what dismisses a status message.
private bool modifierKey(SDL_KeyCode key)
{
    switch (key)
    {
    case SDLK_LSHIFT, SDLK_RSHIFT,
         SDLK_LCTRL, SDLK_RCTRL,
         SDLK_LALT, SDLK_RALT,
         SDLK_LGUI, SDLK_RGUI,
         SDLK_CAPSLOCK, SDLK_NUMLOCKCLEAR, SDLK_SCROLLLOCK,
         SDLK_MODE:
        return true;
    default:
        return false;
    }
}

/// SDL3 keycode to omnibar key (0 if unmapped).
///
/// Separate from muiKey: its HEX_KEY_* bits collide with ddui's editing keys
/// (HEX_KEY_HOME == MU_KEY_DELETE). ddui only honours copy/cut/paste/select-all
/// while Ctrl is held.
private int omniKey(SDL_KeyCode key)
{
    switch (key)
    {
    case SDLK_RETURN, SDLK_KP_ENTER: return MU_KEY_RETURN;
    case SDLK_BACKSPACE:             return MU_KEY_BACKSPACE;
    case SDLK_LSHIFT, SDLK_RSHIFT:   return MU_KEY_SHIFT;
    case SDLK_LCTRL, SDLK_RCTRL:     return MU_KEY_CTRL;
    case SDLK_LALT, SDLK_RALT:       return MU_KEY_ALT;
    case SDLK_LEFT:                  return MU_KEY_LEFT;
    case SDLK_RIGHT:                 return MU_KEY_RIGHT;
    case SDLK_HOME:                  return MU_KEY_HOME;
    case SDLK_END:                   return MU_KEY_END;
    case SDLK_DELETE:                return MU_KEY_DELETE;
    case SDLK_C:                     return MU_KEY_COPY;      // with Ctrl
    case SDLK_X:                     return MU_KEY_CUT;
    case SDLK_V:                     return MU_KEY_PASTE;
    case SDLK_A:                     return MU_KEY_SELECTALL;
    // Fills in the selected row. Checked before Ctrl+Tab since the box owns the
    // keyboard.
    case SDLK_TAB:                   return MU_KEY_TAB;
    case SDLK_UP:                    return OMNI_KEY_UP;
    case SDLK_DOWN:                  return OMNI_KEY_DOWN;
    case SDLK_PAGEUP:                return OMNI_KEY_PAGEUP;
    case SDLK_PAGEDOWN:              return OMNI_KEY_PAGEDOWN;
    default:                         return 0;
    }
}

/// SDL3 mouse button to ddui flag (0 if unmapped).
private int mouseButton(SDL_MouseButton button)
{
    switch (button)
    {
    case SDL_BUTTON_LEFT:   return MU_MOUSE_LEFT;
    case SDL_BUTTON_RIGHT:  return MU_MOUSE_RIGHT;
    case SDL_BUTTON_MIDDLE: return MU_MOUSE_MIDDLE;
    default:                return 0;
    }
}

/// SDL3 keycode to ddui key flags (0 if unmapped). Modifiers come from their
/// keycodes, not the event's mod mask: SDL3 clears the bit before key-up, which
/// left it stuck in ddui.
private int muiKey(SDL_KeyCode key)
{
    switch (key)
    {
    case SDLK_RETURN, SDLK_KP_ENTER: return MU_KEY_RETURN;
    case SDLK_BACKSPACE:             return MU_KEY_BACKSPACE;
    case SDLK_TAB:                   return MU_KEY_TAB;
    case SDLK_LSHIFT, SDLK_RSHIFT:   return MU_KEY_SHIFT;
    case SDLK_LCTRL, SDLK_RCTRL:     return MU_KEY_CTRL;
    case SDLK_LALT, SDLK_RALT:       return MU_KEY_ALT;
    case SDLK_LEFT:                  return HEX_KEY_LEFT;
    case SDLK_RIGHT:                 return HEX_KEY_RIGHT;
    case SDLK_UP:                    return HEX_KEY_UP;
    case SDLK_DOWN:                  return HEX_KEY_DOWN;
    case SDLK_HOME:                  return HEX_KEY_HOME;
    case SDLK_END:                   return HEX_KEY_END;
    case SDLK_PAGEUP:                return HEX_KEY_PGUP;
    case SDLK_PAGEDOWN:              return HEX_KEY_PGDN;
    case SDLK_INSERT:                return HEX_KEY_INS;
    case SDLK_DELETE:                return HEX_KEY_DEL;
    case SDLK_Z:                     return HEX_KEY_UNDO; // assumes with Ctrl
    case SDLK_Y:                     return HEX_KEY_REDO; // assumes with Ctrl
    default:                         return 0;
    }
}

