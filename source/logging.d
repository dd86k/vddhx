/// Log destinations: stderr when there is one, a per-session file, and SDL's own
/// messages folded into both.
/// Authors: dd86k <dd@dax.moe>
module logging;

import std.format : format;
import std.string : fromStringz;
import ddlogger;
import bindbc.sdl;
import about : VERSION, COMPILER;

private enum string APPNAME = "vddhx";
private enum string FILENAME = "vddhx.log";

private __gshared SDL_LogOutputFunction sdlDefault;
private __gshared void* sdlDefaultData;

/// Set the level, open the log file, and log what a bug report needs first.
/// Console appenders must already be added, so a file that fails to open can
/// still be reported.
void logging_init(LogLevel level, bool file)
{
    logSetLevel(level);
    string path = file ? openFile(level) : null;
    logInfo("vddhx %s, built with %s, on %s", VERSION, COMPILER, platform());
    if (path)
        logInfo("logging to %s", path);
}

/// Route SDL's messages through ddlogger. After loader_init, before SDL_Init.
void logging_sdl(LogLevel level)
{
    SDL_GetLogOutputFunction(&sdlDefault, &sdlDefaultData);
    SDL_SetLogOutputFunction(&onSdlLog, null);
    // SDL filters by its own priorities before the hook ever sees a message.
    if (level >= LogLevel.trace)
        SDL_SetLogPriorities(SDL_LOG_PRIORITY_VERBOSE);
    logInfo("SDL %s, SDL_ttf %s", versionText(SDL_GetVersion()), versionText(TTF_Version()));
}

// One file per session, the previous kept as .old so the run that crashed
// survives the relaunch that follows it.
private string openFile(LogLevel level)
{
    import std.file : exists, mkdirRecurse, rename;
    import std.path : buildPath, dirName;

    string base = stateFolder();
    if (base is null)
        return null;
    string path = buildPath(base, APPNAME, FILENAME);

    try
    {
        mkdirRecurse(dirName(path));
        if (exists(path))
            rename(path, path ~ ".old");
    }
    catch (Exception e) // Windows refuses while another instance holds it: share it
        logDebugging("%s: %s", path, e.msg);

    try
    {
        FileAppender appender = new FileAppender(path);
        appender.setLogLevel(level);
        logAddAppender(appender);
    }
    catch (Exception e)
    {
        logWarn("%s: %s", path, e.msg);
        return null;
    }
    return path;
}

// XDG keeps logs under state rather than config; Windows has no such split.
private string stateFolder()
{
    import os.path : getHomeFolder, getUserConfigFolder;

    version (Windows)
        return getUserConfigFolder();
    else
    {
        import std.path : buildPath, isAbsolute;
        import std.process : environment;

        string xdg = environment.get("XDG_STATE_HOME");
        if (xdg.length && isAbsolute(xdg)) // the spec says to ignore relative ones
            return xdg;
        string home = getHomeFolder();
        return home ? buildPath(home, ".local", "state") : null;
    }
}

private string platform()
{
    import std.conv : to;
    import std.system : os;

    version (Posix)
    {
        import core.sys.posix.sys.utsname : utsname, uname;

        utsname u;
        if (uname(&u) == 0)
            return format("%s %s %s", u.sysname.ptr.fromStringz,
                u.release.ptr.fromStringz, u.machine.ptr.fromStringz);
    }
    return to!string(os);
}

private string versionText(int v)
{
    return format("%d.%d.%d", v / 1_000_000, v / 1_000 % 1_000, v % 1_000);
}

extern (C) private void onSdlLog(void* user, int category, SDL_LogPriority priority,
    const(char)* message) nothrow
{
    import core.thread : Thread;

    // ddlogger formats into a stack buffer, but a failing appender still
    // allocates its exception: threads druntime never met (SDL's own) must not.
    if (Thread.getThis() is null)
    {
        sdlDefault(sdlDefaultData, category, priority, message);
        return;
    }

    const(char)[] text = message.fromStringz;
    switch (priority)
    {
    case SDL_LOG_PRIORITY_CRITICAL: logCritical("SDL: %s", text); break;
    case SDL_LOG_PRIORITY_ERROR:    logError("SDL: %s", text); break;
    case SDL_LOG_PRIORITY_WARN:     logWarn("SDL: %s", text); break;
    case SDL_LOG_PRIORITY_INFO:     logInfo("SDL: %s", text); break;
    case SDL_LOG_PRIORITY_DEBUG:    logDebugging("SDL: %s", text); break;
    default:                        logTrace("SDL: %s", text);
    }
}
