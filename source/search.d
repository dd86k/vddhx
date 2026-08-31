/// Byte-pattern search over a document.
///
/// The document is reached through the same kind of read hook the hex panel uses,
/// so the matching can be tested against a plain array.
///
/// The pattern syntax is ddhx's own, read by ddhx's own parser (`utils.arguments`
/// splits the line, `patterns.pattern` compiles the tokens), so the two cannot
/// drift apart. One concession to a graphical find box: text with no prefix at all
/// is taken literally, spaces and all, so typing `hello world` finds those eleven
/// bytes rather than two tokens with nothing to say what they are.
///
///   hello world     the bytes of the text, exactly as typed
///   "hello world"   the same, the quoting saying where it ends
///   utf8:hello      ditto, said with a prefix
///   utf16:hello     the same text, as UTF-16 code units
///   0xdeadbeef      four bytes, written out in hex
///   x:de ad be ef   the same four; "ad" and the rest inherit the prefix
///   u16:255  i8:-1  a value encoded into the width its prefix names
///   f32:1.0         IEEE-754, the bits a float occupies
///   0xde ? 0xef     '?' stands for one byte, whatever it is
///   0xde * 0xef     '*' for a run of them, however long
///
/// Scalars are encoded little-endian. ddhx follows a setting there; vddhx has
/// none to follow, its inspector listing both orders as readings of their own
/// instead, so write the bytes out with `x:` when the other order is wanted.
/// Authors: dd86k <dd@dax.moe>
module search;

import std.system : Endian;

import patterns : matchPattern, pattern, Pattern, patternpfx, PatternType,
    PATTERN_GLOB_MANY, PATTERN_GLOB_ONE, PATTERN_HAS_GLOB;
import utils : Argument, arguments;

/// One element of a pattern: a byte value, ANY for "one byte, whatever", or RUN
/// for "however many bytes, including none". ddhx's own sentinels, so a compiled
/// pattern drops straight into a needle.
enum ushort SEARCH_ANY = PATTERN_GLOB_ONE;
/// Ditto
enum ushort SEARCH_RUN = PATTERN_GLOB_MANY;

/// Longest pattern taken, in elements. A needle is compared at every offset in
/// the document, so this is a limit on the work one search can be asked to do as
/// much as it is on the pattern itself.
enum size_t SEARCH_MAX = 256;

/// A parsed pattern. Fixed storage, the elements being copied out of what ddhx's
/// parser hands back, so a needle held between searches owns nothing. Reading one
/// does allocate, which is why the find box keeps its result rather than parsing
/// its text every frame (see ui.ui_find_needle).
struct Needle
{
    /// Elements, each a byte value, SEARCH_ANY or SEARCH_RUN.
    ushort[SEARCH_MAX] data;
    /// How many are in use. Not the length of a match, a SEARCH_RUN standing for
    /// as many bytes as it takes: see `search_least`.
    size_t length;
    /// ddhx's pattern flags, PATTERN_HAS_GLOB when a wildcard is among them.
    int flags;
}

/// On-demand byte source, the same shape the hex panel reads through: fill `buf`
/// from document offset `pos` and return what was actually read.
alias SearchReadFn = ubyte[] function(long pos, ubyte[] buf, void* user);

/// Read a pattern out of `text`. See the module header for the syntax.
/// Returns: false when the text is not a pattern (yet), leaving `needle` empty.
bool search_parse(const(char)[] text, out Needle needle)
{
    text = search_strip(text);
    if (text.length == 0)
        return false;

    // ddhx's own splitting, so the quoting is read by the rules that wrote it.
    Argument[] args;
    bool split = true;
    try args = arguments(text);
    catch (Exception)
        split = false; // an unterminated quote, or an escape that is not one

    // Nothing in front to say what the text is means it is text, spaces and all.
    // A line that came to exactly one argument is taken from it, so `"hello
    // world"` loses its quotes; where the split failed, the line as typed is all
    // there is to ask.
    if (split == false)
    {
        // A prefix in front of a quote that has not been closed yet is a pattern
        // mid-keystroke, not text; text with a quote in it has no prefix.
        if (search_prefixed(text))
            return false;
        return search_puttext(needle, text);
    }
    if (args.length == 0)
        return false;
    if (search_prefixed(cast(const(char)[]) args[0].data) == false)
        return search_puttext(needle,
            args.length == 1 ? cast(const(char)[]) args[0].data : text);

    Pattern pat;
    try pat = pattern(Endian.littleEndian, args);
    catch (Exception)
        return false; // not a pattern, or not one yet: it is still being typed

    if (pat.data.length == 0 || pat.data.length > SEARCH_MAX)
        return false;
    needle.data[0 .. pat.data.length] = pat.data;
    needle.length = pat.data.length;
    needle.flags  = pat.flags;
    return search_matchable(needle);
}

/// The fewest bytes a match can come to: every element bar a SEARCH_RUN stands
/// for exactly one byte, and a run may stand for none. Equal to `needle.length`
/// when there is no run in it, which is what makes a match a fixed size.
size_t search_least(ref const(Needle) needle)
{
    size_t least;
    foreach (ushort element; needle.data[0 .. needle.length])
        if (element != SEARCH_RUN)
            ++least;
    return least;
}

/// Find `needle` from `from` - the first offset tried going forward, the last one
/// going `backward` - and, failing that, in the rest of the document, so a search
/// always wraps.
///
/// Every offset is tried, a window at a time, so a large document costs a read of
/// itself; nothing is indexed and nothing is cached between calls.
/// Returns: Offset the match starts at, or -1 when the pattern is nowhere in it,
///          with `length` the bytes it came to (0 when nothing was found).
long search_find(ref const(Needle) needle, long from, long size, bool backward,
    out size_t length, SearchReadFn read, void* user)
{
    if (needle.length == 0 || read is null)
        return -1;

    size_t least = search_least(needle);
    if (least == 0)
        return -1; // nothing but runs: see search_matchable

    long last = size - cast(long) least; // last offset a match can start at
    if (last < 0)
        return -1;
    if (from > last)
        from = last;

    if (backward)
    {
        // Before the document even begins - what the caret at offset zero comes
        // to - there is nothing on this side of the wrap, so the whole document
        // is searched and its last match answered.
        if (from < 0)
            return search_range(needle, 0, last, true, length, read, user);

        long hit = search_range(needle, 0, from, true, length, read, user);
        if (hit < 0 && from < last) // wrap: carry on from the far end
            hit = search_range(needle, from + 1, last, true, length, read, user);
        return hit;
    }

    if (from < 0)
        from = 0;
    long hit = search_range(needle, from, last, false, length, read, user);
    if (hit < 0 && from > 0)
        hit = search_range(needle, 0, from - 1, false, length, read, user);
    return hit;
}

/// Longest element a skip may be asked to walk over, in bytes. A run is compared
/// against a copy of itself, so this is what that copy is allowed to cost;
/// anything selected past it is a search, not a skip.
enum size_t SEARCH_ELEMENT_MAX = 4096;

/// Walk away from `from` until the `len` bytes there differ from the `len` bytes
/// at `from`, which is how ddhx's skip-back / skip-forward cross a run of the same
/// data in one keystroke. `len` is 1 for a bare caret and the selection's length
/// otherwise, up to SEARCH_ELEMENT_MAX.
///
/// Positions are aligned to `from`, again as ddhx aligns them: only offsets
/// `from ± n * len` are looked at, so a run of records is walked a record at a
/// time rather than sliding a window through them byte by byte.
///
/// Unlike a search this never wraps: the intent was to move even when there is
/// nothing different left, the same reading a text editor gives Ctrl+Left on a
/// line of one repeated character.
/// Returns: Offset the first differing element starts at, the last element the end
///          of the document leaves room for, or -1 when there is nothing to read
///          (an empty document, or an element longer than the limit or than what
///          is left of the document).
long search_skip(long from, long len, long size, bool backward,
    SearchReadFn read, void* user)
{
    if (read is null || size <= 0 || len < 1 || len > cast(long) SEARCH_ELEMENT_MAX)
        return -1;

    // The caret may sit on the append slot past the last byte, where there is no
    // data to take a run from, so the last element that fits is used instead.
    // Same for a selection left hanging past a delete.
    if (from + len > size)
        from = size - len;
    if (from < 0)
        return -1; // the document is shorter than one element of it

    size_t n = cast(size_t) len;
    ubyte[] want = read(from, element[0 .. n], user);
    if (want.length < n)
        return -1;

    // Whole elements per window, so a window boundary never splits one.
    long step = cast(long)((SEARCH_WINDOW / n) * n);

    if (backward)
    {
        long end = from; // one past the last byte still to look at
        while (end - len >= 0)
        {
            long room = ((end - from % len) / len) * len; // aligned bytes below it
            long take = room > step ? step : room;
            long pos = end - take;
            ubyte[] have = read(pos, window[0 .. cast(size_t) take], user);
            if (have.length < n)
                break;
            foreach_reverse (size_t b; 0 .. have.length / n)
                if (have[b * n .. (b + 1) * n] != element[0 .. n])
                    return pos + cast(long)(b * n);
            end = pos;
        }
        return from % len; // ran into the start: the lowest element in step with it
    }

    long pos = from + len;
    while (pos + len <= size)
    {
        long room = ((size - pos) / len) * len;
        long take = room > step ? step : room;
        ubyte[] have = read(pos, window[0 .. cast(size_t) take], user);
        if (have.length < n)
            break;
        foreach (size_t b; 0 .. have.length / n)
            if (have[b * n .. (b + 1) * n] != element[0 .. n])
                return pos + cast(long)(b * n);
        pos += cast(long)((have.length / n) * n);
    }
    // Ran into the end: the last element in step with `from` that still fits.
    return from + ((size - len - from) / len) * len;
}

private:

/// Window pulled out of the document at a time. Not on the stack: the search runs
/// on the main thread only, and 64 KiB of frame is more than some of the platforms
/// this builds for care to give.
enum size_t SEARCH_WINDOW = 64 * 1024;
__gshared ubyte[SEARCH_WINDOW] window;

/// The element a skip walks over, copied out of the document once so the windows
/// can be compared against it. Off the stack for the same reason as `window`.
__gshared ubyte[SEARCH_ELEMENT_MAX] element;

/// Whether `text` opens with one of ddhx's pattern prefixes, or is a wildcard of
/// its own - anything else being text the find box takes literally. ddhx answers
/// this, so a prefix it grows (`ascii:`, `re:`) needs nothing here to keep in step.
bool search_prefixed(const(char)[] text)
{
    if (text == "?" || text == "*")
        return true;
    return patternpfx(text).spec.type != PatternType.unknown;
}

/// Take `text` as the needle, byte for byte.
bool search_puttext(ref Needle needle, const(char)[] text)
{
    if (text.length == 0 || text.length > SEARCH_MAX)
        return false;
    foreach (size_t i, char c; text)
        needle.data[i] = cast(ubyte) c;
    needle.length = text.length;
    return true;
}

/// Whether the pattern holds anything to actually match on. Wildcards alone fit at
/// every offset, answering a search with "the next byte", so they are refused.
bool search_matchable(ref const(Needle) needle)
{
    foreach (ushort element; needle.data[0 .. needle.length])
        if (element < SEARCH_ANY)
            return true;
    return false;
}

/// ddhx's view of the needle, for handing to `matchPattern`. That only ever reads
/// its pattern, so the elements are lent out of the needle's own storage.
Pattern search_pattern(ref const(Needle) needle)
{
    Pattern pat;
    pat.data  = cast(ushort[]) needle.data[0 .. needle.length];
    pat.flags = needle.flags;
    return pat;
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

/// Try every offset in [lo, hi] and answer with the first match, or the last one
/// when `wantLast` is set (which is how a backward search is served: the range
/// is still walked forwards, since a document reads one way).
///
/// A pattern holding a SEARCH_RUN is matched inside a single window, so a run
/// reaching further than SEARCH_WINDOW bytes past where its match began is not
/// found. Nothing without a run is bounded that way, the window always reaching
/// past its last candidate by the whole of a fixed-size match.
long search_range(ref const(Needle) needle, long lo, long hi, bool wantLast,
    out size_t length, SearchReadFn read, void* user)
{
    if (lo > hi)
        return -1;

    Pattern pat = search_pattern(needle);
    size_t least = search_least(needle);
    // How far past a candidate the window has to reach: exactly the match for a
    // pattern of a fixed size, as far as a window will go for one with a run.
    size_t span = least == needle.length ? least : SEARCH_WINDOW;

    long best = -1;
    size_t bestlen;
    long pos = lo;
    while (pos <= hi)
    {
        // Enough bytes for every candidate left in the range, up to a window.
        long want = (hi - pos) + cast(long) span;
        if (want > cast(long) SEARCH_WINDOW)
            want = SEARCH_WINDOW;

        ubyte[] have = read(pos, window[0 .. cast(size_t) want], user);
        if (have.length < least)
            break; // what is left cannot hold a match

        size_t limit = have.length - least; // last index in the window one can start at
        foreach (size_t i; 0 .. limit + 1)
        {
            if (pos + cast(long) i > hi)
                break;
            ptrdiff_t got = matchPattern(have, pat, i, 0);
            if (got < 0)
                continue;
            if (wantLast == false)
            {
                length = cast(size_t) got;
                return pos + cast(long) i;
            }
            best = pos + cast(long) i;
            bestlen = cast(size_t) got;
        }

        // Step past the candidates just tried, leaving the tail that the next
        // window's first candidates still need.
        pos += cast(long)(limit + 1);
    }
    length = bestlen;
    return best;
}

unittest
{
    static Needle parse(string text)
    {
        Needle n;
        search_parse(text, n);
        return n;
    }
    static const(ushort)[] elems(ref Needle n) { return n.data[0 .. n.length]; }

    // Plain text, spaces being part of it rather than separators.
    Needle n = parse("hi");
    assert(elems(n) == [ 'h', 'i' ]);
    n = parse("hello world");
    assert(n.length == 11);
    n = parse(`"hello world"`); // one argument, so the quotes come off it
    assert(n.length == 11);
    n = parse("utf8:abc");
    assert(elems(n) == [ 'a', 'b', 'c' ]);
    n = parse("utf16:hi");      // code units, little-endian like any scalar
    assert(elems(n) == [ 'h', 0, 'i', 0 ]);
    n = parse("utf32:h");
    assert(elems(n) == [ 'h', 0, 0, 0 ]);
    n = parse(`C:\Users`);      // a path is text, backslashes and colon and all
    assert(n.length == 8);

    // Numbers, in each base and width ddhx spells out.
    n = parse("0xdeadbeef");
    assert(elems(n) == [ 0xde, 0xad, 0xbe, 0xef ]);
    n = parse("x:de ad");
    assert(elems(n) == [ 0xde, 0xad ]);
    n = parse("x:de beef");   // the bare token inherits hex
    assert(elems(n) == [ 0xde, 0xbe, 0xef ]);
    n = parse("0x00de");      // kept as two bytes, not read as a number
    assert(elems(n) == [ 0x00, 0xde ]);
    n = parse("u8:255");
    assert(elems(n) == [ 0xff ]);
    n = parse("o8:377");
    assert(elems(n) == [ 0xff ]);
    n = parse("u16:255");     // as many bytes as the width asked for
    assert(elems(n) == [ 0xff, 0x00 ]);
    n = parse("i16:-1");
    assert(elems(n) == [ 0xff, 0xff ]);
    n = parse("f32:1.0");
    assert(elems(n) == [ 0x00, 0x00, 0x80, 0x3f ]);
    n = parse(`0xde utf8:ab`); // bases and text in one pattern
    assert(elems(n) == [ 0xde, 'a', 'b' ]);

    // Wildcards, and the flag that says one is in there.
    n = parse("0xde ? 0xef");
    assert(elems(n) == [ 0xde, SEARCH_ANY, 0xef ]);
    assert(n.flags & PATTERN_HAS_GLOB);
    assert(search_least(n) == 3);
    n = parse("0xde * 0xef");
    assert(elems(n) == [ 0xde, SEARCH_RUN, 0xef ]);
    assert(search_least(n) == 2); // a run may stand for no bytes at all
    n = parse(`utf8:"?"`);        // said with a prefix, so it is the character
    assert(elems(n) == [ '?' ]);

    // Not patterns.
    Needle bad;
    assert(search_parse("", bad) == false);
    assert(search_parse("   ", bad) == false);
    assert(search_parse("0x", bad) == false);     // a prefix with nothing behind it
    assert(search_parse("0xde a", bad) == false); // half a byte
    assert(search_parse("0xzz", bad) == false);
    assert(search_parse("u8:256", bad) == false); // over the width
    assert(search_parse("o8:8", bad) == false);   // not an octal digit
    assert(search_parse("utf8:'abc", bad) == false); // still being typed
    assert(search_parse("?", bad) == false);      // matches everything: not a search
    assert(search_parse("* ?", bad) == false);

    // An unterminated quote with no prefix in front is not a half-typed pattern,
    // it is text with a quote in it, and the find box takes it as such.
    assert(search_parse(`"unclosed`, bad));
    assert(bad.length == 9);
}

unittest
{
    // Read through the same hook shape the panel uses, so the search is exercised
    // the way the application drives it.
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

    assert(search_find(n, 0, size, false, len, &reader, null) == 0);
    assert(len == 4);
    assert(search_find(n, 1, size, false, len, &reader, null) == 6);
    assert(search_find(n, 7, size, false, len, &reader, null) == 0);  // wrapped around
    assert(search_find(n, 6, size, true,  len, &reader, null) == 6);
    assert(search_find(n, 5, size, true,  len, &reader, null) == 0);
    assert(search_find(n, 0, size, true,  len, &reader, null) == 0);  // 0 is itself a match
    assert(search_find(n, -1, size, true, len, &reader, null) == 6);  // wrapped the other way

    // The trailing "de ad" has no "be ef" behind it, so it is not a match.
    assert(search_parse("0xdead", n));
    assert(search_find(n, 7, size, false, len, &reader, null) == 12);

    assert(search_parse("0xde ? 0xbe", n));
    assert(search_find(n, 0, size, false, len, &reader, null) == 0);
    assert(len == 3);

    // A run is as short as it can be: from 0 the nearest 0xef is at 3, so the
    // match is those four bytes and not the ten reaching the second one.
    assert(search_parse("0xde * 0xef", n));
    assert(search_find(n, 0, size, false, len, &reader, null) == 0);
    assert(len == 4);
    // ...and a run may stand for nothing at all.
    assert(search_parse("0xde * 0xad", n));
    assert(search_find(n, 0, size, false, len, &reader, null) == 0);
    assert(len == 2);
    // The last one found, which is how a backward search is answered.
    assert(search_parse("0xbe * 0x33", n));
    assert(search_find(n, size - 1, size, true, len, &reader, null) == 8);
    assert(len == 4);

    // Nowhere in the document, and longer than the document.
    assert(search_parse("0xc0ffee", n));
    assert(search_find(n, 0, size, false, len, &reader, null) == -1);
    assert(len == 0);
    assert(search_parse("0xde * 0xc0ffee", n));
    assert(search_find(n, 0, size, false, len, &reader, null) == -1);
    assert(search_parse("hello world, and then some more text than fits", n));
    assert(search_find(n, 0, size, false, len, &reader, null) == -1);
}

unittest
{
    // Three runs, with singles either side of them.
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

    // Forward: off the end of the run the caret sits in, wherever in it it sits.
    assert(search_skip(4, 1, size, false, &reader, null) == 10);
    assert(search_skip(9, 1, size, false, &reader, null) == 10);
    assert(search_skip(10, 1, size, false, &reader, null) == 13);
    assert(search_skip(0, 1, size, false, &reader, null) == 1); // a run of one byte

    // Backward: onto the last byte before the run.
    assert(search_skip(9, 1, size, true, &reader, null) == 3);
    assert(search_skip(4, 1, size, true, &reader, null) == 3);
    assert(search_skip(12, 1, size, true, &reader, null) == 9);

    // Running into either end without finding anything different, which still
    // moves, and the append slot past the last byte, which reads as that byte.
    assert(search_skip(0, 1, size, true, &reader, null) == 0);
    assert(search_skip(15, 1, size, false, &reader, null) == 15);
    assert(search_skip(size, 1, size, true, &reader, null) == 14);
    assert(search_skip(0, 1, 0, false, &reader, null) == -1); // empty document

    // A longer element, the shape a selection gives it. Alignment follows the
    // offset the walk started from, so the walk from 3 reads its pairs on odd
    // offsets and stops at 1 (45 4c against the 46 00 it started on).
    assert(search_skip(4, 2, size, false, &reader, null) == 10);
    assert(search_skip(4, 2, size, true, &reader, null) == 2);
    assert(search_skip(3, 2, size, true, &reader, null) == 1);
    assert(search_skip(10, 3, size, false, &reader, null) == 13); // 02 02 02, then ff ff 01

    // An element the document is too short for, and one past the limit.
    assert(search_skip(0, size + 1, size, false, &reader, null) == -1);
    assert(search_skip(0, cast(long) SEARCH_ELEMENT_MAX + 1, size, false, &reader, null) == -1);
}

unittest
{
    // A match straddling a window seam, which is what search_range's overlap is
    // for.
    enum size_t SIZE = SEARCH_WINDOW + 1024;
    static __gshared ubyte[SIZE] big;
    enum long AT = SEARCH_WINDOW - 2; // starts inside the first window, ends past it
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
    assert(search_find(n, 0, SIZE, false, len, &reader, null) == AT);
    assert(len == 4);
    assert(search_find(n, SIZE - 1, SIZE, true, len, &reader, null) == AT);
}
