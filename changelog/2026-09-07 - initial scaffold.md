# 2026-09-07 — Initial scaffold

Thumbdrive Multiboot starts as a Desktop-Tooling app for formatting USB sticks in three modes (live ISO, installed Btrfs, or both), always with a Windows-visible branded exFAT service volume.

## Added

* D library: mode model, layout planner, format dry-run plans, service payload writer, host disk enumerator, debug dump
* CLI `tmb`: modes, disks, plan, format (stub execute), write-payload, about, debug-dump
* GUI shell (dlangui): disk/mode pickers, plan preview, About, debug dump, format stub
* Embedded service-payload templates (README, VERSION, links, docs, tools readme)
* Antora docs module + in-repo demos note for the three modes
