module guiapp;

import dlangui;
import std.conv : to;
import std.format : format;

import thumbdrive_multiboot;

mixin APP_ENTRY_POINT;

extern (C) int UIAppMain(string[] args)
{
    auto window = Platform.instance.createWindow(
            appName ~ " " ~ appVersion, null, WindowFlag.Resizable, 920, 680);
    window.mainWidget = new MainFrame();
    window.show();
    return Platform.instance.enterMessageLoop();
}

final class MainFrame : VerticalLayout
{
    ComboBox _diskBox;
    ComboBox _modeBox;
    EditLine _labelEdit;
    EditLine _exfatEdit;
    EditBox _planBox;
    TextWidget _status;
    DiskInfo[] _disks;

    this()
    {
        super("main");
        layoutWidth = FILL_PARENT;
        layoutHeight = FILL_PARENT;
        padding = Rect(16, 16, 16, 16);
        margins = Rect(4, 4, 4, 4);

        addChild(new TextWidget(null,
                "Format a USB stick for live ISOs, thin Btrfs installs, or both."d));
        addChild(new TextWidget(null,
                "Every mode gets a branded Windows-visible exFAT volume with README, version stamp, docs, and tools."d));

        auto rowDisk = new HorizontalLayout();
        rowDisk.addChild(new TextWidget(null, "Disk:"d));
        _diskBox = new ComboBox("disk");
        _diskBox.layoutWidth = FILL_PARENT;
        rowDisk.addChild(_diskBox);
        auto refresh = new Button("refresh", "Refresh"d);
        refresh.click = &onRefresh;
        rowDisk.addChild(refresh);
        addChild(rowDisk);

        auto rowMode = new HorizontalLayout();
        rowMode.addChild(new TextWidget(null, "Mode:"d));
        _modeBox = new ComboBox("mode", ["Live ISOs"d, "Installed OSes"d, "Both"d]);
        _modeBox.selectedItemIndex = 0;
        _modeBox.layoutWidth = FILL_PARENT;
        rowMode.addChild(_modeBox);
        addChild(rowMode);

        auto rowLabel = new HorizontalLayout();
        rowLabel.addChild(new TextWidget(null, "Volume label:"d));
        _labelEdit = new EditLine("label", appName.to!dstring);
        _labelEdit.layoutWidth = FILL_PARENT;
        rowLabel.addChild(_labelEdit);
        addChild(rowLabel);

        auto rowExfat = new HorizontalLayout();
        rowExfat.addChild(new TextWidget(null, "Both-mode exFAT GiB:"d));
        _exfatEdit = new EditLine("exfat", "32"d);
        _exfatEdit.layoutWidth = FILL_PARENT;
        rowExfat.addChild(_exfatEdit);
        addChild(rowExfat);

        auto rowBtns = new HorizontalLayout();
        auto planBtn = new Button("plan", "Preview plan"d);
        planBtn.click = &onPlan;
        rowBtns.addChild(planBtn);
        auto aboutBtn = new Button("about", "About"d);
        aboutBtn.click = &onAbout;
        rowBtns.addChild(aboutBtn);
        auto dumpBtn = new Button("dump", "Debug dump"d);
        dumpBtn.click = &onDump;
        rowBtns.addChild(dumpBtn);
        auto formatBtn = new Button("format", "Format (stub)"d);
        formatBtn.click = &onFormat;
        rowBtns.addChild(formatBtn);
        addChild(rowBtns);

        _planBox = new EditBox("planBox", ""d);
        _planBox.layoutWidth = FILL_PARENT;
        _planBox.layoutHeight = FILL_PARENT;
        _planBox.readOnly = true;
        addChild(_planBox);

        _status = new TextWidget("status", "Ready."d);
        addChild(_status);

        reloadDisks();
    }

    bool onRefresh(Widget src)
    {
        reloadDisks();
        _status.text = "Disk list refreshed."d;
        return true;
    }

    void reloadDisks()
    {
        _disks = new HostDiskEnumerator().listDisks();
        dstring[] items;
        foreach (d; _disks)
            items ~= describeDisk(d).to!dstring;
        if (!items.length)
            items ~= "(no disks found — try running as admin / on Linux)"d;
        _diskBox.items = items;
        _diskBox.selectedItemIndex = 0;
    }

    DriveMode selectedMode()
    {
        switch (_modeBox.selectedItemIndex)
        {
        case 1:
            return DriveMode.installed;
        case 2:
            return DriveMode.both;
        default:
            return DriveMode.liveIso;
        }
    }

    FormatPlan currentPlan(bool confirm)
    {
        DiskInfo disk;
        if (_disks.length && _diskBox.selectedItemIndex >= 0
                && _diskBox.selectedItemIndex < cast(int) _disks.length)
        {
            disk = _disks[_diskBox.selectedItemIndex];
        }
        else
        {
            disk.id = "none";
            disk.devicePath = "";
            disk.sizeBytes = 64UL * 1024 * 1024 * 1024;
            disk.removable = true;
            disk.model = "none";
        }

        LayoutOptions opts;
        opts.volumeLabel = _labelEdit.text.to!string;
        try
            opts.bothExfatBytes = cast(ulong)(_exfatEdit.text.to!string.to!double * 1024 * 1024 * 1024);
        catch (Exception)
            opts.bothExfatBytes = defaultBothExfatBytes;

        FormatRequest req;
        req.disk = disk;
        req.mode = selectedMode();
        req.layoutOptions = opts;
        req.confirmDestructive = confirm;
        return buildFormatPlan(req);
    }

    bool onPlan(Widget src)
    {
        auto plan = currentPlan(false);
        _planBox.text = describeFormatPlan(plan).to!dstring;
        _status.text = "Dry-run plan generated."d;
        return true;
    }

    bool onFormat(Widget src)
    {
        auto plan = currentPlan(true);
        _planBox.text = describeFormatPlan(plan).to!dstring;
        auto result = executeFormat(plan);
        _status.text = result.message.to!dstring;
        window.showMessageBox("Format"d, result.message.to!dstring);
        return true;
    }

    bool onAbout(Widget src)
    {
        auto body = format("%s\n\nHomepage: %s\nDocs: %s\nIssues: %s\n\n%s",
                versionLine(), homepageUrl, docsUrl, issuesUrl,
                "Modes: live ISO, installed (Btrfs), or both. Service exFAT on every stick.")
            .to!dstring;
        window.showMessageBox("About"d, body);
        return true;
    }

    bool onDump(Widget src)
    {
        auto dump = writeDebugDump();
        _status.text = ("Wrote " ~ dump.path).to!dstring;
        window.showMessageBox("Debug dump"d, dump.path.to!dstring);
        return true;
    }
}
