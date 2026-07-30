/// Byte-pattern search over a document.
///
/// Two halves: reading a pattern out of what the user typed, and walking a
/// document looking for it. Both are kept clear of the editor and the UI - the
/// document is reached through the same kind of read hook the hex panel uses -
/// so the matching can be tested against a plain array.
///
/// The pattern syntax follows ddhx's own, with one concession to a graphical
/// find box: text with no prefix at all is taken literally, spaces and all, so
/// typing `hello world` finds those eleven bytes rather than being read as two
/// tokens. Anything that opens with a prefix is read as ddhx reads it, a token
/// at a time, each token inheriting the last one's type:
///
///   hello world     the bytes of the text, exactly as typed
///   "hello world"   the same, said explicitly
///   s:hello         ditto, ddhx's prefix
///   0xdeadbeef      four bytes, written out in hex
///   x:de ad be ef   the same four; "ad" and the rest inherit the hex prefix
///   d:255  o:377    one byte each, in decimal and octal
///   0xde ? 0xef     '?' stands for any one byte
///
/// Two places this deliberately parts from ddhx's scanner: hex is read as a
/// string of bytes rather than as a number, so "0x00de" is the two bytes 00 de
/// and not the one byte de a number's leading zeros would collapse to; and
/// decimal and octal tokens are one byte each (0-255), since without a width or
/// an endianness a longer number cannot be turned into bytes unambiguously.
/// Authors: dd
module search;

/// One element of a pattern: a byte value, or ANY for "one byte, whatever".
enum ushort SEARCH_ANY = 0x100;

/// Longest pattern taken, in elements. A needle is compared at every offset in
/// the document, so this is a limit on the work one search can be asked to do as
/// much as it is on the pattern itself.
enum size_t SEARCH_MAX = 256;

/// A parsed pattern. Fixed storage: it is re-read on every frame the find box is
/// open, and a pattern that cannot outgrow the struct cannot allocate either.
struct Needle
{
    /// Elements, each a byte value or SEARCH_ANY.
    ushort[SEARCH_MAX] data;
    /// How many of them are in use.
    size_t length;
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

    // No prefix anywhere in front means the whole thing is literal text, spaces
    // included; that is what someone typing into a find box means by it.
    if (search_prefix(text) == Token.none)
    {
        if (search_put_text(needle, text) == false)
            return false;
        return search_literal(needle);
    }

    Token last = Token.none;
    size_t at;
    while (at < text.length)
    {
        while (at < text.length && text[at] == ' ')
            ++at;
        if (at >= text.length)
            break;

        // A quoted run is one token however many blanks are inside it.
        size_t end = void;
        if (text[at] == '"')
        {
            end = at + 1;
            while (end < text.length && text[end] != '"')
                ++end;
            if (end >= text.length)
                return false; // still being typed: no closing quote yet
            ++end;
        }
        else
        {
            end = at;
            while (end < text.length && text[end] != ' ')
                ++end;
        }

        if (search_token(needle, text[at .. end], last) == false)
            return false;
        at = end;
    }
    return search_literal(needle);
}

/// Find `needle` between `lo` and `hi` (both offsets a match may start at) and,
/// failing that, in the rest of the document, so a search always wraps.
///
/// Every offset in the range is tried, a window at a time, so a large document
/// costs a read of itself; nothing is indexed and nothing is cached between
/// calls. Direction decides which end of the range is answered with, and which
/// side is searched first.
/// Params:
///     needle = What to look for.
///     from = Where to start: the first offset tried going forward, the last
///         one going backward.
///     size = Document size in bytes.
///     backward = Search towards the start of the document instead.
///     read = Byte source.
///     user = Opaque pointer handed to `read`.
/// Returns: Offset the match starts at, or -1 when the pattern is nowhere in it.
long search_find(ref const(Needle) needle, long from, long size, bool backward,
    SearchReadFn read, void* user)
{
    if (needle.length == 0 || read is null)
        return -1;

    long last = size - cast(long) needle.length; // last offset a match can start at
    if (last < 0)
        return -1;
    if (from > last)
        from = last;

    if (backward)
    {
        // Asked to start before the document even begins - which is what the
        // caret at offset zero comes to - there is nothing on this side of the
        // wrap, so the whole document is searched and its last match answered.
        if (from < 0)
            return search_range(needle, 0, last, true, read, user);

        long hit = search_range(needle, 0, from, true, read, user);
        if (hit < 0 && from < last) // wrap: carry on from the far end
            hit = search_range(needle, from + 1, last, true, read, user);
        return hit;
    }

    if (from < 0)
        from = 0;
    long hit = search_range(needle, from, last, false, read, user);
    if (hit < 0 && from > 0)
        hit = search_range(needle, 0, from - 1, false, read, user);
    return hit;
}

/// Longest element a skip may be asked to walk over, in bytes. A run is compared
/// against a copy of itself, so this is what that copy is allowed to cost;
/// anything selected past it is a search, not a skip.
enum size_t SEARCH_ELEMENT_MAX = 4096;

/// Walk away from `from` until the `len` bytes there differ from the `len` bytes
/// at `from`, which is how ddhx's skip-back / skip-forward cross a run of the
/// same data (a field of zeroes, a stretch of padding, a table of identical
/// records) in one keystroke. `len` is 1 for the byte under a bare caret, and the
/// length of the selection when there is one.
///
/// Positions are aligned to `from`, again as ddhx aligns them: only offsets
/// `from ± n * len` are looked at, so a run of records is walked a whole record
/// at a time rather than sliding a window through them a byte at a time.
///
/// Unlike a search this never wraps: a run reaching the end of the document
/// answers with the last element that end leaves room for, since the intent was
/// to move even when there is nothing different left - the same reading a text
/// editor gives Ctrl+Left on a line of one repeated character.
/// Params:
///     from = Offset the element starts at (the low end of a selection).
///     len = Element length in bytes, up to SEARCH_ELEMENT_MAX.
///     size = Document size in bytes.
///     backward = Walk towards the start of the document instead.
///     read = Byte source.
///     user = Opaque pointer handed to `read`.
/// Returns: Offset the first differing element starts at, the last element the
///     end of the document leaves room for, or -1 when there is nothing to read
///     (an empty document, an element longer than the limit or than what is
///     left of the document).
long search_skip(long from, long len, long size, bool backward,
    SearchReadFn read, void* user)
{
    if (read is null || size <= 0 || len < 1 || len > cast(long) SEARCH_ELEMENT_MAX)
        return -1;

    // The caret may sit on the append slot past the last byte, where there is no
    // data to take a run from; the last element that fits is what a run there is
    // made of. Same for a selection left hanging past a delete.
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

/// Window pulled out of the document at a time. Not on the stack: the search
/// runs on the main thread only, and 64 KiB of frame is more than some of the
/// platforms this builds for care to give.
enum size_t SEARCH_WINDOW = 64 * 1024;
__gshared ubyte[SEARCH_WINDOW] window;

/// The element a skip walks over, copied out of the document once so the windows
/// below can be compared against it. Same reasoning as `window` for not being on
/// the stack.
__gshared ubyte[SEARCH_ELEMENT_MAX] element;

/// Which of the pattern syntaxes a token is written in.
enum Token
{
    none,   /// No prefix recognised.
    hex,
    dec,
    oct,
    text,
    any,    /// '?', a single byte of anything.
}

/// The syntax `text` opens with, if any.
Token search_prefix(const(char)[] text)
{
    static bool starts(const(char)[] text, string prefix)
    {
        return text.length >= prefix.length && text[0 .. prefix.length] == prefix;
    }

    if (starts(text, "x:") || starts(text, "0x")) return Token.hex;
    if (starts(text, "d:"))                       return Token.dec;
    if (starts(text, "o:") || starts(text, "0o")) return Token.oct;
    if (starts(text, "s:"))                       return Token.text;
    if (text.length && text[0] == '"')            return Token.text;
    if (text == "?")                              return Token.any;
    return Token.none;
}

/// Read one token onto the end of `needle`, inheriting `last`'s syntax when it
/// carries no prefix of its own. Updates `last` for the token after it.
bool search_token(ref Needle needle, const(char)[] token, ref Token last)
{
    Token kind = search_prefix(token);
    if (kind == Token.none)
    {
        if (last == Token.none || last == Token.any)
            return false; // nothing to inherit: "de ad" alone is not a pattern
        kind = last;
    }
    else if (kind != Token.any)
    {
        // Drop the prefix. The "0x" and "0o" forms keep their digits, the
        // "x:"-style ones are two characters either way, and a quoted run loses
        // the quotes at both ends.
        if (token[0] == '"')
            token = token[1 .. $ - 1];
        else if (token.length >= 2 && token[1] == ':')
            token = token[2 .. $];
        else
            token = token[2 .. $];
    }

    final switch (kind)
    {
    case Token.any:
        last = Token.any;
        return search_put(needle, SEARCH_ANY);
    case Token.text:
        last = Token.text;
        return search_put_text(needle, token);
    case Token.hex:
        last = Token.hex;
        if (token.length == 0 || token.length % 2)
            return false; // whole bytes only; a lone digit is half of one
        for (size_t i; i < token.length; i += 2)
        {
            int hi = search_digit(token[i]);
            int lo = search_digit(token[i + 1]);
            if (hi < 0 || hi > 15 || lo < 0 || lo > 15)
                return false;
            if (search_put(needle, cast(ushort)((hi << 4) | lo)) == false)
                return false;
        }
        return true;
    case Token.dec, Token.oct:
        last = kind;
        int radix = kind == Token.dec ? 10 : 8;
        if (token.length == 0)
            return false;
        int value;
        foreach (char c; token)
        {
            int digit = search_digit(c);
            if (digit < 0 || digit >= radix)
                return false;
            value = value * radix + digit;
            if (value > 255)
                return false; // one byte per token: see the module header
        }
        return search_put(needle, cast(ushort) value);
    case Token.none:
        return false;
    }
}

/// Append the bytes of `text` as they were typed.
bool search_put_text(ref Needle needle, const(char)[] text)
{
    if (text.length == 0)
        return false;
    foreach (char c; text)
        if (search_put(needle, cast(ubyte) c) == false)
            return false;
    return true;
}

/// Whether the pattern holds anything to actually match on. Wildcards alone fit
/// at every offset in the document, which answers a search with "the next byte";
/// that is not what was asked, so it is refused instead.
bool search_literal(ref const(Needle) needle)
{
    foreach (ushort element; needle.data[0 .. needle.length])
        if (element != SEARCH_ANY)
            return true;
    return false;
}

/// Append one element, unless the pattern is already as long as it may be.
bool search_put(ref Needle needle, ushort value)
{
    if (needle.length >= SEARCH_MAX)
        return false;
    needle.data[needle.length++] = value;
    return true;
}

/// A hex digit's value, or -1. Callers below 16 check their own radix.
int search_digit(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/// Trim the blanks off both ends.
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
long search_range(ref const(Needle) needle, long lo, long hi, bool wantLast,
    SearchReadFn read, void* user)
{
    if (lo > hi)
        return -1;

    size_t n = needle.length;
    long best = -1;
    long pos = lo;
    while (pos <= hi)
    {
        // Enough bytes for every candidate left in the range, up to a window.
        long want = (hi - pos) + cast(long) n;
        if (want > cast(long) SEARCH_WINDOW)
            want = SEARCH_WINDOW;

        ubyte[] have = read(pos, window[0 .. cast(size_t) want], user);
        if (have.length < n)
            break; // what is left cannot hold a match

        size_t limit = have.length - n; // last index in the window one can start at
        foreach (size_t i; 0 .. limit + 1)
        {
            if (pos + cast(long) i > hi)
                break;
            if (search_at(needle, have[i .. i + n]) == false)
                continue;
            if (wantLast == false)
                return pos + cast(long) i;
            best = pos + cast(long) i;
        }

        // Step past the candidates just tried, leaving the tail that the next
        // window's first candidates still need.
        pos += cast(long)(limit + 1);
    }
    return best;
}

/// Whether the pattern sits exactly on `bytes`.
bool search_at(ref const(Needle) needle, const(ubyte)[] bytes)
{
    foreach (size_t i, ushort element; needle.data[0 .. needle.length])
    {
        if (element == SEARCH_ANY)
            continue;
        if (bytes[i] != element)
            return false;
    }
    return true;
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

    // Plain text, taken as it stands - spaces are part of it, not separators.
    Needle n = parse("hi");
    assert(elems(n) == [ 'h', 'i' ]);
    n = parse("hello world");
    assert(n.length == 11);
    n = parse(`"hello world"`);
    assert(n.length == 11);
    n = parse("s:abc");
    assert(elems(n) == [ 'a', 'b', 'c' ]);

    // Numbers, in each base ddhx spells out.
    n = parse("0xdeadbeef");
    assert(elems(n) == [ 0xde, 0xad, 0xbe, 0xef ]);
    n = parse("x:de ad");
    assert(elems(n) == [ 0xde, 0xad ]);
    n = parse("x:de beef");   // the bare token inherits hex
    assert(elems(n) == [ 0xde, 0xbe, 0xef ]);
    n = parse("0x00de");      // kept as two bytes, not read as a number
    assert(elems(n) == [ 0x00, 0xde ]);
    n = parse("d:255");
    assert(elems(n) == [ 0xff ]);
    n = parse("o:377");
    assert(elems(n) == [ 0xff ]);
    n = parse("0xde ? 0xef");
    assert(elems(n) == [ 0xde, SEARCH_ANY, 0xef ]);
    n = parse(`0xde "ab"`);   // bases and text in one pattern
    assert(elems(n) == [ 0xde, 'a', 'b' ]);

    // Not patterns.
    Needle bad;
    assert(search_parse("", bad) == false);
    assert(search_parse("   ", bad) == false);
    assert(search_parse("0x", bad) == false);    // a prefix with nothing behind it
    assert(search_parse("0xde a", bad) == false); // half a byte
    assert(search_parse("0xzz", bad) == false);
    assert(search_parse("d:256", bad) == false); // over a byte
    assert(search_parse("o:8", bad) == false);   // not an octal digit
    assert(search_parse(`"unclosed`, bad) == false);
    assert(search_parse("?", bad) == false);     // matches everything: not a search
}

unittest
{
    // A whole document held in one array, read through the same hook shape the
    // panel uses, so the search is exercised the way the application drives it.
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
    assert(search_parse("0xdeadbeef", n));
    long size = cast(long) data.length;

    assert(search_find(n, 0, size, false, &reader, null) == 0);
    assert(search_find(n, 1, size, false, &reader, null) == 6);
    assert(search_find(n, 7, size, false, &reader, null) == 0);  // wrapped around
    assert(search_find(n, 6, size, true,  &reader, null) == 6);
    assert(search_find(n, 5, size, true,  &reader, null) == 0);
    assert(search_find(n, 0, size, true,  &reader, null) == 0);  // 0 is itself a match
    assert(search_find(n, -1, size, true, &reader, null) == 6);  // wrapped the other way

    // The trailing "de ad" has no "be ef" behind it, so it is not a match.
    assert(search_parse("0xdead", n));
    assert(search_find(n, 7, size, false, &reader, null) == 12);

    // Wildcards.
    assert(search_parse("0xde ? 0xbe", n));
    assert(search_find(n, 0, size, false, &reader, null) == 0);

    // Nowhere in the document, and longer than the document.
    assert(search_parse("0xc0ffee", n));
    assert(search_find(n, 0, size, false, &reader, null) == -1);
    assert(search_parse("hello world, and then some more text than fits", n));
    assert(search_find(n, 0, size, false, &reader, null) == -1);
}

unittest
{
    // Skipping runs: a document of three runs, with singles either side of them.
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

    // A longer element, the shape a selection gives it. From 4 the pairs read
    // 00 00, 00 00, 00 00, then 02 02 at 10; backwards from there the pair below
    // is 4c 46 at 2, already different. Alignment follows the offset the walk
    // started from, so the same walk from 3 reads its pairs on odd offsets and
    // stops at 1 (45 4c against the 46 00 it started on).
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
    // Across a window boundary: the document is longer than one read, and the
    // match straddles the seam, which is what the overlap in search_range is for.
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
    assert(search_parse("0xcafebabe", n));
    assert(search_find(n, 0, SIZE, false, &reader, null) == AT);
    assert(search_find(n, SIZE - 1, SIZE, true, &reader, null) == AT);
}
