// The launcher inside the packaged app (build_app.py compiles it as Contents/MacOS/TOTK).
// The game itself is Contents/Resources/totk/build/totk-native; everything it writes goes to the player's own folders:
//   ~/Library/Application Support/MacNativeGames/TOTK/   profile (account, saves), shader cache, game slot, RomFS proof
//   ~/Library/Logs/MacNativeGames/totk.log             this run (totk.previous.log: the one before)
// If the game is already running, the launcher only brings it to the front.
//
// This is the settings window: choose a save profile, a merged mod overlay, the three performance
// overlays, a performance mode and controller features, then press Start. The choices are stored in
// <data>/launcher-settings.json and applied as environment variables before exec'ing the game.
// TOTK_LAUNCHER_AUTO=1 (or --play) skips the window and starts with the stored/environment settings.
#import <AppKit/AppKit.h>
#import <GameController/GameController.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/proc.h>
#include <unistd.h>
#include "dmsh_chain.h"   // DMSH_CHAIN: the shader translation chain the cache folder is named after
#include "game_version.h"

static void show_error(NSString *detail) {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"The game could not start";
    alert.informativeText = detail;
    [alert runModal];
}

static NSDictionary<NSString *, NSString *> *kv_read(NSString *path) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *key = [line substringToIndex:eq.location];
        if (!out[key]) out[key] = [line substringFromIndex:eq.location + 1];
    }
    return out;
}

static uint64_t pid_start(pid_t pid) {   // 0 if gone or a zombie; with the pid it names one process exactly
    struct proc_bsdinfo bi;
    if (pid <= 0 || proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, sizeof bi) != (int)sizeof bi || bi.pbi_status == SZOMB) return 0;
    return bi.pbi_start_tvsec;
}

/* The game slot (runtime/game_slot.c): the running game holds an exclusive lock on <slot>/lock and names itself in
   <slot>/holder. Returns the running game's pid, or 0. */
static pid_t running_game(NSString *slot) {
    int fd = open([slot stringByAppendingPathComponent:@"lock"].fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    int held = flock(fd, LOCK_EX | LOCK_NB) != 0;
    close(fd);
    if (!held) return 0;
    NSDictionary *h = kv_read([slot stringByAppendingPathComponent:@"holder"]);
    /* A player launch must reach runtime/game_slot.c to preempt an agent's
       test. Only an existing player game (or another test for a test request)
       is brought forward here. */
    const char *requestOwner = getenv("TOTK_SLOT_OWNER");
    if (![h[@"owner"] isEqualToString:@"user"] &&
        (!requestOwner || !*requestOwner || !strcmp(requestOwner, "user"))) return 0;
    pid_t pid = [h[@"game_pid"] intValue];
    return pid > 0 && pid_start(pid) == (uint64_t)[h[@"game_start"] longLongValue] ? pid : 0;
}

static BOOL make_dir(NSString *path) {
    return [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
}

static BOOL is_dir(NSString *path) {
    BOOL d = NO;
    return [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&d] && d;
}

static NSString *env_string(const char *name) {
    const char *v = getenv(name);
    return v && *v ? @(v) : nil;
}

@interface TOTKLauncher : NSObject <NSWindowDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) NSTextField *profileField;
@property (nonatomic, strong) NSTextField *modField;
@property (nonatomic, strong) NSTextField *statusField;
@property (nonatomic, strong) NSButton *fpsCheck;
@property (nonatomic, strong) NSButton *shaderCheck;
@property (nonatomic, strong) NSButton *loadCheck;
@property (nonatomic, strong) NSButton *perfCheck;
@property (nonatomic, strong) NSButton *mfxCheck;
@property (nonatomic, strong) NSButton *mfxScaleCheck;
@property (nonatomic, strong) NSButton *skipWarmCheck;
@property (nonatomic, strong) NSButton *fullscreenCheck;
@property (nonatomic, strong) NSTextField *outputResField;
@property (nonatomic, strong) NSTextField *windowSizeField;
@property (nonatomic, strong) NSPopUpButton *fillPopup;
@property (nonatomic, strong) NSPopUpButton *aspectPopup;
@property (nonatomic, strong) NSTextField *controllerStatus;
@property (nonatomic, strong) NSButton *swapCheck;
@property (nonatomic, strong) NSButton *rumbleCheck;
@property (nonatomic, strong) NSButton *gyroCheck;
@property (nonatomic, copy) NSString *root;
@property (nonatomic, copy) NSString *binary;
@property (nonatomic, copy) NSString *data;
@property (nonatomic, copy) NSString *logs;
@property (nonatomic, copy) NSString *defaultProfile;
@property (nonatomic, copy) NSString *defaultSlot;
@property (nonatomic, copy) NSString *defaultCache;
@property (nonatomic, copy) NSString *settingsPath;
@property (nonatomic, copy) NSDictionary *saved;
@property (nonatomic, copy) NSString *profileValue;
@property (nonatomic, copy) NSString *modValue;
@property (nonatomic) BOOL fpsOn;
@property (nonatomic) BOOL shaderOn;
@property (nonatomic) BOOL loadOn;
@property (nonatomic) BOOL perfOn;
@property (nonatomic) BOOL mfxOff;
@property (nonatomic) BOOL mfxScale;
@property (nonatomic) BOOL skipWarm;
@property (nonatomic) BOOL fullscreenOn;
@property (nonatomic, copy) NSString *outputRes;
@property (nonatomic, copy) NSString *windowSize;
@property (nonatomic, copy) NSString *pictureFill;
@property (nonatomic, copy) NSString *aspectRatio;
@property (nonatomic) BOOL swapOn;
@property (nonatomic) BOOL rumbleOn;
@property (nonatomic) BOOL gyroOn;
@property (nonatomic) BOOL autoMode;
@end

@implementation TOTKLauncher

- (NSString *)trimmed:(NSString *)s {
    return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (NSString *)expanded:(NSString *)s fallback:(NSString *)fallback {
    NSString *t = [self trimmed:s ?: @""];
    return t.length ? t.stringByExpandingTildeInPath : fallback;
}

- (void)loadSettings {
    NSData *json = [NSData dataWithContentsOfFile:self.settingsPath];
    id obj = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
    self.saved = [obj isKindOfClass:NSDictionary.class] ? obj : @{};

    NSString *p = self.saved[@"profile"];
    NSString *m = self.saved[@"mod"];
    NSString *envProfile = env_string("TOTK_PROFILE_DIR");
    NSString *envMod = env_string("TOTK_ROMFS_PATCHES");
    self.profileValue = envProfile.length ? envProfile : ([p isKindOfClass:NSString.class] && p.length ? p : self.defaultProfile);
    self.modValue = envMod.length && strcmp(envMod.UTF8String, "0") ? envMod : ([m isKindOfClass:NSString.class] ? m : @"");

    self.fpsOn = [self initialBool:@"fps" env:"TOTK_FPS_OVERLAY" def:YES];
    self.shaderOn = [self initialBool:@"shader" env:"TOTK_SHADER_OVERLAY" def:YES];
    self.loadOn = [self initialBool:@"load" env:"TOTK_LOAD_OVERLAY" def:YES];
    self.perfOn = [self initialBool:@"perf" env:"TOTK_DRAWABLE_SCALE" def:NO];
    self.mfxOff = [self initialBool:@"mfx_off" env:"TOTK_MFX_OUTPUT" def:NO];
    self.mfxScale = [self initialBool:@"mfx_scale" env:"TOTK_MFX_UPSCALE" def:NO];
    { id v = self.saved[@"skip_warm"]; const char *pm = getenv("DM_PSO_MANIFEST");
      self.skipWarm = (pm && !strcmp(pm, "off")) ? YES : ([v isKindOfClass:NSNumber.class] ? [v boolValue] : NO); }
    self.fullscreenOn = [self initialBool:@"fullscreen" env:"TOTK_FULLSCREEN" def:NO];
    { NSString *v = env_string("TOTK_OUTPUT_RES"); if (!v.length) v = self.saved[@"output_res"];
      self.outputRes = [v isKindOfClass:NSString.class] ? v : @""; }
    { NSString *v = env_string("TOTK_WINDOW_SIZE"); if (!v.length) v = self.saved[@"window_size"];
      self.windowSize = [v isKindOfClass:NSString.class] ? v : @""; }
    { NSString *v = env_string("TOTK_PICTURE_FILL"); if (!v.length) v = self.saved[@"picture_fill"];
      self.pictureFill = [v isKindOfClass:NSString.class] && v.length ? v : @"fit"; }
    { NSString *v = env_string("TOTK_ASPECT_RATIO"); if (!v.length) v = self.saved[@"aspect_ratio"];
      self.aspectRatio = [v isKindOfClass:NSString.class] && v.length ? v : @"custom"; }
    self.swapOn = [self initialBool:@"swap" env:"TOTK_GAMEPAD_SWAP_ABXY" def:NO];
    self.rumbleOn = [self initialBool:@"rumble" env:"TOTK_RUMBLE" def:NO];
    self.gyroOn = [self initialBool:@"gyro" env:"TOTK_GYRO" def:NO];
}

- (BOOL)initialBool:(NSString *)key env:(const char *)name def:(BOOL)def {
    const char *e = getenv(name);
    if (e) return strcmp(e, "0") != 0;
    id v = self.saved[key];
    return [v isKindOfClass:NSNumber.class] ? [v boolValue] : def;
}

- (NSTextField *)label:(NSString *)text frame:(NSRect)frame size:(CGFloat)size bold:(BOOL)bold color:(NSColor *)color {
    NSTextField *t = [NSTextField labelWithString:text];
    t.frame = frame;
    t.font = bold ? [NSFont boldSystemFontOfSize:size] : [NSFont systemFontOfSize:size];
    t.textColor = color ?: NSColor.labelColor;
    return t;
}

- (NSTextField *)pathField:(NSString *)value frame:(NSRect)frame {
    NSTextField *f = [NSTextField textFieldWithString:value ?: @""];
    f.frame = frame;
    f.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    f.lineBreakMode = NSLineBreakByTruncatingMiddle;
    return f;
}

- (NSButton *)check:(NSString *)title frame:(NSRect)frame on:(BOOL)on {
    NSButton *b = [NSButton checkboxWithTitle:title target:nil action:nil];
    b.frame = frame;
    b.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    b.font = [NSFont systemFontOfSize:12];
    return b;
}

- (NSButton *)button:(NSString *)title frame:(NSRect)frame action:(SEL)action key:(NSString *)key {
    NSButton *b = [NSButton buttonWithTitle:title target:self action:action];
    b.frame = frame;
    b.bezelStyle = NSBezelStyleRounded;
    if (key) b.keyEquivalent = key;
    return b;
}

- (NSBox *)separator:(CGFloat)y {
    NSBox *s = [NSBox new];
    s.boxType = NSBoxSeparator;
    s.frame = NSMakeRect(20, y, 620, 1);
    return s;
}

- (void)buildWindow {
    NSRect content = NSMakeRect(0, 0, 660, 640);
    self.window = [[NSWindow alloc] initWithContentRect:content
                                             styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    self.window.title = [NSString stringWithFormat:@"Tears of the Kingdom Mac — 启动设置 · Ver. %s", TOTK_GAME_VERSION];
    self.window.releasedWhenClosed = NO;
    self.window.delegate = self;
    [self.window center];
    NSView *v = [[NSView alloc] initWithFrame:content];
    self.window.contentView = v;

    [v addSubview:[self label:@"Tears of the Kingdom Mac" frame:NSMakeRect(20, 598, 620, 30) size:23 bold:YES color:nil]];
    [v addSubview:[self label:[NSString stringWithFormat:@"Ver. %s · 设置启动选项", TOTK_GAME_VERSION]
                        frame:NSMakeRect(20, 574, 620, 20) size:12 bold:NO color:NSColor.secondaryLabelColor]];

    [v addSubview:[self label:@"存档 profile" frame:NSMakeRect(20, 535, 95, 20) size:13 bold:YES color:nil]];
    self.profileField = [self pathField:self.profileValue frame:NSMakeRect(115, 531, 430, 25)];
    [v addSubview:self.profileField];
    [v addSubview:[self button:@"选择…" frame:NSMakeRect(555, 529, 85, 27) action:@selector(chooseProfile:) key:nil]];
    [v addSubview:[self label:@"换存档时选另一个 profile 目录；首次更新版本启动会自动备份为 profile-before-<版本>。"
                        frame:NSMakeRect(20, 509, 620, 18) size:11 bold:NO color:NSColor.secondaryLabelColor]];

    [v addSubview:[self label:@"添加Mod" frame:NSMakeRect(20, 475, 95, 20) size:13 bold:YES color:nil]];
    self.modField = [self pathField:self.modValue frame:NSMakeRect(115, 471, 350, 25)];
    [v addSubview:self.modField];
    [v addSubview:[self button:@"选择…" frame:NSMakeRect(475, 469, 75, 27) action:@selector(chooseMod:) key:nil]];
    [v addSubview:[self button:@"清除" frame:NSMakeRect(558, 469, 82, 27) action:@selector(clearMod:) key:nil]];
    [v addSubview:[self label:@"只支持替换 RomFS 已有文件；用 make_mod_overlay.py 生成目录（含 manifest.tsv）；留空 = 内置。"
                        frame:NSMakeRect(20, 449, 620, 18) size:11 bold:NO color:NSColor.secondaryLabelColor]];

    [v addSubview:[self separator:438]];
    [v addSubview:[self label:@"性能浮层（游戏内按 4 也可随时开关）" frame:NSMakeRect(20, 410, 620, 20) size:13 bold:YES color:nil]];
    self.fpsCheck = [self check:@"FPS（右上）" frame:NSMakeRect(20, 382, 150, 22) on:self.fpsOn];
    self.shaderCheck = [self check:@"着色器（左下）" frame:NSMakeRect(190, 382, 170, 22) on:self.shaderOn];
    self.loadCheck = [self check:@"系统负载（右下）" frame:NSMakeRect(380, 382, 180, 22) on:self.loadOn];
    [v addSubview:self.fpsCheck];
    [v addSubview:self.shaderCheck];
    [v addSubview:self.loadCheck];

    [v addSubview:[self separator:360]];
    [v addSubview:[self label:@"性能" frame:NSMakeRect(20, 332, 620, 20) size:13 bold:YES color:nil]];
    self.perfCheck = [self check:@"性能模式：1x 画布" frame:NSMakeRect(20, 304, 540, 22) on:self.perfOn];
    self.mfxCheck = [self check:@"关闭 MetalFX 输出超分" frame:NSMakeRect(20, 278, 290, 22) on:self.mfxOff];
    self.mfxScaleCheck = [self check:@"MetalFX 空间超分（默认关）" frame:NSMakeRect(330, 278, 310, 22) on:self.mfxScale];
    self.skipWarmCheck = [self check:@"跳过首次着色器预热（更快；可能编译黑块/卡顿）" frame:NSMakeRect(20, 252, 620, 22) on:self.skipWarm];
    [v addSubview:self.perfCheck];
    [v addSubview:self.mfxCheck];
    [v addSubview:self.mfxScaleCheck];
    [v addSubview:self.skipWarmCheck];

    [v addSubview:[self separator:242]];
    self.fullscreenCheck = [self check:@"全屏启动" frame:NSMakeRect(20, 218, 130, 22) on:self.fullscreenOn];
    [v addSubview:self.fullscreenCheck];
    [v addSubview:[self label:@"输出分辨率" frame:NSMakeRect(158, 219, 80, 20) size:12 bold:NO color:nil]];
    self.outputResField = [self pathField:self.outputRes frame:NSMakeRect(238, 217, 120, 24)];
    self.outputResField.placeholderString = @"自动/2560x1440";
    [v addSubview:self.outputResField];
    [v addSubview:[self label:@"窗口" frame:NSMakeRect(370, 219, 42, 20) size:12 bold:NO color:nil]];
    self.windowSizeField = [self pathField:self.windowSize frame:NSMakeRect(414, 217, 88, 24)];
    self.windowSizeField.placeholderString = @"留空自动";
    [v addSubview:self.windowSizeField];

    [v addSubview:[self label:@"比例" frame:NSMakeRect(20, 191, 40, 20) size:12 bold:NO color:nil]];
    self.aspectPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(62, 188, 120, 26) pullsDown:NO];
    [self.aspectPopup addItemsWithTitles:@[@"自定义", @"16:9", @"16:10", @"4:2 (2:1)", @"3:2", @"4:3", @"21:9"]];
    { NSArray *keys = @[@"custom", @"16:9", @"16:10", @"4:2", @"3:2", @"4:3", @"21:9"];
      NSUInteger i = [keys indexOfObject:self.aspectRatio]; if (i == NSNotFound) i = 0;
      [self.aspectPopup selectItemAtIndex:(NSInteger)i]; }
    self.aspectPopup.target = self; self.aspectPopup.action = @selector(aspectChanged:);
    [v addSubview:self.aspectPopup];
    [v addSubview:[self label:@"填充" frame:NSMakeRect(196, 191, 40, 20) size:12 bold:NO color:nil]];
    self.fillPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(238, 188, 120, 26) pullsDown:NO];
    [self.fillPopup addItemsWithTitles:@[@"保持比例", @"拉伸铺满", @"裁剪铺满"]];
    [self.fillPopup selectItemAtIndex:[self.pictureFill isEqualToString:@"stretch"] ? 1 : [self.pictureFill isEqualToString:@"crop"] ? 2 : 0];
    [v addSubview:self.fillPopup];
    [v addSubview:[self label:@"输出=画布/UI · 填充=整屏" frame:NSMakeRect(370, 192, 270, 18) size:10 bold:NO color:NSColor.secondaryLabelColor]];

    [v addSubview:[self label:@"手柄" frame:NSMakeRect(20, 162, 620, 20) size:13 bold:YES color:nil]];
    self.rumbleCheck = [self check:@"HD 震动" frame:NSMakeRect(20, 134, 260, 22) on:self.rumbleOn];
    self.gyroCheck = [self check:@"六轴体感" frame:NSMakeRect(300, 134, 260, 22) on:self.gyroOn];
    [v addSubview:self.rumbleCheck];
    [v addSubview:self.gyroCheck];
    self.swapCheck = [self check:@"交换 X/Y、A/B" frame:NSMakeRect(20, 110, 260, 22) on:self.swapOn];
    [v addSubview:self.swapCheck];
    self.controllerStatus = [self label:@"手柄：未连接" frame:NSMakeRect(300, 110, 320, 20) size:11 bold:NO color:NSColor.secondaryLabelColor];
    [v addSubview:self.controllerStatus];

    [v addSubview:[self button:@"开始游戏" frame:NSMakeRect(20, 62, 150, 36) action:@selector(startGame:) key:@"\r"]];
    [v addSubview:[self button:@"恢复默认" frame:NSMakeRect(180, 62, 110, 36) action:@selector(resetDefaults:) key:nil]];
    [v addSubview:[self button:@"退出游戏" frame:NSMakeRect(528, 62, 112, 36) action:@selector(quit:) key:nil]];
    self.statusField = [self label:@"数字键：1 MetalFX开关 · 2 补帧 · 3 画质 · 4 性能窗口开关"
                            frame:NSMakeRect(20, 20, 620, 32) size:11 bold:NO color:NSColor.secondaryLabelColor];
    self.statusField.lineBreakMode = NSLineBreakByWordWrapping;
    self.statusField.maximumNumberOfLines = 2;
    [v addSubview:self.statusField];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(controllerChanged:) name:GCControllerDidConnectNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(controllerChanged:) name:GCControllerDidDisconnectNotification object:nil];
    [self updateControllerStatus];

    [self.window makeFirstResponder:self.profileField];
}

- (void)aspectChanged:(id)sender {
    (void)sender;
    NSInteger i = self.aspectPopup.indexOfSelectedItem;
    NSArray *keys = @[@"custom", @"16:9", @"16:10", @"4:2", @"3:2", @"4:3", @"21:9"];
    NSArray *dims = @[@"", @"2560x1440", @"2560x1600", @"2560x1280", @"2560x1706", @"2560x1920", @"2560x1098"];
    if (i < 0 || i >= (NSInteger)keys.count) i = 0;
    self.aspectRatio = keys[(NSUInteger)i];
    if (i > 0) {
        self.outputResField.stringValue = dims[(NSUInteger)i];
        self.fullscreenCheck.state = NSControlStateValueOn;   /* every aspect preset opens full screen */
        self.statusField.stringValue = [NSString stringWithFormat:@"已切换 %@：输出分辨率 %@（全屏）", self.aspectPopup.titleOfSelectedItem, dims[(NSUInteger)i]];
    }
}

- (void)controllerChanged:(NSNotification *)note {
    (void)note;
    [self updateControllerStatus];
}

- (void)updateControllerStatus {
    NSArray<GCController *> *pads = GCController.controllers;
    if (pads.count == 0) {
        self.controllerStatus.stringValue = @"手柄：未连接";
        return;
    }
    GCController *pad = pads.firstObject;
    NSString *name = pad.vendorName.length ? pad.vendorName : (pad.productCategory.length ? pad.productCategory : @"未知手柄");
    if (pads.count == 1) self.controllerStatus.stringValue = [NSString stringWithFormat:@"手柄：已连接 — %@", name];
    else self.controllerStatus.stringValue = [NSString stringWithFormat:@"手柄：已连接 %lu 个 — %@", (unsigned long)pads.count, name];
}

- (void)windowWillClose:(NSNotification *)note {
    (void)note;
    [NSApp terminate:nil];
}

- (void)chooseProfile:(id)sender {
    (void)sender;
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseDirectories = YES;
    p.canChooseFiles = NO;
    p.canCreateDirectories = YES;
    p.prompt = @"选择";
    p.message = @"选择存档 profile 目录（可以新建一个）";
    if ([p runModal] == NSModalResponseOK && p.URL) self.profileField.stringValue = p.URL.path;
}

- (void)chooseMod:(id)sender {
    (void)sender;
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseDirectories = YES;
    p.canChooseFiles = NO;
    p.canCreateDirectories = NO;
    p.prompt = @"选择";
    p.message = @"选择 make_mod_overlay.py 生成的 overlay 目录（含 manifest.tsv）";
    if ([p runModal] == NSModalResponseOK && p.URL) self.modField.stringValue = p.URL.path;
}

- (void)clearMod:(id)sender {
    (void)sender;
    self.modField.stringValue = @"";
}

- (void)resetDefaults:(id)sender {
    (void)sender;
    self.profileField.stringValue = self.defaultProfile;
    self.modField.stringValue = @"";
    self.fpsCheck.state = NSControlStateValueOn;
    self.shaderCheck.state = NSControlStateValueOn;
    self.loadCheck.state = NSControlStateValueOn;
    self.perfCheck.state = NSControlStateValueOff;
    self.mfxCheck.state = NSControlStateValueOff;
    self.mfxScaleCheck.state = NSControlStateValueOff;
    self.skipWarmCheck.state = NSControlStateValueOff;
    self.fullscreenCheck.state = NSControlStateValueOff;
    self.outputResField.stringValue = @"";
    self.windowSizeField.stringValue = @"";
    [self.aspectPopup selectItemAtIndex:0];
    [self.fillPopup selectItemAtIndex:0];
    self.swapCheck.state = NSControlStateValueOff;
    self.rumbleCheck.state = NSControlStateValueOff;
    self.gyroCheck.state = NSControlStateValueOff;
    self.statusField.stringValue = @"已恢复默认：输出自动、保持比例、三个浮层开、MetalFX 关";
}

- (BOOL)saveSettings:(NSString *)profile mod:(NSString *)mod {
    NSDictionary *d = @{
        @"profile": profile ?: @"",
        @"mod": mod ?: @"",
        @"fps": @(self.fpsCheck.state == NSControlStateValueOn),
        @"shader": @(self.shaderCheck.state == NSControlStateValueOn),
        @"load": @(self.loadCheck.state == NSControlStateValueOn),
        @"perf": @(self.perfCheck.state == NSControlStateValueOn),
        @"mfx_off": @(self.mfxCheck.state == NSControlStateValueOn),
        @"mfx_scale": @(self.mfxScaleCheck.state == NSControlStateValueOn),
        @"skip_warm": @(self.skipWarmCheck.state == NSControlStateValueOn),
        @"fullscreen": @(self.fullscreenCheck.state == NSControlStateValueOn),
        @"output_res": self.outputResField.stringValue ?: @"",
        @"window_size": self.windowSizeField.stringValue ?: @"",
        @"picture_fill": @[@"fit", @"stretch", @"crop"][MAX(0, MIN(2, self.fillPopup.indexOfSelectedItem))],
        @"aspect_ratio": self.aspectRatio ?: @"custom",
        @"swap": @(self.swapCheck.state == NSControlStateValueOn),
        @"rumble": @(self.rumbleCheck.state == NSControlStateValueOn),
        @"gyro": @(self.gyroCheck.state == NSControlStateValueOn),
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingPrettyPrinted error:nil];
    if (!json) return NO;
    return [json writeToFile:self.settingsPath atomically:YES];
}

- (void)startGame:(id)sender {
    (void)sender;
    NSString *profile = [self expanded:self.profileField.stringValue fallback:self.defaultProfile];
    NSString *mod = [self expanded:self.modField.stringValue fallback:@""];
    if (!make_dir(profile)) {
        show_error([NSString stringWithFormat:@"Cannot create the profile folder:\n%@", profile]);
        return;
    }
    if (mod.length) {
        if (!is_dir(mod)) {
            show_error([NSString stringWithFormat:@"Mod overlay folder does not exist:\n%@", mod]);
            return;
        }
        if (![NSFileManager.defaultManager fileExistsAtPath:[mod stringByAppendingPathComponent:@"manifest.tsv"]]) {
            show_error([NSString stringWithFormat:@"This folder has no manifest.tsv.\nGenerate it with scripts/make_mod_overlay.py:\n%@", mod]);
            return;
        }
    }
    NSString *out = [self trimmed:self.outputResField.stringValue ?: @""];
    if (out.length && strcasecmp(out.UTF8String, "auto") && strcmp(out.UTF8String, "0")) {
        unsigned w = 0, h = 0; char tail = 0;
        if (sscanf(out.UTF8String, "%ux%u%c", &w, &h, &tail) != 2 || w < 640 || h < 360 || w > 7680 || h > 4320) {
            show_error(@"Output resolution must be empty, auto, 0 or WxH (640x360 .. 7680x4320).");
            return;
        }
    }
    NSString *win = [self trimmed:self.windowSizeField.stringValue ?: @""];
    if (win.length) {
        unsigned w = 0, h = 0; char tail = 0;
        if (sscanf(win.UTF8String, "%ux%u%c", &w, &h, &tail) != 2 || w < 320 || h < 180 || w > 8192 || h > 8192) {
            show_error(@"Window size must be empty or WxH (320x180 .. 8192x8192).");
            return;
        }
    }
    if (!self.autoMode && ![self saveSettings:profile mod:mod]) {
        self.statusField.stringValue = @"警告：设置无法保存，本次仍会按窗口选项启动。";
    }
    [self launchProfile:profile mod:mod];
}

- (void)launchProfile:(NSString *)profile mod:(NSString *)mod {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (!make_dir(self.data) || !make_dir(self.logs) || !make_dir(self.defaultSlot) || !make_dir(self.defaultCache)) {
        show_error([NSString stringWithFormat:@"Cannot create %@.", self.data]);
        return;
    }
#if defined(TOTK_GAME_V112) || defined(TOTK_GAME_V143)
    NSString *backup = [profile stringByAppendingFormat:@"-before-%s", TOTK_GAME_VERSION];
    if (![fm fileExistsAtPath:backup]) {
        NSString *temporary = [backup stringByAppendingFormat:@".copy-%d", getpid()];
        NSError *error = nil;
        if (![fm copyItemAtPath:profile toPath:temporary error:&error] ||
            ![fm moveItemAtPath:temporary toPath:backup error:&error]) {
            [fm removeItemAtPath:temporary error:nil];
            show_error([@"Cannot back up saves before upgrading: " stringByAppendingString:error.localizedDescription ?: @"unknown error"]);
            return;
        }
    }
#endif
    if (chdir(self.root.fileSystemRepresentation) != 0) {   // the game reads its data relative to this folder
        show_error(@"Cannot open the game folder inside the app.");
        return;
    }
    setenv("TOTK_PROFILE_DIR", profile.fileSystemRepresentation, 1);
    setenv("TOTK_SHADER_CACHE", self.defaultCache.fileSystemRepresentation, 1);
    setenv("TOTK_GAME_SLOT_DIR", self.defaultSlot.fileSystemRepresentation, 1);
    setenv("TOTK_ROMFS_PROOF_DIR", self.data.fileSystemRepresentation, 1);   // the app bundle stays read-only
    setenv("TOTK_SHARED_FONTS", "extracted/firmware/shared-fonts", 1);
    setenv("TOTK_GPU_ALLOW_SUBMIT", "1", 1);
    setenv("TOTK_GPU_WIDEN", "1", 1);
    setenv("TOTK_GPU_BLOCKRT", "1", 1);
    setenv("TOTK_GPU_MIDCLEAR", "1", 1);
    setenv("TOTK_GPU_BUDGET_MB", "5000", 1);
    setenv("TOTK_SLOT_OWNER", "user", 0);
    setenv("TOTK_SLOT_PURPOSE", "player", 0);
    unsetenv("TOTK_AUTOLOAD");   // the game starts at its title screen, as on the console

    if (mod.length) setenv("TOTK_ROMFS_PATCHES", mod.fileSystemRepresentation, 1);
    else unsetenv("TOTK_ROMFS_PATCHES");
    if (self.fpsCheck.state != NSControlStateValueOn) setenv("TOTK_FPS_OVERLAY", "0", 1); else unsetenv("TOTK_FPS_OVERLAY");
    if (self.shaderCheck.state != NSControlStateValueOn) setenv("TOTK_SHADER_OVERLAY", "0", 1); else unsetenv("TOTK_SHADER_OVERLAY");
    if (self.loadCheck.state != NSControlStateValueOn) setenv("TOTK_LOAD_OVERLAY", "0", 1); else unsetenv("TOTK_LOAD_OVERLAY");
    if (self.perfCheck.state == NSControlStateValueOn) setenv("TOTK_DRAWABLE_SCALE", "0.5", 1); else unsetenv("TOTK_DRAWABLE_SCALE");
    if (self.mfxCheck.state == NSControlStateValueOn) setenv("TOTK_MFX_OUTPUT", "0", 1); else unsetenv("TOTK_MFX_OUTPUT");
    setenv("TOTK_MFX_UPSCALE", self.mfxScaleCheck.state == NSControlStateValueOn ? "1" : "0", 1);
    if (self.skipWarmCheck.state == NSControlStateValueOn) setenv("DM_PSO_MANIFEST", "off", 1); else unsetenv("DM_PSO_MANIFEST");
    if (self.fullscreenCheck.state == NSControlStateValueOn) {
        setenv("TOTK_FULLSCREEN", "1", 1); unsetenv("TOTK_WINDOW_MAX");
    } else {
        unsetenv("TOTK_FULLSCREEN"); setenv("TOTK_WINDOW_MAX", "1", 1);
    }
    { NSString *o = [self trimmed:self.outputResField.stringValue ?: @""];
      if (o.length && strcasecmp(o.UTF8String, "auto") && strcmp(o.UTF8String, "0")) setenv("TOTK_OUTPUT_RES", o.UTF8String, 1);
      else unsetenv("TOTK_OUTPUT_RES"); }
    { NSString *w = [self trimmed:self.windowSizeField.stringValue ?: @""];
      if (w.length) setenv("TOTK_WINDOW_SIZE", w.UTF8String, 1); else unsetenv("TOTK_WINDOW_SIZE"); }
    { NSString *fill = @[@"fit", @"stretch", @"crop"][MAX(0, MIN(2, self.fillPopup.indexOfSelectedItem))];
      setenv("TOTK_PICTURE_FILL", fill.UTF8String, 1); }
    setenv("TOTK_GAMEPAD_SWAP_ABXY", self.swapCheck.state == NSControlStateValueOn ? "1" : "0", 1);
    if (self.rumbleCheck.state == NSControlStateValueOn) setenv("TOTK_RUMBLE", "1", 1); else unsetenv("TOTK_RUMBLE");
    if (self.gyroCheck.state == NSControlStateValueOn) setenv("TOTK_GYRO", "1", 1); else unsetenv("TOTK_GYRO");

    /* runtime command channel (runtime/input.c): echo "shot ~/Desktop/shot.png" >> "<data>/input.txt" */
    { NSString *cmds = [self.data stringByAppendingPathComponent:@"input.txt"];
      FILE *cf = fopen(cmds.fileSystemRepresentation, "w"); if (cf) fclose(cf);
      setenv("TOTK_INPUT_FILE", cmds.fileSystemRepresentation, 1); }

    NSString *log = [self.logs stringByAppendingPathComponent:@"totk.log"];
    [fm removeItemAtPath:[self.logs stringByAppendingPathComponent:@"totk.previous.log"] error:nil];
    [fm moveItemAtPath:log toPath:[self.logs stringByAppendingPathComponent:@"totk.previous.log"] error:nil];
    FILE *lf = fopen(log.fileSystemRepresentation, "w");
    if (lf) {
        dup2(fileno(lf), STDOUT_FILENO);
        dup2(fileno(lf), STDERR_FILENO);
        fclose(lf);
    }
    char *const arguments[] = {(char *)self.binary.fileSystemRepresentation, "rewritten/" TOTK_GAME_DIR, "boot", NULL};
    execv(arguments[0], arguments);
    fprintf(stderr, "[launcher] execv failed: %s\n", strerror(errno));
    show_error([NSString stringWithFormat:@"Starting the game failed. See %@.", log]);
}

- (void)quit:(id)sender {
    (void)sender;
    [NSApp terminate:nil];
}

@end

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *root = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"totk"];
        NSString *binary = [root stringByAppendingPathComponent:@"build/totk-native"];
        /* --check (build_app.py, once after packaging): only look that the game is there and exit. The first run of a new
           app is when macOS scans the whole bundle (minutes for 16 GB, with nothing on screen); doing it during the build
           makes the player's first start immediate. */
        if (argc > 1 && !strcmp(argv[1], "--check")) {
            int ok = access(binary.fileSystemRepresentation, X_OK) == 0;
            NSString *declared = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
            ok = ok && [declared isEqualToString:@TOTK_GAME_VERSION];
            printf("%s: game version %s\n", ok ? "ok" : "missing binary or version mismatch", TOTK_GAME_VERSION);
            return ok ? 0 : 1;
        }
        if (access(binary.fileSystemRepresentation, X_OK) != 0) {
            show_error(@"The game files are missing from this app. Build it again with build_app.py.");
            return 1;
        }
        NSString *home = NSHomeDirectory();
        NSString *data = [home stringByAppendingPathComponent:@"Library/Application Support/MacNativeGames/TOTK"];
        NSString *logs = [home stringByAppendingPathComponent:@"Library/Logs/MacNativeGames"];
        NSString *slot = env_string("TOTK_GAME_SLOT_DIR") ?: [data stringByAppendingPathComponent:@"game-slot"];
        NSString *cache = env_string("TOTK_SHADER_CACHE") ?: [data stringByAppendingPathComponent:[NSString stringWithFormat:@"shader-cache/rt-%s", DMSH_CHAIN]];
        NSString *defaultProfile = env_string("TOTK_PROFILE_DIR") ?: [data stringByAppendingPathComponent:@"profile"];
        if (!make_dir(data) || !make_dir(logs) || !make_dir(slot)) {
            show_error([NSString stringWithFormat:@"Cannot create %@.", data]);
            return 1;
        }
        pid_t running = running_game(slot);
        if (running) {
            [[NSRunningApplication runningApplicationWithProcessIdentifier:running] activateWithOptions:NSApplicationActivateAllWindows];
            return 0;
        }

        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        TOTKLauncher *launcher = [TOTKLauncher new];
        launcher.root = root;
        launcher.binary = binary;
        launcher.data = data;
        launcher.logs = logs;
        launcher.defaultProfile = defaultProfile;
        launcher.defaultSlot = slot;
        launcher.defaultCache = cache;
        launcher.settingsPath = [data stringByAppendingPathComponent:@"launcher-settings.json"];
        [launcher loadSettings];
        [launcher buildWindow];

        const char *autoenv = getenv("TOTK_LAUNCHER_AUTO");
        BOOL autoStart = (autoenv && *autoenv) || (argc > 1 && !strcmp(argv[1], "--play"));
        if (autoStart) {
            launcher.autoMode = YES;
            [launcher startGame:nil];
            return 0;
        }

        NSMenu *menu = [NSMenu new];
        NSMenuItem *appItem = [NSMenuItem new];
        [menu addItem:appItem];
        NSMenu *appMenu = [NSMenu new];
        [appMenu addItemWithTitle:@"退出游戏" action:@selector(terminate:) keyEquivalent:@"q"];
        appItem.submenu = appMenu;
        app.mainMenu = menu;
        [app activateIgnoringOtherApps:YES];
        [launcher.window makeKeyAndOrderFront:nil];
        [app run];
        return 0;
    }
}
