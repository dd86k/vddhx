/// Glue between ddui (microui) draw commands and SDL3's 2D renderer.
///
/// Text is drawn with SDL3_ttf: real system fonts, located by probing known
/// Noto install paths, each with a Noto fallback chain for glyphs the primary
/// face lacks. Drawing goes through the renderer text engine, which keeps its
/// own multi-font glyph atlas, so one string can transparently pull glyphs from
/// several faces (base + CJK + symbols). UI icons are Unicode glyphs drawn
/// through the same path rather than a baked bitmap strip.
/// Authors: dd
module render;

import core.stdc.string : strlen;
import std.file : exists;
import std.string : toStringz;
import bindbc.sdl; // publicly re-exports SDL3_ttf (TTF_*) under the static config
import ddui;

// Point size the faces are opened at. render_text_height reports the real TTF
// line height of whichever face a command used, so this only sets the scale.
private enum float FONT_SIZE = 14.0f;

// The renderer text engine caches rasterised glyphs across every open face.
private __gshared TTF_TextEngine* engine;

// Proportional face for general UI (the default ctx.style.font) plus a
// monospace face reserved for the hex panel component. Each carries the same
// fallback chain so missing glyphs resolve no matter which face is selected.
private __gshared TTF_Font* fontUI;
private __gshared TTF_Font* fontMono;

// Fallback faces, retained so render_quit can close them after the primaries.
private __gshared TTF_Font*[8] fallbacks;
private __gshared size_t fallbackCount;

// UI icons as Unicode glyphs, drawn via the UI face and its symbol fallback.
// Indexed by ddui's MU_ICON_* ids; index 0 is unused.
private immutable(char)*[MU_ICON_MAX] iconGlyph = [
    MU_ICON_CLOSE:     "✕", // ✕ multiplication x
    MU_ICON_CHECK:     "✓", // ✓ check mark
    MU_ICON_COLLAPSED: "▶", // ▶ right-pointing triangle
    MU_ICON_EXPANDED:  "▼", // ▼ down-pointing triangle
    MU_ICON_DROPDOWN:  "▾", // ▾ small down-pointing triangle
];

// Known system locations for each face, tried in order. "System fonts" here
// means probing these paths, since neither SDL nor SDL_ttf enumerates fonts.
version (Windows)
{
    private immutable string[] uiPaths = [
        `C:\Windows\Fonts\NotoSans-Regular.ttf`,
        `C:\Windows\Fonts\segoeui.ttf`,
        `C:\Windows\Fonts\arial.ttf`,
    ];
    private immutable string[] monoPaths = [
        `C:\Windows\Fonts\NotoSansMono-Regular.ttf`,
        `C:\Windows\Fonts\consola.ttf`,
    ];
    private immutable string[] cjkPaths = [
        `C:\Windows\Fonts\NotoSansCJKsc-Regular.otf`,
        `C:\Windows\Fonts\msgothic.ttc`,
    ];
    private immutable string[] symPaths = [
        `C:\Windows\Fonts\NotoSansSymbols-Regular.ttf`,
        `C:\Windows\Fonts\seguisym.ttf`,
    ];
}
else
{
    private immutable string[] uiPaths = [
        "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/TTF/NotoSans-Regular.ttf",
    ];
    private immutable string[] monoPaths = [
        "/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf",
        "/usr/share/fonts/noto/NotoSansMono-Regular.ttf",
        "/usr/share/fonts/TTF/NotoSansMono-Regular.ttf",
    ];
    private immutable string[] cjkPaths = [
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
    ];
    private immutable string[] symPaths = [
        "/usr/share/fonts/truetype/noto/NotoSansSymbols2-Regular.ttf",
        "/usr/share/fonts/truetype/noto/NotoSansSymbols-Regular.ttf",
        "/usr/share/fonts/noto/NotoSansSymbols2-Regular.ttf",
    ];
}

/// Bring up SDL3_ttf, the text engine, and the font faces. Call once after the
/// renderer is created.
/// Returns: false on failure (SDL_GetError has the reason).
bool render_init(SDL_Renderer* renderer)
{
    if (TTF_Init() == false)
        return false;

    engine = TTF_CreateRendererTextEngine(renderer);
    if (engine is null)
        return false;

    fontUI = openFirst(uiPaths);
    if (fontUI is null)
        return false;

    // Missing the mono face is not fatal: fall back to the UI face so text
    // still renders (the hex panel just will not be monospaced until installed).
    fontMono = openFirst(monoPaths);
    if (fontMono is null)
        fontMono = fontUI;

    addFallback(cjkPaths);
    addFallback(symPaths);
    return true;
}

/// Close every face and tear down the text engine and SDL3_ttf.
void render_quit()
{
    foreach (ref f; fallbacks[0 .. fallbackCount])
    {
        TTF_CloseFont(f);
        f = null;
    }
    fallbackCount = 0;

    if (fontMono && fontMono !is fontUI)
        TTF_CloseFont(fontMono);
    fontMono = null;

    if (fontUI)
        TTF_CloseFont(fontUI);
    fontUI = null;

    if (engine)
    {
        TTF_DestroyRendererTextEngine(engine);
        engine = null;
    }
    TTF_Quit();
}

/// The proportional face for general UI; assign to ctx.style.font after mu_init.
TTF_Font* render_font_ui() => fontUI;

/// The monospace face reserved for the hex panel component. Push it into
/// ctx.style.font around that component, then restore the UI face.
TTF_Font* render_font_mono() => fontMono;

/// Text measuring callbacks, handed to mu_Context. The font handle is a
/// TTF_Font*, so measurement follows whichever face the widget selected.
extern (C) int render_text_width(mu_Font font, const(char)* str, int len)
{
    if (len < 0) len = cast(int) strlen(str);
    TTF_Font* f = cast(TTF_Font*) font;
    if (f is null) f = fontUI;
    int w;
    TTF_GetStringSize(f, str, len, &w, null);
    return w;
}

/// ditto
extern (C) int render_text_height(mu_Font font)
{
    TTF_Font* f = cast(TTF_Font*) font;
    if (f is null) f = fontUI;
    return TTF_GetFontHeight(f);
}

/// Replay every ddui draw command onto the renderer for this frame.
///
/// Iterate with mu_get_next_command rather than mu_command_range: the latter
/// walks the raw command buffer in insertion order, but ddui stitches its root
/// containers into z-index order with JUMP commands. Following the jumps is
/// what makes popups (menus, dropdowns) paint on top of the window content.
void render_commands(SDL_Renderer* renderer, mu_Context* ctx)
{
    mu_Command* cmd;
    while (mu_get_next_command(ctx, &cmd))
    {
        switch (cmd.type)
        {
        case MU_COMMAND_RECT:
            draw_rect(renderer, cmd.rect.rect, cmd.rect.color);
            break;
        case MU_COMMAND_TEXT:
            draw_text(cmd.text.font, mu_command_text(ctx, cmd), cmd.text.pos, cmd.text.color);
            break;
        case MU_COMMAND_ICON:
            draw_icon(cmd.icon.id, cmd.icon.rect, cmd.icon.color);
            break;
        case MU_COMMAND_CLIP:
            SDL_Rect clip = SDL_Rect(cmd.clip.rect.x, cmd.clip.rect.y,
                cmd.clip.rect.w, cmd.clip.rect.h);
            SDL_SetRenderClipRect(renderer, &clip);
            break;
        default:
        }
    }
    // Leave clipping disabled for whatever is drawn after us.
    SDL_SetRenderClipRect(renderer, null);
}

private:

// Open the first face that exists from a candidate list.
TTF_Font* openFirst(const(string)[] paths)
{
    foreach (p; paths)
    {
        if (exists(p) == false)
            continue;
        if (TTF_Font* f = TTF_OpenFont(p.toStringz, FONT_SIZE))
            return f;
    }
    return null;
}

// Open one fallback face and register it on both primaries.
void addFallback(const(string)[] paths)
{
    if (fallbackCount >= fallbacks.length)
        return;
    TTF_Font* f = openFirst(paths);
    if (f is null)
        return;
    fallbacks[fallbackCount++] = f;
    TTF_AddFallbackFont(fontUI, f);
    if (fontMono !is fontUI)
        TTF_AddFallbackFont(fontMono, f);
}

void draw_rect(SDL_Renderer* renderer, mu_Rect rect, mu_Color color)
{
    SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, color.a);
    SDL_FRect dst = SDL_FRect(rect.x, rect.y, rect.w, rect.h);
    SDL_RenderFillRect(renderer, &dst);
}

void draw_text(mu_Font font, const(char)* str, mu_Vec2 pos, mu_Color color)
{
    TTF_Font* f = cast(TTF_Font*) font;
    if (f is null) f = fontUI;

    // length 0: SDL_ttf treats the string as null-terminated.
    TTF_Text* text = TTF_CreateText(engine, f, str, 0);
    if (text is null)
        return;
    scope(exit) TTF_DestroyText(text);

    TTF_SetTextColor(text, color.r, color.g, color.b, color.a);
    TTF_DrawRendererText(text, pos.x, pos.y);
}

void draw_icon(int id, mu_Rect rect, mu_Color color)
{
    if (id <= 0 || id >= MU_ICON_MAX)
        return;
    immutable(char)* glyph = iconGlyph[id];
    if (glyph is null)
        return;

    TTF_Text* text = TTF_CreateText(engine, fontUI, glyph, 0);
    if (text is null)
        return;
    scope(exit) TTF_DestroyText(text);

    TTF_SetTextColor(text, color.r, color.g, color.b, color.a);

    // Centre the glyph in its cell.
    int w, h;
    TTF_GetTextSize(text, &w, &h);
    int x = rect.x + (rect.w - w) / 2;
    int y = rect.y + (rect.h - h) / 2;
    TTF_DrawRendererText(text, x, y);
}
