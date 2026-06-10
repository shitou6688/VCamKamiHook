/**
 * VCamKamiHook v21 - 完全模仿同行 vcam_kami(5)
 * 
 * 关键差异（之前遗漏的）：
 * 1. NSTimer 定时器持续刷新 VIP 状态
 * 2. vcam_expires 用 yyyy/MM/dd HH:mm:ss 格式
 * 3. llyKeychain 存储 vcam_kami
 * 4. 完全替换 requestAPI，不调原始
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

#pragma mark - VIP 激活（同行完整方案）

static void forceVIPActive(void) {
    // 1. NSUserDefaults
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:YES forKey:@"vcam_vip_unlocked"];
    
    // 2. vcam_expires 用日期格式（同行做法）
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    [fmt setDateFormat:@"yyyy/MM/dd HH:mm:ss"];
    NSString *expires = [fmt stringFromDate:[[NSDate date] dateByAddingTimeInterval:365*24*3600]];
    [ud setObject:expires forKey:@"vcam_expires"];
    [ud synchronize];
    
    // 3. Keychain
    @try {
        Class kcClass = objc_getClass("llyKeychain");
        if (kcClass) {
            SEL sel = @selector(setPassword:forService:account:);
            if ([kcClass respondsToSelector:sel]) {
                ((void(*)(id, SEL, id, id, id))objc_msgSend)(kcClass, sel, @"VCAM_VIP_ACTIVATED", @"vcam_kami", @"vcam_kami");
            }
        }
    } @catch (NSException *e) {}
    
    // 4. VCamVerifyManager
    @try {
        Class vmClass = objc_getClass("VCamVerifyManager");
        if (vmClass) {
            id vm = [vmClass performSelector:@selector(sharedInstance)];
            if (vm) {
                // 设 vip 过期时间戳
                @try { [vm setValue:@([[[NSDate date] dateByAddingTimeInterval:365*24*3600] timeIntervalSince1970]) forKey:@"vip"]; } @catch (NSException *e) {}
                // 设 VIP 标志
                for (NSString *k in @[@"isVIP", @"isVip", @"isVerified", @"isAuthorized",
                                      @"vipActivated", @"hasVIP", @"vipEnabled", @"isPremium",
                                      @"_isVIP", @"_vipActive"]) {
                    @try { [vm setValue:@YES forKey:k]; } @catch (NSException *e) {}
                }
            }
        }
    } @catch (NSException *e) {}
    
    // 5. VCamMenuVC UI
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIViewController *menuVC = nil;
            for (UIWindow *window in [UIApplication sharedApplication].windows) {
                UIViewController *root = window.rootViewController;
                if (!root) continue;
                
                // 递归查找
                UIViewController *findVC(UIViewController *vc) {
                    if (!vc) return nil;
                    if ([vc isKindOfClass:NSClassFromString(@"VCamMenuVC")]) return vc;
                    UIViewController *found = findVC(vc.presentedViewController);
                    if (found) return found;
                    for (UIViewController *child in vc.childViewControllers) {
                        found = findVC(child);
                        if (found) return found;
                    }
                    return nil;
                }
                
                menuVC = findVC(root);
                if (menuVC) break;
            }
            
            if (!menuVC) return;
            
            // authStatusLabel
            @try {
                UILabel *label = [menuVC valueForKey:@"authStatusLabel"];
                if (label && [label isKindOfClass:[UILabel class]]) {
                    label.text = @"已激活";
                    label.textColor = [UIColor greenColor];
                }
            } @catch (NSException *e) {}
            
            // 按钮
            for (NSString *name in @[@"btnLoop", @"btnSound", @"btnRotate",
                                     @"btnMirror", @"btnReplacement", @"btnPhotoReplacement"]) {
                @try {
                    UIButton *btn = [menuVC valueForKey:name];
                    if (btn && [btn isKindOfClass:[UIButton class]]) {
                        btn.enabled = YES;
                        btn.alpha = 1.0;
                    }
                } @catch (NSException *e) {}
            }
            
            // refreshUIStates
            @try {
                if ([menuVC respondsToSelector:@selector(refreshUIStates)]) {
                    ((void(*)(id, SEL))objc_msgSend)(menuVC, @selector(refreshUIStates));
                }
            } @catch (NSException *e) {}
            
            // showToast
            @try {
                if ([menuVC respondsToSelector:@selector(showToast:)]) {
                    ((void(*)(id, SEL, id))objc_msgSend)(menuVC, @selector(showToast:), @"激活成功");
                }
            } @catch (NSException *e) {}
        } @catch (NSException *e) {}
    });
}

#pragma mark - NSTimer 定时刷新（同行关键做法）

static NSTimer *g_vipTimer = nil;

static void startVIPTimer(void) {
    if (g_vipTimer) return;
    
    g_vipTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *timer) {
        @try {
            forceVIPActive();
        } @catch (NSException *e) {}
    }];
    NSLog(@"[VCAM] VIP 定时器已启动");
}

#pragma mark - Hook requestAPIWithAction

static void (*orig_reqAPI)(id, SEL, NSString *, NSString *, BOOL, void (^)(NSDictionary *));

static void h_reqAPI(id self, SEL _cmd,
    NSString *action, NSString *kami, BOOL isHeartbeat,
    void (^completion)(NSDictionary *)) {
    
    NSLog(@"[VCAM] reqAPI: action=%@ kami=%@ heartbeat=%d", action, kami, (int)isHeartbeat);
    
    // 调原始方法（URL已替换）
    // 但 wrap completion 来加 VIP 激活
    void (^wrappedCompletion)(NSDictionary *) = ^(NSDictionary *result) {
        NSLog(@"[VCAM] 结果: %@", result);
        
        NSInteger code = [result[@"code"] integerValue];
        if (code == 0) {
            // 保存 kami
            if (kami && kami.length > 0) {
                [[NSUserDefaults standardUserDefaults] setObject:kami forKey:@"vcam_verified_kami"];
                [[NSUserDefaults standardUserDefaults] synchronize];
            }
            
            // 强制激活
            forceVIPActive();
            
            // 启动定时器
            startVIPTimer();
        }
        
        if (completion) completion(result);
    };
    
    if (orig_reqAPI) {
        orig_reqAPI(self, _cmd, action, kami, isHeartbeat, wrappedCompletion);
    }
}

#pragma mark - 初始化

__attribute__((constructor))
static void vcam_kami_init(void) {
    NSLog(@"[VCAM] === v21 ===");
    
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
    }
    
    // 2. Hook requestAPIWithAction
    Class vmClass = objc_getClass("VCamVerifyManager");
    if (vmClass) {
        SEL apiSel = NSSelectorFromString(@"requestAPIWithAction:kami:isHeartbeat:completion:");
        Method apiMethod = class_getInstanceMethod(vmClass, apiSel);
        if (apiMethod) {
            orig_reqAPI = (void *)method_setImplementation(apiMethod, (IMP)h_reqAPI);
            NSLog(@"[VCAM] Hooked requestAPIWithAction");
        }
    }
    
    // 3. 检查是否之前已激活，自动启动定时器
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"vcam_vip_unlocked"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            forceVIPActive();
            startVIPTimer();
        });
    }
    
    NSLog(@"[VCAM] Ready");
}
