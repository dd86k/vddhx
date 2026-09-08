// BMP to PNG converter script
///
// The screenshot driver (source/screenshots.d) can only write BMP, since that is
// all SDL3 core encodes, and the pages want PNG. This is here so a shot can be
// converted without ffmpeg or ImageMagick on the machine.
///
// Reads what SDL_SaveBMP emits: 24- or 32-bit, BI_RGB or BI_BITFIELDS, either
// row order. Palettes and RLE are not handled, nothing here produces them.
//
// Usage: rdmd tools/bmp2png.d in.bmp out.png
module bmp2png;

import std.bitmanip : littleEndianToNative, nativeToBigEndian;
import std.file : read, write;
import std.stdio : stderr, writeln;
import std.zlib : compress, crc32;

private: // Shuts up dscanner on a lot of things. This is just a script

uint le32(const(ubyte)[] b, size_t at)
{
    return littleEndianToNative!uint(b[at .. at + 4][0 .. 4]);
}

ushort le16(const(ubyte)[] b, size_t at)
{
    return littleEndianToNative!ushort(b[at .. at + 2][0 .. 2]);
}

// A channel mask is a run of set bits: its offset is the low zero count and its
// width the popcount, which is all that is needed to scale it back to 8 bits.
struct Channel
{
    int shift;
    uint max;

    this(uint mask)
    {
        if (mask == 0)
            return;
        while ((mask & 1) == 0)
        {
            mask >>= 1;
            ++shift;
        }
        max = mask;
    }

    ubyte extract(uint px) const
    {
        if (max == 0)
            return 255; // absent channel: opaque alpha, or a colour that is all of it
        const uint v = (px >> shift) & max;
        return cast(ubyte)((v * 255 + max / 2) / max);
    }
}

void chunk(ref ubyte[] o, string type, const(ubyte)[] data)
{
    o ~= nativeToBigEndian(cast(uint)data.length)[];
    ubyte[] body_ = cast(ubyte[])type.dup ~ data;
    o ~= body_;
    o ~= nativeToBigEndian(crc32(0, body_))[];
}

void write_png(string path, int w, int h, const(ubyte)[] rgba)
{
    ubyte[] raw;
    raw.reserve(h * (1 + w * 4));
    for (int y; y < h; ++y)
    {
        raw ~= 0; // filter: none
        raw ~= rgba[y * w * 4 .. (y + 1) * w * 4];
    }

    ubyte[] ihdr;
    ihdr ~= nativeToBigEndian(cast(uint)w)[];
    ihdr ~= nativeToBigEndian(cast(uint)h)[];
    ihdr ~= [cast(ubyte)8, 6, 0, 0, 0];

    ubyte[] png = [0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'];
    chunk(png, "IHDR", ihdr);
    chunk(png, "IDAT", cast(ubyte[])compress(raw, 9));
    chunk(png, "IEND", null);
    write(path, png);
}

int main(string[] args)
{
    if (args.length != 3)
    {
        stderr.writeln("usage: bmp2png in.bmp out.png");
        return 1;
    }

    ubyte[] bmp = cast(ubyte[])read(args[1]);
    if (bmp.length < 54 || bmp[0] != 'B' || bmp[1] != 'M')
    {
        stderr.writeln("not a BMP: ", args[1]);
        return 1;
    }

    const uint offset = le32(bmp, 10);
    const uint hdrsize = le32(bmp, 14);
    const int  width   = cast(int)le32(bmp, 18);
    const int  rawh    = cast(int)le32(bmp, 22);
    const ushort bpp   = le16(bmp, 28);
    const uint compression = le32(bmp, 30);

    // Negative height is the top-down form; positive rows run bottom-up.
    const bool bottomUp = rawh > 0;
    const int height = bottomUp ? rawh : -rawh;

    if (bpp != 24 && bpp != 32)
    {
        stderr.writeln("unsupported bit depth: ", bpp);
        return 1;
    }
    if (compression != 0 && compression != 3)
    {
        stderr.writeln("unsupported compression: ", compression);
        return 1;
    }

    // BI_BITFIELDS spells the masks out, either in the header (V4 and up) or in
    // the three words between header and pixels; BI_RGB is fixed BGR(A).
    // BI_RGB's fourth byte is padding, not alpha: reading it would turn writers
    // that leave it zero into a fully transparent image.
    uint rmask = 0x00ff0000, gmask = 0x0000ff00, bmask = 0x000000ff, amask = 0;
    if (compression == 3)
    {
        const size_t at = 14 + (hdrsize >= 52 ? 40 : hdrsize);
        rmask = le32(bmp, at);
        gmask = le32(bmp, at + 4);
        bmask = le32(bmp, at + 8);
        amask = hdrsize >= 56 ? le32(bmp, at + 12) : 0;
    }

    const Channel R = Channel(rmask), G = Channel(gmask);
    const Channel B = Channel(bmask), A = Channel(amask);

    const size_t bytes = bpp / 8;
    const size_t stride = (width * bytes + 3) & ~3; // rows are 4-byte aligned
    if (offset + stride * height > bmp.length)
    {
        stderr.writeln("truncated pixel data");
        return 1;
    }

    ubyte[] rgba = new ubyte[width * height * 4];
    for (int y; y < height; ++y)
    {
        const size_t src = offset + (bottomUp ? height - 1 - y : y) * stride;
        for (int x; x < width; ++x)
        {
            const size_t s = src + x * bytes;
            const uint px = bytes == 4
                ? le32(bmp, s)
                : bmp[s] | (bmp[s + 1] << 8) | (bmp[s + 2] << 16);
            const size_t d = (y * width + x) * 4;
            rgba[d    ] = R.extract(px);
            rgba[d + 1] = G.extract(px);
            rgba[d + 2] = B.extract(px);
            rgba[d + 3] = bytes == 4 ? A.extract(px) : 255;
        }
    }

    write_png(args[2], width, height, rgba);
    writeln("write: ", args[2], " (", width, 'x', height, ')');
    return 0;
}
