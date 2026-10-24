/// Manages (byte) bookmarks in a document.
///
/// Invariant: sorted by offset, no overlaps, so lookups binary search (called
/// per drawn byte and per minimap cell). Touching bookmarks only stay separate
/// when their names differ.
/// Authors: dd86k <dd@dax.moe>
module bookmarks;

/// Represents a bookmark at a position with length, and optional name.
struct Bookmark
{
    long at;        /// Absolute position
    long length;    /// Length, in bytes
    string name;    /// User label, empty if unnamed.
}

/// Returns true if there's a bookmark at this location. Uses bookmark_find.
bool bookmark_has(const(Bookmark)[] list, long at)
{
    return bookmark_find(list, at) >= 0;
}

/// Get the index, in a list of bookmarks, if there is a bookmark contained at this location.
/// Uses at and length fields for comparison.
ptrdiff_t bookmark_find(const(Bookmark)[] list, long at)
{
    size_t low;
    size_t high = list.length;
    while (low < high)
    {
        size_t mid = low + (high - low) / 2;
        if (at < list[mid].at)
            high = mid;
        else if (at >= list[mid].at + list[mid].length)
            low = mid + 1;
        else
            return cast(ptrdiff_t) mid;
    }
    return -1;
}

/// Returns true if all of at..at+length is bookmarked, across touching bookmarks.
bool bookmark_covers(const(Bookmark)[] list, long at, long length)
{
    ptrdiff_t index = bookmark_find(list, at);
    if (index < 0)
        return false;

    long end  = at + length;
    long tail = list[index].at + list[index].length;
    for (size_t i = index + 1; tail < end && i < list.length && list[i].at == tail; ++i)
        tail = list[i].at + list[i].length;
    return tail >= end;
}

/// Returns true if any byte in at..at+length is bookmarked. For minimap cells.
bool bookmark_hits(const(Bookmark)[] list, long at, long length)
{
    if (length < 1)
        return false;

    // Only the first bookmark ending past `at` can match.
    size_t low;
    size_t high = list.length;
    while (low < high)
    {
        size_t mid = low + (high - low) / 2;
        if (list[mid].at + list[mid].length <= at)
            low = mid + 1;
        else
            high = mid;
    }
    return low < list.length && list[low].at < at + length;
}

/// Toggle a bookmark over at..at+length: removed if fully bookmarked, else added.
/// Returns: true if the range ends up bookmarked.
bool bookmark_toggle(ref Bookmark[] list, long at, long length)
{
    if (length < 1)
        length = 1;

    if (bookmark_covers(list, at, length))
    {
        bookmark_clear(list, at, length);
        return false;
    }
    bookmark_add(list, at, length, null);
    return true;
}

/// Add sorted, non-overlapping `runs` in one pass, merged like single adds.
void bookmark_add_all(ref Bookmark[] list, const(Bookmark)[] runs)
{
    Bookmark[] all = new Bookmark[list.length + runs.length];
    size_t i, j, n;
    while (i < list.length || j < runs.length)
    {
        if (j == runs.length || (i < list.length && list[i].at <= runs[j].at))
            all[n++] = list[i++];
        else
            all[n++] = runs[j++];
    }
    bookmark_merge(all);
    list = all;
}

/// Set the name of the bookmark containing `at`; empty removes it.
/// Returns: false if no bookmark contains `at`.
bool bookmark_rename(ref Bookmark[] list, long at, string name)
{
    ptrdiff_t index = bookmark_find(list, at);
    if (index < 0)
        return false;

    list[index].name = name;
    bookmark_merge(list);
    return true;
}

/// Index of the next (dir > 0) or previous bookmark from `from`, wrapping.
/// Returns: -1 if empty.
ptrdiff_t bookmark_step(const(Bookmark)[] list, long from, int dir)
{
    if (list.length == 0)
        return -1;

    if (dir >= 0)
    {
        foreach (size_t i, ref const(Bookmark) b; list)
            if (b.at > from)
                return cast(ptrdiff_t) i;
        return 0; // wrap to first
    }

    foreach_reverse (size_t i, ref const(Bookmark) b; list)
        if (b.at < from)
            return cast(ptrdiff_t) i;
    return cast(ptrdiff_t) list.length - 1;
}

/// Move bookmarks after `shift` bytes are inserted (>0) or removed (<0) at `at`.
/// Bookmarks fully removed are dropped.
void bookmark_shift(ref Bookmark[] list, long at, long shift)
{
    if (shift == 0 || list.length == 0)
        return;

    Bookmark[] kept;
    kept.reserve(list.length);
    foreach (ref const(Bookmark) b; list)
    {
        long head = b.at;
        long tail = b.at + b.length;

        if (shift > 0)
        {
            // Insert at bookmark start: shift it. At its end: outside. Inside: grow.
            if (head >= at)
                head += shift;
            if (tail > at)
                tail += shift;
        }
        else
        {
            // Ends past the removed span move back; ends inside collapse to `at`.
            long end = at - shift;
            if (head > at)
                head = head >= end ? head + shift : at;
            if (tail > at)
                tail = tail >= end ? tail + shift : at;
        }

        if (tail > head)
            kept ~= Bookmark(head, tail - head, b.name);
    }
    list = kept;
    bookmark_merge(list); // removal can make bookmarks touch
}

/// Bookmarks as ddhx's bookmark-save writes them, one "0xADDR\tLENGTH" per line.
/// A name goes in a third field, which ddhx ignores on load.
string bookmark_format(const(Bookmark)[] list)
{
    import std.array : appender, Appender;
    import std.format : formattedWrite;
    import std.string : tr;

    Appender!string text = appender!string;
    text.put("# ddhx bookmarks\n");
    foreach (ref const(Bookmark) b; list)
    {
        text.formattedWrite("0x%x\t%d", b.at, b.length);
        if (b.name.length)
            text.formattedWrite("\t%s", tr(b.name, "\r\n", "  "));
        text.put('\n');
    }
    return text.data;
}

/// Parse bookmark_format text, sorted and merged into `list`. Blank lines and
/// '#' comments are skipped. Returns null, or the error with its line in `line`.
string bookmark_parse(const(char)[] text, out Bookmark[] list, out size_t line)
{
    import std.algorithm.mutation : SwapStrategy;
    import std.algorithm.sorting : sort;
    import std.conv : ConvException, parse;
    import std.string : indexOfAny, lineSplitter, strip, stripLeft;
    import address : address_number;

    foreach (const(char)[] raw; lineSplitter(text))
    {
        ++line;
        const(char)[] rest = strip(raw);
        if (rest.length == 0 || rest[0] == '#')
            continue;

        ptrdiff_t space = indexOfAny(rest, " \t");
        if (space <= 0)
            return "expected '<address> <length>'";

        Bookmark b;
        if (address_number(rest[0 .. space], b.at) == false)
            return "invalid address";
        rest = stripLeft(rest[space .. $]);
        try b.length = parse!long(rest);
        catch (ConvException)
            return "invalid length";
        if (rest.length && rest[0] != ' ' && rest[0] != '\t')
            return "invalid length";
        if (b.length <= 0)
            return "length must be positive";
        if (b.at > long.max - b.length)
            return "bookmark ends past the largest offset";
        b.name = strip(rest).idup;
        list ~= b;
    }

    line = 0;
    sort!((a, b) => a.at < b.at, SwapStrategy.stable)(list);
    bookmark_merge(list);
    return null;
}

/// Add a bookmark, absorbing overlapping ones and touching same-named ones.
private void bookmark_add(ref Bookmark[] list, long at, long length, string name)
{
    long end = at + length;

    Bookmark[] kept;
    kept.reserve(list.length + 1);

    size_t i;
    for (; i < list.length && list[i].at + list[i].length <= at &&
           bookmark_joins(list[i], at, end, name) == false; ++i)
        kept ~= list[i];

    // Test against the grown span, not the original.
    for (; i < list.length && bookmark_joins(list[i], at, end, name); ++i)
    {
        if (list[i].at < at)
            at = list[i].at;
        long tail = list[i].at + list[i].length;
        if (tail > end)
            end = tail;
        if (name.length == 0)
            name = list[i].name; // keep the name over an unnamed bookmark
    }

    kept ~= Bookmark(at, end - at, name);
    kept ~= list[i .. $];
    list = kept;
}

/// Whether `b` merges with at..end: overlapping always, touching if same name.
private bool bookmark_joins(ref const(Bookmark) b, long at, long end, string name)
{
    long tail = b.at + b.length;
    if (b.at < end && tail > at)
        return true;
    return (tail == at || b.at == end) && b.name == name;
}

/// Remove at..at+length from bookmarks, splitting as needed.
private void bookmark_clear(ref Bookmark[] list, long at, long length)
{
    long end = at + length;

    Bookmark[] kept;
    kept.reserve(list.length + 1);
    foreach (ref const(Bookmark) b; list)
    {
        long tail = b.at + b.length;
        if (tail <= at || b.at >= end)
        {
            kept ~= b;
            continue;
        }
        // Both halves keep the name.
        if (b.at < at)
            kept ~= Bookmark(b.at, at - b.at, b.name);
        if (tail > end)
            kept ~= Bookmark(end, tail - end, b.name);
    }
    list = kept;
}

/// Merge overlapping bookmarks and touching same-named ones.
private void bookmark_merge(ref Bookmark[] list)
{
    size_t n;
    foreach (ref const(Bookmark) b; list)
    {
        if (n)
        {
            long tail = list[n - 1].at + list[n - 1].length;
            if (tail > b.at || (tail == b.at && list[n - 1].name == b.name))
            {
                long end = b.at + b.length;
                if (end > tail)
                    list[n - 1].length = end - list[n - 1].at;
                if (list[n - 1].name.length == 0)
                    list[n - 1].name = b.name;
                continue;
            }
        }
        list[n++] = b;
    }
    list = list[0 .. n];
}

unittest
{
    Bookmark[] list;

    // Stays sorted regardless of insert order.
    assert(bookmark_toggle(list, 0x20, 1));
    assert(bookmark_toggle(list, 0x10, 4));
    assert(bookmark_toggle(list, 0x30, 1));
    assert(list == [ Bookmark(0x10, 4), Bookmark(0x20, 1), Bookmark(0x30, 1) ]);

    assert(bookmark_has(list, 0x10));
    assert(bookmark_has(list, 0x13));
    assert(bookmark_has(list, 0x14) == false);
    assert(bookmark_covers(list, 0x10, 4));
    assert(bookmark_covers(list, 0x10, 5) == false);

    // Touching is enough.
    assert(bookmark_hits(list, 0x00, 0x40));
    assert(bookmark_hits(list, 0x13, 1));             // last byte
    assert(bookmark_hits(list, 0x00, 0x11));          // ends one byte inside
    assert(bookmark_hits(list, 0x14, 0x0c) == false); // gap
    assert(bookmark_hits(list, 0x00, 0x10) == false); // ends at bookmark start
    assert(bookmark_hits(list, 0x31, 0x10) == false);
    assert(bookmark_hits(list, 0x10, 0) == false);
    assert(bookmark_hits(null, 0, long.max) == false);

    // Toggling again clears.
    assert(bookmark_toggle(list, 0x10, 4) == false);
    assert(list == [ Bookmark(0x20, 1), Bookmark(0x30, 1) ]);

    // Partial clear keeps the rest.
    list = [ Bookmark(0x10, 8) ];
    assert(bookmark_toggle(list, 0x12, 2) == false);
    assert(list == [ Bookmark(0x10, 2), Bookmark(0x14, 4) ]);

    // Absorbs overlapping bookmarks and touching unnamed ones.
    list = [ Bookmark(0x10, 2), Bookmark(0x14, 4) ];
    assert(bookmark_toggle(list, 0x11, 4));
    assert(list == [ Bookmark(0x10, 8) ]);
    list = [ Bookmark(0x10, 4) ];
    assert(bookmark_toggle(list, 0x14, 4));
    assert(list == [ Bookmark(0x10, 8) ]);

    // Wraps at both ends.
    list = [ Bookmark(0x10, 4), Bookmark(0x30, 1) ];
    assert(bookmark_step(list, 0x00, 1) == 0);
    assert(bookmark_step(list, 0x10, 1) == 1);
    assert(bookmark_step(list, 0x12, 1) == 1); // from inside: next
    assert(bookmark_step(list, 0x30, 1) == 0); // wrap
    assert(bookmark_step(list, 0x30, -1) == 0);
    assert(bookmark_step(list, 0x10, -1) == 1); // wrap
    assert(bookmark_step(null, 0, 1) == -1);

    // Insert: bookmarks after it move...
    list = [ Bookmark(0x10, 1), Bookmark(0x30, 1), Bookmark(0x40, 1) ];
    bookmark_shift(list, 0x20, 4);
    assert(list == [ Bookmark(0x10, 1), Bookmark(0x34, 1), Bookmark(0x44, 1) ]);

    // ...inside one: grows...
    list = [ Bookmark(0x10, 4) ];
    bookmark_shift(list, 0x12, 2);
    assert(list == [ Bookmark(0x10, 6) ]);

    // ...at its start: shifts...
    list = [ Bookmark(0x20, 2) ];
    bookmark_shift(list, 0x20, 2);
    assert(list == [ Bookmark(0x22, 2) ]);

    // ...at its end: outside.
    list = [ Bookmark(0x20, 2) ];
    bookmark_shift(list, 0x22, 2);
    assert(list == [ Bookmark(0x20, 2) ]);

    // Removal trims bookmarks, drops fully removed ones.
    list = [ Bookmark(0x10, 1), Bookmark(0x30, 1), Bookmark(0x32, 4) ];
    bookmark_shift(list, 0x30, -4);
    assert(list == [ Bookmark(0x10, 1), Bookmark(0x30, 2) ]);

    // Removal between bookmarks: they merge.
    list = [ Bookmark(0x10, 4), Bookmark(0x18, 4) ];
    bookmark_shift(list, 0x14, -4);
    assert(list == [ Bookmark(0x10, 8) ]);
}

/// Names and merging.
unittest
{
    // Touching differently named bookmarks stay separate.
    Bookmark[] list;
    assert(bookmark_toggle(list, 0x00, 4));
    assert(bookmark_rename(list, 0x00, "magic"));
    assert(bookmark_toggle(list, 0x04, 4));
    assert(bookmark_rename(list, 0x04, "version"));
    assert(list == [ Bookmark(0x00, 4, "magic"), Bookmark(0x04, 4, "version") ]);

    // Same name: merged.
    assert(bookmark_rename(list, 0x04, "magic"));
    assert(list == [ Bookmark(0x00, 8, "magic") ]);
    assert(bookmark_rename(list, 0x40, "nothing there") == false);

    // Unnamed bookmarks merge.
    list = [ Bookmark(0x10, 4) ];
    assert(bookmark_toggle(list, 0x14, 4));
    assert(list == [ Bookmark(0x10, 8) ]);

    // Unnamed bookmark touching a named one: separate...
    list = [ Bookmark(0x10, 4, "header") ];
    assert(bookmark_toggle(list, 0x14, 4));
    assert(list == [ Bookmark(0x10, 4, "header"), Bookmark(0x14, 4) ]);

    // ...overlapping: merged under the existing name.
    list = [ Bookmark(0x10, 4, "header") ];
    assert(bookmark_toggle(list, 0x12, 4));
    assert(list == [ Bookmark(0x10, 6, "header") ]);

    // Spanning two named bookmarks: one bookmark, first name.
    list = [ Bookmark(0x10, 2, "magic"), Bookmark(0x14, 2, "version") ];
    assert(bookmark_toggle(list, 0x11, 4));
    assert(list == [ Bookmark(0x10, 6, "magic") ]);

    // Coverage spans touching bookmarks.
    list = [ Bookmark(0x00, 4, "magic"), Bookmark(0x04, 4, "version") ];
    assert(bookmark_covers(list, 0x00, 8));
    assert(bookmark_covers(list, 0x02, 4));
    assert(bookmark_covers(list, 0x00, 9) == false);
    assert(bookmark_toggle(list, 0x00, 8) == false);
    assert(list.length == 0);

    // Splitting a named bookmark: both halves keep the name.
    list = [ Bookmark(0x10, 8, "table") ];
    assert(bookmark_toggle(list, 0x12, 2) == false);
    assert(list == [ Bookmark(0x10, 2, "table"), Bookmark(0x14, 4, "table") ]);

    // Shifts keep names; halves rejoin when made adjacent again.
    list = [ Bookmark(0x10, 4, "magic"), Bookmark(0x20, 4, "version") ];
    bookmark_shift(list, 0x18, 4);
    assert(list == [ Bookmark(0x10, 4, "magic"), Bookmark(0x24, 4, "version") ]);
    list = [ Bookmark(0x10, 4, "table"), Bookmark(0x18, 4, "table") ];
    bookmark_shift(list, 0x14, -4);
    assert(list == [ Bookmark(0x10, 8, "table") ]);

    // Differently named bookmarks made to touch stay separate.
    list = [ Bookmark(0x10, 4, "magic"), Bookmark(0x18, 4, "version") ];
    bookmark_shift(list, 0x14, -4);
    assert(list == [ Bookmark(0x10, 4, "magic"), Bookmark(0x14, 4, "version") ]);

    // Batch add: interleaved with existing ones, touching unnamed runs fold.
    list = [ Bookmark(0x08, 2, "magic"), Bookmark(0x30, 2) ];
    bookmark_add_all(list, [ Bookmark(0x00, 2), Bookmark(0x02, 2), Bookmark(0x09, 4),
        Bookmark(0x40, 1) ]);
    assert(list == [ Bookmark(0x00, 4), Bookmark(0x08, 5, "magic"), Bookmark(0x30, 2),
        Bookmark(0x40, 1) ]);
}

/// Saving and loading.
unittest
{
    Bookmark[] list = [ Bookmark(0x10, 4), Bookmark(0x20, 2, "magic\nnumber") ];
    string text = bookmark_format(list);
    assert(text == "# ddhx bookmarks\n0x10\t4\n0x20\t2\tmagic number\n");

    Bookmark[] back;
    size_t line;
    assert(bookmark_parse(text, back, line) is null);
    assert(back == [ Bookmark(0x10, 4), Bookmark(0x20, 2, "magic number") ]);

    // ddhx files, hand-written ones: any order, decimal, spaces, CRLF.
    assert(bookmark_parse("0x30 1\r\n\n  # note\n16   2\n0x11\t4\n", back, line) is null);
    assert(back == [ Bookmark(0x10, 5), Bookmark(0x30, 1) ]);

    assert(bookmark_parse("0x10 4\n0x20\n", back, line) !is null && line == 2);
    assert(bookmark_parse("zz 4\n", back, line) !is null && line == 1);
    assert(bookmark_parse("0x10 4x\n", back, line) !is null);
    assert(bookmark_parse("0x10 0\n", back, line) !is null);
    assert(bookmark_parse("0x10 -1\n", back, line) !is null);
    assert(bookmark_parse("", back, line) is null && back.length == 0);
}
