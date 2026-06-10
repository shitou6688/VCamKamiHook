/**
 * VCamKamiHook v17.3 - 替换请求到我们服务器
 * 不调原始方法，自己发请求，返回结果给 completion
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static void (*orig_requestAPI)(id, SEL, NSString *, NSString *, BOOL, void (^)(NSDictionary *));

static void h_requestAPI(id self, SEL _cmd,
    NSString *action, NSString *kami, BOOL isHeartbeat,
    void (^completion)(NSDictionary *)) {
    
    NSLog(@"[VCAM] reqAPI: action=%@ kami=%@ heartbeat=%d", action, kami, (int)isHeartbeat);
    
    // 获取设备 ID
    NSString *udid = @"unknown";
    @try {
        SEL sel = NSSelectorFromString(@"getDeviceID");
        if ([self respondsToSelector:sel]) {
            id ret = ((id(*)(id, SEL))objc_msgSend)(self, sel);
            if ([ret isKindOfClass:[NSString class]] && [(NSString *)ret length] > 0) {
                udid = (NSString *)ret;
            }
        }
    } @catch (NSException *e) {}
    
    if ([udid isEqualToString:@"unknown"]) {
        @try {
            udid = [[[UIDevice currentDevice] identifierForVendor] UUIDString] ?: @"unknown";
        } @catch (NSException *e) {}
    }
    
    // 构造请求到我们服务器
    NSString *urlStr = [NSString stringWithFormat:@"http://124.221.171.80/vcam_api.php?action=%@&udid=%@&ts=%lld&sign=0",
        action ?: @"check", udid, (long long)[[NSDate date] timeIntervalSince1970]];
    if (kami && kami.length > 0) {
        urlStr = [urlStr stringByAppendingFormat:@"&kami=%@", kami];
    }
    
    NSLog(@"[VCAM] 请求: %@", urlStr);
    
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:15.0];
    [request setHTTPMethod:@"GET"];
    [request setValue:@"TrollInstallerX/1.0" forHTTPHeaderField:@"User-Agent"];
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) {
                NSLog(@"[VCAM] 网络错误: %@", error.localizedDescription);
                if (completion) completion(@{@"code": @(-1), @"msg": @"网络错误"});
                return;
            }
            
            NSDictionary *json = nil;
            if (data) {
                json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            }
            
            NSLog(@"[VCAM] 返回: %@", json);
            
            if (!json) {
                if (completion) completion(@{@"code": @(-1), @"msg": @"格式错误"});
                return;
            }
            
            if (completion) completion(json);
        }];
    [task resume];
}

__attribute__((constructor))
static void vcam_kami_init(void) {
    NSLog(@"[VCAM] === v17.3 ===");
    
    Class vmClass = objc_getClass("VCamVerifyManager");
    if (vmClass) {
        SEL apiSel = NSSelectorFromString(@"requestAPIWithAction:kami:isHeartbeat:completion:");
        Method apiMethod = class_getInstanceMethod(vmClass, apiSel);
        if (apiMethod) {
            orig_requestAPI = (void *)method_setImplementation(apiMethod, (IMP)h_requestAPI);
            NSLog(@"[VCAM] Hooked OK");
        }
    }
    
    NSLog(@"[VCAM] Ready");
}
