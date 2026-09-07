<div align="center">

<a href="https://github.com/Desktop-Tooling/Thumbdrive-Multiboot/graphs/contributors"><img src="https://img.shields.io/github/contributors/Desktop-Tooling/Thumbdrive-Multiboot.svg?style=for-the-badge" alt="Contributors"></a>
<a href="https://github.com/Desktop-Tooling/Thumbdrive-Multiboot/network/members"><img src="https://img.shields.io/github/forks/Desktop-Tooling/Thumbdrive-Multiboot.svg?style=for-the-badge" alt="Forks"></a>
<a href="https://github.com/Desktop-Tooling/Thumbdrive-Multiboot/stargazers"><img src="https://img.shields.io/github/stars/Desktop-Tooling/Thumbdrive-Multiboot.svg?style=for-the-badge" alt="Stargazers"></a>
<a href="https://github.com/Desktop-Tooling/Thumbdrive-Multiboot/issues"><img src="https://img.shields.io/github/issues/Desktop-Tooling/Thumbdrive-Multiboot.svg?style=for-the-badge" alt="Issues"></a>
<a href="https://github.com/Desktop-Tooling/Thumbdrive-Multiboot/blob/main/LICENSE"><img src="https://img.shields.io/github/license/Desktop-Tooling/Thumbdrive-Multiboot.svg?style=for-the-badge" alt="MIT License"></a>

<h3 align="center">Thumbdrive Multiboot</h3>

<p align="center">
  Format USB sticks for live ISOs, thin Btrfs-installed Linux systems, or both — with a Windows-visible branded volume every time.
  <br />
  <a href="https://desktop-tooling.github.io/docs/thumbdrive-multiboot/"><strong>Explore the docs »</strong></a>
  <br />
  <br />
  <a href="https://github.com/Desktop-Tooling/Thumbdrive-Multiboot/issues">Report Bug</a>
  &middot;
  <a href="https://github.com/Desktop-Tooling/Thumbdrive-Multiboot/issues">Request Feature</a>
</p>

</div>

## About

Thumbdrive Multiboot is a D library, CLI (`tmb`), and desktop GUI for preparing multiboot flash drives.

| Mode | What you get |
| --- | --- |
| **Live ISOs** | ESP + large exFAT — drag `.iso` files into `isos/` like Ventoy |
| **Installed OSes** | ESP + small service exFAT + Btrfs pool (thin subvolumes, zstd, snapshots) |
| **Both** | Sized exFAT for ISOs + remaining Btrfs for installs |

Every mode stamps a **service kit** on the Windows-visible volume: README, version/instance metadata, docs, links, and room for host tools (native builds + optional polyglot binary).

Small drives: prefer two sticks (toolkit vs installed). Hybrid is optional when capacity allows.

### Built With

* **Runtime:** D (LDC/DMD), DUB
* **UI:** dlangui
* **Disk model:** GPT · FAT32 ESP · exFAT service/ISO · Btrfs install pool
* **Docs:** AsciiDoc / Antora (Desktop-Tooling docs hub)

## Getting Started

### Prerequisites

* [DUB](https://dub.pm/) + LDC or DMD
* Windows, Linux, or macOS host (destructive format execute lands first on Linux; Win/mac use a helper VM later)

### Build

```bash
dub build --config=application   # CLI → bin/tmb
dub build --config=gui           # GUI → bin/thumbdrive-multiboot
dub build --config=unittest      # tests
```

### CLI examples

```bash
tmb modes
tmb plan --mode installed --size-gib 64
tmb plan --mode both --size-gib 128 --exfat-gib 32
tmb write-payload --mount /mnt/tmb --mode live-iso --instance demo
```

## Roadmap

* [x] Mode planner + service payload + CLI/GUI scaffold
* [x] Destructive format execute (Linux full; Windows live-iso; helper script for Btrfs)
* [x] GRUB install/stage + ISO loopback menu generation
* [x] Distro bootstrap into Btrfs subvolumes (Linux tools / rootfs tar)
* [x] Reconfigure / replace-volume flows
* [ ] Bundled GRUB `BOOTX64.EFI` in releases (when `grub-install` absent)
* [ ] Headless helper VM auto-attach on Windows/macOS
* [ ] Signed installers + auto-update (Software Product Essentials)

## Changelog

See [CHANGELOG.md](CHANGELOG.md) and [changelog/](changelog/).

## License

Distributed under the MIT License. See [LICENSE](LICENSE).

## Contact

* Org: [Desktop-Tooling](https://github.com/Desktop-Tooling)
* Issues: [Thumbdrive-Multiboot issues](https://github.com/Desktop-Tooling/Thumbdrive-Multiboot/issues)
