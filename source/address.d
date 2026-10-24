/// Offset expressions, as ddhx's `goto` takes them (omnibar ':' mode):
///
///   1234        decimal (default)
///   0x1f40      hexadecimal
///   0b1011      binary
///   0755        octal (leading zero)
///   +16 / -16   relative to the caret
///   %50         percent of the document, fractions allowed
///
/// Never throws: the omnibar reparses partial input every frame.
/// Authors: dd86k <dd@dax.moe>
module address;

import std.string : strip;

/// Kind of address (absolute, relative, etc.) so goto command knows how to deal with input.
enum AddressKind
{
    absolute, /// Plain offset.
    relative, /// '+' or '-', relative to the caret.
    percent,  /// '%', fraction of the document.
}

/// Parsed address/offset.
struct Address
{
    // NOTE: Packing
    //       I like bit fields but useless if structure is just used once and not in a tight loop
    
    /// Valid offset. Other fields are meaningless if false.
    bool ok;
    /// Was out of range and clamped ("%150", "+999999" still resolve).
    bool clamped;
    /// Address kind for goto command.
    AddressKind kind;
    /// Resolved offset/address value. End (EOF) is still valid, it's the append slot.
    long pos;
}

/// Parse an offset expression against a document of `size` bytes.
/// Returns: Resolved Address instance. Check Address.ok if valid.
Address address_parse(const(char)[] text, long caret, long size) pure nothrow @safe @nogc
{
    Address a;

    text = strip(text);
    if (text.length == 0)
        return a;

    long value;
    switch (text[0])
    {
    case '+', '-':
        if (address_number(text[1 .. $], value) == false)
            return a;
        a.kind = AddressKind.relative;
        a.pos  = address_add(caret, text[0] == '+' ? value : -value);
        break;
    case '%':
        double per;
        if (address_percent(text[1 .. $], per) == false)
            return a;
        a.kind = AddressKind.percent;
        if (per > 100.0)
        {
            per = 100.0;
            a.clamped = true;
        }
        a.pos = cast(long)(size * (per / 100.0));
        break;
    default:
        if (address_number(text, value) == false)
            return a;
        a.kind = AddressKind.absolute;
        a.pos  = value;
    }

    a.ok = true;
    if (a.pos < 0)
    {
        a.pos = 0;
        a.clamped = true;
    }
    if (a.pos > size)
    {
        a.pos = size;
        a.clamped = true;
    }
    return a;
}

unittest
{
    import std.conv : octal;
    // Decimal
    assert(address_parse("10",     0, 4096).pos == 10);
    assert(address_parse("  32  ", 0, 4096).pos == 32);
    // Hex
    assert(address_parse("0x10",   0, 4096).pos == 0x10);
    assert(address_parse("0X1f40", 0, 65536).pos == 0x1f40);
    // Octal
    assert(address_parse("0755",   0, 4096).pos == octal!755);
    assert(address_parse("07",     0, 4096).pos == octal!7);
    // Bit
    assert(address_parse("0b1011", 0, 4096).pos == 0b1011);

    // Check fields
    Address x10 = address_parse("0x10", 0, 4096);
    assert(x10.kind == AddressKind.absolute);
    assert(x10.ok);
    assert(x10.clamped == false);

    // Relative from cursor position
    assert(address_parse("+16", 100, 4096).pos == 116);
    assert(address_parse("-16", 100, 4096).pos == 84);
    assert(address_parse("+0x10", 100, 4096).pos == 116);
    assert(address_parse("+16", 100, 4096).kind == AddressKind.relative);

    // Percentage, depending on document size
    assert(address_parse("%50",   0, 1000).pos == 500);
    assert(address_parse("%0",    0, 1000).pos == 0);
    assert(address_parse("%100",  0, 1000).pos == 1000);
    assert(address_parse("%12.5", 0, 1000).pos == 125);
    assert(address_parse("%50",   0, 1000).kind == AddressKind.percent);

    // Out of range: clamped.
    assert(address_parse("999", 0, 100).pos == 100);
    assert(address_parse("999", 0, 100).clamped);
    assert(address_parse("-16", 0, 100).pos == 0);
    assert(address_parse("-16", 0, 100).clamped);
    assert(address_parse("%150", 0, 100).pos == 100);
    assert(address_parse("%150", 0, 100).clamped);

    // Invalid.
    assert(address_parse("", 0, 100).ok == false);
    assert(address_parse("   ", 0, 100).ok == false);
    assert(address_parse("0x", 0, 100).ok == false);   // prefix only
    assert(address_parse("0xzz", 0, 100).ok == false);
    assert(address_parse("0b2", 0, 100).ok == false);
    assert(address_parse("12ab", 0, 100).ok == false); // hex digits need the prefix
    assert(address_parse("+", 0, 100).ok == false);
    assert(address_parse("%", 0, 100).ok == false);
    assert(address_parse("%50.", 0, 100).ok == false);
    assert(address_parse("%1.2.3", 0, 100).ok == false);
    assert(address_parse("hello", 0, 100).ok == false);
    assert(address_parse("32 32", 0, 100).ok == false);

    // Overflow is refused, not wrapped.
    assert(address_parse("0xffffffffffffffff", 0, 100).ok == false);
}

private:

/// Parse an integer in the base its prefix names (0x, 0b, leading 0, else
/// decimal). Refuses overflow.
bool address_number(const(char)[] text, out long value) pure nothrow @safe @nogc
{
    text = strip(text);

    int radix = 10;
    // Prefixes need a digit after; "07" is 7 in either base.
    // And no, std.conv.parse does not do any prefix detection.
    if (text.length > 2 && text[0] == '0' && (text[1] == 'x' || text[1] == 'X'))
    {
        radix = 16;
        text = text[2 .. $];
    }
    else if (text.length > 2 && text[0] == '0' && (text[1] == 'b' || text[1] == 'B'))
    {
        radix = 2;
        text = text[2 .. $];
    }
    else if (text.length > 2 && text[0] == '0')
    {
        radix = 8;
        text = text[1 .. $];
    }
    if (text.length == 0)
        return false;

    foreach (char c; text)
    {
        int digit = address_digit(c);
        if (digit < 0 || digit >= radix)
            return false;
        if (value > (long.max - digit) / radix)
            return false; // overflow
        value = value * radix + digit;
    }
    return true;
}

/// Parse a percentage, e.g. "50", "12.5".
bool address_percent(const(char)[] text, out double per) pure nothrow @safe @nogc
{
    text = strip(text);

    double value = 0; // .init is NaN
    size_t at;
    for (; at < text.length && text[at] >= '0' && text[at] <= '9'; ++at)
        value = value * 10 + (text[at] - '0');
    if (at == 0)
        return false; // no integer part

    if (at < text.length)
    {
        if (text[at] != '.')
            return false;
        ++at;

        size_t start = at;
        double scale = 0.1;
        for (; at < text.length && text[at] >= '0' && text[at] <= '9'; ++at)
        {
            value += (text[at] - '0') * scale;
            scale /= 10;
        }
        if (at == start || at < text.length)
            return false; // no digits after the point, or trailing junk
    }

    per = value;
    return true;
}

/// Hex digit value, or -1. Caller range-checks narrower bases.
int address_digit(char c) pure nothrow @safe @nogc
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/// Saturating add. The result gets clamped to the document afterwards.
long address_add(long a, long b) pure nothrow @safe @nogc
{
    if (b > 0 && a > long.max - b)
        return long.max;
    if (b < 0 && a < long.min - b)
        return long.min;
    return a + b;
}
