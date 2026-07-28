/// Reading document offsets the way ddhx's front-end reads them.
///
/// The omnibar's ':' mode takes the expressions ddhx's `goto` command takes, so
/// a position written one way in the terminal front-end means the same thing
/// here: a plain number in whatever base its prefix says, a signed step from the
/// caret, or a percentage of the document.
///
///   1234        decimal, the default base
///   0x1f40      hexadecimal
///   0b1011      binary
///   0755        octal, from the leading zero
///   +16 / -16   forward or back from where the caret is
///   %50         half way into the document, fractions allowed
///
/// Nothing here throws. The omnibar reads what is in its box on every frame it
/// draws, so a half-typed offset is the ordinary state rather than an error, and
/// paying for an exception object sixty times a second to say so would be silly.
/// Authors: dd
module address;

/// How an offset was written down.
enum AddressKind
{
    absolute, /// A plain number: the offset itself.
    relative, /// '+' or '-': a step from where the caret is.
    percent,  /// '%': a fraction of the document.
}

/// A parsed offset.
struct Address
{
    /// Whether the text spells out an offset at all. Everything below is only
    /// meaningful when this is true.
    bool ok;
    /// The offset landed outside the document and was pulled back to its edge.
    /// Worth saying out loud: "%150" and "+999999" are answered, not refused.
    bool clamped;
    /// How it was written.
    AddressKind kind;
    /// Where it resolves to, held within [0, size]. The end itself is a valid
    /// caret: it is the append slot one past the last byte.
    long pos;
}

/// Read an offset expression and resolve it against a document.
/// Params:
///     text = What the user typed, blanks and all.
///     caret = Where the caret is, for the relative forms.
///     size = Document size in bytes, for the percentage form and the clamp.
/// Returns: The offset, or a result with `ok` clear when the text is not one.
Address address_parse(const(char)[] text, long caret, long size)
{
    Address a;

    text = address_strip(text);
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
        if (per > 100.0) // past the end of the document; there is nothing beyond
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
    // Bases. Decimal is the default, the way ddhx's own scanner has it, so "10"
    // is ten and not sixteen however much a hex editor might suggest otherwise.
    assert(address_parse("10",     0, 4096).pos == 10);
    assert(address_parse("0x10",   0, 4096).pos == 0x10);
    assert(address_parse("0X1f40", 0, 65536).pos == 0x1f40);
    assert(address_parse("0b1011", 0, 4096).pos == 0b1011);
    assert(address_parse("0755",   0, 4096).pos == 493); // octal from the lead zero
    assert(address_parse("07",     0, 4096).pos == 7);   // too short to be octal: same either way
    assert(address_parse("  32  ", 0, 4096).pos == 32);  // blanks around it are nothing

    assert(address_parse("0x10", 0, 4096).kind == AddressKind.absolute);
    assert(address_parse("0x10", 0, 4096).ok);
    assert(address_parse("0x10", 0, 4096).clamped == false);

    // Relative, from wherever the caret is.
    assert(address_parse("+16", 100, 4096).pos == 116);
    assert(address_parse("-16", 100, 4096).pos == 84);
    assert(address_parse("+0x10", 100, 4096).pos == 116);
    assert(address_parse("+16", 100, 4096).kind == AddressKind.relative);

    // Percentages, fractions included.
    assert(address_parse("%50",   0, 1000).pos == 500);
    assert(address_parse("%0",    0, 1000).pos == 0);
    assert(address_parse("%100",  0, 1000).pos == 1000);
    assert(address_parse("%12.5", 0, 1000).pos == 125);
    assert(address_parse("%50",   0, 1000).kind == AddressKind.percent);

    // Outside the document, answered rather than refused.
    assert(address_parse("999", 0, 100).pos == 100);
    assert(address_parse("999", 0, 100).clamped);
    assert(address_parse("-16", 0, 100).pos == 0);
    assert(address_parse("-16", 0, 100).clamped);
    assert(address_parse("%150", 0, 100).pos == 100);
    assert(address_parse("%150", 0, 100).clamped);

    // Not offsets.
    assert(address_parse("", 0, 100).ok == false);
    assert(address_parse("   ", 0, 100).ok == false);
    assert(address_parse("0x", 0, 100).ok == false);   // a prefix and no digits
    assert(address_parse("0xzz", 0, 100).ok == false);
    assert(address_parse("0b2", 0, 100).ok == false);  // not a binary digit
    assert(address_parse("12ab", 0, 100).ok == false); // hex digits without the prefix
    assert(address_parse("+", 0, 100).ok == false);
    assert(address_parse("%", 0, 100).ok == false);
    assert(address_parse("%50.", 0, 100).ok == false);
    assert(address_parse("%1.2.3", 0, 100).ok == false);
    assert(address_parse("hello", 0, 100).ok == false);
    assert(address_parse("32 32", 0, 100).ok == false); // one offset, not two

    // Too large for a document offset at all, rather than silently wrapping.
    assert(address_parse("0xffffffffffffffff", 0, 100).ok == false);
}

private:

/// Trim the blanks off both ends of `text`.
const(char)[] address_strip(const(char)[] text)
{
    size_t start;
    size_t end = text.length;
    while (start < end && (text[start] == ' ' || text[start] == '\t'))
        ++start;
    while (end > start && (text[end - 1] == ' ' || text[end - 1] == '\t'))
        --end;
    return text[start .. end];
}

/// Read a whole number in the base its prefix names: 0x hex, 0b binary, a lead
/// zero octal, otherwise decimal. Returns false for anything else, a number too
/// large to be a document offset included - it is refused rather than wrapped.
bool address_number(const(char)[] text, out long value)
{
    text = address_strip(text);

    int radix = 10;
    // Each prefix needs a digit behind it, hence the length: "0x" alone is not a
    // number, and "07" is the same seven whether it is read as octal or decimal.
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
            return false; // past what an offset can hold
        value = value * radix + digit;
    }
    return true;
}

/// Read a percentage, with an optional fractional part: "50", "12.5".
bool address_percent(const(char)[] text, out double per)
{
    text = address_strip(text);

    double value = 0; // a double's .init is NaN, which would swallow every digit
    size_t at;
    for (; at < text.length && text[at] >= '0' && text[at] <= '9'; ++at)
        value = value * 10 + (text[at] - '0');
    if (at == 0)
        return false; // nothing before the point, or nothing at all

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
            return false; // a point with nothing behind it, or trailing junk
    }

    per = value;
    return true;
}

/// A hex digit's value, or -1. Bases below 16 are caught by the caller, which
/// knows its radix.
int address_digit(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/// Add, saturating rather than wrapping: an absurd step lands on the end of the
/// range and is clamped into the document from there.
long address_add(long a, long b)
{
    if (b > 0 && a > long.max - b)
        return long.max;
    if (b < 0 && a < long.min - b)
        return long.min;
    return a + b;
}
