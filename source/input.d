/// SDL input events into ddui and the UI: every key binding lives here.
module input;

import std.string : fromStringz;
import bindbc.sdl;
import ddui;
import hexview;
import omnibar : OMNI_COMMAND, OMNI_ADDRESS, OMNI_FIND, OMNI_INSPECT,
    OMNI_KEY_UP, OMNI_KEY_DOWN, OMNI_KEY_PAGEUP, OMNI_KEY_PAGEDOWN;
import ui;

/// Route one input event: pointer, wheel, text, drops and keys. Anything else
/// (quit, window, renderer) is the loop's and is ignored here.
void input_event(mu_Context* ctx, ref const(SDL_Event) event)
{
    // Before the dispatch below, so an event that has something to say
    // still leaves its own message up. Modifiers alone are not an
    // acknowledgement: the Ctrl of a Ctrl+F is the user acting on the
    // message rather than dismissing it unread.
    if ((event.type == SDL_EVENT_KEY_DOWN && modifierKey(event.key.key) == false) ||
        event.type == SDL_EVENT_MOUSE_BUTTON_DOWN)
        ui_status_dismiss();

    switch (event.type)
    {
    case SDL_EVENT_MOUSE_MOTION:
        mu_input_mousemove(ctx, cast(int) event.motion.x, cast(int) event.motion.y);
        break;
    case SDL_EVENT_MOUSE_WHEEL:
        // Shift turns a plain wheel sideways, for mice without a tilt.
        if (SDL_GetModState() & SDL_KMOD_SHIFT)
            mu_input_scroll(ctx, cast(int)(event.wheel.y * -30), 0);
        else
            mu_input_scroll(ctx, cast(int)(event.wheel.x * 30), cast(int)(event.wheel.y * -30));
        break;
    case SDL_EVENT_TEXT_INPUT:
        // Bookmarks step on the bare brackets, as they do in ddhx, bound
        // to the character typed rather than a keycode: outside US ANSI
        // they are rarely a key of their own (fr-ca puts them behind
        // AltGr, whose unshifted keycode is not a bracket at all), and
        // this is what the layout actually produced. The omnibar is a text
        // box, so it keeps its own brackets.
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
        // Light up the pane being pointed at, so where the file would land
        // is visible before the button comes up.
        ui_drop_hover(cast(int) event.drop.x, cast(int) event.drop.y);
        break;
    case SDL_EVENT_DROP_BEGIN, SDL_EVENT_DROP_COMPLETE:
        ui_drop_clear();
        break;
    case SDL_EVENT_DROP_FILE:
        // SDL3 owns the path string (no free), so copy it before it goes.
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
        // The omnibar next: Ctrl+E raises it on the tab switcher, one key
        // per prefixed mode raises it straight on that one, and each key
        // puts away the mode it opens. Ctrl+G, Ctrl+F and Alt+I are what
        // ddhx binds goto, find and the inspector to.
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
        }
        if (event.type == SDL_EVENT_KEY_DOWN && event.key.mod & SDL_KMOD_ALT &&
            event.key.key == SDLK_I)
        {
            ui_omni_toggle(OMNI_INSPECT);
            break;
        }
        // While it is up it owns the keyboard, its keys going through
        // ddui's text-editing map rather than the panel's, whose chords
        // and hex digits would fight what is being typed.
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
        // After the omnibar, whose own Escape closes it: only then does the
        // key reach a walk the focused tab is waiting on.
        if (event.type == SDL_EVENT_KEY_DOWN && event.key.key == SDLK_ESCAPE &&
            ui_job_cancel())
            break;
        // Alt+1..9 picks a tab within the focused pane, counting the way
        // Ctrl+1..9 counts panes: one modifier per level of the grid, so a
        // number key is never ambiguous about which it means. After the
        // omnibar, whose text these would otherwise be typed into.
        if (event.type == SDL_EVENT_KEY_DOWN && event.key.mod & SDL_KMOD_ALT &&
            event.key.key >= SDLK_1 && event.key.key <= SDLK_9)
        {
            ui_select_tab(event.key.key - SDLK_1);
            break;
        }
        // Menu chords: the File and Edit entries, keyed the way every GUI
        // toolkit keys them.
        if (event.type == SDL_EVENT_KEY_DOWN && event.key.mod & SDL_KMOD_CTRL)
        {
            // Through SDL's queue rather than ending the loop here, so it
            // meets the same unsaved-changes check as the other routes.
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
            // Ctrl+Tab is caught here so it never reaches ddui as a focus
            // step.
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
            // Ctrl+\ is what VS Code splits with, Shift stacking the new
            // pane under the old one instead of alongside; Ctrl+1..9 is
            // the editor-group binding rather than the browser tab one.
            // On a layout that puts backslash behind AltGr neither fires,
            // and the omnibar's "Split Pane Right" / "Down" are the route
            // that always works.
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
            // Shift forces the Save As dialog; plain Ctrl+S writes in
            // place, falling back to the dialog when there is no path yet.
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
            // Shift copies the text lane instead of the hex one. Caught
            // here because Shift leaves the keycode alone: left to muiKey
            // both chords would arrive as MU_KEY_COPY.
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
            // ddhx's skip-back / skip-forward, caught here so the arrow
            // never reaches the panel, which would step one nibble.
            // Shift selects the run crossed rather than jumping over it.
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

/// Keys that cannot be a keystroke on their own, either half of a chord or a mode
/// the keyboard latches. Only used to decide what dismisses a status message.
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

/// Map an SDL3 keycode for the omnibar's text box (0 if unmapped).
///
/// The panel's map below sends arrows and paging keys as HEX_KEY_* bits, several
/// of which collide with ddui's editing keys (HEX_KEY_HOME shares a bit with
/// MU_KEY_DELETE): right for the grid, wrong for a text box.
///
/// Copy / cut / paste / select-all are mapped from the bare letters, ddui only
/// honouring those bits while Ctrl is held.
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
    case SDLK_X:                     return MU_KEY_CUT;       // ditto
    case SDLK_V:                     return MU_KEY_PASTE;     // ditto
    case SDLK_A:                     return MU_KEY_SELECTALL; // ditto
    // Reached before the Ctrl+Tab that cycles tabs, which is tested further down
    // the event handler: while the box is up it owns the keyboard, and this is the
    // key that fills it in from the row the list is on.
    case SDLK_TAB:                   return MU_KEY_TAB;
    case SDLK_UP:                    return OMNI_KEY_UP;
    case SDLK_DOWN:                  return OMNI_KEY_DOWN;
    case SDLK_PAGEUP:                return OMNI_KEY_PAGEUP;
    case SDLK_PAGEDOWN:              return OMNI_KEY_PAGEDOWN;
    default:                         return 0;
    }
}

/// Map an SDL3 mouse button to a ddui mouse flag (0 if unmapped).
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

/// Map an SDL3 keycode to ddui key flags (0 if unmapped). Modifiers come from
/// their own keycodes rather than the event's mod mask, so each physical key
/// toggles its bit symmetrically: on a modifier's key-up SDL3 reports the mask
/// with that bit already cleared, which left the bit stuck held in ddui. ddui
/// reads that held state itself, so Shift+Right needs only the arrow here.
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
    case SDLK_Z:                     return HEX_KEY_UNDO; // undo when Ctrl is held
    case SDLK_Y:                     return HEX_KEY_REDO; // redo when Ctrl is held
    default:                         return 0;
    }
}

