module thumbdrive_multiboot.layout;

import thumbdrive_multiboot.mode;
import thumbdrive_multiboot.versioning : appName;

/// Default ESP size (FAT32) for GRUB EFI.
enum ulong defaultEspBytes = 512UL * 1024 * 1024;

/// Service-only exFAT on installed mode (docs + tools).
enum ulong defaultServiceExfatBytes = 256UL * 1024 * 1024;

/// Default ISO/drop exFAT size when mode is Both (rest → Btrfs).
enum ulong defaultBothExfatBytes = 32UL * 1024 * 1024 * 1024;

/// Minimum disk we will plan for (ESP + service + tiny pool slack).
enum ulong minimumDiskBytes = 2UL * 1024 * 1024 * 1024;

struct LayoutOptions
{
    string volumeLabel = appName;
    ulong espBytes = defaultEspBytes;
    /// For Both: requested exFAT size. Ignored for Live (uses remainder) and
    /// Installed (uses serviceExfatBytes).
    ulong bothExfatBytes = defaultBothExfatBytes;
    ulong serviceExfatBytes = defaultServiceExfatBytes;
}

struct PartitionSpec
{
    string role; /// "esp" | "exfat" | "btrfs"
    string filesystem;
    string label;
    ulong sizeBytes; /// 0 = fill remaining
    string purpose;
}

struct LayoutPlan
{
    DriveMode mode;
    string volumeLabel;
    ulong diskSizeBytes;
    PartitionSpec[] partitions;
    bool hasIsoDropZone;
    bool hasBtrfsPool;
    string summary;
}

LayoutPlan planLayout(DriveMode mode, ulong diskSizeBytes, LayoutOptions opts = LayoutOptions.init)
{
    if (diskSizeBytes < minimumDiskBytes)
    {
        throw new Exception("Disk too small for Thumbdrive Multiboot (need at least ~2 GiB)");
    }

    LayoutPlan plan;
    plan.mode = mode;
    plan.volumeLabel = opts.volumeLabel.length ? opts.volumeLabel : appName;
    plan.diskSizeBytes = diskSizeBytes;

    PartitionSpec esp;
    esp.role = "esp";
    esp.filesystem = "fat32";
    esp.label = "TMB-EFI";
    esp.sizeBytes = opts.espBytes ? opts.espBytes : defaultEspBytes;
    esp.purpose = "UEFI System Partition (GRUB)";

    final switch (mode)
    {
    case DriveMode.liveIso:
        plan.hasIsoDropZone = true;
        plan.hasBtrfsPool = false;
        PartitionSpec drop;
        drop.role = "exfat";
        drop.filesystem = "exfat";
        drop.label = plan.volumeLabel;
        drop.sizeBytes = 0; // remainder
        drop.purpose = "ISO drop zone + service kit (Windows-visible)";
        plan.partitions = [esp, drop];
        plan.summary = "Live ISOs: ESP + exFAT for drag-and-drop ISOs and service files.";
        break;

    case DriveMode.installed:
        plan.hasIsoDropZone = false;
        plan.hasBtrfsPool = true;
        PartitionSpec service;
        service.role = "exfat";
        service.filesystem = "exfat";
        service.label = plan.volumeLabel;
        service.sizeBytes = opts.serviceExfatBytes ? opts.serviceExfatBytes
            : defaultServiceExfatBytes;
        service.purpose = "Service kit (README, version, docs, tools) — Windows-visible";
        PartitionSpec pool;
        pool.role = "btrfs";
        pool.filesystem = "btrfs";
        pool.label = "TMB-POOL";
        pool.sizeBytes = 0;
        pool.purpose = "Thin install pool (subvolumes, zstd compression)";
        plan.partitions = [esp, service, pool];
        plan.summary = "Installed OSes: ESP + small service exFAT + Btrfs pool.";
        break;

    case DriveMode.both:
        plan.hasIsoDropZone = true;
        plan.hasBtrfsPool = true;
        auto exfatSize = opts.bothExfatBytes ? opts.bothExfatBytes : defaultBothExfatBytes;
        if (esp.sizeBytes + exfatSize + (512UL * 1024 * 1024) >= diskSizeBytes)
        {
            throw new Exception(
                    "Both-mode exFAT size leaves too little room for Btrfs; shrink the ISO partition.");
        }
        PartitionSpec dropBoth;
        dropBoth.role = "exfat";
        dropBoth.filesystem = "exfat";
        dropBoth.label = plan.volumeLabel;
        dropBoth.sizeBytes = exfatSize;
        dropBoth.purpose = "ISO drop zone + service kit (Windows-visible)";
        PartitionSpec poolBoth;
        poolBoth.role = "btrfs";
        poolBoth.filesystem = "btrfs";
        poolBoth.label = "TMB-POOL";
        poolBoth.sizeBytes = 0;
        poolBoth.purpose = "Thin install pool (subvolumes, zstd compression)";
        plan.partitions = [esp, dropBoth, poolBoth];
        plan.summary = "Both: ESP + sized exFAT (ISOs) + Btrfs pool.";
        break;
    }

    return plan;
}

string formatBytes(ulong n)
{
    import std.format : format;

    enum ulong kib = 1024UL;
    enum ulong mib = kib * 1024;
    enum ulong gib = mib * 1024;
    if (n >= gib)
        return format("%.1f GiB", cast(double) n / gib);
    if (n >= mib)
        return format("%.1f MiB", cast(double) n / mib);
    if (n >= kib)
        return format("%.1f KiB", cast(double) n / kib);
    return format("%s B", n);
}

string describePlan(const LayoutPlan plan)
{
    import std.array : appender;
    import std.format : format;
    import thumbdrive_multiboot.mode : modeTitle;

    auto app = appender!string();
    app.put(format("%s — %s\n", modeTitle(plan.mode), plan.summary));
    app.put(format("Disk: %s  Label: %s\n", formatBytes(plan.diskSizeBytes), plan.volumeLabel));
    foreach (i, p; plan.partitions)
    {
        auto size = p.sizeBytes == 0 ? "remainder" : formatBytes(p.sizeBytes);
        app.put(format("  %s. %-6s %-6s  %s  — %s\n", i + 1, p.role, p.filesystem, size, p.purpose));
    }
    return app.data;
}
