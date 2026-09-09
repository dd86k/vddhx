/// PNG as a layout: the eight-byte signature, then the chunk loop.
///
/// The first real format over the layout interface, and picked for it: chunks are
/// length-prefixed and follow one another, so the whole file parses front to back one
/// record at a time, which is what the incremental cache is built around. Only IHDR
/// is broken into fields; every other chunk's payload is left as one span, there being
/// nothing to say about it that the bytes do not.
/// Authors: dd86k <dd@dax.moe>
module layouts.png;

import std.system : Endian;

import layout;

/// The signature every PNG opens with.
immutable ubyte[8] PNG_SIGNATURE = [ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a ];

/// Whether the bytes a document starts with are a PNG's.
bool png_detect(const(ubyte)[] head)
{
    return head.length >= PNG_SIGNATURE.length && head[0 .. PNG_SIGNATURE.length] == PNG_SIGNATURE;
}

/// PNG structure over a document.
final class PngLayout : ILayout
{
    string name()
    {
        return "PNG";
    }

    bool parse(ref LayoutBuilder b, long until)
    {
        if (b.at == 0)
        {
            if (b.size < PNG_SIGNATURE.length)
                return false;
            b.field(LayoutRole.magic, "signature", PNG_SIGNATURE.length);
        }

        while (ended == false && b.at < until)
            if (chunk(b) == false)
                return false;

        return ended == false;
    }

    void forget()
    {
        ended = false; // the interned tags are worth keeping, this is not
    }

    private:

    bool ended;

    // Chunk types are four bytes read out of the file rather than literals, so naming
    // a span after one means a string per chunk. Keyed by the four bytes, a file of a
    // hundred thousand IDATs allocates once. Per layout instance rather than global:
    // the table belongs to the document being parsed, and nothing here is threaded.
    string[uint] tags;

    // One chunk: a length, a type, that many bytes of payload, and a CRC over the two
    // middle parts. Registered under the declared length even when the file is too
    // short for it, so a truncated last chunk shows as the short one it is.
    // Returns: false at the end of the chunks, whether that is IEND or a cut file.
    bool chunk(ref LayoutBuilder b)
    {
        long head = b.at;
        if (head + 8 > b.size) // no room for even a length and a type
            return false;

        ulong declared = b.peek(4, Endian.bigEndian);

        ubyte[4] raw = void;
        if (b.read(head + 4, raw).length < 4)
            return false;
        string tag = tagName(raw);

        long total = 12 + cast(long) declared;
        bool whole  = head + total <= b.size;

        b.open(tag, whole ? total : b.size - head);
        b.field(LayoutRole.length, "length", 4);
        b.field(LayoutRole.magic, "type", 4);

        long payload = whole ? cast(long) declared : b.size - b.at;
        if (tag == "IHDR" && payload == 13)
            ihdr(b);
        else if (payload > 0)
            b.field(LayoutRole.data, "data", payload);

        if (whole)
            b.field(LayoutRole.checksum, "crc", 4);
        b.close();

        if (whole == false)
            return false;

        ended = tag == "IEND";
        return true;
    }

    // IHDR's thirteen bytes, the one payload worth naming: everything downstream of a
    // PNG is read in terms of these.
    void ihdr(ref LayoutBuilder b)
    {
        b.field(LayoutRole.scalar, "width", 4);
        b.field(LayoutRole.scalar, "height", 4);
        b.field(LayoutRole.scalar, "bit depth", 1);
        b.field(LayoutRole.flags, "colour type", 1);
        b.field(LayoutRole.flags, "compression", 1);
        b.field(LayoutRole.flags, "filter", 1);
        b.field(LayoutRole.flags, "interlace", 1);
    }

    // A chunk type as a name, interned. Bytes outside printable ASCII become dots
    // rather than going into a name as they are: a corrupt type is worth seeing, and
    // worth seeing as four characters wide.
    string tagName(ref const(ubyte[4]) raw)
    {
        uint key = (raw[0] << 24) | (raw[1] << 16) | (raw[2] << 8) | raw[3];
        if (string* found = key in tags)
            return *found;

        char[4] chars = void;
        foreach (size_t i, ubyte c; raw)
            chars[i] = c >= 0x20 && c < 0x7f ? cast(char) c : '.';

        string name = chars.idup;
        tags[key] = name;
        return name;
    }
}

version (unittest)
{
    private ubyte[] pngChunk(string type, const(ubyte)[] data)
    {
        uint length = cast(uint) data.length;
        ubyte[] out_;
        out_ ~= [
            cast(ubyte)(length >> 24), cast(ubyte)(length >> 16),
            cast(ubyte)(length >> 8), cast(ubyte) length
        ];
        out_ ~= cast(const(ubyte)[]) type;
        out_ ~= data;
        out_ ~= [ 0, 0, 0, 0 ]; // CRC, which nothing here checks
        return out_;
    }

    // Signature, IHDR, one IDAT, IEND. Offsets the tests below name by hand:
    //   0  signature (8)
    //   8  IHDR chunk (25): 8 length, 12 type, 16 width, 20 height, 24 depth,
    //      25 colour, 26 compression, 27 filter, 28 interlace, 29 crc
    //   33 IDAT chunk (16): 33 length, 37 type, 41 data, 45 crc
    //   49 IEND chunk (12): 49 length, 53 type, 57 crc
    private ubyte[] pngFile()
    {
        ubyte[] doc = PNG_SIGNATURE.dup;
        doc ~= pngChunk("IHDR", [
            0, 0, 0, 16, 0, 0, 0, 16, 8, 6, 0, 0, 0
        ]);
        doc ~= pngChunk("IDAT", [ 0xde, 0xad, 0xbe, 0xef ]);
        doc ~= pngChunk("IEND", null);
        return doc;
    }

    private LayoutReadFn readerFor(ubyte[] doc)
    {
        return delegate(long at, ubyte[] buf)
        {
            if (at < 0 || at >= doc.length)
                return buf[0 .. 0];
            size_t n = cast(size_t)(doc.length - at);
            if (n > buf.length)
                n = buf.length;
            buf[0 .. n] = doc[cast(size_t) at .. cast(size_t) at + n];
            return buf[0 .. n];
        };
    }
}

unittest
{
    assert(png_detect(PNG_SIGNATURE));
    assert(png_detect(pngFile()));
    assert(png_detect(PNG_SIGNATURE[0 .. 7]) == false);
    assert(png_detect([ 'G', 'I', 'F', '8', '9', 'a', 0, 0 ]) == false);
    assert(png_detect(null) == false);
}

unittest
{
    ubyte[] doc = pngFile();
    assert(doc.length == 61);

    LayoutCache c = layout_bind(new PngLayout(), readerFor(doc), doc.length);
    assert(layout_name(c) == "PNG");

    LayoutSpan s;
    assert(layout_at(c, 0, s));
    assert(s.role == LayoutRole.magic && s.name == "signature" && s.length == 8);
    assert(layout_ancestor(c, 0, 1, s) == false); // the signature is not in a chunk

    // IHDR, broken out into its fields, each inside the chunk that holds them.
    assert(layout_at(c, 8, s) && s.role == LayoutRole.length && s.name == "length");
    assert(layout_at(c, 12, s) && s.role == LayoutRole.magic && s.name == "type");
    assert(layout_at(c, 16, s) && s.name == "width" && s.length == 4);
    assert(layout_at(c, 20, s) && s.name == "height");
    assert(layout_at(c, 24, s) && s.name == "bit depth" && s.length == 1);
    assert(layout_at(c, 28, s) && s.name == "interlace");
    assert(layout_at(c, 29, s) && s.role == LayoutRole.checksum && s.name == "crc");

    assert(layout_ancestor(c, 16, 1, s));
    assert(s.name == "IHDR" && s.at == 8 && s.length == 25 && s.role == LayoutRole.none);

    // An unnamed payload stays one span.
    assert(layout_at(c, 41, s));
    assert(s.role == LayoutRole.data && s.name == "data" && s.at == 41 && s.length == 4);
    assert(layout_ancestor(c, 41, 1, s));
    assert(s.name == "IDAT" && s.at == 33 && s.length == 16);

    // IEND carries no payload, so its CRC follows its type.
    assert(layout_at(c, 57, s) && s.role == LayoutRole.checksum);
    assert(layout_ancestor(c, 57, 1, s) && s.name == "IEND" && s.length == 12);

    // Nothing past the end of the file.
    assert(layout_at(c, 61, s) == false);

    // Every byte of the file is covered, the chunks tiling it end to end.
    foreach (long at; 0 .. cast(long) doc.length)
        assert(layout_at(c, at, s), "uncovered byte");
}

/// Only the chunks up to the offset asked about are walked.
unittest
{
    ubyte[] doc = pngFile();

    LayoutCache c = layout_bind(new PngLayout(), readerFor(doc), doc.length);

    LayoutSpan s;
    assert(layout_at(c, 16, s) && s.name == "width");

    // IHDR was reached, so IDAT and IEND were not: asking for one of their offsets
    // would have had to parse them.
    assert(layout_ancestor(c, 41, 1, s) && s.name == "IDAT");
}

/// A file cut short mid-chunk shows the short chunk rather than nothing.
unittest
{
    ubyte[] doc = pngFile()[0 .. 45]; // inside IDAT, its CRC lost

    LayoutCache c = layout_bind(new PngLayout(), readerFor(doc), doc.length);

    LayoutSpan s;
    assert(layout_ancestor(c, 41, 1, s));
    assert(s.name == "IDAT" && s.at == 33 && s.length == 12); // 16 declared, 12 left
    assert(layout_at(c, 41, s) && s.role == LayoutRole.data && s.length == 4);

    // And one cut inside a chunk header registers nothing of it at all.
    doc = pngFile()[0 .. 12];
    c = layout_bind(new PngLayout(), readerFor(doc), doc.length);
    assert(layout_at(c, 0, s) && s.name == "signature");
    assert(layout_at(c, 8, s) == false);
}

/// A corrupt chunk type is still a four-character name.
unittest
{
    ubyte[] doc = PNG_SIGNATURE.dup;
    doc ~= pngChunk("\x00A\xffB", [ 1, 2 ]);

    LayoutCache c = layout_bind(new PngLayout(), readerFor(doc), doc.length);

    LayoutSpan s;
    assert(layout_ancestor(c, 8 + 8, 1, s));
    assert(s.name == ".A.B" && s.length == 14);
}

/// An edit drops the chunk it lands in and no more, and the same spans come back.
unittest
{
    ubyte[] doc = pngFile();

    LayoutCache c = layout_bind(new PngLayout(), readerFor(doc), doc.length);

    LayoutSpan s;
    assert(layout_at(c, 57, s)); // parse it all

    layout_invalidate(c, 41); // inside IDAT's payload
    assert(layout_at(c, 16, s) && s.name == "width"); // IHDR survived
    assert(layout_ancestor(c, 41, 1, s) && s.name == "IDAT" && s.at == 33);
    assert(layout_ancestor(c, 57, 1, s) && s.name == "IEND");
}
