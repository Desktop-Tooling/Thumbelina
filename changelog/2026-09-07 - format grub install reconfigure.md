# 2026-09-07 — Format, GRUB, install, reconfigure

Delivered the product paths that were still stubbed after the scaffold.

## Added

* **Format execute**
  * Linux: wipefs/sgdisk/mkfs (FAT32, exFAT, Btrfs), mounts, service payload, `@shared_home`, GRUB cfg + `grub-install` when available
  * Windows: full **live-iso** format via PowerShell Clear-Disk; installed/both require `tmb helper-script` + `scripts/linux-format.sh` in Linux/VM
* **GRUB**: menu generator for installed subvolumes + ISO loopback (loopback.cfg / casper / Arch / Fedora heuristics); `tmb refresh-boot`
* **Install engine**: bootstrap into Btrfs subvolumes (`debootstrap` / `pacstrap` / `dnf --installroot` / rootfs tar); remove + readonly snapshot
* **Reconfigure**: refresh-metadata, change-mode-destructive, replace-volume strategies
* CLI commands: `format`, `helper-script`, `refresh-boot`, `install`, `remove-os`, `snapshot`, `reconfigure`
* GUI: format + Linux helper script actions
