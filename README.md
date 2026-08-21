# AASX Package Explorer — Linux Installer

Interactive installer to run the [AASX Package Explorer](https://github.com/eclipse-aaspe/package-explorer) (Eclipse AASX Package Explorer) on Linux via Wine, since the app is a WPF (.NET 8) application with no native Linux build.

## What the script does

- Checks and installs system dependencies (`wine`, `wine64`, `wine32:i386`, `curl`, `unzip`) via `apt`, with confirmation.
- Queries the GitHub API and downloads the latest release from [eclipse-aaspe/package-explorer](https://github.com/eclipse-aaspe/package-explorer/releases), letting you pick among the available variants (classic WPF, Blazor, "small" builds).
- Extracts the package, fixing folder permissions that ship without the execute bit in the original Windows-packaged zip.
- Creates a dedicated Wine prefix (`~/.wine-aasx` by default) and installs the **.NET Windows Desktop Runtime 8** inside it.
- Generates a `run.sh` to launch the app.
- Extracts the real icon embedded in the `.exe` (via `wrestool` + Pillow) and creates a `.desktop` shortcut in the applications menu.
- Writes an install manifest to support a full uninstall and to skip redundant downloads on future runs with the same version.

## Usage

```bash
./install-aasx-linux.sh
```

Follow the interactive prompts. To uninstall everything (install directory, Wine prefix, shortcut, and icon):

```bash
./install-aasx-linux.sh --uninstall
```

## Optional environment variables

| Variable            | Default                             | Description                    |
|----------------------|--------------------------------------|---------------------------------|
| `AASX_INSTALL_DIR`  | `~/Apps/AasxPackageExplorer`        | Where the app gets installed    |
| `AASX_WINEPREFIX`   | `~/.wine-aasx`                       | Dedicated Wine prefix for the app |

## Requirements

- Debian/Ubuntu-based distro (uses `apt`).
- `sudo` access to install system dependencies.
- Internet connection (downloads ~250MB for the package + .NET runtime on first install).

## License

This repository contains only the installer script. AASX Package Explorer itself is distributed under the license of the [eclipse-aaspe/package-explorer](https://github.com/eclipse-aaspe/package-explorer) project.
