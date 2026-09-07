module app;

import std.conv : to;
import std.datetime.systime : Clock;
import std.file : mkdirRecurse, tempDir;
import std.getopt : getopt, config;
import std.path : buildPath;
import std.stdio : writeln, writefln, stderr;
import std.uuid : randomUUID;

import thumbdrive_multiboot;

int main(string[] args)
{
    if (args.length < 2)
    {
        printHelp();
        return 1;
    }

    auto cmd = args[1];
    auto rest = args[0] ~ args[2 .. $];

    try
    {
        switch (cmd)
        {
        case "help":
        case "--help":
        case "-h":
            printHelp();
            return 0;
        case "version":
        case "--version":
            writeln(versionLine());
            return 0;
        case "modes":
            return cmdModes();
        case "disks":
            return cmdDisks();
        case "plan":
            return cmdPlan(rest);
        case "format":
            return cmdFormat(rest);
        case "helper-script":
            return cmdHelperScript(rest);
        case "write-payload":
            return cmdWritePayload(rest);
        case "refresh-boot":
            return cmdRefreshBoot(rest);
        case "install":
            return cmdInstall(rest);
        case "remove-os":
            return cmdRemoveOs(rest);
        case "snapshot":
            return cmdSnapshot(rest);
        case "reconfigure":
            return cmdReconfigure(rest);
        case "debug-dump":
            return cmdDebugDump();
        case "about":
            return cmdAbout();
        default:
            stderr.writefln("Unknown command: %s", cmd);
            printHelp();
            return 1;
        }
    }
    catch (Exception ex)
    {
        stderr.writefln("error: %s", ex.msg);
        return 2;
    }
}

void printHelp()
{
    writeln(versionLine());
    writeln();
    writeln("Usage: tmb <command> [options]");
    writeln();
    writeln("Commands:");
    writeln("  modes              List drive modes");
    writeln("  disks              List physical disks");
    writeln("  plan               Dry-run a format layout plan");
    writeln("  format             Format disk (--yes required; Linux full / Windows live-iso)");
    writeln("  helper-script      Write linux-format.sh + plan JSON for VM/live use");
    writeln("  write-payload      Write service kit into a mounted exFAT path");
    writeln("  refresh-boot       Regenerate grub.cfg from mounted ESP/exFAT[/btrfs]");
    writeln("  install            Bootstrap a distro into a Btrfs subvolume (Linux)");
    writeln("  remove-os          Delete an installed subvolume (Linux)");
    writeln("  snapshot           Snapshot an installed subvolume (Linux)");
    writeln("  reconfigure        Refresh metadata, change mode, or replace a volume");
    writeln("  debug-dump         Redacted debug dump");
    writeln("  about | version | help");
}

int cmdModes()
{
    foreach (m; [DriveMode.liveIso, DriveMode.installed, DriveMode.both])
    {
        writefln("%-10s  %s", modeId(m), modeTitle(m));
        writefln("            %s", modeBlurb(m));
        writeln();
    }
    return 0;
}

int cmdDisks()
{
    auto disks = new HostDiskEnumerator().listDisks();
    if (!disks.length)
    {
        writeln("No disks reported.");
        return 0;
    }
    foreach (d; disks)
        writeln(describeDisk(d));
    return 0;
}

FormatRequest parseFormatRequest(string[] args, bool requireDisk, bool yesDefault = false)
{
    string modeStr = "live-iso";
    string diskId;
    double sizeGib = 64;
    double exfatGib = 32;
    string label = appName;
    bool yes = yesDefault;
    getopt(args, config.passThrough,
            "mode", &modeStr,
            "disk", &diskId,
            "size-gib", &sizeGib,
            "exfat-gib", &exfatGib,
            "label", &label,
            "yes", &yes);

    DiskInfo disk;
    if (diskId.length)
        disk = findDisk(diskId);
    else if (requireDisk)
        throw new Exception("--disk is required");
    else
    {
        disk.id = "synthetic";
        disk.devicePath = "(plan-only)";
        disk.model = "synthetic";
        disk.sizeBytes = cast(ulong)(sizeGib * 1024 * 1024 * 1024);
        disk.removable = true;
    }

    LayoutOptions opts;
    opts.volumeLabel = label;
    opts.bothExfatBytes = cast(ulong)(exfatGib * 1024 * 1024 * 1024);

    FormatRequest req;
    req.disk = disk;
    req.mode = parseDriveMode(modeStr);
    req.layoutOptions = opts;
    req.confirmDestructive = yes;
    return req;
}

int cmdPlan(string[] args)
{
    auto req = parseFormatRequest(args, false);
    writeln(describeFormatPlan(buildFormatPlan(req)));
    return 0;
}

int cmdFormat(string[] args)
{
    auto req = parseFormatRequest(args, true);
    auto plan = buildFormatPlan(req);
    writeln(describeFormatPlan(plan));
    auto result = executeFormat(plan);
    writeln(result.message);
    return result.success ? 0 : 3;
}

int cmdHelperScript(string[] args)
{
    string outDir = buildPath(tempDir, "tmb-helper");
    auto req = parseFormatRequest(args, true);
    // helper does not need --yes to write scripts
    req.confirmDestructive = true;
    auto plan = buildFormatPlan(req);
    getopt(args, config.passThrough, "out", &outDir);
    mkdirRecurse(outDir);
    FormatExecuteOptions opts;
    opts.instanceId = randomUUID().toString();
    auto script = writeLinuxFormatHelper(outDir, plan, opts);
    writefln("Wrote %s and format-plan.json", script);
    writeln("Attach the USB to Linux (or a VM), edit device in JSON if needed, run: bash linux-format.sh --yes");
    return 0;
}

int cmdWritePayload(string[] args)
{
    string mount;
    string modeStr = "installed";
    string instance = "local-dev";
    getopt(args, config.passThrough, "mount", &mount, "mode", &modeStr, "instance", &instance);
    if (!mount.length)
        throw new Exception("--mount is required");
    ServicePayloadOptions opts;
    opts.mode = parseDriveMode(modeStr);
    opts.instanceId = instance;
    opts.createdAtIso = Clock.currTime.toUTC().toISOExtString();
    writeServicePayload(mount, opts);
    writefln("Wrote service payload to %s", mount);
    return 0;
}

int cmdRefreshBoot(string[] args)
{
    string esp, exfat, btrfs, modeStr = "both", uuid;
    getopt(args, config.passThrough,
            "esp", &esp, "exfat", &exfat, "btrfs", &btrfs, "mode", &modeStr, "uuid", &uuid);
    if (!esp.length || !exfat.length)
        throw new Exception("--esp and --exfat are required");
    GrubMenuModel menu;
    menu.mode = parseDriveMode(modeStr);
    menu.btrfsUuid = uuid;
    menu.isos = scanIsos(exfat);
    if (btrfs.length)
        menu.installs = scanInstalls(btrfs);
    auto cfg = generateGrubCfg(menu);
    writeGrubCfgToEsp(esp, cfg);
    writefln("Wrote grub.cfg (%s ISOs, %s installs)", menu.isos.length, menu.installs.length);
    auto grub = installGrubEfi(esp);
    writeln(grub.message);
    return 0;
}

int cmdInstall(string[] args)
{
    string btrfs, name, source, release, familyStr = "auto", esp, uuid;
    bool refresh;
    getopt(args, config.passThrough,
            "btrfs", &btrfs, "name", &name, "source", &source, "release", &release,
            "family", &familyStr, "esp", &esp, "uuid", &uuid, "refresh-grub", &refresh);
    if (!btrfs.length || !name.length)
        throw new Exception("--btrfs and --name are required");
    InstallRequest req;
    req.btrfsMount = btrfs;
    req.name = name;
    req.source = source;
    req.release = release;
    req.refreshGrub = refresh;
    req.espMount = esp;
    req.btrfsUuid = uuid;
    if (familyStr == "arch")
        req.family = DistroFamily.arch;
    else if (familyStr == "debian" || familyStr == "ubuntu")
        req.family = DistroFamily.debian;
    else if (familyStr == "fedora")
        req.family = DistroFamily.fedora;
    else if (familyStr == "alpine")
        req.family = DistroFamily.alpine;
    else if (familyStr == "tar" || familyStr == "rootfs")
        req.family = DistroFamily.rootfsTar;
    else
        req.family = DistroFamily.autoDetect;
    auto result = installDistro(req);
    writeln(result.message);
    return result.success ? 0 : 3;
}

int cmdRemoveOs(string[] args)
{
    string btrfs, name, esp, uuid;
    bool refresh;
    getopt(args, config.passThrough,
            "btrfs", &btrfs, "name", &name, "esp", &esp, "uuid", &uuid, "refresh-grub", &refresh);
    auto result = removeDistro(btrfs, name, refresh, esp, uuid);
    writeln(result.message);
    return result.success ? 0 : 3;
}

int cmdSnapshot(string[] args)
{
    string btrfs, name, suffix;
    getopt(args, config.passThrough, "btrfs", &btrfs, "name", &name, "suffix", &suffix);
    auto result = snapshotDistro(btrfs, name, suffix);
    writeln(result.message);
    return result.success ? 0 : 3;
}

int cmdReconfigure(string[] args)
{
    string diskId, modeStr = "both", currentStr = "live-iso", strategy = "refresh-metadata";
    string role, esp, exfat, btrfs;
    bool yes;
    double exfatGib = 32;
    getopt(args, config.passThrough,
            "disk", &diskId, "mode", &modeStr, "current-mode", &currentStr,
            "strategy", &strategy, "volume-role", &role,
            "esp", &esp, "exfat", &exfat, "btrfs", &btrfs,
            "exfat-gib", &exfatGib, "yes", &yes);

    ReconfigureRequest req;
    if (diskId.length)
        req.disk = findDisk(diskId);
    else
    {
        req.disk.devicePath = "(mounted)";
        req.disk.sizeBytes = 64UL * 1024 * 1024 * 1024;
        req.disk.removable = true;
    }
    req.currentMode = parseDriveMode(currentStr);
    req.targetMode = parseDriveMode(modeStr);
    req.layoutOptions.bothExfatBytes = cast(ulong)(exfatGib * 1024 * 1024 * 1024);
    req.confirmDestructive = yes;
    req.volumeRole = role;
    if (strategy == "change-mode" || strategy == "change-mode-destructive")
        req.strategy = ReconfigureStrategy.changeModeDestructive;
    else if (strategy == "replace-volume")
        req.strategy = ReconfigureStrategy.replaceVolume;
    else
        req.strategy = ReconfigureStrategy.refreshMetadata;

    auto plan = buildReconfigurePlan(req);
    writeln(describeReconfigurePlan(plan));
    auto result = executeReconfigure(plan, esp, exfat, btrfs);
    writeln(result.message);
    return result.success ? 0 : 3;
}

int cmdDebugDump()
{
    auto dump = writeDebugDump();
    writefln("Wrote %s", dump.path);
    writeln(dump.summary);
    return 0;
}

int cmdAbout()
{
    writeln(versionLine());
    writefln("Homepage: %s", homepageUrl);
    writefln("Docs:     %s", docsUrl);
    writefln("Issues:   %s", issuesUrl);
    return 0;
}

DiskInfo findDisk(string id)
{
    foreach (d; new HostDiskEnumerator().listDisks())
        if (d.id == id || d.devicePath == id)
            return d;
    throw new Exception("Disk not found: " ~ id);
}
