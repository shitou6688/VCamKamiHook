/**
 * VCamKamiHook v14 - 模仿同行方案，URL 替换 + completion 修改
 * 
 * 参考 URLRedirectNoMSG(4).dylib 逆向：
 * 1. Hook NSURL URLWithString: 替换 URL
 * 2. Hook requestAPIWithAction:completion: 修改回调数据
 * 
 * 两个目标域名：
 * - yz.xnsp.v200dd.eu.org → 124.221.171.80/vcam_api.php
 * - sq.qiaohe.site → 124.221.171.80/vcam_api.php
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - URL 替换

static NSURL* (*orig_URLWithString)(id, SEL, NSString *);
static NSURL* (*orig_URLWithString_rel)(id, SEL, NSString *, NSURL *);

static NSURL* new_URLWithString(id self, SEL _cmd, NSString *string) {
    if (string && [string containsString:@"xnsp"]) {
        NSString *newStr = [string stringByReplacingOccurrencesOfString:@"https://yz.xnsp.v200dd.eu.org/api.php"
                                                            withString:@"http://124.221.171.80/vcam_api.php"];
        NSLog(@"[VCAM] URL替换: %@ → %@", string, newStr);
        return orig_URLWithString(self, _cmd, newStr);
    }
    if (string && [string containsString:@"qiaohe"]) {
        NSString *newStr = [string stringByReplacingOccurrencesOfString:@"https://sq.qiaohe.site"
                                                            withString:@"http://124.221.171.80"];
        NSLog(@"[VCAM] URL替换: %@ → %@", string, newStr);
        return orig_URLWithString(self, _cmd, newStr);
    }
    return orig_URLWithString(self, _cmd, string);
}

static NSURL* new_URLWithString_rel(id self, SEL _cmd, NSString *string, NSURL *baseURL) {
    if (string && [string containsString:@"xnsp"]) {
        NSString *newStr = [string stringByReplacingOccurrencesOfString:@"https://yz.xnsp.v200dd.eu.org/api.php"
                                                            withString:@"http://124.221.171.80/vcam_api.php"];
        NSLog(@"[VCAM] URL替换(rel): %@ → %@", string, newStr);
        return orig_URLWithString_rel(self, _cmd, newStr, baseURL);
    }
    if (string && [string containsString:@"qiaohe"]) {
        NSString *newStr = [string stringByReplacingOccurrencesOfString:@"https://sq.qiaohe.site"
                                                            withString:@"http://124.221.171.80"];
        NSLog(@"[VCAM] URL替换(rel): %@ → %@", string, newStr);
        return orig_URLWithString_rel(self, _cmd, newStr, baseURL);
    }
    return orig_URLWithString_rel(self, _cmd, string, baseURL);
}

#pragma mark - Hook requestAPIWithAction completion 修改返回数据

static void (*orig_reqAPI)(id, SEL, NSString *, NSString *, BOOL, void (^)(NSDictionary *));
static void h_reqAPI(id self, SEL _cmd,
    NSString *action, NSString *kami, BOOL isHeartbeat,
    void (^completion)(NSDictionary *)) {
    
    NSLog(@"[VCAM] reqAPI: action=%@ kami=%@ heartbeat=%d", action, kami, (int)isHeartbeat);
    
    void (^wrappedCompletion)(NSDictionary *) = ^(NSDictionary *result) {
        NSLog(@"[VCAM] reqAPI返回: %@", result);
        
        // 如果返回成功，确保 vip 状态正确
        if (result && [result[@"code"] integerValue] == 0) {
            NSMutableDictionary *mutResult = [result mutableCopy];
            NSMutableDictionary *mutData = [mutResult[@"data"] mutableCopy];
            if (!mutData) mutData = [NSMutableDictionary dictionary];
            
            // 确保有 status:active
            if (!mutData[@"status"] || ![mutData[@"status"] isEqualToString:@"active"]) {
                mutData[@"status"] = @"active";
            }
            // 确保 vip 有值
            if (!mutData[@"vip"] || [mutData[@"vip"] doubleValue] <= 0) {
                mutData[@"vip"] = @([[[NSDate date] dateByAddingTimeInterval:365*24*3600] timeIntervalSince1970]);
            }
            mutResult[@"data"] = mutData;
            
            NSLog(@"[VCAM] 修改后返回: %@", mutResult);
            if (completion) completion(mutResult);
            return;
        }
        
        if (completion) completion(result);
    };
    
    if (orig_reqAPI) {
        orig_reqAPI(self, _cmd, action, kami, isHeartbeat, wrappedCompletion);
    }
}

#pragma mark - 初始化

static void installHooks(void) {
    NSLog(@"[VCAM] === VCamKamiHook v14 (URL替换+completion修改) ===");
    
    // 1. Hook NSURL URLWithString:
    Class nsurlClass = [NSURL class];
    
    // 获取 meta class (因为 URLWithString: 是类方法)
    Class metaClass = objc_getMetaClass("NSURL");
    
    Method urlMethod = class_getClassMethod(nsurlClass, @selector(URLWithString:));
    if (urlMethod) {
        orig_URLWithString = (void *)method_setImplementation(urlMethod, (IMP)new_URLWithString);
        NSLog(@"[VCAM] Hooked NSURL URLWithString:");
    }
    
    Method urlRelMethod = class_getClassMethod(nsurlClass, @selector(URLWithString:relativeToURL:));
    if (urlRelMethod) {
        orig_URLWithString_rel = (void *)method_setImplementation(urlRelMethod, (IMP)new_URLWithString_rel);
        NSLog(@"[VCAM] Hooked NSURL URLWithString:relativeToURL:");
    }
    
    // 2. Hook VCamVerifyManager requestAPIWithAction:kami:isHeartbeat:completion:
    Class vmClass = objc_getClass("VCamVerifyManager");
    if (vmClass) {
        SEL apiSel = NSSelectorFromString(@"requestAPIWithAction:kami:isHeartbeat:completion:");
        Method apiMethod = class_getInstanceMethod(vmClass, apiSel);
        if (apiMethod) {
            orig_reqAPI = (void *)method_setImplementation(apiMethod, (IMP)h_reqAPI);
            NSLog(@"[VCAM] Hooked requestAPIWithAction");
        } else {
            NSLog(@"[VCAM] WARNING: requestAPIWithAction 方法未找到");
        }
    } else {
        NSLog(@"[VCAM] WARNING: VCamVerifyManager 类未找到");
    }
    
    NSLog(@"[VCAM] VCamKamiHook v14 Ready");
}

__attribute__((constructor))
static void vcam_kami_init(void) {
    installHooks();
}
