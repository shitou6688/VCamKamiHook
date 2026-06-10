/**
 * VCamKamiHook v9 - 正确拦截 yz.xnsp.v200dd.eu.org
 * 
 * 真实 API 格式（从抓包得知）：
 * GET https://yz.xnsp.v200dd.eu.org/api.php?action=check&udid=XXX&ts=XXX&sign=XXX
 * GET https://yz.xnsp.v200dd.eu.org/api.php?action=use_kami&udid=XXX&ts=XXX&sign=XXX&kami=XXX
 * 
 * 策略：
 * 1. 拦截该域名的所有请求
 * 2. action=check → 直接返回验证通过
 * 3. action=use_kami → 转发到自有服务器验证卡密，返回 App 期望的格式
 * 4. 不 hook 任何 App 方法，App 原生流程不变
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CommonCrypto/CommonHMAC.h>

#pragma mark - 配置

static NSString *const kAPIBase = @"http://124.221.171.80";
static NSString *const kAppID   = @"10003";
static NSString *const kTargetHost = @"yz.xnsp.v200dd.eu.org";

#pragma mark - 原方法指针

static NSURLSessionDataTask *(*orig_dataTaskWithRequest)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *)) = NULL;

#pragma mark - 拦截标志

static BOOL g_isOurRequest = NO;

#pragma mark - 设备标识

static NSString *getDeviceID(void) {
    return [[UIDevice currentDevice].identifierForVendor UUIDString] ?: @"unknown";
}

#pragma mark - 构造 HTTPURLResponse

static NSHTTPURLResponse *makeResponse(NSURL *url, NSInteger statusCode, NSDictionary *headers) {
    return [[NSHTTPURLResponse alloc] initWithURL:url
                                       statusCode:statusCode
                                      HTTPVersion:@"HTTP/1.1"
                                     headerFields:headers ?: @{@"Content-Type": @"application/json"}];
}

#pragma mark - Hook: dataTaskWithRequest:completionHandler:

static NSURLSessionDataTask *h_dataTaskWithRequest(id self, SEL _cmd,
    NSURLRequest *request,
    void (^completion)(NSData *data, NSURLResponse *response, NSError *error)) {

    NSURL *url = request.URL;
    NSString *host = url.host;

    // 只拦截目标域名
    if (host && [host containsString:@"xnsp"] && !g_isOurRequest) {
        NSLog(@"[VCAM] 拦截请求: %@", url);
        
        NSString *query = url.query ?: @"";
        NSURLComponents *comp = [NSURLComponents componentsWithString:url.absoluteString];
        NSMutableDictionary *params = [NSMutableDictionary dictionary];
        for (NSURLQueryItem *item in comp.queryItems) {
            params[item.name] = item.value;
        }
        
        NSString *action = params[@"action"];
        NSString *udid = params[@"udid"];
        NSString *kami = params[@"kami"];
        
        NSLog(@"[VCAM] action=%@ udid=%@ kami=%@", action, udid, kami);
        
        if ([action isEqualToString:@"check"]) {
            // check 请求：直接返回验证通过
            NSDictionary *responseBody = @{
                @"code": @(0),
                @"msg": @"ok",
                @"data": @{
                    @"vip": @([[[NSDate date] dateByAddingTimeInterval:365*24*3600] timeIntervalSince1970]),
                    @"status": @"active"
                }
            };
            NSData *responseData = [NSJSONSerialization dataWithJSONObject:responseBody options:0 error:nil];
            NSHTTPURLResponse *resp = makeResponse(url, 200, nil);
            if (completion) completion(responseData, resp, nil);
            
            // 返回 dummy task
            return [self dataTaskWithRequest:request completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {}];
        }
        
        if ([action isEqualToString:@"use_kami"]) {
            // use_kami 请求：转发到自有服务器验证
            NSString *deviceID = getDeviceID();
            NSString *verifyURL = [NSString stringWithFormat:
                @"%@/api.php?api=kmlogon&app=%@&kami=%@&markcode=%@",
                kAPIBase, kAppID,
                [kami stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
                [deviceID stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
            
            NSMutableURLRequest *ourReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:verifyURL]
                                                                   cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                               timeoutInterval:15];
            [ourReq setHTTPMethod:@"GET"];
            
            g_isOurRequest = YES;
            
            NSURLSessionDataTask *ourTask = orig_dataTaskWithRequest(self, _cmd, ourReq,
                ^(NSData *data, NSURLResponse *resp, NSError *err) {
                    g_isOurRequest = NO;
                    
                    if (err || !data) {
                        NSLog(@"[VCAM] 自有服务器错误: %@", err);
                        NSDictionary *failBody = @{@"code": @(-1), @"msg": @"网络连接失败"};
                        NSData *failData = [NSJSONSerialization dataWithJSONObject:failBody options:0 error:nil];
                        if (completion) completion(failData, makeResponse(url, 200, nil), nil);
                        return;
                    }
                    
                    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    NSLog(@"[VCAM] 自有服务器响应: %@", json);
                    
                    NSInteger code = [json[@"code"] integerValue];
                    
                    if (code == 200) {
                        // 验证成功，构造 App 期望的响应
                        // 先用 check 格式再请求一次确认，直接返回成功
                        NSDictionary *responseBody = @{
                            @"code": @(0),
                            @"msg": @"ok",
                            @"data": @{
                                @"vip": @([[[NSDate date] dateByAddingTimeInterval:365*24*3600] timeIntervalSince1970]),
                                @"status": @"active"
                            }
                        };
                        NSData *responseData = [NSJSONSerialization dataWithJSONObject:responseBody options:0 error:nil];
                        NSLog(@"[VCAM] 返回成功: %@", responseBody);
                        if (completion) completion(responseData, makeResponse(url, 200, nil), nil);
                    } else {
                        NSDictionary *responseBody = @{
                            @"code": @(-1),
                            @"msg": json[@"msg"] ?: @"卡密无效"
                        };
                        NSData *responseData = [NSJSONSerialization dataWithJSONObject:responseBody options:0 error:nil];
                        if (completion) completion(responseData, makeResponse(url, 200, nil), nil);
                    }
                });
            [ourTask resume];
            
            // 返回 dummy task
            return [self dataTaskWithRequest:request completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {}];
        }
        
        // 其他 action，也拦截返回成功
        NSDictionary *responseBody = @{@"code": @(0), @"msg": @"ok"};
        NSData *responseData = [NSJSONSerialization dataWithJSONObject:responseBody options:0 error:nil];
        if (completion) completion(responseData, makeResponse(url, 200, nil), nil);
        return [self dataTaskWithRequest:request completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {}];
    }
    
    // 非目标域名，正常处理
    return orig_dataTaskWithRequest(self, _cmd, request, completion);
}

#pragma mark - 初始化

__attribute__((constructor))
static void vcam_kami_init(void) {
    NSLog(@"[VCAM] === VCamKamiHook v9 (xnsp intercept) ===");
    
    // Hook NSURLSession dataTaskWithRequest:completionHandler:
    // 注意：NSURLSession 是类簇，需要 hook 具体子类
    // 先尝试 hook __NSCFURLSession
    Class sessionClass = objc_getClass("__NSCFURLSession");
    if (!sessionClass) {
        sessionClass = [NSURLSession class];
    }
    
    SEL sel = @selector(dataTaskWithRequest:completionHandler:);
    Method m = class_getInstanceMethod(sessionClass, sel);
    if (m) {
        orig_dataTaskWithRequest = (void *)method_setImplementation(m, (IMP)h_dataTaskWithRequest);
        NSLog(@"[VCAM] Hooked %@ dataTaskWithRequest", NSStringFromClass(sessionClass));
    } else {
        NSLog(@"[VCAM] FAILED to hook, trying all classes...");
        // 遍历所有 NSURLSession 子类
        int numClasses = 0;
        Class *classes = NULL;
        numClasses = objc_getClassList(NULL, 0);
        if (numClasses > 0) {
            classes = (Class *)malloc(sizeof(Class) * numClasses);
            objc_getClassList(classes, numClasses);
            for (int i = 0; i < numClasses; i++) {
                Class cls = classes[i];
                if (class_getInstanceMethod(cls, sel) && class_isSubclass(cls, [NSURLSession class])) {
                    Method cm = class_getInstanceMethod(cls, sel);
                    orig_dataTaskWithRequest = (void *)method_setImplementation(cm, (IMP)h_dataTaskWithRequest);
                    NSLog(@"[VCAM] Hooked subclass: %@", NSStringFromClass(cls));
                }
            }
            free(classes);
        }
    }
    
    NSLog(@"[VCAM] VCamKamiHook v9 Ready");
}

// 辅助：检查类继承关系
static BOOL class_isSubclass(Class cls, Class parent) {
    Class c = cls;
    while (c) {
        if (c == parent) return YES;
        c = class_getSuperclass(c);
    }
    return NO;
}
