#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

// ============================================================================
// Overview
// ----------------------------------------------------------------------------
// Ammonia restricts injection to processes listed in the companion
// `ClassicTitlebar.dylib.whitelist`. Inside an injected process we
// classify each window and apply one of two treatments:
//
//   * Base treatment      — every target window. Forces a standard titled
//                           NSWindow with visible traffic-light buttons, an
//                           opaque, non-hidden titlebar, and a centered title.
//
//   * Then either:
//     - Native treatment   — non-Electron windows. Ensures the app's NSToolbar
//                            is user-customizable so right-clicking it gives
//                            the standard Icons/Text/Both display modes,
//                            "Use Small Size", and "Customize Toolbar…".
//
//     - Electron treatment — ElectronNSWindow instances. Electron treats its
//                            NSWindow as frameless and renders chrome in HTML;
//                            this branch undoes that so a native titlebar
//                            takes the place of the HTML chrome.
//
// Adding a new app to the whitelist requires no code changes — windows are
// classified at runtime by their NSWindow subclass.
// ============================================================================

#pragma mark - Window classification

// Filters out windows where forcing a traditional titlebar would be wrong
// (panels, popovers, status-bar windows, tiny utility windows).
static BOOL CTIsTargetWindow(NSWindow *window) {
    if (!window) return NO;
    if ([window isKindOfClass:NSClassFromString(@"NSStatusBarWindow")]) return NO;
    if ([window isKindOfClass:NSClassFromString(@"NSPanel")]) return NO;

    NSRect f = window.frame;
    if (f.size.width < 320 || f.size.height < 200) return NO;

    if ([NSStringFromClass(window.class) localizedCaseInsensitiveContainsString:@"Popover"]) {
        return NO;
    }
    return YES;
}

// True for Electron's NSWindow subclass. The Electron treatment branch
// shouldn't fire for native AppKit apps because their toolbar and
// titlebar-accessory APIs are legitimate UI that we must not strip.
static BOOL CTIsElectronWindow(NSWindow *window) {
    Class cls = NSClassFromString(@"ElectronNSWindow");
    return cls && [window isKindOfClass:cls];
}

// Three real window stacks live behind whitelisted apps' NSWindows:
//
//   AppKit    — Notes (ICMMainWindow), Calendar (CALWindow), and any plain
//               NSWindow. Standard NSToolbar / titlebar-accessory APIs work.
//
//   Electron  — Slack-style ElectronNSWindow. Renders chrome in HTML; we
//               undo that and pin the native titlebar.
//
//   Catalyst  — Mac Catalyst apps (Messages: UINSWindow, Reminders:
//               TUINSWindow). NSWindow is a thin AppKit shell wrapping a
//               UIKit scene. NSToolbar / NSTitlebarAccessoryViewController
//               are bridged from UIKit and don't tolerate external
//               mutation; doing so crashes the bridge on launch.
//
// Catalyst detection by class-name substring catches both the public
// names and underscored variants (UINSWindow, _UINSWindow, TUINSWindow,
// _TUINSWindow).
typedef NS_ENUM(NSUInteger, CTWindowStack) {
    CTWindowStackAppKit,
    CTWindowStackElectron,
    CTWindowStackCatalyst,
};

static CTWindowStack CTClassifyWindow(NSWindow *window) {
    if (CTIsElectronWindow(window)) return CTWindowStackElectron;
    if ([NSStringFromClass(window.class) containsString:@"UINSWindow"]) {
        return CTWindowStackCatalyst;
    }
    return CTWindowStackAppKit;
}

#pragma mark - Base treatment

// macOS 26 leading-aligns the window title whenever the Liquid Glass
// ("Solarium") appearance is active and the window has neither a
// Preference-style toolbar nor a leading titlebar accessory
// (-[NSThemeFrame _defaultTitlebarTitleRect]). The classic look centers the
// title unconditionally. The theme-frame swizzle below makes AppKit pick its
// centered rect for target windows; this helper re-runs AppKit's title layout
// when the existing title field was placed before the swizzle took effect
// (or before the window became a target). Idempotent: it only triggers the
// relayout when the field's x origin disagrees with the computed rect.
static void CTCenterTitleIfStale(NSWindow *window) {
    NSView *themeFrame = window.contentView.superview;
    SEL fieldSel = NSSelectorFromString(@"_titleTextField");
    SEL frameSel = NSSelectorFromString(@"_titleTextFieldFrame");
    SEL relayoutSel = NSSelectorFromString(@"windowTitlePositionChanged");
    if (!themeFrame ||
        ![themeFrame respondsToSelector:fieldSel] ||
        ![themeFrame respondsToSelector:frameSel] ||
        ![themeFrame respondsToSelector:relayoutSel]) {
        return;
    }
    NSView *field = ((id (*)(id, SEL))objc_msgSend)(themeFrame, fieldSel);
    if (!field) return;
    NSRect want = ((NSRect (*)(id, SEL))objc_msgSend)(themeFrame, frameSel);
    if (fabs(want.origin.x - field.frame.origin.x) > 0.5) {
        ((void (*)(id, SEL))objc_msgSend)(themeFrame, relayoutSel);
    }
}

static NSWindowStyleMask CTDesiredStyleMask(NSWindowStyleMask current) {
    NSWindowStyleMask mask = current;
    // Only the two bits the classic-titlebar goal actually requires: ensure
    // the window is titled (so there is a titlebar to center the title in)
    // and clear FullSizeContentView (so the content no longer extends behind
    // it). We deliberately do NOT force Closable/Miniaturizable/Resizable:
    // adding those to a window the app made fixed-size or button-less (large
    // sheets, fixed dialogs) changes behavior the user never asked for. The
    // traffic-light buttons we unhide in the base treatment still appear for
    // whatever buttons the window's own mask already enables.
    mask |= NSWindowStyleMaskTitled;
    mask &= ~NSWindowStyleMaskFullSizeContentView;
    return mask;
}

// Universal across every whitelisted app. Idempotent.
//
// NOTE: this also mutates `styleMask` on Catalyst windows (Messages'
// UINSWindow, Reminders' TUINSWindow), which drives the UIKit->AppKit
// bridge. Verified safe on macOS 26 (Tahoe, Darwin 25.6). This is the most
// OS-version-sensitive line in the tweak: re-test on every major macOS
// update, and treat it as the first suspect if Messages or Reminders start
// misbehaving or failing to launch after an update.
static void CTApplyBaseTreatment(NSWindow *window) {
    NSWindowStyleMask desired = CTDesiredStyleMask(window.styleMask);
    if (window.styleMask != desired) {
        window.styleMask = desired;
    }
    if (window.titlebarAppearsTransparent) {
        window.titlebarAppearsTransparent = NO;
    }
    if (window.titleVisibility != NSWindowTitleVisible) {
        window.titleVisibility = NSWindowTitleVisible;
    }

    NSWindowButton btnTypes[] = {
        NSWindowCloseButton,
        NSWindowMiniaturizeButton,
        NSWindowZoomButton,
    };
    for (NSUInteger i = 0; i < sizeof(btnTypes) / sizeof(btnTypes[0]); i++) {
        NSButton *btn = [window standardWindowButton:btnTypes[i]];
        if (btn.isHidden) btn.hidden = NO;
    }

    CTCenterTitleIfStale(window);
}

#pragma mark - Native treatment

// Applied to native AppKit windows (non-Electron). Restores the classic
// "toolbar below titlebar" layout and enables the toolbar's right-click
// context menu items (Customize Toolbar… and, when the toolbar supports
// it, Icons / Text / Both display-mode toggles).
//
// Note: in macOS 26, apps like Apple Notes ship custom-NSView-based
// toolbar items (e.g. ICMFoldersToolbarItem, ICMNewNoteToolbarItem). Those
// items render their own pixels; the toolbar's `displayMode` doesn't add
// labels under them. Notes' NSToolbar subclass also overrides
// `setDisplayMode:` to refuse external changes. We don't fight either —
// the app's icon-only design wins for those items.
static void CTApplyNativeTreatment(NSWindow *window) {
    // Force the classic "toolbar below titlebar" layout. macOS 11+ defaults
    // to NSWindowToolbarStyleUnified, where the toolbar lives inline with
    // the title — Expanded restores the traditional separation.
    if (window.toolbarStyle != NSWindowToolbarStyleExpanded) {
        window.toolbarStyle = NSWindowToolbarStyleExpanded;
    }

    NSToolbar *toolbar = window.toolbar;
    if (!toolbar) return;
    if (!toolbar.allowsUserCustomization) {
        toolbar.allowsUserCustomization = YES;
    }
    if (!toolbar.autosavesConfiguration) {
        toolbar.autosavesConfiguration = YES;
    }
    // `allowsDisplayModeCustomization` (macOS 15+) gates the Icons/Text/Both
    // menu items independently of `allowsUserCustomization`. Use a runtime
    // check so older macOS versions don't crash.
    SEL setAllowsDM = @selector(setAllowsDisplayModeCustomization:);
    if ([toolbar respondsToSelector:setAllowsDM]) {
        SEL getAllowsDM = @selector(allowsDisplayModeCustomization);
        BOOL (*getter)(id, SEL) = (BOOL (*)(id, SEL))[toolbar methodForSelector:getAllowsDM];
        if (!getter(toolbar, getAllowsDM)) {
            void (*setter)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))[toolbar methodForSelector:setAllowsDM];
            setter(toolbar, setAllowsDM, YES);
        }
    }
}

#pragma mark - Electron treatment

// Slack/Electron uses an NSToolbar plus titlebar accessory view controllers
// to host its search bar and other custom chrome — these inflate the titlebar
// and aren't meaningful native UI. Drop them so the native bar is just a bar.
static void CTStripElectronCustomChrome(NSWindow *window) {
    if (window.toolbar) {
        window.toolbar = nil;
    }
    if (window.toolbarStyle != NSWindowToolbarStyleAutomatic) {
        window.toolbarStyle = NSWindowToolbarStyleAutomatic;
    }
    if (window.subtitle.length > 0) {
        window.subtitle = @"";
    }
    while (window.titlebarAccessoryViewControllers.count > 0) {
        [window removeTitlebarAccessoryViewControllerAtIndex:0];
    }
}

// Shrink an NSTitlebarContainerView (and its NSTitlebarView child) back to
// 28pt and re-center the traffic-light buttons. Slack/Electron repeatedly
// re-inflates this container to ~40pt for "hidden inset" traffic lights;
// we re-constrain on every setFrame: via the swizzle below. Idempotent so
// it's safe to re-enter from setFrame:.
static void CTConstrainTitlebarContainer(NSView *titlebarContainer) {
    if (!titlebarContainer) return;

    NSRect tf = titlebarContainer.frame;
    if (tf.size.height > 28.0) {
        NSView *themeFrame = titlebarContainer.superview;
        if (themeFrame) {
            tf.origin.y = themeFrame.bounds.size.height - 28.0;
        } else {
            tf.origin.y += (tf.size.height - 28.0);
        }
        tf.size.height = 28.0;
        titlebarContainer.frame = tf;
    }

    for (NSView *child in titlebarContainer.subviews) {
        NSRect cf = child.frame;
        if (cf.size.height > 28.0 || cf.origin.y != 0.0) {
            cf.origin.y = 0.0;
            cf.size.height = 28.0;
            child.frame = cf;
        }
    }

    NSWindow *window = titlebarContainer.window;
    if (!window) return;
    NSWindowButton btnTypes[] = {
        NSWindowCloseButton,
        NSWindowMiniaturizeButton,
        NSWindowZoomButton,
    };
    for (NSUInteger i = 0; i < sizeof(btnTypes) / sizeof(btnTypes[0]); i++) {
        NSButton *btn = [window standardWindowButton:btnTypes[i]];
        if (!btn) continue;
        NSRect bf = btn.frame;
        CGFloat targetY = floor((28.0 - bf.size.height) / 2.0);
        if (bf.origin.y != targetY) {
            bf.origin.y = targetY;
            btn.frame = bf;
        }
    }
}

static void CTSwizzleInstanceMethod(Class cls, SEL original, SEL replacement);

// Installs the ElectronNSWindow.contentRectForFrameRect: swizzle if it
// hasn't been done yet AND the class is now loaded. Ammonia injects this
// dylib before the Electron framework loads, so the eager install in the
// constructor sometimes runs too early — that's why Slack used to need
// 3–4 launches to catch the titlebar. By also calling this on every
// Electron-window patch, we guarantee the swizzle is in place as soon as
// we see an ElectronNSWindow instance. Returns YES on the call that
// performs the install, so the caller can force a relayout.
static BOOL CTInstallElectronContentRectSwizzleIfPossible(void) {
    static BOOL installed = NO;  // main-thread only — no sync needed
    if (installed) return NO;
    Class cls = NSClassFromString(@"ElectronNSWindow");
    if (!cls) return NO;
    CTSwizzleInstanceMethod(cls,
                            @selector(contentRectForFrameRect:),
                            @selector(ct_electron_contentRectForFrameRect:));
    installed = YES;
    return YES;
}

// Applied in addition to the base treatment for ElectronNSWindow instances.
static void CTApplyElectronTreatment(NSWindow *window) {
    BOOL justInstalled = CTInstallElectronContentRectSwizzleIfPossible();

    CTStripElectronCustomChrome(window);

    NSView *themeFrame = window.contentView.superview;
    for (NSView *sub in themeFrame.subviews) {
        if ([NSStringFromClass(sub.class) isEqualToString:@"NSTitlebarContainerView"]) {
            CTConstrainTitlebarContainer(sub);
            break;
        }
    }

    // Force Chromium through a real resize cycle so it honors our inset
    // content rect. Setting the frame to exactly its current value is a
    // no-op that BridgedContentView's setFrameSize: override can ignore;
    // growing by 1px then shrinking back forces a genuine resize.
    //
    // This is expensive (a full Chromium relayout), so do it ONLY when the
    // layout is actually stale: right after installing the contentRect
    // swizzle, or when this window's content view still extends behind the
    // titlebar. Once contentRectForFrameRect: is swizzled, correctly-laid-out
    // windows report the right height on every subsequent focus, so this
    // branch is skipped — focusing Slack no longer triggers a relayout.
    BOOL needs_relayout = justInstalled;
    NSView *content = window.contentView;
    if (!needs_relayout && content) {
        NSRect want = [window contentRectForFrameRect:window.frame];
        if (fabs(want.size.height - content.frame.size.height) > 0.5) {
            needs_relayout = YES;
        }
    }
    if (needs_relayout) {
        NSRect frame = window.frame;
        NSRect jiggle = frame;
        jiggle.size.height += 1;
        [window setFrame:jiggle display:NO];
        [window setFrame:frame display:YES];
    }
}

#pragma mark - Per-window patch dispatcher

static void CTPatchWindow(NSWindow *window) {
    if (!CTIsTargetWindow(window)) return;
    @try {
        CTApplyBaseTreatment(window);
        switch (CTClassifyWindow(window)) {
            case CTWindowStackElectron:
                CTApplyElectronTreatment(window);
                break;
            case CTWindowStackAppKit:
                CTApplyNativeTreatment(window);
                break;
            case CTWindowStackCatalyst:
                // Base AppKit treatment only. AppKit-side mutation of
                // toolbar / titlebar accessories / contentView frame
                // crashes the UIKit→AppKit bridge on launch (verified on
                // Reminders' TUINSWindow and Messages' UINSWindow).
                // -[UIViewController setAdditionalSafeAreaInsets:] would
                // be the right knob in principle, but Reminders does not
                // actually load UIKit (UIApplication class is not present
                // in-process despite TUINSWindow naming) so we have no
                // reachable padding mechanism from this dylib.
                break;
        }
    } @catch (NSException *ex) {
        NSLog(@"[ClassicTitlebar] Failed to patch window %@: %@", window, ex);
    }
}

#pragma mark - Swizzle helper

static void CTSwizzleInstanceMethod(Class cls, SEL original, SEL replacement) {
    Method originalMethod = class_getInstanceMethod(cls, original);
    Method replacementMethod = class_getInstanceMethod(cls, replacement);
    if (!originalMethod || !replacementMethod) return;

    BOOL added = class_addMethod(cls,
                                 original,
                                 method_getImplementation(replacementMethod),
                                 method_getTypeEncoding(replacementMethod));
    if (added) {
        class_replaceMethod(cls,
                            replacement,
                            method_getImplementation(originalMethod),
                            method_getTypeEncoding(originalMethod));
    } else {
        method_exchangeImplementations(originalMethod, replacementMethod);
    }
}

#pragma mark - Universal NSWindow swizzles

// These swizzles apply to every NSWindow in the process; their bodies gate
// on CTIsTargetWindow / CTIsElectronWindow so non-target and non-Electron
// windows are unaffected.

@interface NSWindow (ClassicTitlebar)
- (void)ct_setStyleMask:(NSWindowStyleMask)styleMask;
- (void)ct_setToolbar:(NSToolbar *)toolbar;
- (void)ct_setToolbarStyle:(NSWindowToolbarStyle)style;
- (void)ct_setSubtitle:(NSString *)subtitle;
- (void)tt_addTitlebarAccessoryViewController:(NSTitlebarAccessoryViewController *)vc;
- (void)tt_insertTitlebarAccessoryViewController:(NSTitlebarAccessoryViewController *)vc atIndex:(NSInteger)index;
- (void)ct_orderFront:(id)sender;
- (void)ct_makeKeyAndOrderFront:(id)sender;
@end

@implementation NSWindow (ClassicTitlebar)

// setStyleMask is part of the base treatment: every target window must have
// FullSizeContentView stripped so the native titlebar can occupy its space.
- (void)ct_setStyleMask:(NSWindowStyleMask)styleMask {
    if (CTIsTargetWindow(self)) {
        styleMask = CTDesiredStyleMask(styleMask);
    }
    if (self.styleMask != styleMask) {
        [self ct_setStyleMask:styleMask];
    }
}

// Toolbar / subtitle / titlebar-accessory writes are blocked only for
// Electron windows. Native AppKit apps use these APIs for real UI we keep.
- (void)ct_setToolbar:(NSToolbar *)toolbar {
    if (CTIsTargetWindow(self) && CTIsElectronWindow(self) && toolbar != nil) {
        toolbar = nil;
    }
    [self ct_setToolbar:toolbar];
}

- (void)ct_setToolbarStyle:(NSWindowToolbarStyle)style {
    if (CTIsTargetWindow(self) && CTIsElectronWindow(self) && style != NSWindowToolbarStyleAutomatic) {
        style = NSWindowToolbarStyleAutomatic;
    }
    [self ct_setToolbarStyle:style];
}

- (void)ct_setSubtitle:(NSString *)subtitle {
    if (CTIsTargetWindow(self) && CTIsElectronWindow(self) && subtitle.length > 0) {
        subtitle = @"";
    }
    [self ct_setSubtitle:subtitle];
}

- (void)tt_addTitlebarAccessoryViewController:(NSTitlebarAccessoryViewController *)vc {
    if (CTIsTargetWindow(self) && CTIsElectronWindow(self)) return;
    [self tt_addTitlebarAccessoryViewController:vc];
}

- (void)tt_insertTitlebarAccessoryViewController:(NSTitlebarAccessoryViewController *)vc atIndex:(NSInteger)index {
    if (CTIsTargetWindow(self) && CTIsElectronWindow(self)) return;
    [self tt_insertTitlebarAccessoryViewController:vc atIndex:index];
}

// Patch BEFORE the original orderFront/makeKey so the window is already in
// its corrected state by the time it appears on screen. Without this, Slack
// briefly shows its frameless HTML chrome before our patch propagates.
- (void)ct_orderFront:(id)sender {
    CTPatchWindow(self);
    [self ct_orderFront:sender];
}

- (void)ct_makeKeyAndOrderFront:(id)sender {
    CTPatchWindow(self);
    [self ct_makeKeyAndOrderFront:sender];
}

@end

#pragma mark - NSTitlebarContainerView swizzle (Electron only)

// Slack re-inflates the titlebar container height on web-content reloads
// and occlusion changes without firing NSWindowDidBecome{Main,Key}, so we
// re-constrain at the container's setFrame: instead of relying on window
// notifications. Gated on CTIsElectronWindow so Notes' taller toolbar bar
// is left alone.
@interface NSView (ClassicTitlebarContainer)
- (void)ct_titlebarContainer_setFrame:(NSRect)frame;
@end

@implementation NSView (ClassicTitlebarContainer)
- (void)ct_titlebarContainer_setFrame:(NSRect)frame {
    [self ct_titlebarContainer_setFrame:frame];
    // Only act when something inflated the container past the classic 28pt.
    // In the steady state Slack sets the frame at the correct height, so this
    // gate skips the subview/button walk entirely and keeps the swizzle off
    // the hot path. When we do re-constrain, our own setFrame to 28pt re-enters
    // here with height == 28 and stops — bounding the recursion at one level.
    if (frame.size.height > 28.0) {
        NSWindow *win = self.window;
        if (win && CTIsTargetWindow(win) && CTIsElectronWindow(win)) {
            CTConstrainTitlebarContainer(self);
        }
    }
}
@end

#pragma mark - NSThemeFrame swizzle (centered title)

// AppKit asks -[NSThemeFrame _defaultTitlebarTitleRect] where to put the
// title, and on macOS 26 it answers with the leading-aligned rect for most
// Liquid Glass windows. For target windows, answer with AppKit's own centered
// rect instead; every other window gets the stock behavior. Installed on the
// private NSThemeFrame class, so the category lives on NSView.
@interface NSView (ClassicTitlebarThemeFrame)
- (NSRect)ct_defaultTitlebarTitleRect;
@end

@implementation NSView (ClassicTitlebarThemeFrame)
- (NSRect)ct_defaultTitlebarTitleRect {
    SEL centeredSel = NSSelectorFromString(@"_defaultCenteredTitlebarTitleRect");
    if (CTIsTargetWindow(self.window) && [self respondsToSelector:centeredSel]) {
        return ((NSRect (*)(id, SEL))objc_msgSend)(self, centeredSel);
    }
    return [self ct_defaultTitlebarTitleRect];
}
@end

#pragma mark - Titlebar decoration swizzle (sharp corner overrides)

// With NSConvolutionOverride1 set, AppKit rounds the window shape at the
// override radius, but the classic (non-Liquid-Glass) titlebar outline is a
// CoreUI-rendered image with the stock radius baked in. That image paints a
// grey crescent between the old and new curves. The outline lives in the
// decoration view's CUIWindowFrameLayer as its borderLayer. We hide it and
// stroke its visible part — a faint white top-edge highlight, one pixel row
// at roughly the stock brightness — ourselves along the override radius. Only
// applied while the override is active, and only on target windows.
static CGFloat CTCornerOverrideRadius(void) {
    return [NSUserDefaults.standardUserDefaults floatForKey:@"NSConvolutionOverride1"];
}

// Builds the top-edge highlight path for a titlebar of the given size:
// down-left corner arc, straight top edge, down-right corner arc. Layer
// coordinates are y-up, so the top edge is at y == size.height.
static CGPathRef CTCreateTopHighlightPath(CGSize size, CGFloat radius, CGFloat inset) {
    CGMutablePathRef path = CGPathCreateMutable();
    CGFloat top = size.height - inset;
    CGPathMoveToPoint(path, NULL, inset, top - radius);
    CGPathAddArc(path, NULL, radius, top - radius, radius - inset, M_PI, M_PI_2, YES);
    CGPathAddLineToPoint(path, NULL, size.width - radius, top);
    CGPathAddArc(path, NULL, size.width - radius, top - radius, radius - inset, M_PI_2, 0, YES);
    return path;
}

static void CTReplaceDecorationBorder(NSView *decorationView) {
    static NSString *const highlight_name = @"ct_top_highlight";
    SEL borderSel = NSSelectorFromString(@"borderLayer");
    CGFloat radius = CTCornerOverrideRadius();
    if (radius <= 0 || !CTIsTargetWindow(decorationView.window)) return;

    CALayer *host = decorationView.layer;
    for (CALayer *layer in host.sublayers) {
        if (![layer respondsToSelector:borderSel]) continue;
        CALayer *border = ((id (*)(id, SEL))objc_msgSend)(layer, borderSel);
        if (border && !border.hidden) border.hidden = YES;
    }

    CAShapeLayer *line = nil;
    for (CALayer *layer in host.sublayers) {
        if ([layer.name isEqualToString:highlight_name]) line = (CAShapeLayer *)layer;
    }
    if (!line) {
        line = [CAShapeLayer layer];
        line.name = highlight_name;
        line.fillColor = NULL;
        line.strokeColor = CGColorGetConstantColor(kCGColorWhite);
        line.lineWidth = 0.5;
        line.opacity = 0.35;
        line.mask = [CAGradientLayer layer];
        [host addSublayer:line];
    }
    // A free-standing layer animates frame/path changes implicitly, which
    // would make the line trail the titlebar during a live resize.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    line.frame = host.bounds;

    // Fade the corner arcs out over the corner's height, as the stock outline
    // does, so the line doesn't end in a hard cut where the corner meets the
    // window's vertical edge. Layer space is y-up: the gradient runs bottom
    // (transparent) to top (opaque).
    CAGradientLayer *fade = (CAGradientLayer *)line.mask;
    CGFloat height = host.bounds.size.height;
    fade.frame = host.bounds;
    fade.startPoint = CGPointMake(0.5, 0.0);
    fade.endPoint = CGPointMake(0.5, 1.0);
    fade.colors = @[ (id)CGColorGetConstantColor(kCGColorClear),
                     (id)CGColorGetConstantColor(kCGColorClear),
                     (id)CGColorGetConstantColor(kCGColorWhite) ];
    fade.locations = @[ @0.0, @((height - radius) / height), @((height - 1.0) / height) ];

    CGPathRef path = CTCreateTopHighlightPath(host.bounds.size, radius, 0.5);
    line.path = path;
    CGPathRelease(path);
    [CATransaction commit];
}

@interface NSView (ClassicTitlebarDecoration)
- (void)ct_decoration_updateLayer;
- (void)ct_decoration_layout;
@end

@implementation NSView (ClassicTitlebarDecoration)
- (void)ct_decoration_updateLayer {
    [self ct_decoration_updateLayer];
    CTReplaceDecorationBorder(self);
}

- (void)ct_decoration_layout {
    [self ct_decoration_layout];
    CTReplaceDecorationBorder(self);
}
@end

#pragma mark - ElectronNSWindow swizzle (the load-bearing fix)

// Electron overrides -contentRectForFrameRect: to return the full frame
// (treating the window as frameless), but preserves the original AppKit
// implementation under -originalContentRectForFrameRect:. Routing the
// override back through the original undoes Electron's customization at
// the layout layer — both AppKit and Chromium then see the properly-inset
// content rect, so the contentView lays out below the titlebar instead of
// extending behind it.
@interface NSWindow (ClassicTitlebarElectron)
- (NSRect)ct_electron_contentRectForFrameRect:(NSRect)frameRect;
@end

@implementation NSWindow (ClassicTitlebarElectron)
- (NSRect)ct_electron_contentRectForFrameRect:(NSRect)frameRect {
    if (CTIsTargetWindow(self)) {
        SEL origSel = NSSelectorFromString(@"originalContentRectForFrameRect:");
        if ([self respondsToSelector:origSel]) {
            IMP imp = [self methodForSelector:origSel];
            return ((NSRect (*)(id, SEL, NSRect))imp)(self, origSel, frameRect);
        }
    }
    return [self ct_electron_contentRectForFrameRect:frameRect];
}
@end

#pragma mark - Init

__attribute__((constructor))
static void ClassicTitlebarInit(void) {
    NSLog(@"[ClassicTitlebar] Loaded into %@", NSBundle.mainBundle.bundleIdentifier ?: @"(unknown)");

    // Install method swizzles synchronously, in the constructor, so they're
    // active before the app creates any NSWindow. NSWindow and the private
    // NSTitlebarContainerView are loaded with AppKit (always available); the
    // app-specific ElectronNSWindow may load later and is installed lazily
    // from CTApplyElectronTreatment on first sight.
    CTSwizzleInstanceMethod(NSWindow.class, @selector(setStyleMask:), @selector(ct_setStyleMask:));
    CTSwizzleInstanceMethod(NSWindow.class, @selector(setToolbar:), @selector(ct_setToolbar:));
    CTSwizzleInstanceMethod(NSWindow.class, @selector(setToolbarStyle:), @selector(ct_setToolbarStyle:));
    CTSwizzleInstanceMethod(NSWindow.class, @selector(setSubtitle:), @selector(ct_setSubtitle:));
    CTSwizzleInstanceMethod(NSWindow.class, @selector(addTitlebarAccessoryViewController:), @selector(tt_addTitlebarAccessoryViewController:));
    CTSwizzleInstanceMethod(NSWindow.class, @selector(insertTitlebarAccessoryViewController:atIndex:), @selector(tt_insertTitlebarAccessoryViewController:atIndex:));
    CTSwizzleInstanceMethod(NSWindow.class, @selector(orderFront:), @selector(ct_orderFront:));
    CTSwizzleInstanceMethod(NSWindow.class, @selector(makeKeyAndOrderFront:), @selector(ct_makeKeyAndOrderFront:));

    Class titlebarContainerClass = NSClassFromString(@"NSTitlebarContainerView");
    if (titlebarContainerClass) {
        CTSwizzleInstanceMethod(titlebarContainerClass,
                                @selector(setFrame:),
                                @selector(ct_titlebarContainer_setFrame:));
    }

    Class themeFrameClass = NSClassFromString(@"NSThemeFrame");
    if (themeFrameClass) {
        CTSwizzleInstanceMethod(themeFrameClass,
                                NSSelectorFromString(@"_defaultTitlebarTitleRect"),
                                @selector(ct_defaultTitlebarTitleRect));
    }

    Class decorationClass = NSClassFromString(@"_NSTitlebarDecorationView");
    if (decorationClass) {
        CTSwizzleInstanceMethod(decorationClass, @selector(updateLayer), @selector(ct_decoration_updateLayer));
        CTSwizzleInstanceMethod(decorationClass, @selector(layout), @selector(ct_decoration_layout));
    }

    CTInstallElectronContentRectSwizzleIfPossible();

    // Things that depend on the main runloop are deferred to dispatch_async:
    // iterating existing windows (if any) and installing notification
    // observers that need the main operation queue.
    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSWindow *window in NSApplication.sharedApplication.windows) {
            CTPatchWindow(window);
            if (CTIsTargetWindow(window)) {
                [window setFrame:window.frame display:YES];
            }
        }

        void (^patchSender)(NSNotification *) = ^(NSNotification *note) {
            id sender = note.object;
            if ([sender isKindOfClass:NSWindow.class]) {
                CTPatchWindow((NSWindow *)sender);
            }
        };

        // Observe become-key only. Become-main and become-key almost always
        // fire together for these top-level windows, so observing both ran
        // the full treatment twice per focus. Window appearance is already
        // covered by the orderFront:/makeKeyAndOrderFront: swizzles and the
        // initial sweep above, and Electron's web-reload re-inflation is
        // caught by the NSTitlebarContainerView setFrame: swizzle — so a
        // single become-key observer is a sufficient backstop at half the
        // per-focus work.
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:NSWindowDidBecomeKeyNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:patchSender];
    });
}

// Ammonia calls LoadFunction with its Frida-gum interceptor handle when the
// dylib is loaded. We don't use it, but exporting it lets Ammonia confirm
// a clean load.
void LoadFunction(void *gum_interceptor) {
    (void)gum_interceptor;
}
