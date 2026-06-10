/**
 * VCamKamiHook v15.1 - 安全版，避免闪退
 * 
 * 1. URL 替换（NSURL URLWithString:）
 * 2. Hook requestAPIWithAction completion → API成功后激活VIP
 * 3. 不在启动时做任何操作，避免闪退
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
    if (string && ([string containsString:@"xnsp"] || [string containsString:@"qiaohe"])) {
        return new_URLWithString(self, @selector(URLWithString:), string);
    }
    return orig_URLWithString_rel(self, _cmd, string, baseURL);
}

#pragma mark - VIP 激活（安全版）

static void activateVIPOnVC(id targetVC) {
    NSLog(@"[VCAM] 在 VCamMenuVC 上激活 VIP");
    
    // 设置 authStatusLabel
    @try {
        id label = [targetVC valueForKey:@"authStatusLabel"];
        if (label && [label isKindOfClass:[UILabel class]]) {
            [(UILabel *)label setText:@"已激活"];
            [(UILabel *)label setTextColor:[UIColor systemGreenColor]];
            NSLog(@"[VCAM] authStatusLabel 已设置");
        }
    } @catch (NSException *e) {
        NSLog(@"[VCAM] authStatusLabel 异常: %@", e);
    }
    
    // 启用 VIP 按钮
    NSArray *btnNames = @[@"btnLoop", @"btnSound", @"btnRotate",
                          @"btnMirror", @"btnReplacement", @"btnPhotoReplacement"];
    for (NSString *name in btnNames) {
        @try {
            id btn = [targetVC valueForKey:name];
            if (btn && [btn isKindOfClass:[UIButton class]]) {
                [(UIButton *)btn setEnabled:YES];
                [(UIButton *)btn setAlpha:1.0];
                NSLog(@"[VCAM] 启用按钮: %@", name);
            }
        } @catch (NSException *e) {
            NSLog(@"[VCAM] 按钮 %@ 异常: %@", name, e);
        }
    }
    
    // 刷新 UI
    @try {
        SEL refreshSel = NSSelectorFromString(@"refreshUIStates");
        if ([targetVC respondsToSelector:refreshSel]) {
            ((void(*)(id, SEL))objc_msgSend)(targetVC, refreshSel);
            NSLog(@"[VCAM] refreshUIStates 已调用");
        }
    } @catch (NSException *e) {
        NSLog(@"[VCAM] refreshUIStates 异常: %@", e);
    }
    
    // NSUserDefaults 持久化
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:YES forKey:@"vcam_vip_unlocked"];
    [ud setObject:@"VCAM_VIP_ACTIVATED" forKey:@"vcam_verified_kami"];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    [fmt setDateFormat:@"yyyy/MM/dd HH:mm:ss"];
    NSString *expires = [fmt stringFromDate:[[NSDate date] dateByAddingTimeInterval:365*24*3600]];
    [ud setObject:expires forKey:@"vcam_expires"];
    [ud synchronize];
    NSLog(@"[VCAM] NSUserDefaults 已保存");
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
            // API 成功 → 主线程激活 VIP
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    // 遍历 window 找 VCamMenuVC
                    for (UIWindow *window in [UIApplication sharedApplication].windows) {
                        UIViewController *rootVC = window.rootViewController;
                        if (!rootVC) continue;
                        
                        // 递归查找 VCamMenuVC
                        __block UIViewController *found = nil;
                        void (^findVC)(UIViewController *) = ^(UIViewController *vc) {
                            if (found) return;
                            if ([vc isKindOfClass:NSClassFromString(@"VCamMenuVC")]) {
                                found = vc;
                                return;
                            }
                            for (UIViewController *child in vc.childViewControllers) {
                                findVC(child);
                                if (found) return;
                            }
                        };
                        findVC(rootVC);
                        
                        if (found) {
                            activateVIPOnVC(found);
                            break;
                        }
                    }
                } @catch (NSException *e) {
                    NSLog(@"[VCAM] VIP激活异常: %@", e);
                }
            });
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
    NSLog(@"[VCAM] === VCamKamiHook v15.1 (safe) ===");
    
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
    
    NSLog(@"[VCAM] VCamKamiHook v15.1 Ready");
}
