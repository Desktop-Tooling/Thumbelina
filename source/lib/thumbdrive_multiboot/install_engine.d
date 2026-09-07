module thumbdrive_multiboot.install_engine;

import std.array : appender;
import std.file : exists, mkdirRecurse, write;
import std.format : format;
import std.path : baseName, buildPath, extension;
import std.string : startsWith, toLower;

import thumbdrive_multiboot.grub;
import thumbdrive_multiboot.procutil;

/// Supported bootstrap families.
enum DistroFamily
{
    autoDetect,
    arch,
    debian, /// includes Ubuntu via debootstrap
    fedora,
    alpine,
    rootfsTar /// generic rootfs tarball unpack
}

struct InstallRequest
{
    string btrfsMount; /// mounted pool root (top-level)
    string name; /// subvolume name without @, e.g. "arch"
    DistroFamily family = DistroFamily.autoDetect;
    string source; /// mirror URL, ISO path, or rootfs tar path
    string release; /// e.g. bookworm, noble — family-specific
    bool refreshGrub;
    string espMount; /// required if refreshGrub
    string btrfsUuid;
}

struct InstallResult
{
    bool success;
    string subvol;
    string message;
}

string subvolName(string name)
{
    auto n = name;
    if (n.startsWith("@"))
        return n;
    return "@" ~ n;
}

DistroFamily detectFamily(string source, DistroFamily hint)
{
    if (hint != DistroFamily.autoDetect)
        return hint;
    auto s = source.toLower();
    auto bn = baseName(s);
    if (extension(bn) == ".tar" || bn.endsWith(".tar.gz") || bn.endsWith(".tgz")
            || bn.endsWith(".tar.xz") || bn.endsWith(".tar.zst"))
        return DistroFamily.rootfsTar;
    if (s.canFind("archlinux") || s.canFind("arch"))
        return DistroFamily.arch;
    if (s.canFind("fedora"))
        return DistroFamily.fedora;
    if (s.canFind("alpine"))
        return DistroFamily.alpine;
    if (s.canFind("debian") || s.canFind("ubuntu") || s.canFind("mint"))
        return DistroFamily.debian;
    return DistroFamily.rootfsTar;
}

InstallResult installDistro(InstallRequest req)
{
    try
    {
        if (!req.btrfsMount.length || !exists(req.btrfsMount))
            throw new Exception("btrfsMount does not exist: " ~ req.btrfsMount);
        if (!req.name.length)
            throw new Exception("Install name is required");

        auto sub = subvolName(req.name);
        auto dest = buildPath(req.btrfsMount, sub);
        if (exists(dest))
            throw new Exception("Subvolume already exists: " ~ sub);

        version (linux)
        {
            enforceOk(runArgv(["btrfs", "subvolume", "create", dest]), "btrfs subvolume create");
            auto family = detectFamily(req.source, req.family);
            auto log = appender!string();
            final switch (family)
            {
            case DistroFamily.arch:
                installArch(dest, req, log);
                break;
            case DistroFamily.debian:
                installDebian(dest, req, log);
                break;
            case DistroFamily.fedora:
                installFedora(dest, req, log);
                break;
            case DistroFamily.alpine:
                installAlpine(dest, req, log);
                break;
            case DistroFamily.rootfsTar:
            case DistroFamily.autoDetect:
                installRootfsTar(dest, req, log);
                break;
            }

            // fstab stub
            mkdirRecurse(buildPath(dest, "etc"));
            write(buildPath(dest, "etc", "fstab.tmb-example"),
                    format("# UUID=%s / btrfs subvol=%s,compress=zstd:2 0 1\n",
                            req.btrfsUuid.length ? req.btrfsUuid : "POOL-UUID", sub));

            if (req.refreshGrub)
            {
                if (!req.espMount.length)
                    throw new Exception("espMount required when refreshGrub is set");
                GrubMenuModel menu;
                menu.btrfsUuid = req.btrfsUuid;
                menu.installs = scanInstalls(req.btrfsMount);
                // ISOs unknown here unless exfat mounted — caller can refresh-boot later
                writeGrubCfgToEsp(req.espMount, generateGrubCfg(menu));
            }

            return InstallResult(true, sub, "Installed " ~ sub ~ " via " ~ family.to!string ~ "\n" ~ log.data);
        }
        else
        {
            return InstallResult(false, "",
                    "Distro install requires a Linux host (or helper VM) with btrfs-progs and bootstrap tools.");
        }
    }
    catch (Exception ex)
    {
        return InstallResult(false, "", ex.msg);
    }
}

version (linux)
{
    void installArch(string dest, InstallRequest req, ref Appender!string log)
    {
        // Prefer official bootstrap tarball URL or local path
        if (req.source.length && exists(req.source))
        {
            installRootfsTar(dest, req, log);
            return;
        }
        if (!commandExists("pacstrap"))
            throw new Exception("pacstrap not found; provide an Arch bootstrap tarball via --source");
        // pacstrap into dest (needs to be run as root; dest is a directory)
        auto r = runArgv(["pacstrap", "-c", dest, "base", "linux", "linux-firmware"]);
        enforceOk(r, "pacstrap");
        log.put(r.output);
    }

    void installDebian(string dest, InstallRequest req, ref Appender!string log)
    {
        if (!commandExists("debootstrap"))
        {
            if (req.source.length && exists(req.source))
            {
                installRootfsTar(dest, req, log);
                return;
            }
            throw new Exception("debootstrap not found; install it or pass a rootfs tarball");
        }
        auto release = req.release.length ? req.release : "bookworm";
        auto mirror = req.source.length ? req.source : "http://deb.debian.org/debian/";
        auto r = runArgv(["debootstrap", release, dest, mirror]);
        enforceOk(r, "debootstrap");
        log.put(r.output);
    }

    void installFedora(string dest, InstallRequest req, ref Appender!string log)
    {
        if (req.source.length && exists(req.source))
        {
            installRootfsTar(dest, req, log);
            return;
        }
        if (!commandExists("dnf"))
            throw new Exception("dnf not found; provide a Fedora rootfs tarball via --source");
        auto release = req.release.length ? req.release : "40";
        auto r = runArgv([
                "dnf", "--installroot=" ~ dest, "--releasever=" ~ release,
                "-y", "install", "@core", "kernel"
        ]);
        enforceOk(r, "dnf --installroot");
        log.put(r.output);
    }

    void installAlpine(string dest, InstallRequest req, ref Appender!string log)
    {
        if (req.source.length && exists(req.source))
        {
            installRootfsTar(dest, req, log);
            return;
        }
        throw new Exception("Alpine install expects a minirootfs tarball via --source");
    }

    void installRootfsTar(string dest, InstallRequest req, ref Appender!string log)
    {
        if (!req.source.length || !exists(req.source))
            throw new Exception("rootfs tar path required: " ~ req.source);
        string[] argv;
        auto src = req.source.toLower();
        if (src.endsWith(".tar.zst"))
        {
            if (!commandExists("tar") || !commandExists("zstd"))
                throw new Exception("tar+zstd required for .tar.zst");
            // tar --use-compress-program=zstd -xf
            argv = ["tar", "--use-compress-program=zstd", "-xvf", req.source, "-C", dest];
        }
        else if (src.endsWith(".tar.xz"))
            argv = ["tar", "-xJvf", req.source, "-C", dest];
        else if (src.endsWith(".tar.gz") || src.endsWith(".tgz"))
            argv = ["tar", "-xzvf", req.source, "-C", dest];
        else
            argv = ["tar", "-xvf", req.source, "-C", dest];
        auto r = runArgv(argv);
        enforceOk(r, "tar extract rootfs");
        log.put("Extracted " ~ req.source ~ " into " ~ dest ~ "\n");
    }
}

InstallResult removeDistro(string btrfsMount, string name, bool refreshGrub = false,
        string espMount = null, string btrfsUuid = null)
{
    try
    {
        auto sub = subvolName(name);
        auto dest = buildPath(btrfsMount, sub);
        version (linux)
        {
            if (!exists(dest))
                throw new Exception("Subvolume not found: " ~ sub);
            enforceOk(runArgv(["btrfs", "subvolume", "delete", dest]), "btrfs subvolume delete");
            if (refreshGrub && espMount.length)
            {
                GrubMenuModel menu;
                menu.btrfsUuid = btrfsUuid;
                menu.installs = scanInstalls(btrfsMount);
                writeGrubCfgToEsp(espMount, generateGrubCfg(menu));
            }
            return InstallResult(true, sub, "Deleted " ~ sub);
        }
        else
            return InstallResult(false, sub, "removeDistro requires Linux");
    }
    catch (Exception ex)
    {
        return InstallResult(false, "", ex.msg);
    }
}

struct SnapshotResult
{
    bool success;
    string snapshot;
    string message;
}

SnapshotResult snapshotDistro(string btrfsMount, string name, string snapshotSuffix = null)
{
    try
    {
        import std.datetime.systime : Clock;
        import std.string : replace;

        auto sub = subvolName(name);
        auto src = buildPath(btrfsMount, sub);
        auto suffix = snapshotSuffix.length
            ? snapshotSuffix
            : Clock.currTime.toUTC().toISOString().replace(":", "").replace(".", "");
        auto snap = sub ~ "_backup_" ~ suffix;
        version (linux)
        {
            enforceOk(runArgv([
                    "btrfs", "subvolume", "snapshot", "-r", src, buildPath(btrfsMount, snap)
            ]), "btrfs snapshot");
            return SnapshotResult(true, snap, "Created readonly snapshot " ~ snap);
        }
        else
            return SnapshotResult(false, "", "snapshotDistro requires Linux");
    }
    catch (Exception ex)
    {
        return SnapshotResult(false, "", ex.msg);
    }
}

import std.algorithm : canFind, endsWith;
import std.array : Appender;
import std.conv : to;
