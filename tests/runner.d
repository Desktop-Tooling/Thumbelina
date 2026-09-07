module runner;

import std.algorithm : canFind;
import std.file : mkdirRecurse, readText, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import std.uuid : randomUUID;

import thumbdrive_multiboot;

void main()
{
    {
        auto live = planLayout(DriveMode.liveIso, 64UL * 1024 * 1024 * 1024);
        assert(live.hasIsoDropZone && !live.hasBtrfsPool && live.partitions.length == 2);

        auto installed = planLayout(DriveMode.installed, 64UL * 1024 * 1024 * 1024);
        assert(!installed.hasIsoDropZone && installed.hasBtrfsPool && installed.partitions.length == 3);

        auto both = planLayout(DriveMode.both, 128UL * 1024 * 1024 * 1024);
        assert(both.hasIsoDropZone && both.hasBtrfsPool);
    }

    assert(parseDriveMode("live-iso") == DriveMode.liveIso);

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
        assert(readText(buildPath(root, "README.txt")).canFind("test-instance"));
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
        assert(!executeFormat(plan).success);
    }

    // GRUB cfg generation
    {
        GrubMenuModel menu;
        menu.mode = DriveMode.both;
        menu.btrfsUuid = "abcd-ef01";
        InstalledOsEntry os;
        os.subvol = "@arch";
        os.title = "Arch";
        os.kernelRel = "boot/vmlinuz-linux";
        os.initrdRel = "boot/initramfs-linux.img";
        menu.installs ~= os;
        IsoEntry iso;
        iso.relativePath = "isos/ubuntu.iso";
        iso.title = "Ubuntu";
        menu.isos ~= iso;
        auto cfg = generateGrubCfg(menu);
        assert(cfg.canFind("menuentry \"Arch\""));
        assert(cfg.canFind("subvol=@arch"));
        assert(cfg.canFind("isos/ubuntu.iso"));
        assert(cfg.canFind("loopback loop"));
    }

    // ISO scan
    {
        auto root = buildPath(tempDir, "tmb-iso-" ~ randomUUID().toString());
        mkdirRecurse(buildPath(root, "isos"));
        scope (exit)
            rmdirRecurse(root);
        write(buildPath(root, "isos", "demo.iso"), "not-a-real-iso");
        auto isos = scanIsos(root);
        assert(isos.length == 1);
        assert(isos[0].relativePath == "isos/demo.iso");
    }

    // Reconfigure refresh is executable without --yes
    {
        ReconfigureRequest req;
        req.disk.sizeBytes = 64UL * 1024 * 1024 * 1024;
        req.disk.removable = true;
        req.disk.devicePath = "/dev/sdb";
        req.currentMode = DriveMode.liveIso;
        req.targetMode = DriveMode.liveIso;
        req.strategy = ReconfigureStrategy.refreshMetadata;
        auto plan = buildReconfigurePlan(req);
        assert(plan.executable);
    }

    // Helper script write
    {
        DiskInfo disk;
        disk.id = "2";
        disk.devicePath = "/dev/sdb";
        disk.sizeBytes = 64UL * 1024 * 1024 * 1024;
        disk.removable = true;
        FormatRequest req;
        req.disk = disk;
        req.mode = DriveMode.both;
        req.confirmDestructive = true;
        auto plan = buildFormatPlan(req);
        auto dir = buildPath(tempDir, "tmb-helper-" ~ randomUUID().toString());
        auto script = writeLinuxFormatHelper(dir, plan, FormatExecuteOptions.init);
        assert(script.canFind("linux-format.sh"));
        assert(readText(script).canFind("sgdisk"));
        rmdirRecurse(dir);
    }

    assert(sanitizeLabel("Thumbdrive Multiboot").length <= 11);
}
