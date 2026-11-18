#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <libproc.h>

static void writeLog(NSFileHandle *log, NSString *message);
static NSURL *stateDirectory(void);

// App 包可能在含中文的路径下（如「死神vs火影」）。Wine/AIR 用相对路径加载
// assets 时，非 ASCII 路径会导致资源加载卡在最后一步（图片 4/4）。
static NSURL *bundledGameDirectory(void)
{
    return [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"Game" isDirectory:YES];
}

static NSURL *runtimeGameDirectory(void)
{
    return [stateDirectory() URLByAppendingPathComponent:@"Game" isDirectory:YES];
}

static NSURL *gameDirectory(void)
{
    return runtimeGameDirectory();
}

static BOOL syncGameToAsciiPath(NSFileHandle *log, NSError **error)
{
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *source = bundledGameDirectory();
    NSURL *dest = runtimeGameDirectory();
    if (![files fileExistsAtPath:source.path]) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOENT userInfo:@{
                NSLocalizedDescriptionKey: @"找不到内置游戏目录。"
            }];
        }
        return NO;
    }

    // 目标已是最新则跳过（SWF 大小 + 修改时间）
    NSURL *srcSwf = [source URLByAppendingPathComponent:@"FighterTester.swf"];
    NSURL *dstSwf = [dest URLByAppendingPathComponent:@"FighterTester.swf"];
    NSDictionary *srcAttr = [files attributesOfItemAtPath:srcSwf.path error:nil];
    NSDictionary *dstAttr = [files attributesOfItemAtPath:dstSwf.path error:nil];
    NSDate *srcDate = srcAttr.fileModificationDate;
    NSDate *dstDate = dstAttr.fileModificationDate;
    unsigned long long srcSize = srcAttr.fileSize;
    unsigned long long dstSize = dstAttr.fileSize;
    if (srcDate && dstDate && srcSize == dstSize && srcSize > 0
        && [srcDate compare:dstDate] != NSOrderedDescending
        && [files isReadableFileAtPath:[dest URLByAppendingPathComponent:@"FighterTester.exe"].path]) {
        // 运行副本不比内置旧，且同大小 → 复用（避免覆盖已打的帧率补丁）
        writeLog(log, [NSString stringWithFormat:@"Using ASCII game path %@", dest.path]);
        return YES;
    }

    writeLog(log, [NSString stringWithFormat:@"Syncing game files to ASCII path %@", dest.path]);
    if ([files fileExistsAtPath:dest.path]) {
        if (![files removeItemAtURL:dest error:error]) return NO;
    }
    if (![files createDirectoryAtURL:dest.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }
    if (![files copyItemAtURL:source toURL:dest error:error]) return NO;
    writeLog(log, @"Game file sync complete");
    return YES;
}

// Wine/AIR 在 macOS 上无法正确接收中文输入法（拼音等）拦截的按键。
// 游戏运行期间强制切到英文键盘布局，退出后再恢复用户原来的输入法。
static TISInputSourceRef gSavedInputSource;
static BOOL gForcedLatinKeyboard;

static TISInputSourceRef copyPreferredLatinKeyboard(void)
{
    NSArray<NSString *> *preferredIDs = @[
        @"com.apple.keylayout.ABC",
        @"com.apple.keylayout.US",
        @"com.apple.keylayout.British",
        @"com.apple.keylayout.Australian",
        @"com.apple.keylayout.Canadian",
    ];
    for (NSString *sourceID in preferredIDs) {
        CFArrayRef matched = TISCreateInputSourceList((__bridge CFDictionaryRef)@{
            (__bridge NSString *)kTISPropertyInputSourceID: sourceID
        }, false);
        if (matched && CFArrayGetCount(matched) > 0) {
            TISInputSourceRef source = (TISInputSourceRef)CFRetain(CFArrayGetValueAtIndex(matched, 0));
            CFRelease(matched);
            return source;
        }
        if (matched) CFRelease(matched);
    }

    CFArrayRef all = TISCreateInputSourceList(NULL, false);
    if (!all) return NULL;
    for (CFIndex i = 0; i < CFArrayGetCount(all); i++) {
        TISInputSourceRef source = (TISInputSourceRef)CFArrayGetValueAtIndex(all, i);
        CFStringRef type = TISGetInputSourceProperty(source, kTISPropertyInputSourceType);
        CFBooleanRef ascii = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable);
        CFBooleanRef enabled = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled);
        if (type && CFEqual(type, kTISTypeKeyboardLayout)
            && ascii && CFBooleanGetValue(ascii)
            && (!enabled || CFBooleanGetValue(enabled))) {
            TISInputSourceRef retained = (TISInputSourceRef)CFRetain(source);
            CFRelease(all);
            return retained;
        }
    }
    CFRelease(all);
    return NULL;
}

static BOOL currentInputSourceIsLatinKeyboard(void)
{
    TISInputSourceRef current = TISCopyCurrentKeyboardInputSource();
    if (!current) return NO;
    CFStringRef type = TISGetInputSourceProperty(current, kTISPropertyInputSourceType);
    CFBooleanRef ascii = TISGetInputSourceProperty(current, kTISPropertyInputSourceIsASCIICapable);
    BOOL ok = type && CFEqual(type, kTISTypeKeyboardLayout) && ascii && CFBooleanGetValue(ascii);
    CFRelease(current);
    return ok;
}

static void ensureLatinKeyboardForGame(NSFileHandle *log)
{
    if (currentInputSourceIsLatinKeyboard()) {
        writeLog(log, @"Keyboard already using a Latin layout");
        return;
    }
    if (!gSavedInputSource) {
        gSavedInputSource = TISCopyCurrentKeyboardInputSource();
    }
    TISInputSourceRef latin = copyPreferredLatinKeyboard();
    if (!latin) {
        writeLog(log, @"No Latin keyboard layout available; keyboard may not work under IME");
        return;
    }
    OSStatus status = TISSelectInputSource(latin);
    CFStringRef selectedID = TISGetInputSourceProperty(latin, kTISPropertyInputSourceID);
    writeLog(log, [NSString stringWithFormat:@"Switched input source to %@ (status %d) so Wine can receive keys",
                   selectedID ? (__bridge NSString *)selectedID : @"(unknown)", (int)status]);
    gForcedLatinKeyboard = (status == noErr);
    CFRelease(latin);
}

static void restoreSavedInputSource(NSFileHandle *log)
{
    if (!gForcedLatinKeyboard || !gSavedInputSource) return;
    OSStatus status = TISSelectInputSource(gSavedInputSource);
    CFStringRef restoredID = TISGetInputSourceProperty(gSavedInputSource, kTISPropertyInputSourceID);
    writeLog(log, [NSString stringWithFormat:@"Restored input source to %@ (status %d)",
                   restoredID ? (__bridge NSString *)restoredID : @"(unknown)", (int)status]);
    CFRelease(gSavedInputSource);
    gSavedInputSource = NULL;
    gForcedLatinKeyboard = NO;
}

// FighterTester 右侧 Debug NativeWindow：开发测试面板（选人/地图/开战）。
// 打包版无法改 SWF，故用辅助功能在系统层隐藏/显示该窗口。
static BOOL titleLooksLikeDebugPanel(NSString *title)
{
    if (title.length == 0) return NO;
    NSString *folded = title.lowercaseString;
    return [folded isEqualToString:@"debug"]
        || [folded containsString:@"debug"]
        || [title containsString:@"调试"]
        || [title containsString:@"测试面板"];
}

static BOOL ensureAccessibility(NSFileHandle *log)
{
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    BOOL trusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    if (!trusted) {
        writeLog(log, @"Accessibility permission missing; cannot hide/show the Debug panel");
    }
    return trusted;
}

static NSInteger setDebugPanelsHidden(pid_t pid, BOOL hidden, NSFileHandle *log)
{
    if (pid <= 0) return 0;
    if (!ensureAccessibility(log)) return -1;

    AXUIElementRef app = AXUIElementCreateApplication(pid);
    if (!app) return 0;

    CFTypeRef windowsRef = NULL;
    AXError err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &windowsRef);
    if (err != kAXErrorSuccess || !windowsRef || CFGetTypeID(windowsRef) != CFArrayGetTypeID()) {
        if (windowsRef) CFRelease(windowsRef);
        CFRelease(app);
        writeLog(log, [NSString stringWithFormat:@"AX windows query failed for PID %d (err %d)", pid, (int)err]);
        return 0;
    }

    CFArrayRef windows = (CFArrayRef)windowsRef;
    NSInteger changed = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(windows); i++) {
        AXUIElementRef window = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
        CFTypeRef titleRef = NULL;
        if (AXUIElementCopyAttributeValue(window, kAXTitleAttribute, &titleRef) != kAXErrorSuccess || !titleRef) {
            continue;
        }
        NSString *title = CFGetTypeID(titleRef) == CFStringGetTypeID() ? (__bridge NSString *)titleRef : @"";
        BOOL isDebug = titleLooksLikeDebugPanel(title);
        CFRelease(titleRef);
        if (!isDebug) continue;

        AXError setErr = AXUIElementSetAttributeValue(
            window,
            kAXMinimizedAttribute,
            hidden ? kCFBooleanTrue : kCFBooleanFalse
        );
        if (setErr == kAXErrorSuccess) {
            changed++;
            writeLog(log, [NSString stringWithFormat:@"%@ Debug panel window \"%@\"",
                           hidden ? @"Minimized" : @"Restored", title]);
        } else if (hidden) {
            // 部分 Wine 窗口不支持最小化，改为点关闭按钮（下次启动会再出现）。
            CFTypeRef closeRef = NULL;
            if (AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute, &closeRef) == kAXErrorSuccess
                && closeRef) {
                AXUIElementRef closeBtn = (AXUIElementRef)closeRef;
                if (AXUIElementPerformAction(closeBtn, kAXPressAction) == kAXErrorSuccess) {
                    changed++;
                    writeLog(log, [NSString stringWithFormat:@"Closed Debug panel window \"%@\"", title]);
                }
                CFRelease(closeRef);
            } else {
                writeLog(log, [NSString stringWithFormat:@"Failed to hide Debug panel \"%@\" (err %d)", title, (int)setErr]);
            }
        } else {
            writeLog(log, [NSString stringWithFormat:@"Failed to show Debug panel \"%@\" (err %d)", title, (int)setErr]);
        }
    }

    CFRelease(windows);
    CFRelease(app);
    return changed;
}

static NSURL *wineBundle(void)
{
    return [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"Wine Stable.app" isDirectory:YES];
}

static NSURL *wineExecutable(void)
{
    return [wineBundle() URLByAppendingPathComponent:@"Contents/Resources/wine/bin/wine"];
}

static NSURL *stateDirectory(void)
{
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [support URLByAppendingPathComponent:@"OpenBleachVsNaruto" isDirectory:YES];
}

static NSFileHandle *openLaunchLog(NSError **error)
{
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *state = stateDirectory();
    if (![files createDirectoryAtURL:state withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    NSURL *url = [state URLByAppendingPathComponent:@"launch.log"];
    if (![files fileExistsAtPath:url.path]) [files createFileAtPath:url.path contents:nil attributes:nil];
    NSFileHandle *log = [NSFileHandle fileHandleForWritingToURL:url error:error];
    return [log seekToEndReturningOffset:NULL error:error] ? log : nil;
}

static void writeLog(NSFileHandle *log, NSString *message)
{
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", NSDate.date, message];
    [log writeData:[line dataUsingEncoding:NSUTF8StringEncoding] error:NULL];
}

static NSTask *gameProcess(NSString *prefix, NSFileHandle *log)
{
    NSTask *task = [NSTask new];
    task.executableURL = wineExecutable();
    task.currentDirectoryURL = gameDirectory();
    task.arguments = @[@"./FighterTester.exe"];
    NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    environment[@"WINEPREFIX"] = prefix;
    environment[@"WINEDEBUG"] = @"-all,err+all,warn+macdrv";
    environment[@"MVK_CONFIG_LOG_LEVEL"] = @"0";
    environment[@"WINEDLLOVERRIDES"] = @"mscoree,mshtml=";
    // 尽量减少合成/垂直同步带来的额外限帧
    environment[@"WINE_DISABLE_VSYNC"] = @"1";
    environment[@"vblank_mode"] = @"0";
    environment[@"MESA_VK_WSI_PRESENT_MODE"] = @"immediate";
    if (!environment[@"LANG"]) environment[@"LANG"] = @"en_US.UTF-8";
    task.environment = environment;
    task.standardOutput = log;
    task.standardError = log;
    return task;
}

static BOOL isBundledWineProcess(NSRunningApplication *application)
{
    if (!application || application.terminated || application.activationPolicy != NSApplicationActivationPolicyRegular) return NO;
    pid_t pid = application.processIdentifier;
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (pid <= 0 || proc_pidpath(pid, path, sizeof path) <= 0) return NO;
    NSString *winePath = [wineBundle().URLByResolvingSymlinksInPath.path stringByAppendingString:@"/"];
    return [[NSFileManager.defaultManager stringWithFileSystemRepresentation:path length:strlen(path)] hasPrefix:winePath];
}

static NSString *installError(void)
{
    NSFileManager *files = NSFileManager.defaultManager;
    if (![files isExecutableFileAtPath:wineExecutable().path])
        return @"找不到游戏运行组件。";
    // 校验内置包；运行时会再同步到无中文的 Application Support 路径
    for (NSString *file in @[@"FighterTester.exe", @"FighterTester.swf", @"META-INF/AIR/application.xml"])
        if (![files isReadableFileAtPath:[bundledGameDirectory() URLByAppendingPathComponent:file].path])
            return [NSString stringWithFormat:@"缺少游戏文件 %@。", file];
    return nil;
}

@interface BVNLauncher : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) NSTextField *status;
@property (nonatomic, strong) NSProgressIndicator *progress;
@property (nonatomic, strong) NSButton *retry;
@property (nonatomic, strong) NSTask *gameTask;
@property (nonatomic, strong) NSRunningApplication *gameApp;
@property (nonatomic, strong) NSURL *logURL;
@property (nonatomic, copy) NSString *prefix;
@property (nonatomic, strong) NSFileHandle *gameLog;
@property (nonatomic, strong) NSTask *stopTask;
@property (nonatomic, strong) NSButton *hideDebug;
@property (nonatomic, strong) NSButton *showDebug;
@property (nonatomic) BOOL restartAfterExit;
@end

@implementation BVNLauncher
- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    NSMenu *mainMenu = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    appItem.submenu = [[NSMenu alloc] initWithTitle:@"死神vs火影"];
    [appItem.submenu addItemWithTitle:@"隐藏调试面板" action:@selector(hideDebugPanel:) keyEquivalent:@"d"];
    [appItem.submenu addItemWithTitle:@"显示调试面板" action:@selector(showDebugPanel:) keyEquivalent:@"D"];
    [appItem.submenu addItem:[NSMenuItem separatorItem]];
    [appItem.submenu addItemWithTitle:@"退出" action:@selector(terminate:) keyEquivalent:@"q"];
    [mainMenu addItem:appItem];
    NSApp.mainMenu = mainMenu;

    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 460, 168)
                                             styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                                               backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"死神vs火影 · 开放版";
    self.window.releasedWhenClosed = NO;
    [self.window center];

    self.progress = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(22, 124, 20, 20)];
    self.progress.style = NSProgressIndicatorStyleSpinning;
    self.progress.displayedWhenStopped = NO;
    [self.window.contentView addSubview:self.progress];

    self.status = [NSTextField wrappingLabelWithString:@"正在启动游戏…"];
    self.status.frame = NSMakeRect(54, 78, 380, 66);
    [self.window.contentView addSubview:self.status];

    self.hideDebug = [NSButton buttonWithTitle:@"隐藏调试面板" target:self action:@selector(hideDebugPanel:)];
    self.hideDebug.frame = NSMakeRect(20, 42, 120, 28);
    self.hideDebug.enabled = NO;
    [self.window.contentView addSubview:self.hideDebug];

    self.showDebug = [NSButton buttonWithTitle:@"显示调试面板" target:self action:@selector(showDebugPanel:)];
    self.showDebug.frame = NSMakeRect(148, 42, 120, 28);
    self.showDebug.enabled = NO;
    [self.window.contentView addSubview:self.showDebug];

    self.retry = [NSButton buttonWithTitle:@"再试一次" target:self action:@selector(retryGame:)];
    self.retry.frame = NSMakeRect(240, 10, 96, 28);
    [self.window.contentView addSubview:self.retry];

    NSButton *logButton = [NSButton buttonWithTitle:@"打开日志" target:self action:@selector(openLog:)];
    logButton.frame = NSMakeRect(344, 10, 96, 28);
    [self.window.contentView addSubview:logButton];

    [[NSDistributedNotificationCenter defaultCenter] addObserver:self selector:@selector(wineWillActivate:)
                                                            name:@"WineAppWillActivateNotification" object:nil
                                              suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    self.logURL = [stateDirectory() URLByAppendingPathComponent:@"launch.log"];
    [self.window makeKeyAndOrderFront:nil];
    dispatch_async(dispatch_get_main_queue(), ^{ [self startGame:nil]; });
}

- (void)showProblem:(NSString *)message
{
    [self.progress stopAnimation:nil];
    self.retry.title = self.gameTask ? @"重新启动" : @"再试一次";
    self.retry.enabled = YES;
    self.status.stringValue = message;
}

- (void)openLog:(id)sender
{
    if (self.logURL && [NSFileManager.defaultManager isReadableFileAtPath:self.logURL.path])
        [NSWorkspace.sharedWorkspace openURL:self.logURL];
}

- (void)hideDebugPanel:(id)sender
{
    if (!self.gameApp || self.gameApp.terminated) {
        [self showProblem:@"游戏尚未运行，无法隐藏调试面板。"];
        return;
    }
    NSInteger n = setDebugPanelsHidden(self.gameApp.processIdentifier, YES, self.gameLog);
    if (n < 0) {
        self.status.stringValue = @"需要辅助功能权限才能隐藏调试面板。请在系统设置中允许本应用后重试。";
        return;
    }
    if (n == 0) {
        self.status.stringValue = @"未找到名为 Debug 的调试面板窗口。可直接点该窗口红色关闭按钮。";
        return;
    }
    self.status.stringValue = @"已隐藏调试面板。点「显示调试面板」可恢复；开战请先在面板点「测试」。";
    [self activateGame];
}

- (void)showDebugPanel:(id)sender
{
    if (!self.gameApp || self.gameApp.terminated) {
        [self showProblem:@"游戏尚未运行，无法显示调试面板。"];
        return;
    }
    NSInteger n = setDebugPanelsHidden(self.gameApp.processIdentifier, NO, self.gameLog);
    if (n < 0) {
        self.status.stringValue = @"需要辅助功能权限才能显示调试面板。请在系统设置中允许本应用后重试。";
        return;
    }
    if (n == 0) {
        self.status.stringValue = @"没有可恢复的调试面板（若已关闭窗口，请重新启动游戏）。";
        return;
    }
    self.status.stringValue = @"已显示调试面板（选角色/地图并点「测试」开战）。";
}

- (void)startGame:(id)sender
{
    if (self.gameTask || self.stopTask) return;
    NSError *error = nil;
    NSFileHandle *log = openLaunchLog(&error);
    if (!log) {
        [self showProblem:error.localizedDescription ?: @"无法写入游戏启动日志。"];
        return;
    }
    writeLog(log, @"Beginning a new launch attempt");
    NSString *problem = installError();
    if (problem) {
        writeLog(log, problem);
        [log closeFile];
        [self showProblem:problem];
        return;
    }
    NSError *syncError = nil;
    if (!syncGameToAsciiPath(log, &syncError)) {
        NSString *msg = syncError.localizedDescription ?: @"无法同步游戏文件到英文路径。";
        writeLog(log, msg);
        [log closeFile];
        [self showProblem:msg];
        return;
    }
    // Wine keys its server to the prefix directory. Leave the old one and its processes alone.
    self.prefix = [stateDirectory() URLByAppendingPathComponent:@"wine-game" isDirectory:YES].path;
    NSTask *task = gameProcess(self.prefix, log);
    self.gameApp = nil;
    self.gameTask = task;
    self.gameLog = log;
    self.retry.enabled = NO;
    self.status.stringValue = @"正在启动游戏。首次运行需要初始化，请稍等。";
    [self.progress startAnimation:nil];

    __weak BVNLauncher *weakSelf = self;
    task.terminationHandler = ^(NSTask *finished) {
        dispatch_async(dispatch_get_main_queue(), ^{
            BVNLauncher *launcher = weakSelf;
            NSString *reason = finished.terminationReason == NSTaskTerminationReasonExit ? @"exit" : @"signal";
            int code = finished.terminationStatus;
            writeLog(log, [NSString stringWithFormat:@"Wine %@ %d", reason, code]);
            restoreSavedInputSource(log);
            [log closeFile];
            launcher.gameTask = nil;
            launcher.gameLog = nil;
            BOOL showedGame = launcher.gameApp != nil;
            launcher.gameApp = nil;
            if (launcher.restartAfterExit) {
                if (!launcher.stopTask) {
                    launcher.restartAfterExit = NO;
                    [launcher startGame:nil];
                }
            } else if (code == 0 && showedGame) {
                [NSApp terminate:nil];
            } else {
                NSString *status = finished.terminationReason == NSTaskTerminationReasonExit ? @"退出码" : @"信号";
                [launcher showProblem:[NSString stringWithFormat:@"游戏进程已退出（%@ %d）。可以打开日志查看详情。", status, code]];
                [launcher.window makeKeyAndOrderFront:nil];
            }
        });
    };
    if (![task launchAndReturnError:&error]) {
        writeLog(log, error.localizedDescription);
        [log closeFile];
        self.gameTask = nil;
        self.gameLog = nil;
        [self showProblem:error.localizedDescription];
        return;
    }
    writeLog(log, [NSString stringWithFormat:@"Started Wine PID %d for FighterTester.exe", task.processIdentifier]);
    ensureLatinKeyboardForGame(log);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 180 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        BVNLauncher *launcher = weakSelf;
        if (launcher.gameTask != task || launcher.gameApp || launcher.restartAfterExit) return;
        writeLog(log, @"No game-window activation after 180 seconds");
        [launcher showProblem:@"等待游戏窗口超时。可以重新启动或打开日志。"];
    });
}

- (void)retryGame:(id)sender
{
    if (self.stopTask) return;
    NSTask *previous = self.gameTask;
    if (!previous) {
        [self startGame:sender];
        return;
    }
    self.restartAfterExit = YES;
    self.retry.enabled = NO;
    self.status.stringValue = @"正在关闭本次启动…";
    writeLog(self.gameLog, @"Restart requested for the game's Wine prefix");

    NSTask *stop = [NSTask new];
    stop.executableURL = [wineExecutable().URLByDeletingLastPathComponent URLByAppendingPathComponent:@"wineserver"];
    stop.arguments = @[@"-k"];
    stop.environment = previous.environment;
    stop.standardOutput = self.gameLog;
    stop.standardError = self.gameLog;
    self.stopTask = stop;
    __weak BVNLauncher *weakSelf = self;
    stop.terminationHandler = ^(NSTask *finished) {
        dispatch_async(dispatch_get_main_queue(), ^{
            BVNLauncher *launcher = weakSelf;
            if (launcher.stopTask != finished) return;
            launcher.stopTask = nil;
            if (!launcher.gameTask) {
                launcher.restartAfterExit = NO;
                [launcher startGame:nil];
                return;
            }
            if (finished.terminationStatus == 0 && previous.running) {
                [previous terminate];
            } else if (finished.terminationStatus != 0) {
                launcher.restartAfterExit = NO;
                writeLog(launcher.gameLog, [NSString stringWithFormat:@"wineserver -k exited with %d", finished.terminationStatus]);
                [launcher showProblem:@"暂时无法关闭本次启动。可以打开日志查看详情。"];
            }
        });
    };
    NSError *error;
    if (![stop launchAndReturnError:&error]) {
        self.stopTask = nil;
        self.restartAfterExit = NO;
        writeLog(self.gameLog, error.localizedDescription);
        [self showProblem:error.localizedDescription];
    }
}

- (void)wineWillActivate:(NSNotification *)notification
{
    if (!self.gameTask || ![notification.userInfo[@"ActivatingAppPrefix"] isEqual:self.prefix]) return;
    NSNumber *process = notification.userInfo[@"ActivatingAppPID"];
    if (![process isKindOfClass:NSNumber.class]) return;
    NSRunningApplication *application = [NSRunningApplication runningApplicationWithProcessIdentifier:process.intValue];
    if (isBundledWineProcess(application)) [self foundGame:application];
}

- (void)foundGame:(NSRunningApplication *)application
{
    if (self.restartAfterExit) return;
    self.gameApp = application;
    writeLog(self.gameLog, [NSString stringWithFormat:@"Received game-window activation from PID %d", application.processIdentifier]);
    ensureLatinKeyboardForGame(self.gameLog);
    self.retry.enabled = NO;
    self.hideDebug.enabled = YES;
    self.showDebug.enabled = YES;
    [self.progress stopAnimation:nil];
    self.status.stringValue = @"加载完成后请点右侧「开始测试」进入对战。可用「隐藏调试面板」。请保持英文键盘 ABC。";
    if (NSApp.isActive) [self activateGame];
    // 窗口激活后 macOS 可能按应用恢复输入法，稍后再强制一次英文布局。
    __weak BVNLauncher *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BVNLauncher *launcher = weakSelf;
        if (!launcher.gameApp || launcher.gameApp.terminated) return;
        ensureLatinKeyboardForGame(launcher.gameLog);
        [launcher activateGame];
    });
}

- (BOOL)activateGame
{
    if (!self.gameApp || self.gameApp.terminated) return NO;
    ensureLatinKeyboardForGame(self.gameLog);
    [NSApp yieldActivationToApplication:self.gameApp];
    return [self.gameApp activateFromApplication:NSRunningApplication.currentApplication options:0];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)application hasVisibleWindows:(BOOL)visible
{
    if (![self activateGame]) {
        [self.window makeKeyAndOrderFront:nil];
    }
    return NO;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)application
{
    return self.gameTask == nil;
}
@end

int main(int argc, const char **argv)
{
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--check") == 0) {
            NSString *problem = installError();
            if (problem) {
                fprintf(stderr, "%s\n", problem.UTF8String);
                return EXIT_FAILURE;
            }
            NSTask *check = gameProcess([NSTemporaryDirectory() stringByAppendingPathComponent:@"bvn-version-check"], nil);
            check.arguments = @[@"--version"];
            check.standardOutput = NSFileHandle.fileHandleWithStandardOutput;
            check.standardError = NSFileHandle.fileHandleWithStandardError;
            NSError *error;
            if (![check launchAndReturnError:&error]) {
                fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
                return EXIT_FAILURE;
            }
            [check waitUntilExit];
            return check.terminationStatus;
        }
        NSFileHandle *log = openLaunchLog(NULL);
        writeLog(log, @"Entered the macOS launcher");
        [log closeFile];
        NSApplication *application = NSApplication.sharedApplication;
        [application setActivationPolicy:NSApplicationActivationPolicyRegular];
        __attribute__((objc_precise_lifetime)) BVNLauncher *launcher = [BVNLauncher new];
        application.delegate = launcher;
        [application run];
    }
    return EXIT_SUCCESS;
}
