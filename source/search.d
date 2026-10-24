/// Byte-pattern search over a document, through a read hook (testable on an
/// array).
///
/// Syntax and parsing are ddhx's (`utils.arguments`, `patterns.pattern`).
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
/// Authors: dd86k <dd@dax.moe>
module search;

import core.atomic : atomicLoad;
import std.system : Endian;

import patterns : pattern, Pattern, patternpfx, PatternType,
    PatternRange, PATTERN_GLOB_MANY, PATTERN_GLOB_ONE, PATTERN_HAS_GLOB,
    PATTERN_HAS_RANGE, PATTERN_RANGE, PATTERN_RANGE_TAIL;
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

/// Read into `buf` from `pos`, return what was read. Same shape as the hex
/// panel's.
alias SearchReadFn = ubyte[] function(long pos, ubyte[] buf, void* user);

/// Reader and buffers for a walk. Caller-owned so walks can run concurrently.
struct SearchContext
{
    SearchReadFn read;
    void* user;
    /// Checked per window. Results of a cancelled walk are meaningless.
    shared(bool)* cancel;
    /// Called per window with 0-100.
    void delegate(int percent) progress;
    /// Candidate window.
    ubyte[] window;
    /// Read-ahead for runs; used at the same time as `window`.
    ubyte[] runWindow;
    /// Copy of the element being skipped over.
    ubyte[SEARCH_ELEMENT_MAX] element;

    private long total, done;
}

/// Context with default window sizes.
SearchContext* search_context(SearchReadFn read, void* user)
{
    SearchContext* ctx = new SearchContext;
    ctx.read      = read;
    ctx.user      = user;
    ctx.window    = new ubyte[SEARCH_WINDOW];
    ctx.runWindow = new ubyte[SEARCH_WINDOW];
    return ctx;
}

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
/// `backward`), wrapping around. Linear scan by window, no index or cache.
/// Returns: Match offset or -1, with `length` the match length (0 if none).
long search_find(ref const(Needle) needle, long from, long size, bool backward,
    out size_t length, ref SearchContext ctx)
{
    if (needle.length == 0 || ctx.read is null)
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

    if (backward)
    {
        // Before offset 0 (caret at 0 going back): search all, take the last match.
        if (from < 0)
            return search_range(needle, 0, last, size, true, length, ctx);

        long hit = search_range(needle, 0, from, size, true, length, ctx);
        if (hit < 0 && from < last) // wrap
            hit = search_range(needle, from + 1, last, size, true, length, ctx);
        return hit;
    }

    if (from < 0)
        from = 0;
    long hit = search_range(needle, from, last, size, false, length, ctx);
    if (hit < 0 && from > 0)
        hit = search_range(needle, 0, from - 1, size, false, length, ctx);
    return hit;
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
    if (ctx.read is null || size <= 0 || len < 1 || len > cast(long) SEARCH_ELEMENT_MAX)
        return -1;

    // Caret on the append slot or selection past a delete: use the last element
    // that fits.
    if (from + len > size)
        from = size - len;
    if (from < 0)
        return -1; // document shorter than one element

    size_t n = cast(size_t) len;
    ubyte[] want = ctx.read(from, ctx.element[0 .. n], ctx.user);
    if (want.length < n)
        return -1;

    // Whole elements per window so none is split.
    long step = cast(long)((ctx.window.length / n) * n);
    ctx.total = backward ? from : size - from - len;
    ctx.done  = 0;

    if (backward)
    {
        long end = from; // one past the last byte to check
        while (end - len >= 0)
        {
            if (search_halted(ctx))
                return -1;
            long room = ((end - from % len) / len) * len; // aligned bytes below
            long take = room > step ? step : room;
            long pos = end - take;
            ubyte[] have = ctx.read(pos, ctx.window[0 .. cast(size_t) take], ctx.user);
            if (have.length < n)
                break;
            search_advance(ctx, cast(long) have.length);
            foreach_reverse (size_t b; 0 .. have.length / n)
                if (have[b * n .. (b + 1) * n] != ctx.element[0 .. n])
                    return pos + cast(long)(b * n);
            end = pos;
        }
        return from % len; // hit start: lowest aligned element
    }

    long pos = from + len;
    while (pos + len <= size)
    {
        if (search_halted(ctx))
            return -1;
        long room = ((size - pos) / len) * len;
        long take = room > step ? step : room;
        ubyte[] have = ctx.read(pos, ctx.window[0 .. cast(size_t) take], ctx.user);
        if (have.length < n)
            break;
        search_advance(ctx, cast(long) have.length);
        foreach (size_t b; 0 .. have.length / n)
            if (have[b * n .. (b + 1) * n] != ctx.element[0 .. n])
                return pos + cast(long)(b * n);
        pos += cast(long)((have.length / n) * n);
    }
    // Hit end: last aligned element that fits.
    return from + ((size - len - from) / len) * len;
}

private:

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

/// Run-free stretch: `length` elements from `at`, each one byte. Runs never
/// fall inside ranges.
struct Segment
{
    size_t at;
    size_t length;
}

/// Needle split at runs: fixed-length stretches matched in order, any distance
/// apart.
struct Segments
{
    Segment[SEARCH_MAX / 2 + 1] seg; /// Runs between each, so at most this many.
    size_t count;
    /// Pattern starts with a run: the first stretch isn't anchored either.
    bool lead;
}

Segments search_split(ref const(Needle) needle)
{
    Segments segs;
    size_t i;
    while (i < needle.length)
    {
        if (needle.data[i] == SEARCH_RUN)
        {
            if (i == 0)
                segs.lead = true;
            ++i;
            continue;
        }
        size_t start = i;
        while (i < needle.length && needle.data[i] != SEARCH_RUN)
            ++i;
        segs.seg[segs.count++] = Segment(start, i - start);
    }
    return segs;
}

/// Whether `seg` matches `have[at .. at + seg.length]`; caller ensures bounds.
bool search_fits(ref const(Needle) needle, Segment seg, const(ubyte)[] have, size_t at)
{
    size_t i;
    while (i < seg.length)
    {
        ushort element = needle.data[seg.at + i];
        if (element >= SEARCH_RANGE)
        {
            const(PatternRange)* range = &needle.ranges[element - SEARCH_RANGE];
            if (range.contains(have[at + i .. $]) == false)
                return false;
            i += range.width;
            continue;
        }
        if (element != SEARCH_ANY && have[at + i] != cast(ubyte) element)
            return false;
        ++i;
    }
    return true;
}

/// Lowest offset in [from, hi] where the stretch matches, windows overlapping
/// by a stretch so no match is split.
/// Returns: The offset, or -1.
long search_seek(ref const(Needle) needle, Segment seg, long from, long hi,
    ubyte[] buf, ref SearchContext ctx)
{
    long pos = from < 0 ? 0 : from;
    while (pos <= hi)
    {
        if (search_halted(ctx))
            return -1;
        long want = (hi - pos) + cast(long) seg.length;
        if (want > cast(long) buf.length)
            want = cast(long) buf.length;

        ubyte[] have = ctx.read(pos, buf[0 .. cast(size_t) want], ctx.user);
        if (have.length < seg.length)
            return -1;

        size_t limit = have.length - seg.length;
        foreach (size_t i; 0 .. limit + 1)
        {
            if (pos + cast(long) i > hi)
                return -1;
            if (search_fits(needle, seg, have, i))
                return pos + cast(long) i;
        }
        pos += cast(long)(limit + 1);
    }
    return -1;
}

/// Result of matching a chain of stretches.
struct Chain
{
    /// Where the first stretch matched. Used to tell if the result still applies
    /// for another start: see search_range.
    long at;
    /// One past the match end, or -1 if a stretch wasn't found.
    long end;
}

/// Match stretches from `first` on, each at the lowest offset after the
/// previous: runs are as short as possible, like ddhx's '*'.
///
/// A failure fails all later starts too: they'd search from further along.
Chain search_chain(ref const(Needle) needle, ref const(Segments) segs, size_t first,
    long pos, long size, ref SearchContext ctx)
{
    Chain chain = { pos, -1 };
    foreach (size_t s; first .. segs.count)
    {
        Segment seg = segs.seg[s];
        long hit = search_seek(needle, seg, pos, size - cast(long) seg.length,
            ctx.runWindow, ctx);
        if (hit < 0)
            return chain;
        if (s == first)
            chain.at = hit;
        pos = hit + cast(long) seg.length;
    }
    chain.end = pos;
    return chain;
}

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

/// Try every offset in [lo, hi]; return the first match, or the last if
/// `wantLast` (backward search; the walk is still forward).
///
/// Not ddhx's `matchPattern`: it takes a haystack, so runs couldn't reach past
/// the buffer. Stretches are streamed separately, so runs span the document.
long search_range(ref const(Needle) needle, long lo, long hi, long size,
    bool wantLast, out size_t length, ref SearchContext ctx)
{
    if (lo > hi)
        return -1;

    Segments segs = search_split(needle);
    if (segs.count == 0)
        return -1; // runs only: see search_matchable

    // Leading run: matches from any start if the rest is ahead, same answer for
    // all starts up to where the rest begins. One attempt settles it.
    if (segs.lead)
    {
        long at = wantLast ? hi : lo;
        Chain chain = search_chain(needle, segs, 0, at, size, ctx);
        if (chain.end >= 0)
        {
            length = cast(size_t)(chain.end - at);
            return at;
        }
        if (wantLast == false)
            return -1;
        // For the last match: the scan below finds where the first stretch last
        // begins.
    }

    Segment head = segs.seg[0];
    long best = -1;
    size_t bestlen;

    // Last chain result, reused for later candidates. A candidate before the
    // chain's first stretch reaches that same stretch, so the result stands.
    // Otherwise resume past it. Stretches are swept once in total, not per
    // candidate.
    Chain chain = { -1, -1 };

    long pos = lo;
    scan: while (pos <= hi)
    {
        if (search_halted(ctx))
            return -1;
        // Enough for the remaining candidates, up to a window. Only the first stretch
        // is scanned here; stretches after runs use their own window.
        long want = (hi - pos) + cast(long) head.length;
        if (want > cast(long) ctx.window.length)
            want = cast(long) ctx.window.length;

        ubyte[] have = ctx.read(pos, ctx.window[0 .. cast(size_t) want], ctx.user);
        if (have.length < head.length)
            break; // remainder too short

        size_t limit = have.length - head.length; // last start index
        foreach (size_t i; 0 .. limit + 1)
        {
            if (pos + cast(long) i > hi)
                break;
            if (search_fits(needle, head, have, i) == false)
                continue;

            long at   = pos + cast(long) i;
            long from = at + cast(long) head.length;
            long end  = from;
            if (segs.count > 1)
            {
                if (chain.end < 0 || from > chain.at)
                {
                    chain = search_chain(needle, segs, 1, from, size, ctx);
                    if (chain.end < 0)
                        break scan; // all later candidates fail too
                }
                end = chain.end;
            }

            if (wantLast == false)
            {
                length = cast(size_t)(end - at);
                return at;
            }
            best = at;
            bestlen = cast(size_t)(end - at);
        }

        // Advance past tried candidates, keeping the overlap for the next window.
        pos += cast(long)(limit + 1);
        search_advance(ctx, cast(long)(limit + 1));
    }
    length = bestlen;
    return best;
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

unittest
{
    // Same hook shape the panel uses.
    static ubyte[] data = [
        0xde, 0xad, 0xbe, 0xef, 0x00, 0x11, 0xde, 0xad,
        0xbe, 0xef, 0x22, 0x33, 0xde, 0xad, 0x44, 0x55,
    ];
    static ubyte[] reader(long pos, ubyte[] buf, void* user)
    {
        if (pos >= data.length)
            return null;
        size_t n = data.length - cast(size_t) pos;
        if (n > buf.length) n = buf.length;
        buf[0 .. n] = data[cast(size_t) pos .. cast(size_t) pos + n];
        return buf[0 .. n];
    }

    Needle n;
    size_t len;
    assert(search_parse("0xdeadbeef", n));
    long size = cast(long) data.length;

    assert(search_find(n, 0, size, false, len, *search_context(&reader, null)) == 0);
    assert(len == 4);
    assert(search_find(n, 1, size, false, len, *search_context(&reader, null)) == 6);
    assert(search_find(n, 7, size, false, len, *search_context(&reader, null)) == 0);  // wrapped
    assert(search_find(n, 6, size, true,  len, *search_context(&reader, null)) == 6);
    assert(search_find(n, 5, size, true,  len, *search_context(&reader, null)) == 0);
    assert(search_find(n, 0, size, true,  len, *search_context(&reader, null)) == 0);  // 0 matches
    assert(search_find(n, -1, size, true, len, *search_context(&reader, null)) == 6);  // wrapped backward

    // Trailing "de ad" without "be ef": no match.
    assert(search_parse("0xdead", n));
    assert(search_find(n, 7, size, false, len, *search_context(&reader, null)) == 12);

    assert(search_parse("0xde ? 0xbe", n));
    assert(search_find(n, 0, size, false, len, *search_context(&reader, null)) == 0);
    assert(len == 3);

    // Runs are minimal: from 0, the nearest 0xef (3) gives 4 bytes, not 10.
    assert(search_parse("0xde * 0xef", n));
    assert(search_find(n, 0, size, false, len, *search_context(&reader, null)) == 0);
    assert(len == 4);
    // Empty run.
    assert(search_parse("0xde * 0xad", n));
    assert(search_find(n, 0, size, false, len, *search_context(&reader, null)) == 0);
    assert(len == 2);
    // Last match, for backward search.
    assert(search_parse("0xbe * 0x33", n));
    assert(search_find(n, size - 1, size, true, len, *search_context(&reader, null)) == 8);
    assert(len == 4);

    // Ranges use the prefix's width and byte order.
    assert(search_parse("u8:32..64", n));
    assert(search_find(n, 0, size, false, len, *search_context(&reader, null)) == 10);
    assert(len == 1);
    assert(search_parse("i8:-40..-30", n)); // 0xde is -34
    assert(search_find(n, 1, size, false, len, *search_context(&reader, null)) == 6);
    assert(search_parse("x:de u8:170..175", n));
    assert(search_find(n, 0, size, false, len, *search_context(&reader, null)) == 0);
    assert(len == 2);
    assert(search_parse("u16:57000..57100", n, Endian.bigEndian)); // de ad
    assert(search_find(n, 1, size, false, len, *search_context(&reader, null)) == 6);
    assert(len == 2);
    assert(search_parse("u16:57000..57100", n));
    assert(search_find(n, 0, size, false, len, *search_context(&reader, null)) == -1);
    assert(search_parse("u8:34..34 * u8:85", n));
    assert(search_find(n, 0, size, false, len, *search_context(&reader, null)) == 10);
    assert(len == 6);

    // Absent, and longer than the document.
    assert(search_parse("0xc0ffee", n));
    assert(search_find(n, 0, size, false, len, *search_context(&reader, null)) == -1);
    assert(len == 0);
    assert(search_parse("0xde * 0xc0ffee", n));
    assert(search_find(n, 0, size, false, len, *search_context(&reader, null)) == -1);
    assert(search_parse(`utf8:'hello world, and then some more text than fits'`, n));
    assert(search_find(n, 0, size, false, len, *search_context(&reader, null)) == -1);
}

unittest
{
    // Three runs with single bytes around them.
    static ubyte[] runs = [
        0x7f, 0x45, 0x4c, 0x46, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x02, 0x02, 0x02, 0xff, 0xff, 0x01,
    ];
    static ubyte[] reader(long pos, ubyte[] buf, void* user)
    {
        if (pos >= runs.length)
            return null;
        size_t n = runs.length - cast(size_t) pos;
        if (n > buf.length) n = buf.length;
        buf[0 .. n] = runs[cast(size_t) pos .. cast(size_t) pos + n];
        return buf[0 .. n];
    }
    long size = cast(long) runs.length;

    // Forward: past the run, from anywhere in it.
    assert(search_skip(4, 1, size, false, *search_context(&reader, null)) == 10);
    assert(search_skip(9, 1, size, false, *search_context(&reader, null)) == 10);
    assert(search_skip(10, 1, size, false, *search_context(&reader, null)) == 13);
    assert(search_skip(0, 1, size, false, *search_context(&reader, null)) == 1); // single-byte run

    // Backward: last byte before the run.
    assert(search_skip(9, 1, size, true, *search_context(&reader, null)) == 3);
    assert(search_skip(4, 1, size, true, *search_context(&reader, null)) == 3);
    assert(search_skip(12, 1, size, true, *search_context(&reader, null)) == 9);

    // No difference until the end: still moves. Append slot reads as last byte.
    assert(search_skip(0, 1, size, true, *search_context(&reader, null)) == 0);
    assert(search_skip(15, 1, size, false, *search_context(&reader, null)) == 15);
    assert(search_skip(size, 1, size, true, *search_context(&reader, null)) == 14);
    assert(search_skip(0, 1, 0, false, *search_context(&reader, null)) == -1); // empty

    // Longer element (selection). Aligned to the start offset: from 4 back, pairs
    // on even offsets, stops at 2.
    assert(search_skip(4, 2, size, false, *search_context(&reader, null)) == 10);
    assert(search_skip(4, 2, size, true, *search_context(&reader, null)) == 2);
    assert(search_skip(3, 2, size, true, *search_context(&reader, null)) == 1);
    assert(search_skip(10, 3, size, false, *search_context(&reader, null)) == 13); // 02 02 02, then ff ff 01

    // Element too long for the document, and past the limit.
    assert(search_skip(0, size + 1, size, false, *search_context(&reader, null)) == -1);
    assert(search_skip(0, cast(long) SEARCH_ELEMENT_MAX + 1, size, false, *search_context(&reader, null)) == -1);
}

unittest
{
    // Match across a window boundary.
    enum size_t SIZE = SEARCH_WINDOW + 1024;
    static __gshared ubyte[SIZE] big;
    enum long AT = SEARCH_WINDOW - 2; // spans first and second window
    big[AT .. AT + 4] = [ 0xca, 0xfe, 0xba, 0xbe ];

    static ubyte[] reader(long pos, ubyte[] buf, void* user)
    {
        if (pos >= SIZE)
            return null;
        size_t n = SIZE - cast(size_t) pos;
        if (n > buf.length) n = buf.length;
        buf[0 .. n] = big[cast(size_t) pos .. cast(size_t) pos + n];
        return buf[0 .. n];
    }

    Needle n;
    size_t len;
    assert(search_parse("0xcafebabe", n));
    assert(search_find(n, 0, SIZE, false, len, *search_context(&reader, null)) == AT);
    assert(len == 4);
    assert(search_find(n, SIZE - 1, SIZE, true, len, *search_context(&reader, null)) == AT);
}

unittest
{
    // Runs spanning multiple windows.
    enum size_t SIZE = 3 * SEARCH_WINDOW;
    enum long HEAD = 100;                        // first window
    enum long MID  = SEARCH_WINDOW + 5000;       // second
    enum long TAIL = 2 * SEARCH_WINDOW + 9000;   // third
    static __gshared ubyte[SIZE] big;
    big[HEAD .. HEAD + 2] = [ 0xca, 0xfe ];
    big[MID  .. MID  + 2] = [ 0xba, 0xbe ];
    big[TAIL .. TAIL + 2] = [ 0xde, 0xad ];

    static ubyte[] reader(long pos, ubyte[] buf, void* user)
    {
        if (pos >= SIZE)
            return null;
        size_t n = SIZE - cast(size_t) pos;
        if (n > buf.length) n = buf.length;
        buf[0 .. n] = big[cast(size_t) pos .. cast(size_t) pos + n];
        return buf[0 .. n];
    }

    Needle n;
    size_t len;

    assert(search_parse("0xcafe * 0xbabe", n));
    assert(search_find(n, 0, SIZE, false, len, *search_context(&reader, null)) == HEAD);
    assert(len == MID + 2 - HEAD);
    assert(search_find(n, SIZE - 1, SIZE, true, len, *search_context(&reader, null)) == HEAD);
    assert(len == MID + 2 - HEAD);

    // Two runs, three stretches, each in a different window.
    assert(search_parse("0xcafe * 0xbabe * 0xdead", n));
    assert(search_find(n, 0, SIZE, false, len, *search_context(&reader, null)) == HEAD);
    assert(len == TAIL + 2 - HEAD);

    // Order matters.
    assert(search_parse("0xbabe * 0xcafe", n));
    assert(search_find(n, 0, SIZE, false, len, *search_context(&reader, null)) == -1);
    assert(len == 0);

    // Leading run: match starts at the search start.
    assert(search_parse("* 0xbabe", n));
    assert(search_find(n, 0, SIZE, false, len, *search_context(&reader, null)) == 0);
    assert(len == MID + 2);
    // Backward: last offset with the rest still ahead.
    assert(search_find(n, SIZE - 1, SIZE, true, len, *search_context(&reader, null)) == MID);
    assert(len == 2);
}

unittest
{
    // Many first-stretch candidates, one distant tail: the cached chain avoids a
    // walk to the tail per candidate.
    enum size_t SIZE = 2 * SEARCH_WINDOW;
    enum size_t RUN  = 4096; // 0x22 below this
    static __gshared ubyte[SIZE] many;
    many[0 .. RUN] = 0x22;
    many[SIZE - 1] = 0x33;

    // Plus a nearer tail with a candidate past it, so the cached chain must be
    // dropped there.
    enum long NEAR = SEARCH_WINDOW + 1000;
    enum long FAR  = NEAR + 2000;
    many[SEARCH_WINDOW] = 0x22;
    many[NEAR] = 0x33;
    many[FAR]  = 0x22;

    static __gshared size_t reads;
    static ubyte[] reader(long pos, ubyte[] buf, void* user)
    {
        ++reads;
        if (pos >= SIZE)
            return null;
        size_t n = SIZE - cast(size_t) pos;
        if (n > buf.length) n = buf.length;
        buf[0 .. n] = many[cast(size_t) pos .. cast(size_t) pos + n];
        return buf[0 .. n];
    }

    Needle n;
    size_t len;
    assert(search_parse("x:22 * x:33", n));

    // Forward: first 0x22 to the first 0x33 after it.
    assert(search_find(n, 0, SIZE, false, len, *search_context(&reader, null)) == 0);
    assert(len == NEAR + 1);

    // Backward: the last candidate, past the near tail, has its own.
    reads = 0;
    assert(search_find(n, SIZE - 1, SIZE, true, len, *search_context(&reader, null)) == FAR);
    assert(len == SIZE - FAR);
    // Document is 4 windows; without the cache it'd be a walk per candidate.
    assert(reads < 16);

    // Last candidate in the run shares the near tail.
    assert(search_find(n, SEARCH_WINDOW - 1, SIZE, true, len, *search_context(&reader, null)) == RUN - 1);
    assert(len == NEAR + 1 - (RUN - 1));
}

/// Progress reaches 100; cancel stops at the next window.
unittest
{
    enum size_t SIZE = 4 * SEARCH_WINDOW;
    static __gshared ubyte[SIZE] data;
    static ubyte[] reader(long pos, ubyte[] buf, void* user)
    {
        size_t n = cast(size_t)(SIZE - pos < buf.length ? SIZE - pos : buf.length);
        buf[0 .. n] = data[cast(size_t) pos .. cast(size_t) pos + n];
        return buf[0 .. n];
    }

    Needle n;
    search_parse("x:aa bb", n);
    size_t len;

    int[] seen;
    SearchContext* ctx = search_context(&reader, null);
    ctx.progress = (int p) { seen ~= p; };
    assert(search_find(n, 0, SIZE, false, len, *ctx) == -1);
    assert(seen.length >= 4 && seen[$ - 1] == 100);

    static __gshared size_t reads;
    static ubyte[] counting(long pos, ubyte[] buf, void* user)
    {
        ++reads;
        return reader(pos, buf, user);
    }
    shared bool stop;
    ctx = search_context(&counting, null);
    ctx.cancel = &stop;
    ctx.progress = (int p) { stop = true; }; // cancel after the first window
    search_find(n, 0, SIZE, false, len, *ctx);
    assert(reads == 1);

    reads = 0;
    stop = false;
    assert(search_skip(0, 1, SIZE, false, *ctx) == -1);
    assert(reads == 2); // element, then one window
}
