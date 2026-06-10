/**
 * VCamKamiHook v13 - 强制 VIP，无需卡密
 * 
 * 策略：
 * 1. Hook NSUserDefaults boolForKey:/objectForKey: → VIP 相关 key 返回 YES
 * 2. Hook VCamVerifyManager 所有未知 getter → 返回 YES/@"" 
 * 3. Hook showBanAlert → 拦截封禁
 * 4. 不拦截任何网络请求，不需要服务器
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - VIP 相关 key 模式

static BOOL isVIPKey(NSString *key) {
    if (!key) return NO;
    NSString *lower = [key lowercaseString];
    return ([lower containsString:@"vip"] ||
            [lower containsString:@"auth"] ||
            [lower containsString:@"verify"] ||
            [lower containsString:@"active"] ||
            [lower containsString:@"unlock"] ||
            [lower containsString:@"premium"] ||
            [lower containsString:@"license"] ||
            [lower containsString:@"kami"] ||
            [lower containsString:@"expire"]);
}

#pragma mark - Hook NSUserDefaults

static BOOL (*orig_boolForKey)(id, SEL, NSString *);
static BOOL h_boolForKey(id self, SEL _cmd, NSString *key) {
    if (isVIPKey(key)) {
        NSLog(@"[VCAM] boolForKey: %@ → YES", key);
        return YES;
    }
    return orig_boolForKey(self, _cmd, key);
}

static id (*orig_objectForKey)(id, SEL, NSString *);
static id h_objectForKey(id self, SEL _cmd, NSString *key) {
    if (isVIPKey(key)) {
        // 对于 kami 相关的 key，返回一个假卡密
        if ([key.lowercaseString containsString:@"kami"] ||
            [key.lowercaseString containsString:@"license"] ||
            [key.lowercaseString containsString:@"code"]) {
            NSLog(@"[VCAM] objectForKey: %@ → 假卡密", key);
            return @"VCAM_VIP_ACTIVATED";
        }
        // 对于 expire 相关的 key，返回未来时间
        if ([key.lowercaseString containsString:@"expire"]) {
            NSString *future = @"2099/12/31 23:59:59";
            NSLog(@"[VCAM] objectForKey: %@ → %@", key, future);
            return future;
        }
        // 其他 VIP key 返回 YES
        NSLog(@"[VCAM] objectForKey: %@ → @YES", key);
        return @YES;
    }
    return orig_objectForKey(self, _cmd, key);
}

#pragma mark - Hook VCamVerifyManager forwardInvocation

static void (*orig_vm_forwardInvocation)(id, SEL, NSInvocation *);
static void h_vm_forwardInvocation(id self, SEL _cmd, NSInvocation *inv) {
    SEL sel;
    sel = [inv selector];
    NSString *name = NSStringFromSelector(sel);
    
    // 如果是 getter 方法（is*/has*/get*），返回 YES
    if ([name hasPrefix:@"is"] || [name hasPrefix:@"has"] || [name hasPrefix:@"get"]) {
        NSMethodSignature *sig = [inv methodSignature];
        const char *retType = [sig methodReturnType];
        
        if (strcmp(retType, "B") == 0 || strcmp(retType, "c") == 0) {
            // BOOL / char
            BOOL result = YES;
            [inv setReturnValue:&result];
            NSLog(@"[VCAM] forwardInvocation: %@ → YES", name);
            return;
        }
    }
    
    // 调原始
    if (orig_vm_forwardInvocation) {
        orig_vm_forwardInvocation(self, _cmd, inv);
    }
}

#pragma mark - Hook VCamVerifyManager respondsToSelector

static BOOL (*orig_vm_respondsToSelector)(id, SEL, SEL);
static BOOL h_vm_respondsToSelector(id self, SEL _cmd, SEL aSelector) {
    NSString *name = NSStringFromSelector(aSelector);
    // 对 VIP 相关的 selector 返回 YES
    NSString *lower = name.lowercaseString;
    if ([lower containsString:@"vip"] || [lower containsString:@"auth"] ||
        [lower containsString:@"verify"] || [lower containsString:@"active"] ||
        [lower containsString:@"unlock"] || [lower containsString:@"premium"]) {
        NSLog(@"[VCAM] respondsToSelector: %@ → YES", name);
        return YES;
    }
    return orig_vm_respondsToSelector(self, _cmd, aSelector);
}

#pragma mark - 动态添加 VIP getter 方法

static BOOL vipGetterYES(id self, SEL _cmd) {
    NSLog(@"[VCAM] %@ → YES", NSStringFromSelector(_cmd));
    return YES;
}

static NSString *kamiGetter(id self, SEL _cmd) {
    return @"VCAM_VIP_ACTIVATED";
}

#pragma mark - Hook showBanAlert

static void (*orig_showBanAlert)(id, SEL, id);
static void h_showBanAlert(id self, SEL _cmd, id msg) {
    NSLog(@"[VCAM] showBanAlert 拦截: %@", msg);
}

#pragma mark - Hook VCamMenuVC 的 startVerifyProcess

static void (*orig_startVerifyProcess)(id, SEL);
static void h_startVerifyProcess(id self, SEL _cmd) {
    NSLog(@"[VCAM] startVerifyProcess → 直接激活 VIP，跳过验证");
    
    // 不调原始方法，直接设置 VIP 状态
    Class vmClass = objc_getClass("VCamVerifyManager");
    if (vmClass && [vmClass respondsToSelector:@selector(sharedInstance)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id vm = [vmClass performSelector:@selector(sharedInstance)];
#pragma clang diagnostic pop
        if (vm) {
            // 暴力设置所有可能的属性
            NSArray *boolKeys = @[@"isVIP", @"isVerified", @"isAuthorized", @"vipActivated",
                                  @"verified", @"isVip", @"hasVIP", @"vipEnabled", 
                                  @"isPremium", @"unlocked", @"is_authorized", @"auth"];
            for (NSString *k in boolKeys) {
                @try { [vm setValue:@YES forKey:k]; } @catch (NSException *e) { }
            }
            NSArray *kamiKeys = @[@"use_kami", @"kami", @"activeKami", @"currentKami",
                                  @"licenseKey", @"activationCode"];
            for (NSString *k in kamiKeys) {
                @try { [vm setValue:@"VCAM_VIP_ACTIVATED" forKey:k]; } @catch (NSException *e) { }
            }
            NSLog(@"[VCAM] VCamVerifyManager 已强制设置 VIP");
        }
    }
    
    // 也对 self (VCamMenuVC) 设置
    NSArray *boolKeys = @[@"isVIP", @"isVerified", @"isAuthorized", @"vipActivated",
                          @"verified", @"isVip", @"hasVIP", @"vipEnabled"];
    for (NSString *k in boolKeys) {
        @try { [self setValue:@YES forKey:k]; } @catch (NSException *e) { }
    }
    
    // 保存到 NSUserDefaults
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"vcam_vip_unlocked"];
    [[NSUserDefaults standardUserDefaults] setObject:@"VCAM_VIP_ACTIVATED" forKey:@"vcam_verified_kami"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark - 初始化

__attribute__((constructor))
static void vcam_kami_init(void) {
    NSLog(@"[VCAM] === VCamKamiHook v13 (force VIP, no kami needed) ===");
    
    // 1. Hook NSUserDefaults
    Class udClass = [NSUserDefaults class];
    
    Method boolMethod = class_getInstanceMethod(udClass, @selector(boolForKey:));
    if (boolMethod) {
        orig_boolForKey = (void *)method_setImplementation(boolMethod, (IMP)h_boolForKey);
        NSLog(@"[VCAM] Hooked boolForKey:");
    }
    
    Method objMethod = class_getInstanceMethod(udClass, @selector(objectForKey:));
    if (objMethod) {
        orig_objectForKey = (void *)method_setImplementation(objMethod, (IMP)h_objectForKey);
        NSLog(@"[VCAM] Hooked objectForKey:");
    }
    
    // 2. Hook VCamVerifyManager
    Class vmClass = objc_getClass("VCamVerifyManager");
    if (vmClass) {
        // 动态添加常见的 VIP getter（如果不存在）
        NSArray *boolGetters = @[@"isVIP", @"isVerified", @"isAuthorized", @"isVip",
                                 @"hasVIP", @"vipEnabled", @"isPremium", @"isUnlocked"];
        for (NSString *name in boolGetters) {
            SEL sel = NSSelectorFromString(name);
            if (!class_getInstanceMethod(vmClass, sel)) {
                class_addMethod(vmClass, sel, (IMP)vipGetterYES, "B@:");
                NSLog(@"[VCAM] 添加方法: %@", name);
            }
        }
        
        // 添加 kami getter
        NSArray *kamiGetters = @[@"use_kami", @"kami", @"activeKami"];
        for (NSString *name in kamiGetters) {
            SEL sel = NSSelectorFromString(name);
            if (!class_getInstanceMethod(vmClass, sel)) {
                class_addMethod(vmClass, sel, (IMP)kamiGetter, "@@:");
                NSLog(@"[VCAM] 添加方法: %@", name);
            }
        }
        
        // Hook forwardInvocation 捕获未知方法调用
        Method fiMethod = class_getInstanceMethod(vmClass, @selector(forwardInvocation:));
        if (fiMethod) {
            orig_vm_forwardInvocation = (void *)method_setImplementation(fiMethod, (IMP)h_vm_forwardInvocation);
            NSLog(@"[VCAM] Hooked forwardInvocation:");
        }
        
        // Hook respondsToSelector
        Method rtm = class_getInstanceMethod(vmClass, @selector(respondsToSelector:));
        if (rtm) {
            orig_vm_respondsToSelector = (void *)method_setImplementation(rtm, (IMP)h_vm_respondsToSelector);
            NSLog(@"[VCAM] Hooked respondsToSelector:");
        }
    }
    
    // 3. Hook VCamMenuVC
    Class mcClass = objc_getClass("VCamMenuVC");
    if (mcClass) {
        // showBanAlert:
        Method banMethod = class_getInstanceMethod(mcClass, NSSelectorFromString(@"showBanAlert:"));
        if (banMethod) {
            orig_showBanAlert = (void *)method_setImplementation(banMethod, (IMP)h_showBanAlert);
            NSLog(@"[VCAM] Hooked showBanAlert:");
        }
        
        // startVerifyProcess
        Method svpMethod = class_getInstanceMethod(mcClass, NSSelectorFromString(@"startVerifyProcess"));
        if (svpMethod) {
            orig_startVerifyProcess = (void *)method_setImplementation(svpMethod, (IMP)h_startVerifyProcess);
            NSLog(@"[VCAM] Hooked startVerifyProcess");
        }
    }
    
    // 4. 预设 NSUserDefaults VIP 值
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:YES forKey:@"vcam_vip_unlocked"];
    [ud setObject:@"VCAM_VIP_ACTIVATED" forKey:@"vcam_verified_kami"];
    [ud setObject:@"2099/12/31 23:59:59" forKey:@"vcam_expires"];
    [ud synchronize];
    NSLog(@"[VCAM] NSUserDefaults VIP 已预设");
    
    NSLog(@"[VCAM] VCamKamiHook v13 Ready - 无需卡密，强制 VIP");
}
