/**
 * vcam_kami_hook.m v4
 *
 * 核心策略：用 NSURLProtocol 拦截 VCAM 的 API 请求
 * 直接返回 VCAM 期望的 JSON 响应格式
 * 让原始验证流程自然走通
 *
 * 已知协议（从网络抓包获取）：
 *   服务器: https://yz.xnsp.v200dd.eu.org/api.php
 *   action=check: 设备检查 → 期望 {"code":200,"msg":{"vip":"4102243200"}}
 *   action=use_kami: 卡密验证 → 期望 {"code":200,"msg":{"vip":"4102243200","kami":"xxx"}}
 *   参数: udid, ts, sign(sha256), kami
 *   响应: JSON with "code" and "msg" fields
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ============ 配置 ============

static NSString *const kKamiServer    = @"124.221.171.80";
static NSString *const kKamiAppID     = @"10003";
static NSString *const kVIPExpire     = @"4102243200"; // ~2100年

// ============ VCamURLProtocol ============

@interface VCamURLProtocol : NSURLProtocol
@end

@implementation VCamURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *host = request.URL.host;
    // 匹配 VCAM 的验证服务器域名
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
        // 设备检查 → 直接返回已授权
        NSLog(@"[VCAM Hook] 📋 action=check → 返回已授权");
        [self returnJSON:@{
            @"code": @200,
            @"msg": @{@"vip": kVIPExpire}
        }];
        
    } else if ([urlStr containsString:@"action=use_kami"]) {
        // 卡密验证 → 先去我们的服务器验证卡密
        NSString *kami = [self queryParam:@"kami" fromURL:self.request.URL];
        NSString *udid = [self queryParam:@"udid" fromURL:self.request.URL];
        
        NSLog(@"[VCAM Hook] 🔑 action=use_kami: kami=%@ udid=%@", kami, udid);
        
        if (kami.length > 0) {
            [self validateKami:kami udid:udid ?: @""];
        } else {
            [self returnJSON:@{@"code": @400, @"msg": @"卡密不能为空"}];
        }
        
    } else {
        // 其他请求也返回成功
        NSLog(@"[VCAM Hook] 📋 未知action → 返回已授权");
        [self returnJSON:@{
            @"code": @200,
            @"msg": @{@"vip": kVIPExpire}
        }];
    }
}

- (void)stopLoading {
    // Nothing
}

#pragma mark - 辅助方法

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

- (void)validateKami:(NSString *)kami udid:(NSString *)udid {
    // 构建我们服务器的验证URL
    NSString *encodedKami = [kami stringByAddingPercentEncodingWithAllowedCharacters:
                             [NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *encodedUdid = [udid stringByAddingPercentEncodingWithAllowedCharacters:
                             [NSCharacterSet URLQueryAllowedCharacterSet]];
    
    NSString *urlStr = [NSString stringWithFormat:
        @"http://%@/api.php?api=kmlogon&app=%@&kami=%@&markcode=%@",
        kKamiServer, kKamiAppID, encodedKami, encodedUdid];
    
    NSLog(@"[VCAM Hook] 🌐 验证卡密: %@", urlStr);
    
    // 用独立 session 避免递归（不触发我们的 protocol）
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:urlStr]
                                             cachePolicy:NSURLRequestReloadIgnoringCacheData
                                         timeoutInterval:15.0];
    
    [[[session dataTaskWithRequest:request
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
                // 卡密有效 → 注册设备
                NSString *regUrl = [NSString stringWithFormat:
                    @"http://%@/trollstore-device-api.php?api=ts_register&markcode=%@&kami=%@&model=iPhone&ios=17.0",
                    kKamiServer, encodedUdid, encodedKami];
                [[[NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]]
                  dataTaskWithURL:[NSURL URLWithString:regUrl]] resume];
                
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
    }] resume];
}

@end

// ============ NSURLSessionConfiguration Hook ============
// 注入我们的 Protocol 到所有 Session Configuration

static NSURLSessionConfiguration* (*orig_defaultConfig)(id, SEL);
static NSURLSessionConfiguration* (*orig_ephemeralConfig)(id, SEL);

static void injectProtocol(NSURLSessionConfiguration *config) {
    if (!config) return;
    NSMutableArray *protocols = [config.protocolClasses mutableCopy] ?: [NSMutableArray array];
    
    // 避免重复添加
    for (Class cls in protocols) {
        if ([cls isKindOfClass:[VCamURLProtocol class]] || cls == [VCamURLProtocol class]) {
            return;
        }
    }
    
    [protocols insertObject:[VCamURLProtocol class] atIndex:0];
    config.protocolClasses = protocols;
    NSLog(@"[VCAM Hook] 💉 注入 Protocol 到 SessionConfiguration");
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
    NSLog(@"[VCAM Hook] v4 Initializing (NSURLProtocol 拦截模式)...");
    
    // 1. 全局注册 Protocol（对 sharedSession 和 NSURLConnection 有效）
    [NSURLProtocol registerClass:[VCamURLProtocol class]];
    NSLog(@"[VCAM Hook] ✅ VCamURLProtocol 全局注册完成");
    
    // 2. Hook NSURLSessionConfiguration（对自定义 Session 有效）
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
    
    // 3. 延迟注入已有的 SessionConfiguration 实例
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            NSLog(@"[VCAM Hook] 🔄 延迟检查...");
            
            // 打印 VCamVerifyManager 信息
            Class vcamClass = objc_getClass("VCamVerifyManager");
            if (vcamClass) {
                NSLog(@"[VCAM Hook] ✅ VCamVerifyManager 已加载");
                
                unsigned int methodCount = 0;
                Method *methods = class_copyMethodList(vcamClass, &methodCount);
                NSLog(@"[VCAM Hook] 📋 方法列表 (%u):", methodCount);
                for (unsigned int i = 0; i < methodCount; i++) {
                    SEL sel = method_getName(methods[i]);
                    NSLog(@"[VCAM Hook]   - %s", sel_getName(sel));
                }
                if (methods) free(methods);
            }
        });
    
    NSLog(@"[VCAM Hook] v4 Init complete - NSURLProtocol 拦截已激活");
    NSLog(@"[VCAM Hook] 拦截域名: *xnsp*, *v200dd*, *lengye*");
    NSLog(@"[VCAM Hook] action=check → 自动授权");
    NSLog(@"[VCAM Hook] action=use_kami → 验证卡密(服务器: %@)", kKamiServer);
}
