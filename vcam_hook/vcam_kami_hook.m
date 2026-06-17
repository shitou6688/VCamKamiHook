/**
 * vcam_kami_hook.m v7
 *
 * 修复抖音等App验证失败的问题：
 * - 新增 hook [NSURLSession sessionWithConfiguration:delegate:delegateQueue:]
 * - 在创建 session 时注入 Protocol（和 NetworkLogger 一样的方式）
 * - 抖音等 App 用自定义 configuration 创建 session，之前漏了
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>
#import <dlfcn.h>

// ============ 配置 ============

static NSString *const kKamiServer    = @"124.221.171.80";
static NSString *const kKamiAppID     = @"10003";
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
    size_t size = 0;
    sysctlbyname("hw.serialnumber", NULL, &size, NULL, 0);
    if (size > 0) {
        char *buf = (char *)malloc(size);
        sysctlbyname("hw.serialnumber", buf, &size, NULL, 0);
        NSString *serial = [NSString stringWithUTF8String:buf];
        free(buf);
        serial = [serial stringByTrimmingCharactersInSet:[NSCharacterSet controlCharacterSet]];
        if (serial.length > 0) return serial;
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

// 获取稳定的设备标识：序列号 > UDID > 传入的 udid
static NSString *getStableMarkcode(NSString *fallbackUdid) {
    NSString *serial = getDeviceSerial();
    if (serial.length > 0) return serial;
    NSString *udid = getDeviceUDID();
    if (udid.length > 0) return udid;
    return fallbackUdid ?: @"";
}

// 独立验证（查 trollstore_devices，绕过 yixi 的 markcode 绑定检查）
// 返回: 1=已授权  0=未授权需激活  -1=网络错误
static NSInteger tsVerifySync(NSString *kami, NSString *markcode) {
    if (kami.length == 0) return -1;
    NSString *serial = getDeviceSerial();
    NSString *udid = getDeviceUDID() ?: @"";
    
    NSString *eKami = [kami stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *eMC   = [markcode stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *eSerial = [serial stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *eUdid  = [udid stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    
    NSString *urlStr = [NSString stringWithFormat:
        @"http://%@/trollstore-device-api.php?api=ts_verify&serial=%@&udid=%@&markcode=%@&kami=%@",
        kKamiServer, eSerial, eUdid, eMC, eKami];
    
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
                result = (code == 200) ? 1 : (code == 301) ? 0 : -1;
                NSLog(@"[VCAM Hook] 🔍 ts_verify: code=%ld result=%ld", (long)code, (long)result);
            } @catch (NSException *e) {
                result = -1;
            }
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kVerifyTimeout * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(sem, timeout) != 0) {
        NSLog(@"[VCAM Hook] ⚠️ ts_verify 超时");
        return -1;
    }
    return result;
}

// 同步解绑卡密（把旧的 markcode 绑定清掉）
static BOOL unbindKamiSync(NSString *kami, NSString *oldMarkcode) {
    if (kami.length == 0 || oldMarkcode.length == 0) return NO;
    
    NSString *encodedKami = [kami stringByAddingPercentEncodingWithAllowedCharacters:
                             [NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *encodedMC = [oldMarkcode stringByAddingPercentEncodingWithAllowedCharacters:
                           [NSCharacterSet URLQueryAllowedCharacterSet]];
    
    NSString *urlStr = [NSString stringWithFormat:
        @"http://%@/api.php?api=kmunmachine&app=%@&kami=%@&markcode=%@",
        kKamiServer, kKamiAppID, encodedKami, encodedMC];
    
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return NO;
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                       timeoutInterval:kVerifyTimeout];
    request.HTTPMethod = @"GET";
    
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL success = NO;
    
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForRequest = kVerifyTimeout;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                           completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data) {
            @try {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSInteger code = [json[@"code"] integerValue];
                success = (code == 200);
                NSLog(@"[VCAM Hook] 🔄 解绑结果: code=%ld success=%d", (long)code, success);
            } @catch (NSException *e) {
                NSLog(@"[VCAM Hook] ⚠️ 解绑响应解析失败");
            }
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kVerifyTimeout * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(sem, timeout) != 0) {
        NSLog(@"[VCAM Hook] ⚠️ 解绑超时");
        return NO;
    }
    
    return success;
}

static NSInteger verifyKamiSync(NSString *kami, NSString *markcode) {
    if (kami.length == 0 || markcode.length == 0) return 0;
    
    NSString *encodedKami = [kami stringByAddingPercentEncodingWithAllowedCharacters:
                             [NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *encodedMC = [markcode stringByAddingPercentEncodingWithAllowedCharacters:
                           [NSCharacterSet URLQueryAllowedCharacterSet]];
    
    NSString *urlStr = [NSString stringWithFormat:
        @"http://%@/api.php?api=kmlogon&app=%@&kami=%@&markcode=%@",
        kKamiServer, kKamiAppID, encodedKami, encodedMC];
    
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return -1;
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                       timeoutInterval:kVerifyTimeout];
    request.HTTPMethod = @"GET";
    
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSInteger result = -1;
    
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForRequest = kVerifyTimeout;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                           completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            NSLog(@"[VCAM Hook] ⚠️ 同步验证网络失败: %@", error.localizedDescription);
            result = -1;
        } else {
            @try {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSInteger code = [json[@"code"] integerValue];
                result = (code == 200) ? 1 : 0;
                NSLog(@"[VCAM Hook] 🔍 同步验证结果: code=%ld result=%ld", (long)code, (long)result);
            } @catch (NSException *e) {
                result = -1;
            }
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kVerifyTimeout * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(sem, timeout) != 0) {
        NSLog(@"[VCAM Hook] ⚠️ 同步验证超时");
        return -1;
    }
    
    return result;
}

// ============ VCamURLProtocol 前置声明 ============

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
        if (isActivated()) {
            [self returnJSON:@{@"code": @200, @"msg": @{@"vip": kVIPExpire}}];
        } else {
            [self returnJSON:@{@"code": @401, @"msg": @"未授权"}];
        }
    }
}

- (void)stopLoading {}

#pragma mark - check 请求

- (void)handleCheck {
    if (!isActivated()) {
        NSLog(@"[VCAM Hook] ❌ 未激活，返回 401");
        [self returnJSON:@{@"code": @401, @"msg": @"未授权"}];
        return;
    }

    NSString *kami = savedKami();
    NSString *savedMC = savedMarkcode();
    NSString *markcode = getStableMarkcode(savedMC);
    NSLog(@"[VCAM Hook] 🔄 已激活，同步验证... savedMC=%@ stableMC=%@", savedMC, markcode);

    // 0. 先走独立验证（查 trollstore_devices，绕过 yixi markcode 检查）
    NSInteger tsResult = tsVerifySync(kami, markcode);
    if (tsResult == 1) {
        NSLog(@"[VCAM Hook] ✅ ts_verify 已授权，直接返回");
        setActivated(kami, markcode);
        [self returnJSON:@{@"code": @200, @"msg": @{@"vip": kVIPExpire}}];
        return;
    }

    // 1. ts_verify 未命中，用 kmlogon 验证
    NSInteger result = verifyKamiSync(kami, markcode);

    if (result == 1) {
        NSLog(@"[VCAM Hook] ✅ 卡密有效，返回授权");
        setActivated(kami, markcode);
        [self returnJSON:@{@"code": @200, @"msg": @{@"vip": kVIPExpire}}];
        return;
    }

    // 2. 验证失败，尝试解绑后重试（需要本地保存过旧标识）
    if (savedMC.length > 0 && ![savedMC isEqualToString:markcode]) {
        NSLog(@"[VCAM Hook] 🔄 markcode 变化，试解绑旧绑定...");
        if (unbindKamiSync(kami, savedMC)) {
            result = verifyKamiSync(kami, markcode);
            if (result == 1) {
                setActivated(kami, markcode);
                [self returnJSON:@{@"code": @200, @"msg": @{@"vip": kVIPExpire}}];
                return;
            }
        }
        // 3. 解绑失败或重试失败 → 用旧标识兜底
        NSLog(@"[VCAM Hook] ⚠️ 解绑/重试未成功，用旧标识兜底");
        result = verifyKamiSync(kami, savedMC);
        if (result == 1) {
            NSLog(@"[VCAM Hook] ✅ 旧标识验证通过，暂不迁移");
            [self returnJSON:@{@"code": @200, @"msg": @{@"vip": kVIPExpire}}];
            return;
        }
    }

    // 最终失败
    if (result == 0) {
        NSLog(@"[VCAM Hook] 🚫 卡密已失效，撤销授权");
        clearActivated();
        [self returnJSON:@{@"code": @401, @"msg": @"卡密已失效"}];
    } else {
        NSLog(@"[VCAM Hook] ⚠️ 验证网络失败，信任本地记录");
        [self returnJSON:@{@"code": @200, @"msg": @{@"vip": kVIPExpire}}];
    }
}

#pragma mark - 卡密验证

// 发 kmlogon 验证请求，回调返回 serverCode
- (void)doKmlogon:(NSString *)kami
         markcode:(NSString *)markcode
        onSuccess:(void(^)(NSDictionary *json))onSuccess
        onFailure:(void(^)(NSInteger code, NSString *msg))onFailure
         onError:(void(^)(NSString *err))onError {

    NSString *encodedKami = [kami stringByAddingPercentEncodingWithAllowedCharacters:
                             [NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *encodedMC = [markcode stringByAddingPercentEncodingWithAllowedCharacters:
                           [NSCharacterSet URLQueryAllowedCharacterSet]];

    NSString *urlStr = [NSString stringWithFormat:
        @"http://%@/api.php?api=kmlogon&app=%@&kami=%@&markcode=%@",
        kKamiServer, kKamiAppID, encodedKami, encodedMC];

    NSLog(@"[VCAM Hook] 🌐 kmlogon: markcode=%@", markcode);

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:urlStr]
                                             cachePolicy:NSURLRequestReloadIgnoringCacheData
                                         timeoutInterval:15.0];

    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                           completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            if (onError) onError(@"网络连接失败");
            return;
        }
        @try {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSInteger code = [json[@"code"] integerValue];
            if (code == 200) {
                if (onSuccess) onSuccess(json);
            } else {
                NSString *msg = json[@"msg"] ?: @"验证失败";
                if (![msg isKindOfClass:[NSString class]]) msg = [msg description];
                if (onFailure) onFailure(code, msg);
            }
        } @catch (NSException *e) {
            if (onError) onError(@"服务器响应格式错误");
        }
    }];
    [task resume];
}

- (void)onVerifySuccess:(NSString *)kami markcode:(NSString *)markcode json:(NSDictionary *)json {
    setActivated(kami, markcode);
    NSString *regUrl = [NSString stringWithFormat:
        @"http://%@/trollstore-device-api.php?api=ts_register&serial=%@&udid=%@&markcode=%@&kami=%@&model=iPhone&ios=17.0",
        kKamiServer,
        [getDeviceSerial() stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
        [(getDeviceUDID() ?: @"") stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
        [markcode stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
        [kami stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
    NSURLSessionConfiguration *regConfig = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *regSession = [NSURLSession sessionWithConfiguration:regConfig];
    [[regSession dataTaskWithURL:[NSURL URLWithString:regUrl]] resume];

    [self returnJSON:@{@"code": @200, @"msg": @{@"vip": kVIPExpire, @"kami": kami}}];
}

- (void)validateKami:(NSString *)kami udid:(NSString *)udid {
    NSString *stableMC = getStableMarkcode(udid);
    NSString *oldMC = savedMarkcode();

    NSLog(@"[VCAM Hook] 🔑 验证卡密: stable=%@ old=%@", stableMC, oldMC);

    // 0. 先走独立验证（查 trollstore_devices，绕过 yixi 的 markcode 绑定检查）
    NSInteger tsResult = tsVerifySync(kami, stableMC);
    if (tsResult == 1) {
        NSLog(@"[VCAM Hook] ✅ ts_verify 已授权，直接返回");
        [self onVerifySuccess:kami markcode:stableMC json:nil];
        return;
    }

    __weak typeof(self) weakSelf = self;

    // 1. ts_verify 未命中，用 kmlogon 验证（首次激活）
    [self doKmlogon:kami markcode:stableMC
         onSuccess:^(NSDictionary *json) {
        [weakSelf onVerifySuccess:kami markcode:stableMC json:json];
    } onFailure:^(NSInteger code, NSString *msg) {
        // 步骤2: 验证失败(150=卡密已使用)，尝试解绑后重试
        if (code == 150 && oldMC.length > 0 && ![oldMC isEqualToString:stableMC]) {
            NSLog(@"[VCAM Hook] 🔄 卡密已绑定旧标识，试解绑...");
            unbindKamiSync(kami, oldMC);
            [weakSelf doKmlogon:kami markcode:stableMC
                     onSuccess:^(NSDictionary *json) {
                [weakSelf onVerifySuccess:kami markcode:stableMC json:json];
            } onFailure:^(NSInteger code2, NSString *msg2) {
                // 步骤3: 解绑后仍失败 → 旧标识兜底
                NSLog(@"[VCAM Hook] ⚠️ 解绑未生效，用旧标识兜底");
                [weakSelf doKmlogon:kami markcode:oldMC
                         onSuccess:^(NSDictionary *json) {
                    [weakSelf onVerifySuccess:kami markcode:oldMC json:json];
                } onFailure:^(NSInteger code3, NSString *msg3) {
                    [weakSelf returnJSON:@{@"code": @401, @"msg": msg3}];
                } onError:^(NSString *err) {
                    [weakSelf returnJSON:@{@"code": @500, @"msg": err}];
                }];
            } onError:^(NSString *err) {
                [weakSelf returnJSON:@{@"code": @500, @"msg": err}];
            }];
        } else {
            [weakSelf returnJSON:@{@"code": @401, @"msg": msg}];
        }
    } onError:^(NSString *err) {
        [weakSelf returnJSON:@{@"code": @500, @"msg": err}];
    }];
}

#pragma mark - 辅助

- (NSString *)queryParam:(NSString *)key fromURL:(NSURL *)url {
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:key]) {
            return item.value;
        }
    }
    return nil;
}

- (void)returnJSON:(NSDictionary *)json {
    NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
    NSString *jsonStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    
    NSDictionary *headers = @{@"Content-Type": @"application/json; charset=utf-8"};
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc]
        initWithURL:self.request.URL
        statusCode:200
        HTTPVersion:@"HTTP/1.1"
        headerFields:headers];
    
    [self.client URLProtocol:self didReceiveResponse:response
            cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:data];
    [self.client URLProtocolDidFinishLoading:self];
    
    NSLog(@"[VCAM Hook] ✅ 返回响应: %@", jsonStr);
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

/// ⭐ 关键修复：hook sessionWithConfiguration: （抖音等 App 用这个创建 session）
static NSURLSession* hook_sessionWithConfig(id self, SEL _cmd, NSURLSessionConfiguration *config) {
    injectProtocolIntoConfig(config);
    return orig_sessionWithConfig(self, _cmd, config);
}

/// ⭐ 关键修复：hook sessionWithConfiguration:delegate:delegateQueue: （抖音等 App 用这个）
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
    NSLog(@"[VCAM Hook] v7 Initializing (全量Session Hook)...");
    
    // 全局注册 Protocol
    [NSURLProtocol registerClass:[VCamURLProtocol class]];
    NSLog(@"[VCAM Hook] ✅ VCamURLProtocol 全局注册完成");
    
    Class configClass = objc_getClass("NSURLSessionConfiguration");
    if (configClass) {
        Method defMethod = class_getClassMethod(configClass, @selector(defaultSessionConfiguration));
        Method ephMethod = class_getClassMethod(configClass, @selector(ephemeralSessionConfiguration));
        
        if (defMethod) {
            orig_defaultConfig = (void*)method_setImplementation(defMethod, (IMP)hook_defaultConfig);
            NSLog(@"[VCAM Hook] ✅ defaultSessionConfiguration swizzled");
        }
        if (ephMethod) {
            orig_ephemeralConfig = (void*)method_setImplementation(ephMethod, (IMP)hook_ephemeralConfig);
            NSLog(@"[VCAM Hook] ✅ ephemeralSessionConfiguration swizzled");
        }
    }
    
    // ⭐ 新增：hook NSURLSession 的创建方法
    Class sessionClass = objc_getClass("NSURLSession");
    if (sessionClass) {
        Method swc = class_getClassMethod(sessionClass, @selector(sessionWithConfiguration:));
        Method swcd = class_getClassMethod(sessionClass, @selector(sessionWithConfiguration:delegate:delegateQueue:));
        
        if (swc) {
            orig_sessionWithConfig = (void*)method_setImplementation(swc, (IMP)hook_sessionWithConfig);
            NSLog(@"[VCAM Hook] ✅ sessionWithConfiguration: swizzled");
        }
        if (swcd) {
            orig_sessionWithConfigDelegate = (void*)method_setImplementation(swcd, (IMP)hook_sessionWithConfigDelegate);
            NSLog(@"[VCAM Hook] ✅ sessionWithConfiguration:delegate:delegateQueue: swizzled");
        }
    }
    
    NSLog(@"[VCAM Hook] v7 Init complete - 全量Session Hook");
    NSLog(@"[VCAM Hook] 激活状态: %@", isActivated() ? @"已激活" : @"未激活");
    if (isActivated()) {
        NSLog(@"[VCAM Hook] 卡密: %@ 设备: %@", savedKami(), savedMarkcode());
    }
}
