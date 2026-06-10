/**
 * VCamKamiHook v11.1 - NSURLProtocol URL 重定向（修复响应 URL）
 * 
 * 拦截 yz.xnsp.v200dd.eu.org → 124.221.171.80
 * 转发响应时构造原始 URL 的 HTTPURLResponse，App 不会发现 URL 变了
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
    // 改 URL 的 scheme 和 host，保留原始 path 和 query
    NSURLComponents *comp = [[NSURLComponents alloc] initWithString:self.request.URL.absoluteString];
    comp.scheme = @"http";
    comp.host = kOurHost;
    if ([comp.path isEqualToString:@"/api.php"]) {
        comp.path = @"/vcam_api.php";
    }
    
    NSMutableURLRequest *newReq = [self.request mutableCopy];
    newReq.URL = [comp URL];
    
    NSLog(@"[VCAM] 重定向: %@ → %@", self.request.URL, newReq.URL);
    
    // 用 ephemeral session 避免递归
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    
    // 保存原始 URL 用于构造假响应
    NSURL *originalURL = self.request.URL;
    
    self.task = [session dataTaskWithRequest:newReq
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) {
                [self.client URLProtocol:self didFailWithError:error];
                return;
            }
            
            // 构造假响应：用原始 URL，不是重定向后的 URL
            NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
            NSDictionary *respHeaders = httpResp.allHeaderFields;
            
            // 替换 headers 中的 URL 相关字段
            NSMutableDictionary *fakeHeaders = [respHeaders mutableCopy];
            [fakeHeaders removeObjectForKey:@"Location"];
            // 确保 Content-Type 是 JSON
            fakeHeaders[@"Content-Type"] = @"application/json; charset=utf-8";
            
            NSHTTPURLResponse *fakeResp = [[NSHTTPURLResponse alloc] 
                initWithURL:originalURL
                statusCode:httpResp.statusCode
                HTTPVersion:@"HTTP/1.1"
                headerFields:fakeHeaders];
            
            NSLog(@"[VCAM] 响应 URL 伪装: %@ (实际: %@)", originalURL, response.URL);
            
            [self.client URLProtocol:self didReceiveResponse:fakeResp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
            if (data) {
                [self.client URLProtocol:self didLoadData:data];
            }
            [self.client URLProtocolDidFinishLoading:self];
            
            // 打印响应体用于调试
            if (data) {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSLog(@"[VCAM] 响应内容: %@", json);
            }
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
    NSLog(@"[VCAM] === VCamKamiHook v11.1 (fix response URL) ===");
    
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
    
    NSLog(@"[VCAM] VCamKamiHook v11.1 Ready");
}
