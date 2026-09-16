/// Window icon: an installed icon if there is one, else the copy shipped beside
/// the executable.
///
/// BMP rather than PNG because SDL3 core decodes BMP and nothing else, and a
/// window icon is not worth a decoder or an SDL_image dependency. The icon theme
/// spec wants PNG, so the hicolor files installed for the desktop are a separate
/// thing from these; what a launcher shows comes off the .desktop entry, not off
/// SDL_SetWindowIcon.
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

/// The one size handed over. SDL takes alternate images too, but only Wayland
/// reads them. X11, Windows and Cocoa each publish a single surface, so the
/// desktop is doing the scaling either way. Handing it the largest gives it the
/// most to scale down from.
///
/// The smaller sizes mkicon.d draws are for the desktop's own icon lookup and
/// the Windows .ico, neither of which comes through here.
private enum int ICON_SIZE = 256;

/// Find the icon and hand it to the window.
///
/// Finding none is not fatal: the window keeps whatever the desktop gives an
/// application with no icon of its own.
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

    // SDL copies the pixels into the backend's own storage (an X11 property, a
    // Wayland buffer), so the surface has done its job by here.
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

/// Where a `size`-pixel icon may live, installed locations before the build
/// tree, so a stale copy in the source directory cannot shadow an installed one.
string[] candidates(int size)
{
    string[] paths;
    string leaf = buildPath("vddhx", "icons", text("vddhx-", size, ".bmp"));

    version (Posix)
    {
        // Application data per the base directory spec: XDG_DATA_HOME, then
        // XDG_DATA_DIRS, each with the documented default when unset. Not the
        // hicolor theme, which is PNG only.
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

string exeDir()
{
    try return thisExePath().dirName;
    catch (Exception e)
    {
        logWarn("thisExePath: %s", e.msg);
        return ".";
    }
}
