module runner;

import std.algorithm : canFind;
import std.file : mkdirRecurse, readText, rmdirRecurse, tempDir;
import std.path : buildPath;
import std.uuid : randomUUID;

import thumbdrive_multiboot;

void main()
{
    // Layout plans
    {
        auto live = planLayout(DriveMode.liveIso, 64UL * 1024 * 1024 * 1024);
        assert(live.hasIsoDropZone);
        assert(!live.hasBtrfsPool);
        assert(live.partitions.length == 2);

        auto installed = planLayout(DriveMode.installed, 64UL * 1024 * 1024 * 1024);
        assert(!installed.hasIsoDropZone);
        assert(installed.hasBtrfsPool);
        assert(installed.partitions.length == 3);
        assert(installed.partitions[1].filesystem == "exfat");
        assert(installed.partitions[1].sizeBytes == defaultServiceExfatBytes);

        auto both = planLayout(DriveMode.both, 128UL * 1024 * 1024 * 1024);
        assert(both.hasIsoDropZone && both.hasBtrfsPool);
        assert(both.partitions.length == 3);
    }

    assert(parseDriveMode("live-iso") == DriveMode.liveIso);
    assert(parseDriveMode("installed") == DriveMode.installed);
    assert(parseDriveMode("both") == DriveMode.both);

    {
        auto root = buildPath(tempDir, "tmb-payload-" ~ randomUUID().toString());
        mkdirRecurse(root);
        scope (exit)
            rmdirRecurse(root);

        ServicePayloadOptions opts;
        opts.mode = DriveMode.installed;
        opts.instanceId = "test-instance";
        opts.createdAtIso = "2026-09-07T00:00:00Z";
        writeServicePayload(root, opts);

        auto readme = readText(buildPath(root, "README.txt"));
        assert(readme.length > 0);
        assert(readme.canFind("test-instance"));
        assert(readme.canFind(appName));
        auto inst = readText(buildPath(root, "instance.json"));
        assert(inst.canFind("installed"));
    }

    {
        DiskInfo disk;
        disk.id = "1";
        disk.devicePath = `\\.\PhysicalDrive1`;
        disk.sizeBytes = 32UL * 1024 * 1024 * 1024;
        disk.removable = true;
        FormatRequest req;
        req.disk = disk;
        req.mode = DriveMode.liveIso;
        req.confirmDestructive = false;
        auto plan = buildFormatPlan(req);
        assert(!plan.executable);
        auto result = executeFormat(plan);
        assert(!result.success);
    }
}
