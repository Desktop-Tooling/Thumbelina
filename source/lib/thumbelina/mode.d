module thumbelina.mode;

/// How the stick is laid out. Reconfigurable later (may require migrate/wipe).
enum DriveMode
{
    /// ESP + large exFAT (ISOs + service kit). No Btrfs pool.
    liveIso,

    /// ESP + small service exFAT + Btrfs install pool.
    installed,

    /// ESP + sized exFAT (ISOs + service kit) + remaining Btrfs pool.
    both
}

string modeId(DriveMode mode)
{
    final switch (mode)
    {
    case DriveMode.liveIso:
        return "live-iso";
    case DriveMode.installed:
        return "installed";
    case DriveMode.both:
        return "both";
    }
}

string modeTitle(DriveMode mode)
{
    final switch (mode)
    {
    case DriveMode.liveIso:
        return "Live ISOs";
    case DriveMode.installed:
        return "Installed OSes";
    case DriveMode.both:
        return "Live ISOs + installed OSes";
    }
}

string modeBlurb(DriveMode mode)
{
    final switch (mode)
    {
    case DriveMode.liveIso:
        return "Ventoy-like: drag installer/live ISOs onto the Windows-visible volume. Best for rescue/toolkit sticks.";
    case DriveMode.installed:
        return "Thin Btrfs subvolumes for full distro installs, plus a small branded service volume so Windows still shows what the stick is.";
    case DriveMode.both:
        return "ISO drop zone and Btrfs install pool on one stick. Use when capacity allows; otherwise prefer two specialized sticks.";
    }
}

DriveMode parseDriveMode(string id)
{
    import std.string : toLower, strip;

    auto s = id.strip().toLower();
    if (s == "live" || s == "live-iso" || s == "iso" || s == "liveiso")
        return DriveMode.liveIso;
    if (s == "installed" || s == "install" || s == "os" || s == "btrfs")
        return DriveMode.installed;
    if (s == "both" || s == "hybrid" || s == "all")
        return DriveMode.both;
    throw new Exception("Unknown drive mode: " ~ id
            ~ " (expected live-iso, installed, or both)");
}
