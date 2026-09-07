module thumbelina.service_payload;

import std.file : exists, mkdirRecurse, write, readText;
import std.path : buildPath;
import std.string : replace;

import thumbelina.mode;
import thumbelina.versioning;

/// Files stamped onto the Windows-visible exFAT volume for every mode.
struct ServicePayloadOptions
{
    DriveMode mode;
    string instanceId; /// Stick UUID / random id
    string createdAtIso; /// ISO-8601
    string appVersionOverride; /// empty → appVersion
}

string readPayloadTemplate(string name)
{
    // stringImportPaths = service-payload/
    switch (name)
    {
    case "README.txt":
        return import("README.txt");
    case "VERSION.txt":
        return import("VERSION.txt");
    case "links.txt":
        return import("links.txt");
    case "docs/overview.txt":
        return import("docs/overview.txt");
    case "tools/README.txt":
        return import("tools/README.txt");
    default:
        throw new Exception("Unknown service payload template: " ~ name);
    }
}

string expandPlaceholders(string text, ServicePayloadOptions opts)
{
    auto ver = opts.appVersionOverride.length ? opts.appVersionOverride : appVersion;
    return text
        .replace("{{APP_NAME}}", appName)
        .replace("{{APP_VERSION}}", ver)
        .replace("{{APP_BUILD}}", appBuildId)
        .replace("{{MODE_ID}}", modeId(opts.mode))
        .replace("{{MODE_TITLE}}", modeTitle(opts.mode))
        .replace("{{INSTANCE_ID}}", opts.instanceId.length ? opts.instanceId : "(unset)")
        .replace("{{CREATED_AT}}", opts.createdAtIso.length ? opts.createdAtIso : "(unset)")
        .replace("{{HOMEPAGE_URL}}", homepageUrl)
        .replace("{{DOCS_URL}}", docsUrl)
        .replace("{{ISSUES_URL}}", issuesUrl)
        .replace("{{ORG_NAME}}", orgName);
}

/// Write the service kit into an already-mounted exFAT path.
void writeServicePayload(string mountRoot, ServicePayloadOptions opts)
{
    if (!exists(mountRoot))
        throw new Exception("Mount root does not exist: " ~ mountRoot);

    mkdirRecurse(buildPath(mountRoot, "docs"));
    mkdirRecurse(buildPath(mountRoot, "tools"));
    mkdirRecurse(buildPath(mountRoot, "isos")); // Live/Both; harmless empty on Installed

    static immutable files = [
        "README.txt",
        "VERSION.txt",
        "links.txt",
        "docs/overview.txt",
        "tools/README.txt",
    ];

    foreach (rel; files)
    {
        auto body = expandPlaceholders(readPayloadTemplate(rel), opts);
        write(buildPath(mountRoot, rel), body);
    }

    // Machine-readable stamp for support / reconfigure.
    auto json = expandPlaceholders(q"JSON
{
  "app": "{{APP_NAME}}",
  "version": "{{APP_VERSION}}",
  "build": "{{APP_BUILD}}",
  "mode": "{{MODE_ID}}",
  "instanceId": "{{INSTANCE_ID}}",
  "createdAt": "{{CREATED_AT}}",
  "homepage": "{{HOMEPAGE_URL}}",
  "docs": "{{DOCS_URL}}",
  "issues": "{{ISSUES_URL}}"
}
JSON", opts);
    write(buildPath(mountRoot, "instance.json"), json);
}

/// Dry-run: return relative paths that would be written.
string[] listServicePayloadFiles()
{
    return [
        "README.txt",
        "VERSION.txt",
        "links.txt",
        "instance.json",
        "docs/overview.txt",
        "tools/README.txt",
        "isos/",
    ];
}
