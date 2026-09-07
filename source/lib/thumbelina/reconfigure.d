module thumbelina.reconfigure;

import std.array : appender;
import std.format : format;

import thumbelina.format_plan;
import thumbelina.layout;
import thumbelina.mode;

/// How aggressively to change an existing stick.
enum ReconfigureStrategy
{
    /// Only rewrite service payload + grub.cfg (safe).
    refreshMetadata,
    /// Change mode by recreating partitions — data loss on affected volumes.
    changeModeDestructive,
    /// Replace/reclaim one volume role (exFAT or Btrfs) — data loss on that volume.
    replaceVolume
}

struct ReconfigureRequest
{
    DiskInfo disk;
    DriveMode currentMode = DriveMode.liveIso;
    DriveMode targetMode;
    LayoutOptions layoutOptions;
    ReconfigureStrategy strategy = ReconfigureStrategy.refreshMetadata;
    bool confirmDestructive;
    /// For replaceVolume: "exfat" or "btrfs"
    string volumeRole;
}

struct ReconfigurePlan
{
    ReconfigureRequest request;
    string[] steps;
    string[] warnings;
    string[] dataLoss;
    bool executable;
    LayoutPlan targetLayout;
}

import thumbelina.disk;

ReconfigurePlan buildReconfigurePlan(ReconfigureRequest req)
{
    ReconfigurePlan plan;
    plan.request = req;
    plan.targetLayout = planLayout(req.targetMode, req.disk.sizeBytes, req.layoutOptions);

    final switch (req.strategy)
    {
    case ReconfigureStrategy.refreshMetadata:
        plan.steps ~= "Mount ESP and exFAT";
        plan.steps ~= "Rewrite service payload (VERSION/instance/docs)";
        plan.steps ~= "Scan isos/ and Btrfs subvolumes";
        plan.steps ~= "Regenerate grub.cfg on ESP";
        plan.executable = true; // non-destructive
        break;

    case ReconfigureStrategy.changeModeDestructive:
        plan.warnings ~= "Mode change rewrites the partition table for the new layout.";
        plan.dataLoss ~= "All partitions on " ~ req.disk.devicePath ~ " will be wiped.";
        plan.steps ~= "Confirm target disk " ~ req.disk.devicePath;
        plan.steps ~= format("Change mode %s → %s", modeId(req.currentMode), modeId(req.targetMode));
        foreach (p; plan.targetLayout.partitions)
        {
            auto size = p.sizeBytes == 0 ? "remainder" : formatBytes(p.sizeBytes);
            plan.steps ~= "Recreate " ~ p.filesystem ~ " (" ~ p.role ~ ", " ~ size ~ ")";
        }
        plan.steps ~= "Write service payload + GRUB";
        plan.executable = req.confirmDestructive;
        if (!req.confirmDestructive)
            plan.warnings ~= "Pass --yes to allow destructive mode change.";
        break;

    case ReconfigureStrategy.replaceVolume:
        if (req.volumeRole != "exfat" && req.volumeRole != "btrfs")
            plan.warnings ~= "volumeRole must be 'exfat' or 'btrfs'";
        plan.dataLoss ~= "Contents of the " ~ req.volumeRole ~ " volume will be erased.";
        plan.steps ~= "Identify " ~ req.volumeRole ~ " partition on " ~ req.disk.devicePath;
        plan.steps ~= "Unmount and recreate filesystem on that partition";
        if (req.volumeRole == "exfat")
            plan.steps ~= "Rewrite service payload and isos/ skeleton";
        if (req.volumeRole == "btrfs")
            plan.steps ~= "Recreate @shared_home baseline subvolume";
        plan.steps ~= "Regenerate grub.cfg";
        plan.executable = req.confirmDestructive && (req.volumeRole == "exfat" || req.volumeRole == "btrfs");
        if (!req.confirmDestructive)
            plan.warnings ~= "Pass --yes to allow volume replace.";
        break;
    }

    return plan;
}

string describeReconfigurePlan(const ReconfigurePlan plan)
{
    auto app = appender!string();
    app.put(format("Reconfigure strategy: %s\n", plan.request.strategy));
    app.put(format("Mode: %s → %s\n", modeId(plan.request.currentMode), modeId(plan.request.targetMode)));
    app.put(describePlan(plan.targetLayout));
    app.put("\nSteps:\n");
    foreach (i, s; plan.steps)
        app.put(format("  %s. %s\n", i + 1, s));
    if (plan.dataLoss.length)
    {
        app.put("\nDATA LOSS:\n");
        foreach (d; plan.dataLoss)
            app.put("  ! " ~ d ~ "\n");
    }
    if (plan.warnings.length)
    {
        app.put("\nWarnings:\n");
        foreach (w; plan.warnings)
            app.put("  - " ~ w ~ "\n");
    }
    app.put(plan.executable ? "\nStatus: READY\n" : "\nStatus: NOT EXECUTABLE yet\n");
    return app.data;
}

struct ReconfigureResult
{
    bool success;
    string message;
}

ReconfigureResult executeReconfigure(const ReconfigurePlan plan,
        string espMount = null, string exfatMount = null, string btrfsMount = null)
{
    import thumbelina.grub;
    import thumbelina.service_payload;
    import thumbelina.format_execute : executeFormat, FormatExecuteOptions;
    import std.datetime.systime : Clock;
    import std.uuid : randomUUID;

    if (!plan.executable)
        return ReconfigureResult(false, "Reconfigure plan is not executable (need --yes?).");

    try
    {
        final switch (plan.request.strategy)
        {
        case ReconfigureStrategy.refreshMetadata:
            if (!exfatMount.length || !espMount.length)
                return ReconfigureResult(false, "refreshMetadata requires --esp and --exfat mount paths");
            ServicePayloadOptions opts;
            opts.mode = plan.request.targetMode;
            opts.instanceId = randomUUID().toString();
            opts.createdAtIso = Clock.currTime.toUTC().toISOExtString();
            writeServicePayload(exfatMount, opts);
            GrubMenuModel menu;
            menu.mode = plan.request.targetMode;
            menu.isos = scanIsos(exfatMount);
            if (btrfsMount.length)
                menu.installs = scanInstalls(btrfsMount);
            writeGrubCfgToEsp(espMount, generateGrubCfg(menu));
            return ReconfigureResult(true, "Refreshed service payload and grub.cfg");

        case ReconfigureStrategy.changeModeDestructive:
            FormatRequest freq;
            freq.disk = cast() plan.request.disk;
            freq.mode = plan.request.targetMode;
            freq.layoutOptions = cast() plan.request.layoutOptions;
            freq.confirmDestructive = true;
            freq.scope_ = FormatScope.wholeDisk;
            auto fplan = buildFormatPlan(freq);
            auto fres = executeFormat(fplan);
            return ReconfigureResult(fres.success, fres.message);

        case ReconfigureStrategy.replaceVolume:
            version (linux)
                return replaceVolumeLinux(plan, espMount, exfatMount, btrfsMount);
            else
                return ReconfigureResult(false,
                        "replaceVolume execute currently requires Linux (use helper script from Windows).");
        }
    }
    catch (Exception ex)
    {
        return ReconfigureResult(false, ex.msg);
    }
}

version (linux)
{
    import thumbelina.procutil;
    import thumbelina.service_payload;
    import thumbelina.grub;
    import std.datetime.systime : Clock;
    import std.uuid : randomUUID;

    ReconfigureResult replaceVolumeLinux(const ReconfigurePlan plan,
            string espMount, string exfatMount, string btrfsMount)
    {
        // Caller must pass the partition device via disk.devicePath meaning the VOLUME device
        // For simplicity: expect plan.request.disk.devicePath to be the partition to reformat
        // when volumeRole is set — documented in CLI.
        auto part = plan.request.disk.devicePath;
        if (plan.request.volumeRole == "exfat")
        {
            enforceOk(runArgv([
                    "mkfs.exfat", "-n", "THUMBELINA", part
            ]), "mkfs.exfat replace");
            if (!exfatMount.length)
                return ReconfigureResult(false, "Provide --exfat mount path after recreating FS");
            // assume already remounted by caller
            ServicePayloadOptions opts;
            opts.mode = plan.request.targetMode;
            opts.instanceId = randomUUID().toString();
            opts.createdAtIso = Clock.currTime.toUTC().toISOExtString();
            writeServicePayload(exfatMount, opts);
        }
        else if (plan.request.volumeRole == "btrfs")
        {
            enforceOk(runArgv(["mkfs.btrfs", "-f", "-L", "THUMBELINA-POOL", part]), "mkfs.btrfs replace");
            if (!btrfsMount.length)
                return ReconfigureResult(false, "Provide --btrfs mount path after recreating FS");
            enforceOk(runArgv(["btrfs", "subvolume", "create", btrfsMount ~ "/@shared_home"]),
                    "create @shared_home");
        }
        if (espMount.length && exfatMount.length)
        {
            GrubMenuModel menu;
            menu.mode = plan.request.targetMode;
            menu.isos = scanIsos(exfatMount);
            if (btrfsMount.length)
                menu.installs = scanInstalls(btrfsMount);
            writeGrubCfgToEsp(espMount, generateGrubCfg(menu));
        }
        return ReconfigureResult(true, "Replaced " ~ plan.request.volumeRole ~ " volume on " ~ part);
    }
}
