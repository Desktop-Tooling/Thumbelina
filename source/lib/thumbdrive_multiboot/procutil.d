module thumbdrive_multiboot.procutil;

import std.array : join;
import std.process : Config, execute, executeShell;
import std.string : strip;

struct CmdResult
{
    int status;
    string output;
    string command;
}

CmdResult runArgv(string[] argv, string workDir = null)
{
    import std.process : execute;

    auto cfg = Config.none;
    string[string] env;
    auto r = workDir.length
        ? execute(argv, env, cfg, size_t.max, workDir)
        : execute(argv);
    return CmdResult(r.status, r.output, argv.join(" "));
}

CmdResult runShell(string command)
{
    auto r = executeShell(command);
    return CmdResult(r.status, r.output, command);
}

bool commandExists(string name)
{
    version (Windows)
    {
        auto r = runArgv(["where.exe", name]);
        return r.status == 0 && r.output.strip.length > 0;
    }
    else
    {
        auto r = runArgv(["sh", "-c", "command -v " ~ name]);
        return r.status == 0 && r.output.strip.length > 0;
    }
}

void enforceOk(CmdResult r, string context)
{
    if (r.status != 0)
    {
        throw new Exception(context ~ " failed (" ~ r.command ~ "): " ~ r.output.strip);
    }
}
