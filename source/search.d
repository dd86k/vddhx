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
/// Scalars are encoded in the byte order the caller passes in - the document's
/// own setting, as ddhx has one for the same job. Byte strings (`x:`, text) have
/// no order to follow and ignore it.
/// Authors: dd86k <dd@dax.moe>
module search;

import std.system : Endian;

import patterns : pattern, Pattern, patternpfx, PatternType,
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

/// Read a pattern out of `text`, `endian` being the order its scalars are
/// encoded in. See the module header for the syntax.
/// Returns: false when the text is not a pattern (yet), leaving `needle` empty.
bool search_parse(const(char)[] text, out Needle needle,
    Endian endian = Endian.littleEndian)
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
    try pat = pattern(endian, args);
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
            return search_range(needle, 0, last, size, true, length, read, user);

        long hit = search_range(needle, 0, from, size, true, length, read, user);
        if (hit < 0 && from < last) // wrap: carry on from the far end
            hit = search_range(needle, from + 1, last, size, true, length, read, user);
        return hit;
    }

    if (from < 0)
        from = 0;
    long hit = search_range(needle, from, last, size, false, length, read, user);
    if (hit < 0 && from > 0)
        hit = search_range(needle, 0, from - 1, size, false, length, read, user);
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

/// Ditto, for what a run reaches over. A second buffer rather than the one above
/// because the two are read at once: the window holds the candidates being tried
/// while this one walks ahead looking for the rest of the pattern.
__gshared ubyte[SEARCH_WINDOW] runWindow;

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

/// One stretch of the needle with no run in it: `length` elements from `at`, each
/// a byte value or SEARCH_ANY, so it stands for exactly that many bytes.
struct Segment
{
    size_t at;
    size_t length;
}

/// A needle split at its runs: the stretches left over, each of a known length, to
/// be found in order with any distance between them.
struct Segments
{
    Segment[SEARCH_MAX / 2 + 1] seg; /// A run between every two, so at most this many.
    size_t count;
    /// The pattern opens with a run, so its first stretch is not pinned to where
    /// the match starts either.
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

/// Whether `seg` stands for the bytes at `have[at .. at + seg.length]`, which the
/// caller has already made room for.
bool search_fits(ref const(Needle) needle, Segment seg, const(ubyte)[] have, size_t at)
{
    foreach (size_t i; 0 .. seg.length)
    {
        ushort element = needle.data[seg.at + i];
        if (element != SEARCH_ANY && have[at + i] != cast(ubyte) element)
            return false;
    }
    return true;
}

/// Lowest offset in [from, hi] the stretch fits at, reading through `buf` a window
/// at a time, each reaching a stretch past its last candidate so no match falls in
/// a seam.
/// Returns: That offset, or -1 when the stretch is nowhere in the range.
long search_seek(ref const(Needle) needle, Segment seg, long from, long hi,
    ubyte[] buf, SearchReadFn read, void* user)
{
    long pos = from < 0 ? 0 : from;
    while (pos <= hi)
    {
        long want = (hi - pos) + cast(long) seg.length;
        if (want > cast(long) buf.length)
            want = cast(long) buf.length;

        ubyte[] have = read(pos, buf[0 .. cast(size_t) want], user);
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

/// Where a chain of stretches landed.
struct Chain
{
    /// Offset the first of them matched at. Nothing else about the chain depends
    /// on where it was asked from, so this is what says when an answer still
    /// stands for another start: see search_range.
    long at;
    /// One past the last byte of the match, or -1 when a stretch was nowhere left
    /// in the document.
    long end;
}

/// Match the stretches from `first` on, each at the lowest offset it fits from
/// where the one before it ended: a run stands for as few bytes as it can, which is
/// the reading ddhx's own '*' has.
///
/// A failure is final for the whole scan and not just for this start: a stretch
/// with nothing left to match would only be looked for further along from any
/// later one.
Chain search_chain(ref const(Needle) needle, ref const(Segments) segs, size_t first,
    long pos, long size, SearchReadFn read, void* user)
{
    Chain chain = { pos, -1 };
    foreach (size_t s; first .. segs.count)
    {
        Segment seg = segs.seg[s];
        long hit = search_seek(needle, seg, pos, size - cast(long) seg.length,
            runWindow, read, user);
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

/// Try every offset in [lo, hi] and answer with the first match, or the last one
/// when `wantLast` is set (which is how a backward search is served: the range
/// is still walked forwards, since a document reads one way).
///
/// The matching is not ddhx's own `matchPattern`: that one is handed a haystack, so
/// a run in the pattern can reach no further than the buffer it was called on. The
/// needle is split at its runs instead and its stretches are looked for one after
/// another, each streaming through the document on its own, so what a run spans is
/// bounded by the document and nothing else.
long search_range(ref const(Needle) needle, long lo, long hi, long size,
    bool wantLast, out size_t length, SearchReadFn read, void* user)
{
    if (lo > hi)
        return -1;

    Segments segs = search_split(needle);
    if (segs.count == 0)
        return -1; // nothing but runs: see search_matchable

    // A pattern opening with a run begins wherever it is tried, the run reaching
    // ahead to whatever follows it, so there is no first stretch to scan for: the
    // only question is whether the rest of the pattern is anywhere ahead. The
    // answer is the same for every start in the range, up to where the rest of it
    // begins, so one attempt settles it.
    if (segs.lead)
    {
        long at = wantLast ? hi : lo;
        Chain chain = search_chain(needle, segs, 0, at, size, read, user);
        if (chain.end >= 0)
        {
            length = cast(size_t)(chain.end - at);
            return at;
        }
        if (wantLast == false)
            return -1;
        // Nothing at hi means nothing past it either, so the last match in the
        // range is where the first stretch itself last begins: the scan below.
    }

    Segment head = segs.seg[0];
    long best = -1;
    size_t bestlen;

    // What the last chain came to, kept for the candidates after it. A candidate
    // that has not passed the stretch that chain opened with meets that same
    // stretch - it is the first one from where the earlier candidate looked, and
    // this one looks from no further back than it - so the rest of the chain is
    // the rest of that one too, and the answer stands as it is. Where it does not,
    // the walk resumes past it, so the stretches are swept once between them all
    // rather than once per candidate.
    Chain chain = { -1, -1 };

    long pos = lo;
    scan: while (pos <= hi)
    {
        // Enough bytes for every candidate left in the range, up to a window. Only
        // the first stretch is looked for here, whatever follows a run being
        // streamed through a window of its own.
        long want = (hi - pos) + cast(long) head.length;
        if (want > cast(long) SEARCH_WINDOW)
            want = SEARCH_WINDOW;

        ubyte[] have = read(pos, window[0 .. cast(size_t) want], user);
        if (have.length < head.length)
            break; // what is left cannot hold a match

        size_t limit = have.length - head.length; // last index one can start at
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
                    chain = search_chain(needle, segs, 1, from, size, read, user);
                    if (chain.end < 0)
                        break scan; // and every later candidate fails the same way
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

        // Step past the candidates just tried, leaving the tail that the next
        // window's first candidates still need.
        pos += cast(long)(limit + 1);
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

    // Big-endian: a scalar is written the other way round, while bytes written
    // out as bytes - and text - stay in the order they were typed.
    n = parse("u16:255", Endian.bigEndian);
    assert(elems(n) == [ 0x00, 0xff ]);
    n = parse("f32:1.0", Endian.bigEndian);
    assert(elems(n) == [ 0x3f, 0x80, 0x00, 0x00 ]);
    n = parse("x:de ad", Endian.bigEndian);
    assert(elems(n) == [ 0xde, 0xad ]);
    n = parse("utf16:hi", Endian.bigEndian);
    assert(elems(n) == [ 0, 'h', 0, 'i' ]);

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

unittest
{
    // A run reaching over more than one window, which is what the stretches are
    // matched one at a time for.
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
    assert(search_find(n, 0, SIZE, false, len, &reader, null) == HEAD);
    assert(len == MID + 2 - HEAD);
    assert(search_find(n, SIZE - 1, SIZE, true, len, &reader, null) == HEAD);
    assert(len == MID + 2 - HEAD);

    // Two runs, so three stretches, each found in a window of its own.
    assert(search_parse("0xcafe * 0xbabe * 0xdead", n));
    assert(search_find(n, 0, SIZE, false, len, &reader, null) == HEAD);
    assert(len == TAIL + 2 - HEAD);

    // The stretch after the run is behind the one before it, not ahead of it.
    assert(search_parse("0xbabe * 0xcafe", n));
    assert(search_find(n, 0, SIZE, false, len, &reader, null) == -1);
    assert(len == 0);

    // A leading run starts the match where the search does and reaches ahead.
    assert(search_parse("* 0xbabe", n));
    assert(search_find(n, 0, SIZE, false, len, &reader, null) == 0);
    assert(len == MID + 2);
    // ...and backward it is the last offset the rest is still ahead of.
    assert(search_find(n, SIZE - 1, SIZE, true, len, &reader, null) == MID);
    assert(len == 2);
}

unittest
{
    // Thousands of candidates for the first stretch and one far-off tail, which is
    // the shape the chain is remembered across: without that, a backward search
    // here walks to the tail once per candidate.
    enum size_t SIZE = 2 * SEARCH_WINDOW;
    enum size_t RUN  = 4096; // 0x22 at every offset below this
    static __gshared ubyte[SIZE] many;
    many[0 .. RUN] = 0x22;
    many[SIZE - 1] = 0x33;

    // ...and a nearer tail, with a candidate past it, so the remembered chain is
    // dropped where it no longer stands rather than answered from.
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

    // Forward: the first 0x22 there is, reaching to the first 0x33 after it.
    assert(search_find(n, 0, SIZE, false, len, &reader, null) == 0);
    assert(len == NEAR + 1);

    // Backward: the last one, which is past the near tail and so has one of its
    // own - the remembered chain does not answer for it.
    reads = 0;
    assert(search_find(n, SIZE - 1, SIZE, true, len, &reader, null) == FAR);
    assert(len == SIZE - FAR);
    // A handful of windows: this document is four of them, and answering the
    // thousands of candidates from the remembered chain is what keeps it to that
    // rather than to a walk each.
    assert(reads < 16);

    // The last candidate inside the run, which shares the near tail with every
    // candidate before it.
    assert(search_find(n, SEARCH_WINDOW - 1, SIZE, true, len, &reader, null) == RUN - 1);
    assert(len == NEAR + 1 - (RUN - 1));
}
