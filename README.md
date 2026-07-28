# HeicDrop

A tiny macOS menu bar utility that converts images. Drag files onto the menu bar icon, a
small panel opens under it, pick what you want, done.

- **In**: HEIC/HEIF primarily, but anything ImageIO can read — PNG, TIFF, WebP, JPEG
- **Out**: JPEG, PNG, or HEIF
- **Size presets** that show the *real* output dimensions and file sizes before you convert
- **Remove metadata** — strips EXIF, GPS, timestamps, XMP (and keeps the photo upright)
- **Destinations**: a folder of your choice, same-folder-and-Trash-the-original, or the clipboard
- **Start at Login**, one checkbox

No Dock icon, no windows, no preferences pane. Pure AppKit in a single `main.swift`,
built with `swiftc`. No Xcode project, no SwiftUI, no third-party dependencies.

Nothing leaves your Mac: the app has no network code at all, no analytics, no telemetry.
Originals are only ever moved to the Trash (never deleted), and only after the converted
file has been written successfully.

## Download

Grab `HeicDrop.zip` from the [latest release](../../releases/latest), unzip it, and move
`HeicDrop.app` to `/Applications` (or anywhere). The release build is Apple Silicon
(arm64); on an Intel Mac, [build from source](#build-from-source) — it takes a few seconds.

The app is ad-hoc signed, not notarized, so on first open macOS will refuse it with
"cannot be opened" or "damaged". Two ways past that, pick one:

1. **System Settings** — double-click the app once (let it refuse), then open
   System Settings → Privacy & Security, scroll down, and click **Open Anyway**.
2. **Terminal** — clear the quarantine flag and open normally:

   ```sh
   xattr -d com.apple.quarantine /Applications/HeicDrop.app
   ```

Each release lists the zip's SHA-256 so you can check what you downloaded:

```sh
shasum -a 256 ~/Downloads/HeicDrop.zip
```

## Using it

The icon sits in the menu bar. Everything happens in one popover under it.

**Drag and drop.** Drag one or more files onto the icon. The icon highlights when the drop
is accepted, and the popover opens showing what you dropped. Multiple files per drop are
fine. Dropping again while the popover is open replaces the pending files.

**Left-click the icon.** Opens the same popover with nothing pending. In that state it
doubles as the settings panel, and has a **Choose Files…** button that opens a normal
multi-select open panel instead of dragging.

**Right-click the icon.** A minimal escape-hatch menu: **Quality** (80% / 90% / 100%) and
**Quit HeicDrop**. Quality is the one setting deliberately left out of the popover.

### The popover

With files pending, top to bottom:

- **Header** — a 48 pt thumbnail of the first file, its name (`IMG_1234.heic + 2 more`
  when there is more than one), and a line like `4032×3024 · HEIC · 3.2 MB`. The
  dimensions are the first file's, after its EXIF orientation is applied; the byte figure
  is the total on-disk size of everything you dropped.
- **Format** — JPEG / PNG / HEIF.
- **Size** — four radio rows, biggest first, labelled with what you would actually get:

  ```
  Actual — 4032×3024 · 2.1 MB
  Large  — 1280×960 · 480 KB
  Medium — 640×480 · 152 KB
  Small  — 320×240 · 58 KB
  ```

- **Remove metadata** — checkbox.
- **Save to** — the output folder's name, `Same folder, delete original`, `Clipboard`, or
  `Choose Folder…` to pick a new output folder.
- **Footer** — **Start at Login**, then **Cancel** and **Convert**. Return converts.

With nothing pending, the header is replaced by "Drop images on the menu bar icon to
convert" plus **Choose Files…**, and the footer's Cancel/Convert become **Quit**.

Clicking away closes the popover and discards the pending files.

### The size rows show real numbers

The byte figures are not estimates: for drops of five files or fewer the app really encodes
every file at every preset with the current format, quality, and metadata settings, and
shows the total. It does that on a background queue, so the rows read
`Actual — 4032×3024 · …` for a moment until the numbers land, and they recompute whenever
you change the format, the metadata checkbox, or the files. Above five files that gets
slow, so the rows degrade to `Large — max 1280 px` with no byte figure. The idle state does
the same, since there is nothing to measure.

### Save to

- **`<folder name>`** — writes `<basename>.<ext>` into the output folder. On a name
  collision it appends ` 2`, ` 3`, and so on rather than overwriting.
- **Same folder, delete original** — writes the converted file next to the source, then
  moves the original to the Trash. The original is only trashed once the new file has been
  written successfully, and it goes to the Trash rather than being deleted outright, so
  it is always recoverable.
- **Clipboard** — converts and puts the image on the clipboard, as both the format's own
  UTI (`public.jpeg`, `public.png`, or `public.heic`) and TIFF data, so it pastes into as
  many apps as possible.

**Note:** the clipboard destination uses only the *first* file. A clipboard holds one
image, so dropping five files and choosing Clipboard copies the first and ignores the rest.
Use one of the save destinations for batches.

### What persists

In the idle state the popover *is* the settings panel, so Format, Size, Remove metadata and
Save to are written to `UserDefaults` the moment you change them.

With files pending, the selections are provisional: **Convert** writes them all (so the
same choices are preselected next time), **Cancel** or clicking away discards them. The
output folder is the exception — picking one in `Choose Folder…` saves it immediately,
either way.

Conversions run on a background queue, so the popover closes at once and a big batch never
freezes anything. The completion sound tells you when it is done: Glass if everything
succeeded, Basso if anything failed.

### Start at Login

The popover footer has a **Start at Login** checkbox, backed by `SMAppService.mainApp`
(the modern `ServiceManagement` login-item API, macOS 13+). The first time the GUI ever
launches it registers itself once, so the app starts at login by default. That happens
exactly once — unchecking the box afterwards sticks, and is never overridden.

The checkbox reflects the real state (`SMAppService.mainApp.status == .enabled`), not what
was last asked for. If macOS refuses the registration — most often "Login Items & Extensions"
needs your approval in System Settings — the box goes back to its real state and the error
is logged to stderr rather than crashing.

## Build from source

```sh
./build.sh
```

This compiles `main.swift` for the host architecture, assembles `HeicDrop.app`, and ad-hoc
signs it. The app lands next to the source; move it wherever you like and double-click to
run. Requires macOS 13.0 or later and the Xcode Command Line Tools (for `swiftc`).

A locally built app has no quarantine flag, so none of the Gatekeeper steps from the
Download section apply.

## Reference

### Settings storage

`UserDefaults` keys: `destination`, `outputFolder`, `jpegQuality`, `outputFormat`,
`sizePreset`, `stripMetadata`, and `didAutoRegisterLogin`.

Sizes are Actual (default), Small (max 320 px), Medium (max 640 px), Large (max 1280 px).
The number is the maximum *long edge*; the aspect ratio is kept, and images already smaller
than the preset are left alone rather than upscaled. The 320 / 640 / 1280 figures follow the
Apple Mail convention. Quality defaults to 90%, applies to JPEG and HEIF, and is simply not
passed to the PNG encoder because PNG is lossless. The output folder defaults to `~/Desktop`.

### Conversion details

Everything goes through ImageIO, and file writes and clipboard copies share one encode
path. There are two branches:

**Fast path** — Actual size with metadata kept. `CGImageSourceCreateWithURL` straight into
`CGImageDestinationAddImageFromSource`. The image is never decoded to a bitmap and
re-encoded through a pixel pipeline, so EXIF, XMP, and the orientation tag carry over
exactly as they were.

**Resize and/or strip path** — `CGImageSourceCreateThumbnailAtIndex` with
`kCGImageSourceCreateThumbnailFromImageAlways`, `kCGImageSourceCreateThumbnailWithTransform`,
and a `kCGImageSourceThumbnailMaxPixelSize` clamped so it never exceeds the image's own long
edge. The `WithTransform` option is the important one: it **bakes the EXIF orientation into
the pixels**. Without it, stripping metadata from a portrait photo would throw away the
orientation tag and leave the image lying on its side.

Because the transform is already applied, the resize path then rewrites the orientation to
`1` (both the top-level key and the one inside the TIFF sub-dictionary) and drops the now
stale pixel-dimension keys before handing the properties to the destination. When metadata
is being removed, no source properties are copied at all — only the quality option.

Note that ImageIO writes a small amount of its own baseline metadata when it encodes from a
bitmap (colour space and pixel dimensions, and for some JPEG inputs an empty Photoshop IRB
block). "Remove metadata" removes everything that came from the source — camera, software,
timestamps, GPS, XMP — but the output is not guaranteed to be literally marker-free.

Files that fail to open are skipped rather than aborting the batch. There are no
notification-center notifications — they require a permission prompt that is more trouble
than it is worth for an unsigned app.

### Headless mode

The same conversion path is reachable from the command line without any GUI, which is how
the build is verified:

```sh
HeicDrop.app/Contents/MacOS/HeicDrop --convert <input> [options]
```

| Flag | Values | Default |
| --- | --- | --- |
| `--out <dir>` | any directory, created if missing | the stored Output Folder |
| `--format` | `jpg` \| `png` \| `heif` | the stored Format |
| `--size` | `actual` \| `small` \| `medium` \| `large` | the stored Size |
| `--quality` | `0.0`–`1.0` | the stored Quality |
| `--strip` | bare flag, removes metadata | the stored Remove metadata |

Flags override the stored settings for that run only; nothing is written back to
`UserDefaults`. The output extension follows `--format` (`jpg` / `png` / `heic`). It prints
the output path and exits 0 on success, or prints the error to stderr and exits 1 on
failure.

```
$ HeicDrop.app/Contents/MacOS/HeicDrop --convert test.heic --out ./out
./out/test.jpg

$ HeicDrop.app/Contents/MacOS/HeicDrop --convert test.heic --out ./out --format png --size medium --strip
./out/test.png
```

The login item is scriptable the same way. Run these against the binary *inside* the
`.app` bundle — `SMAppService` identifies the login item by its bundle:

```sh
HeicDrop.app/Contents/MacOS/HeicDrop --login-status    # enabled|notRegistered|requiresApproval|notFound
HeicDrop.app/Contents/MacOS/HeicDrop --enable-login    # register, print resulting status
HeicDrop.app/Contents/MacOS/HeicDrop --disable-login   # unregister, print resulting status
```

`--login-status` always exits 0. `--enable-login` / `--disable-login` exit 0 on success and
1 if the call threw, printing the status either way.

## License

MIT — see [LICENSE](LICENSE).
