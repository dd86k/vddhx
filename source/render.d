/// Glue between ddui (microui) draw commands and SDL3's 2D renderer.
///
/// Text is drawn with SDL3_ttf through the renderer text engine, whose glyph
/// atlas spans every open face, so one string can pull glyphs from several
/// (base + CJK + symbols). UI icons go the same way rather than through a baked
/// bitmap strip.
/// Authors: dd86k <dd@dax.moe>
module render;

import core.stdc.string : strlen;
import std.file : exists;
import std.format : format;
import std.string : fromStringz, toStringz;
import bindbc.sdl; // publicly re-exports SDL3_ttf (TTF_*) under the static config
import ddlogger;
import ddui;
import elite : MU_COMMAND_SHIP, elite_draw;

// Point size the faces are opened at. render_text_height reports the real TTF
// line height of whichever face a command used, so this only sets the scale.
private enum float FONT_SIZE = 14.0f;

// The renderer text engine caches rasterised glyphs across every open face.
private __gshared TTF_TextEngine* engine;

// Both carry the same fallback chain, so missing glyphs resolve whichever face
// is selected.
private __gshared TTF_Font* fontUI;
private __gshared TTF_Font* fontMono;

// Fallback faces, retained so render_quit can close them after the primaries.
private __gshared TTF_Font*[8] fallbacks;
private __gshared size_t fallbackCount;

private struct Icon
{
    dchar code;
    immutable(char)* glyph;
    immutable(char)* plain;
}

// Drawn via the UI face and its symbol fallback. Index 0 is unused. `plain` is
// what iconText falls back to when no open face carries the codepoint: an ugly
// close button beats one that cannot be rendered.
private immutable Icon[MU_ICON_MAX] icons = [
    MU_ICON_CLOSE:     Icon('✕', "✕", "x"),
    MU_ICON_CHECK:     Icon('✓', "✓", "*"),
    MU_ICON_COLLAPSED: Icon('▶', "▶", ">"),
    MU_ICON_EXPANDED:  Icon('▼', "▼", "v"),
    MU_ICON_DROPDOWN:  Icon('▾', "▾", "v"),
];

// Resolved once the faces are open, since the answer depends on what they hold.
private __gshared immutable(char)*[MU_ICON_MAX] iconText;

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
    // In general: fontconfig first, these second
    private immutable string[] uiPaths = [
        "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/TTF/NotoSans-Regular.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
        "/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
    ];
    private immutable string[] monoPaths = [
        "/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf",
        "/usr/share/fonts/noto/NotoSansMono-Regular.ttf",
        "/usr/share/fonts/TTF/NotoSansMono-Regular.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
        "/usr/share/fonts/dejavu/DejaVuSansMono.ttf",
        "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
        "/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
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
/// Returns: null on success, else a reason worded for the user.
string render_init(SDL_Renderer* renderer)
{
    if (TTF_Init() == false)
        return format("TTF_Init: %s", SDL_GetError().fromStringz);

    engine = TTF_CreateRendererTextEngine(renderer);
    if (engine is null)
        return format("TTF_CreateRendererTextEngine: %s", SDL_GetError().fromStringz);

    // Without this the renderer writes fills as-is: a translucent tint (the
    // minimap's viewport marker) comes out solid, and the fully transparent
    // MU_COLOR_PANELBG paints black over whatever the panel sits on.
    SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_BLEND);

    // Nothing here consults SDL_GetError: a face is missing because nothing on
    // the machine matched, which SDL never saw.
    fontUI = openFace("UI", "sans-serif", 0, uiPaths);
    if (fontUI is null)
    {
        logCritical("no UI font; looked for %-(%s, %)", uiPaths);
        return "No font found.\n\nInstall a TrueType font: fonts-noto or " ~
            "fonts-dejavu will do.";
    }

    // Missing the mono face is not fatal, the hex panel merely goes unaligned.
    fontMono = openFace("mono", "monospace", 0, monoPaths);
    if (fontMono is null)
    {
        logWarn("no monospace font, falling back to the UI face (the hex grid " ~
            "will not align); install one of: %s", monoPaths);
        fontMono = fontUI;
    }

    // A match is checked for the one glyph that was the point of asking: given a
    // pattern nothing installed can satisfy, fontconfig still answers with its
    // best effort rather than nothing.
    // Attempt to match a glyph. fontconfig still answers
    addFallback("CJK", ":lang=ja", '一', cjkPaths);
    addFallback("symbol",
        format(":charset=%04X", cast(uint) icons[MU_ICON_CLOSE].code),
        icons[MU_ICON_CLOSE].code, symPaths);

    // Once the chain is complete: TTF_FontHasGlyph follows fallbacks, so this
    // asks the whole set at once.
    foreach (size_t i, ref immutable(Icon) icon; icons)
    {
        if (icon.glyph is null)
            continue;
        bool has = TTF_FontHasGlyph(fontUI, icon.code);
        iconText[i] = has ? icon.glyph : icon.plain;
        if (has == false)
            logInfo("no glyph for U+%04X, drawing icon %u as '%s'", cast(uint) icon.code,
                cast(uint) i, icon.plain.fromStringz);
    }
    return null;
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
    // TTF_GetStringSize reads a zero length as "the string is NUL-terminated",
    // which would run off the end of a caller's slice; an empty string measures
    // zero either way, so answer that here rather than handing it over.
    if (len == 0) return 0;
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
        case MU_COMMAND_SHIP: // The secret!
            elite_draw(renderer, cmd.rect.rect);
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

// A face for one role: fontconfig's answer for the pattern, then the built-in
// paths. `probe` is a codepoint the face has to carry, or 0 to take whatever
// comes back.
TTF_Font* openFace(string role, string pattern, dchar probe, const(string)[] paths)
{
    string matched = fc_match(pattern);
    if (matched.length)
        if (TTF_Font* f = openPath(role, matched, probe))
            return f;

    foreach (string p; paths)
        if (TTF_Font* f = openPath(role, p, probe))
            return f;

    return null;
}

TTF_Font* openPath(string role, string path, dchar probe)
{
    if (exists(path) == false)
        return null;
    TTF_Font* f = TTF_OpenFont(path.toStringz, FONT_SIZE);
    if (f is null)
        return null;
    if (probe == 0 || TTF_FontHasGlyph(f, probe))
    {
        logInfo("%s face: %s", role, path);
        return f;
    }
    TTF_CloseFont(f);
    return null;
}

// Open one fallback face and register it on both primaries.
void addFallback(string role, string pattern, dchar probe, const(string)[] paths)
{
    if (fallbackCount >= fallbacks.length)
        return;
    TTF_Font* f = openFace(role, pattern, probe, paths);
    if (f is null)
    {
        logInfo("no %s face; those glyphs will draw blank", role);
        return;
    }
    fallbacks[fallbackCount++] = f;
    TTF_AddFallbackFont(fontUI, f);
    if (fontMono !is fontUI)
        TTF_AddFallbackFont(fontMono, f);
}

// fontconfig, opened at runtime so that it stays a nicety rather than a link-time
// dependency: SDL3_ttf does not pull it in, and a container may not have it.
version (Posix)
{
    import core.sys.posix.dlfcn : RTLD_LAZY, dlopen, dlsym;

    extern (C) nothrow @nogc
    {
        alias fcInit_t             = int function();
        alias fcNameParse_t        = void* function(const(char)*);
        alias fcConfigSubstitute_t = int function(void*, void*, int);
        alias fcDefaultSubstitute_t = void function(void*);
        alias fcFontMatch_t        = void* function(void*, void*, int*);
        alias fcPatternGetString_t = int function(void*, const(char)*, int, const(char)**);
        alias fcPatternDestroy_t   = void function(void*);
    }

    private __gshared fcNameParse_t         FcNameParse;
    private __gshared fcConfigSubstitute_t  FcConfigSubstitute;
    private __gshared fcDefaultSubstitute_t FcDefaultSubstitute;
    private __gshared fcFontMatch_t         FcFontMatch;
    private __gshared fcPatternGetString_t  FcPatternGetString;
    private __gshared fcPatternDestroy_t    FcPatternDestroy;
    private __gshared bool fcTried;

    // Returns: the file fontconfig matches the pattern to, or null when it has
    //          nothing to say (library absent, or no font installed at all).
    string fc_match(string pattern)
    {
        if (fcOpen() == false)
            return null;

        void* pat = FcNameParse(pattern.toStringz);
        if (pat is null)
            return null;
        scope(exit) FcPatternDestroy(pat);

        // The pair every fontconfig client runs before matching: the first applies
        // the user's and the system's rules, the second fills what they left unset.
        FcConfigSubstitute(null, pat, FcMatchPattern);
        FcDefaultSubstitute(pat);

        int result;
        void* match = FcFontMatch(null, pat, &result);
        if (match is null)
            return null;
        scope(exit) FcPatternDestroy(match);

        const(char)* file;
        if (FcPatternGetString(match, "file", 0, &file) != FcResultMatch || file is null)
            return null;
        return file.fromStringz.idup;
    }

    private enum FcMatchPattern = 0;
    private enum FcResultMatch  = 0;

    private bool fcOpen()
    {
        if (fcTried)
            return FcFontMatch !is null;
        fcTried = true;

        void* lib = dlopen("libfontconfig.so.1", RTLD_LAZY);
        if (lib is null)
            lib = dlopen("libfontconfig.so", RTLD_LAZY);
        if (lib is null)
        {
            logInfo("no fontconfig, falling back to known font paths");
            return false;
        }

        fcInit_t FcInit;
        bool bind(T)(ref T fn, string name)
        {
            fn = cast(T) dlsym(lib, name.ptr); // string literals are NUL-terminated
            return fn !is null;
        }
        if (bind(FcInit, "FcInit") == false ||
            bind(FcNameParse, "FcNameParse") == false ||
            bind(FcConfigSubstitute, "FcConfigSubstitute") == false ||
            bind(FcDefaultSubstitute, "FcDefaultSubstitute") == false ||
            bind(FcFontMatch, "FcFontMatch") == false ||
            bind(FcPatternGetString, "FcPatternGetString") == false ||
            bind(FcPatternDestroy, "FcPatternDestroy") == false)
        {
            logWarn("fontconfig is missing symbols, ignoring it");
            FcFontMatch = null;
            return false;
        }

        if (FcInit() == 0)
        {
            logWarn("FcInit failed, ignoring fontconfig");
            FcFontMatch = null;
            return false;
        }
        return true;
    }
}
else
{
    string fc_match(string pattern) => null; // Windows: the paths below are it
}

void draw_rect(SDL_Renderer* renderer, mu_Rect rect, mu_Color color)
{
    if (color.a == 0) // fully transparent: blending would leave the target as-is
        return;
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
    immutable(char)* glyph = iconText[id];
    if (glyph is null)
        return;

    TTF_Text* text = TTF_CreateText(engine, fontUI, glyph, 0);
    if (text is null)
        return;
    scope(exit) TTF_DestroyText(text);

    TTF_SetTextColor(text, color.r, color.g, color.b, color.a);

    int w, h;
    TTF_GetTextSize(text, &w, &h);
    int x = rect.x + (rect.w - w) / 2;
    int y = rect.y + (rect.h - h) / 2;
    TTF_DrawRendererText(text, x, y);
}
