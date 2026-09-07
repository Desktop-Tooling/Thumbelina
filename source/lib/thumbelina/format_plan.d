module thumbelina.format_plan;

import std.conv : to;

import thumbelina.disk;
import thumbelina.layout;
import thumbelina.mode;
import thumbelina.service_payload;

/// Destructive action the user must confirm before execute.
enum FormatScope
{
    /// Wipe whole disk GPT and create mode layout.
    wholeDisk,
    /// Reclaim/replace a single volume — see reconfigure.replaceVolume.
    replaceVolume
}

struct FormatRequest
{
    DiskInfo disk;
    DriveMode mode;
    LayoutOptions layoutOptions;
    FormatScope scope_ = FormatScope.wholeDisk;
    bool confirmDestructive;
}

struct FormatPlan
{
    FormatRequest request;
    LayoutPlan layout;
    string[] warnings;
    string[] steps;
    bool executable;
}

struct FormatResult
{
    bool success;
    string message;
}

FormatPlan buildFormatPlan(FormatRequest req)
{
    FormatPlan plan;
    plan.request = req;
    plan.layout = planLayout(req.mode, req.disk.sizeBytes, req.layoutOptions);

    if (!req.disk.removable)
        plan.warnings ~= "Disk is not flagged removable — double-check this is the USB stick.";
    if (req.disk.sizeBytes >= 512UL * 1024 * 1024 * 1024)
        plan.warnings ~= "Disk is ≥512 GiB; confirm you are not targeting an internal drive.";
    if (req.scope_ == FormatScope.replaceVolume)
        plan.warnings ~= "For single-volume replace use `thumbelina reconfigure --strategy replace-volume`.";

    plan.steps ~= "Verify device path: " ~ req.disk.devicePath;
    plan.steps ~= "Create GPT partition table";
    foreach (p; plan.layout.partitions)
    {
        auto size = p.sizeBytes == 0 ? "remainder" : formatBytes(p.sizeBytes);
        plan.steps ~= "Create " ~ p.filesystem ~ " partition (" ~ p.role ~ ", " ~ size ~ ") label=" ~ p.label;
    }
    plan.steps ~= "Install GRUB EFI to ESP (or stage grub.cfg if grub-install missing)";
    plan.steps ~= "Write service payload to exFAT volume ("
        ~ listServicePayloadFiles().length.to!string() ~ " entries)";
    if (plan.layout.hasBtrfsPool)
    {
        plan.steps ~= "Create Btrfs filesystem with zstd compression defaults";
        plan.steps ~= "Create baseline subvolumes (@shared_home)";
    }
    if (plan.layout.hasIsoDropZone)
        plan.steps ~= "Ensure isos/ folder on exFAT for drag-and-drop";

    version (Windows)
    {
        if (plan.layout.hasBtrfsPool)
            plan.warnings ~= "Windows cannot mkfs.btrfs natively — use Linux or `thumbelina helper-script` + VM/live USB.";
        else
            plan.steps ~= "Windows path: PowerShell Clear-Disk + FAT32/exFAT";
    }
    version (linux)
        plan.steps ~= "Linux path: wipefs/sgdisk/mkfs + mount + grub-install";

    plan.executable = req.confirmDestructive
        && req.scope_ == FormatScope.wholeDisk
        && req.disk.devicePath.length > 0;

    if (!req.confirmDestructive)
        plan.warnings ~= "Pass --yes / confirm in GUI before any wipe.";

    return plan;
}

string describeFormatPlan(const FormatPlan plan)
{
    import std.array : appender;
    import std.format : format;

    auto app = appender!string();
    app.put(describePlan(plan.layout));
    app.put("\nSteps:\n");
    foreach (i, s; plan.steps)
        app.put(format("  %s. %s\n", i + 1, s));
    if (plan.warnings.length)
    {
        app.put("\nWarnings:\n");
        foreach (w; plan.warnings)
            app.put("  - " ~ w ~ "\n");
    }
    app.put(plan.executable
            ? "\nStatus: READY (destructive confirm set)\n"
            : "\nStatus: DRY-RUN only (not executable yet)\n");
    return app.data;
}
