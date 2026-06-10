/**
 * VCamKamiHook v15 - 完整方案（学习同行 vcam_kami）
 * 
 * 关键发现：
 * 1. verifyAndProceed: 是激活 VIP 的核心方法
 * 2. VIP 按钮需要手动 setEnabled + setAlpha
 * 3. authStatusLabel 需要设置"已激活"
 * 4. NSUserDefaults + Keychain 存状态
 * 5. refreshUIStates 刷新 UI
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - URL 替换 (NSURL URLWithString:)

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
    if (string && ([string containsString:@"xnsp"] || [string containsString:@"qiaohe"])) {
        return new_URLWithString(self, @selector(URLWithString:), string);
    }
    return orig_URLWithString_rel(self, _cmd, string, baseURL);
}

#pragma mark - VIP 激活核心函数

static void activateVIP(void) {
    NSLog(@"[VCAM] === 开始激活 VIP ===");
    
    // 1. NSUserDefaults 存状态
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:YES forKey:@"vcam_vip_unlocked"];
    [ud setObject:@"VCAM_VIP_ACTIVATED" forKey:@"vcam_verified_kami"];
    
    // 过期时间格式: yyyy/MM/dd HH:mm:ss
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    [fmt setDateFormat:@"yyyy/MM/dd HH:mm:ss"];
    NSString *expires = [fmt stringFromDate:[[NSDate date] dateByAddingTimeInterval:365*24*3600]];
    [ud setObject:expires forKey:@"vcam_expires"];
    [ud synchronize];
    NSLog(@"[VCAM] NSUserDefaults 已设置, expires=%@", expires);
    
    // 2. Keychain 存卡密
    @try {
        Class kcClass = objc_getClass("llyKeychain");
        if (kcClass) {
            SEL setPwSel = @selector(setPassword:forService:account:);
            if ([kcClass respondsToSelector:setPwSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [kcClass performSelector:setPwSel withObject:@"VCAM_VIP_ACTIVATED" withObject:@"vcam_kami" withObject:@"vcam_kami"];
#pragma clang diagnostic pop
                NSLog(@"[VCAM] Keychain 已设置");
            }
        } else {
            NSLog(@"[VCAM] llyKeychain 类不存在，跳过 Keychain");
        }
    } @catch (NSException *e) {
        NSLog(@"[VCAM] Keychain 写入异常: %@", e);
    }
    
    // 3. 获取 VCamMenuVC 实例，激活按钮
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            // 遍历所有 window 找 VCamMenuVC
            for (UIWindow *window in [UIApplication sharedApplication].windows) {
                UIViewController *rootVC = window.rootViewController;
                UIViewController *targetVC = nil;
                
                // 递归查找
                void (^findVC)(UIViewController *) = ^(UIViewController *vc) {
                    if ([vc isKindOfClass:NSClassFromString(@"VCamMenuVC")]) {
                        targetVC = vc;
                        return;
                    }
                    for (UIViewController *child in vc.childViewControllers) {
                        findVC(child);
                    }
                };
                findVC(rootVC);
                
                if (targetVC) {
                    NSLog(@"[VCAM] 找到 VCamMenuVC");
                    
                    // 设置 authStatusLabel
                    @try {
                        id label = [targetVC valueForKey:@"authStatusLabel"];
                        if (label && [label respondsToSelector:@selector(setText:)]) {
                            [label setText:@"已激活"];
                        }
                    } @catch (NSException *e) {}
                    
                    // 设置 authStatusLabel 颜色
                    @try {
                        id label = [targetVC valueForKey:@"authStatusLabel"];
                        if (label && [label respondsToSelector:@selector(setTextColor:)]) {
                            [label setTextColor:[UIColor systemGreenColor]];
                        }
                    } @catch (NSException *e) {}
                    
                    // 启用所有 VIP 按钮
                    NSArray *btnNames = @[@"btnLoop", @"btnSound", @"btnRotate", 
                                          @"btnMirror", @"btnReplacement", @"btnPhotoReplacement"];
                    for (NSString *name in btnNames) {
                        @try {
                            id btn = [targetVC valueForKey:name];
                            if (btn) {
                                if ([btn respondsToSelector:@selector(setEnabled:)]) {
                                    [btn setEnabled:YES];
                                }
                                if ([btn respondsToSelector:@selector(setAlpha:)]) {
                                    [btn setAlpha:1.0];
                                }
                                NSLog(@"[VCAM] 启用按钮: %@", name);
                            }
                        } @catch (NSException *e) {
                            NSLog(@"[VCAM] 按钮 %@ 异常: %@", name, e);
                        }
                    }
                    
                    // 调用 verifyAndProceed: 激活 VIP
                    @try {
                        SEL verifySel = NSSelectorFromString(@"verifyAndProceed:");
                        if ([targetVC respondsToSelector:verifySel]) {
                            // verifyAndProceed: 需要一个 sender 参数
                            ((void(*)(id, SEL, id))objc_msgSend)(targetVC, verifySel, targetVC);
                            NSLog(@"[VCAM] 已调用 verifyAndProceed:");
                        }
                    } @catch (NSException *e) {
                        NSLog(@"[VCAM] verifyAndProceed: 异常: %@", e);
                    }
                    
                    // 刷新 UI
                    @try {
                        SEL refreshSel = NSSelectorFromString(@"refreshUIStates");
                        if ([targetVC respondsToSelector:refreshSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                            [targetVC performSelector:refreshSel];
#pragma clang diagnostic pop
                            NSLog(@"[VCAM] 已调用 refreshUIStates");
                        }
                    } @catch (NSException *e) {}
                    
                    break;
                }
            }
        } @catch (NSException *e) {
            NSLog(@"[VCAM] VIP激活异常: %@", e);
        }
    });
}

#pragma mark - Hook requestAPIWithAction

static void (*orig_reqAPI)(id, SEL, NSString *, NSString *, BOOL, void (^)(NSDictionary *));

static void h_reqAPI(id self, SEL _cmd,
    NSString *action, NSString *kami, BOOL isHeartbeat,
    void (^completion)(NSDictionary *)) {
    
    NSLog(@"[VCAM] reqAPI: action=%@ kami=%@ heartbeat=%d", action, kami, (int)isHeartbeat);
    
    void (^wrappedCompletion)(NSDictionary *) = ^(NSDictionary *result) {
        NSLog(@"[VCAM] reqAPI返回: %@", result);
        
        if (result && [result[@"code"] integerValue] == 0) {
            // API 返回成功，触发 VIP 激活
            activateVIP();
        }
        
        if (completion) completion(result);
    };
    
    if (orig_reqAPI) {
        orig_reqAPI(self, _cmd, action, kami, isHeartbeat, wrappedCompletion);
    }
}

#pragma mark - App 启动时自动激活（如果之前已验证过）

static void checkAndAutoActivate(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if ([ud boolForKey:@"vcam_vip_unlocked"]) {
        NSLog(@"[VCAM] 检测到已激活状态，自动激活 VIP");
        activateVIP();
    }
}

#pragma mark - 初始化

__attribute__((constructor))
static void vcam_kami_init(void) {
    NSLog(@"[VCAM] === VCamKamiHook v15 ===");
    
    // 1. Hook NSURL URLWithString:
    Class nsurlClass = [NSURL class];
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
    
    // 3. 延迟检查是否需要自动激活
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        checkAndAutoActivate();
    });
    
    NSLog(@"[VCAM] VCamKamiHook v15 Ready");
}
