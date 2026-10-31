/// SDL input events into ddui and the UI. Key chords go through the bindings
/// (bindings.d) first.
module input;

import std.ascii : isAlphaNum;
import std.string : fromStringz;
import bindbc.sdl;
import ddui;
import hexview;
import bindings;
import omnibar : OMNI_ADDRESS, OMNI_FIND, OMNI_INSPECT,
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
        // The text of a key a binding just took.
        if (swallowText)
        {
            swallowText = false;
            break;
        }
        // Typed-character bindings (brackets, braces), matched on the character
        // so they follow the layout (behind AltGr on fr-ca).
        dchar ch = textChar(event.text.text);
        if (ch && capturing())
        {
            capture(Chord(ch, 0, true));
            break;
        }
        if (ch && typing(ctx) == false)
        {
            int id = bind_find(Chord(ch, 0, true));
            if (id >= 0)
            {
                run(id);
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
        bool down = event.type == SDL_EVENT_KEY_DOWN;
        if (down)
            swallowText = false;
        if (down && capturing() && modifierKey(event.key.key) == false)
        {
            captureKey(event.key.key, event.key.mod);
            break;
        }
        if (down && bindKey(ctx, event.key.key, event.key.mod))
            break;
        // While open it owns the keyboard. Panel keys and hex digits would interfere.
        if (ui_omni_active())
        {
            if (down && event.key.key == SDLK_ESCAPE)
            {
                ui_omni_close();
                break;
            }
            int okey = omniKey(event.key.key);
            if (okey == 0)
                break;
            if (down)
                mu_input_keydown(ctx, okey);
            else
                mu_input_keyup(ctx, okey);
            break;
        }
        // After the omnibar, which handles its own Escape.
        if (down && event.key.key == SDLK_ESCAPE && ui_job_cancel())
            break;
        // Alt+1..9: tab in focused pane, Ctrl+1..9: pane. After the omnibar,
        // which would take them as text.
        if (down && event.key.key >= SDLK_1 && event.key.key <= SDLK_9)
        {
            if (event.key.mod & SDL_KMOD_ALT)
            {
                ui_select_tab(event.key.key - SDLK_1);
                break;
            }
            if (event.key.mod & SDL_KMOD_CTRL)
            {
                ui_focus_pane(event.key.key - SDLK_1);
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

/// Text of the key a binding just took, dropped when it arrives.
private __gshared bool swallowText;

/// Run the command bound to a key press, if any. Returns: True if one ran.
private bool bindKey(mu_Context* ctx, SDL_Keycode key, SDL_Keymod mod)
{
    Chord c = bind_chord(key, mod);
    int id = bind_find(c);
    if (id < 0)
        return false;
    // Only some reach past the omnibar. Keys without Ctrl or Alt are text in a box.
    bool plain = (c.mods & (MOD_CTRL | MOD_ALT)) == 0;
    if (ui_omni_active())
    {
        if (bind_global(id) == false)
            return false;
    }
    else if (plain && typing(ctx))
        return false;
    run(id);
    swallowText = plain;
    return true;
}

/// Run bound command `id`. Omnibar keys toggle the box, and none of these take
/// the focus from it.
private void run(int id)
{
    switch (id)
    {
    case CMD_GOTO:       ui_omni_toggle(OMNI_ADDRESS); return;
    case CMD_FIND:       ui_omni_toggle(OMNI_FIND);    return;
    case CMD_FIND_BACK:  ui_find_back_toggle();        return;
    case CMD_INSPECT:    ui_omni_toggle(OMNI_INSPECT); return;
    case CMD_ZOOM_IN:    ui_zoom(1);                   return;
    case CMD_ZOOM_OUT:   ui_zoom(-1);                  return;
    case CMD_ZOOM_RESET: ui_zoom(0);                   return;
    default:             ui_omni_run(id);
    }
}

/// Whether Settings waits for a key. Leaving its tab stops it.
private bool capturing()
{
    if (bind_capturing() < 0)
        return false;
    if (ui_on_settings())
        return true;
    bind_capture(-1);
    return false;
}

/// Capture a key press for Settings. Esc cancels. Plain punctuation waits for
/// its typed character, the way such bindings match.
private void captureKey(SDL_Keycode key, SDL_Keymod mod)
{
    if (key == SDLK_ESCAPE)
    {
        bind_capture(-1);
        return;
    }
    Chord c = bind_chord(key, mod);
    if ((c.mods & (MOD_CTRL | MOD_ALT)) == 0 && key < 0x7F && key > ' ' &&
        isAlphaNum(cast(char) key) == false)
        return;
    if (c.key >= 0x80 && (c.key & SDLK_SCANCODE_MASK) == 0 && c.mods == 0)
        return; // non-ASCII layout key, same
    capture(c);
}

/// Bind `c` to the command being captured, telling what it ran before.
private void capture(Chord c)
{
    int id = bind_capturing();
    int was = bind_capture_take(c);
    swallowText = true;
    if (was >= 0 && was != id)
        ui_status("%s now runs %s, no longer %s", bind_label(c),
            bind_command_label(id), bind_command_label(was));
    else
        ui_status("%s now runs %s", bind_label(c), bind_command_label(id));
}

/// Whether a text box has the keyboard (omnibar, Settings fields).
private bool typing(mu_Context* ctx)
{
    return ui_omni_active() || (ctx.focus != 0 && ctx.focus == ctx.caret_id);
}

/// The one character in `text`, or 0.
private dchar textChar(const(char)* text)
{
    import std.utf : decode, UTFException;

    if (text is null || text[0] == 0)
        return 0;
    const(char)[] s = text.fromStringz;
    size_t i;
    dchar ch;
    try
        ch = decode(s, i);
    catch (UTFException)
        return 0;
    return i == s.length ? ch : 0;
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
/// (HEX_KEY_HOME == MU_KEY_DELETE). ddui only honors copy/cut/paste/select-all
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
    default:                         return 0;
    }
}

