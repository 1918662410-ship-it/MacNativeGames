#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <AVFoundation/AVFoundation.h>
#import <GameController/GameController.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/utsname.h>

extern void runtime_ios_attach_layer(CAMetalLayer *layer, UIView *host);
extern int totk_loader_main(int argc, char **argv);
extern void runtime_input_key_synthetic(unsigned code, int down);
extern void runtime_input_clear(void);
extern void runtime_ios_set_display(int hz, double w, double h);

static UILabel *gDataLabel, *gControllerLabel;
static UIView *gRoot, *gLauncher, *gPad;
static UIButton *gStartButton;
static UITableView *gTable;
static BOOL gBusy, gHasData;
static BOOL gPickingMod, gCustomPad;
static NSString *gModPath;
static NSString *gCustomOutput;
static UIView *gPadEditOverlay;
static CGFloat gEditStartScale, gEditStartX, gEditStartY;
static BOOL gEditPad;
static NSMutableDictionary *gPadLayout;
static NSMutableDictionary<NSString *, NSString *> *gPadDefaultFrames;
static NSDictionary *gPadLayoutSnapshot;
static UIView *gPadHUD, *gPadEditorPanel;
static NSString *gEditItemKey;
static CGRect gEditItemFrame, gPanStart;
static CGFloat gEditItemAlpha;
static unsigned char gKeyState[128];

typedef struct {
    BOOL langEnglish;
    NSInteger fps;
    NSInteger outputIndex;
    NSInteger fillIndex;
    BOOL fpsOverlay, shaderOverlay, loadOverlay;
    BOOL performance, mfxUpscale, skipWarm;
    BOOL unlockFPS;
    BOOL virtualPad, swapABXY, rumble, gyro;
    BOOL flowPreset;
    CGFloat padScale, padOffsetX, padOffsetY;
} Settings;
static Settings gSet;
static Settings gFlowBackup;
static BOOL gFlowBackupValid;
static void *loader_thread(void *arg);

static const NSInteger kFps[] = {30, 40, 45, 50, 60, 70, 80, 90, 100, 120, 0};
static const char *kFpsTitle[] = {"30", "40", "45", "50", "60", "70", "80", "90", "100", "120", "不锁"};
static NSString *const kOutputs[] = {@"自动", @"1280x720", @"1600x900", @"1920x1080", @"2560x1440", @"自定义"};
static NSString *const kFills[] = {@"保持比例", @"拉伸铺满", @"裁剪铺满"};
static const char *kFillValues[] = {"fit", "stretch", "crop"};

@interface RuntimeView : UIView
@end
@implementation RuntimeView
+ (Class)layerClass { return [CAMetalLayer class]; }
@end

static NSString *documents_dir(void);
static NSString *bundle_data_dir(void) {
    NSString *p = [[NSBundle mainBundle] pathForResource:@"totk-data" ofType:nil];
    if (p && [[NSFileManager defaultManager] fileExistsAtPath:[p stringByAppendingPathComponent:@"romfs/romfs.bin"]]) return p;
    return nil;
}
static NSString *romfs_index_path(void) {
    NSString *b = bundle_data_dir();
    if (b) return [b stringByAppendingPathComponent:@"romfs/runtime-index.bin"];
    return [documents_dir() stringByAppendingPathComponent:@"extracted/v143/romfs/runtime-index.bin"];
}
static NSString *documents_dir(void) {
    NSArray<NSString *> *d = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return d.count ? d[0] : NSTemporaryDirectory();
}
static void ensure_dir(NSString *path) {
    [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
}
static void set_path(const char *name, NSString *path) { setenv(name, path.UTF8String, 1); }

static void load_settings(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    gSet.langEnglish = [d boolForKey:@"ui_lang_en"];
    gSet.fps = [d objectForKey:@"ui_fps"] ? [d integerForKey:@"ui_fps"] : 30;
    gSet.outputIndex = [d objectForKey:@"ui_output"] ? [d integerForKey:@"ui_output"] : 0;
    gSet.fillIndex = [d objectForKey:@"ui_fill"] ? [d integerForKey:@"ui_fill"] : 0;
    gSet.fpsOverlay = [d objectForKey:@"ui_fps_overlay"] ? [d boolForKey:@"ui_fps_overlay"] : YES;
    gSet.shaderOverlay = [d objectForKey:@"ui_shader_overlay"] ? [d boolForKey:@"ui_shader_overlay"] : YES;
    gSet.loadOverlay = [d objectForKey:@"ui_load_overlay"] ? [d boolForKey:@"ui_load_overlay"] : YES;
    gSet.performance = [d boolForKey:@"ui_performance"];
    gSet.mfxUpscale = [d boolForKey:@"ui_mfx_upscale"];
    gSet.skipWarm = [d objectForKey:@"ui_skip_warm"] ? [d boolForKey:@"ui_skip_warm"] : YES;
    gSet.unlockFPS = [d boolForKey:@"ui_unlock_fps"];
    gSet.virtualPad = [d objectForKey:@"ui_virtual_pad"] ? [d boolForKey:@"ui_virtual_pad"] : YES;
    gSet.swapABXY = [d boolForKey:@"ui_swap_abxy"];
    gSet.rumble = [d boolForKey:@"ui_rumble"];
    gSet.gyro = [d boolForKey:@"ui_gyro"];
    gSet.flowPreset = [d boolForKey:@"ui_flow_preset"];
    if (![d boolForKey:@"ui_stablefix_v38"]) {
        gSet.fps = 30; gSet.performance = YES; gSet.outputIndex = 1;
        gSet.fpsOverlay = NO; gSet.shaderOverlay = NO; gSet.loadOverlay = NO;
        gSet.mfxUpscale = NO; gSet.unlockFPS = NO; gSet.flowPreset = YES;
        [d setBool:YES forKey:@"ui_stablefix_v38"];
        [d setInteger:30 forKey:@"ui_fps"];
        [d setBool:YES forKey:@"ui_perf"];
        [d setInteger:1 forKey:@"ui_output"];
        [d setBool:NO forKey:@"ui_fps_overlay"];
        [d setBool:NO forKey:@"ui_shader_overlay"];
        [d setBool:NO forKey:@"ui_load_overlay"];
        [d setBool:NO forKey:@"ui_mfx_scale"];
        [d setBool:NO forKey:@"ui_unlock_fps"];
        [d setBool:YES forKey:@"ui_flow_preset"];
    }
    gSet.padScale = [d objectForKey:@"ui_pad_scale"] ? [d doubleForKey:@"ui_pad_scale"] : 1.0;
    gSet.padOffsetX = [d objectForKey:@"ui_pad_x"] ? [d doubleForKey:@"ui_pad_x"] : 0.0;
    gSet.padOffsetY = [d objectForKey:@"ui_pad_y"] ? [d doubleForKey:@"ui_pad_y"] : 0.0;
    gCustomOutput = [d stringForKey:@"ui_custom_output"];
    gModPath = [d stringForKey:@"ui_mod_path"];
    gPadLayout = [NSMutableDictionary dictionaryWithDictionary:([d dictionaryForKey:@"ui_pad_layout"] ?: @{})];
    if (gModPath.length && ![[NSFileManager defaultManager] fileExistsAtPath:gModPath]) gModPath = nil;
}
static void save_settings(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setBool:gSet.langEnglish forKey:@"ui_lang_en"];
    [d setInteger:gSet.fps forKey:@"ui_fps"];
    [d setInteger:gSet.outputIndex forKey:@"ui_output"];
    [d setInteger:gSet.fillIndex forKey:@"ui_fill"];
    [d setBool:gSet.fpsOverlay forKey:@"ui_fps_overlay"];
    [d setBool:gSet.shaderOverlay forKey:@"ui_shader_overlay"];
    [d setBool:gSet.loadOverlay forKey:@"ui_load_overlay"];
    [d setBool:gSet.performance forKey:@"ui_performance"];
    [d setBool:gSet.mfxUpscale forKey:@"ui_mfx_upscale"];
    [d setBool:gSet.skipWarm forKey:@"ui_skip_warm"];
    [d setBool:gSet.unlockFPS forKey:@"ui_unlock_fps"];
    [d setBool:gSet.virtualPad forKey:@"ui_virtual_pad"];
    [d setBool:gSet.swapABXY forKey:@"ui_swap_abxy"];
    [d setBool:gSet.rumble forKey:@"ui_rumble"];
    [d setBool:gSet.gyro forKey:@"ui_gyro"];
    [d setBool:gSet.flowPreset forKey:@"ui_flow_preset"];
    [d setDouble:gSet.padScale forKey:@"ui_pad_scale"];
    [d setDouble:gSet.padOffsetX forKey:@"ui_pad_x"];
    [d setDouble:gSet.padOffsetY forKey:@"ui_pad_y"];
    if (gCustomOutput.length) [d setObject:gCustomOutput forKey:@"ui_custom_output"]; else [d removeObjectForKey:@"ui_custom_output"];
    if (gModPath.length) [d setObject:gModPath forKey:@"ui_mod_path"]; else [d removeObjectForKey:@"ui_mod_path"];
    [d setObject:gPadLayout ?: @{} forKey:@"ui_pad_layout"];
    [d synchronize];
}
static NSInteger pending_shader_count(void) {
    NSString *docs = documents_dir();
    NSString *reqDir = [docs stringByAppendingPathComponent:@"shader-requests"];
    NSString *cache = [docs stringByAppendingPathComponent:@"shader-cache"];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:reqDir error:nil];
    NSInteger n = 0;
    for (NSString *f in files) {
        if (![f hasSuffix:@".json"]) continue;
        NSString *v = [f stringByDeletingPathExtension];
        NSString *metal = [cache stringByAppendingPathComponent:[v stringByAppendingString:@"_b.metal"]];
        if (![[NSFileManager defaultManager] fileExistsAtPath:metal]) n++;
    }
    return n;
}
static NSString *output_title(void) {
    if (gSet.outputIndex == 5) return gCustomOutput.length ? gCustomOutput : @"自定义";
    return kOutputs[gSet.outputIndex];
}
static NSString *fps_title(NSInteger fps) {
    if (fps > 60) return [NSString stringWithFormat:@"%ld（需高帧率）", (long)fps];
    for (int i = 0; i < 11; i++) if (kFps[i] == fps) return [NSString stringWithUTF8String:kFpsTitle[i]];
    return @"不锁";
}
static NSInteger output_height(void) {
    NSInteger h = 720;
    switch (gSet.outputIndex) {
        case 0: h = 720; break;
        case 1: h = 720; break;
        case 2: h = 900; break;
        case 3: h = 1080; break;
        case 4: h = 1440; break;
        case 5: {
            NSArray *a = [gCustomOutput.lowercaseString componentsSeparatedByString:@"x"];
            h = a.count == 2 ? [a[1] integerValue] : 720;
            break;
        }
    }
    if (h < 360) h = 360; if (h > 2160) h = 2160;
    return h;
}
static NSInteger present_hz(void) {
    if (gSet.fps > 60 && gSet.unlockFPS) return gSet.fps;
    NSInteger f = gSet.fps > 0 ? gSet.fps : 60;
    return MIN(f, 60);
}
static NSInteger fps_limit_hz(void) {
    if (gSet.fps > 60 && gSet.unlockFPS) return gSet.fps;
    NSInteger f = gSet.fps > 0 ? gSet.fps : 60;
    return MIN(f, 60);
}
static void apply_display_env(void) {
    if (gSet.fps <= 60) gSet.unlockFPS = NO;
    NSInteger oh = output_height();
    setenv("TOTK_IOS_DRAWABLE_H", [NSString stringWithFormat:@"%ld", (long)oh].UTF8String, 1);
    setenv("TOTK_OPERATION_MODE", "handheld", 1);
    NSInteger ph = present_hz();
    BOOL high = gSet.fps > 60 && gSet.unlockFPS;
    setenv("TOTK_PRESENT_HZ", [NSString stringWithFormat:@"%ld", (long)ph].UTF8String, 1);
    if (high) { setenv("DM_PRESENT_LINK", "0", 1); setenv("TOTK_UNCAPPED", "1", 1); }
    else { setenv("DM_PRESENT_LINK", "0", 1); setenv("TOTK_UNCAPPED", "0", 1); }
    setenv("TOTK_REUP_RECYCLE", "0", 1);
    setenv("TOTK_TEX_EVICT", "0", 1);
}

static NSString *device_name(void) {
    struct utsname u; if (uname(&u) != 0) return @"iPhone";
    NSString *m = @(u.machine);
    if ([m isEqualToString:@"iPhone17,1"]) return @"iPhone 16 Pro";
    if ([m isEqualToString:@"iPhone17,2"]) return @"iPhone 16 Pro Max";
    if ([m isEqualToString:@"iPhone16,1"]) return @"iPhone 15 Pro";
    if ([m isEqualToString:@"iPhone16,2"]) return @"iPhone 15 Pro Max";
    if ([m isEqualToString:@"iPad13,6"]) return @"iPad Pro 11 (M1)";
    return m;
}

static void configure_environment(void) {
    NSString *docs = documents_dir();
    NSString *bd = bundle_data_dir();
    ensure_dir([docs stringByAppendingPathComponent:@"profile"]);
    ensure_dir([docs stringByAppendingPathComponent:@"game-slot"]);
    NSString *romfs = bd ? [bd stringByAppendingPathComponent:@"romfs"] : [docs stringByAppendingPathComponent:@"extracted/v143/romfs"];
    NSString *fonts = bd ? [bd stringByAppendingPathComponent:@"shared-fonts"] : [docs stringByAppendingPathComponent:@"shared-fonts"];
    NSString *shaders = bd ? [bd stringByAppendingPathComponent:@"shader-cache"] : [docs stringByAppendingPathComponent:@"shader-cache"];
    if (!bd) { ensure_dir(romfs); ensure_dir(fonts); ensure_dir(shaders); }
    set_path("TOTK_ROMFS", romfs);
    set_path("TOTK_ROMFS_PROOF_DIR", docs);
    set_path("TOTK_PROFILE_DIR", [docs stringByAppendingPathComponent:@"profile"]);
    set_path("TOTK_GAME_SLOT_DIR", [docs stringByAppendingPathComponent:@"game-slot"]);
    set_path("TOTK_SHARED_FONTS", fonts);
    set_path("TOTK_SHADER_CACHE", shaders);
    if (gModPath.length) setenv("TOTK_ROMFS_PATCHES", gModPath.UTF8String, 1); else setenv("TOTK_ROMFS_PATCHES", "0", 1);
    setenv("TOTK_GPU_ALLOW_SUBMIT", "1", 1);
    setenv("TOTK_ASYNC_REPLAY", "1", 1);
    setenv("TOTK_REALTIME", "1", 1);
    setenv("TOTK_ALIAS_GIB", "3", 1);
    setenv("TOTK_SLOT_OWNER", "user", 1);
    setenv("TOTK_SLOT_PURPOSE", "player", 1);
    setenv("TOTK_WARM_LIGHT", "0", 1);
    setenv("DM_PSO_MANIFEST", "off", 1);
    setenv("TOTK_GPU_BLOCKRT", "1", 1);
    setenv("TOTK_GPU_MIDCLEAR", "1", 1);
    setenv("TOTK_MIP_DROP", "1", 1);
    setenv("TOTK_GPU_KEEPALIVE", "0", 1);
    setenv("TOTK_GPU_BUDGET_MB", "3072", 1);
    setenv("TOTK_REUP_RECYCLE", "0", 1);
    setenv("TOTK_TEX_EVICT", "0", 1);
    apply_display_env();
    fprintf(stderr, "[TOTK] docs=%s\n", docs.UTF8String);
    fprintf(stderr, "[TOTK] output_h=%ld present_hz=%ld operation=%s\n", (long)output_height(), (long)present_hz(), output_height() >= 1080 ? "docked" : "handheld");
}
static void apply_environment(void) {
    NSString *lang = gSet.langEnglish ? @"en-US" : @"zh-Hans";
    setenv("TOTK_LANG", lang.UTF8String, 1);
    setenv("TOTK_FPS60", gSet.fps == 30 ? "0" : "1", 1);
    setenv("TOTK_FPS_LIMIT", [NSString stringWithFormat:@"%ld", (long)fps_limit_hz()].UTF8String, 1);
    if (gSet.outputIndex == 5 && gCustomOutput.length) setenv("TOTK_OUTPUT_RES", gCustomOutput.UTF8String, 1);
    else if (gSet.outputIndex > 0 && gSet.outputIndex < 5) setenv("TOTK_OUTPUT_RES", kOutputs[gSet.outputIndex].UTF8String, 1);
    else unsetenv("TOTK_OUTPUT_RES");
    apply_display_env();
    setenv("TOTK_PICTURE_FILL", kFillValues[gSet.fillIndex], 1);
    if (gSet.performance) setenv("TOTK_DRAWABLE_SCALE", "0.5", 1); else unsetenv("TOTK_DRAWABLE_SCALE");
    setenv("TOTK_MFX_UPSCALE", gSet.mfxUpscale ? "1" : "0", 1);
    if (!gSet.fpsOverlay) setenv("TOTK_FPS_OVERLAY", "0", 1); else unsetenv("TOTK_FPS_OVERLAY");
    if (!gSet.shaderOverlay) setenv("TOTK_SHADER_OVERLAY", "0", 1); else unsetenv("TOTK_SHADER_OVERLAY");
    if (!gSet.loadOverlay) setenv("TOTK_LOAD_OVERLAY", "0", 1); else unsetenv("TOTK_LOAD_OVERLAY");
    if (gModPath.length) setenv("TOTK_ROMFS_PATCHES", gModPath.UTF8String, 1); else setenv("TOTK_ROMFS_PATCHES", "0", 1);
    setenv("TOTK_GAMEPAD_SWAP_ABXY", gSet.swapABXY ? "1" : "0", 1);
    if (gSet.rumble) setenv("TOTK_RUMBLE", "1", 1); else unsetenv("TOTK_RUMBLE");
    if (gSet.gyro) setenv("TOTK_GYRO", "1", 1); else unsetenv("TOTK_GYRO");
    setenv("DM_PSO_MANIFEST", "off", 1);
    fprintf(stderr, "[TOTK] lang=%s fps=%ld output=%s fill=%s perf=%d mfx=%d\n",
            lang.UTF8String, (long)gSet.fps, kOutputs[gSet.outputIndex].UTF8String,
            kFillValues[gSet.fillIndex], gSet.performance ? 1 : 0, gSet.mfxUpscale ? 1 : 0);
}

static void configure_audio_session(void) {
    NSError *e = nil;
    AVAudioSession *s = [AVAudioSession sharedInstance];
    [s setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:&e];
    [s setActive:YES error:&e];
    fprintf(stderr, "[TOTK] audio session: %s\n", e ? e.localizedDescription.UTF8String : "active");
}

static void set_key(unsigned code, int down) {
    if (code >= 128 || gKeyState[code] == (down ? 1 : 0)) return;
    gKeyState[code] = down ? 1 : 0;
    runtime_input_key_synthetic(code, down ? 1 : 0);
}
static void release_all_keys(void) { for (unsigned i = 0; i < 128; i++) if (gKeyState[i]) set_key(i, 0); }
static unsigned swap_button(unsigned code) {
    if (!gSet.swapABXY) return code;
    if (code == 38) return 40; if (code == 40) return 38;
    if (code == 34) return 32; if (code == 32) return 34;
    return code;
}
static void stick_axes(BOOL right, CGFloat nx, CGFloat ny) {
    const CGFloat dz = 0.22;
    if (right) { set_key(123, nx < -dz); set_key(124, nx > dz); set_key(125, ny > dz); set_key(126, ny < -dz); }
    else { set_key(0, nx < -dz); set_key(2, nx > dz); set_key(1, ny > dz); set_key(13, ny < -dz); }
}

@interface StickView : UIView
@property (nonatomic) BOOL rightStick;
@property (nonatomic, strong) UIView *knob;
@end
@implementation StickView
- (instancetype)initWithFrame:(CGRect)frame right:(BOOL)right {
    self = [super initWithFrame:frame];
    if (self) {
        _rightStick = right;
        self.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
        self.layer.cornerRadius = frame.size.width / 2;
        self.layer.borderWidth = 1.5;
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.32].CGColor;
        self.clipsToBounds = YES; self.multipleTouchEnabled = YES;
        CGFloat k = frame.size.width * 0.38;
        _knob = [[UIView alloc] initWithFrame:CGRectMake((frame.size.width-k)/2, (frame.size.height-k)/2, k, k)];
        _knob.backgroundColor = [UIColor colorWithWhite:1 alpha:0.30];
        _knob.layer.cornerRadius = k/2;
        _knob.userInteractionEnabled = NO;
        [self addSubview:_knob];
    }
    return self;
}
- (void)touch:(NSSet<UITouch *> *)touches {
    UITouch *t = touches.anyObject; if (!t) return;
    CGPoint p = [t locationInView:self];
    CGFloat cx = self.bounds.size.width/2, cy = self.bounds.size.height/2;
    CGFloat nx = MAX(-1, MIN(1, (p.x-cx)/cx)), ny = MAX(-1, MIN(1, (p.y-cy)/cy));
    stick_axes(_rightStick, nx, ny);
    CGFloat r = self.bounds.size.width * 0.30;
    _knob.center = CGPointMake(cx + nx*r, cy + ny*r);
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { if (!gEditPad) [self touch:touches]; }
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { if (!gEditPad) [self touch:touches]; }
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (gEditPad) return;
    stick_axes(_rightStick, 0, 0);
    _knob.center = CGPointMake(self.bounds.size.width/2, self.bounds.size.height/2);
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self touchesEnded:touches withEvent:event]; }
@end

static void set_status(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{ if (gDataLabel) gDataLabel.text = text; });
}

@interface Launcher : UIViewController <UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation Launcher
- (void)viewDidLoad {
    [super viewDidLoad];
    load_settings();
    configure_audio_session();
    configure_environment();

    CGRect r = self.view.bounds;
    CGFloat w = r.size.width, h = r.size.height;
    self.view.backgroundColor = [UIColor colorWithWhite:0.045 alpha:1];
    gRoot = [[RuntimeView alloc] initWithFrame:r];
    gRoot.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    gRoot.backgroundColor = UIColor.blackColor;
    [self.view addSubview:gRoot];

    CAMetalLayer *layer = (CAMetalLayer *)gRoot.layer;
    layer.device = MTLCreateSystemDefaultDevice();
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = NO;

    gLauncher = [[UIView alloc] initWithFrame:r];
    gLauncher.backgroundColor = [UIColor colorWithWhite:0.045 alpha:1];
    [self.view addSubview:gLauncher];

    CGFloat lw = MIN(300, w * 0.36);
    UIImage *icon = nil;
    NSString *iconPath = [[NSBundle mainBundle] pathForResource:@"AppIcon" ofType:@"png"];
    if (iconPath) icon = [UIImage imageWithContentsOfFile:iconPath];
    UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake((lw-68)/2, 14, 68, 68)];
    iv.image = icon; iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.layer.cornerRadius = 15; iv.clipsToBounds = YES;
    [gLauncher addSubview:iv];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 88, lw - 24, 40)];
    title.text = @"Tears of the Kingdom"; title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:18]; title.numberOfLines = 2;
    title.textAlignment = NSTextAlignmentCenter;
    [gLauncher addSubview:title];
    UILabel *ver = [[UILabel alloc] initWithFrame:CGRectMake(12, 128, lw - 24, 18)];
    ver.text = @"iOS · v3.10.0"; ver.textColor = [UIColor colorWithWhite:0.65 alpha:1];
    ver.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    ver.textAlignment = NSTextAlignmentCenter;
    [gLauncher addSubview:ver];

    gDataLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 152, lw - 32, 130)];
    gDataLabel.numberOfLines = 0; gDataLabel.textColor = UIColor.whiteColor;
    gDataLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightMedium];
    gDataLabel.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.8];
    gDataLabel.layer.cornerRadius = 9; gDataLabel.clipsToBounds = YES;
    [gLauncher addSubview:gDataLabel];

    gStartButton = [UIButton buttonWithType:UIButtonTypeSystem];
    gStartButton.frame = CGRectMake(24, h - 112, lw - 48, 52);
    gStartButton.backgroundColor = [UIColor colorWithRed:0.09 green:0.55 blue:0.31 alpha:1];
    gStartButton.layer.cornerRadius = 12;
    gStartButton.titleLabel.font = [UIFont boldSystemFontOfSize:19];
    [gStartButton setTitle:@"开始游戏" forState:UIControlStateNormal];
    [gStartButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [gStartButton addTarget:self action:@selector(startTapped:) forControlEvents:UIControlEventTouchUpInside];
    [gLauncher addSubview:gStartButton];

    UIButton *reset = [UIButton buttonWithType:UIButtonTypeSystem];
    reset.frame = CGRectMake(24, h - 52, lw - 48, 32);
    [reset setTitle:@"恢复默认设置" forState:UIControlStateNormal];
    [reset setTitleColor:[UIColor colorWithWhite:0.7 alpha:1] forState:UIControlStateNormal];
    [reset addTarget:self action:@selector(resetTapped:) forControlEvents:UIControlEventTouchUpInside];
    [gLauncher addSubview:reset];

    gTable = [[UITableView alloc] initWithFrame:CGRectMake(lw + 12, 12, w - lw - 24, h - 24) style:UITableViewStyleInsetGrouped];
    gTable.dataSource = self; gTable.delegate = self;
    gTable.backgroundColor = UIColor.clearColor;
    gTable.separatorColor = [UIColor colorWithWhite:0.25 alpha:1];
    gTable.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [gLauncher addSubview:gTable];

    gPad = [[UIView alloc] initWithFrame:r];
    gPad.backgroundColor = UIColor.clearColor;
    gPad.hidden = YES;
    [self.view addSubview:gPad];
    [self buildPad:r];

    NSString *index = romfs_index_path();
    gHasData = [[NSFileManager defaultManager] fileExistsAtPath:index];
    gStartButton.enabled = gHasData;
    gStartButton.alpha = gHasData ? 1 : 0.45;

    [self refreshDataLabel];
    [self refreshControllerLabel];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(controllerChanged:) name:GCControllerDidConnectNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(controllerChanged:) name:GCControllerDidDisconnectNotification object:nil];

    runtime_ios_attach_layer(layer, gRoot);
    [self.view bringSubviewToFront:gLauncher];
}

- (void)refreshDataLabel {
    NSString *docs = documents_dir();
    NSString *data = gHasData ? (bundle_data_dir() ? @"RomFS 16 GB · 内置" : @"RomFS 16 GB") : @"Game data: MISSING";
    gDataLabel.text = [NSString stringWithFormat:
        @"%@\niOS %@\nGame 1.4.3 · App 2.3.0\n%@",
        device_name(), [UIDevice currentDevice].systemVersion, data];
}
- (void)refreshControllerLabel {
    NSArray *pads = GCController.controllers;
    if (!pads.count) gControllerLabel = nil;
    if (gTable) [gTable reloadData];
}
- (void)controllerChanged:(NSNotification *)n { (void)n; [self refreshControllerLabel]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { (void)tv; return 5; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    (void)tv; return @[@"画面", @"性能", @"操作", @"存档", @"Mod"][s];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    (void)tv; return s == 0 ? 3 : s == 1 ? 8 : s == 2 ? 6 : s == 3 ? 2 : 3;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"cell"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"cell"];
    c.backgroundColor = [UIColor colorWithWhite:0.09 alpha:1];
    c.textLabel.textColor = UIColor.whiteColor;
    c.detailTextLabel.textColor = [UIColor colorWithWhite:0.75 alpha:1];
    c.accessoryView = nil; c.accessoryType = UITableViewCellAccessoryNone; c.selectionStyle = UITableViewCellSelectionStyleDefault;
    c.detailTextLabel.text = nil;

    NSInteger s = ip.section, r = ip.row;
    if (s == 0) {
        if (r == 0) { c.textLabel.text = @"语言"; c.detailTextLabel.text = gSet.langEnglish ? @"English" : @"中文"; c.accessoryType = UITableViewCellAccessoryDisclosureIndicator; }
        else if (r == 1) { c.textLabel.text = @"输出分辨率"; c.detailTextLabel.text = output_title(); c.accessoryType = UITableViewCellAccessoryDisclosureIndicator; }
        else { c.textLabel.text = @"填充方式"; c.detailTextLabel.text = kFills[gSet.fillIndex]; c.accessoryType = UITableViewCellAccessoryDisclosureIndicator; }
    } else if (s == 1) {
        if (r == 0) { c.textLabel.text = @"锁帧上限"; c.detailTextLabel.text = fps_title(gSet.fps); c.accessoryType = UITableViewCellAccessoryDisclosureIndicator; }
        else {
            UISwitch *sw = [UISwitch new];
            sw.tag = s * 100 + r;
            BOOL on = NO; NSString *t = nil;
            switch (r) {
                case 1: t = @"FPS 浮层（右上）"; on = gSet.fpsOverlay; break;
                case 2: t = @"着色器浮层（左下）"; on = gSet.shaderOverlay; break;
                case 3: t = @"系统负载浮层（右下）"; on = gSet.loadOverlay; break;
                case 4: t = @"性能模式：0.5x 画布"; on = gSet.performance; break;
                case 5: t = @"MetalFX 空间超分"; on = gSet.mfxUpscale; break;
                case 6: t = @"高帧率模式（60+ 实验）"; on = gSet.unlockFPS; break;
                case 7: t = @"流畅优先预设"; on = gSet.flowPreset; break;
            }
            c.textLabel.text = t; sw.on = on; c.accessoryView = sw;
            if (r == 7) c.detailTextLabel.text = @"30 FPS · 0.5x · 720p";
            [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        }
    } else if (s == 2) {
        if (r == 0 || r == 2 || r == 3 || r == 4) {
            UISwitch *sw = [UISwitch new]; sw.tag = s * 100 + r;
            BOOL on = NO; NSString *t = nil;
            switch (r) {
                case 0: t = @"屏幕虚拟手柄"; on = gSet.virtualPad; break;
                case 2: t = @"交换 X/Y、A/B"; on = gSet.swapABXY; break;
                case 3: t = @"HD 震动"; on = gSet.rumble; break;
                case 4: t = @"六轴体感"; on = gSet.gyro; break;
            }
            c.textLabel.text = t; sw.on = on; c.accessoryView = sw;
            [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        } else if (r == 1) {
            c.textLabel.text = @"自定义虚拟手柄";
            c.detailTextLabel.text = @"进游戏拖动/缩放";
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            NSArray *pads = GCController.controllers;
            c.textLabel.text = @"实体手柄";
            c.detailTextLabel.text = pads.count ? [NSString stringWithFormat:@"已连接 %lu 个", (unsigned long)pads.count] : @"未连接";
        }
    } else if (s == 3) {
        if (r == 0) { c.textLabel.text = @"Profile 文件夹"; c.detailTextLabel.text = @"打开"; c.accessoryType = UITableViewCellAccessoryDisclosureIndicator; }
        else if (r == 1) { c.textLabel.text = @"备份存档"; c.detailTextLabel.text = @"复制到 backups"; c.accessoryType = UITableViewCellAccessoryDisclosureIndicator; }
    } else {
        if (r == 0) { c.textLabel.text = @"添加 / 更换 Mod"; c.detailTextLabel.text = gModPath.length ? [gModPath lastPathComponent] : @"未添加"; c.accessoryType = UITableViewCellAccessoryDisclosureIndicator; }
        else if (r == 1) { c.textLabel.text = @"清除 Mod"; c.detailTextLabel.text = gModPath.length ? @"恢复原版" : @"当前无 Mod"; c.accessoryType = UITableViewCellAccessoryDisclosureIndicator; }
        else { c.textLabel.text = @"Mod 格式"; c.detailTextLabel.text = @"含 manifest.tsv 的文件夹"; }
    }
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSInteger s = ip.section, r = ip.row;
    if (s == 0 && r == 0) [self choose:@[@"中文", @"English"] selected:gSet.langEnglish handler:^(NSInteger i) { gSet.langEnglish = i == 1; save_settings(); [tv reloadData]; }];
    if (s == 0 && r == 1) {
        NSArray *arr = [NSArray arrayWithObjects:kOutputs count:6];
        [self choose:arr selected:gSet.outputIndex handler:^(NSInteger i) {
            if (i == 5) { [self promptCustomOutput]; return; }
            gSet.outputIndex = i; save_settings(); [tv reloadData];
        }];
    }
    if (s == 0 && r == 2) {
        NSArray *arr = [NSArray arrayWithObjects:kFills count:3];
        [self choose:arr selected:gSet.fillIndex handler:^(NSInteger i) { gSet.fillIndex = i; save_settings(); [tv reloadData]; }];
    }
    if (s == 1 && r == 0) {
        NSMutableArray *titles = [NSMutableArray array];
        for (int i = 0; i < 11; i++) [titles addObject:[NSString stringWithUTF8String:kFpsTitle[i]]];
        NSInteger cur = 10; for (int i = 0; i < 11; i++) if (kFps[i] == gSet.fps) cur = i;
        [self choose:titles selected:cur handler:^(NSInteger i) {
            gSet.fps = kFps[i];
            if (gSet.fps <= 60) gSet.unlockFPS = NO;
            save_settings(); [tv reloadData];
        }];
    }
    if (s == 2 && r == 1) { gSet.virtualPad = YES; gCustomPad = YES; [self startTapped:nil]; }
    if (s == 3 && r == 0) [self openProfileFolder];
    if (s == 3 && r == 1) [self backupProfile];
    if (s == 4 && r == 0) [self pickModFolder];
    if (s == 4 && r == 1) [self clearMod];
}

- (NSString *)padRowTitle:(NSInteger)r {
    if (r == 1) return [NSString stringWithFormat:@"手柄大小 %ld%%", (long)lround(gSet.padScale * 100)];
    if (r == 2) return [NSString stringWithFormat:@"水平位置 %+.0f%%", gSet.padOffsetX * 100];
    return [NSString stringWithFormat:@"垂直位置 %+.0f%%", gSet.padOffsetY * 100];
}
- (void)sliderChanged:(UISlider *)sl {
    NSInteger s = sl.tag / 100, r = sl.tag % 100;
    if (r == 1) gSet.padScale = sl.value;
    else if (r == 2) gSet.padOffsetX = sl.value;
    else if (r == 3) gSet.padOffsetY = sl.value;
    save_settings();
    UITableViewCell *cell = [gTable cellForRowAtIndexPath:[NSIndexPath indexPathForRow:r inSection:s]];
    if (cell) cell.textLabel.text = [self padRowTitle:r];
}
- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    (void)tv;
    return 48;
}
- (void)openProfileFolder {
    gPickingMod = NO;
    NSString *profile = [documents_dir() stringByAppendingPathComponent:@"profile"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:profile]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:profile withIntermediateDirectories:YES attributes:nil error:nil];
    }
    UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
    p.directoryURL = [NSURL fileURLWithPath:profile isDirectory:YES];
    p.delegate = self;
    p.allowsMultipleSelection = NO;
    [self presentViewController:p animated:YES completion:nil];
}
- (void)choose:(NSArray *)titles selected:(NSInteger)sel handler:(void (^)(NSInteger))handler {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
        [ac addAction:[UIAlertAction actionWithTitle:titles[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { (void)a; handler(i); }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *pc = ac.popoverPresentationController;
    if (pc) { pc.sourceView = self.view; pc.sourceRect = CGRectMake(self.view.bounds.size.width/2, self.view.bounds.size.height/2, 1, 1); }
    [self presentViewController:ac animated:YES completion:nil];
}
- (void)switchChanged:(UISwitch *)sw {
    NSInteger s = sw.tag / 100, r = sw.tag % 100;
    if (s == 1) {
        if (r == 1) gSet.fpsOverlay = sw.on; else if (r == 2) gSet.shaderOverlay = sw.on;
        else if (r == 3) gSet.loadOverlay = sw.on; else if (r == 4) gSet.performance = sw.on;
        else if (r == 5) gSet.mfxUpscale = sw.on;
        else if (r == 6) gSet.unlockFPS = sw.on;
        else if (r == 7) {
            if (sw.on) {
                if (!gSet.flowPreset) { gFlowBackup = gSet; gFlowBackupValid = YES; }
                gSet.flowPreset = YES;
                gSet.fps = 30; gSet.performance = YES; gSet.outputIndex = 1;
                gSet.fpsOverlay = NO; gSet.shaderOverlay = NO; gSet.loadOverlay = NO;
                gSet.mfxUpscale = NO; gSet.unlockFPS = NO;
            } else {
                gSet.flowPreset = NO;
                if (gFlowBackupValid) { gSet = gFlowBackup; gSet.flowPreset = NO; gFlowBackupValid = NO; }
                else {
                    gSet.fps = 30; gSet.performance = NO; gSet.outputIndex = 0;
                    gSet.fpsOverlay = YES; gSet.shaderOverlay = YES; gSet.loadOverlay = YES;
                    gSet.mfxUpscale = NO; gSet.unlockFPS = NO;
                }
            }
            save_settings(); [gTable reloadData]; return;
        }
    } else if (s == 2) {
        if (r == 0) gSet.virtualPad = sw.on; else if (r == 2) gSet.swapABXY = sw.on;
        else if (r == 3) gSet.rumble = sw.on; else if (r == 4) gSet.gyro = sw.on;
    }
    save_settings();
}
- (void)promptCustomOutput {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"自定义分辨率" message:@"输入 WxH，例如 1920x1080" preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"1920x1080";
        tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        tf.text = gCustomOutput.length ? gCustomOutput : @"1920x1080";
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a;
        NSString *t = [ac.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^[0-9]{3,4}x[0-9]{3,4}$" options:0 error:nil];
        if (!t.length || ![re firstMatchInString:t options:0 range:NSMakeRange(0, t.length)]) {
            [self promptCustomOutput]; return;
        }
        gCustomOutput = t; gSet.outputIndex = 5; save_settings(); [gTable reloadData];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}
- (void)backupProfile {
    NSString *docs = documents_dir();
    NSString *src = [docs stringByAppendingPathComponent:@"profile"];
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *dst = [[docs stringByAppendingPathComponent:@"backups"] stringByAppendingPathComponent:[NSString stringWithFormat:@"profile-%@", [df stringFromDate:[NSDate date]]]];
    NSError *e = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:[docs stringByAppendingPathComponent:@"backups"] withIntermediateDirectories:YES attributes:nil error:nil];
    BOOL ok = [[NSFileManager defaultManager] copyItemAtPath:src toPath:dst error:&e];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:ok ? @"存档已备份" : @"备份失败" message:ok ? dst : e.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}
- (void)resetTapped:(id)sender {
    (void)sender;
    gSet = (Settings){ .fps = 30, .skipWarm = YES, .virtualPad = YES, .fpsOverlay = YES, .shaderOverlay = YES, .loadOverlay = YES, .padScale = 1.0 };
    gFlowBackupValid = NO;
    save_settings(); [gTable reloadData];
}
- (void)applyDisplayToLayer {
    NSInteger oh = output_height();
    CGFloat scale = self.view.window.screen.nativeScale > 0 ? self.view.window.screen.nativeScale : UIScreen.mainScreen.nativeScale;
    double vw = round(self.view.bounds.size.width * scale), vh = round(self.view.bounds.size.height * scale);
    if (oh > 0) {
        double h = vw / vh < 16.0 / 9.0 ? round(oh * 16.0 / 9.0 * vh / vw) : (double)oh;
        if (h < vh) { vw = round(vw * h / vh); vh = h; }
    }
    runtime_ios_set_display((int)present_hz(), vw, vh);
}
- (void)startTapped:(id)sender {
    (void)sender;
    if (gBusy || !gHasData) { gCustomPad = NO; return; }
    if (gSet.fps <= 60) gSet.unlockFPS = NO;
    BOOL custom = gCustomPad; gCustomPad = NO;
    gBusy = YES;
    release_all_keys();
    gStartButton.enabled = NO;
    gLauncher.hidden = YES;
    [self applyPadLayout];
    gPad.transform = CGAffineTransformIdentity;
    gPad.center = CGPointMake(self.view.bounds.size.width/2, self.view.bounds.size.height/2);
    gPad.hidden = !gSet.virtualPad;
    if (gSet.virtualPad) [self.view bringSubviewToFront:gPad];
    if (custom) [self beginPadEdit];
    apply_environment();
    [self applyDisplayToLayer];
    char *mode = strdup("boot");
    pthread_attr_t attr; pthread_attr_init(&attr); pthread_attr_setstacksize(&attr, 64 * 1024 * 1024);
    pthread_t th;
    if (pthread_create(&th, &attr, loader_thread, mode) == 0) pthread_detach(th);
    else { free(mode); gBusy = NO; gLauncher.hidden = NO; gPad.hidden = YES; gStartButton.enabled = YES; }
    pthread_attr_destroy(&attr);
}
- (UIView *)padViewForKey:(NSString *)key {
    for (UIView *v in gPad.subviews) if ([v.accessibilityIdentifier isEqualToString:key]) return v;
    return nil;
}
- (void)applyPadLayout {
    for (UIView *v in gPad.subviews) {
        NSString *key = v.accessibilityIdentifier; if (!key.length) continue;
        NSDictionary *d = gPadLayout[key];
        NSString *def = gPadDefaultFrames[key];
        if (d) {
            v.frame = CGRectMake([d[@"x"] doubleValue], [d[@"y"] doubleValue], [d[@"w"] doubleValue], [d[@"h"] doubleValue]);
            v.alpha = [d[@"a"] doubleValue];
        } else if (def) {
            v.frame = CGRectFromString(def); v.alpha = 1.0;
        }
    }
}
- (void)storePadItem:(NSString *)key view:(UIView *)v {
    if (!key.length || !v) return;
    gPadLayout[key] = @{@"x": @(v.frame.origin.x), @"y": @(v.frame.origin.y),
                        @"w": @(v.frame.size.width), @"h": @(v.frame.size.height),
                        @"a": @(v.alpha)};
    save_settings();
}
- (void)storeAllPadItems {
    for (UIView *v in gPad.subviews) if (v.accessibilityIdentifier.length) [self storePadItem:v.accessibilityIdentifier view:v];
}
- (void)setPadGestures:(BOOL)on {
    for (UIView *v in gPad.subviews) for (UIGestureRecognizer *g in v.gestureRecognizers)
        if ([g isKindOfClass:UIPanGestureRecognizer.class] || [g isKindOfClass:UITapGestureRecognizer.class]) g.enabled = on;
}
- (void)beginPadEdit {
    gPadLayoutSnapshot = [gPadLayout copy];
    gEditPad = YES;
    gSet.virtualPad = YES; gPad.hidden = NO;
    [self applyPadLayout]; [self.view bringSubviewToFront:gPad];
    [self setPadGestures:YES];

    CGFloat w = self.view.bounds.size.width;
    gPadHUD = [[UIView alloc] initWithFrame:CGRectMake(w/2-210, 14, 420, 46)];
    gPadHUD.backgroundColor = [UIColor colorWithWhite:0 alpha:0.76];
    gPadHUD.layer.cornerRadius = 10; gPadHUD.clipsToBounds = YES;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(14, 8, 240, 30)];
    l.text = @"拖动按钮移动 · 点击调大小/透明度";
    l.textColor = UIColor.whiteColor; l.font = [UIFont boldSystemFontOfSize:12];
    [gPadHUD addSubview:l];
    UIButton *save = [UIButton buttonWithType:UIButtonTypeSystem];
    save.frame = CGRectMake(262, 7, 68, 32);
    [save setTitle:@"保存" forState:UIControlStateNormal];
    save.backgroundColor = [UIColor colorWithRed:0.09 green:0.55 blue:0.31 alpha:1];
    save.layer.cornerRadius = 7; [save setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [save addTarget:self action:@selector(savePadEdit:) forControlEvents:UIControlEventTouchUpInside];
    [gPadHUD addSubview:save];
    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    cancel.frame = CGRectMake(336, 7, 70, 32);
    [cancel setTitle:@"取消" forState:UIControlStateNormal];
    cancel.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1];
    cancel.layer.cornerRadius = 7; [cancel setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [cancel addTarget:self action:@selector(cancelPadEdit:) forControlEvents:UIControlEventTouchUpInside];
    [gPadHUD addSubview:cancel];
    [self.view addSubview:gPadHUD];
}
- (void)padItemPan:(UIPanGestureRecognizer *)g {
    if (!gEditPad) return;
    UIView *v = g.view;
    if (g.state == UIGestureRecognizerStateBegan) gPanStart = v.frame;
    CGPoint t = [g translationInView:gPad];
    CGRect f = gPanStart;
    f.origin.x += t.x; f.origin.y += t.y;
    f.origin.x = MAX(0, MIN(gPad.bounds.size.width - f.size.width, f.origin.x));
    f.origin.y = MAX(0, MIN(gPad.bounds.size.height - f.size.height, f.origin.y));
    v.frame = f;
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled)
        [self storePadItem:v.accessibilityIdentifier view:v];
}
- (void)padItemTap:(UITapGestureRecognizer *)g {
    if (!gEditPad) return;
    UIView *v = g.view; NSString *key = v.accessibilityIdentifier; if (!key.length) return;
    [self closePadEditor];
    gEditItemKey = key; gEditItemFrame = v.frame; gEditItemAlpha = v.alpha;
    CGRect pr = self.view.bounds;
    gPadEditorPanel = [[UIView alloc] initWithFrame:CGRectMake(pr.size.width/2-170, pr.size.height/2-115, 340, 230)];
    gPadEditorPanel.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.97];
    gPadEditorPanel.layer.cornerRadius = 12; gPadEditorPanel.layer.borderWidth = 1;
    gPadEditorPanel.layer.borderColor = [UIColor colorWithWhite:0.4 alpha:1].CGColor;
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, 308, 26)];
    title.text = [NSString stringWithFormat:@"自定义：%@", key];
    title.textColor = UIColor.whiteColor; title.font = [UIFont boldSystemFontOfSize:16];
    [gPadEditorPanel addSubview:title];
    UILabel *sl1 = [[UILabel alloc] initWithFrame:CGRectMake(16, 52, 60, 20)];
    sl1.text = @"大小"; sl1.textColor = UIColor.whiteColor; sl1.font = [UIFont systemFontOfSize:13];
    [gPadEditorPanel addSubview:sl1];
    UISlider *size = [[UISlider alloc] initWithFrame:CGRectMake(78, 48, 230, 30)];
    size.minimumValue = 0.5f; size.maximumValue = 2.0f;
    CGRect base = CGRectFromString(gPadDefaultFrames[key]);
    size.value = base.size.width > 0 ? (float)(v.frame.size.width / base.size.width) : 1.0f;
    size.tag = 1; [size addTarget:self action:@selector(padEditorSlider:) forControlEvents:UIControlEventValueChanged];
    [gPadEditorPanel addSubview:size];
    UILabel *sl2 = [[UILabel alloc] initWithFrame:CGRectMake(16, 104, 60, 20)];
    sl2.text = @"透明度"; sl2.textColor = UIColor.whiteColor; sl2.font = [UIFont systemFontOfSize:13];
    [gPadEditorPanel addSubview:sl2];
    UISlider *alpha = [[UISlider alloc] initWithFrame:CGRectMake(78, 100, 230, 30)];
    alpha.minimumValue = 0.2f; alpha.maximumValue = 1.0f; alpha.value = (float)v.alpha;
    alpha.tag = 2; [alpha addTarget:self action:@selector(padEditorSlider:) forControlEvents:UIControlEventValueChanged];
    [gPadEditorPanel addSubview:alpha];
    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    done.frame = CGRectMake(190, 172, 126, 38);
    [done setTitle:@"完成" forState:UIControlStateNormal];
    done.backgroundColor = [UIColor colorWithRed:0.09 green:0.55 blue:0.31 alpha:1];
    done.layer.cornerRadius = 8; [done setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [done addTarget:self action:@selector(padEditorDone:) forControlEvents:UIControlEventTouchUpInside];
    [gPadEditorPanel addSubview:done];
    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    cancel.frame = CGRectMake(16, 172, 126, 38);
    [cancel setTitle:@"取消" forState:UIControlStateNormal];
    cancel.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1];
    cancel.layer.cornerRadius = 8; [cancel setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [cancel addTarget:self action:@selector(padEditorCancel:) forControlEvents:UIControlEventTouchUpInside];
    [gPadEditorPanel addSubview:cancel];
    [self.view addSubview:gPadEditorPanel];
}
- (void)padEditorSlider:(UISlider *)sl {
    UIView *v = [self padViewForKey:gEditItemKey]; if (!v) return;
    if (sl.tag == 1) {
        CGRect base = CGRectFromString(gPadDefaultFrames[gEditItemKey]);
        CGPoint c = v.center;
        v.bounds = CGRectMake(0, 0, base.size.width * sl.value, base.size.height * sl.value);
        v.center = c;
    } else v.alpha = sl.value;
}
- (void)closePadEditor { [gPadEditorPanel removeFromSuperview]; gPadEditorPanel = nil; }
- (void)padEditorDone:(id)sender {
    (void)sender;
    UIView *v = [self padViewForKey:gEditItemKey];
    [self closePadEditor];
    if (v) [self storePadItem:gEditItemKey view:v];
}
- (void)padEditorCancel:(id)sender {
    (void)sender;
    UIView *v = [self padViewForKey:gEditItemKey];
    if (v) { v.frame = gEditItemFrame; v.alpha = gEditItemAlpha; }
    [self closePadEditor];
}
- (void)savePadEdit:(id)sender {
    (void)sender;
    [self closePadEditor]; [self storeAllPadItems]; save_settings();
    [gPadHUD removeFromSuperview]; gPadHUD = nil;
    [self setPadGestures:NO]; gEditPad = NO;
}
- (void)cancelPadEdit:(id)sender {
    (void)sender;
    [self closePadEditor];
    gPadLayout = [gPadLayoutSnapshot mutableCopy];
    [self applyPadLayout]; save_settings();
    [gPadHUD removeFromSuperview]; gPadHUD = nil;
    [self setPadGestures:NO]; gEditPad = NO;
}
- (void)pickModFolder {
    gPickingMod = YES;
    UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
    p.delegate = self; p.allowsMultipleSelection = NO;
    [self presentViewController:p animated:YES completion:nil];
}
- (void)clearMod {
    gModPath = nil; save_settings(); [gTable reloadData];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    if (!gPickingMod) return;
    gPickingMod = NO;
    NSURL *src = urls.firstObject; if (!src) return;
    [src startAccessingSecurityScopedResource];
    NSString *mods = [documents_dir() stringByAppendingPathComponent:@"mods"];
    [[NSFileManager defaultManager] createDirectoryAtPath:mods withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dest = [mods stringByAppendingPathComponent:src.lastPathComponent];
    NSError *e = nil;
    [[NSFileManager defaultManager] removeItemAtPath:dest error:nil];
    BOOL ok = [[NSFileManager defaultManager] copyItemAtURL:src toURL:[NSURL fileURLWithPath:dest isDirectory:YES] error:&e];
    [src stopAccessingSecurityScopedResource];
    if (ok && [[NSFileManager defaultManager] fileExistsAtPath:[dest stringByAppendingPathComponent:@"manifest.tsv"]]) {
        gModPath = dest; save_settings();
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Mod 已添加" message:[NSString stringWithFormat:@"%@\n下次开始游戏生效", [dest lastPathComponent]] preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
    } else {
        if (ok) [[NSFileManager defaultManager] removeItemAtPath:dest error:nil];
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Mod 无效" message:e.localizedDescription ?: @"文件夹内没有 manifest.tsv" preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
    }
    [gTable reloadData];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller { (void)controller; gPickingMod = NO; }

- (void)addPadItem:(UIView *)v key:(NSString *)key {
    v.accessibilityIdentifier = key;
    gPadDefaultFrames[key] = NSStringFromCGRect(v.frame);
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(padItemPan:)];
    pan.enabled = NO; pan.cancelsTouchesInView = NO;
    [v addGestureRecognizer:pan];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(padItemTap:)];
    tap.enabled = NO; tap.cancelsTouchesInView = NO;
    [v addGestureRecognizer:tap];
    [gPad addSubview:v];
}
- (void)buildPad:(CGRect)r {
    CGFloat w = r.size.width, h = r.size.height;
    gPadDefaultFrames = [NSMutableDictionary dictionary];
    NSArray *top = @[@[@"L", @6, @16, @10, @52, @30], @[@"ZL", @12, @16, @44, @52, @30],
                     @[@"R", @8, @(-68), @10, @52, @30], @[@"ZR", @14, @(-68), @44, @52, @30],
                     @[@"−", @56, @(-46), @10, @38, @30], @[@"+", @58, @6, @10, @38, @30]];
    for (NSArray *a in top) {
        CGFloat x = [a[2] doubleValue]; if (x < 0) x = w + x;
        NSString *key = [NSString stringWithFormat:@"btn%@", a[0]];
        UIButton *b = [self padButton:a[0] code:[a[1] unsignedIntValue] frame:CGRectMake(x, [a[3] doubleValue], [a[4] doubleValue], [a[5] doubleValue])];
        [self addPadItem:b key:key];
    }
    StickView *ls = [[StickView alloc] initWithFrame:CGRectMake(18, h-126, 104, 104) right:NO];
    [self addPadItem:ls key:@"stickL"];
    StickView *rs = [[StickView alloc] initWithFrame:CGRectMake(w-122, h-238, 96, 96) right:YES];
    [self addPadItem:rs key:@"stickR"];
    NSArray *dpad = @[@[@"▲", @3, @148, @(h-126)], @[@"◀", @4, @110, @(h-88)], @[@"▶", @5, @186, @(h-88)], @[@"▼", @17, @148, @(h-50)]];
    for (NSArray *a in dpad) {
        UIButton *b = [self padButton:a[0] code:[a[1] unsignedIntValue] frame:CGRectMake([a[2] doubleValue], [a[3] doubleValue], 38, 38)];
        [self addPadItem:b key:[NSString stringWithFormat:@"btn%@", a[1]]];
    }
    CGFloat cx = w-80, cy = h-86, s = 42;
    NSArray *abxy = @[@[@"X", @34, @(cx-s/2), @(cy-1.5*s)], @[@"Y", @32, @(cx-1.5*s), @(cy-s/2)],
                      @[@"A", @38, @(cx+0.5*s), @(cy-s/2)], @[@"B", @40, @(cx-s/2), @(cy+0.5*s)]];
    for (NSArray *a in abxy) {
        UIButton *b = [self padButton:a[0] code:[a[1] unsignedIntValue] frame:CGRectMake([a[2] doubleValue], [a[3] doubleValue], s, s)];
        [self addPadItem:b key:[NSString stringWithFormat:@"btn%@", a[0]]];
    }
    // restore persisted positions on top of defaults
    [self applyPadLayout];
}
- (UIButton *)padButton:(NSString *)title code:(unsigned)code frame:(CGRect)f {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = f; b.tag = code; b.exclusiveTouch = NO;
    b.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    b.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.50];
    b.layer.cornerRadius = 9; b.layer.borderWidth = 1;
    b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.32].CGColor;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [b addTarget:self action:@selector(padDown:) forControlEvents:UIControlEventTouchDown];
    [b addTarget:self action:@selector(padUp:) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchCancel];
    return b;
}
- (void)padDown:(UIButton *)b { if (!gEditPad) set_key(swap_button((unsigned)b.tag), 1); }
- (void)padUp:(UIButton *)b { if (!gEditPad) set_key(swap_button((unsigned)b.tag), 0); }

- (void)applicationWillResignActive:(UIApplication *)application { (void)application; release_all_keys(); runtime_input_clear(); }
@end

static void *loader_thread(void *arg) {
    char *mode = (char *)arg;
    char *argv[] = {(char *)"totk-native", (char *)"rewritten", mode, NULL};
    int rc = totk_loader_main(3, argv);
    dispatch_async(dispatch_get_main_queue(), ^{
        gBusy = NO; gPad.hidden = YES; gLauncher.hidden = NO; gStartButton.enabled = gHasData;
        set_status([NSString stringWithFormat:@"游戏已退出 (loader %d)", rc]);
    });
    free(mode); return NULL;
}

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) Launcher *launcher;
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opt {
    (void)app; (void)opt;
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.launcher = [Launcher new];
    self.window.rootViewController = self.launcher;
    [self.window makeKeyAndVisible];
    return YES;
}
- (void)applicationWillResignActive:(UIApplication *)app { (void)app; [self.launcher applicationWillResignActive:app]; }
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class])); }
}
