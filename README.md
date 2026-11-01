# ServerMonitor

A tiny macOS menu bar app that monitors remote Linux GPU servers over SSH.

- Menu bar shows average GPU utilization per host (`×` = unreachable)
- Dropdown shows, per host: CPU, memory, root disk, and per-GPU utilization / VRAM / temperature / which users hold VRAM
- Refreshes every 10 s; one SSH call per host, nothing to install on the servers
- "Open at Login" toggle

## Requirements

- macOS 13+, Swift toolchain (`xcode-select --install`)
- Passwordless SSH (key/agent) to each host, configured in `~/.ssh/config`
- `nvidia-smi`, `vmstat`, `free`, `df` on the servers

## Usage

Edit `HOSTS` / `INTERVAL` at the top of `main.swift`, then:

```bash
./build.sh            # build ServerMonitor.app in place
./build.sh --install  # build, copy to ~/Applications and launch
```
