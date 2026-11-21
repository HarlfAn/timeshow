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
    // 直接匹配本机实际的 AppleARMPMUCharger 节点
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
        self.overlayWindow = [[BatteryETAWindow alloc] initWithFrame:[UIScreen mainScreen].
