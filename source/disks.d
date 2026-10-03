/// The disks and volumes this machine has, for the omnibar's Open Disk prompt.
///
/// Listing asks for no access to the media themselves, so it works unelevated;
/// opening one is what may need more.
module disks;

import std.format : format;

struct Disk
{
    /// What FileDocument opens.
    string path;
    /// Model, or volume label; empty when the system has neither.
    string name;
    /// Bytes, 0 when unknown.
    long size;
    /// A partition or volume rather than a whole device.
    bool part;
}

version (Windows)    enum bool DISKS_LISTED = true;
else version (linux) enum bool DISKS_LISTED = true;
else                 enum bool DISKS_LISTED = false;

/// Every disk, each followed by its partitions. Empty where DISKS_LISTED is false
/// or nothing could be read.
Disk[] disks_list()
{
    try
        return disks_scan();
    catch (Exception)
        return null;
}

/// `size` as the largest binary unit it reaches, "931.5 GiB".
string disks_size(long size)
{
    static immutable string[] UNITS = [ "B", "KiB", "MiB", "GiB", "TiB", "PiB" ];
    double n = size;
    size_t u;
    while (n >= 1024 && u + 1 < UNITS.length)
    {
        n /= 1024;
        ++u;
    }
    return u ? format("%.1f %s", n, UNITS[u]) : format("%d B", size);
}
unittest
{
    assert(disks_size(512) == "512 B");
    assert(disks_size(1536) == "1.5 KiB");
    assert(disks_size(1000204886016) == "931.5 GiB");
}

private:

version (linux)
Disk[] disks_scan()
{
    import std.algorithm.sorting : sort;
    import std.file : DirEntry, SpanMode, dirEntries, exists;
    import std.path : baseName;
    import std.string : startsWith;

    string[string] labels = labelsByDevice();

    Disk[] list;
    string[] devs;
    foreach (DirEntry e; dirEntries("/sys/block", SpanMode.shallow))
        devs ~= baseName(e.name);
    sort!byNumber(devs);

    foreach (string dev; devs)
    {
        // Memory-backed: swap, ramdisks, and the loops every snap mounts.
        if (dev.startsWith("loop") || dev.startsWith("ram") || dev.startsWith("zram"))
            continue;
        string sys = "/sys/block/" ~ dev;
        long sectors = sysLong(sys ~ "/size");
        if (sectors == 0) // empty card reader, ejected disc
            continue;

        string name = sysText(sys ~ "/device/model");
        if (name.length == 0)
            name = sysText(sys ~ "/dm/name");
        list ~= Disk("/dev/" ~ dev, name, sectors * 512);

        string[] parts;
        foreach (DirEntry p; dirEntries(sys, SpanMode.shallow))
            if (exists(p.name ~ "/partition"))
                parts ~= baseName(p.name);
        sort!byNumber(parts);
        foreach (string part; parts)
        {
            string* label = part in labels;
            list ~= Disk("/dev/" ~ part, label ? *label : null,
                sysLong(sys ~ "/" ~ part ~ "/size") * 512, true);
        }
    }
    return list;
}

version (linux)
{
    /// sdb before sda10, by putting the shorter name first.
    bool byNumber(string a, string b)
    {
        return a.length != b.length ? a.length < b.length : a < b;
    }

    /// The `/sys` value as text, trimmed; empty when it is not there.
    string sysText(string path)
    {
        import std.file : readText;
        import std.string : strip;
        try
            return readText(path).strip;
        catch (Exception)
            return null;
    }

    long sysLong(string path)
    {
        import std.conv : to;
        try
            return sysText(path).to!long;
        catch (Exception)
            return 0;
    }

    /// Filesystem labels by device name, out of udev's `/dev/disk/by-label`, where
    /// a name escapes its spaces and slashes as `\x20`.
    string[string] labelsByDevice()
    {
        import std.conv : to;
        import std.file : DirEntry, SpanMode, dirEntries, readLink;
        import std.path : baseName;

        string[string] labels;
        try
        {
            foreach (DirEntry e; dirEntries("/dev/disk/by-label", SpanMode.shallow))
            {
                string link = baseName(e.name);
                char[] label;
                for (size_t i; i < link.length; ++i)
                {
                    if (link[i] == '\\' && i + 3 < link.length && link[i + 1] == 'x')
                    {
                        label ~= cast(char) link[i + 2 .. i + 4].to!ubyte(16);
                        i += 3;
                    }
                    else
                        label ~= link[i];
                }
                labels[baseName(readLink(e.name))] = cast(string) label;
            }
        }
        catch (Exception) {} // no udev, as in most containers
        return labels;
    }
}

version (Windows)
Disk[] disks_scan()
{
    import core.sys.windows.windows;
    import std.utf : toUTF16z;

    Disk[] list;

    // Numbered from zero but with gaps where a disk was pulled, so every slot a
    // machine plausibly has is tried. Access 0 opens without admin, and both
    // ioctls below are FILE_ANY_ACCESS.
    foreach (int i; 0 .. 64)
    {
        string path = format(`\\.\PhysicalDrive%d`, i);
        HANDLE h = CreateFileW(path.toUTF16z, 0, FILE_SHARE_READ | FILE_SHARE_WRITE,
            null, OPEN_EXISTING, 0, null);
        if (h == INVALID_HANDLE_VALUE)
            continue;
        scope(exit) CloseHandle(h);
        list ~= Disk(path, deviceModel(h), deviceSize(h));
    }

    // Volumes by letter. Their length ioctl wants read access, so the size is the
    // filesystem's, which is what Explorer shows for one anyway.
    DWORD letters = GetLogicalDrives();
    foreach (int i; 0 .. 26)
    {
        if ((letters & (1 << i)) == 0)
            continue;
        char letter = cast(char)('A' + i);
        wchar[4] root = [ letter, ':', '\\', 0 ];
        switch (GetDriveTypeW(root.ptr))
        {
        case DRIVE_FIXED, DRIVE_REMOVABLE, DRIVE_CDROM, DRIVE_RAMDISK: break;
        default: continue; // network shares are not block devices
        }

        wchar[MAX_PATH + 1] label = void;
        string name;
        if (GetVolumeInformationW(root.ptr, label.ptr, label.length,
                null, null, null, null, 0))
            name = fromWide(label.ptr);

        ULARGE_INTEGER total;
        long size = GetDiskFreeSpaceExW(root.ptr, null, &total, null) ?
            cast(long) total.QuadPart : 0;
        list ~= Disk(format(`\\.\%s:`, letter), name, size, true);
    }
    return list;
}

version (Windows)
{
    import core.sys.windows.windows : DeviceIoControl, DWORD, HANDLE;

    enum DWORD IOCTL_DISK_GET_DRIVE_GEOMETRY_EX = 0x000700A0;
    enum DWORD IOCTL_STORAGE_QUERY_PROPERTY     = 0x002D1400;

    long deviceSize(HANDLE h)
    {
        // DISK_GEOMETRY_EX: a 24-byte DISK_GEOMETRY, then the size.
        ubyte[256] buf = void;
        DWORD got;
        if (DeviceIoControl(h, IOCTL_DISK_GET_DRIVE_GEOMETRY_EX, null, 0,
                buf.ptr, buf.length, &got, null) == 0 || got < 32)
            return 0;
        return *cast(long*) &buf[24];
    }

    /// Vendor and product out of the STORAGE_DEVICE_DESCRIPTOR, which carries them
    /// as offsets to C strings within itself.
    string deviceModel(HANDLE h)
    {
        import std.string : strip;

        uint[3] query; // StorageDeviceProperty, PropertyStandardQuery, no parameters
        ubyte[1024] buf = void;
        DWORD got;
        if (DeviceIoControl(h, IOCTL_STORAGE_QUERY_PROPERTY, query.ptr, query.sizeof,
                buf.ptr, buf.length, &got, null) == 0 || got < 20)
            return null;

        string at(size_t field)
        {
            uint off = *cast(uint*) &buf[field];
            if (off == 0 || off >= got)
                return null;
            size_t end = off;
            while (end < got && buf[end])
                ++end;
            return (cast(char[]) buf[off .. end]).idup.strip;
        }
        string vendor = at(12), product = at(16);
        return vendor.length ? vendor ~ " " ~ product : product;
    }

    string fromWide(const(wchar)* s)
    {
        import std.utf : toUTF8;
        size_t n;
        while (s[n])
            ++n;
        return toUTF8(s[0 .. n]);
    }
}

static if (DISKS_LISTED == false)
Disk[] disks_scan()
{
    return null;
}
