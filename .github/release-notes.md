## Install

1. Download **Readout-*.dmg** below and open it.
2. Drag **Readout** into **Applications**.
3. Open Readout. It lives in the menu bar — look for the gauge — and has no Dock icon.

Requires a Mac with Apple silicon. Built and tested on macOS 26.

### "Apple could not verify Readout"

Readout is not notarized by Apple, so macOS stops it the first time it opens.
To allow it once:

1. Open Readout and click **Done** on the warning.
2. Open **System Settings → Privacy & Security**.
3. Scroll down to *"Readout" was blocked* and click **Open Anyway**.

Or from Terminal, after copying it to Applications:

```bash
xattr -dr com.apple.quarantine /Applications/Readout.app
```

`SHA256SUMS` lists the checksum of each download.
