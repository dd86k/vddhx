/// Window icon: installed icon if present, else the one shipped beside the
/// executable.
///
/// BMP because SDL3 core only decodes BMP. The hicolor PNGs are for the
/// .desktop entry, which is what launchers show; not used here.
/// Authors: dd86k <dd@dax.moe>
module icon;

import std.algorithm.iteration : splitter;
import std.conv : text;
import std.file : exists, thisExePath;
import std.path : buildPath, dirName;
import std.process : environment;
import std.string : fromStringz, toStringz;
import bindbc.sdl;
import ddlogger;

/// Only Wayland reads alternate sizes; others take one surface and scale it,
/// so pass the largest. Smaller sizes from mkicon.d are for the theme and .ico.
private enum int ICON_SIZE = 256;

/// Find the icon and set it on the window. Not fatal if none is found.
void icon_apply(SDL_Window* window)
{
    SDL_Surface* icon = load();
    if (icon is null)
    {
        logWarn("no window icon found");
        return;
    }

    if (SDL_SetWindowIcon(window, icon) == false)
        logWarn("SDL_SetWindowIcon: %s", SDL_GetError().fromStringz);

    // SDL copies the pixels into the backend.
    SDL_DestroySurface(icon);
}

private:

SDL_Surface* load()
{
    foreach (string path; candidates(ICON_SIZE))
    {
        if (exists(path) == false)
        {
            logDebugging("icon %s: absent", path);
            continue;
        }
        SDL_Surface* s = SDL_LoadBMP(path.toStringz);
        if (s is null)
        {
            logDebugging("icon %s: %s", path, SDL_GetError().fromStringz);
            continue;
        }
        logDebugging("window icon %dx%d from %s", s.w, s.h, path);
        return s;
    }
    return null;
}

/// Candidate paths for a `size`-pixel icon. Installed locations first so a
/// stale copy in the source tree can't shadow them.
string[] candidates(int size)
{
    string[] paths;
    string leaf = buildPath("vddhx", "icons", text("vddhx-", size, ".bmp"));

    version (Posix)
    {
        // XDG base dir spec: XDG_DATA_HOME, then XDG_DATA_DIRS, with defaults.
        string home = environment.get("XDG_DATA_HOME");
        if (home.length)
        {
            paths ~= buildPath(home, leaf);
        }
        else
        {
            string h = environment.get("HOME");
            if (h.length)
                paths ~= buildPath(h, ".local", "share", leaf);
        }

        foreach (string dir; environment.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share").splitter(':'))
        {
            if (dir)
                paths ~= buildPath(dir, leaf);
        }
    }

    paths ~= buildPath(exeDir(), "assets", "icon", text("vddhx-", size, ".bmp"));
    return paths;
}

/// Executable's directory (where assets/ ships); "." if unknown.
public string exeDir()
{
    try return thisExePath().dirName;
    catch (Exception e)
    {
        logWarn("thisExePath: %s", e.msg);
        return ".";
    }
}
