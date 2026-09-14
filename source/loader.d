/// SDL3 shared library loading.
///
/// Only the default "application" configuration needs this: the "static" one
/// links the archives in and bindbc emits plain externs, folding it all away.
/// Authors: dd86k <dd@dax.moe>
module loader;

import bindbc.sdl : staticBinding;
import ddlogger;

static if (staticBinding)
{
    /// Open the SDL3 libraries, before the first SDL_* or TTF_* call.
    /// Returns: false if a library is missing or unusable, the reason logged and
    /// put up in a message box.
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

    // bindbc only probes the unversioned SONAME (libSDL3.so), which distributions
    // ship in their -dev package; try the runtime package's ABI-versioned names
    // before giving up. Windows has no such split.
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

    // Set the moment SDL3 itself is in, which is what makes SDL_* callable:
    // until then every binding is a null pointer, SDL's message box included.
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

    // `load` is loadSDL or loadSDLTTF: the no-argument overload walks the names
    // bindbc knows, then the fallbacks go through the one taking a library name.
    private bool open(alias load)(string what, immutable string[] fallbacks)
    {
        resetErrors(); // keep a failure from reporting an earlier library's misses

        LoadMsg msg = load();
        foreach (string name; fallbacks)
        {
            if (msg != LoadMsg.noLibrary)
                break;
            msg = load(name.ptr); // string literals are NUL-terminated
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
            // Missing symbols don't mean much to people, at least logs will have them
            foreach (ref const(ErrorInfo) err; errors)
                logCritical("%s: %s: %s", what, err.error.fromStringz, err.message.fromStringz);
            fail(format("%s is missing symbols, it is likely too old (SDL 3.2.0 or later is needed).", what));
            return false;
        }
    }

    // core.sys.windows.winuser has its own pragma(lib, "user32"), but that only
    // reaches the linker when winuser.obj is itself pulled out of druntime.lib.
    version (Windows) pragma(lib, "user32");

    // Called by open() and invokes SDL_ShowSimpleMessageBox or Win32 MsgBox if able.
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
