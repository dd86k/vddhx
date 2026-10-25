/// Saved settings (.vddhxrc, ddhx's `key value` syntax): defaults for new
/// documents and views, plus window chrome.
///
/// Saving edits lines in place, preserving comments, order and unknown keys.
/// Authors: dd86k <dd@dax.moe>
module preferences;

import std.system : Endian;
import ddlogger;
import ddhx.charset : Charset, ASCII, findCharset;
import hexview : HEX_COLUMNS_MAX, HexBase;

/// Mode new tabs start in. Read-only only sets the tab's starting state.
enum WriteMode { overwrite, insert, readonly }

/// Default text size in points.
enum int FONT_SIZE = 14;
/// Smallest text size in points.
enum int FONT_SIZE_MIN = 6;
/// Largest text size in points.
enum int FONT_SIZE_MAX = 72;

/// Copied into documents and views on creation; changes don't affect open ones.
struct Prefs
{
    int columns = 16;   /// Elements per row. 0 to fit to pane.
    immutable(Charset)* charset = &ASCII;   /// Change charset default.
    Endian endian = Endian.littleEndian;    /// Change endianness default.
    WriteMode writemode;    /// Change write mode default.
    HexBase address;        /// Offset base default.
    bool minimap = true;    /// Show minimap.
    bool crumbs = true;     /// Show breadcrumbs.
    int fontsize = FONT_SIZE;   /// Text size in points.
}

/// Ditto.
__gshared Prefs prefs;

/// All keys, in the order a new file lists them.
immutable string[] PREFS_KEYS = [
    "columns", "charset", "endian", "writemode", "address", "minimap",
    "breadcrumbs", "fontsize",
];

private enum string APPNAME = "vddhx";
private enum string FILENAME = ".vddhxrc";

private __gshared string[] lines;
private __gshared string savePath;

/// Read the first .vddhxrc found, same lookup as ddhx. Bad lines are logged
/// and skipped.
void prefs_load()
{
    import std.file : readText;
    import std.string : lineSplitter;
    import std.array : array;
    import os.path : findConfig;

    savePath = prefs_user_path();

    string path = findConfig(APPNAME, FILENAME);
    if (path is null)
        return;

    string text;
    try
        text = readText(path);
    catch (Exception e)
    {
        logWarn("%s: %s", path, e.msg);
        return;
    }

    // Don't overwrite a system-wide file: save a user copy, seeded with its lines.
    if (prefs_system(path) == false)
        savePath = path;

    lines = text.lineSplitter.array;
    prefs_parse(prefs, lines, path);
}

/// Write `prefs` back. Errors are logged, not thrown.
/// Returns: False if the file could not be written.
bool prefs_save()
{
    import std.file : mkdirRecurse, rename, write;
    import std.path : dirName;

    if (savePath is null)
    {
        logWarn("no place to save settings");
        return false;
    }

    prefs_merge(lines, prefs);

    try
    {
        mkdirRecurse(dirName(savePath));
        // Write via temp file to avoid partial writes.
        string tmp = savePath ~ ".tmp";
        write(tmp, prefs_text(lines));
        rename(tmp, savePath);
    }
    catch (Exception e)
    {
        logError("%s: %s", savePath, e.msg);
        return false;
    }
    return true;
}

/// prefs_save target, null if there is no config folder.
string prefs_path()
{
    return savePath;
}

/// Set one key from its file text.
/// Returns: False for an unknown key or invalid value.
bool prefs_set(ref Prefs p, string key, string value)
{
    switch (key)
    {
    case "columns":
        import std.conv : to;
        if (value == "auto" || value == "autoresize") // ddhx takes both
        {
            p.columns = 0;
            return true;
        }
        int cols;
        try
            cols = to!int(value);
        catch (Exception)
            return false;
        if (cols < 1 || cols > HEX_COLUMNS_MAX)
            return false;
        p.columns = cols;
        return true;
    case "charset":
        immutable(Charset)* set = findCharset(value);
        if (set is null)
            return false;
        p.charset = set;
        return true;
    case "endian":
        switch (value)
        {
        case "little", "le": p.endian = Endian.littleEndian; return true;
        case "big", "be":    p.endian = Endian.bigEndian;    return true;
        default:             return false;
        }
    case "writemode":
        switch (value)
        {
        case "overwrite": p.writemode = WriteMode.overwrite; return true;
        case "insert":    p.writemode = WriteMode.insert;    return true;
        case "readonly":  p.writemode = WriteMode.readonly;  return true;
        default:          return false;
        }
    case "address":
        // ddhx's values, spelled out or short.
        switch (value)
        {
        case "hexadecimal", "hex": p.address = HexBase.hex; return true;
        case "decimal", "dec":     p.address = HexBase.dec; return true;
        case "octal", "oct":       p.address = HexBase.oct; return true;
        default:                   return false;
        }
    case "minimap":     return prefs_bool(value, p.minimap);
    case "breadcrumbs": return prefs_bool(value, p.crumbs);
    case "fontsize":
        import std.conv : to;
        int pt;
        try
            pt = to!int(value);
        catch (Exception)
            return false;
        if (pt < FONT_SIZE_MIN || pt > FONT_SIZE_MAX)
            return false;
        p.fontsize = pt;
        return true;
    default:            return false;
    }
}

/// One key's value in file syntax.
string prefs_get(ref const(Prefs) p, string key)
{
    import std.conv : to;

    switch (key)
    {
    case "columns":     return p.columns ? to!string(p.columns) : "auto";
    case "charset":     return p.charset.id;
    case "endian":      return p.endian == Endian.bigEndian ? "big" : "little";
    case "writemode":   return to!string(p.writemode);
    case "address":     return to!string(p.address);
    case "minimap":     return p.minimap ? "on" : "off";
    case "breadcrumbs": return p.crumbs ? "on" : "off";
    case "fontsize":    return to!string(p.fontsize);
    default:            assert(false, key);
    }
}

private:

// Same values as ddhx's configuration.boolean.
bool prefs_bool(string value, ref bool field)
{
    switch (value)
    {
    case "on":  field = true;  return true;
    case "off": field = false; return true;
    default:    return false;
    }
}

bool prefs_system(string path)
{
    import std.path : buildPath;
    import os.path : getSystemFolder;

    string sys = getSystemFolder();
    return sys !is null && path == buildPath(sys, APPNAME, FILENAME);
}

string prefs_user_path()
{
    import std.path : buildPath;
    import os.path : getUserConfigFolder;

    string dir = getUserConfigFolder();
    return dir ? buildPath(dir, APPNAME, FILENAME) : null;
}

// Key set by a line, null for blank lines and comments.
string prefs_line_key(string line, out string value)
{
    import std.string : strip;
    import utils : Argument, arguments;

    string text = strip(line);
    if (text.length == 0 || text[0] == '#')
        return null;

    Argument[] args;
    try
        args = arguments(text);
    catch (Exception)
        return text; // key-like; caller reports it
    if (args.length == 0)
        return null;
    if (args.length > 1)
        value = args[1].text;
    return args[0].text;
}

void prefs_parse(ref Prefs p, const(string)[] text, string path)
{
    foreach (size_t i, string line; text)
    {
        string value;
        string key = prefs_line_key(line, value);
        if (key is null)
            continue;
        if (prefs_set(p, key, value) == false)
            logWarn("%s:%u: ignored: %s", path, i + 1, line);
    }
}

// Rewrites each key's last line (the effective one). Missing keys are added
// only when non-default, so an untouched file stays empty.
void prefs_merge(ref string[] text, ref const(Prefs) p)
{
    static immutable Prefs defaults;

    foreach (string key; PREFS_KEYS)
    {
        string line = key ~ " " ~ prefs_get(p, key);

        ptrdiff_t at = -1;
        foreach (size_t i, string l; text)
        {
            string value;
            if (prefs_line_key(l, value) == key)
                at = i;
        }

        if (at >= 0)
            text[at] = line;
        else if (prefs_get(p, key) != prefs_get(defaults, key))
            text ~= line;
    }
}

string prefs_text(const(string)[] text)
{
    import std.array : join;
    return text.length ? join(text, "\n") ~ "\n" : "";
}

unittest
{
    import ddhx.charset : CP437;

    Prefs p;
    string[] text = [
        "# mine",
        "columns 8",
        "bind j left",
        "charset cp437",
        "columns 24",
    ];
    prefs_parse(p, text, "test");
    assert(p.columns == 24);
    assert(p.charset == &CP437);

    // Only the effective line changes; untouched defaults add nothing.
    p.columns = 0;
    p.minimap = false;
    prefs_merge(text, p);
    assert(text == [
        "# mine",
        "columns 8",
        "bind j left",
        "charset cp437",
        "columns auto",
        "minimap off",
    ]);
}

unittest
{
    Prefs p;
    assert(prefs_set(p, "columns", "0") == false);
    assert(prefs_set(p, "columns", "257") == false);
    assert(prefs_set(p, "endian", "be"));
    assert(p.endian == Endian.bigEndian);
    assert(prefs_set(p, "writemode", "readonly"));
    assert(p.writemode == WriteMode.readonly);
    assert(prefs_get(p, "writemode") == "readonly");
    assert(prefs_set(p, "writemode", "digit") == false);
    assert(prefs_set(p, "address", "octal"));
    assert(p.address == HexBase.oct);
    assert(prefs_get(p, "address") == "oct");
    assert(prefs_set(p, "address", "dec"));
    assert(p.address == HexBase.dec);
    assert(prefs_set(p, "address", "binary") == false);
    assert(prefs_set(p, "minimap", "true") == false);
    assert(prefs_set(p, "fontsize", "18"));
    assert(p.fontsize == 18);
    assert(prefs_get(p, "fontsize") == "18");
    assert(prefs_set(p, "fontsize", "5") == false);
    assert(prefs_set(p, "fontsize", "big") == false);
    assert(prefs_set(p, "nope", "on") == false);
}
