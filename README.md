# ClassicTitlebar

A small Ammonia tweak dylib that forces classic AppKit titlebars for whitelisted apps. Defaults ship with:

- Slack: `/Slack.app/Contents/MacOS/Slack`
- Apple Notes: `/Notes.app/Contents/MacOS/Notes`

Targeting uses Ammonia's native per-tweak whitelist. The companion file `ClassicTitlebar.dylib.whitelist` lists one substring per line; Ammonia injects the dylib when the line appears anywhere in the target process's executable path (from `_NSGetExecutablePath`, not the bundle identifier). Pick substrings narrow enough to avoid matching helpers and renderers — `/Slack.app/Contents/MacOS/Slack` matches Slack's main process but not `Slack Helper`. To target additional apps, add an exe-path substring to the installed whitelist and relaunch the app.

## Build

```sh
make
```

This produces `ClassicTitlebar.dylib`. The linker auto-applies an `adhoc,linker-signed` signature, which is what macOS's page validator accepts at dlopen time. Do not re-sign with `codesign --sign -` — it rewrites the signature into a tool-signed form that gets rejected on load in some processes (e.g. Slack will SIGKILL with `Invalid Page`).

## Install for Ammonia

```sh
make install
```

`make install` won't overwrite an existing whitelist; the default Slack+Notes whitelist is only installed if no whitelist file is present.

Or manually:

```sh
mkdir -p /private/var/ammonia/core/tweaks
cp ClassicTitlebar.dylib /private/var/ammonia/core/tweaks/
cp ClassicTitlebar.dylib.whitelist /private/var/ammonia/core/tweaks/
```

Then relaunch the whitelisted apps.

## How it works

Each target window gets one of two treatments depending on its NSWindow subclass; classification happens at runtime, so adding a new app to the whitelist requires no code changes.

**Base treatment — applied to every target window.** Forces a standard titled NSWindow with `FullSizeContentView` stripped, ensures the titlebar is opaque and the title is visible, and unhides the traffic-light buttons. Toolbar / subtitle / titlebar-accessory APIs are left alone so native AppKit apps render their normal chrome.

**Electron treatment — applied additionally when the window is an `ElectronNSWindow`.** Electron treats its NSWindow as frameless and renders chrome in HTML; this branch undoes that:

1. Routes `-[ElectronNSWindow contentRectForFrameRect:]` through `-originalContentRectForFrameRect:` (Electron's preserved copy of the standard AppKit implementation). This is the load-bearing fix — AppKit and Chromium both then see a properly-inset content rect, so the contentView sits below the titlebar instead of extending behind it.
2. Strips any `NSToolbar`, `subtitle`, and `titlebarAccessoryViewController` set by Electron — they're vehicles for custom chrome, not real native UI.
3. Constrains `NSTitlebarContainerView` to 28pt and re-centers the traffic-light buttons. Slack re-inflates the container on web-content reloads via direct frame manipulation, so this is enforced inside a `setFrame:` swizzle on the container class. No periodic polling.

The two paths share the base treatment but the Electron branch only runs when `CTIsElectronWindow()` returns true.
