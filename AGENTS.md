# Agent notes — Thumbelina

- Org: `Desktop-Tooling` · product: multiboot USB orchestrator (not a Ventoy fork)
- Stack: D library + CLI (`tmb`) + GUI (dlangui)
- Modes: `live-iso` | `installed` | `both` — always stamp branded exFAT service kit
- Layout: GPT · ESP FAT32 · exFAT (ISO and/or service) · optional Btrfs pool
- Docs component: `Thumbelina` → wire into `Desktop-Tooling/docs` playbook
- Destructive wipe is stubbed until platform format backends land
- Machine facts: `$CODE_ROOT/MEMORIES.md` only
