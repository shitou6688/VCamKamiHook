/**
 * VCamKamiHook v11 - 纯 URL 重定向版
 * 
 * 策略：用 NSURLProtocol 只改 URL 的 host，其余完全不变
 * 请求从 yz.xnsp.v200dd.eu.org → 124.221.171.80
 * App 原生代码完全正常处理请求和响应
 * 服务器端 vcam_api.php 兼容原始 API 格式
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kTargetHost = @"yz.xnsp.v200dd.eu.org";
static NSString *const kOurHost    = @"124.221.171.80";

@interface VCamRedirectProtocol : NSURLProtocol
@property (nonatomic, strong) NSURLSessionDataTask *task;
@end

@implementation VCamRedirectProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *host = request.URL.host;
    return (host && [host isEqualToString:kTargetHost]);
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    // 只改 host，保留原始 path、query、method、headers
    NSURLComponents *comp = [[NSURLComponents alloc] initWithString:self.request.URL.absoluteString];
    comp.scheme = @"http";  // 我们服务器是 HTTP
    comp.host = kOurHost;
    // 改路径到 vcam_api.php（服务器上的 api.php 是极简验证系统）
    if ([comp.path isEqualToString:@"/api.php"]) {
        comp.path = @"/vcam_api.php";
    }
    // path 保持 /api.php
    // query 保持 action=xxx&udid=xxx&ts=xxx&sign=xxx&kami=xxx
    
    NSMutableURLRequest *newReq = [self.request mutableCopy];
    newReq.URL = [comp URL];
    
    NSLog(@"[VCAM] 重定向: %@ → %@", self.request.URL, newReq.URL);
    
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.protocolClasses = @[];  // 不走自定义 protocol，防递归
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    
    self.task = [session dataTaskWithRequest:newReq
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) {
                [self.client URLProtocol:self didFailWithError:error];
                return;
            }
            [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
            if (data) {
                [self.client URLProtocol:self didLoadData:data];
            }
            [self.client URLProtocolDidFinishLoading:self];
            NSLog(@"[VCAM] 响应已转发: %lu bytes", (unsigned long)data.length);
        }];
    [self.task resume];
}

- (void)stopLoading {
    [self.task cancel];
}

@end

#pragma mark - 注册

static void (*orig_set_protocolClasses)(id, SEL, NSArray *);
static void h_set_protocolClasses(id self, SEL _cmd, NSArray *classes) {
    NSMutableArray *newClasses = [NSMutableArray arrayWithObject:[VCamRedirectProtocol class]];
    if (classes) [newClasses addObjectsFromArray:classes];
    orig_set_protocolClasses(self, _cmd, newClasses);
}

__attribute__((constructor))
static void vcam_kami_init(void) {
    NSLog(@"[VCAM] === VCamKamiHook v11 (URL redirect) ===");
    
    [NSURLProtocol registerClass:[VCamRedirectProtocol class]];
    
    Class cfgClass = [NSURLSessionConfiguration class];
    SEL sel = @selector(setProtocolClasses:);
    Method m = class_getInstanceMethod(cfgClass, sel);
    if (m) {
        orig_set_protocolClasses = (void *)method_setImplementation(m, (IMP)h_set_protocolClasses);
        NSLog(@"[VCAM] Hooked setProtocolClasses");
    }
    
    // 修改现有 configuration
    for (NSURLSessionConfiguration *cfg in @[[NSURLSessionConfiguration defaultSessionConfiguration],
                                              [NSURLSessionConfiguration ephemeralSessionConfiguration]]) {
        NSMutableArray *pc = [NSMutableArray arrayWithObject:[VCamRedirectProtocol class]];
        if (cfg.protocolClasses) [pc addObjectsFromArray:cfg.protocolClasses];
        cfg.protocolClasses = pc;
    }
    
    NSLog(@"[VCAM] VCamKamiHook v11 Ready");
}
