// Builds static SDL3 and SDL3_ttf for `dub build -c static`.
//
// Windows builds with MSVC (cl) + Ninja: DMD/LDC emit MSVC-ABI objects on
// win64, so an archive from the mingw gcc that is often on PATH will not link.
// SDL_ttf vendors freetype/harfbuzz by default, so the binary (and the
// AppImage built from it) carries no font-stack dependency beyond fontconfig.
//
// Usage: dmd -run tools/build-sdl3.d [--help] [--dry-run] [options...]
// (or ldmd2/gdmd -run; gdc has no -run, so compile it first)
module build_sdl3;

import std.algorithm : canFind, filter, map, splitter, startsWith;
import std.array : array, join, split;
import std.file : copy, dirEntries, DirEntry, exists, isFile, readText,
    rmdirRecurse, SpanMode;
import std.getopt : defaultGetoptPrinter, getopt, GetoptResult;
import std.path : absolutePath, baseName, buildPath, dirName, expandTilde,
    pathSeparator;
import std.process : environment, escapeShellCommand, execute, executeShell,
    spawnProcess, wait;
import std.stdio : readln, stderr, stdout, write, writeln;
import std.string : format, indexOf, lineSplitter, strip;
import std.typecons : Tuple;

private:

enum SDL_TAG     = "release-3.4.16";
enum SDL_TTF_TAG = "release-3.2.2"; // matches the SDL_TTF_3_2_2 version in dub.sdl

version (Windows) enum bool WINDOWS = true;
else              enum bool WINDOWS = false;

enum Family { unknown, debian, fedora, el }

bool dryRun;
bool enableCrb;

// The fonts are the runtime side, found through fontconfig (see source/render.d).
immutable string[] DEBIAN_PACKAGES = [
    "build-essential", "cmake", "ninja-build", "git",
    "libx11-dev", "libxext-dev", "libxrandr-dev", "libxcursor-dev", "libxi-dev",
    "libxfixes-dev", "libxss-dev", "libxtst-dev", "libwayland-dev", "wayland-protocols",
    "libdecor-0-dev", "libxkbcommon-dev", "libegl1-mesa-dev", "libgles2-mesa-dev",
    "libpulse-dev", "libasound2-dev", "libdbus-1-dev",
    // fonts used in packaging
    "fonts-noto-core", "fonts-noto-mono", "fonts-noto-cjk",
];
immutable string[] FEDORA_PACKAGES = [
    "gcc", "gcc-c++", "cmake", "ninja-build", "git",
    "libX11-devel", "libXext-devel", "libXrandr-devel", "libXcursor-devel", "libXi-devel",
    "libXfixes-devel", "libXScrnSaver-devel", "libXtst-devel", "wayland-devel", "wayland-protocols-devel",
    "libdecor-devel", "libxkbcommon-devel", "mesa-libEGL-devel", "mesa-libGLES-devel",
    "pulseaudio-libs-devel", "alsa-lib-devel", "dbus-devel",
    // fonts used in packaging
    "google-noto-sans-fonts", "google-noto-sans-mono-fonts", "google-noto-sans-cjk-fonts",
];
// Only needed with --vendored=false.
immutable string[] DEBIAN_TTF_PACKAGES = ["libfreetype-dev", "libharfbuzz-dev"];
immutable string[] FEDORA_TTF_PACKAGES = ["freetype-devel", "harfbuzz-devel"];

// RHEL and rebuilds name a few packages differently from Fedora.
string elPackage(string fedora)
{
    switch (fedora)
    {
    case "mesa-libGLES-devel":         return "libglvnd-devel";
    case "google-noto-sans-cjk-fonts": return "google-noto-sans-cjk-ttc-fonts";
    default:                           return fedora;
    }
}

int main(string[] args)
{
    string prefix;
    bool noClean, dynamicCrt, skipPackages;
    bool vendored = true;
    GetoptResult opts = getopt(args,
        "dry-run|n", "Print what would run; only read-only checks execute", &dryRun,
        "skip-packages", "Report missing distro packages instead of installing them", &skipPackages,
        "vendored", "Build freetype/harfbuzz into SDL_ttf (default: true; Windows always)", &vendored,
        "enable-crb", "EL: install from the CRB repo without asking (this run only)", &enableCrb,
        "prefix", "Install prefix (default: ~/.local, or <repo>/install on Windows)", &prefix,
        "no-clean", "Keep existing build directories", &noClean,
        "dynamic-crt", "Windows: link SDL against /MD (D side then needs -mscrtlib=msvcrt)", &dynamicCrt);
    if (opts.helpWanted)
    {
        defaultGetoptPrinter("Build static SDL3 + SDL3_ttf for `dub build -c static`.", opts.options);
        return 0;
    }

    string root = dirName(dirName(__FILE_FULL_PATH__));
    string defaultPrefix = WINDOWS ? buildPath(root, "install") : expandTilde("~/.local");
    if (prefix.length == 0)
        prefix = defaultPrefix;
    prefix = absolutePath(prefix);

    try
    {
        build(root, prefix, noClean == false, dynamicCrt, skipPackages, vendored || WINDOWS);
    }
    catch (Exception ex)
    {
        stderr.writeln("error: ", ex.msg);
        return 1;
    }

    if (prefix != defaultPrefix)
        writeln("warning: dub.sdl searches ", buildPath(defaultPrefix, "lib"),
            ", not ", buildPath(prefix, "lib"));
    return 0;
}

void build(string root, string prefix, bool clean, bool dynamicCrt, bool skipPackages, bool vendored)
{
    string sdlDir = buildPath(root, "SDL");
    string ttfDir = buildPath(root, "SDL_ttf");
    string libDir = buildPath(prefix, "lib");

    // Pinned so a distro picking lib64 cannot move the archives away from where
    // dub.sdl looks.
    string[] common = [
        "CMAKE_BUILD_TYPE=Release",
        "CMAKE_INSTALL_PREFIX=" ~ prefix,
        "CMAKE_INSTALL_LIBDIR=lib",
    ];
    if (WINDOWS)
    {
        importMsvc();
        // DMD/LDC link the static CRT (libcmt) by default; SDL defaults to the
        // dynamic UCRT, and mixing them yields unresolved __imp_* symbols.
        // SDL_FORCE_STATIC_VCRT is SDL2-only and SDL3 silently ignores it.
        common ~= "CMAKE_MSVC_RUNTIME_LIBRARY=" ~ (dynamicCrt ? "MultiThreadedDLL" : "MultiThreaded");
        // cl.exe cannot create its .pch on a VM shared folder (C1083).
        common ~= "CMAKE_DISABLE_PRECOMPILE_HEADERS=ON";
        writeln("CRT: ", dynamicCrt ? "dynamic (/MD)" : "static (/MT)");
    }
    else
    {
        installPackages(skipPackages, vendored);
    }

    foreach (string tool; WINDOWS ? ["cl", "cmake", "ninja", "git"] : ["cmake", "ninja", "git"])
    {
        string path = findTool(tool);
        if (path is null && dryRun)
            writeln("warning: required tool '", tool, "' not found on PATH");
        else if (path is null)
            throw new Exception(format("required tool '%s' not found on PATH", tool));
        else
            writeln(format("  %-6s %s", tool, path));
    }

    checkout(sdlDir, "https://github.com/libsdl-org/SDL.git", SDL_TAG, false);
    cmakeBuild(sdlDir, clean, common ~ [
        "SDL_SHARED=OFF",
        "SDL_STATIC=ON",
        "SDL_TESTS=OFF",
        "SDL_TEST_LIBRARY=OFF",
    ]);

    if (vendored == false)
        environment["PKG_CONFIG_PATH"] = buildPath(libDir, "pkgconfig") ~
            pathSeparator ~ environment.get("PKG_CONFIG_PATH", "");
    checkout(ttfDir, "https://github.com/libsdl-org/SDL_ttf.git", SDL_TTF_TAG, vendored);
    cmakeBuild(ttfDir, clean, common ~ [
        "CMAKE_PREFIX_PATH=" ~ prefix,
        "BUILD_SHARED_LIBS=OFF",
        "SDLTTF_VENDORED=" ~ (vendored ? "ON" : "OFF"),
        "SDLTTF_HARFBUZZ=ON",
        "SDLTTF_SAMPLES=OFF",
    ]);
    if (vendored)
        copyVendored(buildPath(ttfDir, "build"), libDir);

    if (dryRun)
    {
        writeln();
        writeln("Dry run: nothing changed; the dub.sdl check below reads the existing install.");
        checkDubLibs(root, libDir);
        return;
    }

    string sdlLib = buildPath(libDir, WINDOWS ? "SDL3-static.lib" : "libSDL3.a");
    writeln();
    writeln("Installed to ", prefix);
    writeln("  static libs : ", libDir, vendored ? " (+ vendored freetype/harfbuzz)" : "");
    writeln("  headers     : ", buildPath(prefix, "include"));
    writeln("  pkg-config  : ", buildPath(libDir, "pkgconfig"));
    if (exists(sdlLib) == false)
        writeln("warning: expected ", sdlLib, " but it is missing; check the install output above");

    checkDubLibs(root, libDir);
}

void run(string[] args)
{
    writeln(dryRun ? "(dry) " : "> ", escapeShellCommand(args));
    if (dryRun)
        return;
    int status = wait(spawnProcess(args));
    if (status != 0)
        throw new Exception(format("%s failed (exit code %d)", args[0], status));
}

string findTool(string name)
{
    if (WINDOWS)
        name ~= ".exe";
    foreach (string dir; environment.get("PATH", "").splitter(pathSeparator))
    {
        if (dir.length == 0)
            continue;
        string path = buildPath(dir, name);
        if (exists(path) && isFile(path))
            return path;
    }
    return null;
}

string[string] readOsRelease()
{
    string[string] fields;
    foreach (string path; ["/etc/os-release", "/usr/lib/os-release"])
    {
        if (exists(path) == false)
            continue;
        foreach (string line; readText(path).lineSplitter)
        {
            ptrdiff_t eq = line.indexOf('=');
            if (eq <= 0 || line.startsWith("#"))
                continue;
            string value = line[eq + 1 .. $].strip;
            if (value.length >= 2 && (value[0] == '"' || value[0] == '\'') && value[$ - 1] == value[0])
                value = value[1 .. $ - 1];
            fields[line[0 .. eq]] = value;
        }
        break;
    }
    return fields;
}

Family detectFamily(string[string] osr)
{
    foreach (string id; (osr.get("ID", "") ~ " " ~ osr.get("ID_LIKE", "")).split)
    {
        switch (id)
        {
        case "debian", "ubuntu":
            return Family.debian;
        case "fedora":
            return Family.fedora;
        case "rhel", "centos":
            return Family.el;
        default:
        }
    }
    return Family.unknown;
}

// Per package, so the install line and any admin request name only what is
// missing. dpkg -s would accept a removed package whose config files remain.
string[] missingPackages(Family family, const(string)[] pkgs)
{
    string[] missing;
    foreach (string pkg; pkgs)
    {
        string[] query = family == Family.debian
            ? ["dpkg-query", "-W", "-f=${db:Status-Status}", pkg]
            : ["rpm", "-q", pkg];
        bool installed;
        try
        {
            auto r = execute(query);
            installed = r.status == 0 && (family != Family.debian || r.output == "installed");
        }
        catch (Exception)
        {
        }
        if (installed == false)
            missing ~= pkg;
    }
    return missing;
}

bool isRoot()
{
    version (Posix)
    {
        import core.sys.posix.unistd : geteuid;
        return geteuid() == 0;
    }
    else
        return false;
}

void installPackages(bool skip, bool vendored)
{
    string[string] osr = readOsRelease();
    Family family = detectFamily(osr);
    if (family == Family.unknown)
    {
        writeln("warning: no package list for '", osr.get("ID", "?"), "'; install the headers for:");
        writeln("  X11 (Xext Xrandr Xcursor Xi Xfixes XScrnSaver Xtst), Wayland + protocols,");
        writeln("  xkbcommon, libdecor, EGL, GLES2, PulseAudio, ALSA, D-Bus;");
        if (vendored == false)
            writeln("  FreeType, HarfBuzz;");
        writeln("  plus a C compiler, cmake, ninja, git, and Noto fonts");
        return;
    }

    const(string)[] wanted = family == Family.debian
        ? DEBIAN_PACKAGES ~ (vendored ? [] : DEBIAN_TTF_PACKAGES)
        : FEDORA_PACKAGES ~ (vendored ? [] : FEDORA_TTF_PACKAGES);
    if (family == Family.el)
        wanted = wanted.map!elPackage.array;
    string[] missing = missingPackages(family, wanted);
    if (missing.length == 0)
        return;

    string crbHint;
    string[] install = family == Family.debian ? ["apt-get", "install", "-y"] : ["dnf", "install", "-y"];
    // ninja-build and libdecor-devel live in CRB. Enabled for this transaction
    // only, so the repo configuration stays as the administrator left it.
    if (family == Family.el && crbEnabled() == false)
    {
        if (enableCrb == false && skip == false && dryRun == false)
            enableCrb = confirm("ninja-build and libdecor-devel are in the disabled CRB repository; " ~
                "use it for this install? [y/N] ");
        if (enableCrb || skip || dryRun)
            install ~= "--enablerepo=crb";
        else
            crbHint = "\nor rerun with --enable-crb to install from CRB for this run.";
    }
    install ~= missing;
    // SDL's configure drops a backend whose headers are absent instead of
    // failing, so building past this point yields e.g. a binary without Wayland.
    string request = "missing packages; as root (or ask an administrator):\n  " ~ escapeShellCommand(install);
    if (skip)
    {
        writeln("warning: ", request, "\nSDL drops the backends whose headers are missing.");
        return;
    }
    request ~= "\nor rerun with --skip-packages to build without them (SDL drops the matching backends).";
    request ~= crbHint;

    string[] elevate;
    if (isRoot() == false)
    {
        string tool = findTool("sudo");
        if (tool is null)
            tool = findTool("doas");
        if (tool is null && dryRun == false)
            throw new Exception(request);
        elevate = [tool is null ? "sudo" : baseName(tool)];
    }

    // Covers a user outside sudoers too: sudo asks for the password, then fails.
    try
    {
        if (family == Family.debian)
            run(elevate ~ ["apt-get", "update"]);
        run(elevate ~ install);
    }
    catch (Exception ex)
    {
        throw new Exception(ex.msg ~ "\n" ~ request);
    }
}

bool crbEnabled()
{
    try
    {
        Tuple!(int, "status", string, "output") r = execute(["dnf", "repolist", "--enabled", "-q"]);
        foreach (string line; r.output.lineSplitter)
            if (line.startsWith("crb ", "codeready-builder"))
                return true;
    }
    catch (Exception)
    {
    }
    return false;
}

// No terminal (CI, pipes) means no answer, which is a no.
bool confirm(string question)
{
    version (Posix)
    {
        import core.sys.posix.unistd : isatty;
        if (isatty(0) == 0)
            return false;
    }
    write(question);
    stdout.flush();
    string answer = readln().strip;
    return answer == "y" || answer == "Y" || answer == "yes";
}

// The Windows half of what the Linux package step does: the Win32/D3D/WASAPI
// backends ship in the Windows SDK, so only the compiler's environment is needed.
void importMsvc()
{
    string vswhere = buildPath(environment.get("ProgramFiles(x86)", `C:\Program Files (x86)`),
        `Microsoft Visual Studio\Installer\vswhere.exe`);
    if (exists(vswhere) == false)
        throw new Exception(`vswhere.exe not found: no Visual Studio / Build Tools install detected.

Install the C++ build tools (free, no IDE required):
    winget install --id Microsoft.VisualStudio.2022.BuildTools --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"

A mingw gcc is not a substitute: DMD/LDC produce MSVC-ABI objects on win64.`);

    // Native toolset for the host, matching what the D compiler targets.
    version (AArch64)
    {
        enum string COMPONENT = "Microsoft.VisualStudio.Component.VC.Tools.ARM64";
        enum string VCVARS = "vcvarsarm64.bat";
    }
    else
    {
        enum string COMPONENT = "Microsoft.VisualStudio.Component.VC.Tools.x86.x64";
        enum string VCVARS = "vcvars64.bat";
    }

    auto found = execute([vswhere, "-latest", "-products", "*",
        "-requires", COMPONENT,
        "-property", "installationPath"]);
    string vsRoot = found.output.strip;
    if (found.status != 0 || vsRoot.length == 0)
        throw new Exception("Visual Studio found, but the 'Desktop development with C++' workload is not installed");

    string vcvars = buildPath(vsRoot, `VC\Auxiliary\Build`, VCVARS);
    if (exists(vcvars) == false)
        throw new Exception(VCVARS ~ " not found under " ~ vsRoot);

    writeln("Importing MSVC environment from ", vcvars);
    auto dump = executeShell(`call "` ~ vcvars ~ `" >nul 2>&1 && set`);
    if (dump.status != 0)
        throw new Exception(format("%s failed (exit code %d)", VCVARS, dump.status));
    foreach (string line; dump.output.lineSplitter)
    {
        ptrdiff_t eq = line.indexOf('=');
        if (eq <= 0)
            continue;
        // Output is in the OEM codepage; a variable that is not valid UTF-8 is
        // never one cmake needs.
        try
            environment[line[0 .. eq]] = line[eq + 1 .. $];
        catch (Exception)
        {
        }
    }

    // mingw stays on PATH after vcvars and ships its own gcc; pin cl.
    environment["CC"]  = "cl";
    environment["CXX"] = "cl";
}

void checkout(string dir, string url, string tag, bool submodules)
{
    if (exists(dir) == false)
    {
        string[] cmd = ["git", "clone", "--depth", "1", "--branch", tag];
        if (submodules)
            cmd ~= "--recurse-submodules";
        run(cmd ~ [url, dir]);
        return;
    }

    writeln("Reusing existing checkout at ", dir);
    // A checkout from a --vendored=false run lacks the vendored sources.
    if (submodules)
        run(["git", "-C", dir, "submodule", "update", "--init", "--depth", "1"]);
    // Informational only: a network-share checkout can trip git's "dubious
    // ownership" guard, which must not abort the build.
    try
    {
        auto desc = execute(["git", "-C", dir, "describe", "--tags", "--always"]);
        string at = desc.output.strip;
        if (desc.status == 0 && at != tag)
            writeln("warning: ", dir, " is at ", at, ", expected ", tag, "; delete it to re-clone");
    }
    catch (Exception)
    {
    }
}

void cmakeBuild(string src, bool clean, string[] defines)
{
    string dir = buildPath(src, "build");
    // Settings change between runs and a stale cache does not notice.
    if (clean && exists(dir))
    {
        writeln(dryRun ? "(dry) remove " : "Removing stale ", dir);
        if (dryRun == false)
            rmdirRecurse(dir);
    }
    run(["cmake", "-S", src, "-B", dir, "-G", "Ninja"] ~ defines.map!(d => "-D" ~ d).array);
    run(["cmake", "--build", dir]);
    run(["cmake", "--install", dir]);
}

// SDL_ttf installs only its own archive: the vendored freetype/harfbuzz stay
// in the build tree, where the final static link cannot find them.
void copyVendored(string buildDir, string libDir)
{
    if (dryRun)
    {
        writeln("(dry) copy vendored freetype/harfbuzz archives -> ", libDir);
        return;
    }
    foreach (string name; ["freetype", "harfbuzz"])
    {
        string[] wanted = [name ~ ".lib", "lib" ~ name ~ ".a"];
        string hit;
        foreach (DirEntry entry; dirEntries(buildDir, SpanMode.depth))
        {
            if (entry.isFile && wanted.canFind(baseName(entry.name)))
            {
                hit = entry.name;
                break;
            }
        }
        if (hit is null)
        {
            writeln("warning: no built ", name, " archive under ", buildDir, "; the link will fail");
            continue;
        }
        copy(hit, buildPath(libDir, baseName(hit)));
        writeln("  vendored ", baseName(hit), " -> ", libDir);
    }
}

// Flags drift instead of reprinting the list, so an SDL upgrade that adds a
// system dependency does not surface later as a confusing link error.
void checkDubLibs(string root, string libDir)
{
    // druntime already links these.
    immutable string[] implicit = WINDOWS ? [] : ["c", "m", "dl", "pthread", "rt"];

    string[] libs;
    foreach (string pc; ["sdl3.pc", "sdl3-ttf.pc"])
    {
        string path = buildPath(libDir, "pkgconfig", pc);
        if (exists(path) == false)
        {
            writeln("warning: ", path, " missing; cannot check dub.sdl");
            return;
        }
        foreach (string line; readText(path).lineSplitter)
        {
            if (line.startsWith("Libs:", "Libs.private:") == 0)
                continue;
            foreach (string token; line.split)
            {
                if (token.startsWith("-l") == false)
                    continue;
                string lib = token[2 .. $];
                if (libs.canFind(lib) == false && implicit.canFind(lib) == false)
                    libs ~= lib;
            }
        }
    }

    string dub = readText(buildPath(root, "dub.sdl"));
    string[] missing = libs.filter!(lib => dub.canFind(`"` ~ lib ~ `"`) == false).array;
    writeln();
    if (missing.length)
        writeln("warning: dub.sdl's static configuration is missing: ", missing.join(" "));
    else
        writeln("dub.sdl already links all ", libs.length, " libs SDL reports.");
}
