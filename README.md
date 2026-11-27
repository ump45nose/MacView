# MacView

[简体中文](README.zh-CN.md)

MacView is a native macOS image browser inspired by [NeeView](https://github.com/neelabo/NeeView), built with Swift 6 and AppKit. It is designed for browsing photo collections, reading comics, and viewing collections that mix images and videos.

## Features

- Browse folders and unencrypted ZIP/CBZ, TAR, TAR.GZ and GZIP archives, including nested archives.
- Read in single-page, double-page, vertical or horizontal continuous, and waterfall modes. Zoom freely, view animated images, and play videos supported by AVFoundation.
- Work with local files and system-mounted SMB or NFS volumes. On-demand decoding, prefetching, and bounded caches help keep browsing responsive.
- Arrange dockable panels, switch between list, table, grid, and waterfall layouts, and use multiple windows and tabs with restored reading positions.
- Organize collections with bookmarks, browsing history, playlists, search, ratings, and tags. Copy, move, rename, classify, and delete files from the browser.
- Customize keyboard shortcuts, gestures, menus, toolbars, themes, layouts, and display profiles. Export and import your MacView user data.
- Extend the browser through JavaScript scripts, custom commands, and plugins for sources, panels, and image filters.

Image decoding uses ImageIO, and video playback uses AVFoundation. Files inside archives are read-only; RAR, 7z, and encrypted archives are not supported.

## System requirements

- macOS 27 or later.
- To build from source: Xcode with the macOS 27 SDK, and [Homebrew](https://brew.sh/) for XcodeGen.

## Download and install

1. Download the ad-hoc ZIP package from [GitHub Releases](https://github.com/ump45nose/MacView/releases) together with its matching SHA-256 checksum. To verify the download, run `shasum -a 256 -c` with the checksum filename in the download directory.
2. Extract the ZIP and place `MacView.app` in `/Applications`.
3. Public builds are ad-hoc signed, not notarized. If macOS blocks the first launch, try opening the app from Finder's contextual menu. You can also remove the download quarantine attribute:

   ```sh
   xattr -dr com.apple.quarantine /Applications/MacView.app
   ```

   Open MacView normally afterward.

## Build from source

Clone the repository and build the app:

```sh
git clone https://github.com/ump45nose/MacView.git
cd MacView
brew install xcodegen
make build
```

The Debug app is built under `build/DerivedData/Build/Products/Debug/MacView.app`. To launch it, use `make run`.

To run the test suite:

```sh
make test
```

### Local signing and installation

Development builds and Debug self-tests remain ad-hoc signed. Rebuilding them may cause macOS to ask for network-volume access again.

For a stable local installation identity, create the local self-signed certificate once, then build and install a fresh local package:

```sh
scripts/setup-signing.sh
scripts/install.sh local --build
```

The first command may request Keychain authorization. The local installation channel reuses the same `MacView Local Development` identity across builds and is intended to preserve network-volume permissions. It is separate from the ad-hoc public distribution channel. A local package can also be built with `scripts/package.sh --local`; public packages use `scripts/package.sh --adhoc`.

## Scripts and plugins

MacView supports JavaScript scripts and external commands through its command system, as well as JavaScript plugins, HTML/JavaScript panels, and external-process plugins.

- [Examples/Plugins](Examples/Plugins/) contains example source, panel, command, and filter plugins.
- [PluginSupport/python](PluginSupport/python/) contains the Python support module for external-process plugins.

Manage scripts and plugins in the Extensions section of Settings.

## Contributing

Keep personal paths, network addresses, and credentials out of the repository. Optional local network test settings are described by [Fixtures/environment.example.json](Fixtures/environment.example.json).

Run the generic privacy check before submitting changes:

```sh
scripts/privacy-check --staged --generic-only
```

CI checks generic privacy rules. OCR of changed screenshots runs only in the local pre-push hook, because Vision text recognition is unavailable on GitHub's macOS runners. If you maintain a private, nonempty exact-pattern file at `~/.config/macview/privacy-patterns.txt`, install the repository's pre-push hook:

```sh
scripts/install-hooks.sh
```

The hook checks the history root and outgoing commits and requires the private pattern file. Contributors without that file should use `--generic-only` explicitly for local checks.

## License

MacView is available under the [MIT License](LICENSE). See [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES) for the license of bundled third-party software.
