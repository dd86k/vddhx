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
    /// Returns: false if a library is missing or unusable (reason is logged).
    bool loader_init() { return true; }

    /// Close the SDL3 libraries.
    void loader_quit() {}
}
else
{
    import std.string : fromStringz;
    import bindbc.loader : ErrorInfo, LoadMsg, errors, resetErrors;
    import bindbc.sdl : loadSDL, unloadSDL, loadSDLTTF, unloadSDLTTF;

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

    bool loader_init()
    {
        return open!loadSDL("SDL3", sdlNames) && open!loadSDLTTF("SDL3_ttf", ttfNames);
    }

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
            logCritical("%s: shared library not found", what);
            return false;
        case LoadMsg.badLibrary:
            logCritical("%s: shared library is missing symbols (too old?)", what);
            foreach (ref const(ErrorInfo) err; errors)
                logCritical("%s: %s: %s", what, err.error.fromStringz, err.message.fromStringz);
            return false;
        }
    }
}
