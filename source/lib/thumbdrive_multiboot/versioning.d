module thumbdrive_multiboot.versioning;

/// Marketing / SemVer product version (stamped at release).
enum string appVersion = "0.1.0";

/// Build id placeholder — CI should replace via -version= or -J.
enum string appBuildId = "dev";

enum string appName = "Thumbdrive Multiboot";
enum string appSlug = "Thumbdrive-Multiboot";
enum string orgName = "Desktop-Tooling";

enum string homepageUrl = "https://github.com/Desktop-Tooling/Thumbdrive-Multiboot";
enum string docsUrl = "https://desktop-tooling.github.io/docs/thumbdrive-multiboot/";
enum string issuesUrl = "https://github.com/Desktop-Tooling/Thumbdrive-Multiboot/issues";

string versionLine()
{
    return appName ~ " " ~ appVersion ~ " (" ~ appBuildId ~ ")";
}
