/**
 * VCamKamiHook v10 - NSURLProtocol 拦截版
 * 
 * 用 iOS 官方 NSURLProtocol 拦截 yz.xnsp.v200dd.eu.org 请求
 * 不 hook 任何 App 方法，不 hook NSURLSession
 * 
 * 真实 API 格式（抓包确认）：
 * GET https://yz.xnsp.v200dd.eu.org/api.php?action=check&udid=XXX&ts=XXX&sign=XXX
 * GET https://yz.xnsp.v200dd.eu.org/api.php?action=use_kami&udid=XXX&ts=XXX&sign=XXX&kami=XXX
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - 配置

static NSString *const kAPIBase = @"http://124.221.171.80";
static NSString *const kAppID   = @"10003";
static NSString *const kTargetHost = @"yz.xnsp.v200dd.eu.org";

#pragma mark - 设备标识

static NSString *getDeviceID(void) {
    return [[UIDevice currentDevice].identifierForVendor UUIDString] ?: @"unknown";
}

#pragma mark - VCamKamiURLProtocol

@interface VCamKamiURLProtocol : NSURLProtocol
@property (nonatomic, strong) NSURLSessionDataTask *underlyingTask;
@end

@implementation VCamKamiURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *host = request.URL.host;
    // 只拦截目标域名
    return (host && [host containsString:@"xnsp"]);
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSURL *url = self.request.URL;
    NSLog(@"[VCAM] 拦截请求: %@", url);
    
    NSURLComponents *comp = [NSURLComponents componentsWithString:url.absoluteString];
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in comp.queryItems) {
        params[item.name] = item.value;
    }
    
    NSString *action = params[@"action"];
    NSString *kami = params[@"kami"];
    
    if ([action isEqualToString:@"check"]) {
        // check 请求：直接返回成功
        [self sendSuccessResponse];
    } else if ([action isEqualToString:@"use_kami"]) {
        // use_kami 请求：转发到自有服务器
        [self forwardToOurServer:kami];
    } else {
        // 其他 action，也返回成功
        [self sendSuccessResponse];
    }
}

- (void)stopLoading {
    [self.underlyingTask cancel];
}

- (void)sendSuccessResponse {
    NSDictionary *responseBody = @{
        @"code": @(0),
        @"msg": @"ok",
        @"data": @{
            @"vip": @([[[NSDate date] dateByAddingTimeInterval:365*24*3600] timeIntervalSince1970]),
            @"status": @"active"
        }
    };
    [self sendJSONResponse:responseBody];
}

- (void)sendFailResponse:(NSString *)msg {
    NSDictionary *responseBody = @{
        @"code": @(-1),
        @"msg": msg ?: @"卡密无效"
    };
    [self sendJSONResponse:responseBody];
}

- (void)sendJSONResponse:(NSDictionary *)body {
    NSData *data = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                               statusCode:200
                                                              HTTPVersion:@"HTTP/1.1"
                                                             headerFields:@{@"Content-Type": @"application/json"}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:data];
    [self.client URLProtocolDidFinishLoading:self];
    NSLog(@"[VCAM] 返回: %@", body);
}

- (void)forwardToOurServer:(NSString *)kami {
    NSString *deviceID = getDeviceID();
    NSString *verifyURL = [NSString stringWithFormat:
        @"%@/api.php?api=kmlogon&app=%@&kami=%@&markcode=%@",
        kAPIBase, kAppID,
        [kami stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: @"",
        [deviceID stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
    
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:verifyURL]
                                                        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                    timeoutInterval:15];
    [req setHTTPMethod:@"GET"];
    
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    // 不让我们的请求也被拦截
    cfg.protocolClasses = @[];  // 空，不走自定义 protocol
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    
    self.underlyingTask = [session dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            if (err || !data) {
                NSLog(@"[VCAM] 自有服务器错误: %@", err);
                [self sendFailResponse:@"网络连接失败"];
                return;
            }
            
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSLog(@"[VCAM] 自有服务器响应: %@", json);
            
            NSInteger code = [json[@"code"] integerValue];
            if (code == 200) {
                [self sendSuccessResponse];
            } else {
                [self sendFailResponse:json[@"msg"]];
            }
        }];
    [self.underlyingTask resume];
}

@end

#pragma mark - 注册 NSURLProtocol 到所有 NSURLSessionConfiguration

static void (*orig_set_protocolClasses)(id, SEL, NSArray *);
static void h_set_protocolClasses(id self, SEL _cmd, NSArray *classes) {
    // 在已有 protocolClasses 前面插入我们的
    NSMutableArray *newClasses = [NSMutableArray arrayWithObject:[VCamKamiURLProtocol class]];
    if (classes) {
        [newClasses addObjectsFromArray:classes];
    }
    orig_set_protocolClasses(self, _cmd, newClasses);
}

static void registerProtocolToAllConfigurations(void) {
    // 1. 注册全局 protocol（对 NSURLConnection 和 default session 生效）
    [NSURLProtocol registerClass:[VCamKamiURLProtocol class]];
    
    // 2. Hook NSURLSessionConfiguration 的 protocolClasses setter
    // 这样所有新创建的 session 都会包含我们的 protocol
    Class cfgClass = [NSURLSessionConfiguration class];
    SEL sel = @selector(setProtocolClasses:);
    Method m = class_getInstanceMethod(cfgClass, sel);
    if (m) {
        orig_set_protocolClasses = (void *)method_setImplementation(m, (IMP)h_set_protocolClasses);
        NSLog(@"[VCAM] Hooked setProtocolClasses:");
    }
    
    // 3. 修改 defaultSessionConfiguration 和 ephemeralSessionConfiguration 的 protocolClasses
    NSURLSessionConfiguration *defaultCfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSMutableArray *defaultProtocols = [NSMutableArray arrayWithObject:[VCamKamiURLProtocol class]];
    if (defaultCfg.protocolClasses) {
        [defaultProtocols addObjectsFromArray:defaultCfg.protocolClasses];
    }
    defaultCfg.protocolClasses = defaultProtocols;
    
    NSURLSessionConfiguration *ephemeralCfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSMutableArray *ephemeralProtocols = [NSMutableArray arrayWithObject:[VCamKamiURLProtocol class]];
    if (ephemeralCfg.protocolClasses) {
        [ephemeralProtocols addObjectsFromArray:ephemeralCfg.protocolClasses];
    }
    ephemeralCfg.protocolClasses = ephemeralProtocols;
}

#pragma mark - 初始化

__attribute__((constructor))
static void vcam_kami_init(void) {
    NSLog(@"[VCAM] === VCamKamiHook v10 (NSURLProtocol) ===");
    
    registerProtocolToAllConfigurations();
    
    NSLog(@"[VCAM] VCamKamiHook v10 Ready");
}
