/// Structure overlay for a document: what the bytes *mean*, as named spans.
///
/// A layout is a parser walking a document and registering spans - a field, a
/// record, a chunk - which the grid draws borders around, the theme colours by
/// role, and the status bar names at the caret. Parsing is incremental: the cache
/// drives a layout forward only as far as the offset asked about, so a screenful
/// of a multi-gigabyte container costs the chunks up to it rather than all of them.
///
/// Spans nest but never straddle: a child sits wholly inside its parent and two
/// siblings never overlap. That is what makes this a sorted array with parent links
/// rather than a tree of nodes, and what lets a lookup be a binary search and a walk
/// up the ancestors. It also means a layout has to register in ascending order; a
/// parser that seeks backwards over ground it already covered is not supported.
///
/// An edit at some offset reparses from the start of the outermost span covering it,
/// so a layout registering one span over the whole document turns every edit into a
/// full reparse. Open containers that are actually containers.
/// Authors: dd86k <dd@dax.moe>
module layout;

import std.system : Endian;

/// What a span, or a lone byte, is. The theme maps every one of these to a colour.
enum LayoutRole
{
    none,

    // Roles useful when no other layouts are loaded: "generic" one might say
    zero,
    printable,
    whitespace,
    control,
    high,

    // Roles useful to declare structured data
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

/// What a lone byte is where no layout claims it: the five buckets the grid has
/// always coloured by, said as roles so the classifier and a parser answer in one
/// vocabulary.
LayoutRole layout_classify(ubyte value)
{
    if (value == 0)
        return LayoutRole.zero;
    if (value >= 0x20 && value < 0x7f)
        return LayoutRole.printable;
    if (value == '\t' || value == '\n' || value == '\r')
        return LayoutRole.whitespace;
    if (value < 0x20)
        return LayoutRole.control;
    return LayoutRole.high;
}

/// What to call a role in the interface, empty for `none`.
///
/// The enum member's own name, so a role added above cannot be one the interface has
/// no word for. They are lowercase like the field names a parser registers, which is
/// what lets the two sit in one trail without reading as different kinds of thing.
string layout_role_name(LayoutRole role)
{
    import std.conv : to;
    return role != LayoutRole.none ? role.to!string() : null;
}

unittest
{
    assert(layout_classify(0x00) == LayoutRole.zero);
    assert(layout_classify('A')  == LayoutRole.printable);
    assert(layout_classify('\n') == LayoutRole.whitespace);
    assert(layout_classify(0x01) == LayoutRole.control);
    assert(layout_classify(0x80) == LayoutRole.high);
    assert(layout_classify(0x7f) == LayoutRole.high); // DEL, the way the grid has it

    assert(layout_role_name(LayoutRole.printable) == "printable");
    assert(layout_role_name(LayoutRole.length) == "length");
    assert(layout_role_name(LayoutRole.none) is null);
}

/// One registered span. `parent` indexes the enclosing span in the same array, -1 at
/// the top level; `depth` is how far down that chain it sits, which the border drawing
/// wants without walking it.
///
/// `shade` alternates along a run of touching fields that share a role - IHDR's three
/// scalars, its four flags - so the theme can draw the odd ones a shade off and the eye
/// can tell where one ends. It says nothing about the field itself.
struct LayoutSpan
{
    long at;
    long length;
    LayoutRole role;
    string name;
    int depth;
    int parent = -1;
    bool shade;
}

/// Byte source a layout parses through. Fill `buf` from `at` and return what was
/// actually read, short at the end of the document.
alias LayoutReadFn = ubyte[] delegate(long at, ubyte[] buf);

/// A document parser. The cache calls `parse` repeatedly, each time asking for the
/// spans up to a further offset, and holds the resume position in the builder between
/// calls; anything else the parser needs to remember is its own business.
interface ILayout
{
    /// Name of the format, for the status bar and the tab.
    string name();

    /// Register spans until they cover `until`, or until the document runs out.
    /// Returns: false when there is nothing left to parse.
    bool parse(ref LayoutBuilder b, long until);

    /// Forget whatever was being remembered between parse calls: an edit has thrown
    /// away the spans from some offset on, and parsing is about to resume there.
    ///
    /// The cursor rewinds on its own, being the cache's, but nothing else does, and a
    /// parser that has noted it reached the end of the format would otherwise go on
    /// saying so. Caches - an interning table, say - can be kept.
    void forget();
}

/// How deep spans may nest. Past this an open() is dropped rather than tracked, on
/// the grounds that nothing legible comes of drawing it.
private enum LAYOUT_MAX_DEPTH = 8;

/// What a layout registers into: a cursor over the document, the reads to drive it,
/// and the spans coming out.
///
/// `at` is the parser's position and the only state carried between parse calls, so a
/// format whose records follow one another needs no state of its own.
struct LayoutBuilder
{
    /// Where the next field lands. field() and open() advance it; a parser jumping to
    /// an offset it read out of a header sets it.
    long at;
    /// Document size, so a parser can stop rather than walk off the end.
    long size;

    /// Read `buf.length` bytes from `from`, short at the end of the document.
    ubyte[] read(long from, ubyte[] buf)
    {
        return readFn ? readFn(from, buf) : null;
    }

    /// The unsigned scalar of `width` bytes sitting at the cursor, without moving it,
    /// for the length or offset a parser has to know before it can register anything.
    /// Returns: 0 when the document ends inside it.
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

    /// Register a leaf of `length` bytes at the cursor and step over it.
    void field(LayoutRole role, string name, long length)
    {
        // Only leaves take part: a container sitting between two fields of one role -
        // the last field of a chunk and the first of the next - must not break the run.
        bool shade = role == lastRole && at == lastEnd && !lastShade;
        emit(role, name, length, shade);

        lastRole = role;
        lastShade = shade;
        lastEnd = at + length;
        at += length;
    }

    /// Open a container at the cursor. A `length` of -1 leaves it to close() to
    /// measure, which is what a record whose end is only known once it has been walked
    /// needs. The cursor does not move: what comes next is the first thing inside.
    ///
    /// It takes no role, unlike field(): a container is a box round its fields and a
    /// name, and the colour inside it belongs to the leaves. Giving every record a
    /// role of its own paints the whole file in one colour, which says nothing.
    void open(string name, long length = -1)
    {
        if (depth >= LAYOUT_MAX_DEPTH)
        {
            ++dropped;
            return;
        }
        // Separately, emit() reading `depth` for the parent link: it has to see the
        // container's own depth, not the one its children will be at.
        size_t index = emit(LayoutRole.none, name, length);
        stack[depth++] = cast(int) index;
    }

    /// Close the innermost container, measuring it from the cursor when open() was
    /// left to work it out.
    void close()
    {
        if (dropped)
        {
            --dropped;
            return;
        }
        if (depth <= 0)
            return;

        LayoutSpan* s = &(*spans)[stack[--depth]];
        if (s.length < 0)
            s.length = at - s.at;
    }

    private:

    LayoutReadFn readFn;
    LayoutSpan[]* spans;
    int[LAYOUT_MAX_DEPTH] stack;
    int depth;
    int dropped; // opens refused past the depth cap, so close() can match them

    // The last leaf registered, for the alternating shade. See LayoutSpan.shade.
    long lastEnd = long.min;
    LayoutRole lastRole;
    bool lastShade;

    size_t emit(LayoutRole role, string name, long length, bool shade = false)
    {
        int parent = depth > 0 ? stack[depth - 1] : -1;
        (*spans) ~= LayoutSpan(at, length, role, name, depth, parent, shade);
        return spans.length > 0 ? spans.length - 1 : 0; // @suppress(dscanner.suspicious.length_subtraction)
    }
}

/// A layout bound to a document, with the spans it has produced so far.
struct LayoutCache
{
    private: // fields only, struct used in ui

    ILayout impl;
    LayoutSpan[] spans;
    LayoutBuilder builder;
    bool exhausted;

    // The last span answered with, so walking a row in order costs a bounds check
    // rather than a search. See layout_index.
    size_t hint;
}

/// Point a cache at a layout and a document, dropping whatever it held.
LayoutCache layout_bind(ILayout impl, LayoutReadFn readFn, long size)
{
    LayoutCache c;
    c.impl = impl;
    if (impl)
        impl.forget(); // the same layout may have been walked over another document
    c.builder.readFn = readFn;
    c.builder.size = size;
    c.builder.spans = &c.spans;
    return c;
}

/// Name of the bound format, empty when there is none.
string layout_name(ref LayoutCache c)
{
    return c.impl ? c.impl.name() : null;
}

/// The innermost span holding `at`, parsing further if the layout has not reached it.
/// Returns: false when nothing covers the offset.
bool layout_at(ref LayoutCache c, long at, out LayoutSpan span)
{
    ptrdiff_t i = layout_index(c, at);
    if (i < 0)
        return false;
    span = c.spans[i];
    return true;
}

/// Ditto, for the span `up` levels out from the innermost one: 0 is the innermost
/// itself, 1 its container. What the border drawing asks to nest one box in another.
bool layout_ancestor(ref LayoutCache c, long at, int up, out LayoutSpan span)
{
    ptrdiff_t i = layout_index(c, at);
    for (; i >= 0 && up > 0; --up)
        i = c.spans[i].parent;
    if (i < 0)
        return false;
    span = c.spans[i];
    return true;
}

/// The span `level` levels in from the outermost one over `at`: 0 the record at the
/// top, 1 whatever of it holds the byte.
///
/// Where layout_ancestor counts outwards from the byte, this counts inwards from the
/// document, which is what a border grouping a whole record wants. A chunk's length
/// field and a byte deep in its payload sit at different depths and would need
/// different answers from layout_ancestor; both are in the same thing at level 0.
/// Returns: false when nothing covers `at`, or when it sits shallower than `level`.
bool layout_level(ref LayoutCache c, long at, int level, out LayoutSpan span)
{
    LayoutSpan inner;
    if (layout_at(c, at, inner) == false)
        return false;

    int up = inner.depth - level;
    return up >= 0 && layout_ancestor(c, at, up, span);
}

/// The role of the byte at `at`, innermost span winning.
/// Returns: LayoutRole.none where no span covers it, leaving it to the classifier.
LayoutRole layout_role(ref LayoutCache c, long at)
{
    LayoutSpan span;
    return layout_at(c, at, span) ? span.role : LayoutRole.none;
}

/// Forget everything covering `from` onwards and arrange to parse it again.
///
/// The outermost span covering the edit decides where parsing resumes, since its own
/// registration was a decision made from bytes that may have just changed. Spans are
/// dropped rather than shifted along the way a bookmark is: a bookmark is what the
/// user said about those bytes and outlives them, a span is what the parser concluded
/// from them and does not.
void layout_invalidate(ref LayoutCache c, long from)
{
    long resume = from;
    foreach (ref const(LayoutSpan) s; c.spans)
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

    // Pick the shade run back up from the leaf still standing at the resume point, so a
    // field keeps the colour it had before the edit rather than flipping under the user.
    c.builder.lastEnd = long.min;
    c.builder.lastRole = LayoutRole.none;
    c.builder.lastShade = false;
    foreach_reverse (ref const(LayoutSpan) s; c.spans)
        if (s.role != LayoutRole.none && s.at + s.length == resume)
        {
            c.builder.lastEnd = resume;
            c.builder.lastRole = s.role;
            c.builder.lastShade = s.shade;
            break;
        }

    c.exhausted = false;
    c.hint = 0;
}

/// Tell the cache the document changed size, an edit having moved everything after it.
void layout_resize(ref LayoutCache c, long size)
{
    c.builder.size = size;
}

/// Where the innermost span holding `at` sits in the array, or -1 when none does.
///
/// Spans are sorted by start and a child always follows its parent, so the last span
/// starting at or before `at` is the innermost candidate; when it ends too early the
/// answer is one of its ancestors, and never a sibling, siblings not overlapping.
private ptrdiff_t layout_index(ref LayoutCache c, long at)
{
    layout_ensure(c, at + 1);

    if (c.spans.length == 0)
        return -1;

    // The sequential walk the grid does: the previous answer still holds unless a span
    // starts inside it, and the array being sorted, only the very next one can.
    if (c.hint < c.spans.length && layout_holds(c.spans[c.hint], at) &&
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
    while (i >= 0 && layout_holds(c.spans[i], at) == false)
        i = c.spans[i].parent;

    if (i >= 0)
        c.hint = i;
    return i;
}

private bool layout_holds(ref const(LayoutSpan) s, long at)
{
    return at >= s.at && at < s.at + s.length;
}

/// Drive the layout forward until its spans reach `until`, or it runs out.
private void layout_ensure(ref LayoutCache c, long until)
{
    if (c.impl is null || c.exhausted || c.builder.at >= until)
        return;

    // Pointed at the cache's own spans here rather than only at bind: a cache sitting
    // in a struct someone copied would otherwise have its builder appending into the
    // array of whichever cache it was bound as.
    c.builder.spans = &c.spans;

    // A parse that registers nothing and does not move the cursor would spin here, so
    // the frontier standing still ends the walk as surely as the parser saying so.
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
    // A container of 8-byte records after a 4-byte magic, each record a 4-byte length
    // and the 4 bytes it counts, which is enough shape to exercise nesting, laziness
    // and the ancestor walk without a real format's edge cases.
    private final class RecordLayout : ILayout
    {
        int calls; // how many times the cache came back for more

        string name() { return "record"; }
        void forget() {}

        bool parse(ref LayoutBuilder b, long until)
        {
            ++calls;

            if (b.at == 0)
                b.field(LayoutRole.magic, "magic", 4);

            while (b.at < until && b.at + 8 <= b.size)
            {
                b.open("record", 8);
                b.field(LayoutRole.length, "length", 4);
                b.field(LayoutRole.data, "payload", 4);
                b.close();
            }
            return b.at + 8 <= b.size;
        }
    }

    private LayoutReadFn zeroReader()
    {
        return delegate(long at, ubyte[] buf) { buf[] = 0; return buf; };
    }
}

unittest
{
    RecordLayout impl = new RecordLayout();
    LayoutCache c = layout_bind(impl, zeroReader(), 4 + 8 * 4);
    assert(layout_name(c) == "record");

    // The magic, then the first record's two fields.
    LayoutSpan s;
    assert(layout_at(c, 0, s));
    assert(s.role == LayoutRole.magic && s.at == 0 && s.length == 4);
    assert(layout_at(c, 3, s) && s.role == LayoutRole.magic);

    assert(layout_at(c, 4, s));
    assert(s.role == LayoutRole.length && s.at == 4 && s.depth == 1);
    assert(layout_at(c, 8, s));
    assert(s.role == LayoutRole.data && s.at == 8);

    // One level out from a field is the record holding it, and one further is nothing.
    assert(layout_ancestor(c, 8, 1, s));
    assert(s.role == LayoutRole.none && s.at == 4 && s.length == 8);
    assert(layout_ancestor(c, 8, 2, s) == false);

    // The magic sits at the top level, so it has no container to step out to.
    assert(layout_ancestor(c, 0, 1, s) == false);

    // Counted from the outside, a field and the record holding it answer alike, which
    // is what one border round a whole record needs.
    assert(layout_level(c, 4, 0, s) && s.name == "record" && s.at == 4);
    assert(layout_level(c, 8, 0, s) && s.name == "record" && s.at == 4);
    assert(layout_level(c, 8, 1, s) && s.name == "payload");
    assert(layout_level(c, 8, 2, s) == false); // nothing that deep here
    assert(layout_level(c, 0, 0, s) && s.role == LayoutRole.magic); // a top-level leaf

    assert(layout_role(c, 12) == LayoutRole.length);
    assert(layout_role(c, 16) == LayoutRole.data);

    // Past the last whole record there is nothing to say.
    assert(layout_at(c, 4 + 8 * 4, s) == false);
}

/// Laziness: nothing is parsed until asked for, and asking again costs nothing.
unittest
{
    RecordLayout impl = new RecordLayout();
    LayoutCache c = layout_bind(impl, zeroReader(), 4 + 8 * 1024);

    assert(impl.calls == 0);
    assert(c.spans.length == 0);

    LayoutSpan s;
    assert(layout_at(c, 4, s));
    int first = impl.calls;
    assert(first > 0);

    // A thousand records past the frontier were never touched.
    assert(c.spans.length < 16);

    // Answering from what is already parsed does not go back to the layout.
    assert(layout_at(c, 5, s));
    assert(impl.calls == first);

    // Reaching further does.
    assert(layout_at(c, 4 + 8 * 512, s));
    assert(impl.calls > first);
    assert(s.role == LayoutRole.length);
}

/// The sequential walk the grid does, which is what the hint is for.
unittest
{
    LayoutCache c = layout_bind(new RecordLayout(), zeroReader(), 4 + 8 * 8);

    foreach (long at; 0 .. 4 + 8 * 8)
    {
        LayoutSpan s;
        assert(layout_at(c, at, s));
        if (at < 4)
            assert(s.role == LayoutRole.magic);
        else
            assert(s.role == ((at - 4) % 8 < 4 ? LayoutRole.length : LayoutRole.data));
    }
}

/// Invalidation resumes from the outermost span over the edit, not from the edit.
unittest
{
    LayoutCache c = layout_bind(new RecordLayout(), zeroReader(), 4 + 8 * 4);

    LayoutSpan s;
    assert(layout_at(c, 4 + 8 * 3, s));
    size_t parsed = c.spans.length;
    assert(parsed > 3);

    // An edit inside the payload of the second record takes that whole record with it,
    // its length field having been read from bytes that may have just changed.
    layout_invalidate(c, 4 + 8 + 5);
    assert(c.spans.length < parsed);
    foreach (ref const(LayoutSpan) sp; c.spans)
        assert(sp.at < 4 + 8);

    // And the same offsets read back the same once it has been parsed again.
    assert(layout_at(c, 4 + 8 + 5, s));
    assert(s.role == LayoutRole.data && s.at == 4 + 8 + 4);
    assert(layout_ancestor(c, 4 + 8 + 5, 1, s));
    assert(s.role == LayoutRole.none && s.at == 4 + 8);

    // An edit past everything parsed drops nothing.
    layout_invalidate(c, long.max);
    assert(c.spans.length > 0);
}

/// Scalars, which is how a parser learns where the next thing is.
unittest
{
    ubyte[] doc = [ 0x01, 0x02, 0x03, 0x04, 0xff ];

    LayoutBuilder b;
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
    assert(b.peek(4) == 0); // runs off the end
    assert(b.peek(0) == 0);
    assert(b.peek(9) == 0);
}

/// The alternating shade over a run of touching fields sharing a role.
unittest
{
    LayoutSpan[] spans;
    LayoutBuilder b;
    b.spans = &spans;

    b.field(LayoutRole.magic, "signature", 8);
    b.open("IHDR");
    b.field(LayoutRole.scalar, "width", 4);
    b.field(LayoutRole.scalar, "height", 4);
    b.field(LayoutRole.scalar, "bit depth", 1);
    b.field(LayoutRole.flags, "colour type", 1);
    b.field(LayoutRole.flags, "compression", 1);
    b.close();

    assert(spans[0].shade == false);          // nothing before it to alternate with
    assert(spans[2].shade == false);          // width
    assert(spans[3].shade);                   // height, the same role touching it
    assert(spans[4].shade == false);          // bit depth, back again
    assert(spans[5].shade == false);          // a new role restarts the run
    assert(spans[6].shade);
    assert(spans[1].shade == false);          // the container takes no part

    // A container between two fields of one role does not break the run, and a gap does.
    spans = null;
    b = LayoutBuilder.init;
    b.spans = &spans;
    b.field(LayoutRole.data, "a", 4);
    b.open("record");
    b.field(LayoutRole.data, "b", 4);
    b.close();
    b.at += 4; // a hole nothing claims
    b.field(LayoutRole.data, "c", 4);

    assert(spans[0].shade == false);
    assert(spans[2].shade);
    assert(spans[3].shade == false);
}

/// A reparse picks the run up where it left off rather than flipping it.
unittest
{
    // Four touching fields of one role, so the shade alternates all the way along.
    static final class RunLayout : ILayout
    {
        string name() { return "run"; }
        void forget() {}
        bool parse(ref LayoutBuilder b, long until)
        {
            while (b.at < until && b.at + 4 <= b.size)
                b.field(LayoutRole.scalar, "n", 4);
            return b.at + 4 <= b.size;
        }
    }

    LayoutCache c = layout_bind(new RunLayout(), zeroReader(), 16);
    LayoutSpan s;
    assert(layout_at(c, 12, s) && s.shade);
    assert(layout_at(c, 4, s) && s.shade);
    assert(layout_at(c, 8, s) && s.shade == false);

    // Editing the third field reparses it and the fourth; both come back as they were.
    layout_invalidate(c, 9);
    assert(layout_at(c, 8, s) && s.shade == false);
    assert(layout_at(c, 12, s) && s.shade);
}

/// Containers measured by close(), and the depth cap.
unittest
{
    LayoutSpan[] spans;
    LayoutBuilder b;
    b.spans = &spans;

    b.open("chunk"); // length unknown until walked
    b.field(LayoutRole.magic, "tag", 4);
    b.field(LayoutRole.data, "body", 12);
    b.close();

    assert(spans.length == 3);
    assert(spans[0] == LayoutSpan(0, 16, LayoutRole.none, "chunk", 0, -1));
    assert(spans[1] == LayoutSpan(0, 4, LayoutRole.magic, "tag", 1, 0));
    assert(spans[2] == LayoutSpan(4, 12, LayoutRole.data, "body", 1, 0));

    // Nesting past the cap is dropped, and the matching close() still balances.
    spans = null;
    b = LayoutBuilder.init;
    b.spans = &spans;
    foreach (i; 0 .. LAYOUT_MAX_DEPTH + 4)
        b.open("deep");
    b.field(LayoutRole.data, "leaf", 1);
    foreach (i; 0 .. LAYOUT_MAX_DEPTH + 4)
        b.close();

    assert(spans.length == LAYOUT_MAX_DEPTH + 1);
    assert(spans[$ - 1].depth == LAYOUT_MAX_DEPTH);
    assert(b.depth == 0);
    assert(b.dropped == 0);
}
