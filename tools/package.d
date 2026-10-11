// Builds the static configuration and wraps it into .deb and/or .rpm packages.
//
// The static build only links the distro's freetype/harfbuzz; dpkg-shlibdeps
// and rpmbuild turn those into versioned dependencies. What SDL and render.d
// dlopen (video backends, fontconfig) never shows up as a NEEDED entry, so it
// is listed by hand as recommendations. Build each format on its own distro
// family so that glibc requirements match what users have.
//
// Usage: dmd -run tools/package.d [--help] [options...]
module package_;

import std.algorithm : canFind, map, sort, splitter;
import std.array : array, join;
import std.conv : octal;
import std.digest : toHexString, LetterCase;
import std.digest.md : md5Of;
import std.file : copy, dirEntries, DirEntry, exists, getSize, isFile, mkdirRecurse,
    read, readText, rmdirRecurse, setAttributes, SpanMode, write;
import std.format : format;
import std.getopt : defaultGetoptPrinter, getopt, GetoptResult;
import std.path : absolutePath, buildPath, dirName, pathSeparator, relativePath;
import std.process : Config, environment, escapeShellCommand, execute, spawnProcess, wait;
import std.regex : matchFirst, regex, Captures;
import std.stdio : stderr, writeln;
import std.string : startsWith, strip;
import std.typecons : Tuple;

private: // shuts up dscanner

enum NAME = "vddhx";
enum SUMMARY = "Graphical hex editor";
enum DESCRIPTION = "A graphical hex editor built on ddhx, for files and disks.";

immutable uint[] ICON_SIZES = [16, 32, 48, 64, 128, 256];

// Sonames dlopened at runtime: SDL's video backends and render.d's fontconfig.
// Mapped to Debian package names; rpm can recommend the sonames directly.
immutable string[2][] RUNTIME_LIBS = [
    ["libwayland-client.so.0", "libwayland-client0"],
    ["libwayland-cursor.so.0", "libwayland-cursor0"],
    ["libwayland-egl.so.1",    "libwayland-egl1"],
    ["libxkbcommon.so.0",      "libxkbcommon0"],
    ["libX11.so.6",            "libx11-6"],
    ["libX11-xcb.so.1",        "libx11-xcb1"],
    ["libXcursor.so.1",        "libxcursor1"],
    ["libXext.so.6",           "libxext6"],
    ["libXfixes.so.3",         "libxfixes3"],
    ["libXi.so.6",             "libxi6"],
    ["libXrandr.so.2",         "libxrandr2"],
    ["libXss.so.1",            "libxss1"],
    ["libEGL.so.1",            "libegl1"],
    ["libGL.so.1",             "libgl1"],
    ["libfontconfig.so.1",     "libfontconfig1"],
];

// Fonts render.d asks for first. Fontconfig falls back to anything installed,
// so none are hard requirements. Fedora and openSUSE generate font() provides.
immutable string[] DEB_FONTS = ["fonts-noto-core", "fonts-noto-mono", "fonts-noto-cjk"];
immutable string[] RPM_FONTS = ["font(notosans)", "font(notosansmono)", "font(notosanscjksc)"];

struct Meta
{
    string version_;
    string release;
    string maintainer;
    string homepage;
    string license;
}

int main(string[] args)
{
    bool deb, rpm, noBuild;
    string compiler, outDir, release = "1";
    GetoptResult opts = getopt(args,
        "deb", "Build a .deb (default: every format whose tools are on PATH)", &deb,
        "rpm", "Build an .rpm", &rpm,
        "compiler", "D compiler passed to dub (default: dub's choice)", &compiler,
        "release", "Package release/revision number (default: 1)", &release,
        "out", "Output directory (default: <repo>/dist)", &outDir,
        "no-build", "Package the existing ./vddhx (must be the static configuration)", &noBuild);
    if (opts.helpWanted)
    {
        defaultGetoptPrinter("Package vddhx as .deb and/or .rpm.", opts.options);
        return 0;
    }

    string root = dirName(dirName(__FILE_FULL_PATH__));
    outDir = absolutePath(outDir.length ? outDir : buildPath(root, "dist"));

    // No flag: build whatever this host can, so a bare run just works.
    if (deb == false && rpm == false)
    {
        deb = findTool("dpkg-deb") !is null;
        rpm = findTool("rpmbuild") !is null;
        if (deb == false && rpm == false)
        {
            stderr.writeln("error: neither dpkg-deb nor rpmbuild found on PATH");
            return 1;
        }
    }

    try
    {
        Meta meta = readMeta(root);
        meta.release = release;
        string binary = buildPath(root, NAME);
        if (noBuild == false)
        {
            string[] cmd = ["dub", "build", "-c", "static", "-b", "release", "--root", root];
            if (compiler.length)
                cmd ~= "--compiler=" ~ compiler;
            run(cmd);
        }
        if (exists(binary) == false)
            throw new Exception(binary ~ " not found");

        mkdirRecurse(outDir);
        string arch = machine();
        if (deb)
            writeln("Built ", packageDeb(root, outDir, binary, meta));
        if (rpm)
            writeln("Built ", packageRpm(root, outDir, binary, arch, meta));
    }
    catch (Exception ex)
    {
        stderr.writeln("error: ", ex.msg);
        return 1;
    }
    return 0;
}

// about.d holds the version and project facts; dub.sdl deliberately has none.
Meta readMeta(string root)
{
    // single source of truth, don't have to worry about changing these at multiple places
    string about = readText(buildPath(root, "source", "about.d"));
    string field(string name)
    {
        Captures!string m = matchFirst(about, regex(`enum ` ~ name ~ ` = "([^"]+)"`));
        if (m.empty)
            throw new Exception("source/about.d: no " ~ name);
        return m[1];
    }
    Meta meta;
    meta.version_   = field("VERSION");
    meta.maintainer = field("AUTHOR");
    meta.homepage   = field("HOMEPAGE");
    meta.license    = field("LICENSE");
    return meta;
}

string machine()
{
    Tuple!(int, "status", string, "output") r = execute(["uname", "-m"]);
    if (r.status != 0)
        throw new Exception("uname -m failed");
    return r.output.strip;
}

// Paths shared by both formats, laid out under dir as they land under /.
void stageCommon(string root, string dir, string binary)
{
    if (exists(dir))
        rmdirRecurse(dir);

    install(binary, buildPath(dir, "usr/bin", NAME), octal!755);
    run(["strip", "--strip-unneeded", buildPath(dir, "usr/bin", NAME)]);

    install(buildPath(root, "assets", NAME ~ ".desktop"),
        buildPath(dir, "usr/share/applications", NAME ~ ".desktop"), octal!644);

    string icons = buildPath(dir, "usr/share/icons/hicolor");
    foreach (uint size; ICON_SIZES)
        install(buildPath(root, "assets/icon", format("%s-%u.png", NAME, size)),
            buildPath(icons, format("%ux%u/apps", size, size), NAME ~ ".png"), octal!644);
    install(buildPath(root, "assets/icon", NAME ~ ".svg"),
        buildPath(icons, "scalable/apps", NAME ~ ".svg"), octal!644);
}

void install(string from, string to, uint mode)
{
    mkdirRecurse(dirName(to));
    copy(from, to);
    setAttributes(to, mode);
}

// Sorted so md5sums and listings are stable between runs.
string[] stagedFiles(string dir)
{
    string[] files;
    foreach (DirEntry e; dirEntries(dir, SpanMode.depth))
        if (e.isFile)
            files ~= relativePath(e.name, dir);
    files.sort();
    return files;
}

string packageDeb(string root, string outDir, string binary, Meta meta)
{
    foreach (string tool; ["dpkg-deb", "dpkg-shlibdeps", "dpkg"])
        if (findTool(tool) is null)
            throw new Exception(tool ~ " not found on PATH (dpkg-dev)");

    string arch = execute(["dpkg", "--print-architecture"]).output.strip;
    string stage = buildPath(outDir, "deb");
    stageCommon(root, stage, binary);
    scope (exit) rmdirRecurse(stage);
    install(buildPath(root, "LICENSE"),
        buildPath(stage, "usr/share/doc", NAME, "copyright"), octal!644);

    string[] files = stagedFiles(stage);
    ulong bytes;
    string md5sums;
    foreach (string f; files)
    {
        string path = buildPath(stage, f);
        bytes += getSize(path);
        md5sums ~= toHexString!(LetterCase.lower)(md5Of(read(path))) ~ "  " ~ f ~ "\n";
    }

    string[] depends = [shlibDepends(outDir, buildPath(stage, "usr/bin", NAME))];
    string[] recommends = RUNTIME_LIBS.map!(l => l[1]).array ~ DEB_FONTS.dup;

    string control = format(
        "Package: %s\n" ~
        "Version: %s-%s\n" ~
        "Architecture: %s\n" ~
        "Maintainer: %s\n" ~
        "Installed-Size: %u\n" ~
        "Depends: %s\n" ~
        "Recommends: %s\n" ~
        "Section: editors\n" ~
        "Priority: optional\n" ~
        "Homepage: %s\n" ~
        "Description: %s\n" ~
        " %s\n",
        NAME, meta.version_, meta.release, arch, meta.maintainer, (bytes + 1023) / 1024,
        depends.join(", "), recommends.join(", "), meta.homepage, SUMMARY, DESCRIPTION);

    string debian = buildPath(stage, "DEBIAN");
    mkdirRecurse(debian);
    write(buildPath(debian, "control"), control);
    write(buildPath(debian, "md5sums"), md5sums);

    string deb = buildPath(outDir, format("%s_%s-%s_%s.deb", NAME, meta.version_, meta.release, arch));
    run(["dpkg-deb", "--root-owner-group", "--build", stage, deb]);
    return deb;
}

// dpkg-shlibdeps insists on running from a source tree with debian/control.
string shlibDepends(string outDir, string binary)
{
    string tree = buildPath(outDir, "shlibdeps");
    mkdirRecurse(buildPath(tree, "debian"));
    write(buildPath(tree, "debian/control"),
        "Source: " ~ NAME ~ "\n\nPackage: " ~ NAME ~ "\nArchitecture: any\n");
    scope (exit) rmdirRecurse(tree);

    Tuple!(int, "status", string, "output") r = execute(
        ["dpkg-shlibdeps", "-O", "-e" ~ binary], null, Config.stderrPassThrough, size_t.max, tree);
    enum KEY = "shlibs:Depends=";
    if (r.status != 0 || r.output.startsWith(KEY) == false)
        throw new Exception("dpkg-shlibdeps failed:\n" ~ r.output);
    return r.output[KEY.length .. $].strip;
}

string packageRpm(string root, string outDir, string binary, string arch, Meta meta)
{
    if (findTool("rpmbuild") is null)
        throw new Exception("rpmbuild not found on PATH");

    string stage = buildPath(outDir, "rpm");
    stageCommon(root, stage, binary);
    scope (exit) rmdirRecurse(stage);
    install(buildPath(root, "LICENSE"),
        buildPath(stage, "usr/share/licenses", NAME, "LICENSE"), octal!644);

    // Matches the soname provides rpm generates on 64-bit targets.
    string suffix = ["x86_64", "aarch64", "ppc64le", "riscv64", "s390x"].canFind(arch) ? "()(64bit)" : "";
    string recommends;
    foreach (immutable string[2] lib; RUNTIME_LIBS)
        recommends ~= "Recommends: " ~ lib[0] ~ suffix ~ "\n";
    foreach (string font; RPM_FONTS)
        recommends ~= "Recommends: " ~ font ~ "\n";

    string files;
    foreach (string f; stagedFiles(stage))
        files ~= (f.startsWith("usr/share/licenses/") ? "%license /" : "/") ~ f ~ "\n";

    // Prebuilt: %install only copies the staged tree. Stripping happened in
    // stageCommon, so skip the debuginfo split and its build-id links.
    string spec = format(
        "%%global debug_package %%{nil}\n" ~
        "%%global _build_id_links none\n" ~
        "Name: %s\n" ~
        "Version: %s\n" ~
        "Release: %s\n" ~
        "Summary: %s\n" ~
        "License: %s\n" ~
        "URL: %s\n" ~
        "Packager: %s\n" ~
        "%s" ~
        "\n%%description\n%s\n" ~
        "\n%%install\ncp -a %s/. %%{buildroot}/\n" ~
        "\n%%files\n%s",
        NAME, meta.version_, meta.release, SUMMARY, meta.license, meta.homepage,
        meta.maintainer, recommends, DESCRIPTION, stage, files);

    string top = buildPath(outDir, "rpmbuild");
    mkdirRecurse(top);
    scope (exit) rmdirRecurse(top);
    string specPath = buildPath(top, NAME ~ ".spec");
    write(specPath, spec);

    run(["rpmbuild", "-bb", "--target", arch,
        "--define", "_topdir " ~ top,
        "--define", "_rpmdir " ~ outDir,
        "--define", "_build_name_fmt %%{NAME}-%%{VERSION}-%%{RELEASE}.%%{ARCH}.rpm",
        specPath]);
    return buildPath(outDir, format("%s-%s-%s.%s.rpm", NAME, meta.version_, meta.release, arch));
}

void run(string[] args)
{
    writeln("> ", escapeShellCommand(args));
    int status = wait(spawnProcess(args));
    if (status != 0)
        throw new Exception(format("%s failed (exit code %d)", args[0], status));
}

string findTool(string name)
{
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
