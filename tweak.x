/**
 * VCamKamiHook v22 - 暴力遍历所有 ivar + 定时器
 * 
 * 之前设 VIP 属性用的是猜测的 key 名，可能不对
 * 现在用 runtime 遍历 VCamVerifyManager 的所有 ivar，全部设为 VIP
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
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    [fmt setDateFormat:@"yyyy/MM/dd HH:mm:ss"];
    [ud setObject:[fmt stringFromDate:[[NSDate date] dateByAddingTimeInterval:365*24*3600]] forKey:@"vcam_expires"];
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
    
    // VCamVerifyManager - 暴力遍历所有 ivar
    @try {
        Class vmClass = objc_getClass("VCamVerifyManager");
        if (vmClass) {
            id vm = [vmClass performSelector:@selector(sharedInstance)];
            if (vm) {
                unsigned int ivarCount = 0;
                Ivar *ivars = class_copyIvarList(vmClass, &ivarCount);
                NSLog(@"[VCAM] VCamVerifyManager ivars (%d):", ivarCount);
                for (unsigned int i = 0; i < ivarCount; i++) {
                    const char *ivarName = ivar_getName(ivars[i]);
                    const char *ivarType = ivar_getTypeEncoding(ivars[i]);
                    if (!ivarName) continue;
                    NSString *name = [NSString stringWithUTF8String:ivarName];
                    NSString *type = ivarType ? [NSString stringWithUTF8String:ivarType] : @"";
                    NSLog(@"[VCAM]   ivar: %@ type=%@", name, type);
                    
                    // 根据类型设置值
                    @try {
                        if ([type hasPrefix:@"c"] || [type hasPrefix:@"B"]) {
                            // BOOL / char
                            object_setIvar(vm, ivars[i], @YES);
                            NSLog(@"[VCAM]     -> set YES");
                        } else if ([type hasPrefix:@"i"] || [type hasPrefix:@"l"] || [type hasPrefix:@"q"]) {
                            // int / long / long long
                            object_setIvar(vm, ivars[i], @1);
                            NSLog(@"[VCAM]     -> set 1");
                        } else if ([type hasPrefix:@"d"] || [type hasPrefix:@"f"]) {
                            // double / float -> 设1年后时间戳
                            object_setIvar(vm, ivars[i], @([[[NSDate date] dateByAddingTimeInterval:365*24*3600] timeIntervalSince1970]));
                            NSLog(@"[VCAM]     -> set vip timestamp");
                        } else if ([type hasPrefix:@"@"]) {
                            // 对象类型 - 根据 ivar 名判断
                            NSString *lower = name.lowercaseString;
                            if ([lower containsString:@"vip"] || [lower containsString:@"auth"] ||
                                [lower containsString:@"verify"] || [lower containsString:@"active"] ||
                                [lower containsString:@"unlock"] || [lower containsString:@"premium"] ||
                                [lower containsString:@"license"]) {
                                object_setIvar(vm, ivars[i], @YES);
                                NSLog(@"[VCAM]     -> set @YES (VIP相关)");
                            } else if ([lower containsString:@"kami"] || [lower containsString:@"card"] ||
                                       [lower containsString:@"code"]) {
                                object_setIvar(vm, ivars[i], @"VCAM_VIP_ACTIVATED");
                                NSLog(@"[VCAM]     -> set kami string");
                            } else if ([lower containsString:@"expire"] || [lower containsString:@"expir"]) {
                                object_setIvar(vm, ivars[i], [fmt stringFromDate:[[NSDate date] dateByAddingTimeInterval:365*24*3600]]);
                                NSLog(@"[VCAM]     -> set expiry date");
                            } else if ([lower containsString:@"status"]) {
                                object_setIvar(vm, ivars[i], @"active");
                                NSLog(@"[VCAM]     -> set active");
                            }
                        }
                    } @catch (NSException *e) {
                        NSLog(@"[VCAM]     set failed: %@", e);
                    }
                }
                free(ivars);
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
            
            @try {
                UILabel *label = [menuVC valueForKey:@"authStatusLabel"];
                if (label && [label isKindOfClass:[UILabel class]]) {
                    label.text = @"已激活";
                    label.textColor = [UIColor greenColor];
                }
            } @catch (NSException *e) {}
            
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
            
            @try {
                if ([menuVC respondsToSelector:@selector(refreshUIStates)]) {
                    ((void(*)(id, SEL))objc_msgSend)(menuVC, @selector(refreshUIStates));
                }
            } @catch (NSException *e) {}
        } @catch (NSException *e) {}
    });
}

static NSTimer *g_vipTimer = nil;

static void startVIPTimer(void) {
    if (g_vipTimer) return;
    g_vipTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
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
    NSLog(@"[VCAM] === v22 ===");
    
    Class vmClass = objc_getClass("VCamVerifyManager");
    if (vmClass) {
        SEL apiSel = NSSelectorFromString(@"requestAPIWithAction:kami:isHeartbeat:completion:");
        Method apiMethod = class_getInstanceMethod(vmClass, apiSel);
        if (apiMethod) {
            orig_reqAPI = (void *)method_setImplementation(apiMethod, (IMP)h_reqAPI);
            NSLog(@"[VCAM] Hooked OK");
        }
    }
    
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"vcam_vip_unlocked"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            activateVIPUI();
            startVIPTimer();
        });
    }
    
    NSLog(@"[VCAM] Ready");
}
