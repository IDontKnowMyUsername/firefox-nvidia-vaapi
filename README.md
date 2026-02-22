# firefox-nvidia-vaapi-check

A diagnostic script for troubleshooting Firefox hardware video decoding (VA-API) on NVIDIA GPUs on Linux.

## What it checks

- **System info** — kernel, display server, desktop environment, GPU(s), Firefox version and package type (deb/snap/flatpak/rpm)
- **NVIDIA driver** — driver version, open vs. proprietary kernel modules, `nvidia-drm.modeset=1` and `nvidia-drm.fbdev=1` status, Blackwell GPU compatibility
- **nvidia-vaapi-driver** — presence of `nvidia_drv_video.so` (searches standard paths, `LD_LIBRARY_PATH`, and the system linker cache), EGL vendor config, libva ABI compatibility, installed package version
- **VA-API system support** — `vainfo` output for the default driver and with `LIBVA_DRIVER_NAME=nvidia`, installed VA-API driver packages
- **Environment variables** — status of all relevant variables (`LIBVA_DRIVER_NAME`, `NVD_BACKEND`, `MOZ_DISABLE_RDD_SANDBOX`, `MOZ_X11_EGL`, `MOZ_ENABLE_WAYLAND`, etc.) with suggested values; scans `/etc/environment`, `~/.profile`, `~/.config/environment.d/`, and other sources; warns when a variable is configured in a file but not yet active in the current session
- **Firefox preferences** — reads `prefs.js` and `user.js` from all detected profiles, checks critical about:config flags for hardware decoding
- **DRM render nodes** — lists `/dev/dri/render*` nodes, per-node driver/PCI info, user access, multi-GPU warnings
- **Live decode check** — queries NVDEC utilization and Firefox/RDD process GPU activity via `nvidia-smi`
- **Summary** — consolidated pass/warn/fail report with actionable fix hints

## Requirements

- Linux with an NVIDIA GPU
- bash ≥ 4
- `grep` with PCRE support (`-P` flag) — standard in GNU coreutils
- `nvidia-smi` (NVIDIA driver)
- `vainfo` (`sudo apt install libva-utils`)
- `lspci` (`sudo apt install pciutils`)
- Firefox installed
- `objdump` optional — enables libva ABI compatibility check (`sudo apt install binutils`)

## Usage

```bash
chmod +x script/firefox-nvidia-vaapi-check.sh
./script/firefox-nvidia-vaapi-check.sh
```

Run with `sudo` if some sysfs paths require root access (the script detects this and reads the real user's profile automatically):

```bash
sudo ./script/firefox-nvidia-vaapi-check.sh
```

### Options

```
--help, -h       Show help and exit
--version, -V    Print version and exit
--no-color       Disable ANSI color output (useful when saving to a file)
--profile NAME   Only check profiles matching NAME (case-insensitive substring match)
```

Save output to a file:

```bash
./script/firefox-nvidia-vaapi-check.sh --no-color | tee /tmp/vaapi-report.txt
```

Check only a specific Firefox profile:

```bash
./script/firefox-nvidia-vaapi-check.sh --profile default
```

## Common fixes

| Issue | Fix |
|-------|-----|
| `nvidia-drm.modeset=1` not set | Add to `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`, then `sudo update-grub`; or add `options nvidia_drm modeset=1` to `/etc/modprobe.d/nvidia.conf` |
| `nvidia-drm.fbdev=1` not set (Wayland, driver ≥545) | Add `options nvidia_drm fbdev=1` to `/etc/modprobe.d/nvidia.conf`, then `sudo update-initramfs -u` |
| `LIBVA_DRIVER_NAME` not set to `nvidia` | Add `LIBVA_DRIVER_NAME=nvidia` to `/etc/environment`, then log out and back in |
| `NVD_BACKEND` not set to `direct` | Add `NVD_BACKEND=direct` to `/etc/environment` (EGL backend broken on driver ≥525) |
| `nvidia_drv_video.so` missing | `sudo apt install nvidia-vaapi-driver` |
| User not in `video`/`render` group | `sudo usermod -aG video,render $USER` (re-login required) |
| Blackwell GPU with proprietary modules | Switch to open kernel modules (required for RTX 50xx) |
| libva ABI mismatch | Reinstall `nvidia-vaapi-driver` after a libva upgrade |
| Firefox is a Snap | Consider switching to the `.deb` version for full VA-API support |

## Debugging

To capture detailed Firefox VA-API logs:

```bash
NVD_LOG=1 MOZ_LOG="PlatformDecoderModule:5" firefox 2>&1 | tee /tmp/ff-vaapi.log
```

## License

[GPL v3](LICENSE)
