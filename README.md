# Readout

Menu bar system monitor for Apple silicon Macs: CPU, memory, network, disk, battery and processes.

Click the menu bar icon for the panel. The details window has the rest: battery cycles, per-core load, every volume.

## Install

Paste this into Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/bonkedbythonk/readout/main/Scripts/install.sh | bash
```

Run it again to update. Or grab the `.dmg` from [Releases](https://github.com/bonkedbythonk/readout/releases/latest) and drag Readout into Applications.

Requires Apple silicon. Built and tested on macOS 27.

Readout is not notarized, so macOS blocks the first launch. Click **Done**, then **System Settings → Privacy & Security → Open Anyway**. Or from Terminal:

```bash
xattr -dr com.apple.quarantine /Applications/Readout.app
```

## Updates

Readout checks GitHub once a day and tells you when a newer release exists. **⋯ → Check for Updates…** checks now. **⋯ → Check for Updates Automatically** turns the daily check off.

## Build

```bash
Scripts/compile_and_run.sh
```

Builds the Rust core and the app, assembles `Readout.app` and launches it.

## Release

```bash
git tag v0.2.0
git push origin v0.2.0
```

The tag push builds the app and publishes a GitHub release with the disk image, a zip and `SHA256SUMS`.

## More

How it works, the source of each reading, and the gotchas behind them are in [docs/notes.md](docs/notes.md).
