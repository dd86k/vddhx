/// Bookmarked runs of bytes in a document.
///
/// A bookmark is a run rather than a lone offset, since what is worth marking is
/// usually a field or a record. The list is sorted by offset and no two runs in
/// it overlap or touch, setting one over its neighbours folding them together, so
/// every lookup here can halve the list: the hex panel asks about every byte it
/// draws and the minimap about every cell.
/// Authors: dd86k <dd@dax.moe>
module bookmarks;

/// One bookmarked run: `length` bytes from `at`.
struct Bookmark
{
    long at;        /// Absolute position
    long length;    /// Length in bytes
}

/// Whether `at` falls inside any bookmarked run.
bool bookmark_has(const(Bookmark)[] list, long at)
{
    return bookmark_index(list, at) >= 0;
}

/// Whether the whole run of `length` bytes from `at` is bookmarked.
///
/// One lookup is enough: runs never touch, so a run holding `at` that stops
/// short of the end means there is a gap after it.
bool bookmark_covers(const(Bookmark)[] list, long at, long length)
{
    ptrdiff_t index = bookmark_index(list, at);
    if (index < 0)
        return false;
    return list[index].at + list[index].length >= at + length;
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
    bookmark_add(list, at, length);
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
            kept ~= Bookmark(head, tail - head);
    }
    list = kept;
    bookmark_merge(list); // a removal can leave two runs meeting end to end
}

/// Fold `at` and the `length` bytes after it into the list, swallowing whatever
/// runs it overlaps or meets.
private void bookmark_add(ref Bookmark[] list, long at, long length)
{
    long end = at + length;

    Bookmark[] kept;
    kept.reserve(list.length + 1);

    size_t i;
    for (; i < list.length && list[i].at + list[i].length < at; ++i)
        kept ~= list[i];

    for (; i < list.length && list[i].at <= end; ++i)
    {
        if (list[i].at < at)
            at = list[i].at;
        long tail = list[i].at + list[i].length;
        if (tail > end)
            end = tail;
    }

    kept ~= Bookmark(at, end - at);
    kept ~= list[i .. $];
    list = kept;
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
        if (b.at < at)
            kept ~= Bookmark(b.at, at - b.at);   // the part before it survives
        if (tail > end)
            kept ~= Bookmark(end, tail - end);   // and so does the part after
    }
    list = kept;
}

/// Restore the no-overlap-no-touching invariant after the runs have moved.
private void bookmark_merge(ref Bookmark[] list)
{
    size_t n;
    foreach (ref const(Bookmark) b; list)
    {
        if (n && list[n - 1].at + list[n - 1].length >= b.at)
        {
            long tail = b.at + b.length;
            if (tail > list[n - 1].at + list[n - 1].length)
                list[n - 1].length = tail - list[n - 1].at;
            continue;
        }
        list[n++] = b;
    }
    list = list[0 .. n];
}

/// Where the run holding `at` sits in the list, or -1 when no run holds it.
private ptrdiff_t bookmark_index(const(Bookmark)[] list, long at)
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
