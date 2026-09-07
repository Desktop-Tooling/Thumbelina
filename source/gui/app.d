module guiapp;

import dlangui;
import std.conv : to;
import std.format : format;
import std.file : mkdirRecurse, tempDir;
import std.path : buildPath;
import std.uuid : randomUUID;

import thumbelina;

mixin APP_ENTRY_POINT;

extern (C) int UIAppMain(string[] args)
{
    auto window = Platform.instance.createWindow(
            appName ~ " " ~ appVersion, null, WindowFlag.Resizable, 960, 720);
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

        addChild(new TextWidget(null,
                "Format USB sticks for live ISOs, thin Btrfs installs, or both."d));
        addChild(new TextWidget(null,
                "Every mode gets a branded Windows-visible exFAT volume (README, version, docs, tools)."d));

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
        addBtn(rowBtns, "plan", "Preview plan", &onPlan);
        addBtn(rowBtns, "format", "Format", &onFormat);
        addBtn(rowBtns, "helper", "Linux helper script", &onHelper);
        addBtn(rowBtns, "about", "About", &onAbout);
        addBtn(rowBtns, "dump", "Debug dump", &onDump);
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

    void addBtn(HorizontalLayout row, string id, string label, bool delegate(Widget) handler)
    {
        auto b = new Button(id, label.to!dstring);
        b.click = handler;
        row.addChild(b);
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
            items ~= "(no disks found)"d;
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
            disk = _disks[_diskBox.selectedItemIndex];
        else
        {
            disk.id = "none";
            disk.devicePath = "";
            disk.sizeBytes = 64UL * 1024 * 1024 * 1024;
            disk.removable = true;
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
        _planBox.text = (_planBox.text.to!string ~ "\n\n" ~ result.message).to!dstring;
        _status.text = (result.success ? "Format succeeded." : "Format failed — see plan output.").to!dstring;
        window.showMessageBox(result.success ? "Format"d : "Format failed"d, result.message.to!dstring);
        return true;
    }

    bool onHelper(Widget src)
    {
        auto plan = currentPlan(true);
        auto dir = buildPath(tempDir, "tmb-helper-" ~ randomUUID().toString());
        mkdirRecurse(dir);
        FormatExecuteOptions opts;
        opts.instanceId = randomUUID().toString();
        auto script = writeLinuxFormatHelper(dir, plan, opts);
        auto msg = "Wrote helper to:\n" ~ dir ~ "\n" ~ script;
        _planBox.text = msg.to!dstring;
        _status.text = "Linux helper script written."d;
        window.showMessageBox("Helper script"d, msg.to!dstring);
        return true;
    }

    bool onAbout(Widget src)
    {
        auto body = format("%s\n\n%s\n\nHomepage: %s\nDocs: %s",
                versionLine(),
                "Format / GRUB refresh / install / reconfigure via CLI. GUI covers plan, format, helper script.",
                homepageUrl, docsUrl).to!dstring;
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
