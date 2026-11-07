/// Byte-pattern search over a document: find box parsing, and the find, skip
/// and diff walks.
///
/// Syntax and parsing are ddhx's (`utils.arguments`, `patterns.pattern`), and
/// so is matching (`searches.search`).
/// Patterns require a prefix; no bare text, since it would have to guess
/// the encoding.
///
///   utf8:hello      text as UTF-8
///   utf16:hello     text as UTF-16 code units
///   utf8bom:hello   with BOM
///   utf8:"a\nb"     quoted token, C escapes
///   utf8:'a\nb'     quoted token, literal
///   0xdeadbeef      hex bytes
///   x:de ad be ef   same; later tokens inherit the prefix
///   u16:255  i8:-1  integer in the prefix's width
///   f32:1.0         IEEE-754
///   0xde ? 0xef     '?': any one byte
///   0xde * 0xef     '*': any run, including empty
///   u16:1..9        inclusive range, in the prefix's width
///
/// Quotes only affect escaping, never the encoding.
/// Scalars use the caller's byte order (the document setting); byte strings
/// ignore it.
///
/// NOTE: A '*' reaches at least 64 KiB, like ddhx: a match has to fit in one
/// of its search windows.
/// Authors: dd86k <dd@dax.moe>
module search;

import core.atomic : atomicLoad;
import std.algorithm.comparison : min;
import std.system : Endian;

import ddhx.editor.base : IDocumentEditor;
import patterns : pattern, Pattern, patternpfx, PatternType,
    PatternRange, PATTERN_GLOB_MANY, PATTERN_GLOB_ONE, PATTERN_HAS_GLOB,
    PATTERN_HAS_RANGE, PATTERN_RANGE, PATTERN_RANGE_TAIL;
import searches : ddhx_search = search, SearchResult, SearchAction,
    SEARCH_DIFF, SEARCH_REVERSE, SEARCH_ALIGNED, SEARCH_RESULT_NOT_FOUND;
import utils : Argument, arguments;

/// Needle sentinels (ddhx's): any one byte, and any run including empty.
enum ushort SEARCH_ANY = PATTERN_GLOB_ONE;
/// Ditto
enum ushort SEARCH_RUN = PATTERN_GLOB_MANY;
/// Range head, plus the index into `Needle.ranges`. Followed by
/// SEARCH_RANGE_TAIL for the rest of the width.
enum ushort SEARCH_RANGE = PATTERN_RANGE;
/// Ditto
enum ushort SEARCH_RANGE_TAIL = PATTERN_RANGE_TAIL;

/// Max pattern elements; also bounds per-offset work.
enum size_t SEARCH_MAX = 256;

/// Parsed pattern in fixed storage, owning nothing. Parsing allocates, so the
/// find box caches it (see ui.ui_find_needle).
struct Needle
{
    /// Byte values, SEARCH_ANY, SEARCH_RUN, or range elements.
    ushort[SEARCH_MAX] data;
    /// Elements used. Not the match length (runs vary): see `search_least`.
    size_t length;
    /// ddhx pattern flags (PATTERN_HAS_GLOB).
    int flags;
    /// Indexed by SEARCH_RANGE heads.
    PatternRange[SEARCH_MAX] ranges;
}

/// Document and buffers for a walk. Caller-owned so walks can run concurrently.
struct SearchContext
{
    IDocumentEditor editor;
    /// Checked per window. Results of a canceled walk are meaningless.
    shared(bool)* cancel;
    /// Called per window with 0-100.
    void delegate(int percent) progress;
    /// Diff window for `editor`.
    ubyte[] window;
    /// Diff window for the peer, used at the same time as `window`.
    ubyte[] peerWindow;
    /// Copy of the element being skipped over.
    ubyte[SEARCH_ELEMENT_MAX] element;

    private long total, done;
}

/// Context over `editor` with default window sizes.
SearchContext* search_context(IDocumentEditor editor)
{
    SearchContext* ctx = new SearchContext;
    ctx.editor     = editor;
    ctx.window     = new ubyte[SEARCH_WINDOW];
    ctx.peerWindow = new ubyte[SEARCH_WINDOW];
    return ctx;
}

/// Diff window size.
enum size_t SEARCH_WINDOW = 64 * 1024;

/// Parse a pattern; scalars are encoded in `endian`. Syntax: see module header.
/// Returns: false if not a (complete) pattern; `needle` left empty.
bool search_parse(const(char)[] text, out Needle needle,
    Endian endian = Endian.littleEndian)
{
    text = search_strip(text);
    if (text.length == 0)
        return false;

    // ddhx's tokenizer, for identical quoting rules.
    Argument[] args;
    try args = arguments(text);
    catch (Exception)
        return false; // bad quote or escape
    if (args.length == 0)
        return false;

    // The first token must have a prefix; the rest inherit (ddhx rule).
    if (search_prefixed(cast(const(char)[]) args[0].data) == false)
        return false;

    Pattern pat;
    try pat = pattern(endian, args);
    catch (Exception)
        return false; // invalid or incomplete

    if (pat.data.length == 0 || pat.data.length > SEARCH_MAX)
        return false;
    needle.data[0 .. pat.data.length] = pat.data;
    needle.length = pat.data.length;
    needle.flags  = pat.flags;
    needle.ranges[0 .. pat.ranges.length] = pat.ranges;
    return search_matchable(needle);
}

/// Whether `text` starts with a ddhx pattern prefix or wildcard. Asks ddhx, so
/// new prefixes need no change here.
bool search_prefixed(const(char)[] text)
{
    if (text == "?" || text == "*")
        return true;
    return patternpfx(text).spec.type != PatternType.unknown;
}

/// A prefix and its description, for the find box.
struct SearchPrefix
{
    /// Including the colon.
    string text;
    string what;
}

/// All ddhx prefixes, in ddhx's order.
///
/// NOTE: Copy of ddhx's list (a local in `patternpfx`, without descriptions).
/// The unittest catches removed or renamed prefixes; added ones still work but
/// won't be listed.
immutable SearchPrefix[] SEARCH_PREFIXES = [
    { "x:",        "bytes as written: x:de ad be ef" },
    { "0x",        "ditto, run together: 0xdeadbeef" },

    { "utf8:",     "text, as UTF-8" },
    { "utf16:",    "text, as UTF-16 code units" },
    { "utf32:",    "text, as UTF-32 code units" },
    { "utf8bom:",  "UTF-8 text, behind its byte-order mark" },
    { "utf16bom:", "UTF-16 text, behind its byte-order mark" },
    { "utf32bom:", "UTF-32 text, behind its byte-order mark" },

    { "x8:",       "hexadecimal value, 1 byte wide" },
    { "x16:",      "hexadecimal value, 2 bytes wide" },
    { "x32:",      "hexadecimal value, 4 bytes wide" },
    { "x64:",      "hexadecimal value, 8 bytes wide" },

    { "u8:",       "unsigned value, 1 byte wide" },
    { "u16:",      "unsigned value, 2 bytes wide" },
    { "u32:",      "unsigned value, 4 bytes wide" },
    { "u64:",      "unsigned value, 8 bytes wide" },

    { "i8:",       "signed value, 1 byte wide" },
    { "i16:",      "signed value, 2 bytes wide" },
    { "i32:",      "signed value, 4 bytes wide" },
    { "i64:",      "signed value, 8 bytes wide" },

    { "o8:",       "octal value, 1 byte wide" },
    { "o16:",      "octal value, 2 bytes wide" },
    { "o32:",      "octal value, 4 bytes wide" },
    { "o64:",      "octal value, 8 bytes wide" },

    { "f32:",      "IEEE-754 binary32" },
    { "f64:",      "IEEE-754 binary64" },
    { "f80:",      "IEEE-754 80-bit extended" },
];

/// Prefix `text` starts with, longest match.
/// Returns: null if none.
immutable(SearchPrefix)* search_prefix_of(const(char)[] text)
{
    immutable(SearchPrefix)* best;
    foreach (ref immutable SearchPrefix p; SEARCH_PREFIXES)
    {
        if (text.length < p.text.length || text[0 .. p.text.length] != p.text)
            continue;
        if (best is null || p.text.length > best.text.length)
            best = &p;
    }
    return best;
}

/// Minimum match length: runs may be empty. Equals `needle.length` without
/// runs.
size_t search_least(ref const(Needle) needle)
{
    size_t least;
    foreach (ushort element; needle.data[0 .. needle.length])
        if (element != SEARCH_RUN)
            ++least;
    return least;
}

/// Find `needle` starting at `from` (first offset forward, last offset
/// `backward`), wrapping around.
/// Backward, matches before the wrap must end by `stop` (exclusive), like
/// ddhx's find-prev, which skips matches overlapping the selection.
/// Returns: Match offset or -1, with `length` the match length (0 if none).
long search_find(ref const(Needle) needle, long from, long size, bool backward,
    out size_t length, ref SearchContext ctx, long stop = long.max)
{
    if (needle.length == 0 || ctx.editor is null)
        return -1;

    size_t least = search_least(needle);
    if (least == 0)
        return -1; // runs only: see search_matchable

    long last = size - cast(long) least; // last possible start
    if (last < 0)
        return -1;
    if (from > last)
        from = last;

    ctx.total = last + 1; // both halves of the wrap cover each start once
    ctx.done  = 0;
    Pattern pat = search_pattern(needle);
    SearchResult hit;

    if (backward)
    {
        // Before offset 0 (caret at 0 going back): the last match anywhere.
        if (from < 0)
            hit = search_pass(pat, last, size, true, long.min, ctx);
        else
        {
            hit = search_pass(pat, from, min(stop, size), true, long.min, ctx);
            if (hit.pos < 0 && from < last && search_halted(ctx) == false) // wrap, down to from + 1
            {
                hit = search_pass(pat, last, size, true, from + 1, ctx);
                if (hit.pos <= from)
                    hit.pos = -1;
            }
        }
    }
    else
    {
        if (from < 0)
            from = 0;
        hit = search_pass(pat, from, size, false, long.max, ctx);
        if (hit.pos < 0 && from > 0 && search_halted(ctx) == false) // wrap, up to from
        {
            hit = search_pass(pat, 0, size, false, from, ctx);
            if (hit.pos >= from)
                hit.pos = -1;
        }
    }

    if (hit.pos < 0)
        return -1;
    length = cast(size_t) hit.len;
    return hit.pos;
}

/// Pass every match of `needle` to `each`, first to last, without overlaps.
/// `each` returns false to stop.
void search_all(ref const(Needle) needle, long size,
    bool delegate(long at, size_t length) each, ref SearchContext ctx)
{
    if (needle.length == 0 || ctx.editor is null || search_least(needle) == 0)
        return;

    ctx.total = size;
    ctx.done  = 0;
    Pattern pat = search_pattern(needle);
    search_pass(pat, 0, size, false, long.max, ctx, (SearchResult hit) =>
        each(hit.pos, cast(size_t) hit.len) ? SearchAction.next : SearchAction.stop);
}

/// Max element size for a skip (the comparison copy); larger selections need
/// a search.
enum size_t SEARCH_ELEMENT_MAX = 4096;

/// ddhx skip-back/forward: walk from `from` until the `len` bytes differ from
/// those at `from`. `len`: 1 for a caret, else the selection length (max
/// SEARCH_ELEMENT_MAX).
///
/// Only offsets `from ± n * len` are checked, like ddhx, so records are walked
/// whole. Doesn't wrap; stops at the end if nothing differs (like Ctrl+Left on
/// a line of one repeated character).
/// Returns: Offset of the first differing element, the last element that fits,
///          or -1 if nothing to read (empty document, or element too long).
long search_skip(long from, long len, long size, bool backward,
    ref SearchContext ctx)
{
    if (ctx.editor is null || size <= 0 || len < 1 || len > cast(long) SEARCH_ELEMENT_MAX)
        return -1;

    // Caret on the append slot or selection past a delete: use the last element
    // that fits.
    if (from + len > size)
        from = size - len;
    if (from < 0)
        return -1; // document shorter than one element

    size_t n = cast(size_t) len;
    ubyte[] want = ctx.editor.view(from, ctx.element[0 .. n]);
    if (want.length < n)
        return -1;

    ctx.total = backward ? from : size - from - len;
    ctx.done  = 0;
    long start = backward ? from - len : from + len;
    SearchResult hit;
    try hit = ddhx_search(ctx.editor, Pattern.fromBytes(want), start,
        backward ? SEARCH_DIFF | SEARCH_ALIGNED | SEARCH_REVERSE : SEARCH_DIFF | SEARCH_ALIGNED,
        null, size, 1, search_meter(&ctx, start, backward, backward ? long.min : long.max));
    catch (SearchHalt)
        return -1;

    if (hit.pos >= 0)
        return hit.pos;
    // Hit an edge: the last aligned element that fits.
    return backward ? from % len : from + ((size - len - from) / len) * len;
}

/// ddhx diff-next/diff-prev: start of the next run of bytes differing between
/// two documents compared offset for offset, `size` bytes of `ctx.editor`
/// and `peerSize` of `peer`. Bytes past the shorter end differ.
///
/// Only a run's first byte is a stop, so a modified region takes one jump.
/// Backward from inside a run lands on its own start.
/// Returns: Run start after (or before) `from`, or -1 if none.
long search_diff(long from, long size, long peerSize, bool backward,
    IDocumentEditor peer, ref SearchContext ctx)
{
    if (ctx.editor is null || peer is null || from < 0)
        return -1;

    long common = size < peerSize ? size : peerSize;
    long limit  = size < peerSize ? peerSize : size;
    size_t cap = min(ctx.window.length, ctx.peerWindow.length);
    ctx.done = 0;

    if (backward)
    {
        long end = from < limit ? from : limit; // one past the highest candidate
        if (end <= 0)
            return -1;

        // Whether the byte above the one being checked differs, once there is one.
        bool have, next;
        if (end > common) // from common up, every byte differs: one run
        {
            if (common == 0)
                return 0;
            have = next = true;
            end = common;
        }

        ctx.total = end;
        while (end > 0)
        {
            if (search_halted(ctx))
                return -1;
            long take = end > cast(long) cap ? cast(long) cap : end;
            long pos = end - take;
            size_t n = cast(size_t) take;
            ubyte[] mine   = ctx.editor.view(pos, ctx.window[0 .. n]);
            ubyte[] theirs = peer.view(pos, ctx.peerWindow[0 .. n]);
            if (mine.length < n || theirs.length < n)
                return -1; // changed underneath
            search_advance(ctx, take);
            foreach_reverse (size_t i; 0 .. n)
            {
                bool differs = mine[i] != theirs[i];
                if (have && next && differs == false)
                    return pos + cast(long) i + 1;
                next = differs;
                have = true;
            }
            end = pos;
        }
        return next ? 0 : -1;
    }

    // Every byte from common on differs, so no run starts past it.
    if (from >= common)
        return -1;

    bool prev; // whether the byte before the one being checked differs
    long pos = from;
    ctx.total = common - from;
    while (pos < common)
    {
        if (search_halted(ctx))
            return -1;
        long room = common - pos;
        size_t n = room > cast(long) cap ? cap : cast(size_t) room;
        ubyte[] mine   = ctx.editor.view(pos, ctx.window[0 .. n]);
        ubyte[] theirs = peer.view(pos, ctx.peerWindow[0 .. n]);
        if (mine.length < n || theirs.length < n)
            return -1;
        search_advance(ctx, cast(long) n);
        foreach (size_t i; 0 .. n)
        {
            bool differs = mine[i] != theirs[i];
            if (differs && prev == false && pos + cast(long) i > from)
                return pos + cast(long) i;
            prev = differs;
        }
        pos += cast(long) n;
    }
    // The tail only one side has.
    return common < limit && prev == false ? common : -1;
}

private:

/// Whether the walk was canceled.
bool search_halted(ref SearchContext ctx)
{
    return ctx.cancel && atomicLoad(*ctx.cancel);
}

/// Count `bytes` walked and report progress.
void search_advance(ref SearchContext ctx, long bytes)
{
    ctx.done += bytes;
    if (ctx.progress && ctx.total > 0)
        ctx.progress(cast(int)((ctx.done < ctx.total ? ctx.done : ctx.total) * 100 / ctx.total));
}

/// Whether the pattern has something besides wildcards; wildcards alone match
/// everywhere, so they're refused.
bool search_matchable(ref const(Needle) needle)
{
    foreach (ushort element; needle.data[0 .. needle.length])
        if (element < SEARCH_ANY || element >= SEARCH_RANGE)
            return true;
    return false;
}

/// Thrown from a ddhx progress hook to end its search early.
class SearchHalt : Exception
{
    this() { super("search halted"); }
}

/// ddhx pattern copied from `needle`.
Pattern search_pattern(ref const(Needle) needle)
{
    Pattern pat;
    pat.data = needle.data[0 .. needle.length].dup;
    size_t heads; // range heads are numbered in order
    foreach (ushort element; pat.data)
        if (element >= SEARCH_RANGE)
            ++heads;
    pat.ranges = needle.ranges[0 .. heads].dup;
    pat.flags  = needle.flags;
    return pat;
}

/// ddhx search from `start` for matches ending by `end`, given to `onhit`.
/// Ends once every start past `limit` (below it, `backward`) is scanned.
/// Returns: The match, or a not-found result if none or halted.
SearchResult search_pass(Pattern pat, long start, long end, bool backward, long limit,
    ref SearchContext ctx, SearchAction delegate(SearchResult) onhit = null)
{
    try return ddhx_search(ctx.editor, pat, start, backward ? SEARCH_REVERSE : 0,
        onhit, end, 1, search_meter(&ctx, start, backward, limit));
    catch (SearchHalt)
        return SearchResult(SEARCH_RESULT_NOT_FOUND, 0);
}

/// ddhx progress hook for a search from `start`: counts its scanned bytes into
/// `ctx`, throws SearchHalt on cancel or once the scan passes `limit`.
void delegate(long, long) search_meter(SearchContext* ctx, long start, bool backward,
    long limit)
{
    long counted;
    return (long done, long total) {
        // ddhx reports the next start to scan forward, and the bytes from the
        // lowest scanned start to the end backward.
        long at = backward ? total - done : done;
        long scanned = backward ? start - at + 1 : at - start;
        search_advance(*ctx, scanned - counted);
        counted = scanned;
        if (search_halted(*ctx) || (backward ? at <= limit : at >= limit))
            throw new SearchHalt;
    };
}

/// `text` without leading and trailing blanks.
const(char)[] search_strip(const(char)[] text)
{
    size_t start;
    size_t end = text.length;
    while (start < end && (text[start] == ' ' || text[start] == '\t'))
        ++start;
    while (end > start && (text[end - 1] == ' ' || text[end - 1] == '\t'))
        --end;
    return text[start .. end];
}

unittest
{
    static Needle parse(string text, Endian endian = Endian.littleEndian)
    {
        Needle n;
        search_parse(text, n, endian);
        return n;
    }
    static const(ushort)[] elems(ref Needle n) { return n.data[0 .. n.length]; }

    // Text needs an encoding prefix.
    Needle n = parse("utf8:abc");
    assert(elems(n) == [ 'a', 'b', 'c' ]);
    n = parse("utf16:hi");      // little-endian code units
    assert(elems(n) == [ 'h', 0, 'i', 0 ]);
    n = parse("utf32:h");
    assert(elems(n) == [ 'h', 0, 0, 0 ]);
    n = parse(`utf8:"hello world"`); // quoted: space included
    assert(n.length == 11);
    n = parse(`utf8:'hello world'`);
    assert(n.length == 11);
    n = parse(`utf8:"a\nb"`);    // C escape
    assert(elems(n) == [ 'a', '\n', 'b' ]);
    n = parse(`utf8:'a\nb'`);    // literal
    assert(elems(n) == [ 'a', '\\', 'n', 'b' ]);
    n = parse(`utf8:C:\Users`);  // colon and backslashes are text
    assert(n.length == 8);

    // Numbers in each base and width.
    n = parse("0xdeadbeef");
    assert(elems(n) == [ 0xde, 0xad, 0xbe, 0xef ]);
    n = parse("x:de ad");
    assert(elems(n) == [ 0xde, 0xad ]);
    n = parse("x:de beef");   // inherits hex
    assert(elems(n) == [ 0xde, 0xbe, 0xef ]);
    n = parse("0x00de");      // two bytes, not a number
    assert(elems(n) == [ 0x00, 0xde ]);
    n = parse("u8:255");
    assert(elems(n) == [ 0xff ]);
    n = parse("o8:377");
    assert(elems(n) == [ 0xff ]);
    n = parse("u16:255");     // width-sized
    assert(elems(n) == [ 0xff, 0x00 ]);
    n = parse("i16:-1");
    assert(elems(n) == [ 0xff, 0xff ]);
    n = parse("f32:1.0");
    assert(elems(n) == [ 0x00, 0x00, 0x80, 0x3f ]);
    n = parse(`0xde utf8:ab`); // mixed
    assert(elems(n) == [ 0xde, 'a', 'b' ]);

    // Big-endian: scalars swap, bytes and text don't.
    n = parse("u16:255", Endian.bigEndian);
    assert(elems(n) == [ 0x00, 0xff ]);
    n = parse("f32:1.0", Endian.bigEndian);
    assert(elems(n) == [ 0x3f, 0x80, 0x00, 0x00 ]);
    n = parse("x:de ad", Endian.bigEndian);
    assert(elems(n) == [ 0xde, 0xad ]);
    n = parse("utf16:hi", Endian.bigEndian);
    assert(elems(n) == [ 0, 'h', 0, 'i' ]);

    // Wildcards and the glob flag.
    n = parse("0xde ? 0xef");
    assert(elems(n) == [ 0xde, SEARCH_ANY, 0xef ]);
    assert(n.flags & PATTERN_HAS_GLOB);
    assert(search_least(n) == 3);
    n = parse("0xde * 0xef");
    assert(elems(n) == [ 0xde, SEARCH_RUN, 0xef ]);
    assert(search_least(n) == 2); // run may be empty
    n = parse(`utf8:"?"`);        // quoted: the character
    assert(elems(n) == [ '?' ]);

    // Ranges: head plus tails for the width.
    n = parse("u16:1..9 0x00");
    assert(elems(n) == [ SEARCH_RANGE, SEARCH_RANGE_TAIL, 0 ]);
    assert(n.flags & PATTERN_HAS_RANGE);
    assert(n.ranges[0].min == 1 && n.ranges[0].max == 9 && n.ranges[0].width == 2);
    n = parse("u8:0..255"); // matches any byte, still a range
    assert(search_least(n) == 1);

    // Invalid.
    Needle bad;
    assert(search_parse("", bad) == false);
    assert(search_parse("   ", bad) == false);
    assert(search_parse("0x", bad) == false);     // prefix only
    assert(search_parse("0xde a", bad) == false); // half a byte
    assert(search_parse("0xzz", bad) == false);
    assert(search_parse("u8:256", bad) == false); // overflow
    assert(search_parse("o8:8", bad) == false);   // not octal
    assert(search_parse("utf8:'abc", bad) == false); // incomplete
    assert(search_parse("?", bad) == false);      // matches everything
    assert(search_parse("* ?", bad) == false);
    assert(search_parse("u8:9..1", bad) == false); // reversed
    assert(search_parse("u8:1..", bad) == false);  // incomplete

    // No prefix: not a pattern.
    assert(search_parse("hi", bad) == false);
    assert(search_parse("hello world", bad) == false);
    assert(search_parse(`"hello world"`, bad) == false);
    assert(search_parse(`'hello world'`, bad) == false);
    assert(search_parse(`"unclosed`, bad) == false);
    assert(search_parse(`C:\Users`, bad) == false);
    assert(search_parse("deadbeef", bad) == false); // needs 0x
}

unittest
{
    // Every listed prefix parses.
    foreach (ref immutable SearchPrefix p; SEARCH_PREFIXES)
    {
        assert(search_prefixed(p.text), p.text);
        assert(p.what.length, p.text);
    }

    assert(search_prefix_of("utf16:hi").text == "utf16:");
    assert(search_prefix_of("utf16bom:hi").text == "utf16bom:"); // longest wins
    assert(search_prefix_of("0xdead").text == "0x");
    assert(search_prefix_of("utf") is null);   // partial
    assert(search_prefix_of("hello") is null);
    assert(search_prefix_of("") is null);
}

version (unittest)
{
    import ddhx.editor.dummy : DummyDocumentEditor;
    import searches : SEARCH_CHUNKSIZE;

    /// Context over a copy of `data`.
    SearchContext* test_context(const(ubyte)[] data)
    {
        return search_context(new DummyDocumentEditor(data.idup));
    }

    /// Dummy editor counting its reads.
    class CountingEditor : DummyDocumentEditor
    {
        size_t reads;
        this(immutable(ubyte)[] data) { super(data); }
        alias view = DummyDocumentEditor.view;
        override ubyte[] view(long position, ubyte[] buffer)
        {
            ++reads;
            return super.view(position, buffer);
        }
    }
}

unittest
{
    static immutable ubyte[] data = [
        0xde, 0xad, 0xbe, 0xef, 0x00, 0x11, 0xde, 0xad,
        0xbe, 0xef, 0x22, 0x33, 0xde, 0xad, 0x44, 0x55,
    ];
    SearchContext* ctx = test_context(data);

    Needle n;
    size_t len;
    assert(search_parse("0xdeadbeef", n));
    long size = cast(long) data.length;

    assert(search_find(n, 0, size, false, len, *ctx) == 0);
    assert(len == 4);
    assert(search_find(n, 1, size, false, len, *ctx) == 6);
    assert(search_find(n, 7, size, false, len, *ctx) == 0);  // wrapped
    assert(search_find(n, 6, size, true,  len, *ctx) == 6);
    assert(search_find(n, 5, size, true,  len, *ctx) == 0);
    assert(search_find(n, 0, size, true,  len, *ctx) == 0);  // 0 matches
    assert(search_find(n, -1, size, true, len, *ctx) == 6);  // wrapped backward

    // Trailing "de ad" without "be ef": no match.
    assert(search_parse("0xdead", n));
    assert(search_find(n, 7, size, false, len, *ctx) == 12);

    assert(search_parse("0xde ? 0xbe", n));
    assert(search_find(n, 0, size, false, len, *ctx) == 0);
    assert(len == 3);

    // Runs are minimal: from 0, the nearest 0xef (3) gives 4 bytes, not 10.
    assert(search_parse("0xde * 0xef", n));
    assert(search_find(n, 0, size, false, len, *ctx) == 0);
    assert(len == 4);
    // Empty run.
    assert(search_parse("0xde * 0xad", n));
    assert(search_find(n, 0, size, false, len, *ctx) == 0);
    assert(len == 2);
    // Last match, for backward search.
    assert(search_parse("0xbe * 0x33", n));
    assert(search_find(n, size - 1, size, true, len, *ctx) == 8);
    assert(len == 4);

    // Ranges use the prefix's width and byte order.
    assert(search_parse("u8:32..64", n));
    assert(search_find(n, 0, size, false, len, *ctx) == 10);
    assert(len == 1);
    assert(search_parse("i8:-40..-30", n)); // 0xde is -34
    assert(search_find(n, 1, size, false, len, *ctx) == 6);
    assert(search_parse("x:de u8:170..175", n));
    assert(search_find(n, 0, size, false, len, *ctx) == 0);
    assert(len == 2);
    assert(search_parse("u16:57000..57100", n, Endian.bigEndian)); // de ad
    assert(search_find(n, 1, size, false, len, *ctx) == 6);
    assert(len == 2);
    assert(search_parse("u16:57000..57100", n));
    assert(search_find(n, 0, size, false, len, *ctx) == -1);
    assert(search_parse("u8:34..34 * u8:85", n));
    assert(search_find(n, 0, size, false, len, *ctx) == 10);
    assert(len == 6);

    // Absent, and longer than the document.
    assert(search_parse("0xc0ffee", n));
    assert(search_find(n, 0, size, false, len, *ctx) == -1);
    assert(len == 0);
    assert(search_parse("0xde * 0xc0ffee", n));
    assert(search_find(n, 0, size, false, len, *ctx) == -1);
    assert(search_parse(`utf8:'hello world, and then some more text than fits'`, n));
    assert(search_find(n, 0, size, false, len, *ctx) == -1);
}

// Backward end bound: matches before the selection must end by its start.
unittest
{
    Needle n;
    size_t len;
    SearchContext* ctx = test_context(cast(const(ubyte)[]) "AAAAAAAA");
    long size = 8;
    assert(search_parse("utf8:AAA", n));
    // "AAA" selected at 4: 3 overlaps it, 1 is the first that ends by 4.
    assert(search_find(n, 3, size, true, len, *ctx) == 3);
    assert(search_find(n, 3, size, true, len, *ctx, 4) == 1);
    // Nothing ends by 2, so it wraps to the last match.
    assert(search_find(n, 1, size, true, len, *ctx, 2) == 5);

    ctx = test_context(cast(const(ubyte)[]) "AXYBAXB.");
    assert(search_parse("utf8:A * utf8:B", n));
    assert(search_find(n, 3, size, true, len, *ctx, 4) == 0);
    assert(len == 4);
    assert(search_find(n, 3, size, true, len, *ctx, 3) == 4); // wrapped
    assert(len == 3);
    // Leading run: the last start whose match ends by the bound.
    assert(search_parse("* utf8:B", n));
    assert(search_find(n, 5, size, true, len, *ctx, 5) == 3);
    assert(len == 1);
}

unittest
{
    // Three runs with single bytes around them.
    static immutable ubyte[] runs = [
        0x7f, 0x45, 0x4c, 0x46, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x02, 0x02, 0x02, 0xff, 0xff, 0x01,
    ];
    SearchContext* ctx = test_context(runs);
    long size = cast(long) runs.length;

    // Forward: past the run, from anywhere in it.
    assert(search_skip(4, 1, size, false, *ctx) == 10);
    assert(search_skip(9, 1, size, false, *ctx) == 10);
    assert(search_skip(10, 1, size, false, *ctx) == 13);
    assert(search_skip(0, 1, size, false, *ctx) == 1); // single-byte run

    // Backward: last byte before the run.
    assert(search_skip(9, 1, size, true, *ctx) == 3);
    assert(search_skip(4, 1, size, true, *ctx) == 3);
    assert(search_skip(12, 1, size, true, *ctx) == 9);

    // No difference until the end: still moves. Append slot reads as last byte.
    assert(search_skip(0, 1, size, true, *ctx) == 0);
    assert(search_skip(15, 1, size, false, *ctx) == 15);
    assert(search_skip(size, 1, size, true, *ctx) == 14);
    assert(search_skip(0, 1, 0, false, *ctx) == -1); // empty

    // Longer element (selection). Aligned to the start offset: from 4 back, pairs
    // on even offsets, stops at 2.
    assert(search_skip(4, 2, size, false, *ctx) == 10);
    assert(search_skip(4, 2, size, true, *ctx) == 2);
    assert(search_skip(3, 2, size, true, *ctx) == 1);
    assert(search_skip(10, 3, size, false, *ctx) == 13); // 02 02 02, then ff ff 01

    // Element too long for the document, and past the limit.
    assert(search_skip(0, size + 1, size, false, *ctx) == -1);
    assert(search_skip(0, cast(long) SEARCH_ELEMENT_MAX + 1, size, false, *ctx) == -1);
}

unittest
{
    // Match across a window boundary.
    enum size_t SIZE = SEARCH_CHUNKSIZE + 1024;
    enum long AT = SEARCH_CHUNKSIZE - 2; // spans first and second window
    ubyte[] big = new ubyte[SIZE];
    big[AT .. AT + 4] = [ 0xca, 0xfe, 0xba, 0xbe ];
    SearchContext* ctx = test_context(big);

    Needle n;
    size_t len;
    assert(search_parse("0xcafebabe", n));
    assert(search_find(n, 0, SIZE, false, len, *ctx) == AT);
    assert(len == 4);
    assert(search_find(n, SIZE - 1, SIZE, true, len, *ctx) == AT);
}

unittest
{
    // Runs spanning windows, within ddhx's reach.
    enum size_t SIZE = 3 * SEARCH_CHUNKSIZE;
    enum long HEAD = SEARCH_CHUNKSIZE - 100;
    enum long MID  = HEAD + 20_000;
    enum long TAIL = MID + 30_000;
    ubyte[] big = new ubyte[SIZE];
    big[HEAD .. HEAD + 2] = [ 0xca, 0xfe ];
    big[MID  .. MID  + 2] = [ 0xba, 0xbe ];
    big[TAIL .. TAIL + 2] = [ 0xde, 0xad ];
    SearchContext* ctx = test_context(big);

    Needle n;
    size_t len;

    assert(search_parse("0xcafe * 0xbabe", n));
    assert(search_find(n, 0, SIZE, false, len, *ctx) == HEAD);
    assert(len == MID + 2 - HEAD);
    assert(search_find(n, SIZE - 1, SIZE, true, len, *ctx) == HEAD);
    assert(len == MID + 2 - HEAD);

    // Two runs, three stretches.
    assert(search_parse("0xcafe * 0xbabe * 0xdead", n));
    assert(search_find(n, 0, SIZE, false, len, *ctx) == HEAD);
    assert(len == TAIL + 2 - HEAD);

    // Order matters.
    assert(search_parse("0xbabe * 0xcafe", n));
    assert(search_find(n, 0, SIZE, false, len, *ctx) == -1);
    assert(len == 0);

    // Leading run: match starts at the search start.
    assert(search_parse("* 0xbabe", n));
    assert(search_find(n, MID - 1000, SIZE, false, len, *ctx) == MID - 1000);
    assert(len == 1002);
    // Backward: last offset with the rest still ahead.
    assert(search_find(n, SIZE - 1, SIZE, true, len, *ctx) == MID);
    assert(len == 2);

    // Past the reach: two windows apart is too far.
    big[] = 0;
    big[0 .. 2] = [ 0xca, 0xfe ];
    big[SIZE - 2 .. SIZE] = [ 0xba, 0xbe ];
    ctx = test_context(big);
    assert(search_parse("0xcafe * 0xbabe", n));
    assert(search_find(n, 0, SIZE, false, len, *ctx) == -1);
}

unittest
{
    // Many first-stretch candidates, distant tails.
    enum size_t SIZE = 2 * SEARCH_WINDOW;
    enum size_t RUN  = 4096; // 0x22 below this
    ubyte[] many = new ubyte[SIZE];
    many[0 .. RUN] = 0x22;
    many[SIZE - 1] = 0x33;

    // Plus a nearer tail with a candidate past it.
    enum long NEAR = SEARCH_WINDOW + 1000;
    enum long FAR  = NEAR + 2000;
    many[SEARCH_WINDOW] = 0x22;
    many[NEAR] = 0x33;
    many[FAR]  = 0x22;
    SearchContext* ctx = test_context(many);

    Needle n;
    size_t len;
    assert(search_parse("x:22 * x:33", n));

    // Forward: first 0x22 to the first 0x33 after it.
    assert(search_find(n, 0, SIZE, false, len, *ctx) == 0);
    assert(len == NEAR + 1);

    // Backward: the last candidate, past the near tail, has its own.
    assert(search_find(n, SIZE - 1, SIZE, true, len, *ctx) == FAR);
    assert(len == SIZE - FAR);

    // Last candidate in the run shares the near tail.
    assert(search_find(n, SEARCH_WINDOW - 1, SIZE, true, len, *ctx) == RUN - 1);
    assert(len == NEAR + 1 - (RUN - 1));
}

/// Progress reaches 100; cancel stops at the next window, wraps included.
unittest
{
    enum size_t SIZE = 4 * SEARCH_CHUNKSIZE;
    immutable(ubyte)[] data = new immutable(ubyte)[SIZE];

    Needle n;
    search_parse("x:aa bb", n);
    size_t len;

    int[] seen;
    SearchContext* ctx = test_context(data);
    ctx.progress = (int p) { seen ~= p; };
    assert(search_find(n, 0, SIZE, false, len, *ctx) == -1);
    assert(seen.length >= 4 && seen[$ - 1] == 100);
    seen = null;
    assert(search_find(n, SIZE / 2, SIZE, true, len, *ctx) == -1);
    assert(seen.length >= 4 && seen[$ - 1] == 100);

    CountingEditor counting = new CountingEditor(data);
    shared bool stop;
    ctx = search_context(counting);
    ctx.cancel = &stop;
    ctx.progress = (int p) { stop = true; }; // cancel after the first window
    assert(search_find(n, SIZE / 2, SIZE, false, len, *ctx) == -1);
    assert(counting.reads == 1);

    counting.reads = 0;
    stop = false;
    assert(search_skip(0, 1, SIZE, false, *ctx) == -1);
    assert(counting.reads == 2); // element, then one window
}

// The wrap stops where the first half began.
unittest
{
    enum size_t SIZE = 4 * SEARCH_CHUNKSIZE;
    CountingEditor counting = new CountingEditor(new immutable(ubyte)[SIZE]);
    SearchContext* ctx = search_context(counting);

    Needle n;
    search_parse("x:aa bb", n);
    size_t len;
    assert(search_find(n, SIZE / 2, SIZE, false, len, *ctx) == -1);
    assert(counting.reads <= 6, "forward rescanned past the start");
    counting.reads = 0;
    assert(search_find(n, SIZE / 2, SIZE, true, len, *ctx) == -1);
    assert(counting.reads <= 6, "backward rescanned past the start");
}

unittest
{
    static immutable ubyte[] data = [
        0xde, 0xad, 0xbe, 0xef, 0x00, 0x11, 0xde, 0xad,
        0xbe, 0xef, 0x22, 0x33, 0xde, 0xad, 0x44, 0x55,
        0xaa, 0xaa, 0xaa,
    ];

    long size = cast(long) data.length;
    long[2][] all(string text, size_t stop = size_t.max)
    {
        Needle n;
        assert(search_parse(text, n), text);
        long[2][] hits;
        search_all(n, size, (long at, size_t length) {
            hits ~= [ at, cast(long) length ];
            return hits.length < stop;
        }, *test_context(data));
        return hits;
    }

    assert(all("0xdeadbeef") == [ [ 0, 4 ], [ 6, 4 ] ]);
    assert(all("0xdead") == [ [ 0, 2 ], [ 6, 2 ], [ 12, 2 ] ]);
    assert(all("0xdead", 2) == [ [ 0, 2 ], [ 6, 2 ] ]);
    assert(all("0xaaaa") == [ [ 16, 2 ] ]); // no overlaps
    assert(all("0xde ? ? 0xef") == [ [ 0, 4 ], [ 6, 4 ] ]);
    assert(all("0xde * 0xef") == [ [ 0, 4 ], [ 6, 4 ] ]);
    assert(all("* 0xef") == [ [ 0, 4 ], [ 4, 6 ] ]);
    assert(all("0x99").length == 0);
}

unittest
{
    long diff(const(ubyte)[] mine, const(ubyte)[] theirs, long from, bool backward)
    {
        return search_diff(from, mine.length, theirs.length, backward,
            new DummyDocumentEditor(theirs.idup), *test_context(mine));
    }
    import std.string : representation;
    alias B = representation;

    // Runs start at 2 and 6. Inside a run, forward goes to the next one and
    // backward to its own start.
    assert(diff(B("AAAAAAAAAA"), B("AAXXAAXXAA"), 0, false) == 2);
    assert(diff(B("AAAAAAAAAA"), B("AAXXAAXXAA"), 2, false) == 6);
    assert(diff(B("AAAAAAAAAA"), B("AAXXAAXXAA"), 3, false) == 6);
    assert(diff(B("AAAAAAAAAA"), B("AAXXAAXXAA"), 6, false) == -1);
    assert(diff(B("AAAAAAAAAA"), B("AAXXAAXXAA"), 9, true) == 6);
    assert(diff(B("AAAAAAAAAA"), B("AAXXAAXXAA"), 7, true) == 6);
    assert(diff(B("AAAAAAAAAA"), B("AAXXAAXXAA"), 6, true) == 2);
    assert(diff(B("AAAAAAAAAA"), B("AAXXAAXXAA"), 2, true) == -1);

    // A run at zero.
    assert(diff(B("AAAA"), B("XAAA"), 3, true) == 0);
    assert(diff(B("AAAA"), B("XAAA"), 0, false) == -1);

    // Past the shorter end differs, whichever side is shorter. The append slot
    // and beyond go back to the tail's start.
    assert(diff(B("AAAA"), B("AA"), 0, false) == 2);
    assert(diff(B("AA"), B("AAAA"), 0, false) == 2);
    assert(diff(B("AA"), B("AAAA"), 2, false) == -1);
    assert(diff(B("AAAA"), B("AA"), 4, true) == 2);
    assert(diff(B("AA"), B("AAAA"), 2, true) == -1);
    assert(diff(B("AA"), B("AAAA"), 3, true) == 2);
    assert(diff(B("AX"), B("AAAA"), 0, false) == 1, "tail joins the run before it");
    assert(diff(B("AX"), B("AAAA"), 3, true) == 1);
    assert(diff(B(""), B("AA"), 1, true) == 0);

    // Identical: nothing to go to.
    assert(diff(B("hello"), B("hello"), 0, false) == -1);
    assert(diff(B("hello"), B("hello"), 4, true) == -1);
}

unittest
{
    // A run across a window boundary is one run.
    enum size_t SIZE = SEARCH_WINDOW * 2;
    enum size_t RUN = SEARCH_WINDOW - 2;
    ubyte[] theirs = new ubyte[SIZE];
    theirs[RUN .. SEARCH_WINDOW + 2] = 0xff;
    DummyDocumentEditor peer = new DummyDocumentEditor(theirs.idup);
    long diff(long from, bool backward)
    {
        return search_diff(from, SIZE, SIZE, backward, peer,
            *test_context(new ubyte[SIZE]));
    }
    assert(diff(0, false) == RUN);
    assert(diff(RUN, false) == -1);
    assert(diff(SIZE - 1, true) == RUN);
    assert(diff(SEARCH_WINDOW + 1, true) == RUN);
}
