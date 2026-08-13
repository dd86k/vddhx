/// SDL3 shared library loading.
///
/// The default "application" configuration binds SDL3 and SDL3_ttf through
/// bindbc's runtime function pointers, so both libraries have to be opened
/// before the first SDL_* or TTF_* call. The "static" configuration links the
/// archives in and bindbc emits plain externs instead, which turns everything
/// here into a no-op the compiler folds away.
/// Authors: dd
module loader;

import bindbc.sdl : staticBinding;
import ddlogger;

static if (staticBinding)
{
    /// Open the SDL3 libraries. No-op under the static configuration.
    /// Returns: false if a library is missing or unusable (reason is logged).
    bool loader_init() { return true; }

    /// Close the SDL3 libraries. No-op under the static configuration.
    void loader_quit() {}
}
else
{
    import std.string : fromStringz;
    import bindbc.loader : ErrorInfo, LoadMsg, errors, resetErrors;
    import bindbc.sdl : loadSDL, unloadSDL, loadSDLTTF, unloadSDLTTF;

    // bindbc only probes the unversioned SONAME (libSDL3.so), which distributions
    // ship in their -dev package. Try the ABI-versioned names installed by the
    // runtime package before giving up. Windows has no such split, so the name
    // bindbc already knows (SDL3.dll) is the only one.
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

    // Both libraries load the same way, `load` being loadSDL or loadSDLTTF:
    // the no-argument overload walks the names bindbc knows, then the extra
    // names go through the overload taking one library name.
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
            // The library loaded but symbols were missing, typically an SDL
            // older than the version the bindings were configured for.
            logCritical("%s: shared library is missing symbols (too old?)", what);
            foreach (ref const(ErrorInfo) err; errors)
                logCritical("%s: %s: %s", what, err.error.fromStringz, err.message.fromStringz);
            return false;
        }
    }
}
