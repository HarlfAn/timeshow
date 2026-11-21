#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>

static NSString * const kPrefsDomain = @"com.custom.batteryeta";
static CFStringRef const kPrefsChangedNotification = CFSTR("com.custom.batteryeta/prefsChanged");

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
    CFMutableDictionaryRef matching = p_IOServiceMatching("AppleARMPMUCharger");
    if (!matching) return nil;
    uint32_t service = p_IOServiceGetMatchingService(0, matching);
    if (!service) return nil;
    CFMutableDictionaryRef props = NULL;
    int32_t kr = p_IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0);
    p_IOObjectRelease(service);
    if (kr != 0 || !props) return nil;
    return (__bridge_transfer NSDictionary *)props;
}

static id prefValueForKey(NSString *key) {
    return (__bridge_transfer id)CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kPrefsDomain);
}

@interface BatteryETAWindow : UIWindow
@end

@implementation BatteryETAWindow
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return NO;
}
@end

@interface BatteryETAManager : NSObject
@property (nonatomic, strong) BatteryETAWindow *overlayWindow;
@property (nonatomic, strong) UILabel *etaLabel;
@property (nonatomic, strong) NSLayoutConstraint *topConstraint;
@property (nonatomic, strong) NSLayoutConstraint *horizontalConstraint;
@property (nonatomic, strong) NSLayoutConstraint *heightConstraint;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) double smoothedDischargeMa;
@property (nonatomic, assign) double smoothedChargeMa;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) NSInteger alignment;
@property (nonatomic, assign) CGFloat fontSize;
@property (nonatomic, assign) CGFloat offsetY;
@property (nonatomic, assign) CGFloat offsetX;
@property (nonatomic, assign) CGFloat bgAlpha;
@property (nonatomic, assign) NSInteger textColorMode;
@property (nonatomic, assign) BOOL showPower;
@property (nonatomic, assign) NSTimeInterval refreshInterval;
+ (instancetype)shared;
- (void)start;
- (void)reloadPreferences;
@end

static void prefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[BatteryETAManager shared] reloadPreferences];
    });
}

@implementation BatteryETAManager

+ (instancetype)shared {
    static BatteryETAManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[BatteryETAManager alloc] init];
    });
    return instance;
}

- (void)readPreferences {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kPrefsDomain);

    id vEnabled = prefValueForKey(@"enabled");
    self.enabled = vEnabled ? [vEnabled boolValue] : YES;

    id vAlign = prefValueForKey(@"alignment");
    self.alignment = vAlign ? [vAlign integerValue] : 1; // 0=居左 1=居中 2=居右

    id vFont = prefValueForKey(@"fontSize");
    self.fontSize = vFont ? [vFont floatValue] : 11.5f;

    id vOffsetY = prefValueForKey(@"offsetY");
    self.offsetY = vOffsetY ? [vOffsetY floatValue] : 2.0f;

    id vOffsetX = prefValueForKey(@"offsetX");
    self.offsetX = vOffsetX ? [vOffsetX floatValue] : 0.0f;

    id vAlpha = prefValueForKey(@"bgAlpha");
    self.bgAlpha = vAlpha ? [vAlpha floatValue] : 0.45f;

    id vTextColor = prefValueForKey(@"textColorMode");
    self.textColorMode = vTextColor ? [vTextColor integerValue] : 0; // 0=白 1=黑

    id vPower = prefValueForKey(@"showPower");
    self.showPower = vPower ? [vPower boolValue] : NO;

    id vInterval = prefValueForKey(@"refreshInterval");
    double interval = vInterval ? round([vInterval doubleValue]) : 5.0;
    if (interval < 1.0) interval = 1.0;
    if (interval > 60.0) interval = 60.0;
    self.refreshInterval = interval;
}

- (void)restartTimer {
    if (self.timer) {
        [self.timer invalidate];
        self.timer = nil;
    }
    if (!self.enabled) return;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:self.refreshInterval
                                                  target:self
                                                selector:@selector(updateETA)
                                                userInfo:nil
                                                 repeats:YES];
}

- (void)applyAppearance {
    if (!self.overlayWindow || !self.etaLabel) return;

    UIView *container = self.overlayWindow.rootViewController.view;
    CGFloat barHeight = self.fontSize + 6.5f;

    self.overlayWindow.hidden = !self.enabled;
    self.etaLabel.font = [UIFont monospacedDigitSystemFontOfSize:self.fontSize weight:UIFontWeightSemibold];
    self.etaLabel.textColor = (self.textColorMode == 1) ? [UIColor blackColor] : [UIColor whiteColor];
    self.etaLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:self.bgAlpha];
    self.etaLabel.layer.cornerRadius = barHeight * 0.38f;

    self.topConstraint.constant = self.offsetY;
    self.heightConstraint.constant = barHeight;

    if (self.horizontalConstraint) {
        self.horizontalConstraint.active = NO;
    }

    if (self.alignment == 0) {
        self.horizontalConstraint = [self.etaLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:(12.0f + self.offsetX)];
    } else if (self.alignment == 2) {
        self.horizontalConstraint = [self.etaLabel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:(-12.0f + self.offsetX)];
    } else {
        self.horizontalConstraint = [self.etaLabel.centerXAnchor constraintEqualToAnchor:container.centerXAnchor constant:self.offsetX];
    }
    self.horizontalConstraint.active = YES;
}

- (void)reloadPreferences {
    [self readPreferences];
    [self applyAppearance];
    [self restartTimer];
    [self updateETA];
}

- (void)start {
    if (self.overlayWindow) return;

    [self readPreferences];

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
    self.etaLabel.textAlignment = NSTextAlignmentCenter;
    self.etaLabel.layer.masksToBounds = YES;
    self.etaLabel.text = @" 统计中... ";

    [vc.view addSubview:self.etaLabel];

    self.topConstraint = [self.etaLabel.topAnchor constraintEqualToAnchor:vc.view.topAnchor constant:self.offsetY];
    self.heightConstraint = [self.etaLabel.heightAnchor constraintEqualToConstant:(self.fontSize + 6.5f)];
    self.topConstraint.active = YES;
    self.heightConstraint.active = YES;

    [self applyAppearance];

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    prefsChangedCallback,
                                    kPrefsChangedNotification,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    [self updateETA];
    [self restartTimer];
}

- (NSString *)formatHours:(double)hours prefix:(NSString *)prefix powerSuffix:(NSString *)powerSuffix {
    if (hours <= 0 || hours > 99.0 || isnan(hours) || isinf(hours)) {
        return [NSString stringWithFormat:@" --%@ ", powerSuffix];
    }
    NSInteger totalMinutes = (NSInteger)llround(hours * 60.0);
    NSInteger h = totalMinutes / 60;
    NSInteger m = totalMinutes % 60;
    if (h > 0) {
        return [NSString stringWithFormat:@" %@ %ldh%02ldm%@ ", prefix, (long)h, (long)m, powerSuffix];
    }
    return [NSString stringWithFormat:@" %@ %ldm%@ ", prefix, (long)m, powerSuffix];
}

- (void)updateETA {
    if (!self.enabled) return;

    NSDictionary *info = readBatteryInfo();
    if (!info) {
        self.etaLabel.text = @" 无电池数据 ";
        return;
    }

    BOOL isCharging = [info[@"IsCharging"] boolValue];
    BOOL externalConnected = [info[@"ExternalConnected"] boolValue];
    BOOL fullyCharged = [info[@"FullyCharged"] boolValue];

    double currentMah = [info[@"AppleRawCurrentCapacity"] doubleValue];
    double maxMah = [info[@"AppleRawMaxCapacity"] doubleValue];
    double voltageMv = [info[@"Voltage"] doubleValue];

    int64_t rawAmps = 0;
    if (info[@"InstantAmperage"]) {
        rawAmps = (int64_t)[info[@"InstantAmperage"] unsignedLongLongValue];
    } else if (info[@"Amperage"]) {
        rawAmps = (int64_t)[info[@"Amperage"] unsignedLongLongValue];
    }

    if (currentMah <= 0) {
        self.etaLabel.text = @" -- ";
        return;
    }

    NSString *powerSuffix = @"";
    if (self.showPower && voltageMv > 0) {
        double watts = (voltageMv * (double)rawAmps) / 1000000.0;
        powerSuffix = [NSString stringWithFormat:@" · %+.1fW", watts];
    }

    double alpha = 0.2;

    if (externalConnected && fullyCharged) {
        self.smoothedChargeMa = 0;
        self.smoothedDischargeMa = 0;
        self.etaLabel.text = [NSString stringWithFormat:@" 已充满%@ ", powerSuffix];
    } else if (isCharging && rawAmps > 10) {
        self.smoothedDischargeMa = 0;
        double chargeMa = (double)rawAmps;
        self.smoothedChargeMa = (self.smoothedChargeMa <= 0) ? chargeMa : (alpha * chargeMa + (1.0 - alpha) * self.smoothedChargeMa);
        double remainMah = maxMah - currentMah;
        if (remainMah <= 0) {
            self.etaLabel.text = [NSString stringWithFormat:@" 已充满%@ ", powerSuffix];
        } else {
            self.etaLabel.text = [self formatHours:(remainMah / self.smoothedChargeMa) prefix:@"充" powerSuffix:powerSuffix];
        }
    } else if (!externalConnected && rawAmps < -10) {
        self.smoothedChargeMa = 0;
        double dischargeMa = fabs((double)rawAmps);
        self.smoothedDischargeMa = (self.smoothedDischargeMa <= 0) ? dischargeMa : (alpha * dischargeMa + (1.0 - alpha) * self.smoothedDischargeMa);
        self.etaLabel.text = [self formatHours:(currentMah / self.smoothedDischargeMa) prefix:@"剩" powerSuffix:powerSuffix];
    } else if (externalConnected) {
        self.etaLabel.text = isCharging ? [NSString stringWithFormat:@" 充电中%@ ", powerSuffix] : [NSString stringWithFormat:@" 外接电源%@ ", powerSuffix];
    } else {
        self.etaLabel.text = [NSString stringWithFormat:@" 待机中%@ ", powerSuffix];
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
