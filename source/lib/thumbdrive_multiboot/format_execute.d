module thumbdrive_multiboot.format_execute;

import std.array : appender, split;
import std.conv : to;
import std.datetime.systime : Clock;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, writeFile = write;
import std.format : format;
import std.path : buildPath;
import std.string : strip, replace, splitLines;
import std.uuid : randomUUID;

import thumbdrive_multiboot.format_plan;
import thumbdrive_multiboot.grub;
import thumbdrive_multiboot.layout;
import thumbdrive_multiboot.mode;
import thumbdrive_multiboot.procutil;
import thumbdrive_multiboot.service_payload;

struct FormatExecuteOptions
{
    bool skipGrubInstall;
    string instanceId;
}

FormatResult executeFormat(const FormatPlan plan)
{
    return executeFormat(plan, FormatExecuteOptions.init);
}

FormatResult executeFormat(const FormatPlan plan, FormatExecuteOptions opts)
{
    if (!plan.executable)
    {
        return FormatResult(false,
                "Refusing to execute: confirmation missing or plan not whole-disk.");
    }
    if (plan.request.scope_ != FormatScope.wholeDisk)
    {
        return FormatResult(false, "Only whole-disk format is executable here; use reconfigure for volume replace.");
    }

    try
    {
        version (linux)
            return executeFormatLinux(plan, opts);
        else version (Windows)
            return executeFormatWindows(plan, opts);
        else
            return FormatResult(false, "Format execute is not supported on this host OS yet.");
    }
    catch (Exception ex)
    {
        return FormatResult(false, ex.msg);
    }
}

string sanitizeLabel(string label)
{
    import std.ascii : isAlphaNum;

    char[] buf;
    foreach (c; label)
    {
        if (isAlphaNum(c) || c == ' ' || c == '-' || c == '_')
            buf ~= c;
    }
    if (buf.length > 11)
        buf = buf[0 .. 11];
    if (!buf.length)
        return "TMB";
    return buf.idup;
}

/// Write linux-format.sh + format-plan.json for VM / live execution.
string writeLinuxFormatHelper(string destDir, const FormatPlan plan, FormatExecuteOptions opts)
{
    mkdirRecurse(destDir);
    auto script = buildPath(destDir, "linux-format.sh");
    writeFile(script, import("linux-format.sh"));
    auto exfatBytes = plan.layout.partitions.length > 1 ? plan.layout.partitions[1].sizeBytes : 0;
    auto planJson = format(
            "{\n  \"device\": \"%s\",\n  \"mode\": \"%s\",\n  \"label\": \"%s\",\n  \"exfatBytes\": %s,\n  \"espBytes\": %s,\n  \"instanceId\": \"%s\"\n}\n",
            plan.request.disk.devicePath.replace(`\`, `\\`).replace(`"`, `\"`),
            modeId(plan.request.mode),
            plan.layout.volumeLabel.replace(`"`, `\"`),
            exfatBytes,
            plan.layout.partitions[0].sizeBytes,
            opts.instanceId.length ? opts.instanceId : "helper");
    writeFile(buildPath(destDir, "format-plan.json"), planJson);
    return script;
}

version (linux)
{
    FormatResult executeFormatLinux(const FormatPlan plan, FormatExecuteOptions opts)
    {
        auto disk = plan.request.disk.devicePath;
        auto log = appender!string();

        if (disk.length < 8 || disk[0 .. 5] != "/dev/")
            throw new Exception("Refusing non-/dev/ disk path: " ~ disk);

        requireTools(["wipefs", "sgdisk", "partprobe", "mkfs.vfat", "mkfs.exfat"]);
        if (plan.layout.hasBtrfsPool)
            requireTools(["mkfs.btrfs", "btrfs"]);

        log.put("wipefs -a " ~ disk ~ "\n");
        enforceOk(runArgv(["wipefs", "-a", disk]), "wipefs");
        enforceOk(runArgv(["sgdisk", "--zap-all", disk]), "sgdisk zap");

        ulong partNum = 1;
        string espPart, exfatPart, btrfsPart;

        auto espMiB = plan.layout.partitions[0].sizeBytes / (1024 * 1024);
        if (espMiB == 0)
            espMiB = 512;
        enforceOk(runArgv([
                "sgdisk", "-n", format("%s:0:+%sM", partNum, espMiB),
                "-t", format("%s:EF00", partNum),
                "-c", format("%s:%s", partNum, plan.layout.partitions[0].label),
                disk
        ]), "sgdisk ESP");
        espPart = partitionName(disk, partNum++);

        {
            auto p = plan.layout.partitions[1];
            if (p.sizeBytes == 0)
            {
                enforceOk(runArgv([
                        "sgdisk", "-n", format("%s:0:0", partNum),
                        "-t", format("%s:0700", partNum),
                        "-c", format("%s:%s", partNum, p.label), disk
                ]), "sgdisk exFAT");
            }
            else
            {
                auto miB = p.sizeBytes / (1024 * 1024);
                enforceOk(runArgv([
                        "sgdisk", "-n", format("%s:0:+%sM", partNum, miB),
                        "-t", format("%s:0700", partNum),
                        "-c", format("%s:%s", partNum, p.label), disk
                ]), "sgdisk exFAT");
            }
            exfatPart = partitionName(disk, partNum++);
        }

        if (plan.layout.hasBtrfsPool)
        {
            auto p = plan.layout.partitions[2];
            enforceOk(runArgv([
                    "sgdisk", "-n", format("%s:0:0", partNum),
                    "-t", format("%s:8300", partNum),
                    "-c", format("%s:%s", partNum, p.label), disk
            ]), "sgdisk btrfs");
            btrfsPart = partitionName(disk, partNum);
        }

        enforceOk(runArgv(["partprobe", disk]), "partprobe");
        runArgv(["udevadm", "settle"]);

        enforceOk(runArgv(["mkfs.vfat", "-F", "32", "-n", "TMB-EFI", espPart]), "mkfs.vfat");
        enforceOk(runArgv([
                "mkfs.exfat", "-n", sanitizeLabel(plan.layout.volumeLabel), exfatPart
        ]), "mkfs.exfat");
        if (btrfsPart.length)
            enforceOk(runArgv(["mkfs.btrfs", "-f", "-L", "TMB-POOL", btrfsPart]), "mkfs.btrfs");

        auto work = buildPath(tempDir, "tmb-format-" ~ randomUUID().toString());
        mkdirRecurse(work);
        scope (exit)
        {
            runArgv(["umount", buildPath(work, "esp")]);
            runArgv(["umount", buildPath(work, "exfat")]);
            if (btrfsPart.length)
                runArgv(["umount", buildPath(work, "btrfs")]);
            if (exists(work))
                rmdirRecurse(work);
        }

        auto espM = buildPath(work, "esp");
        auto exfatM = buildPath(work, "exfat");
        mkdirRecurse(espM);
        mkdirRecurse(exfatM);
        enforceOk(runArgv(["mount", espPart, espM]), "mount ESP");
        enforceOk(runArgv(["mount", exfatPart, exfatM]), "mount exFAT");

        string btrfsUuid;
        if (btrfsPart.length)
        {
            auto btrfsM = buildPath(work, "btrfs");
            mkdirRecurse(btrfsM);
            enforceOk(runArgv(["mount", btrfsPart, btrfsM]), "mount btrfs");
            enforceOk(runArgv(["btrfs", "subvolume", "create", buildPath(btrfsM, "@shared_home")]),
                    "btrfs @shared_home");
            runArgv(["btrfs", "property", "set", btrfsM, "compression", "zstd"]);
            btrfsUuid = readUuidIfExists(btrfsPart);
        }

        ServicePayloadOptions payloadOpts;
        payloadOpts.mode = plan.request.mode;
        payloadOpts.instanceId = opts.instanceId.length ? opts.instanceId : randomUUID().toString();
        payloadOpts.createdAtIso = Clock.currTime.toUTC().toISOExtString();
        writeServicePayload(exfatM, payloadOpts);

        GrubMenuModel menu;
        menu.mode = plan.request.mode;
        menu.btrfsUuid = btrfsUuid;
        menu.isos = scanIsos(exfatM);
        if (btrfsPart.length)
            menu.installs = scanInstalls(buildPath(work, "btrfs"));
        writeGrubCfgToEsp(espM, generateGrubCfg(menu));

        GrubInstallResult grub;
        if (!opts.skipGrubInstall)
            grub = installGrubEfi(espM, disk);
        else
            grub = GrubInstallResult(false, "GRUB install skipped by option");

        return FormatResult(true, format(
                "Formatted %s as %s.\nInstance %s\nGRUB: %s\nLog:\n%s",
                disk, modeId(plan.request.mode), payloadOpts.instanceId, grub.message, log.data));
    }

    string partitionName(string disk, ulong num)
    {
        import std.algorithm : canFind;

        if (disk.canFind("nvme") || disk.canFind("mmcblk") || disk.canFind("loop"))
            return format("%sp%s", disk, num);
        return format("%s%s", disk, num);
    }

    void requireTools(string[] names)
    {
        foreach (n; names)
            if (!commandExists(n))
                throw new Exception("Required tool not found: " ~ n);
    }
}

version (Windows)
{
    FormatResult executeFormatWindows(const FormatPlan plan, FormatExecuteOptions opts)
    {
        if (plan.layout.hasBtrfsPool)
        {
            throw new Exception(
                    "Windows cannot create Btrfs pools natively. "
                        ~ "Run `tmb helper-script --disk <id> --mode " ~ modeId(plan.request.mode)
                        ~ "` and execute linux-format.sh from a Linux live environment or VM "
                        ~ "with this USB attached. Or format on a Linux host. "
                        ~ "Live-ISO mode (`--mode live-iso`) formats fully on Windows.");
        }

        auto diskNum = plan.request.disk.id;
        if (!diskNum.length)
            throw new Exception("Windows format requires numeric disk id from `tmb disks`");

        auto espMiB = plan.layout.partitions[0].sizeBytes / (1024 * 1024);
        if (espMiB == 0)
            espMiB = 512;
        auto label = sanitizeLabel(plan.layout.volumeLabel).replace(`'`, `''`);

        auto ps = format(q"PS
$ErrorActionPreference = 'Stop'
Clear-Disk -Number %s -RemoveData -Confirm:$false
Initialize-Disk -Number %s -PartitionStyle GPT
$esp = New-Partition -DiskNumber %s -Size %sMB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
Format-Volume -Partition $esp -FileSystem FAT32 -NewFileSystemLabel 'TMB-EFI' -Confirm:$false | Out-Null
$ex = New-Partition -DiskNumber %s -UseMaximumSize -AssignDriveLetter
Format-Volume -Partition $ex -FileSystem exFAT -NewFileSystemLabel '%s' -Confirm:$false | Out-Null
Get-Partition -DiskNumber %s -PartitionNumber $esp.PartitionNumber | Add-PartitionAccessPath -AssignDriveLetter
$espLetter = (Get-Partition -DiskNumber %s -PartitionNumber $esp.PartitionNumber | Get-Volume).DriveLetter
$exLetter = $ex.DriveLetter
Write-Output ("ESP=$espLetter")
Write-Output ("EXFAT=$exLetter")
PS", diskNum, diskNum, diskNum, espMiB, diskNum, label, diskNum, diskNum);

        auto r = runArgv(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps]);
        enforceOk(r, "PowerShell Clear-Disk/format");

        string espLetter, exLetter;
        foreach (line; r.output.splitLines)
        {
            auto s = line.strip;
            if (s.length > 4 && s[0 .. 4] == "ESP=")
                espLetter = s[4 .. $];
            if (s.length > 6 && s[0 .. 6] == "EXFAT=")
                exLetter = s[6 .. $];
        }
        if (!espLetter.length || !exLetter.length)
            throw new Exception("Could not determine drive letters after format:\n" ~ r.output);

        auto espRoot = espLetter ~ `:\`;
        auto exRoot = exLetter ~ `:\`;

        ServicePayloadOptions payloadOpts;
        payloadOpts.mode = plan.request.mode;
        payloadOpts.instanceId = opts.instanceId.length ? opts.instanceId : randomUUID().toString();
        payloadOpts.createdAtIso = Clock.currTime.toUTC().toISOExtString();
        writeServicePayload(exRoot, payloadOpts);

        GrubMenuModel menu;
        menu.mode = plan.request.mode;
        menu.isos = scanIsos(exRoot);
        writeGrubCfgToEsp(espRoot, generateGrubCfg(menu));
        auto grub = opts.skipGrubInstall
            ? GrubInstallResult(false, "skipped")
            : installGrubEfi(espRoot);

        return FormatResult(true, format(
                "Formatted disk %s as live-iso on Windows.\nInstance %s\nESP %s  exFAT %s\nGRUB: %s\n",
                diskNum, payloadOpts.instanceId, espRoot, exRoot, grub.message));
    }
}
