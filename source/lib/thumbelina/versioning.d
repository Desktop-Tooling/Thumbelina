module thumbelina.versioning;

/// Marketing / SemVer product version (stamped at release).
enum string appVersion = "0.3.0";

/// Build id placeholder — CI should replace via -version= or -J.
enum string appBuildId = "dev";

enum string appName = "Thumbelina";
enum string appSlug = "Thumbelina";
enum string orgName = "Desktop-Tooling";

enum string homepageUrl = "https://github.com/Desktop-Tooling/Thumbelina";
enum string docsUrl = "https://desktop-tooling.github.io/docs/thumbelina/";
enum string issuesUrl = "https://github.com/Desktop-Tooling/Thumbelina/issues";

string versionLine()
{
    return appName ~ " " ~ appVersion ~ " (" ~ appBuildId ~ ")";
}
