# ClassicTitlebar

A small Ammonia tweak dylib that forces classic AppKit titlebars for whitelisted apps. Defaults ship with:

- Slack: `Slack`
- Apple Notes: `Notes`
- Calendar: `Calendar`
- Messages: `Messages`
- Reminders: `Reminders`
- Mail: `Mail`
- Terminal: `Terminal`
- Finder: `Finder`

Slack is the Electron case; Notes, Calendar, Mail, Terminal and Finder are native AppKit; Messages and Reminders are Mac Catalyst (base titlebar treatment only — see "How it works").

Targeting uses Ammonia's native per-tweak whitelist. The companion file `ClassicTitlebar.dylib.whitelist` lists one entry per line, and Ammonia injects the dylib only when a line is an **exact match** for either the target process's full executable path (from `_NSGetExecutablePath`) or its last path component — never a substring, and never the bundle identifier. `Slack` therefore matches `/Applications/Slack.app/Contents/MacOS/Slack` but not `Slack Helper (Renderer)`, and a bare executable name works whether the app lives in `/Applications` or `/System/Applications`. Use a full path only when two different apps share an executable name. To target additional apps, add the executable name to the installed whitelist and relaunch the app.

## Build

```sh
make
```

This produces `ClassicTitlebar.dylib`. The linker auto-applies an `adhoc,linker-signed` signature, which is what macOS's page validator accepts at dlopen time. Do not re-sign with `codesign --sign -` — it rewrites the signature into a tool-signed form that gets rejected on load in some processes (e.g. Slack will SIGKILL with `Invalid Page`).

## Install for Ammonia

```sh
make install
```

`make install` won't overwrite an existing whitelist; the default whitelist is only installed if no whitelist file is present. To push a changed whitelist, copy it by hand (see below).

Or manually:

```sh
mkdir -p /private/var/ammonia/core/tweaks
cp ClassicTitlebar.dylib /private/var/ammonia/core/tweaks/
cp ClassicTitlebar.dylib.whitelist /private/var/ammonia/core/tweaks/
```

Then relaunch the whitelisted apps.

## How it works

Each target window gets one of two treatments depending on its NSWindow subclass; classification happens at runtime, so adding a new app to the whitelist requires no code changes.

**Base treatment — applied to every target window.** Forces a standard titled NSWindow with `FullSizeContentView` stripped, ensures the titlebar is opaque and the title is visible, unhides the traffic-light buttons, and centers the title. macOS 26 leading-aligns titles under the Liquid Glass appearance unless the window has a Preference-style toolbar or a leading titlebar accessory; the tweak swizzles `-[NSThemeFrame _defaultTitlebarTitleRect]` to return AppKit's centered rect for target windows and re-runs the title layout when a window's title field was placed before the swizzle applied. Toolbar / subtitle / titlebar-accessory APIs are left alone so native AppKit apps render their normal chrome.

**Electron treatment — applied additionally when the window is an `ElectronNSWindow`.** Electron treats its NSWindow as frameless and renders chrome in HTML; this branch undoes that:

1. Routes `-[ElectronNSWindow contentRectForFrameRect:]` through `-originalContentRectForFrameRect:` (Electron's preserved copy of the standard AppKit implementation). This is the load-bearing fix — AppKit and Chromium both then see a properly-inset content rect, so the contentView sits below the titlebar instead of extending behind it.
2. Strips any `NSToolbar`, `subtitle`, and `titlebarAccessoryViewController` set by Electron — they're vehicles for custom chrome, not real native UI.
3. Constrains `NSTitlebarContainerView` to 28pt and re-centers the traffic-light buttons. Slack re-inflates the container on web-content reloads via direct frame manipulation, so this is enforced inside a `setFrame:` swizzle on the container class. No periodic polling.

The two paths share the base treatment but the Electron branch only runs when `CTIsElectronWindow()` returns true.
