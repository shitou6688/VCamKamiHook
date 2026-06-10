/**
 * VCamKamiHook v20 - URL替换 + hook功能按钮的VIP检查
 * 
 * 1. URL替换让App正常走验证（保留sign）
 * 2. Hook VCamMenuVC的功能方法，绕过VIP检查
 * 3. 强制设置VIP状态
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
        NSString *newStr = [string stringByReplacingOccurrencesOfString:@"https://yz.xnsp.v200dd.eu.org"
                                                            withString:@"http://124.221.171.80"];
        newStr = [newStr stringByReplacingOccurrencesOfString:@"/api.php"
                                                  withString:@"/vcam_api.php"];
        NSLog(@"[VCAM] URL: %@ -> %@", string, newStr);
        return orig_URLWithString(self, _cmd, newStr);
    }
    if (string && [string containsString:@"qiaohe"]) {
        NSString *newStr = [string stringByReplacingOccurrencesOfString:@"https://sq.qiaohe.site"
                                                            withString:@"http://124.221.171.80"];
        NSLog(@"[VCAM] URL: %@ -> %@", string, newStr);
        return orig_URLWithString(self, _cmd, newStr);
    }
    return orig_URLWithString(self, _cmd, string);
}

static NSURL* new_URLWithString_rel(id self, SEL _cmd, NSString *string, NSURL *baseURL) {
    if (string && ([string containsString:@"xnsp"] || [string containsString:@"qiaohe"])) {
        return new_URLWithString(self, @selector(URLWithString:), string);
    }
    return orig_URLWithString_rel(self, _cmd, string, baseURL);
}

#pragma mark - Hook requestAPIWithAction completion，记录+强制设VIP

static void (*orig_reqAPI)(id, SEL, NSString *, NSString *, BOOL, void (^)(NSDictionary *));

static void h_reqAPI(id self, SEL _cmd,
    NSString *action, NSString *kami, BOOL isHeartbeat,
    void (^completion)(NSDictionary *)) {
    
    NSLog(@"[VCAM] reqAPI: action=%@ kami=%@ heartbeat=%d", action, kami, (int)isHeartbeat);
    
    // 调原始方法（URL已被替换），但 wrap completion
    void (^wrappedCompletion)(NSDictionary *) = ^(NSDictionary *result) {
        NSLog(@"[VCAM] reqAPI结果: %@", result);
        
        // 不管结果如何，强制设VIP
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"vcam_vip_unlocked"];
        if (kami && kami.length > 0) {
            [[NSUserDefaults standardUserDefaults] setObject:kami forKey:@"vcam_verified_kami"];
        }
        [[NSUserDefaults standardUserDefaults] synchronize];
        
        // 强制设置 VCamVerifyManager
        @try {
            Class vmClass = objc_getClass("VCamVerifyManager");
            if (vmClass) {
                id vm = [vmClass performSelector:@selector(sharedInstance)];
                if (vm) {
                    // 暴力设所有可能的 VIP 属性
                    for (NSString *k in @[@"isVIP", @"isVerified", @"isAuthorized", @"vipActivated",
                                          @"isVip", @"hasVIP", @"vipEnabled", @"isPremium",
                                          @"unlocked", @"_isVIP", @"_isVerified", @"_vipActive"]) {
                        @try { [vm setValue:@YES forKey:k]; } @catch (NSException *e) {}
                    }
                    // 设 vip 过期时间
                    for (NSString *k in @[@"vip", @"vipExpiry", @"vipExpireTime", @"expiresAt"]) {
                        @try { [vm setValue:@([[[NSDate date] dateByAddingTimeInterval:365*24*3600] timeIntervalSince1970]) forKey:k]; } @catch (NSException *e) {}
                    }
                    // 设 kami
                    if (kami && kami.length > 0) {
                        for (NSString *k in @[@"kami", @"use_kami", @"activeKami", @"currentKami"]) {
                            @try { [vm setValue:kami forKey:k]; } @catch (NSException *e) {}
                        }
                    }
                }
            }
        } @catch (NSException *e) {}
        
        if (completion) completion(result);
    };
    
    if (orig_reqAPI) {
        orig_reqAPI(self, _cmd, action, kami, isHeartbeat, wrappedCompletion);
    }
}

#pragma mark - Hook 按钮 action 方法的 VIP 检查

// Hook 所有可能的声音/循环等功能的 action 方法
// 扫描 VCamMenuVC 的方法，找到 VIP 检查相关的

static void scanAndHookMenuVC(void) {
    Class mcClass = objc_getClass("VCamMenuVC");
    if (!mcClass) return;
    
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(mcClass, &methodCount);
    NSLog(@"[VCAM] VCamMenuVC has %d methods:", methodCount);
    for (unsigned int i = 0; i < methodCount; i++) {
        SEL sel = method_getName(methods[i]);
        NSString *name = NSStringFromSelector(sel);
        NSLog(@"[VCAM]   %@", name);
    }
    free(methods);
    
    // 也扫描 VCamVerifyManager
    Class vmClass = objc_getClass("VCamVerifyManager");
    if (vmClass) {
        unsigned int vmCount = 0;
        Method *vmMethods = class_copyMethodList(vmClass, &vmCount);
        NSLog(@"[VCAM] VCamVerifyManager has %d methods:", vmCount);
        for (unsigned int i = 0; i < vmCount; i++) {
            SEL sel = method_getName(vmMethods[i]);
            NSString *name = NSStringFromSelector(sel);
            NSLog(@"[VCAM]   %@", name);
        }
        free(vmMethods);
    }
}

#pragma mark - 初始化

__attribute__((constructor))
static void vcam_kami_init(void) {
    NSLog(@"[VCAM] === v20 ===");
    
    // 1. URL 替换
    Class nsurlClass = [NSURL class];
    Method m1 = class_getClassMethod(nsurlClass, @selector(URLWithString:));
    if (m1) {
        orig_URLWithString = (void *)method_setImplementation(m1, (IMP)new_URLWithString);
        NSLog(@"[VCAM] Hooked URLWithString:");
    }
    Method m2 = class_getClassMethod(nsurlClass, @selector(URLWithString:relativeToURL:));
    if (m2) {
        orig_URLWithString_rel = (void *)method_setImplementation(m2, (IMP)new_URLWithString_rel);
        NSLog(@"[VCAM] Hooked URLWithString:relativeToURL:");
    }
    
    // 2. Hook requestAPIWithAction（调原始但加 VIP 设置）
    Class vmClass = objc_getClass("VCamVerifyManager");
    if (vmClass) {
        SEL apiSel = NSSelectorFromString(@"requestAPIWithAction:kami:isHeartbeat:completion:");
        Method apiMethod = class_getInstanceMethod(vmClass, apiSel);
        if (apiMethod) {
            orig_reqAPI = (void *)method_setImplementation(apiMethod, (IMP)h_reqAPI);
            NSLog(@"[VCAM] Hooked requestAPIWithAction");
        }
    }
    
    // 3. 延迟扫描类方法（等 App 完全加载）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        scanAndHookMenuVC();
    });
    
    NSLog(@"[VCAM] Ready");
}
