/**
 * VCamKamiHook v8 - NSURLSession 拦截版
 * 
 * 策略：不替换任何 App 方法，只拦截网络请求
 * 把 kami.lengye.top/api/login 的 POST 请求重定向到自有服务器
 * App 原生验证流程完全不变，只是换了服务器
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - 配置

static NSString *const kAPIBase = @"http://124.221.171.80";
static NSString *const kAppID   = @"10003";

#pragma mark - 原方法指针

static NSURLSessionDataTask *(*orig_dataTaskWithRequest)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *)) = NULL;

#pragma mark - 拦截标志（防止递归）

static BOOL g_isOurRequest = NO;

#pragma mark - 设备标识

static NSString *getDeviceID(void) {
    return [[UIDevice currentDevice].identifierForVendor UUIDString] ?: @"unknown";
}

#pragma mark - Hook: dataTaskWithRequest:completionHandler:

static NSURLSessionDataTask *h_dataTaskWithRequest(id self, SEL _cmd,
    NSURLRequest *request,
    void (^completion)(NSData *data, NSURLResponse *response, NSError *error)) {

    NSURL *url = request.URL;
    NSString *host = url.host;

    // 只拦截 kami.lengye.top 的请求
    if (host && [host containsString:@"lengye.top"] && !g_isOurRequest) {
        NSLog(@"[VCAM] 拦截请求: %@", url);

        // 提取 POST body 中的 kami
        NSString *kami = nil;
        NSData *bodyData = request.HTTPBody;
        if (bodyData) {
            NSDictionary *body = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil];
            if (body) {
                NSLog(@"[VCAM] POST body: %@", body);
                kami = body[@"kami"] ?: body[@"code"] ?: body[@"kamiCode"] ?: body[@"license"];
            }
        }

        if (!kami) {
            // 从 URL query 提取
            NSString *query = url.query;
            if (query) {
                NSURLComponents *comp = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
                for (NSURLQueryItem *item in comp.queryItems) {
                    if ([item.name containsString:@"kami"] || [item.name containsString:@"code"]) {
                        kami = item.value;
                    }
                }
            }
        }

        NSString *finalKami = kami ?: @"";
        NSString *deviceID = getDeviceID();

        // 构造 GET 请求到自有服务器
        NSString *verifyURL = [NSString stringWithFormat:
            @"%@/api.php?api=kmlogon&app=%@&kami=%@&markcode=%@",
            kAPIBase, kAppID,
            [finalKami stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
            [deviceID stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];

        NSMutableURLRequest *ourReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:verifyURL]
                                                               cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                           timeoutInterval:15];
        [ourReq setHTTPMethod:@"GET"];

        // 用同一个 session 发我们的请求
        g_isOurRequest = YES;

        void (^ourCompletion)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *resp, NSError *err) {
            g_isOurRequest = NO;

            if (err || !data) {
                NSLog(@"[VCAM] 自有服务器错误: %@", err);
                // 返回失败给 App
                if (completion) {
                    NSDictionary *failBody = @{@"code": @(-1), @"msg": @"网络连接失败"};
                    NSData *failData = [NSJSONSerialization dataWithJSONObject:failBody options:0 error:nil];
                    NSHTTPURLResponse *failResp = [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                                                                statusCode:200
                                                                               HTTPVersion:@"HTTP/1.1"
                                                                              headerFields:@{@"Content-Type": @"application/json"}];
                    completion(failData, failResp, nil);
                }
                return;
            }

            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSLog(@"[VCAM] 自有服务器响应: %@", json);

            NSInteger code = [json[@"code"] integerValue];

            if (code == 200) {
                // 验证成功，构造 App 期望的响应格式
                // 原始 API 成功格式: {"code": 0, "msg": "ok", "data": {"vip": <timestamp>}}
                long long vipTs = 0;
                id msgObj = json[@"msg"];
                if ([msgObj isKindOfClass:[NSDictionary class]]) {
                    id vipVal = msgObj[@"vip"];
                    if ([vipVal respondsToSelector:@selector(longLongValue)]) {
                        vipTs = [vipVal longLongValue];
                    }
                }
                if (vipTs == 0) {
                    vipTs = (long long)[[[NSDate date] dateByAddingTimeInterval:365*24*3600] timeIntervalSince1970];
                }

                NSDictionary *responseBody = @{
                    @"code": @(0),
                    @"msg": @"ok",
                    @"data": @{@"vip": @(vipTs)}
                };

                NSData *responseData = [NSJSONSerialization dataWithJSONObject:responseBody options:0 error:nil];

                // 构造 HTTPURLResponse 假装来自 kami.lengye.top
                NSHTTPURLResponse *fakeResp = [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                                                             statusCode:200
                                                                            HTTPVersion:@"HTTP/1.1"
                                                                           headerFields:@{@"Content-Type": @"application/json"}];

                NSLog(@"[VCAM] 返回成功响应给 App: %@", responseBody);
                if (completion) completion(responseData, fakeResp, nil);
            } else {
                // 验证失败
                NSDictionary *responseBody = @{
                    @"code": @(-1),
                    @"msg": json[@"msg"] ?: @"卡密无效"
                };
                NSData *responseData = [NSJSONSerialization dataWithJSONObject:responseBody options:0 error:nil];
                NSHTTPURLResponse *fakeResp = [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                                                             statusCode:200
                                                                            HTTPVersion:@"HTTP/1.1"
                                                                           headerFields:@{@"Content-Type": @"application/json"}];
                if (completion) completion(responseData, fakeResp, nil);
            }
        };

        // 发请求
        NSURLSessionDataTask *task = [self dataTaskWithRequest:ourReq completionHandler:ourCompletion];
        [task resume];

        // 返回一个空的 task 给原始调用者（我们已经用 ourCompletion 处理了）
        // 创建一个 dummy task
        NSURLSessionDataTask *dummyTask = [self dataTaskWithRequest:request completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            // 什么都不做，真正的回调已经由 ourCompletion 处理
        }];
        return dummyTask;
    }

    // 非 lengye.top 请求，正常处理
    return orig_dataTaskWithRequest(self, _cmd, request, completion);
}

#pragma mark - 初始化

__attribute__((constructor))
static void vcam_kami_init(void) {
    NSLog(@"[VCAM] === VCamKamiHook v8 (NSURLSession intercept) ===");

    // Hook NSURLSession dataTaskWithRequest:completionHandler:
    Class sessionClass = [NSURLSession class];
    SEL sel = @selector(dataTaskWithRequest:completionHandler:);
    Method m = class_getInstanceMethod(sessionClass, sel);
    if (m) {
        orig_dataTaskWithRequest = (void *)method_setImplementation(m, (IMP)h_dataTaskWithRequest);
        NSLog(@"[VCAM] Hooked NSURLSession dataTaskWithRequest");
    } else {
        NSLog(@"[VCAM] FAILED to hook NSURLSession");
    }

    NSLog(@"[VCAM] VCamKamiHook v8 Ready");
}
