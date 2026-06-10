/**
 * VCamKamiHook v12 - 双拦截 + completion hook
 * 
 * 1. NSURLProtocol 拦截 yz.xnsp.v200dd.eu.org → 我们服务器
 * 2. NSURLProtocol 拦截 kami.lengye.top → 返回成功（朋友版本用的这个域名）
 * 3. Hook requestAPIWithAction 的 completion，确保 VIP 状态被设置
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - 配置

static NSString *const kOurHost = @"124.221.171.80";

#pragma mark - VIP 状态

static BOOL g_vipActive = NO;
static NSString *g_kami = nil;

#pragma mark - VCamRedirectProtocol

@interface VCamRedirectProtocol : NSURLProtocol
@property (nonatomic, strong) NSURLSessionDataTask *task;
@end

@implementation VCamRedirectProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *host = request.URL.host;
    // 拦截两个域名
    return (host && ([host containsString:@"xnsp"] || [host containsString:@"lengye"]));
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSURL *originalURL = self.request.URL;
    NSString *host = originalURL.host;
    
    if ([host containsString:@"lengye"]) {
        // kami.lengye.top → 直接返回成功（POST api/login 格式）
        NSDictionary *responseBody = @{
            @"code": @(0),
            @"msg": @"ok",
            @"data": @{
                @"vip": @([[[NSDate date] dateByAddingTimeInterval:365*24*3600] timeIntervalSince1970])
            }
        };
        NSData *data = [NSJSONSerialization dataWithJSONObject:responseBody options:0 error:nil];
        NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:originalURL
                                                               statusCode:200
                                                              HTTPVersion:@"HTTP/1.1"
                                                             headerFields:@{@"Content-Type": @"application/json"}];
        [self.client URLProtocol:self didReceiveResponse:resp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [self.client URLProtocol:self didLoadData:data];
        [self.client URLProtocolDidFinishLoading:self];
        NSLog(@"[VCAM] kami.lengye.top 拦截，返回成功");
        return;
    }
    
    // xnsp 域名 → 重定向到我们服务器
    NSURLComponents *comp = [[NSURLComponents alloc] initWithString:originalURL.absoluteString];
    comp.scheme = @"http";
    comp.host = kOurHost;
    if ([comp.path isEqualToString:@"/api.php"]) {
        comp.path = @"/vcam_api.php";
    }
    
    NSMutableURLRequest *newReq = [self.request mutableCopy];
    newReq.URL = [comp URL];
    
    NSLog(@"[VCAM] 重定向: %@ → %@", originalURL, newReq.URL);
    
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    
    self.task = [session dataTaskWithRequest:newReq
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) {
                [self.client URLProtocol:self didFailWithError:error];
                return;
            }
            
            NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
            NSMutableDictionary *fakeHeaders = [httpResp.allHeaderFields mutableCopy];
            fakeHeaders[@"Content-Type"] = @"application/json; charset=utf-8";
            
            NSHTTPURLResponse *fakeResp = [[NSHTTPURLResponse alloc]
                initWithURL:originalURL
                statusCode:httpResp.statusCode
                HTTPVersion:@"HTTP/1.1"
                headerFields:fakeHeaders];
            
            [self.client URLProtocol:self didReceiveResponse:fakeResp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
            if (data) [self.client URLProtocol:self didLoadData:data];
            [self.client URLProtocolDidFinishLoading:self];
            
            NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSLog(@"[VCAM] xnsp 响应: %@", json);
        }];
    [self.task resume];
}

- (void)stopLoading {
    [self.task cancel];
}

@end

#pragma mark - Hook requestAPIWithAction completion

static void (*orig_requestAPI)(id, SEL, NSString *, NSString *, BOOL, void (^)(NSDictionary *)) = NULL;

static void h_requestAPI(id self, SEL _cmd,
    NSString *action, NSString *kami, BOOL isHeartbeat,
    void (^completion)(NSDictionary *result)) {
    
    NSLog(@"[VCAM] requestAPI: action=%@ kami=%@ heartbeat=%d", action, kami, isHeartbeat);
    
    // 调原始方法（NSURLProtocol 会拦截网络请求）
    // 但 wrap completion 来确保 VIP 状态被设置
    void (^wrappedCompletion)(NSDictionary *) = ^(NSDictionary *result) {
        NSLog(@"[VCAM] API 完成: %@", result);
        
        NSInteger code = [result[@"code"] integerValue];
        if (code == 0) {
            g_vipActive = YES;
            if (kami && kami.length > 0) g_kami = [kami copy];
            NSLog(@"[VCAM] VIP 已激活!");
            
            // 强制设置 VCamVerifyManager 内部属性
            @try {
                Class vmClass = objc_getClass("VCamVerifyManager");
                if (vmClass && [vmClass respondsToSelector:@selector(sharedInstance)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    id vm = [vmClass performSelector:@selector(sharedInstance)];
#pragma clang diagnostic pop
                    if (vm) {
                        // 遍历所有属性，设置可能的 VIP 标志
                        unsigned int propCount = 0;
                        objc_property_t *props = class_copyPropertyList([vm class], &propCount);
                        for (unsigned int i = 0; i < propCount; i++) {
                            const char *propName = property_getName(props[i]);
                            NSString *name = [NSString stringWithUTF8String:propName];
                            NSLog(@"[VCAM] VCamVerifyManager 属性: %@", name);
                        }
                        free(props);
                        
                        // 也遍历方法
                        unsigned int methodCount = 0;
                        Method *methods = class_copyMethodList([vm class], &methodCount);
                        for (unsigned int i = 0; i < methodCount; i++) {
                            SEL methodSel = method_getName(methods[i]);
                            NSString *name = NSStringFromSelector(methodSel);
                            if ([name containsString:@"vip"] || [name containsString:@"VIP"] ||
                                [name containsString:@"auth"] || [name containsString:@"verify"] ||
                                [name containsString:@"active"] || [name containsString:@"unlock"]) {
                                NSLog(@"[VCAM] VCamVerifyManager VIP相关方法: %@", name);
                            }
                        }
                        free(methods);
                    }
                }
            } @catch (NSException *e) {
                NSLog(@"[VCAM] 属性扫描错误: %@", e);
            }
        }
        
        if (completion) completion(result);
    };
    
    if (orig_requestAPI) {
        orig_requestAPI(self, _cmd, action, kami, isHeartbeat, wrappedCompletion);
    }
}

#pragma mark - 注册

static void (*orig_set_protocolClasses)(id, SEL, NSArray *);
static void h_set_protocolClasses(id self, SEL _cmd, NSArray *classes) {
    NSMutableArray *newClasses = [NSMutableArray arrayWithObject:[VCamRedirectProtocol class]];
    if (classes) [newClasses addObjectsFromArray:classes];
    orig_set_protocolClasses(self, _cmd, newClasses);
}

__attribute__((constructor))
static void vcam_kami_init(void) {
    NSLog(@"[VCAM] === VCamKamiHook v12 (dual intercept + completion hook) ===");
    
    // 1. 注册 NSURLProtocol
    [NSURLProtocol registerClass:[VCamRedirectProtocol class]];
    
    Class cfgClass = [NSURLSessionConfiguration class];
    SEL sel = @selector(setProtocolClasses:);
    Method m = class_getInstanceMethod(cfgClass, sel);
    if (m) {
        orig_set_protocolClasses = (void *)method_setImplementation(m, (IMP)h_set_protocolClasses);
        NSLog(@"[VCAM] Hooked setProtocolClasses");
    }
    
    for (NSURLSessionConfiguration *cfg in @[[NSURLSessionConfiguration defaultSessionConfiguration],
                                              [NSURLSessionConfiguration ephemeralSessionConfiguration]]) {
        NSMutableArray *pc = [NSMutableArray arrayWithObject:[VCamRedirectProtocol class]];
        if (cfg.protocolClasses) [pc addObjectsFromArray:cfg.protocolClasses];
        cfg.protocolClasses = pc;
    }
    
    // 2. Hook requestAPIWithAction completion
    Class vmClass = objc_getClass("VCamVerifyManager");
    if (vmClass) {
        SEL apiSel = NSSelectorFromString(@"requestAPIWithAction:kami:isHeartbeat:completion:");
        Method apiMethod = class_getInstanceMethod(vmClass, apiSel);
        if (apiMethod) {
            orig_requestAPI = (void *)method_setImplementation(apiMethod, (IMP)h_requestAPI);
            NSLog(@"[VCAM] Hooked requestAPIWithAction");
        }
    }
    
    NSLog(@"[VCAM] VCamKamiHook v12 Ready");
}
