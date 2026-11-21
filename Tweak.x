#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>

typedef CFMutableDictionaryRef (*IOServiceMatching_t)(const char *name);
typedef uint32_t (*IOServiceGetMatchingService_t)(uint32_t mainPort, CFDictionaryRef matching);
typedef int32_t (*IORegistryEntryCreateCFProperties_t)(uint32_t entry, CFMutableDictionaryRef *properties, CFAllocatorRef allocator, uint32_t options);
typedef int32_t (*IOObjectRelease_t)(uint32_t object);

static IOServiceMatching_t p_IOServiceMatching = NULL;
static IOServiceGetMatchingService_t p_IOServiceGetMatchingService = NULL;
static IORegistryEntryCreateCFProperties_t p_IORegistryEntryCreateCFProperties = NULL;
static IOObjectRelease_t p_IOObjectRelease = NULL;

static BOOL loadIOKitSymbols(void) {
    static BOOL loaded = NO;
    if (loaded) return YES;
    void *handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!handle) return NO;
    p_IOServiceMatching = (IOServiceMatching_t)dlsym(handle, "IOServiceMatching");
    p_IOServiceGetMatchingService = (IOServiceGetMatchingService_t)dlsym(handle, "IOServiceGetMatchingService");
    p_IORegistryEntryCreateCFProperties = (IORegistryEntryCreateCFProperties_t)dlsym(handle, "IORegistryEntryCreateCFProperties");
    p_IOObjectRelease = (IOObjectRelease_t)dlsym(handle, "IOObjectRelease");
    loaded = (p_IOServiceMatching && p_IOServiceGetMatchingService && p_IORegistryEntryCreateCFProperties && p_IOObjectRelease);
    return loaded;
}

static NSDictionary *readBatteryInfo(void) {
    if (!loadIOKitSymbols()) return nil;
    CFMutableDictionaryRef matching = p_IOServiceMatching("AppleSmartBattery");
    if (!matching) return nil;
    uint32_t service = p_IOServiceGetMatchingService(0, matching);
    if (!service) return nil;
    CFMutableDictionaryRef props = NULL;
    int32_t kr = p_IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0);
    p_IOObjectRelease(service);
    if (kr != 0 || !props) return nil;
    return (__bridge_transfer NSDictionary *)props;
}

@interface BatteryETAWindow : UIWindow
@end

@implementation BatteryETAWindow
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return NO; // 完全穿透触摸，不影响下拉通知中心和状态栏操作
}
@end

@interface BatteryETAManager : NSObject
@property (nonatomic, strong) BatteryETAWindow *overlayWindow;
@property (nonatomic, strong) UILabel *etaLabel;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) double smoothedDischargeMa;
@property (nonatomic, assign) double smoothedChargeMa;
+ (instancetype)shared;
- (void)start;
@end

@implementation BatteryETAManager

+ (instancetype)shared {
    static BatteryETAManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[BatteryETAManager alloc] init];
    });
    return instance;
}

- (void)start {
    if (self.overlayWindow) return;

    UIWindowScene *activeScene = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            activeScene = (UIWindowScene *)scene;
            if (scene.activationState == UISceneActivationStateForegroundActive) break;
        }
    }

    if (activeScene) {
        self.overlayWindow = [[BatteryETAWindow alloc] initWithWindowScene:activeScene];
    } else {
        self.overlayWindow = [[BatteryETAWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    }

    self.overlayWindow.windowLevel = UIWindowLevelStatusBar + 100;
    self.overlayWindow.backgroundColor = [UIColor clearColor];
    self.overlayWindow.userInteractionEnabled = NO;

    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor clearColor];
    vc.view.userInteractionEnabled = NO;
    self.overlayWindow.rootViewController = vc;

    self.etaLabel = [[UILabel alloc] init];
    self.etaLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.etaLabel.font = [UIFont monospacedDigitSystemFontOfSize:11.5 weight:UIFontWeightSemibold];
    self.etaLabel.textColor = [UIColor whiteColor];
    self.etaLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.45];
    self.etaLabel.textAlignment = NSTextAlignmentCenter;
    self.etaLabel.layer.cornerRadius = 7.0;
    self.etaLabel.layer.masksToBounds = YES;
    self.etaLabel.text = @" 统计中... ";

    [vc.view addSubview:self.etaLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.etaLabel.topAnchor constraintEqualToAnchor:vc.view.topAnchor constant:2.0],
        [self.etaLabel.centerXAnchor constraintEqualToAnchor:vc.view.centerXAnchor],
        [self.etaLabel.heightAnchor constraintEqualToConstant:18.0]
    ]];

    self.overlayWindow.hidden = NO;

    [self updateETA];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                  target:self
                                                selector:@selector(updateETA)
                                                userInfo:nil
                                                 repeats:YES];
}

- (NSString *)formatHours:(double)hours prefix:(NSString *)prefix {
    if (hours <= 0 || hours > 99.0 || isnan(hours) || isinf(hours)) {
        return @" -- ";
    }
    NSInteger totalMinutes = (NSInteger)llround(hours * 60.0);
    NSInteger h = totalMinutes / 60;
    NSInteger m = totalMinutes % 60;
    if (h > 0) {
        return [NSString stringWithFormat:@" %@ %ldh%02ldm ", prefix, (long)h, (long)m];
    }
    return [NSString stringWithFormat:@" %@ %ldm ", prefix, (long)m];
}

- (void)updateETA {
    NSDictionary *info = readBatteryInfo();
    if (!info) {
        self.etaLabel.text = @" 无电池数据 ";
        return;
    }

    BOOL isCharging = [info[@"IsCharging"] boolValue];
    double currentMah = [info[@"AppleRawCurrentCapacity"] doubleValue];
    double maxMah = [info[@"AppleRawMaxCapacity"] doubleValue];
    long long rawAmps = [info[@"InstantAmperage"] longLongValue];

    // 兼容部分设备只提供 Amperage 的情况
    if (rawAmps == 0 && info[@"Amperage"]) {
        rawAmps = [info[@"Amperage"] longLongValue];
    }

    if (currentMah <= 0) {
        self.etaLabel.text = @" -- ";
        return;
    }

    double alpha = 0.2; // 指数滑动平均系数，数值越小越平稳

    if (isCharging && rawAmps > 10) {
        double chargeMa = (double)rawAmps;
        self.smoothedChargeMa = (self.smoothedChargeMa <= 0) ? chargeMa : (alpha * chargeMa + (1.0 - alpha) * self.smoothedChargeMa);
        double remainMah = maxMah - currentMah;
        if (remainMah <= 0) {
            self.etaLabel.text = @" 已充满 ";
        } else {
            self.etaLabel.text = [self formatHours:(remainMah / self.smoothedChargeMa) prefix:@"充"];
        }
    } else if (!isCharging && rawAmps < -10) {
        double dischargeMa = fabs((double)rawAmps);
        self.smoothedDischargeMa = (self.smoothedDischargeMa <= 0) ? dischargeMa : (alpha * dischargeMa + (1.0 - alpha) * self.smoothedDischargeMa);
        self.etaLabel.text = [self formatHours:(currentMah / self.smoothedDischargeMa) prefix:@"剩"];
    } else {
        self.etaLabel.text = isCharging ? @" 充电中 " : @" 待机中 ";
    }
}

@end

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[BatteryETAManager shared] start];
    });
}
%end
