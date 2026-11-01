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

Create your host list (git-ignored):

```bash
cp hosts.conf.example hosts.conf   # then edit: one ssh host per line, optional `interval = 10`
```

`build.sh` bundles `hosts.conf` into the app. Alternatively put it at
`~/.config/servermonitor/hosts.conf`, which takes precedence and needs no rebuild (just restart the app).

Then:

```bash
./build.sh            # build ServerMonitor.app in place
./build.sh --install  # build, copy to ~/Applications and launch
```
