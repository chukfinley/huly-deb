# Huly Desktop — Unofficial .deb Packages

Automated GitHub Actions workflow that checks for new [Huly](https://huly.io) desktop releases, converts the official AppImage to `.deb` format, and publishes them as GitHub Releases.

## Why?

Huly only distributes its Linux desktop app as an [AppImage](https://dist.huly.io/). This repo provides `.deb` packages for Debian/Ubuntu users who prefer native package management.

## Install

Download the latest `.deb` from [Releases](../../releases/latest), then:

```bash
sudo dpkg -i huly_*.deb
sudo apt-get install -f   # install any missing dependencies
```

## Uninstall

```bash
sudo apt remove huly
```

## How it works

A GitHub Actions workflow ([`.github/workflows/huly-appimage-to-deb.yml`](.github/workflows/huly-appimage-to-deb.yml)):

1. Runs every 6 hours (or on manual trigger)
2. Queries the [hcengineering/platform](https://github.com/hcengineering/platform/releases) GitHub API for the latest release tag
3. Skips if a matching release already exists in this repo
4. Downloads `https://dist.huly.io/Huly-linux-{version}.AppImage`
5. Extracts the AppImage and repackages into a proper `.deb` with:
   - Desktop entry and icons
   - Launcher script at `/usr/bin/huly`
   - Application installed to `/opt/huly/`
   - Proper dependencies declared
6. Creates a GitHub Release with the `.deb` attached

## Manual trigger

You can trigger a build manually from the Actions tab, optionally forcing a specific version.

## Disclaimer

This is an **unofficial** community project. The `.deb` packages are mechanical repackagings of the official Huly AppImage. For official downloads, visit [huly.io/download](https://huly.io/download).
