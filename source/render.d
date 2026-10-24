/// ddui draw commands to SDL3's renderer.
///
/// Text and UI icons go through SDL3_ttf's renderer text engine; its atlas
/// spans all open faces, so one string can mix base, CJK and symbol glyphs.
/// Authors: dd86k <dd@dax.moe>
module render;

import core.stdc.string : strlen;
import std.file : exists;
import std.format : format;
import std.math : ceil, lround;
import std.path : baseName, buildPath;
import std.string : fromStringz, toStringz;
import bindbc.sdl; // re-exports TTF_* in the static config
import ddlogger;
import ddui;
import elite : MU_COMMAND_SHIP, elite_draw;
import icon : exeDir;

// Sets the scale only; render_text_height reports actual line height.
private enum float FONT_SIZE = 14.0f;

// Output pixels per point. ddui works in points; geometry is mapped here and
// faces are sized to match, so glyphs rasterise at output resolution.
private __gshared float density = 1;

private __gshared TTF_TextEngine* engine;

// Both share the fallback chain.
private __gshared TTF_Font* fontUI;
private __gshared TTF_Font* fontMono;

// Kept so render_quit can close them after the primaries.
private __gshared TTF_Font*[8] fallbacks;
private __gshared size_t fallbackCount;

private struct Icon
{
    dchar code;
    immutable(char)* glyph;
    immutable(char)* plain;
}

// Drawn with the UI face and fallbacks. Index 0 unused. `plain` is used when
// no face has the codepoint.
private immutable Icon[MU_ICON_MAX] icons = [
    MU_ICON_CLOSE:     Icon('✕', "✕", "x"),
    MU_ICON_CHECK:     Icon('✓', "✓", "*"),
    MU_ICON_COLLAPSED: Icon('▶', "▶", ">"),
    MU_ICON_EXPANDED:  Icon('▼', "▼", "v"),
    MU_ICON_DROPDOWN:  Icon('▾', "▾", "v"),
];

// Resolved after the faces are open.
private __gshared immutable(char)*[MU_ICON_MAX] iconText;

// Shaped text cache, keyed by face and content. The hex view draws two strings
// per visible byte, and reshaping dominated frame time. Entries unused for
// TEXT_TTL frames are evicted.
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
private __gshared TextKey[] textStale; // reused by sweep_text
private __gshared uint textFrame;

// Font files tried in order in each font_dirs directory. May include a subdir.
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
    // Without fontconfig: common distro paths.
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

// Set by render_init; per-user on Windows and macOS.
private __gshared string[] fontDirs;

// Bundled fonts beside the executable, same names. Last resort.
private __gshared string bundledDir;

version (OSX) {}
else version (Posix) version = Fontconfig;

/// Create the window's renderer. SDL picks the driver, falling back to
/// software. An unusable `SDL_RENDER_DRIVER` is warned about and ignored.
/// Returns: null on failure (see SDL_GetError).
SDL_Renderer* render_create(SDL_Window* window)
{
    SDL_Renderer* renderer = SDL_CreateRenderer(window, null);

    const(char)* wanted = SDL_GetHint(SDL_HINT_RENDER_DRIVER);
    if (renderer is null && wanted && *wanted)
    {
        logWarn(`renderer "%s" unavailable: %s (have: %-(%s, %)); letting SDL choose`,
            fromStringz(wanted), SDL_GetError().fromStringz, driverNames());
        // Empty, not reset: reset falls back to the env var.
        SDL_SetHintWithPriority(SDL_HINT_RENDER_DRIVER, "", SDL_HINT_OVERRIDE);
        renderer = SDL_CreateRenderer(window, null);
    }

    if (renderer)
        logInfo("renderer: %s", SDL_GetRendererName(renderer).fromStringz);
    return renderer;
}

/// Init SDL3_ttf, the text engine and font faces. Call once after
/// render_create.
/// Returns: null on success, else a user-facing reason.
string render_init(SDL_Renderer* renderer)
{
    if (TTF_Init() == false)
        return format("TTF_Init: %s", SDL_GetError().fromStringz);

    engine = TTF_CreateRendererTextEngine(renderer);
    if (engine is null)
        return format("TTF_CreateRendererTextEngine: %s", SDL_GetError().fromStringz);

    // Otherwise translucent fills (minimap viewport) are opaque and the
    // transparent MU_COLOR_PANELBG paints black.
    SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_BLEND);

    fontDirs = font_dirs();
    bundledDir = buildPath(exeDir(), "assets", "fonts");

    // Missing faces are reported without SDL_GetError: SDL wasn't involved.
    fontUI = openFace("UI", "sans-serif", 0, uiNames);
    if (fontUI is null)
    {
        logCritical("no UI font; looked for %-(%s, %) in %-(%s, %), %s", uiNames, fontDirs, bundledDir);
        return "No font found.\n\nInstall a TrueType font: fonts-noto or " ~
            "fonts-dejavu will do.";
    }

    // No mono face: not fatal, hex panel is just unaligned.
    fontMono = openFace("mono", "monospace", 0, monoNames);
    if (fontMono is null)
    {
        logWarn("no monospace font, falling back to the UI face (the hex grid " ~
            "will not align); install one of: %s", monoNames);
        fontMono = fontUI;
    }

    // Probe glyphs are verified: fontconfig returns a best effort even when
    // nothing matches.
    addFallback("CJK", ":lang=ja", '一', cjkNames);
    addFallback("symbol",
        format(":charset=%04X", cast(uint) icons[MU_ICON_CLOSE].code),
        icons[MU_ICON_CLOSE].code, symNames);

    // After the chain is built: TTF_FontHasGlyph checks fallbacks too.
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

/// Proportional UI face; set as ctx.style.font after mu_init.
TTF_Font* render_font_ui() => fontUI;

/// Monospace face for the hex panel. Swap into ctx.style.font around it.
TTF_Font* render_font_mono() => fontMono;

/// Set the window pixel density; 0 (SDL_GetWindowPixelDensity failure) is
/// ignored.
void render_set_density(float d)
{
    if (d <= 0 || d == density)
        return;
    logInfo("pixel density: %g", d);
    density = d;

    TTF_SetFontSize(fontUI, FONT_SIZE * d);
    if (fontMono !is fontUI)
        TTF_SetFontSize(fontMono, FONT_SIZE * d);
    foreach (TTF_Font* f; fallbacks[0 .. fallbackCount])
        TTF_SetFontSize(f, FONT_SIZE * d);

    foreach (ref TextEntry e; textCache)
        TTF_DestroyText(e.text);
    textCache = null;
}

/// mu_Context text measuring callbacks. `font` is a TTF_Font*.
extern (C) int render_text_width(mu_Font font, const(char)* str, int len)
{
    if (len < 0) len = cast(int) strlen(str);
    // TTF_CreateText treats length 0 as NUL-terminated, running off the slice.
    if (len == 0) return 0;
    TTF_Text* text = cached_text(cast(TTF_Font*) font, str[0 .. len]);
    if (text is null)
        return 0;
    int w;
    TTF_GetTextSize(text, &w, null);
    return toPoints(w);
}

/// ditto
extern (C) int render_text_height(mu_Font font)
{
    TTF_Font* f = cast(TTF_Font*) font;
    if (f is null) f = fontUI;
    return toPoints(TTF_GetFontHeight(f));
}

/// Replay ddui draw commands onto the renderer.
///
/// Must use mu_get_next_command, not mu_command_range: only it follows the
/// JUMP commands that order root containers by z-index (popups on top).
void render_commands(SDL_Renderer* renderer, mu_Context* ctx)
{
    mu_Command* cmd;
    while (mu_get_next_command(ctx, &cmd))
    {
        switch (cmd.type)
        {
        case MU_COMMAND_RECT:
            draw_rect(renderer, toPixels(cmd.rect.rect), cmd.rect.color);
            break;
        case MU_COMMAND_TEXT:
            draw_text(cmd.text.font, mu_command_text(ctx, cmd), cmd.text.pos, cmd.text.color);
            break;
        case MU_COMMAND_ICON:
            draw_icon(cmd.icon.id, toPixels(cmd.icon.rect), cmd.icon.color);
            break;
        case MU_COMMAND_SHIP: // elite.d
            elite_draw(renderer, toPixels(cmd.rect.rect));
            break;
        case MU_COMMAND_CLIP:
            mu_Rect r = toPixels(cmd.clip.rect);
            SDL_Rect clip = SDL_Rect(r.x, r.y, r.w, r.h);
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

// Map edges, not sizes, so adjacent rects meet at fractional densities.
mu_Rect toPixels(mu_Rect r)
{
    int x = toPixels(r.x), y = toPixels(r.y);
    return mu_Rect(x, y, toPixels(r.x + r.w) - x, toPixels(r.y + r.h) - y);
}
int toPixels(int v) => cast(int) lround(v * density);

// Round up so text-sized boxes don't clip.
int toPoints(int v) => cast(int) ceil(v / density);

string[] driverNames()
{
    int count = SDL_GetNumRenderDrivers();
    string[] names = new string[count];
    foreach (int i; 0 .. count)
        names[i] = SDL_GetRenderDriver(i).fromStringz.idup;
    return names;
}

// Open a face: fontconfig match first, then known files, installed before
// bundled. `probe`: required codepoint, or 0.
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

// Open a fallback face and add it to both primaries.
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

// fontconfig loaded at runtime: optional, SDL3_ttf doesn't need it and
// containers may lack it.
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

    // Returns: matched file, or null (no library or no fonts).
    string fc_match(string pattern)
    {
        if (fcOpen() == false)
            return null;

        void* pat = FcNameParse(pattern.toStringz);
        if (pat is null)
            return null;
        scope(exit) FcPatternDestroy(pat);

        // Standard pre-match setup: apply config rules, then defaults.
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
            fn = cast(T) dlsym(lib, name.ptr); // literals are NUL-terminated
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
    // No fontconfig on Windows and macOS.
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
        scope(exit) CoTaskMemFree(path); // required even on failure
        return hr == 0 ? path.fromStringz.to!string : null;
    }

    // Per-user font installs (Windows 10 1809+) go to the user's folder.
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
    if (color.a == 0) // transparent: nothing to draw
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
    TTF_DrawRendererText(text, toPixels(pos.x), toPixels(pos.y));
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
