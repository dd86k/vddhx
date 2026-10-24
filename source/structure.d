/// Structure overlay: parsers register named spans (fields, records, chunks)
/// that the grid borders, the theme colours, and the status bar names.
///
/// Parsing is incremental: the cache only drives a parser up to the offset
/// asked for. Spans nest but never straddle, so they're a sorted array with
/// parent links (binary search, walk up for ancestors). Parsers must register
/// in ascending order; seeking backwards is unsupported.
///
/// An edit reparses from the start of the outermost span covering it, so a
/// parser registering one span over the whole document reparses everything on
/// each edit. Only open real containers.
/// Authors: dd86k <dd@dax.moe>
module structure;

import std.system : Endian;

import ddhx.charset : Charset, ASCII;

/// Span or byte role. The theme maps each to a colour.
enum StructureRole
{
    // Unclaimed: containers, or bytes no span covers. Never a classifier answer.
    none,

    // Classifier roles, for bytes no structure claims.
    zero,
    printable,
    whitespace,
    control,
    unmapped,

    // Structure field roles.
    magic,
    length,
    offset,
    count,
    flags,
    scalar,
    text,
    timestamp,
    checksum,
    reserved,
    data,
}

/// Role of a byte no structure claims, one of the classifier buckets.
///
/// Charset-bound: buckets follow the text lane's encoding (EBCDIC 0xC1 is 'A',
/// printable). Colours per role never change by charset.
///
/// `control` and `whitespace` are by mapped code point, not glyph: CP437 draws
/// all of C0, but calling those printable would colour everything the same.
/// `unmapped`: nothing to draw (includes soft hyphen and private use).
StructureRole structure_classify(ubyte value, immutable(Charset)* set = &ASCII)
{
    if (value == 0)
        return StructureRole.zero;
    dchar c = set.decode(value);
    if (c == '\t' || c == '\n' || c == '\r' || c == 0x85) // 0x85: NEL (EBCDIC newline)
        return StructureRole.whitespace;
    if (c < 0x20 || (c >= 0x7f && c < 0xa0))
        return StructureRole.control;
    return set.printable(value) ? StructureRole.printable : StructureRole.unmapped;
}

/// Display name for a role, empty for `none`. The member name, lowercase like
/// field names.
string structure_role_name(StructureRole role)
{
    import std.conv : to;
    return role != StructureRole.none ? role.to!string() : null;
}

unittest
{
    assert(structure_classify(0x00) == StructureRole.zero);
    assert(structure_classify('A')  == StructureRole.printable);
    assert(structure_classify('\n') == StructureRole.whitespace);
    assert(structure_classify(0x01) == StructureRole.control);
    assert(structure_classify(0x80) == StructureRole.unmapped);
    assert(structure_classify(0x7f) == StructureRole.control); // DEL is in the set

    assert(structure_role_name(StructureRole.printable) == "printable");
    assert(structure_role_name(StructureRole.length) == "length");
    assert(structure_role_name(StructureRole.none) is null);
}

/// Buckets follow the encoding.
unittest
{
    import ddhx.charset : charsets, findCharset;

    // EBCDIC: letters in the high half, controls up to 0x40, soft hyphen unmapped.
    immutable(Charset)* ebcdic = findCharset("ebcdic037");
    assert(structure_classify(0xc1, ebcdic) == StructureRole.printable);  // 'A'
    assert(structure_classify(0x40, ebcdic) == StructureRole.printable);  // space
    assert(structure_classify(0x25, ebcdic) == StructureRole.whitespace); // LF
    assert(structure_classify(0x15, ebcdic) == StructureRole.whitespace); // NEL
    assert(structure_classify(0x3f, ebcdic) == StructureRole.control);
    assert(structure_classify(0xff, ebcdic) == StructureRole.control);    // U+009F
    assert(structure_classify(0xca, ebcdic) == StructureRole.unmapped);

    // CP437 covers all 256, nothing unmapped; C0 is still control despite glyphs.
    immutable(Charset)* cp437 = findCharset("cp437");
    assert(structure_classify(0x80, cp437) == StructureRole.printable); // 'Ç'
    assert(structure_classify(0x01, cp437) == StructureRole.control);   // draws '☺'
    foreach (int i; 0 .. 256)
        assert(structure_classify(cast(ubyte) i, cp437) != StructureRole.unmapped);

    immutable(Charset)* mac = findCharset("macroman");
    assert(structure_classify(0xf0, mac) == StructureRole.unmapped); // Apple logo
    assert(structure_classify(0x80, mac) == StructureRole.printable);

    assert(structure_classify(0x85, findCharset("latin1")) == StructureRole.whitespace);
    assert(structure_classify(0x80, findCharset("win1252")) == StructureRole.printable); // '€'
    assert(structure_classify(0x81, findCharset("win1252")) == StructureRole.unmapped);

    // Consistent with the glyph table: printable implies drawable, unmapped
    // implies not. Not the converse (CP437 controls draw).
    foreach (immutable(Charset)* set; charsets)
        foreach (int i; 0 .. 256)
        {
            ubyte value = cast(ubyte) i;
            StructureRole role = structure_classify(value, set);
            assert(role != StructureRole.none); // never none; see StructureRole.none
            if (role == StructureRole.printable)
                assert(set.printable(value));
            else if (role == StructureRole.unmapped)
                assert(set.printable(value) == false);
        }
}

/// A registered span. `parent`: index of the enclosing span, -1 at top level.
/// `depth`: nesting level, cached for border drawing.
///
/// `shade` alternates across adjacent same-role fields (e.g. IHDR's scalars)
/// so the theme can tell them apart.
struct StructureSpan
{
    long at;
    long length;
    StructureRole role;
    string name;
    int depth;
    int parent = -1;
    bool shade;
}

/// Read into `buf` from `at`; returns the bytes read (short at end of document).
alias StructureReadFn = ubyte[] delegate(long at, ubyte[] buf);

/// Document parser. The cache calls `parse` repeatedly with increasing targets;
/// the builder keeps the resume position between calls.
interface IStructure
{
    /// Format name, for the status bar and tab.
    string name();

    /// Register spans until `until` is covered or the document ends.
    /// Returns: false when done.
    bool parse(ref StructureBuilder b, long until);

    /// Reset parser state after an edit; parsing resumes from an earlier offset.
    /// The cursor is reset by the cache. Caches (e.g. interning) may be kept.
    void forget();
}

/// Max nesting depth; deeper open() calls are dropped.
private enum STRUCTURE_MAX_DEPTH = 8;

/// Parser output: a cursor, the reader, and the spans.
/// `at` is the only state kept between parse calls.
struct StructureBuilder
{
    /// Next field position. field()/open() advance it; parsers may seek forward.
    long at;
    long size;

    /// Read `buf.length` bytes from `from`, short at end of document.
    ubyte[] read(long from, ubyte[] buf)
    {
        return readFn ? readFn(from, buf) : null;
    }

    /// Unsigned scalar of `width` bytes at the cursor, without advancing.
    /// Returns: 0 if the document ends inside it.
    ulong peek(size_t width, Endian endian = Endian.littleEndian)
    {
        if (width == 0 || width > 8)
            return 0;

        ubyte[8] buf = void;
        ubyte[] got = read(at, buf[0 .. width]);
        if (got.length < width)
            return 0;

        ulong value;
        if (endian == Endian.littleEndian)
            foreach_reverse (ubyte b; got)
                value = (value << 8) | b;
        else
            foreach (ubyte b; got)
                value = (value << 8) | b;
        return value;
    }

    /// Register a leaf of `length` bytes at the cursor and advance past it.
    void field(StructureRole role, string name, long length)
    {
        // Leaves only, so containers between same-role fields don't break the run.
        bool shade = role == lastRole && at == lastEnd && !lastShade;
        emit(role, name, length, shade);

        lastRole = role;
        lastShade = shade;
        lastEnd = at + length;
        at += length;
    }

    /// Open a container at the cursor; the cursor doesn't move. `length` -1: close()
    /// measures it.
    ///
    /// No role: colour belongs to the leaves. A role per record would colour the
    /// whole file one way.
    void open(string name, long length = -1)
    {
        if (depth >= STRUCTURE_MAX_DEPTH)
        {
            ++dropped;
            return;
        }
        // Emit before incrementing depth: the parent link needs the container's own
        // depth.
        size_t index = emit(StructureRole.none, name, length);
        stack[depth++] = cast(int) index;
    }

    /// Close the innermost container; measures it if open() was given -1.
    void close()
    {
        if (dropped)
        {
            --dropped;
            return;
        }
        if (depth <= 0)
            return;

        StructureSpan* s = &(*spans)[stack[--depth]];
        if (s.length < 0)
            s.length = at - s.at;
    }

    private:

    StructureReadFn readFn;
    StructureSpan[]* spans;
    int[STRUCTURE_MAX_DEPTH] stack;
    int depth;
    int dropped; // opens dropped past the cap, for close() to match

    // Last leaf, for shading.
    long lastEnd = long.min;
    StructureRole lastRole;
    bool lastShade;

    size_t emit(StructureRole role, string name, long length, bool shade = false)
    {
        int parent = depth > 0 ? stack[depth - 1] : -1;
        (*spans) ~= StructureSpan(at, length, role, name, depth, parent, shade);
        return spans.length > 0 ? spans.length - 1 : 0; // @suppress(dscanner.suspicious.length_subtraction)
    }
}

/// A structure bound to a document, with its spans parsed so far.
struct StructureCache
{
    private: // fields only; struct used in ui

    IStructure impl;
    StructureSpan[] spans;
    StructureBuilder builder;
    bool exhausted;

    // Last answer, so in-order walks skip the search. See structure_index.
    size_t hint;
}

/// Bind a structure and document to a cache, clearing it.
StructureCache structure_bind(IStructure impl, StructureReadFn readFn, long size)
{
    StructureCache c;
    c.impl = impl;
    if (impl)
        impl.forget(); // may have parsed another document
    c.builder.readFn = readFn;
    c.builder.size = size;
    c.builder.spans = &c.spans;
    return c;
}

/// Format name, empty if unbound.
string structure_name(ref StructureCache c)
{
    return c.impl ? c.impl.name() : null;
}

/// Innermost span holding `at`, parsing as needed.
/// Returns: false if nothing covers it.
bool structure_at(ref StructureCache c, long at, out StructureSpan span)
{
    ptrdiff_t i = structure_index(c, at);
    if (i < 0)
        return false;
    span = c.spans[i];
    return true;
}

/// Ditto, `up` levels out from the innermost (0: innermost, 1: its container).
bool structure_ancestor(ref StructureCache c, long at, int up, out StructureSpan span)
{
    ptrdiff_t i = structure_index(c, at);
    for (; i >= 0 && up > 0; --up)
        i = c.spans[i].parent;
    if (i < 0)
        return false;
    span = c.spans[i];
    return true;
}

/// Span `level` levels in from the outermost over `at` (0: top-level record).
/// Counts from the top, unlike structure_ancestor, so all bytes of a record
/// agree at level 0 regardless of depth. For record borders.
/// Returns: false if nothing covers `at` or it's shallower than `level`.
bool structure_level(ref StructureCache c, long at, int level, out StructureSpan span)
{
    StructureSpan inner;
    if (structure_at(c, at, inner) == false)
        return false;

    int up = inner.depth - level;
    return up >= 0 && structure_ancestor(c, at, up, span);
}

/// Role at `at`, innermost span wins.
/// Returns: StructureRole.none if uncovered; classify the byte instead.
StructureRole structure_role(ref StructureCache c, long at)
{
    StructureSpan span;
    return structure_at(c, at, span) ? span.role : StructureRole.none;
}

/// All spans, parsing up to `budget` of them. `whole` is false if cut short.
/// Spans are kept, so repeat calls are free.
const(StructureSpan)[] structure_spans(ref StructureCache c, size_t budget, out bool whole)
{
    c.builder.spans = &c.spans; // see structure_ensure

    // Step one byte past the frontier at a time so the budget counts spans.
    while (c.impl && c.exhausted == false && c.spans.length < budget)
    {
        long was = c.builder.at;
        if (c.impl.parse(c.builder, was + 1) == false || c.builder.at <= was)
            c.exhausted = true;
    }

    whole = c.exhausted && c.spans.length <= budget;
    return c.spans.length > budget ? c.spans[0 .. budget] : c.spans;
}

/// Drop spans covering `from` onwards and reparse from the outermost span over
/// it, whose registration may depend on changed bytes. Spans are dropped, not
/// shifted like bookmarks.
void structure_invalidate(ref StructureCache c, long from)
{
    long resume = from;
    foreach (ref const(StructureSpan) s; c.spans)
        if (s.at + s.length > from && s.at < resume)
            resume = s.at;

    size_t keep;
    while (keep < c.spans.length && c.spans[keep].at < resume)
        ++keep;

    c.spans.length = keep;
    c.spans.assumeSafeAppend();
    if (c.impl)
        c.impl.forget();
    c.builder.at = resume;
    c.builder.depth = 0;
    c.builder.dropped = 0;

    // Resume the shade run from the surviving leaf so fields don't flip colour.
    c.builder.lastEnd = long.min;
    c.builder.lastRole = StructureRole.none;
    c.builder.lastShade = false;
    foreach_reverse (ref const(StructureSpan) s; c.spans)
        if (s.role != StructureRole.none && s.at + s.length == resume)
        {
            c.builder.lastEnd = resume;
            c.builder.lastRole = s.role;
            c.builder.lastShade = s.shade;
            break;
        }

    c.exhausted = false;
    c.hint = 0;
}

/// Update the document size after an edit.
void structure_resize(ref StructureCache c, long size)
{
    c.builder.size = size;
}

/// Index of the innermost span holding `at`, or -1.
///
/// Sorted by start, children after parents: the last span starting at or
/// before `at` is the candidate; if it ends too early, the answer is one of its
/// ancestors.
private ptrdiff_t structure_index(ref StructureCache c, long at)
{
    structure_ensure(c, at + 1);

    if (c.spans.length == 0)
        return -1;

    // Sequential walk: the hint still holds unless the next span starts inside.
    if (c.hint < c.spans.length && structure_holds(c.spans[c.hint], at) &&
        (c.hint + 1 >= c.spans.length || c.spans[c.hint + 1].at > at))
        return cast(ptrdiff_t) c.hint;

    size_t low;
    size_t high = c.spans.length;
    while (low < high)
    {
        size_t mid = low + (high - low) / 2;
        if (c.spans[mid].at <= at)
            low = mid + 1;
        else
            high = mid;
    }
    if (low == 0)
        return -1;

    ptrdiff_t i = cast(ptrdiff_t) low - 1;
    while (i >= 0 && structure_holds(c.spans[i], at) == false)
        i = c.spans[i].parent;

    if (i >= 0)
        c.hint = i;
    return i;
}

private bool structure_holds(ref const(StructureSpan) s, long at)
{
    return at >= s.at && at < s.at + s.length;
}

/// Parse until spans reach `until` or the parser is done.
private void structure_ensure(ref StructureCache c, long until)
{
    if (c.impl is null || c.exhausted || c.builder.at >= until)
        return;

    // Re-pointed here, not just at bind: the cache may have been copied.
    c.builder.spans = &c.spans;

    // Stop if the cursor doesn't move, else a no-op parse would spin.
    while (c.builder.at < until)
    {
        long was = c.builder.at;
        if (c.impl.parse(c.builder, until) == false || c.builder.at <= was)
        {
            c.exhausted = true;
            return;
        }
    }
}

version (unittest)
{
    // 4-byte magic, then 8-byte records (4-byte length + 4 bytes). Enough for
    // nesting, laziness and ancestors.
    private final class RecordStructure : IStructure
    {
        int calls; // parse calls

        string name() { return "record"; }
        void forget() {}

        bool parse(ref StructureBuilder b, long until)
        {
            ++calls;

            if (b.at == 0)
                b.field(StructureRole.magic, "magic", 4);

            while (b.at < until && b.at + 8 <= b.size)
            {
                b.open("record", 8);
                b.field(StructureRole.length, "length", 4);
                b.field(StructureRole.data, "payload", 4);
                b.close();
            }
            return b.at + 8 <= b.size;
        }
    }

    private StructureReadFn zeroReader()
    {
        return delegate(long at, ubyte[] buf) { buf[] = 0; return buf; };
    }
}

unittest
{
    RecordStructure impl = new RecordStructure();
    StructureCache c = structure_bind(impl, zeroReader(), 4 + 8 * 4);
    assert(structure_name(c) == "record");

    // Magic, then the first record's fields.
    StructureSpan s;
    assert(structure_at(c, 0, s));
    assert(s.role == StructureRole.magic && s.at == 0 && s.length == 4);
    assert(structure_at(c, 3, s) && s.role == StructureRole.magic);

    assert(structure_at(c, 4, s));
    assert(s.role == StructureRole.length && s.at == 4 && s.depth == 1);
    assert(structure_at(c, 8, s));
    assert(s.role == StructureRole.data && s.at == 8);

    // Field -> record -> nothing.
    assert(structure_ancestor(c, 8, 1, s));
    assert(s.role == StructureRole.none && s.at == 4 && s.length == 8);
    assert(structure_ancestor(c, 8, 2, s) == false);

    // Magic is top-level.
    assert(structure_ancestor(c, 0, 1, s) == false);

    // From the top, a field and its record agree.
    assert(structure_level(c, 4, 0, s) && s.name == "record" && s.at == 4);
    assert(structure_level(c, 8, 0, s) && s.name == "record" && s.at == 4);
    assert(structure_level(c, 8, 1, s) && s.name == "payload");
    assert(structure_level(c, 8, 2, s) == false); // too deep
    assert(structure_level(c, 0, 0, s) && s.role == StructureRole.magic); // top-level leaf

    assert(structure_role(c, 12) == StructureRole.length);
    assert(structure_role(c, 16) == StructureRole.data);

    // Past the last record.
    assert(structure_at(c, 4 + 8 * 4, s) == false);
}

/// Laziness: parse only on demand, no reparse of known spans.
unittest
{
    RecordStructure impl = new RecordStructure();
    StructureCache c = structure_bind(impl, zeroReader(), 4 + 8 * 1024);

    assert(impl.calls == 0);
    assert(c.spans.length == 0);

    StructureSpan s;
    assert(structure_at(c, 4, s));
    int first = impl.calls;
    assert(first > 0);

    // Records past the target weren't parsed.
    assert(c.spans.length < 16);

    // Known spans don't call the parser.
    assert(structure_at(c, 5, s));
    assert(impl.calls == first);

    // Further offsets do.
    assert(structure_at(c, 4 + 8 * 512, s));
    assert(impl.calls > first);
    assert(s.role == StructureRole.length);
}

/// Sequential walk (hint).
unittest
{
    StructureCache c = structure_bind(new RecordStructure(), zeroReader(), 4 + 8 * 8);

    foreach (long at; 0 .. 4 + 8 * 8)
    {
        StructureSpan s;
        assert(structure_at(c, at, s));
        if (at < 4)
            assert(s.role == StructureRole.magic);
        else
            assert(s.role == ((at - 4) % 8 < 4 ? StructureRole.length : StructureRole.data));
    }
}

/// structure_spans and its budget.
unittest
{
    StructureCache c = structure_bind(new RecordStructure(), zeroReader(), 4 + 8 * 4);

    // Budget reached: partial.
    bool whole;
    const(StructureSpan)[] some = structure_spans(c, 4, whole);
    assert(some.length == 4);
    assert(whole == false);
    assert(some[0].name == "magic");
    assert(some[1].name == "record");

    // Magic plus 4 records of 3 spans each.
    const(StructureSpan)[] all = structure_spans(c, 64, whole);
    assert(all.length == 1 + 4 * 3);
    assert(whole);
    assert(all[$ - 1].name == "payload");

    // Registration order: parents first.
    foreach (ref const(StructureSpan) s; all)
        assert(s.parent < 0 || all[s.parent].at <= s.at);

    // Unbound cache.
    StructureCache none;
    assert(structure_spans(none, 16, whole).length == 0);
    assert(whole == false); // not parsed, not empty
}

/// Invalidation resumes from the outermost span over the edit.
unittest
{
    StructureCache c = structure_bind(new RecordStructure(), zeroReader(), 4 + 8 * 4);

    StructureSpan s;
    assert(structure_at(c, 4 + 8 * 3, s));
    size_t parsed = c.spans.length;
    assert(parsed > 3);

    // Edit in the second record's payload drops the whole record.
    structure_invalidate(c, 4 + 8 + 5);
    assert(c.spans.length < parsed);
    foreach (ref const(StructureSpan) sp; c.spans)
        assert(sp.at < 4 + 8);

    // Reparses identically.
    assert(structure_at(c, 4 + 8 + 5, s));
    assert(s.role == StructureRole.data && s.at == 4 + 8 + 4);
    assert(structure_ancestor(c, 4 + 8 + 5, 1, s));
    assert(s.role == StructureRole.none && s.at == 4 + 8);

    // Edit past the parsed range: nothing dropped.
    structure_invalidate(c, long.max);
    assert(c.spans.length > 0);
}

/// peek.
unittest
{
    ubyte[] doc = [ 0x01, 0x02, 0x03, 0x04, 0xff ];

    StructureBuilder b;
    b.size = doc.length;
    b.readFn = delegate(long at, ubyte[] buf)
    {
        if (at >= doc.length)
            return buf[0 .. 0];
        size_t n = doc.length - at;
        if (n > buf.length)
            n = buf.length;
        buf[0 .. n] = doc[at .. at + n];
        return buf[0 .. n];
    };

    assert(b.peek(1) == 0x01);
    assert(b.peek(4, Endian.littleEndian) == 0x04030201);
    assert(b.peek(4, Endian.bigEndian) == 0x01020304);

    b.at = 3;
    assert(b.peek(2, Endian.bigEndian) == 0x04ff);
    assert(b.peek(4) == 0); // past the end
    assert(b.peek(0) == 0);
    assert(b.peek(9) == 0);
}

/// Shading over adjacent same-role fields.
unittest
{
    StructureSpan[] spans;
    StructureBuilder b;
    b.spans = &spans;

    b.field(StructureRole.magic, "signature", 8);
    b.open("IHDR");
    b.field(StructureRole.scalar, "width", 4);
    b.field(StructureRole.scalar, "height", 4);
    b.field(StructureRole.scalar, "bit depth", 1);
    b.field(StructureRole.flags, "colour type", 1);
    b.field(StructureRole.flags, "compression", 1);
    b.close();

    assert(spans[0].shade == false);          // first
    assert(spans[2].shade == false);          // width
    assert(spans[3].shade);                   // height, the same role touching it
    assert(spans[4].shade == false);          // bit depth, back again
    assert(spans[5].shade == false);          // new role restarts
    assert(spans[6].shade);
    assert(spans[1].shade == false);          // container excluded

    // Containers don't break the run; gaps do.
    spans = null;
    b = StructureBuilder.init;
    b.spans = &spans;
    b.field(StructureRole.data, "a", 4);
    b.open("record");
    b.field(StructureRole.data, "b", 4);
    b.close();
    b.at += 4; // gap
    b.field(StructureRole.data, "c", 4);

    assert(spans[0].shade == false);
    assert(spans[2].shade);
    assert(spans[3].shade == false);
}

/// Reparse keeps the shade run.
unittest
{
    // Four adjacent same-role fields.
    static final class RunStructure : IStructure
    {
        string name() { return "run"; }
        void forget() {}
        bool parse(ref StructureBuilder b, long until)
        {
            while (b.at < until && b.at + 4 <= b.size)
                b.field(StructureRole.scalar, "n", 4);
            return b.at + 4 <= b.size;
        }
    }

    StructureCache c = structure_bind(new RunStructure(), zeroReader(), 16);
    StructureSpan s;
    assert(structure_at(c, 12, s) && s.shade);
    assert(structure_at(c, 4, s) && s.shade);
    assert(structure_at(c, 8, s) && s.shade == false);

    // Editing the third field reparses 3 and 4 unchanged.
    structure_invalidate(c, 9);
    assert(structure_at(c, 8, s) && s.shade == false);
    assert(structure_at(c, 12, s) && s.shade);
}

/// close() measuring, and the depth cap.
unittest
{
    StructureSpan[] spans;
    StructureBuilder b;
    b.spans = &spans;

    b.open("chunk"); // length unknown
    b.field(StructureRole.magic, "tag", 4);
    b.field(StructureRole.data, "body", 12);
    b.close();

    assert(spans.length == 3);
    assert(spans[0] == StructureSpan(0, 16, StructureRole.none, "chunk", 0, -1));
    assert(spans[1] == StructureSpan(0, 4, StructureRole.magic, "tag", 1, 0));
    assert(spans[2] == StructureSpan(4, 12, StructureRole.data, "body", 1, 0));

    // Past the cap: dropped, close() still balances.
    spans = null;
    b = StructureBuilder.init;
    b.spans = &spans;
    foreach (i; 0 .. STRUCTURE_MAX_DEPTH + 4)
        b.open("deep");
    b.field(StructureRole.data, "leaf", 1);
    foreach (i; 0 .. STRUCTURE_MAX_DEPTH + 4)
        b.close();

    assert(spans.length == STRUCTURE_MAX_DEPTH + 1);
    assert(spans[$ - 1].depth == STRUCTURE_MAX_DEPTH);
    assert(b.depth == 0);
    assert(b.dropped == 0);
}
