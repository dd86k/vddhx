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
import std.path : baseName, buildPath;
import std.string : fromStringz, toStringz;
import bindbc.sdl; // publicly re-exports SDL3_ttf (TTF_*) under the static config
import ddlogger;
import ddui;
import elite : MU_COMMAND_SHIP, elite_draw;
import icon : exeDir;

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

// Shaped strings, keyed by face and content: the hex view alone draws two per
// visible byte each frame, and shaping them anew every time dominated the frame.
// Entries left unused for TEXT_TTL frames are dropped, so scrolling through
// offsets does not grow the cache without bound.
private struct TextKey
{
    const(TTF_Font)* font;
    const(char)[] str;

    size_t toHash() const nothrow @trusted => hashOf(str, cast(size_t) font);
    bool opEquals(ref const(TextKey) o) const nothrow @safe => font is o.font && str == o.str;
}
private struct TextEntry
{
    TTF_Text* text;
    uint frame;
}
private enum uint TEXT_TTL = 64;
private __gshared TextEntry[TextKey] textCache;
private __gshared TextKey[] textStale; // reused by the sweep
private __gshared uint textFrame;

// Font file names, tried in order against every directory font_dirs returns.
// Names may carry a subdirectory.
version (Windows)
{
    private immutable string[] uiNames = [
        "NotoSans-Regular.ttf",
        "segoeui.ttf",
        "arial.ttf",
    ];
    private immutable string[] monoNames = [
        "NotoSansMono-Regular.ttf",
        "consola.ttf",
    ];
    private immutable string[] cjkNames = [
        "NotoSansCJKsc-Regular.otf",
        "msgothic.ttc",
    ];
    private immutable string[] symNames = [
        "NotoSansSymbols-Regular.ttf",
        "seguisym.ttf",
    ];
}
else version (OSX)
{
    private immutable string[] uiNames = [
        "NotoSans-Regular.ttf",
        "SFNS.ttf",
        "Helvetica.ttc",
    ];
    private immutable string[] monoNames = [
        "NotoSansMono-Regular.ttf",
        "SFNSMono.ttf",
        "Menlo.ttc",
        "Monaco.ttf",
    ];
    private immutable string[] cjkNames = [
        "NotoSansCJK-Regular.ttc",
        "Hiragino Sans GB.ttc",
        "Supplemental/Arial Unicode.ttf",
    ];
    private immutable string[] symNames = [
        "NotoSansSymbols2-Regular.ttf",
        "Apple Symbols.ttf",
        "Supplemental/Arial Unicode.ttf",
    ];
}
else
{
    // Only reached without fontconfig, so the layouts of the major distributions.
    private immutable string[] uiNames = [
        "truetype/noto/NotoSans-Regular.ttf",
        "noto/NotoSans-Regular.ttf",
        "TTF/NotoSans-Regular.ttf",
        "truetype/dejavu/DejaVuSans.ttf",
        "dejavu/DejaVuSans.ttf",
        "TTF/DejaVuSans.ttf",
        "truetype/liberation/LiberationSans-Regular.ttf",
        "liberation/LiberationSans-Regular.ttf",
    ];
    private immutable string[] monoNames = [
        "truetype/noto/NotoSansMono-Regular.ttf",
        "noto/NotoSansMono-Regular.ttf",
        "TTF/NotoSansMono-Regular.ttf",
        "truetype/dejavu/DejaVuSansMono.ttf",
        "dejavu/DejaVuSansMono.ttf",
        "TTF/DejaVuSansMono.ttf",
        "truetype/liberation/LiberationMono-Regular.ttf",
        "liberation/LiberationMono-Regular.ttf",
    ];
    private immutable string[] cjkNames = [
        "opentype/noto/NotoSansCJK-Regular.ttc",
        "truetype/noto/NotoSansCJK-Regular.ttc",
        "noto-cjk/NotoSansCJK-Regular.ttc",
    ];
    private immutable string[] symNames = [
        "truetype/noto/NotoSansSymbols2-Regular.ttf",
        "truetype/noto/NotoSansSymbols-Regular.ttf",
        "noto/NotoSansSymbols2-Regular.ttf",
    ];
}

// Resolved by render_init, since on Windows and macOS they depend on the user.
private __gshared string[] fontDirs;

// Shipped next to the executable under the same file names, for a system that has
// none of them. Never preferred over an installed font.
private __gshared string bundledDir;

version (OSX) {}
else version (Posix) version = Fontconfig;

/// Create the window's renderer.
///
/// Nothing forces a choice by default: SDL walks its driver list itself and ends
/// on the software one, so a machine whose accelerated drivers all fail to
/// create still gets a renderer. `SDL_RENDER_DRIVER` replaces that list, so a
/// value SDL cannot honor is warned about and dropped.
///
/// Returns: null on failure, with the reason left in SDL_GetError.
SDL_Renderer* render_create(SDL_Window* window)
{
    SDL_Renderer* renderer = SDL_CreateRenderer(window, null);

    const(char)* wanted = SDL_GetHint(SDL_HINT_RENDER_DRIVER);
    if (renderer is null && wanted && *wanted)
    {
        logWarn(`renderer "%s" unavailable: %s (have: %-(%s, %)); letting SDL choose`,
            fromStringz(wanted), SDL_GetError().fromStringz, driverNames());
        // Empty, not reset: a reset falls back to the environment variable.
        SDL_SetHintWithPriority(SDL_HINT_RENDER_DRIVER, "", SDL_HINT_OVERRIDE);
        renderer = SDL_CreateRenderer(window, null);
    }

    if (renderer)
        logInfo("renderer: %s", SDL_GetRendererName(renderer).fromStringz);
    return renderer;
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
    fontDirs = font_dirs();
    bundledDir = buildPath(exeDir(), "assets", "fonts");

    // the machine matched, which SDL never saw.
    fontUI = openFace("UI", "sans-serif", 0, uiNames);
    if (fontUI is null)
    {
        logCritical("no UI font; looked for %-(%s, %) in %-(%s, %), %s", uiNames, fontDirs, bundledDir);
        return "No font found.\n\nInstall a TrueType font: fonts-noto or " ~
            "fonts-dejavu will do.";
    }

    // Missing the mono face is not fatal, the hex panel merely goes unaligned.
    fontMono = openFace("mono", "monospace", 0, monoNames);
    if (fontMono is null)
    {
        logWarn("no monospace font, falling back to the UI face (the hex grid " ~
            "will not align); install one of: %s", monoNames);
        fontMono = fontUI;
    }

    // A match is checked for the one glyph that was the point of asking: given a
    // pattern nothing installed can satisfy, fontconfig still answers with its
    // best effort rather than nothing.
    // Attempt to match a glyph. fontconfig still answers
    addFallback("CJK", ":lang=ja", '一', cjkNames);
    addFallback("symbol",
        format(":charset=%04X", cast(uint) icons[MU_ICON_CLOSE].code),
        icons[MU_ICON_CLOSE].code, symNames);

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
    foreach (ref TextEntry e; textCache)
        TTF_DestroyText(e.text);
    textCache = null;

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
    // TTF_CreateText reads a zero length as "the string is NUL-terminated",
    // which would run off the end of a caller's slice; an empty string measures
    // zero either way, so answer that here rather than handing it over.
    if (len == 0) return 0;
    TTF_Text* text = cached_text(cast(TTF_Font*) font, str[0 .. len]);
    if (text is null)
        return 0;
    int w;
    TTF_GetTextSize(text, &w, null);
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
    sweep_text();
}

private:

// Only for the message above, so nothing caches it.
string[] driverNames()
{
    int count = SDL_GetNumRenderDrivers();
    string[] names = new string[count];
    foreach (int i; 0 .. count)
        names[i] = SDL_GetRenderDriver(i).fromStringz.idup;
    return names;
}

// A face for one role: fontconfig's answer for the pattern, then the known files,
// installed before bundled. `probe` is a codepoint the face has to carry, or 0
// to take whatever comes back.
TTF_Font* openFace(string role, string pattern, dchar probe, const(string)[] names)
{
    string matched = fc_match(pattern);
    if (matched.length)
        if (TTF_Font* f = openPath(role, matched, probe))
            return f;

    foreach (string name; names)
        foreach (string dir; fontDirs)
            if (TTF_Font* f = openPath(role, buildPath(dir, name), probe))
                return f;

    foreach (string name; names)
        if (TTF_Font* f = openPath(role, buildPath(bundledDir, baseName(name)), probe))
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
void addFallback(string role, string pattern, dchar probe, const(string)[] names)
{
    if (fallbackCount >= fallbacks.length)
        return;
    TTF_Font* f = openFace(role, pattern, probe, names);
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
version (Fontconfig)
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
    // Windows and macOS have no fontconfig to ask, so the file names are it.
    string fc_match(string pattern) => null;
}

version (Windows)
{
    import core.sys.windows.basetyps : GUID;
    import core.sys.windows.objbase : CoTaskMemFree;
    import core.sys.windows.windef : DWORD, HANDLE, HRESULT;
    import std.conv : to;

    pragma(lib, "shell32");
    pragma(lib, "ole32");

    // Not in druntime.
    extern (Windows) nothrow @nogc
    HRESULT SHGetKnownFolderPath(const(GUID)* rfid, DWORD flags, HANDLE token, wchar** path);

    private immutable GUID FOLDERID_Fonts =
        { 0xFD228CB7, 0xAE11, 0x4AE3, [ 0x86, 0x4C, 0x16, 0xF3, 0x91, 0x0A, 0xB8, 0xFE ] };
    private immutable GUID FOLDERID_LocalAppData =
        { 0xF1B32785, 0x6FBA, 0x4FCF, [ 0x9D, 0x55, 0x7B, 0x8E, 0x7F, 0x15, 0x70, 0x91 ] };

    private string knownFolder(ref immutable(GUID) id)
    {
        wchar* path;
        HRESULT hr = SHGetKnownFolderPath(&id, 0, null, &path);
        scope(exit) CoTaskMemFree(path); // owed even on failure
        return hr == 0 ? path.fromStringz.to!string : null;
    }

    // Fonts installed without admin rights (Windows 10 1809+) land in the user's
    // own folder, not the system one.
    string[] font_dirs()
    {
        string[] dirs;
        if (string sys = knownFolder(FOLDERID_Fonts))
            dirs ~= sys;
        if (string local = knownFolder(FOLDERID_LocalAppData))
            dirs ~= buildPath(local, `Microsoft\Windows\Fonts`);
        return dirs;
    }
}
else version (OSX)
{
    import std.process : environment;

    string[] font_dirs()
    {
        string[] dirs = [ "/System/Library/Fonts", "/Library/Fonts" ];
        if (string home = environment.get("HOME"))
            dirs ~= buildPath(home, "Library/Fonts");
        return dirs;
    }
}
else
{
    string[] font_dirs() => [ "/usr/share/fonts", "/usr/local/share/fonts" ];
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
    TTF_Text* text = cached_text(cast(TTF_Font*) font, str[0 .. strlen(str)]);
    if (text is null)
        return;

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

    TTF_Text* text = cached_text(fontUI, glyph[0 .. strlen(glyph)]);
    if (text is null)
        return;

    TTF_SetTextColor(text, color.r, color.g, color.b, color.a);

    int w, h;
    TTF_GetTextSize(text, &w, &h);
    int x = rect.x + (rect.w - w) / 2;
    int y = rect.y + (rect.h - h) / 2;
    TTF_DrawRendererText(text, x, y);
}

TTF_Text* cached_text(TTF_Font* font, const(char)[] str)
{
    if (font is null) font = fontUI;
    if (TextEntry* e = TextKey(font, str) in textCache)
    {
        e.frame = textFrame;
        return e.text;
    }
    TTF_Text* text = TTF_CreateText(engine, font, str.ptr, str.length);
    if (text is null)
        return null;
    textCache[TextKey(font, str.idup)] = TextEntry(text, textFrame);
    return text;
}

void sweep_text()
{
    if (++textFrame % TEXT_TTL)
        return;
    textStale.length = 0;
    textStale.assumeSafeAppend();
    foreach (TextKey key, ref TextEntry e; textCache)
        if (textFrame - e.frame >= TEXT_TTL)
            textStale ~= key;
    foreach (ref TextKey key; textStale)
    {
        TTF_DestroyText(textCache[key].text);
        textCache.remove(key);
    }
}
