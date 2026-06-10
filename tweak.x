/**
 * VCamKamiHook v21.1 - 基于 v17.5（稳定版）+ 定时器 + 补全 key
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static void (*orig_reqAPI)(id, SEL, NSString *, NSString *, BOOL, void (^)(NSDictionary *));

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

static void forceVIPActive(void) {
    // NSUserDefaults
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:YES forKey:@"vcam_vip_unlocked"];
    
    // vcam_expires（同行用日期格式）
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    [fmt setDateFormat:@"yyyy/MM/dd HH:mm:ss"];
    NSString *expires = [fmt stringFromDate:[[NSDate date] dateByAddingTimeInterval:365*24*3600]];
    [ud setObject:expires forKey:@"vcam_expires"];
    [ud synchronize];
    
    // Keychain
    @try {
        Class kcClass = objc_getClass("llyKeychain");
        if (kcClass) {
            SEL sel = @selector(setPassword:forService:account:);
            if ([kcClass respondsToSelector:sel]) {
                ((void(*)(id, SEL, id, id, id))objc_msgSend)(kcClass, sel, @"VCAM_VIP_ACTIVATED", @"vcam_kami", @"vcam_kami");
            }
        }
    } @catch (NSException *e) {}
    
    // VCamVerifyManager
    @try {
        Class vmClass = objc_getClass("VCamVerifyManager");
        if (vmClass) {
            id vm = [vmClass performSelector:@selector(sharedInstance)];
            if (vm) {
                @try { [vm setValue:@([[[NSDate date] dateByAddingTimeInterval:365*24*3600] timeIntervalSince1970]) forKey:@"vip"]; } @catch (NSException *e) {}
                for (NSString *k in @[@"isVIP", @"isVip", @"isVerified", @"isAuthorized", @"_isVIP", @"_vipActive"]) {
                    @try { [vm setValue:@YES forKey:k]; } @catch (NSException *e) {}
                }
            }
        }
    } @catch (NSException *e) {}
}

static void activateVIPUI(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            forceVIPActive();
            
            UIViewController *menuVC = nil;
            for (UIWindow *window in [UIApplication sharedApplication].windows) {
                menuVC = findMenuVC(window.rootViewController);
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
            
            // 启用按钮
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

// 定时器
static NSTimer *g_vipTimer = nil;

static void startVIPTimer(void) {
    if (g_vipTimer) return;
    g_vipTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
        forceVIPActive();
    }];
    NSLog(@"[VCAM] Timer started");
}

static void h_reqAPI(id self, SEL _cmd,
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
                NSLog(@"[VCAM] error: %@", error.localizedDescription);
                if (completion) completion(@{@"code": @(-1), @"msg": @"网络错误"});
                return;
            }
            
            NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSLog(@"[VCAM] result: %@", json);
            
            if (json && [json[@"code"] integerValue] == 0) {
                if (kami && kami.length > 0) {
                    [[NSUserDefaults standardUserDefaults] setObject:kami forKey:@"vcam_verified_kami"];
                    [[NSUserDefaults standardUserDefaults] synchronize];
                }
                activateVIPUI();
                dispatch_async(dispatch_get_main_queue(), ^{
                    startVIPTimer();
                });
            }
            
            if (completion) completion(json ?: @{@"code": @(-1), @"msg": @"格式错误"});
        }];
    [task resume];
}

__attribute__((constructor))
static void vcam_kami_init(void) {
    NSLog(@"[VCAM] === v21.1 ===");
    
    Class vmClass = objc_getClass("VCamVerifyManager");
    if (vmClass) {
        SEL apiSel = NSSelectorFromString(@"requestAPIWithAction:kami:isHeartbeat:completion:");
        Method apiMethod = class_getInstanceMethod(vmClass, apiSel);
        if (apiMethod) {
            orig_reqAPI = (void *)method_setImplementation(apiMethod, (IMP)h_reqAPI);
            NSLog(@"[VCAM] Hooked OK");
        }
    }
    
    // 之前激活过则自动启动
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"vcam_vip_unlocked"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            activateVIPUI();
            startVIPTimer();
        });
    }
    
    NSLog(@"[VCAM] Ready");
}
