module thumbelina.debug_dump;

import std.array : appender;
import std.datetime.systime : Clock;
import std.file : tempDir, mkdirRecurse, write;
import std.path : buildPath;
import std.process : environment;

import thumbelina.versioning;

/// Redacted support dump (paths + versions; no secrets).
struct DebugDump
{
    string path;
    string summary;
}

DebugDump writeDebugDump(string destDir = null)
{
    import std.uuid : randomUUID;

    auto dir = destDir.length ? destDir : buildPath(tempDir, "thumbelina-debug-" ~ randomUUID().toString());
    mkdirRecurse(dir);

    auto app = appender!string();
    app.put(versionLine() ~ "\n");
    app.put("utc: " ~ Clock.currTime.toISOExtString() ~ "\n");
    app.put("os: " ~ environment.get("OS", environment.get("OSTYPE", "unknown")) ~ "\n");
    version (Windows)
        app.put("platform: windows\n");
    else version (linux)
        app.put("platform: linux\n");
    else version (OSX)
        app.put("platform: macos\n");
    else
        app.put("platform: other\n");

    auto body = app.data;
    auto file = buildPath(dir, "debug.txt");
    write(file, body);
    return DebugDump(file, body);
}
