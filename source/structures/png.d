/// PNG structure: signature, then chunks. Only IHDR is split into fields;
/// other payloads are one span.
/// Authors: dd86k <dd@dax.moe>
module structures.png;

import std.system : Endian;

import structure;

immutable ubyte[8] PNG_SIGNATURE = [ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a ];

/// Whether `head` starts with the PNG signature.
bool png_detect(const(ubyte)[] head)
{
    return head.length >= PNG_SIGNATURE.length && head[0 .. PNG_SIGNATURE.length] == PNG_SIGNATURE;
}

final class PngStructure : IStructure
{
    string name()
    {
        return "PNG";
    }

    bool parse(ref StructureBuilder b, long until)
    {
        if (b.at == 0)
        {
            if (b.size < PNG_SIGNATURE.length)
                return false;
            b.field(StructureRole.magic, "signature", PNG_SIGNATURE.length);
        }

        while (ended == false && b.at < until)
            if (chunk(b) == false)
                return false;

        return ended == false;
    }

    void forget()
    {
        ended = false; // keep interned tags
    }

    private:

    bool ended;

    // Interned chunk type names keyed by the 4 bytes, so many IDATs allocate once.
    string[uint] tags;

    // Length, type, payload, CRC. Registered at the declared length even if the
    // file is truncated, so a short last chunk shows as such.
    // Returns: false at IEND or end of file.
    bool chunk(ref StructureBuilder b)
    {
        long head = b.at;
        if (head + 8 > b.size) // no room for length and type
            return false;

        ulong declared = b.peek(4, Endian.bigEndian);

        ubyte[4] raw = void;
        if (b.read(head + 4, raw).length < 4)
            return false;
        string tag = tagName(raw);

        long total = 12 + cast(long) declared;
        bool whole  = head + total <= b.size;

        b.open(tag, whole ? total : b.size - head);
        b.field(StructureRole.length, "length", 4);
        b.field(StructureRole.magic, "type", 4);

        long payload = whole ? cast(long) declared : b.size - b.at;
        if (tag == "IHDR" && payload == 13)
            ihdr(b);
        else if (payload > 0)
            b.field(StructureRole.data, "data", payload);

        if (whole)
            b.field(StructureRole.checksum, "crc", 4);
        b.close();

        if (whole == false)
            return false;

        ended = tag == "IEND";
        return true;
    }

    // IHDR's 13 bytes, the only payload split into fields.
    void ihdr(ref StructureBuilder b)
    {
        b.field(StructureRole.scalar, "width", 4);
        b.field(StructureRole.scalar, "height", 4);
        b.field(StructureRole.scalar, "bit depth", 1);
        b.field(StructureRole.flags, "colour type", 1);
        b.field(StructureRole.flags, "compression", 1);
        b.field(StructureRole.flags, "filter", 1);
        b.field(StructureRole.flags, "interlace", 1);
    }

    // Interned chunk type name. Non-printable bytes become dots, keeping it 4 wide.
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
        out_ ~= [ 0, 0, 0, 0 ]; // CRC, unchecked
        return out_;
    }

    // Signature, IHDR, one IDAT, IEND. Offsets used by the tests:
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

    private StructureReadFn readerFor(ubyte[] doc)
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

    StructureCache c = structure_bind(new PngStructure(), readerFor(doc), doc.length);
    assert(structure_name(c) == "PNG");

    StructureSpan s;
    assert(structure_at(c, 0, s));
    assert(s.role == StructureRole.magic && s.name == "signature" && s.length == 8);
    assert(structure_ancestor(c, 0, 1, s) == false); // signature isn't in a chunk

    // IHDR fields, nested in the chunk.
    assert(structure_at(c, 8, s) && s.role == StructureRole.length && s.name == "length");
    assert(structure_at(c, 12, s) && s.role == StructureRole.magic && s.name == "type");
    assert(structure_at(c, 16, s) && s.name == "width" && s.length == 4);
    assert(structure_at(c, 20, s) && s.name == "height");
    assert(structure_at(c, 24, s) && s.name == "bit depth" && s.length == 1);
    assert(structure_at(c, 28, s) && s.name == "interlace");
    assert(structure_at(c, 29, s) && s.role == StructureRole.checksum && s.name == "crc");

    assert(structure_ancestor(c, 16, 1, s));
    assert(s.name == "IHDR" && s.at == 8 && s.length == 25 && s.role == StructureRole.none);

    // Other payloads: one span.
    assert(structure_at(c, 41, s));
    assert(s.role == StructureRole.data && s.name == "data" && s.at == 41 && s.length == 4);
    assert(structure_ancestor(c, 41, 1, s));
    assert(s.name == "IDAT" && s.at == 33 && s.length == 16);

    // IEND: no payload, CRC follows type.
    assert(structure_at(c, 57, s) && s.role == StructureRole.checksum);
    assert(structure_ancestor(c, 57, 1, s) && s.name == "IEND" && s.length == 12);

    assert(structure_at(c, 61, s) == false);

    // Chunks tile the whole file.
    foreach (long at; 0 .. cast(long) doc.length)
        assert(structure_at(c, at, s), "uncovered byte");
}

/// Parsing stops at the requested offset.
unittest
{
    ubyte[] doc = pngFile();

    StructureCache c = structure_bind(new PngStructure(), readerFor(doc), doc.length);

    StructureSpan s;
    assert(structure_at(c, 16, s) && s.name == "width");

    // Only up to IHDR was parsed.
    assert(structure_ancestor(c, 41, 1, s) && s.name == "IDAT");
}

/// Truncated file: the short chunk is still shown.
unittest
{
    ubyte[] doc = pngFile()[0 .. 45]; // inside IDAT, CRC lost

    StructureCache c = structure_bind(new PngStructure(), readerFor(doc), doc.length);

    StructureSpan s;
    assert(structure_ancestor(c, 41, 1, s));
    assert(s.name == "IDAT" && s.at == 33 && s.length == 12); // 16 declared, 12 left
    assert(structure_at(c, 41, s) && s.role == StructureRole.data && s.length == 4);

    // Cut inside a chunk header: nothing registered for it.
    doc = pngFile()[0 .. 12];
    c = structure_bind(new PngStructure(), readerFor(doc), doc.length);
    assert(structure_at(c, 0, s) && s.name == "signature");
    assert(structure_at(c, 8, s) == false);
}

/// Corrupt chunk type still gives a 4-character name.
unittest
{
    ubyte[] doc = PNG_SIGNATURE.dup;
    doc ~= pngChunk("\x00A\xffB", [ 1, 2 ]);

    StructureCache c = structure_bind(new PngStructure(), readerFor(doc), doc.length);

    StructureSpan s;
    assert(structure_ancestor(c, 8 + 8, 1, s));
    assert(s.name == ".A.B" && s.length == 14);
}

/// An edit only drops the chunk it lands in; reparse gives the same spans.
unittest
{
    ubyte[] doc = pngFile();

    StructureCache c = structure_bind(new PngStructure(), readerFor(doc), doc.length);

    StructureSpan s;
    assert(structure_at(c, 57, s)); // parse all

    structure_invalidate(c, 41); // IDAT payload
    assert(structure_at(c, 16, s) && s.name == "width"); // IHDR survived
    assert(structure_ancestor(c, 41, 1, s) && s.name == "IDAT" && s.at == 33);
    assert(structure_ancestor(c, 57, 1, s) && s.name == "IEND");
}
