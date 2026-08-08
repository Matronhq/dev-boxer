# Self-hosting hardware

Cloudflare Tunnel handles "expose a home box to the internet" without port forwarding or a static IP, so spare hardware runs Dev Boxer just as well as a paid VPS — and you skip the $5–20/month rental fee.

Three on-ramps depending on what you have:

## PC / Intel Mac / mini PC

Wipe and install [Ubuntu 24.04 Server](https://ubuntu.com/download/server) from a USB stick (use [Etcher](https://etcher.balena.io/) or `dd` to write the ISO). Boot, finish the installer, then run the Quick start curl command from the README.

## Apple Silicon Mac

[Asahi Linux](https://asahilinux.org/) on bare metal is still rough; the easier path is a VM with [multipass](https://multipass.run/):

```bash
brew install --cask multipass
multipass launch 24.04 --name devbox --cpus 4 --memory 8G --disk 50G
multipass shell devbox
# then run the Quick start curl command inside the VM
```

The VM is arm64: Google Chrome has no arm64 Linux build, so Chrome and the Chrome DevTools MCP are skipped — Firefox and everything else install normally.

## Raspberry Pi 4/5 and other arm64 boards

Install Ubuntu 24.04 Server (64-bit); 8 GB+ RAM is recommended. The same arm64 caveat applies: Chrome and the Chrome DevTools MCP are skipped — Firefox and everything else install normally.

## Windows desktop

Either install [WSL2 + Ubuntu 24.04](https://learn.microsoft.com/en-us/windows/wsl/install) (caveats: WSL2's systemd support is limited and the XRDP desktop module won't work cleanly) or spin up a real Ubuntu VM via Hyper-V — Hyper-V is the cleaner option for the full feature set.

## Tradeoffs vs. a VPS

The box has to stay on (keep it plugged in, disable sleep, set BIOS to wake-on-power-loss); flaky home internet means flaky access; and DDoS protection / uptime is on you. But $0/month and 16 GB RAM with a real CPU often beats $5/month and 2 GB RAM if you've got the hardware sitting around.
