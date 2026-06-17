/**
 * vcam_kami_hook.m v8.2
 *
 * 独立卡密系统 — 不依赖 yixi/10003，直接查 vcam_keys 表
 * 绑定序列号+UDID，刷机还原不变，多App共用同一台设备不冲突
 * v8.2: IOKit → MobileGestalt缓存plist → markcode兜底 三层降级
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>
#import <dlfcn.h>
#import <IOKit/IOKitLib.h>

// ============ 配置 ============

static NSString *const kKamiServer    = @"kami.jumo8.top";
static NSString *const kVIPExpire     = @"4102243200";

static NSString *const kKeyActivated  = @"vcam_kami_activated";
static NSString *const kKeyKamiValue  = @"vcam_kami_value";
static NSString *const kKeyMarkcode   = @"vcam_kami_markcode";

static const NSTimeInterval kVerifyTimeout = 5.0;

// ============ 辅助函数 ============

static BOOL isActivated() {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kKeyActivated];
}

static NSString *savedKami() {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kKeyKamiValue];
}

static NSString *savedMarkcode() {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kKeyMarkcode];
}

static void setActivated(NSString *kami, NSString *markcode) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:YES forKey:kKeyActivated];
    if (kami) [ud setObject:kami forKey:kKeyKamiValue];
    if (markcode) [ud setObject:markcode forKey:kKeyMarkcode];
    [ud synchronize];
    NSLog(@"[VCAM Hook] 💾 激活记录已保存: kami=%@ markcode=%@", kami, markcode);
}

static void clearActivated() {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:NO forKey:kKeyActivated];
    [ud removeObjectForKey:kKeyKamiValue];
    [ud removeObjectForKey:kKeyMarkcode];
    [ud synchronize];
    NSLog(@"[VCAM Hook] 🗑️ 激活记录已清除");
}

static NSString *getDeviceSerial() {
    // 方法1: IOKit IOPlatformSerialNumber
    io_service_t platformExpert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"));
    if (platformExpert) {
        CFTypeRef cfSerial = IORegistryEntryCreateCFProperty(platformExpert, CFSTR("IOPlatformSerialNumber"), kCFAllocatorDefault, 0);
        IOObjectRelease(platformExpert);
        if (cfSerial) {
            if (CFGetTypeID(cfSerial) == CFStringGetTypeID()) {
                NSString *serial = (__bridge_transfer NSString *)cfSerial;
                serial = [serial stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (serial.length > 0) return serial;
            } else { CFRelease(cfSerial); }
        }
    }

    // 方法2: 读 MobileGestalt 缓存 plist（系统容器内，TrollStore 可直接读）
    NSString *plistPath = @"/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist";
    NSDictionary *mgPlist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    if (mgPlist) {
        NSDictionary *cacheExtra = mgPlist[@"CacheExtra"];
        if (cacheExtra) {
            for (NSString *key in @[@"oPeik/9e8lQWMszEjbPzng", @"SerialNumber", @"IOPlatformSerialNumber"]) {
                NSString *val = cacheExtra[key];
                if ([val isKindOfClass:[NSString class]] && val.length >= 10) {
                    NSLog(@"[VCAM Hook] ✅ 通过 MobileGestalt 缓存获取序列号: %@ (key=%@)", val, key);
                    return val;
                }
            }
        }
    }

    return @"";
}

static NSString *getDeviceUDID() {
    void *handle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
    if (!handle) return nil;
    typedef CFTypeRef (*MGCopyAnswerFunc)(CFStringRef);
    MGCopyAnswerFunc MGCopyAnswer = (MGCopyAnswerFunc)dlsym(handle, "MGCopyAnswer");
    if (!MGCopyAnswer) { dlclose(handle); return nil; }
    CFTypeRef result = MGCopyAnswer(CFSTR("UniqueDeviceID"));
    dlclose(handle);
    if (!result) return nil;
    if (CFGetTypeID(result) != CFStringGetTypeID()) { CFRelease(result); return nil; }
    NSString *udid = (__bridge_transfer NSString *)result;
    return udid.length > 0 ? udid : nil;
}

static NSString *getStableMarkcode(NSString *fallbackUdid) {
    NSString *serial = getDeviceSerial();
    if (serial.length > 0) return serial;
    NSString *udid = getDeviceUDID();
    if (udid.length > 0) return udid;
    return fallbackUdid ?: @"";
}

// ============ 独立卡密验证 ============

static NSInteger vcamVerifySync(NSString *kami, NSString *markcode) {
    if (kami.length == 0 || markcode.length == 0) return -1;
    NSString *serial = getDeviceSerial();
    NSString *udid = getDeviceUDID() ?: @"";

    // 兜底: 如果 serial 和 udid 都拿不到，用 markcode 当 serial 传给 server
    // 保证 DB 里至少有一个可匹配的设备标识
    if (serial.length == 0 && udid.length == 0) {
        serial = markcode;
        NSLog(@"[VCAM Hook] ⚠️ IOKit serial 和 MobileGestalt UDID 都失败，用 markcode 兜底: %@", markcode);
    }

    NSString *eKami   = [kami stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *eMC     = [markcode stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *eSerial = [serial stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *eUdid   = [udid stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];

    NSString *urlStr = [NSString stringWithFormat:
        @"http://%@/trollstore-device-api.php?api=vcam_verify&kami=%@&serial=%@&udid=%@&markcode=%@",
        kKamiServer, eKami, eSerial, eUdid, eMC];

    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return -1;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                       timeoutInterval:kVerifyTimeout];
    request.HTTPMethod = @"GET";

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSInteger result = -1;

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = kVerifyTimeout;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                           completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data) {
            @try {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSInteger code = [json[@"code"] integerValue];
                result = (code == 200) ? 1 : 0;
                NSLog(@"[VCAM Hook] 🔍 vcam_verify: code=%ld result=%ld", (long)code, (long)result);
            } @catch (NSException *e) {
                result = -1;
            }
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];

    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kVerifyTimeout * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(sem, timeout) != 0) {
        NSLog(@"[VCAM Hook] ⚠️ vcam_verify 超时");
        return -1;
    }
    return result;
}

// ============ VCamURLProtocol ============

@interface VCamURLProtocol : NSURLProtocol
@end

@implementation VCamURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *host = request.URL.host;
    if ([host containsString:@"xnsp"] ||
        [host containsString:@"v200dd"] ||
        [host containsString:@"lengye"]) {
        return YES;
    }
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSString *urlStr = self.request.URL.absoluteString;
    NSLog(@"[VCAM Hook] 🛑 拦截请求: %@", urlStr);

    if ([urlStr containsString:@"action=check"]) {
        [self handleCheck];
    } else if ([urlStr containsString:@"action=use_kami"]) {
        NSString *kami = [self queryParam:@"kami" fromURL:self.request.URL];
        NSString *udid = [self queryParam:@"udid" fromURL:self.request.URL];
        NSLog(@"[VCAM Hook] 🔑 action=use_kami: kami=%@ udid=%@", kami, udid);
        if (kami.length > 0) {
            [self validateKami:kami udid:udid ?: @""];
        } else {
            [self returnJSON:@{@"code": @401, @"msg": @"请输入卡密"}];
        }
    } else {
        [self returnJSON:isActivated() ?
            @{@"code": @200, @"msg": @{@"vip": kVIPExpire}} :
            @{@"code": @401, @"msg": @"未授权"}];
    }
}

- (void)stopLoading {}

#pragma mark - check 请求

- (void)handleCheck {
    if (!isActivated()) {
        [self returnJSON:@{@"code": @401, @"msg": @"未授权"}];
        return;
    }

    NSString *kami = savedKami();
    NSString *markcode = getStableMarkcode(savedMarkcode());
    NSLog(@"[VCAM Hook] 🔄 check: kami=%@ markcode=%@", kami, markcode);

    NSInteger result = vcamVerifySync(kami, markcode);
    if (result == 1) {
        setActivated(kami, markcode);
        [self returnJSON:@{@"code": @200, @"msg": @{@"vip": kVIPExpire}}];
    } else if (result == 0) {
        NSLog(@"[VCAM Hook] 🚫 卡密验证失败，撤销授权");
        clearActivated();
        [self returnJSON:@{@"code": @401, @"msg": @"卡密已失效"}];
    } else {
        [self returnJSON:@{@"code": @200, @"msg": @{@"vip": kVIPExpire}}]; // 网络不通信任本地
    }
}

#pragma mark - 卡密验证

- (void)validateKami:(NSString *)kami udid:(NSString *)udid {
    NSString *markcode = getStableMarkcode(udid);
    NSLog(@"[VCAM Hook] 🔑 激活卡密: markcode=%@", markcode);

    NSInteger result = vcamVerifySync(kami, markcode);
    if (result == 1) {
        setActivated(kami, markcode);
        [self returnJSON:@{@"code": @200, @"msg": @{@"vip": kVIPExpire, @"kami": kami}}];
    } else if (result == 0) {
        [self returnJSON:@{@"code": @401, @"msg": @"卡密无效或已使用"}];
    } else {
        [self returnJSON:@{@"code": @500, @"msg": @"网络连接失败"}];
    }
}

#pragma mark - 辅助

- (NSString *)queryParam:(NSString *)key fromURL:(NSURL *)url {
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:key]) return item.value;
    }
    return nil;
}

- (void)returnJSON:(NSDictionary *)json {
    NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
    NSDictionary *headers = @{@"Content-Type": @"application/json; charset=utf-8"};
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
        initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:headers];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:data];
    [self.client URLProtocolDidFinishLoading:self];
}

@end

// ============ Protocol 注入 ============

static void injectProtocolIntoConfig(NSURLSessionConfiguration *config) {
    if (!config) return;
    NSMutableArray *protocols = [config.protocolClasses mutableCopy] ?: [NSMutableArray array];
    for (Class cls in protocols) {
        if (cls == [VCamURLProtocol class]) return;
    }
    [protocols insertObject:[VCamURLProtocol class] atIndex:0];
    config.protocolClasses = protocols;
}

// ============ NSURLSession Hook ============

static NSURLSessionConfiguration* (*orig_defaultConfig)(id, SEL);
static NSURLSessionConfiguration* (*orig_ephemeralConfig)(id, SEL);
static NSURLSession* (*orig_sessionWithConfig)(id, SEL, NSURLSessionConfiguration*);
static NSURLSession* (*orig_sessionWithConfigDelegate)(id, SEL, NSURLSessionConfiguration*, id, NSOperationQueue*);

static NSURLSessionConfiguration* hook_defaultConfig(id self, SEL _cmd) {
    NSURLSessionConfiguration *config = orig_defaultConfig(self, _cmd);
    injectProtocolIntoConfig(config);
    return config;
}

static NSURLSessionConfiguration* hook_ephemeralConfig(id self, SEL _cmd) {
    NSURLSessionConfiguration *config = orig_ephemeralConfig(self, _cmd);
    injectProtocolIntoConfig(config);
    return config;
}

static NSURLSession* hook_sessionWithConfig(id self, SEL _cmd, NSURLSessionConfiguration *config) {
    injectProtocolIntoConfig(config);
    return orig_sessionWithConfig(self, _cmd, config);
}

static NSURLSession* hook_sessionWithConfigDelegate(id self, SEL _cmd,
                                                      NSURLSessionConfiguration *config,
                                                      id delegate,
                                                      NSOperationQueue *queue) {
    injectProtocolIntoConfig(config);
    return orig_sessionWithConfigDelegate(self, _cmd, config, delegate, queue);
}

// ============ 构造函数 ============

__attribute__((constructor))
static void vcam_hook_init() {
    NSLog(@"[VCAM Hook] v8.2 Initializing (独立卡密系统)...");

    [NSURLProtocol registerClass:[VCamURLProtocol class]];

    Class configClass = objc_getClass("NSURLSessionConfiguration");
    if (configClass) {
        Method defMethod = class_getClassMethod(configClass, @selector(defaultSessionConfiguration));
        Method ephMethod = class_getClassMethod(configClass, @selector(ephemeralSessionConfiguration));
        if (defMethod) {
            orig_defaultConfig = (void*)method_setImplementation(defMethod, (IMP)hook_defaultConfig);
        }
        if (ephMethod) {
            orig_ephemeralConfig = (void*)method_setImplementation(ephMethod, (IMP)hook_ephemeralConfig);
        }
    }

    Class sessionClass = objc_getClass("NSURLSession");
    if (sessionClass) {
        Method swc = class_getClassMethod(sessionClass, @selector(sessionWithConfiguration:));
        Method swcd = class_getClassMethod(sessionClass, @selector(sessionWithConfiguration:delegate:delegateQueue:));
        if (swc) {
            orig_sessionWithConfig = (void*)method_setImplementation(swc, (IMP)hook_sessionWithConfig);
        }
        if (swcd) {
            orig_sessionWithConfigDelegate = (void*)method_setImplementation(swcd, (IMP)hook_sessionWithConfigDelegate);
        }
    }

    NSLog(@"[VCAM Hook] v8.2 Init complete");
    NSLog(@"[VCAM Hook] 激活状态: %@", isActivated() ? @"已激活" : @"未激活");
    if (isActivated()) {
        NSLog(@"[VCAM Hook] 卡密: %@ 设备: %@", savedKami(), savedMarkcode());
    }
}
