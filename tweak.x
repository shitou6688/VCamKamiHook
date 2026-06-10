/**
 * VCamKamiHook v23 - 完全模仿 kami.lengye.top/api/login 格式
 * 
 * 同行成功的方案：
 * - POST https://kami.lengye.top/api/login
 * - Body: {"appkey":"H0U66ETGBFEC","card":"卡密","device_id":"设备ID"}
 * - 返回: {"code":0,"msg":"登录成功","data":{"card":"XXX","card_type":"day","expires_at":"2026/06/12 00:43:36","duration":"1天0小时"}}
 * - 用 expires_at 日期格式存 vcam_expires
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

static void forceVIPActive(NSString *expiresAt) {
    // NSUserDefaults
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:YES forKey:@"vcam_vip_unlocked"];
    if (expiresAt && expiresAt.length > 0) {
        [ud setObject:expiresAt forKey:@"vcam_expires"];
    } else {
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        [fmt setDateFormat:@"yyyy/MM/dd HH:mm:ss"];
        [ud setObject:[fmt stringFromDate:[[NSDate date] dateByAddingTimeInterval:365*24*3600]] forKey:@"vcam_expires"];
    }
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
    
    // VCamVerifyManager - 暴力设所有 ivar
    @try {
        Class vmClass = objc_getClass("VCamVerifyManager");
        if (vmClass) {
            id vm = [vmClass performSelector:@selector(sharedInstance)];
            if (vm) {
                unsigned int count = 0;
                Ivar *ivars = class_copyIvarList(vmClass, &count);
                for (unsigned int i = 0; i < count; i++) {
                    const char *name = ivar_getName(ivars[i]);
                    const char *type = ivar_getTypeEncoding(ivars[i]);
                    if (!name) continue;
                    NSString *n = [NSString stringWithUTF8String:name];
                    NSString *t = type ? [NSString stringWithUTF8String:type] : @"";
                    @try {
                        if ([t hasPrefix:@"c"] || [t hasPrefix:@"B"]) {
                            object_setIvar(vm, ivars[i], @YES);
                        } else if ([t hasPrefix:@"d"] || [t hasPrefix:@"f"]) {
                            object_setIvar(vm, ivars[i], @([[[NSDate date] dateByAddingTimeInterval:365*24*3600] timeIntervalSince1970]));
                        } else if ([t hasPrefix:@"@"]) {
                            NSString *lower = n.lowercaseString;
                            if ([lower containsString:@"vip"] || [lower containsString:@"auth"] || [lower containsString:@"verify"] || [lower containsString:@"active"] || [lower containsString:@"unlock"]) {
                                object_setIvar(vm, ivars[i], @YES);
                            } else if ([lower containsString:@"kami"] || [lower containsString:@"card"]) {
                                object_setIvar(vm, ivars[i], @"VCAM_VIP_ACTIVATED");
                            } else if ([lower containsString:@"expire"] || [lower containsString:@"expir"]) {
                                object_setIvar(vm, ivars[i], expiresAt ?: @"2099/12/31 23:59:59");
                            } else if ([lower containsString:@"status"]) {
                                object_setIvar(vm, ivars[i], @"active");
                            }
                        }
                    } @catch (NSException *e) {}
                }
                free(ivars);
            }
        }
    } @catch (NSException *e) {}
}

static void activateVIPUI(NSString *expiresAt) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            forceVIPActive(expiresAt);
            
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
            
            @try {
                if ([menuVC respondsToSelector:@selector(showToast:)]) {
                    ((void(*)(id, SEL, id))objc_msgSend)(menuVC, @selector(showToast:), @"激活成功");
                }
            } @catch (NSException *e) {}
        } @catch (NSException *e) {}
    });
}

static NSTimer *g_vipTimer = nil;
static NSString *g_expiresAt = nil;

static void startVIPTimer(void) {
    if (g_vipTimer) return;
    g_vipTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
        forceVIPActive(g_expiresAt);
    }];
}

static void h_reqAPI(id self, SEL _cmd,
    NSString *action, NSString *kami, BOOL isHeartbeat,
    void (^completion)(NSDictionary *)) {
    
    NSLog(@"[VCAM] reqAPI: action=%@ kami=%@ heartbeat=%d", action, kami, (int)isHeartbeat);
    
    // 获取设备 ID
    NSString *deviceID = [[[UIDevice currentDevice] identifierForVendor] UUIDString] ?: @"unknown";
    @try {
        if ([self respondsToSelector:@selector(getDeviceID)]) {
            id ret = [self performSelector:@selector(getDeviceID)];
            if ([ret isKindOfClass:[NSString class]] && [(NSString *)ret length] > 0) {
                deviceID = (NSString *)ret;
            }
        }
    } @catch (NSException *e) {}
    
    // POST 请求（同行格式）
    NSURL *url = [NSURL URLWithString:@"http://124.221.171.80/vcam_api.php"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:15.0];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"TrollInstallerX/1.0" forHTTPHeaderField:@"User-Agent"];
    
    // Body - 模仿 kami.lengye.top/api/login 格式
    NSDictionary *body = @{
        @"appkey": @"H0U66ETGBFEC",
        @"card": kami ?: @"",
        @"device_id": deviceID,
        @"action": action ?: @"check"
    };
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [request setHTTPBody:bodyData];
    
    NSLog(@"[VCAM] POST body: %@", body);
    
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
                // 提取 expires_at（同行关键格式）
                NSString *expiresAt = json[@"data"][@"expires_at"];
                NSString *card = json[@"data"][@"card"];
                
                NSLog(@"[VCAM] expires_at=%@ card=%@", expiresAt, card);
                
                g_expiresAt = expiresAt;
                
                if (card && card.length > 0) {
                    [[NSUserDefaults standardUserDefaults] setObject:card forKey:@"vcam_verified_kami"];
                }
                
                activateVIPUI(expiresAt);
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
    NSLog(@"[VCAM] === v23 ===");
    
    Class vmClass = objc_getClass("VCamVerifyManager");
    if (vmClass) {
        SEL apiSel = NSSelectorFromString(@"requestAPIWithAction:kami:isHeartbeat:completion:");
        Method apiMethod = class_getInstanceMethod(vmClass, apiSel);
        if (apiMethod) {
            orig_reqAPI = (void *)method_setImplementation(apiMethod, (IMP)h_reqAPI);
            NSLog(@"[VCAM] Hooked OK");
        }
    }
    
    // 自动激活
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"vcam_vip_unlocked"]) {
        NSString *savedExpires = [[NSUserDefaults standardUserDefaults] stringForKey:@"vcam_expires"];
        g_expiresAt = savedExpires;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            activateVIPUI(savedExpires);
            startVIPTimer();
        });
    }
    
    NSLog(@"[VCAM] Ready");
}
