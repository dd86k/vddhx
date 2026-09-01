// Icon generator script
///
// The mark is vector geometry in a 64-unit design space: a rounded plate with a
// 3x3 of rounded cells on it. `vddhx.svg` is that geometry written out directly;
// the PNGs and BMPs are the same numbers rasterised here with 4x4 supersampling,
// so every output comes from one source and no external converter is needed.
///
// Colours are copied from hex_classify and ui.d
module mkicon;

import std.file : write, mkdirRecurse;
import std.conv : text;
import std.format : format;
import std.stdio : writeln;
import std.zlib : compress, crc32;
import std.bitmanip : nativeToBigEndian, nativeToLittleEndian;

private: // Shuts up dscanner on a lot of things. This is just a script

struct RGBA { ubyte r, g, b, a = 255; }

// hex_classify (source/hexview.d)
enum RGBA NUL     = RGBA(90, 90, 100);
enum RGBA PRINT   = RGBA(220, 220, 220);
enum RGBA WS      = RGBA(120, 170, 200);
enum RGBA CTRL    = RGBA(200, 130, 90);
enum RGBA HIGH    = RGBA(150, 190, 130);
// ui.d's CANVAS is pure black, which would leave the plate with no silhouette
// against a dark desktop; this is that black lifted just enough to have an edge.
enum RGBA PLATE   = RGBA(18, 18, 22);
// Not in the app: the bookmark wash is a background tint, too dark to carry a
// whole cell on its own.
enum RGBA ACCENT  = RGBA(230, 170, 60);

// One byte class per cell, arranged for balance rather than transcribed from a
// real dump: two runs of padding, a bookmarked byte at the centre to focus it.
immutable RGBA[3][3] CELLS = [
    [HIGH,  PRINT,  CTRL],
    [PRINT, ACCENT, WS],
    [NUL,   NUL,    HIGH],
];

// Design space is 64 units square.
struct Geo
{
    double plateInset, plateSize, plateR;
    double cellOrigin, cellSize, cellGap, cellR;

    double cellAt(int i) const { return cellOrigin + i * (cellSize + cellGap); }
}

// The mark proper. The plate is inset so it has air around it in a grid of
// other icons, and the 9 units between plate edge and first cell are what keep
// it from reading as a full-bleed table.
enum Geo NORMAL = Geo(2, 60, 13, 11, 12, 3, 2.5);

// At 16 the normal geometry puts 3-pixel cells behind 0.75-pixel gaps, which
// average into a grey smear, and the plate's corner radius bites into the
// corner cells. So the small sizes get their own proportions - full bleed, and
// half the padding - chosen to land every edge on a whole pixel at 16.
enum Geo SMALL = Geo(0, 64, 14, 4, 16, 4, 3);

Geo geometry(int size) { return size < 32 ? SMALL : NORMAL; }

// Coverage test for one rounded rectangle, by clamping the point to the rect of
// corner centres: inside the straight edges that lands on the point itself.
bool in_round_rect(double px, double py, double x, double y, double w, double h, double r)
{
    if (px < x || py < y || px > x + w || py > y + h)
        return false;
    double cx = px < x + r ? x + r : (px > x + w - r ? x + w - r : px);
    double cy = py < y + r ? y + r : (py > y + h - r ? y + h - r : py);
    double dx = px - cx, dy = py - cy;
    return dx * dx + dy * dy <= r * r;
}

// The colour at one point in design space, or alpha 0 outside the plate.
RGBA sample(const ref Geo g, double x, double y)
{
    if (in_round_rect(x, y, g.plateInset, g.plateInset, g.plateSize, g.plateSize, g.plateR) == false)
        return RGBA(0, 0, 0, 0);

    foreach (int row, const RGBA[3] line; CELLS)
        foreach (int col, RGBA c; line)
        {
            if (in_round_rect(x, y, g.cellAt(col), g.cellAt(row), g.cellSize, g.cellSize, g.cellR))
                return c;
        }
    return PLATE;
}

struct Image
{
    int size;
    RGBA[] px;
}

// 4x4 subsamples per pixel: enough to keep the plate's corner arc clean at 16,
// where the whole radius is barely three pixels across.
enum int SUPERSAMPLE = 4;

Image render(int size)
{
    Image img;
    img.size = size;
    img.px = new RGBA[size * size];

    const Geo geo = geometry(size);
    const double unit = size / 64.0;
    const double step = 1.0 / SUPERSAMPLE;

    for (int y; y < size; ++y)
        for (int x; x < size; ++x)
        {
            uint r, g, b, hits;
            foreach (int j; 0 .. SUPERSAMPLE)
                foreach (int i; 0 .. SUPERSAMPLE)
                {
                    const double sx = (x + (i + 0.5) * step) / unit;
                    const double sy = (y + (j + 0.5) * step) / unit;
                    const RGBA c = sample(geo, sx, sy);
                    if (c.a == 0)
                        continue;
                    r += c.r; g += c.g; b += c.b;
                    ++hits;
                }

            enum uint total = SUPERSAMPLE * SUPERSAMPLE;
            // Straight alpha, so the colour is the average of the samples that
            // landed on the mark rather than of all of them.
            img.px[y * size + x] = hits == 0 ? RGBA(0, 0, 0, 0)
                : RGBA(cast(ubyte)(r / hits), cast(ubyte)(g / hits), cast(ubyte)(b / hits),
                    cast(ubyte)(255 * hits / total));
        }
    return img;
}

string hex(RGBA c)
{
    return format("#%02x%02x%02x", c.r, c.g, c.b);
}

// Carries NORMAL only: the small-size proportions exist to land on whole pixels
// at one raster size, which is not something a scalable master should bake in.
void write_svg(string path)
{
    enum Geo g = NORMAL;
    string s = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64">` ~ "\n";
    s ~= format(`  <rect x="%g" y="%g" width="%g" height="%g" rx="%g" fill="%s"/>` ~ "\n",
        g.plateInset, g.plateInset, g.plateSize, g.plateSize, g.plateR, hex(PLATE));
    foreach (int row, const RGBA[3] line; CELLS)
        foreach (int col, RGBA c; line)
        {
            s ~= format(`  <rect x="%g" y="%g" width="%g" height="%g" rx="%g" fill="%s"/>` ~ "\n",
                g.cellAt(col), g.cellAt(row), g.cellSize, g.cellSize, g.cellR, hex(c));
        }
    s ~= "</svg>\n";
    write(path, s);
}

void chunk(ref ubyte[] o, string type, const(ubyte)[] data)
{
    o ~= nativeToBigEndian(cast(uint)data.length)[];
    ubyte[] body_ = cast(ubyte[])type.dup ~ data;
    o ~= body_;
    o ~= nativeToBigEndian(crc32(0, body_))[];
}

void write_png(string path, const ref Image img)
{
    ubyte[] raw;
    raw.reserve(img.size * (1 + img.size * 4));
    for (int y; y < img.size; ++y)
    {
        raw ~= 0; // filter: none
        for (int x; x < img.size; ++x)
        {
            const RGBA c = img.px[y * img.size + x];
            raw ~= [c.r, c.g, c.b, c.a];
        }
    }

    ubyte[] ihdr;
    ihdr ~= nativeToBigEndian(cast(uint)img.size)[];
    ihdr ~= nativeToBigEndian(cast(uint)img.size)[];
    ihdr ~= [cast(ubyte)8, 6, 0, 0, 0];

    ubyte[] png = [0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'];
    chunk(png, "IHDR", ihdr);
    chunk(png, "IDAT", cast(ubyte[])compress(raw, 9));
    chunk(png, "IEND", null);
    write(path, png);
}

// 32-bit bottom-up BMP with a BITMAPV4HEADER, which is what the app loads.
//
// The rounded plate needs transparent corners, and SDL only reads an alpha
// channel out of a BMP when the masks are spelled out: BI_BITFIELDS plus a
// header of at least 56 bytes (SDL_bmp.c). V4 is the first standard header
// that size.
void write_bmp(string path, const ref Image img)
{
    const uint pixels = img.size * img.size * 4;
    enum uint OFFSET = 14 + 108;

    ubyte[] o = ['B', 'M'];
    o ~= nativeToLittleEndian(OFFSET + pixels)[];
    o ~= nativeToLittleEndian(cast(uint)0)[];
    o ~= nativeToLittleEndian(OFFSET)[];

    o ~= nativeToLittleEndian(cast(uint)108)[];
    o ~= nativeToLittleEndian(img.size)[];
    o ~= nativeToLittleEndian(img.size)[];
    o ~= nativeToLittleEndian(cast(ushort)1)[];
    o ~= nativeToLittleEndian(cast(ushort)32)[];
    o ~= nativeToLittleEndian(cast(uint)3)[];  // BI_BITFIELDS
    o ~= nativeToLittleEndian(pixels)[];
    o ~= nativeToLittleEndian(2835)[];         // 72 DPI, in pixels per metre
    o ~= nativeToLittleEndian(2835)[];
    o ~= nativeToLittleEndian(cast(uint)0)[];
    o ~= nativeToLittleEndian(cast(uint)0)[];
    o ~= nativeToLittleEndian(0x00ff0000u)[];  // red
    o ~= nativeToLittleEndian(0x0000ff00u)[];  // green
    o ~= nativeToLittleEndian(0x000000ffu)[];  // blue
    o ~= nativeToLittleEndian(0xff000000u)[];  // alpha
    o ~= nativeToLittleEndian(0x57696e20u)[];  // 'Win ', LCS_WINDOWS_COLOR_SPACE
    o.length += 36 + 12;                       // endpoints and gamma, unused

    for (int y = img.size - 1; y >= 0; --y)
        for (int x; x < img.size; ++x)
        {
            const RGBA c = img.px[y * img.size + x];
            o ~= [c.b, c.g, c.r, c.a];
        }
    write(path, o);
}

// Every size gets a PNG, for the desktop's own icon lookup and the Windows
// .ico. Only the one size source/icon.d hands to SDL gets a BMP.
enum int WINDOW_ICON_SIZE = 256;
immutable int[] SIZES = [256, 128, 64, 48, 32, 16];

void emit_icon()
{
    writeln("generating...");

    writeln("write: assets/icon/vddhx.svg");
    write_svg("assets/icon/vddhx.svg");

    foreach (int size; SIZES)
    {
        Image img = render(size);
        string stem = "assets/icon/vddhx-" ~ text(size);

        writeln("write: ", stem, ".png");
        write_png(stem ~ ".png", img);

        if (size != WINDOW_ICON_SIZE)
            continue;

        writeln("write: ", stem, ".bmp");
        write_bmp(stem ~ ".bmp", img);
    }
    writeln("done");
}

void main()
{
    mkdirRecurse("assets/icon");
    emit_icon();
}

