/// Pattern writes (ddhx's replace, insert, and their -range forms): parse the
/// typed text into a range and the bytes to repeat over it.
///
///   x:00                    pattern, over the selection or once at the caret
///   0x100:0x1ff x:00        range then pattern (-range forms)
///   0x100:+16 utf8:ab       start and length
///   16 u16:1                length from the caret
///   .:$ x:ff                caret to the end
///
/// Patterns follow find's rules (see search) minus wildcards and value ranges,
/// which name no bytes.
/// Authors: dd86k <dd@dax.moe>
module edit;

import std.string : strip;
import std.system : Endian;

import patterns : pattern, Pattern, PATTERN_NOT_BYTES;
import ranges : range, Range, RangeSentinel, RANGE_RELATIVE;
import search : search_prefixed;
import utils : Argument, arguments;

/// Parsed write: where, how far, and the repeated bytes.
struct EditRequest
{
    long start;   /// First byte.
    long length;  /// Bytes written, 0 if no range was given.
    ubyte[] data; /// Pattern bytes, repeated over `length`.
}

/// Parse `text`. `ranged`: the first token is a range, resolved against the
/// caret `cursor` and the document `size`.
/// Returns: null on success, else what's wrong, for the prompt's row.
string edit_parse(const(char)[] text, bool ranged, Endian endian, long cursor,
    long size, out EditRequest req)
{
    text = strip(text);
    if (text.length == 0)
        return ranged ? "type a range, then a pattern" : "type a pattern";

    Argument[] args;
    try args = arguments(text);
    catch (Exception e)
        return e.msg;
    if (args.length == 0)
        return ranged ? "type a range, then a pattern" : "type a pattern";

    if (ranged)
    {
        string error = edit_range(cast(string) args[0].data, cursor, size, req);
        if (error)
            return error;
        args = args[1 .. $];
        if (args.length == 0)
            return "type a pattern after the range";
    }

    // Same rule as find: the first token names its encoding.
    if (search_prefixed(cast(const(char)[]) args[0].data) == false)
        return "a pattern needs a prefix: x:, utf8:, u16:, ...";

    Pattern p;
    try p = pattern(endian, args);
    catch (Exception e)
        return e.msg;
    if (p.flags & PATTERN_NOT_BYTES)
        return "wildcards and value ranges can't be written";
    if (p.data.length == 0)
        return "type a pattern";
    req.data = p.toBytes();
    return null;
}

/// Resolve range `text` into `req.start` and `req.length`, like ddhx's
/// askrange. Returns: null, or what's wrong.
string edit_range(string text, long cursor, long size, ref EditRequest req)
{
    Range r;
    try r = range(text);
    catch (Exception e)
        return e.msg;

    switch (r.start)
    {
    case RangeSentinel.eof:     return "a range can't start at $";
    case RangeSentinel.cursor:  r.start = cursor; break;
    default:
    }
    switch (r.end)
    {
    case RangeSentinel.eof:     r.end = size == 0 ? 0 : size - 1; break;
    case RangeSentinel.cursor:  r.end = cursor; break;
    default:
        if (r.flags & RANGE_RELATIVE)
            r.end = r.start + r.end;
    }

    if (r.start < 0 || r.end < 0)
        return "range is out of the document";
    if (r.start > r.end)
        return "range starts after its end";
    // Writing past the append slot would leave a gap.
    if (r.start > size)
        return "range starts past the end";
    req.start  = r.start;
    req.length = r.end - r.start + 1;
    return null;
}

unittest
{
    EditRequest req;
    assert(edit_parse("x:de ad", false, Endian.littleEndian, 0, 100, req) is null);
    assert(req.data == [ 0xde, 0xad ] && req.length == 0);

    assert(edit_parse("u16:1", false, Endian.bigEndian, 0, 100, req) is null);
    assert(req.data == [ 0, 1 ]);

    // Prefix required, wildcards refused.
    assert(edit_parse("hello", false, Endian.littleEndian, 0, 100, req) !is null);
    assert(edit_parse("x:de ? ad", false, Endian.littleEndian, 0, 100, req) !is null);
    assert(edit_parse("", false, Endian.littleEndian, 0, 100, req) !is null);

    assert(edit_parse("0x10:0x1f x:00", true, Endian.littleEndian, 0, 100, req) is null);
    assert(req.start == 0x10 && req.length == 16 && req.data == [ 0 ]);

    // NOTE: ddhx takes +4 as the end offset, so 5 bytes. A bare length is exact.
    assert(edit_parse("0x10:+4 x:ff", true, Endian.littleEndian, 0, 100, req) is null);
    assert(req.start == 0x10 && req.length == 5);

    // Length from the caret, caret to the end.
    assert(edit_parse("8 x:ff", true, Endian.littleEndian, 50, 100, req) is null);
    assert(req.start == 50 && req.length == 8);
    assert(edit_parse(".:$ x:ff", true, Endian.littleEndian, 90, 100, req) is null);
    assert(req.start == 90 && req.length == 10);

    assert(edit_parse("0x10:0x1f", true, Endian.littleEndian, 0, 100, req) !is null);
    assert(edit_parse("0x20:0x10 x:00", true, Endian.littleEndian, 0, 100, req) !is null);
    assert(edit_parse("200:+4 x:00", true, Endian.littleEndian, 0, 100, req) !is null);
    assert(edit_parse("100:+4 x:00", true, Endian.littleEndian, 0, 100, req) is null); // append slot
}
