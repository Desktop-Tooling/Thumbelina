module thumbelina.disk;

import std.conv : to;
import std.process : execute;
import std.string : strip;

/// Physical disk summary for the format UI.
struct DiskInfo
{
    string id; /// Stable-ish id (e.g. Windows PhysicalDrive number or /dev/sdX)
    string devicePath; /// \\.\PhysicalDriveN or /dev/sdX
    string model;
    string bus; /// USB, NVMe, etc. when known
    ulong sizeBytes;
    bool removable;
    string[] volumeLetters; /// Windows drive letters currently on this disk
}

interface DiskEnumerator
{
    DiskInfo[] listDisks();
}

/// Best-effort enumerator. Prefer Linux/sysfs or Windows Get-Disk; never guesses wipe targets.
final class HostDiskEnumerator : DiskEnumerator
{
    DiskInfo[] listDisks()
    {
        version (Windows)
            return listWindowsDisks();
        else version (linux)
            return listLinuxDisks();
        else
            return typeof(return).init;
    }
}

version (Windows)
{
    DiskInfo[] listWindowsDisks()
    {
        // PowerShell JSON is the least-fragile host probe without Win32 bindings yet.
        enum string script =
            "Get-Disk | Select-Object Number, FriendlyName, Size, BusType, "
            ~ "@{n='Removable';e={ $_.BusType -eq 'USB' -or $_.BusType -eq 'SD' }} "
            ~ "| ConvertTo-Json -Compress";

        auto run = execute(["powershell", "-NoProfile", "-Command", script]);
        if (run.status != 0 || !run.output.strip.length)
            return typeof(return).init;

        import std.json : parseJSON, JSONValue, JSONType;

        DiskInfo[] outDisks;
        auto root = parseJSON(run.output);
        JSONValue[] items;
        if (root.type == JSONType.array)
            items = root.array;
        else
            items = [root];

        foreach (item; items)
        {
            DiskInfo d;
            auto num = item["Number"].integer;
            d.id = num.to!string;
            d.devicePath = `\\.\PhysicalDrive` ~ d.id;
            if ("FriendlyName" in item && item["FriendlyName"].type != JSONType.null_)
                d.model = item["FriendlyName"].str;
            if ("BusType" in item && item["BusType"].type != JSONType.null_)
                d.bus = item["BusType"].str;
            if ("Size" in item)
                d.sizeBytes = cast(ulong) item["Size"].integer;
            if ("Removable" in item)
                d.removable = item["Removable"].type == JSONType.true_;
            outDisks ~= d;
        }
        return outDisks;
    }
}

version (linux)
{
    DiskInfo[] listLinuxDisks()
    {
        import std.file : dirEntries, SpanMode, readText, exists;
        import std.path : baseName, buildPath;
        import std.string : startsWith;

        DiskInfo[] outDisks;
        foreach (entry; dirEntries("/sys/block", SpanMode.shallow))
        {
            auto name = baseName(entry.name);
            if (name.startsWith("loop") || name.startsWith("ram") || name.startsWith("dm-"))
                continue;
            DiskInfo d;
            d.id = name;
            d.devicePath = "/dev/" ~ name;
            auto sizePath = buildPath(entry.name, "size");
            if (exists(sizePath))
            {
                // /sys/block/*/size is in 512-byte sectors
                auto sectors = readText(sizePath).strip.to!ulong;
                d.sizeBytes = sectors * 512UL;
            }
            auto removablePath = buildPath(entry.name, "removable");
            if (exists(removablePath))
                d.removable = readText(removablePath).strip == "1";
            auto modelPath = buildPath(entry.name, "device/model");
            if (exists(modelPath))
                d.model = readText(modelPath).strip;
            outDisks ~= d;
        }
        return outDisks;
    }
}

string describeDisk(const DiskInfo d)
{
    import std.format : format;
    import thumbelina.layout : formatBytes;

    return format("[%s] %s  %s  %s  %s",
            d.id,
            d.devicePath,
            d.model.length ? d.model : "(unknown model)",
            formatBytes(d.sizeBytes),
            d.removable ? "removable" : "fixed?");
}
