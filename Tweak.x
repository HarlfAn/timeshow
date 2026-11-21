#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <substrate.h>

static CFPropertyListRef (*orig_MGCopyAnswer)(CFStringRef property);

static CFPropertyListRef hooked_MGCopyAnswer(CFStringRef property) {
    if (property != NULL) {
        // 拦截 Apple Intelligence / 新版 Siri 跑马灯特效能力位查询
        if (CFEqual(property, CFSTR("A62OafQ85EJAiiqKn4agtg"))) {
            // MGCopyAnswer 遵循 CoreFoundation 的 Create/Copy 内存规则，返回前必须 CFRetain
            CFRetain(kCFBooleanTrue);
            return kCFBooleanTrue;
        }
    }
    return orig_MGCopyAnswer(property);
}

%ctor {
    void *handle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
    if (handle) {
        void *sym = dlsym(handle, "MGCopyAnswer");
        if (sym) {
            MSHookFunction(sym, (void *)hooked_MGCopyAnswer, (void **)&orig_MGCopyAnswer);
        }
    }
}
