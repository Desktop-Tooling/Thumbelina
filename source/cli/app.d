module app;

import std.algorithm : canFind;
import std.array : appender;
import std.conv : to;
import std.file : mkdirRecurse, tempDir;
import std.getopt : getopt, config, GetOptException;
import std.path : buildPath;
import std.stdio : writeln, writefln, stderr;
import std.string : strip;

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
        case "write-payload":
            return cmdWritePayload(rest);
        case "format":
            return cmdFormat(rest);
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
    writeln("Usage:");
    writeln("  tmb <command> [options]");
    writeln();
    writeln("Commands:");
    writeln("  modes              List drive modes (live-iso, installed, both)");
    writeln("  disks              List physical disks (best-effort)");
    writeln("  plan               Dry-run a format layout plan");
    writeln("  format             Build plan; execute only with --yes (stubbed wipe)");
    writeln("  write-payload      Write service kit into a mounted exFAT path");
    writeln("  debug-dump         Write a redacted debug dump");
    writeln("  about              About / version");
    writeln("  version            Print version line");
    writeln("  help               This help");
    writeln();
    writeln("Plan / format options:");
    writeln("  --mode live-iso|installed|both");
    writeln("  --disk <id>          Disk id from `tmb disks`");
    writeln("  --size-gib <n>       Synthetic size when --disk omitted (plan only)");
    writeln("  --exfat-gib <n>      Both-mode ISO partition size (default 32)");
    writeln("  --label <name>       Volume label for the Windows-visible exFAT");
    writeln("  --yes                Confirm destructive format (still stubbed)");
    writeln();
    writeln("write-payload options:");
    writeln("  --mount <path>       Mounted exFAT root");
    writeln("  --mode <mode>");
    writeln("  --instance <id>");
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
        writeln("No disks reported (unsupported host probe or empty result).");
        return 0;
    }
    foreach (d; disks)
        writeln(describeDisk(d));
    return 0;
}

int cmdPlan(string[] args)
{
    string modeStr = "live-iso";
    string diskId;
    double sizeGib = 64;
    double exfatGib = 32;
    string label = appName;
    getopt(args,
            config.passThrough,
            "mode", &modeStr,
            "disk", &diskId,
            "size-gib", &sizeGib,
            "exfat-gib", &exfatGib,
            "label", &label);

    auto mode = parseDriveMode(modeStr);
    DiskInfo disk;
    if (diskId.length)
    {
        disk = findDisk(diskId);
    }
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
    req.mode = mode;
    req.layoutOptions = opts;
    req.confirmDestructive = false;

    auto plan = buildFormatPlan(req);
    writeln(describeFormatPlan(plan));
    return 0;
}

int cmdFormat(string[] args)
{
    string modeStr = "live-iso";
    string diskId;
    double exfatGib = 32;
    string label = appName;
    bool yes;
    getopt(args,
            config.passThrough,
            "mode", &modeStr,
            "disk", &diskId,
            "exfat-gib", &exfatGib,
            "label", &label,
            "yes", &yes);

    if (!diskId.length)
        throw new Exception("--disk is required for format");

    LayoutOptions opts;
    opts.volumeLabel = label;
    opts.bothExfatBytes = cast(ulong)(exfatGib * 1024 * 1024 * 1024);

    FormatRequest req;
    req.disk = findDisk(diskId);
    req.mode = parseDriveMode(modeStr);
    req.layoutOptions = opts;
    req.confirmDestructive = yes;

    auto plan = buildFormatPlan(req);
    writeln(describeFormatPlan(plan));
    auto result = executeFormat(plan);
    writeln(result.message);
    return result.success ? 0 : 3;
}

int cmdWritePayload(string[] args)
{
    string mount;
    string modeStr = "installed";
    string instance = "local-dev";
    getopt(args,
            config.passThrough,
            "mount", &mount,
            "mode", &modeStr,
            "instance", &instance);

    if (!mount.length)
        throw new Exception("--mount is required");

    import std.datetime.systime : Clock;

    ServicePayloadOptions opts;
    opts.mode = parseDriveMode(modeStr);
    opts.instanceId = instance;
    opts.createdAtIso = Clock.currTime.toUTC().toISOExtString();
    writeServicePayload(mount, opts);
    writefln("Wrote service payload to %s", mount);
    return 0;
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
    {
        if (d.id == id || d.devicePath == id)
            return d;
    }
    throw new Exception("Disk not found: " ~ id);
}
