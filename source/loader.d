/// SDL3 shared library loading. No-op in the "static" configuration.
/// Authors: dd86k <dd@dax.moe>
module loader;

import bindbc.sdl : staticBinding;
import ddlogger;

static if (staticBinding)
{
    /// Open the SDL3 libraries, before any SDL_*/TTF_* call.
    /// Returns: false if a library is missing or unusable (logged, message box).
    bool loader_init() { return true; }

    /// Close the SDL3 libraries.
    void loader_quit() {}
}
else
{
    import std.format : format;
    import std.string : fromStringz, toStringz;
    import bindbc.loader : ErrorInfo, LoadMsg, errors, resetErrors;
    import bindbc.sdl : loadSDL, unloadSDL, loadSDLTTF, unloadSDLTTF,
        SDL_ShowSimpleMessageBox, SDL_MESSAGEBOX_ERROR;

    // bindbc only tries the unversioned SONAME (libSDL3.so, from -dev packages);
    // also try the ABI-versioned names from runtime packages.
    version (Posix)
    {
        private immutable string[] sdlNames = [ "libSDL3.so.0" ];
        private immutable string[] ttfNames = [ "libSDL3_ttf.so.0" ];
    }
    else
    {
        private immutable string[] sdlNames = [];
        private immutable string[] ttfNames = [];
    }

    // SDL_* bindings are null until set, SDL's message box included.
    private __gshared bool sdlLoaded;

    /// Ditto
    bool loader_init()
    {
        if (open!loadSDL("SDL3", sdlNames) == false)
            return false;
        sdlLoaded = true;
        return open!loadSDLTTF("SDL3_ttf", ttfNames);
    }

    /// Ditto
    void loader_quit()
    {
        unloadSDLTTF();
        unloadSDL();
    }

    // `load`: loadSDL or loadSDLTTF. Default names first, then fallbacks by name.
    private bool open(alias load)(string what, immutable string[] fallbacks)
    {
        resetErrors(); // clear earlier libraries' errors

        LoadMsg msg = load();
        foreach (string name; fallbacks)
        {
            if (msg != LoadMsg.noLibrary)
                break;
            msg = load(name.ptr); // literals are NUL-terminated
        }

        final switch (msg)
        {
        case LoadMsg.success:
            return true;
        case LoadMsg.noLibrary:
            version (Windows)
                enum string hint = ".dll was not found next to vddhx.exe or in PATH.";
            else
                enum string hint = ": shared library not found.";
            fail(what ~ hint);
            return false;
        case LoadMsg.badLibrary:
            // Missing symbols mean little to users, but log them.
            foreach (ref const(ErrorInfo) err; errors)
                logCritical("%s: %s: %s", what, err.error.fromStringz, err.message.fromStringz);
            fail(format("%s is missing symbols, it is likely too old (SDL 3.2.0 or later is needed).", what));
            return false;
        }
    }

    // winuser's pragma(lib) only applies if winuser.obj gets linked from druntime.
    version (Windows) pragma(lib, "user32");

    // SDL message box if loaded, else Win32 MessageBox.
    private void fail(string message)
    {
        logCritical("%s", message);

        if (sdlLoaded)
        {
            SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "vddhx", message.toStringz, null);
            return;
        }

        version (Windows)
        {
            import core.sys.windows.winuser : MessageBoxW, MB_ICONERROR, MB_OK;
            import std.utf : toUTF16z;
            MessageBoxW(null, message.toUTF16z, "vddhx"w.ptr, MB_ICONERROR | MB_OK);
        }
    }
}
