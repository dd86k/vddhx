/// Bookmarked runs of bytes in a document.
///
/// A bookmark is a run rather than a lone offset, since what is worth marking is
/// usually a field or a record. The list is sorted by offset and no two runs in it
/// overlap, so every lookup here can halve the list: the hex panel asks about every
/// byte it draws and the minimap about every cell.
///
/// Runs may sit end to end when their names differ, and only then: an unnamed run
/// set over its neighbours folds them together as it always did, while naming the
/// header field after another one has to leave two runs, or one of the two names
/// would have nowhere to live.
/// Authors: dd86k <dd@dax.moe>
module bookmarks;

/// One bookmarked run: `length` bytes from `at`, under `name` when the user gave
/// it one.
struct Bookmark
{
    long at;        /// Absolute position
    long length;    /// Length in bytes
    string name;    /// User label, empty when unnamed
}

/// Whether `at` falls inside any bookmarked run.
bool bookmark_has(const(Bookmark)[] list, long at)
{
    return bookmark_find(list, at) >= 0;
}

/// Where the run holding `at` sits in the list, or -1 when no run holds it.
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

/// Whether the whole run of `length` bytes from `at` is bookmarked.
///
/// Differently named runs sit end to end, so a run stopping short of the end can
/// still be carried on by the next one; the walk stops at the first gap.
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

/// Whether any byte of the run of `length` bytes from `at` is bookmarked.
///
/// What a minimap cell standing for a whole segment needs: one marked byte
/// anywhere has to colour it, and the sampled read behind the ribbon would walk
/// straight past a short mark.
bool bookmark_hits(const(Bookmark)[] list, long at, long length)
{
    if (length < 1)
        return false;

    // The first run ending past `at` is the only candidate: the ones before it
    // end earlier still, and the ones after it start later than it does.
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

/// Bookmark the run of `length` bytes from `at`, or clear it when all of it is
/// bookmarked already. Clearing part of a longer run leaves the rest of it.
/// Returns: true when the run came away bookmarked.
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

/// Give the run holding `at` the name `name`, or take its name away when `name` is
/// empty. A run left with a like-named neighbour folds into it, since what the two
/// now say about their bytes is the same thing.
/// Returns: false when no run holds `at`.
bool bookmark_rename(ref Bookmark[] list, long at, string name)
{
    ptrdiff_t index = bookmark_find(list, at);
    if (index < 0)
        return false;

    list[index].name = name;
    bookmark_merge(list);
    return true;
}

/// The bookmark nearest `from` in the direction `dir` says (positive forward),
/// not counting one that starts on `from` itself, wrapping around the ends of
/// the document.
/// Returns: Its place in the list, or -1 when there are no bookmarks at all.
ptrdiff_t bookmark_step(const(Bookmark)[] list, long from, int dir)
{
    if (list.length == 0)
        return -1;

    if (dir >= 0)
    {
        foreach (size_t i, ref const(Bookmark) b; list)
            if (b.at > from)
                return cast(ptrdiff_t) i;
        return 0; // past the last one: round to the first
    }

    foreach_reverse (size_t i, ref const(Bookmark) b; list)
        if (b.at < from)
            return cast(ptrdiff_t) i;
    return cast(ptrdiff_t) list.length - 1;
}

/// Keep the marks on their bytes when the document grows or shrinks underneath
/// them: `shift` is how far the bytes at `at` moved, positive for an insert and
/// negative for a removal, which takes whatever of a run sat in the removed span
/// with it. Runs left with nothing to point at are forgotten.
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
            // Bytes inserted at the very start of a run push the whole run
            // along; inserted at its very end they fall outside it. Anywhere
            // between, the run grows to hold them.
            if (head >= at)
                head += shift;
            if (tail > at)
                tail += shift;
        }
        else
        {
            // Both ends slide back past the removed span, and an end inside it
            // collapses onto where the span was.
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
    bookmark_merge(list); // a removal can leave two runs meeting end to end
}

/// Fold `at` and the `length` bytes after it into the list, swallowing whatever
/// runs it overlaps, and those it only meets when they carry the same name.
private void bookmark_add(ref Bookmark[] list, long at, long length, string name)
{
    long end = at + length;

    Bookmark[] kept;
    kept.reserve(list.length + 1);

    size_t i;
    for (; i < list.length && list[i].at + list[i].length <= at &&
           bookmark_joins(list[i], at, end, name) == false; ++i)
        kept ~= list[i];

    // The span grows as it swallows, so the run after the one just taken is tested
    // against what the new run has become rather than what it was handed.
    for (; i < list.length && bookmark_joins(list[i], at, end, name); ++i)
    {
        if (list[i].at < at)
            at = list[i].at;
        long tail = list[i].at + list[i].length;
        if (tail > end)
            end = tail;
        if (name.length == 0)
            name = list[i].name; // a name outlives the unnamed run set over it
    }

    kept ~= Bookmark(at, end - at, name);
    kept ~= list[i .. $];
    list = kept;
}

/// Whether `b` belongs in the run spanning [`at`, `end`) under `name`: overlapping
/// leaves no choice, the list holding no two runs over one byte, while merely
/// meeting it is only a fold when the two say the same thing about their bytes.
private bool bookmark_joins(ref const(Bookmark) b, long at, long end, string name)
{
    long tail = b.at + b.length;
    if (b.at < end && tail > at)
        return true;
    return (tail == at || b.at == end) && b.name == name;
}

/// Take `at` and the `length` bytes after it out of the list, splitting any run
/// that covered more than that.
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
            kept ~= b; // clear of the span
            continue;
        }
        // Both halves keep the name: what was said of the field is still true of
        // the bytes of it that are left.
        if (b.at < at)
            kept ~= Bookmark(b.at, at - b.at, b.name);
        if (tail > end)
            kept ~= Bookmark(end, tail - end, b.name);
    }
    list = kept;
}

/// Restore the invariant after the runs have moved: nothing overlaps, and two runs
/// left meeting are one run when they are named alike.
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

    // Setting keeps the list ordered however the runs arrive.
    assert(bookmark_toggle(list, 0x20, 1));
    assert(bookmark_toggle(list, 0x10, 4));
    assert(bookmark_toggle(list, 0x30, 1));
    assert(list == [ Bookmark(0x10, 4), Bookmark(0x20, 1), Bookmark(0x30, 1) ]);

    assert(bookmark_has(list, 0x10));
    assert(bookmark_has(list, 0x13));
    assert(bookmark_has(list, 0x14) == false);
    assert(bookmark_covers(list, 0x10, 4));
    assert(bookmark_covers(list, 0x10, 5) == false);

    // A span only has to touch a run rather than fill it.
    assert(bookmark_hits(list, 0x00, 0x40));
    assert(bookmark_hits(list, 0x13, 1));             // the run's last byte
    assert(bookmark_hits(list, 0x00, 0x11));          // ends one byte inside it
    assert(bookmark_hits(list, 0x14, 0x0c) == false); // the gap between two runs
    assert(bookmark_hits(list, 0x00, 0x10) == false); // stops where a run starts
    assert(bookmark_hits(list, 0x31, 0x10) == false);
    assert(bookmark_hits(list, 0x10, 0) == false);
    assert(bookmark_hits(null, 0, long.max) == false);

    // Setting the same run again clears it.
    assert(bookmark_toggle(list, 0x10, 4) == false);
    assert(list == [ Bookmark(0x20, 1), Bookmark(0x30, 1) ]);

    // Clearing part of a run leaves the rest of it behind.
    list = [ Bookmark(0x10, 8) ];
    assert(bookmark_toggle(list, 0x12, 2) == false);
    assert(list == [ Bookmark(0x10, 2), Bookmark(0x14, 4) ]);

    // A run swallows the ones it overlaps, and folds in a neighbour it only meets
    // end to end.
    list = [ Bookmark(0x10, 2), Bookmark(0x14, 4) ];
    assert(bookmark_toggle(list, 0x11, 4));
    assert(list == [ Bookmark(0x10, 8) ]);
    list = [ Bookmark(0x10, 4) ];
    assert(bookmark_toggle(list, 0x14, 4));
    assert(list == [ Bookmark(0x10, 8) ]);

    // Stepping, wrapping at both ends.
    list = [ Bookmark(0x10, 4), Bookmark(0x30, 1) ];
    assert(bookmark_step(list, 0x00, 1) == 0);
    assert(bookmark_step(list, 0x10, 1) == 1);
    assert(bookmark_step(list, 0x12, 1) == 1); // from inside a run: the next one
    assert(bookmark_step(list, 0x30, 1) == 0); // wrapped
    assert(bookmark_step(list, 0x30, -1) == 0);
    assert(bookmark_step(list, 0x10, -1) == 1); // wrapped
    assert(bookmark_step(null, 0, 1) == -1);

    // An insert moves the runs after it...
    list = [ Bookmark(0x10, 1), Bookmark(0x30, 1), Bookmark(0x40, 1) ];
    bookmark_shift(list, 0x20, 4);
    assert(list == [ Bookmark(0x10, 1), Bookmark(0x34, 1), Bookmark(0x44, 1) ]);

    // ...one landing inside a run stretches it to hold the new bytes...
    list = [ Bookmark(0x10, 4) ];
    bookmark_shift(list, 0x12, 2);
    assert(list == [ Bookmark(0x10, 6) ]);

    // ...one at the run's own start pushes it along whole...
    list = [ Bookmark(0x20, 2) ];
    bookmark_shift(list, 0x20, 2);
    assert(list == [ Bookmark(0x22, 2) ]);

    // ...and one at its end lands outside it.
    list = [ Bookmark(0x20, 2) ];
    bookmark_shift(list, 0x22, 2);
    assert(list == [ Bookmark(0x20, 2) ]);

    // A removal takes whatever of a run sat in it, and drops a run it ate whole.
    list = [ Bookmark(0x10, 1), Bookmark(0x30, 1), Bookmark(0x32, 4) ];
    bookmark_shift(list, 0x30, -4);
    assert(list == [ Bookmark(0x10, 1), Bookmark(0x30, 2) ]);

    // A removal between two runs leaves them meeting, so they fold into one.
    list = [ Bookmark(0x10, 4), Bookmark(0x18, 4) ];
    bookmark_shift(list, 0x14, -4);
    assert(list == [ Bookmark(0x10, 8) ]);
}

/// Names, and what they do to the folding.
unittest
{
    // Two fields back to back, which is what naming is for: they stay two runs.
    Bookmark[] list;
    assert(bookmark_toggle(list, 0x00, 4));
    assert(bookmark_rename(list, 0x00, "magic"));
    assert(bookmark_toggle(list, 0x04, 4));
    assert(bookmark_rename(list, 0x04, "version"));
    assert(list == [ Bookmark(0x00, 4, "magic"), Bookmark(0x04, 4, "version") ]);

    // Naming one of them what the other is called says one thing about eight bytes.
    assert(bookmark_rename(list, 0x04, "magic"));
    assert(list == [ Bookmark(0x00, 8, "magic") ]);
    assert(bookmark_rename(list, 0x40, "nothing there") == false);

    // Unnamed runs go on folding as they did.
    list = [ Bookmark(0x10, 4) ];
    assert(bookmark_toggle(list, 0x14, 4));
    assert(list == [ Bookmark(0x10, 8) ]);

    // An unnamed run set against a named one leaves it alone...
    list = [ Bookmark(0x10, 4, "header") ];
    assert(bookmark_toggle(list, 0x14, 4));
    assert(list == [ Bookmark(0x10, 4, "header"), Bookmark(0x14, 4) ]);

    // ...but one set over it takes the bytes and the name with them, there being
    // no room in the list for two runs over one byte.
    list = [ Bookmark(0x10, 4, "header") ];
    assert(bookmark_toggle(list, 0x12, 4));
    assert(list == [ Bookmark(0x10, 6, "header") ]);

    // A run reaching over two named ones is one run under the first of the names.
    list = [ Bookmark(0x10, 2, "magic"), Bookmark(0x14, 2, "version") ];
    assert(bookmark_toggle(list, 0x11, 4));
    assert(list == [ Bookmark(0x10, 6, "magic") ]);

    // Covering, and so toggling, reads across runs that meet.
    list = [ Bookmark(0x00, 4, "magic"), Bookmark(0x04, 4, "version") ];
    assert(bookmark_covers(list, 0x00, 8));
    assert(bookmark_covers(list, 0x02, 4));
    assert(bookmark_covers(list, 0x00, 9) == false);
    assert(bookmark_toggle(list, 0x00, 8) == false);
    assert(list.length == 0);

    // Clearing the middle of a named run leaves the name on both halves.
    list = [ Bookmark(0x10, 8, "table") ];
    assert(bookmark_toggle(list, 0x12, 2) == false);
    assert(list == [ Bookmark(0x10, 2, "table"), Bookmark(0x14, 4, "table") ]);

    // Edits carry the names along, and the halves of a name split by a removal
    // meet again as the one run they were.
    list = [ Bookmark(0x10, 4, "magic"), Bookmark(0x20, 4, "version") ];
    bookmark_shift(list, 0x18, 4);
    assert(list == [ Bookmark(0x10, 4, "magic"), Bookmark(0x24, 4, "version") ]);
    list = [ Bookmark(0x10, 4, "table"), Bookmark(0x18, 4, "table") ];
    bookmark_shift(list, 0x14, -4);
    assert(list == [ Bookmark(0x10, 8, "table") ]);

    // Two differently named runs a removal leaves meeting stay two runs.
    list = [ Bookmark(0x10, 4, "magic"), Bookmark(0x18, 4, "version") ];
    bookmark_shift(list, 0x14, -4);
    assert(list == [ Bookmark(0x10, 4, "magic"), Bookmark(0x14, 4, "version") ]);
}
