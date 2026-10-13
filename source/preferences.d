/// Saved settings: what new documents and views start with, plus the window chrome,
/// kept in a .vddhxrc written in ddhx's `key value` syntax.
///
/// The file is rewritten line by line rather than regenerated, so comments, order
/// and keys this build does not know survive the dialog saving over them.
/// Authors: dd86k <dd@dax.moe>
module preferences;

import std.system : Endian;
import ddlogger;
import ddhx.charset : Charset, ASCII, findCharset;
import hexview : HEX_COLUMNS_MAX;

/// Saved settings. Documents and views copy these when created and never look
/// back, so changing one leaves what is already open alone.
struct Prefs
{
    int columns = 16;   /// 0 fits the row to the pane.
    immutable(Charset)* charset = &ASCII;
    Endian endian = Endian.littleEndian;
    bool insert;
    bool minimap = true;
    bool crumbs = true;
}

/// Ditto.
__gshared Prefs prefs;

/// Every key the file may hold, in the order a fresh file lists them.
immutable string[] PREFS_KEYS = [
    "columns", "charset", "endian", "writemode", "minimap", "breadcrumbs",
];

private enum string APPNAME = "vddhx";
private enum string FILENAME = ".vddhxrc";

private __gshared string[] lines;
private __gshared string savePath;

/// Read the first .vddhxrc found, the way ddhx looks for its own. A bad line is
/// logged and skipped: one typo should not throw out the rest of the file.
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

    // A system-wide file is someone else's to change: saving writes a user copy,
    // starting from its lines so the copy does not shadow them with nothing.
    if (prefs_system(path) == false)
        savePath = path;

    lines = text.lineSplitter.array;
    prefs_parse(prefs, lines, path);
}

/// Write `prefs` back. Errors are logged, not thrown: losing a setting is not worth
/// interrupting whatever changed it.
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
        // Through a temporary, so a failed write cannot leave half a file.
        string tmp = savePath ~ ".tmp";
        write(tmp, prefs_text(lines));
        rename(tmp, savePath);
    }
    catch (Exception e)
    {
        logWarn("%s: %s", savePath, e.msg);
        return false;
    }
    return true;
}

/// Where prefs_save writes, null when there is no config folder to write in.
string prefs_path()
{
    return savePath;
}

/// Set one key from its text, as the file writes it.
/// Returns: False for an unknown key or a value it does not take.
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
        // ddhx's "readonly" and "digit" have no vddhx counterpart yet.
        switch (value)
        {
        case "overwrite": p.insert = false; return true;
        case "insert":    p.insert = true;  return true;
        default:          return false;
        }
    case "minimap":     return prefs_bool(value, p.minimap);
    case "breadcrumbs": return prefs_bool(value, p.crumbs);
    default:            return false;
    }
}

/// One key's value as the file writes it.
string prefs_get(ref const(Prefs) p, string key)
{
    import std.conv : to;

    switch (key)
    {
    case "columns":     return p.columns ? to!string(p.columns) : "auto";
    case "charset":     return p.charset.id;
    case "endian":      return p.endian == Endian.bigEndian ? "big" : "little";
    case "writemode":   return p.insert ? "insert" : "overwrite";
    case "minimap":     return p.minimap ? "on" : "off";
    case "breadcrumbs": return p.crumbs ? "on" : "off";
    default:            assert(false, key);
    }
}

private:

// ddhx's pair and no other, see its configuration.boolean.
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

// The key a line sets, or null for a blank line or a comment.
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
        return text; // still a key-ish line; the caller reports it
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

// Each key's last line is the one in force, so that is the one rewritten. A key
// with no line only gets one once it differs from the default, which keeps a file
// nobody touched empty.
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

    // Only the line in force changes; untouched defaults add nothing.
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
    assert(prefs_set(p, "writemode", "readonly") == false);
    assert(prefs_set(p, "minimap", "true") == false);
    assert(prefs_set(p, "nope", "on") == false);
}
