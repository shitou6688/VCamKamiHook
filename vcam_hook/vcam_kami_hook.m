/**
 * vcam_kami_hook.m v5
 *
 * 卡密控制模式：
 * - action=check: 检查本地是否已激活，已激活返回授权，未激活返回未授权
 * - action=use_kami: 去 kami 服务器验证卡密，有效则记录激活并返回授权
 * - 心跳/定期重验: 已激活设备自动通过
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ============ 配置 ============

static NSString *const kKamiServer    = @"124.221.171.80";
static NSString *const kKamiAppID     = @"10003";
static NSString *const kVIPExpire     = @"4102243200";

/// 本地激活记录的 NSUserDefaults key
static NSString *const kKeyActivated  = @"vcam_kami_activated";
static NSString *const kKeyKamiValue  = @"vcam_kami_value";
static NSString *const kKeyMarkcode   = @"vcam_kami_markcode";

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
        // 其他请求：已激活则放行，否则拒绝
        if (isActivated()) {
            [self returnJSON:@{@"code": @200, @"msg": @{@"vip": kVIPExpire}}];
        } else {
            [self returnJSON:@{@"code": @401, @"msg": @"未授权"}];
        }
    }
}

- (void)stopLoading {}

#pragma mark - 处理 check 请求

- (void)handleCheck {
    if (isActivated()) {
        // 已激活 → 后台去服务器验证卡密是否还有效（不阻塞 UI）
        NSLog(@"[VCAM Hook] ✅ 设备已激活，返回授权");
        [self returnJSON:@{@"code": @200, @"msg": @{@"vip": kVIPExpire}}];
        
        // 后台静默验证卡密有效性
        NSString *kami = savedKami();
        NSString *markcode = savedMarkcode();
        if (kami.length > 0 && markcode.length > 0) {
            [self silentVerifyKami:kami markcode:markcode];
        }
    } else {
        // 未激活 → 返回未授权，触发卡密输入 UI
        NSLog(@"[VCAM Hook] ❌ 设备未激活，返回未授权");
        [self returnJSON:@{@"code": @401, @"msg": @"未授权"}];
    }
}

#pragma mark - 后台静默验证（检查卡密是否还有效）

- (void)silentVerifyKami:(NSString *)kami markcode:(NSString *)markcode {
    NSString *encodedKami = [kami stringByAddingPercentEncodingWithAllowedCharacters:
                             [NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *encodedMC = [markcode stringByAddingPercentEncodingWithAllowedCharacters:
                           [NSCharacterSet URLQueryAllowedCharacterSet]];
    
    NSString *urlStr = [NSString stringWithFormat:
        @"http://%@/api.php?api=kmlogon&app=%@&kami=%@&markcode=%@",
        kKamiServer, kKamiAppID, encodedKami, encodedMC];
    
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:urlStr]
                                             cachePolicy:NSURLRequestReloadIgnoringCacheData
                                         timeoutInterval:10.0];
    
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                           completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            NSLog(@"[VCAM Hook] ⚠️ 静默验证网络失败（不影响使用）: %@", error.localizedDescription);
            return;
        }
        @try {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSInteger code = [json[@"code"] integerValue];
            if (code != 200) {
                // 卡密已失效 → 清除本地激活记录
                NSLog(@"[VCAM Hook] 🚫 卡密已失效，清除激活记录");
                [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kKeyActivated];
                [[NSUserDefaults standardUserDefaults] synchronize];
            } else {
                NSLog(@"[VCAM Hook] ✅ 卡密静默验证通过");
            }
        } @catch (NSException *e) {
            NSLog(@"[VCAM Hook] ⚠️ 静默验证解析失败（不影响使用）");
        }
    }];
    [task resume];
}

#pragma mark - 卡密验证

- (void)validateKami:(NSString *)kami udid:(NSString *)udid {
    NSString *encodedKami = [kami stringByAddingPercentEncodingWithAllowedCharacters:
                             [NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *encodedUdid = [udid stringByAddingPercentEncodingWithAllowedCharacters:
                             [NSCharacterSet URLQueryAllowedCharacterSet]];
    
    NSString *urlStr = [NSString stringWithFormat:
        @"http://%@/api.php?api=kmlogon&app=%@&kami=%@&markcode=%@",
        kKamiServer, kKamiAppID, encodedKami, encodedUdid];
    
    NSLog(@"[VCAM Hook] 🌐 验证卡密: %@", urlStr);
    
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:urlStr]
                                             cachePolicy:NSURLRequestReloadIgnoringCacheData
                                         timeoutInterval:15.0];
    
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                           completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            NSLog(@"[VCAM Hook] ❌ 卡密验证网络错误: %@", error.localizedDescription);
            [self returnJSON:@{@"code": @500, @"msg": @"网络连接失败"}];
            return;
        }
        
        @try {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSInteger serverCode = [json[@"code"] integerValue];
            
            NSLog(@"[VCAM Hook] 📨 卡密服务器响应: code=%ld msg=%@", (long)serverCode, json[@"msg"]);
            
            if (serverCode == 200) {
                // 卡密有效 → 保存激活 + 注册设备
                setActivated(kami, udid);
                
                // 后台注册设备
                NSString *regUrl = [NSString stringWithFormat:
                    @"http://%@/trollstore-device-api.php?api=ts_register&markcode=%@&kami=%@&model=iPhone&ios=17.0",
                    kKamiServer, encodedUdid, encodedKami];
                
                NSURLSessionConfiguration *regConfig = [NSURLSessionConfiguration ephemeralSessionConfiguration];
                NSURLSession *regSession = [NSURLSession sessionWithConfiguration:regConfig];
                NSURLSessionDataTask *regTask = [regSession dataTaskWithURL:[NSURL URLWithString:regUrl]];
                [regTask resume];
                
                // 返回 VCAM 期望的格式
                [self returnJSON:@{
                    @"code": @200,
                    @"msg": @{@"vip": kVIPExpire, @"kami": kami}
                }];
            } else {
                // 卡密无效
                NSString *msg = json[@"msg"] ?: @"卡密无效或已过期";
                if (![msg isKindOfClass:[NSString class]]) {
                    msg = [msg description];
                }
                [self returnJSON:@{@"code": @401, @"msg": msg}];
            }
        } @catch (NSException *e) {
            NSLog(@"[VCAM Hook] ❌ 解析卡密响应失败: %@", e);
            [self returnJSON:@{@"code": @500, @"msg": @"服务器响应格式错误"}];
        }
    }];
    [task resume];
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

// ============ NSURLSessionConfiguration Hook ============

static NSURLSessionConfiguration* (*orig_defaultConfig)(id, SEL);
static NSURLSessionConfiguration* (*orig_ephemeralConfig)(id, SEL);

static void injectProtocol(NSURLSessionConfiguration *config) {
    if (!config) return;
    NSMutableArray *protocols = [config.protocolClasses mutableCopy] ?: [NSMutableArray array];
    for (Class cls in protocols) {
        if (cls == [VCamURLProtocol class]) return;
    }
    [protocols insertObject:[VCamURLProtocol class] atIndex:0];
    config.protocolClasses = protocols;
}

static NSURLSessionConfiguration* hook_defaultConfig(id self, SEL _cmd) {
    NSURLSessionConfiguration *config = orig_defaultConfig(self, _cmd);
    injectProtocol(config);
    return config;
}

static NSURLSessionConfiguration* hook_ephemeralConfig(id self, SEL _cmd) {
    NSURLSessionConfiguration *config = orig_ephemeralConfig(self, _cmd);
    injectProtocol(config);
    return config;
}

// ============ 构造函数 ============

__attribute__((constructor))
static void vcam_hook_init() {
    NSLog(@"[VCAM Hook] v5 Initializing (卡密控制模式)...");
    
    // 全局注册 Protocol
    [NSURLProtocol registerClass:[VCamURLProtocol class]];
    NSLog(@"[VCAM Hook] ✅ VCamURLProtocol 全局注册完成");
    
    // Hook NSURLSessionConfiguration
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
    
    NSLog(@"[VCAM Hook] v5 Init complete - 卡密控制模式");
    NSLog(@"[VCAM Hook] 激活状态: %@", isActivated() ? @"已激活" : @"未激活");
    if (isActivated()) {
        NSLog(@"[VCAM Hook] 卡密: %@ 设备: %@", savedKami(), savedMarkcode());
    }
}
