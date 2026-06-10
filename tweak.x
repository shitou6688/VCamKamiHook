/**
 * VCamKamiHook v18 - 绕过功能按钮内部的 VIP 检查
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static void (*orig_requestAPI)(id, SEL, NSString *, NSString *, BOOL, void (^)(NSDictionary *));
static UIViewController* findMenuVC(UIViewController *root) {
    if (!root) return nil;
    if ([root isKindOfClass:NSClassFromString(@"VCamMenuVC")]) return root;
    if (root.presentedViewController) {
        UIViewController *found = findMenuVC(root.presentedViewController);
        if (found) return found;
    }
    for (UIViewController *child in root.childViewControllers) {
        UIViewController *found = findMenuVC(child);
        if (found) return found;
    }
    return nil;
}

static void activateVIPFull(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIViewController *menuVC = nil;
            for (UIWindow *window in [UIApplication sharedApplication].windows) {
                menuVC = findMenuVC(window.rootViewController);
                if (menuVC) break;
            }
            if (!menuVC) return;
            
            NSLog(@"[VCAM] === 完整激活VIP ===");
            
            // 1. authStatusLabel
            @try {
                UILabel *label = [menuVC valueForKey:@"authStatusLabel"];
                if (label && [label isKindOfClass:[UILabel class]]) {
                    label.text = @"已激活";
                    label.textColor = [UIColor greenColor];
                }
            } @catch (NSException *e) {}
            
            // 2. 启用所有按钮
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
            
            // 3. 设置 VCamVerifyManager 内部状态（暴力设置所有可能的属性）
            Class vmClass = objc_getClass("VCamVerifyManager");
            if (vmClass) {
                id vm = nil;
                @try {
                    if ([vmClass respondsToSelector:@selector(sharedInstance)]) {
                        vm = [vmClass performSelector:@selector(sharedInstance)];
                    }
                } @catch (NSException *e) {}
                
                if (vm) {
                    // 暴力设置所有可能的 VIP 属性
                    NSArray *boolProps = @[@"isVIP", @"isVerified", @"isAuthorized",
                                          @"vipActivated", @"verified", @"isVip",
                                          @"hasVIP", @"vipEnabled", @"isPremium",
                                          @"unlocked", @"is_authorized"];
                    for (NSString *k in boolProps) {
                        @try { [vm setValue:@YES forKey:k]; } @catch (NSException *e) {}
                    }
                    
                    // 也尝试直接设 ivar（通过 KVC）
                    NSArray *vipKeys = @[@"_isVIP", @"_isVerified", @"_vipActive",
                                        @"_authorized", @"_unlocked"];
                    for (NSString *k in vipKeys) {
                        @try { [vm setValue:@YES forKey:k]; } @catch (NSException *e) {}
                    }
                    
                    NSLog(@"[VCAM] VCamVerifyManager 属性已设置");
                }
            }
            
            // 4. 对 menuVC 本身也设置 VIP 属性
            for (NSString *k in @[@"isVIP", @"isVerified", @"isAuthorized", @"vipEnabled"]) {
                @try { [menuVC setValue:@YES forKey:k]; } @catch (NSException *e) {}
            }
            
            // 5. refreshUIStates
            @try {
                if ([menuVC respondsToSelector:@selector(refreshUIStates)]) {
                    ((void(*)(id, SEL))objc_msgSend)(menuVC, @selector(refreshUIStates));
                }
            } @catch (NSException *e) {}
            
            // 6. showToast
            @try {
                if ([menuVC respondsToSelector:@selector(showToast:)]) {
                    ((void(*)(id, SEL, id))objc_msgSend)(menuVC, @selector(showToast:), @"激活成功");
                }
            } @catch (NSException *e) {}
            
            NSLog(@"[VCAM] VIP 完整激活完成");
        } @catch (NSException *e) {
            NSLog(@"[VCAM] 异常: %@", e);
        }
    });
}

static void h_requestAPI(id self, SEL _cmd,
    NSString *action, NSString *kami, BOOL isHeartbeat,
    void (^completion)(NSDictionary *)) {
    
    NSLog(@"[VCAM] reqAPI: action=%@ kami=%@ heartbeat=%d", action, kami, (int)isHeartbeat);
    
    NSString *udid = @"unknown";
    @try {
        if ([self respondsToSelector:@selector(getDeviceID)]) {
            id ret = [self performSelector:@selector(getDeviceID)];
            if ([ret isKindOfClass:[NSString class]] && [(NSString *)ret length] > 0) {
                udid = (NSString *)ret;
            }
        }
    } @catch (NSException *e) {}
    
    if ([udid isEqualToString:@"unknown"]) {
        @try { udid = [[[UIDevice currentDevice] identifierForVendor] UUIDString] ?: @"unknown"; } @catch (NSException *e) {}
    }
    
    NSString *urlStr = [NSString stringWithFormat:@"http://124.221.171.80/vcam_api.php?action=%@&udid=%@&ts=%lld&sign=0",
        action ?: @"check", udid, (long long)[[NSDate date] timeIntervalSince1970]];
    if (kami && kami.length > 0) {
        urlStr = [urlStr stringByAppendingFormat:@"&kami=%@", kami];
    }
    
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
            
            NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSLog(@"[VCAM] 返回: %@", json);
            
            if (json && [json[@"code"] integerValue] == 0) {
                [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"vcam_vip_unlocked"];
                [[NSUserDefaults standardUserDefaults] synchronize];
                activateVIPFull();
            }
            
            if (completion) completion(json ?: @{@"code": @(-1), @"msg": @"格式错误"});
        }];
    [task resume];
}

// Hook showBanAlert / 未授权弹窗 → 直接拦截
static void (*orig_showAlert)(id, SEL, id);
static void h_showAlert(id self, SEL _cmd, id msg) {
    NSLog(@"[VCAM] 拦截未授权弹窗: %@", msg);
    // 不调原始方法，直接忽略
}

__attribute__((constructor))
static void vcam_kami_init(void) {
    NSLog(@"[VCAM] === v18 ===");
    
    // 1. Hook requestAPIWithAction
    Class vmClass = objc_getClass("VCamVerifyManager");
    if (vmClass) {
        SEL apiSel = NSSelectorFromString(@"requestAPIWithAction:kami:isHeartbeat:completion:");
        Method apiMethod = class_getInstanceMethod(vmClass, apiSel);
        if (apiMethod) {
            orig_requestAPI = (void *)method_setImplementation(apiMethod, (IMP)h_requestAPI);
            NSLog(@"[VCAM] Hooked requestAPIWithAction");
        }
    }
    
    // 2. Hook showBanAlert / 未授权弹窗
    Class mcClass = objc_getClass("VCamMenuVC");
    if (mcClass) {
        // 尝试多个可能的 selector
        NSArray *alertSels = @[@"showBanAlert:", @"showUnauthorizedAlert:",
                                @"showAuthFailedAlert:", @"showNotAuthorized:"];
        for (NSString *selName in alertSels) {
            SEL sel = NSSelectorFromString(selName);
            Method m = class_getInstanceMethod(mcClass, sel);
            if (m) {
                orig_showAlert = (void *)method_setImplementation(m, (IMP)h_showAlert);
                NSLog(@"[VCAM] Hooked %@", selName);
                break;
            }
        }
    }
    
    NSLog(@"[VCAM] Ready");
}
