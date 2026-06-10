/**
 * VCamKamiHook - 完全模仿 vcam_kami(5) 同行方案
 * 只 hook requestAPIWithAction，自己发 POST 到卡密服务器
 * 不碰 URL，不碰 NSURLProtocol
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static void (*orig_requestAPI)(id, SEL, NSString *, NSString *, BOOL, void (^)(NSDictionary *));
static NSTimer *vipTimer = nil;
static NSString *savedExpires = nil;

static void setVIPActive(NSString *expires) {
    if (expires) savedExpires = expires;
    
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"vcam_vip_unlocked"];
    if (savedExpires) {
        [[NSUserDefaults standardUserDefaults] setObject:savedExpires forKey:@"vcam_expires"];
    }
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    @try {
        Class kcClass = objc_getClass("llyKeychain");
        if (kcClass) {
            SEL sel = @selector(setPassword:forService:account:);
            if ([kcClass respondsToSelector:sel]) {
                ((void(*)(id, SEL, id, id, id))objc_msgSend)(kcClass, sel, @"VCAM_VIP_ACTIVATED", @"vcam_kami", @"vcam_kami");
            }
        }
    } @catch (NSException *e) {}
    
    @try {
        Class cls = objc_getClass("VCamVerifyManager");
        if (cls) {
            id vm = [cls performSelector:@selector(sharedInstance)];
            if (vm) {
                unsigned int cnt = 0;
                Ivar *ivs = class_copyIvarList(cls, &cnt);
                for (unsigned int i = 0; i < cnt; i++) {
                    const char *nm = ivar_getName(ivs[i]);
                    const char *tp = ivar_getTypeEncoding(ivs[i]);
                    if (!nm) continue;
                    NSString *n = [NSString stringWithUTF8String:nm];
                    NSString *t = tp ? [NSString stringWithUTF8String:tp] : @"";
                    @try {
                        if ([t hasPrefix:@"c"] || [t hasPrefix:@"B"]) {
                            object_setIvar(vm, ivs[i], @YES);
                        } else if ([t hasPrefix:@"d"] || [t hasPrefix:@"f"]) {
                            object_setIvar(vm, ivs[i], @([[[NSDate date] dateByAddingTimeInterval:365*24*3600] timeIntervalSince1970]));
                        } else if ([t hasPrefix:@"@"]) {
                            NSString *low = n.lowercaseString;
                            if ([low containsString:@"vip"] || [low containsString:@"auth"] || [low containsString:@"verify"] || [low containsString:@"active"] || [low containsString:@"unlock"]) {
                                object_setIvar(vm, ivs[i], @YES);
                            } else if ([low containsString:@"kami"] || [low containsString:@"card"]) {
                                object_setIvar(vm, ivs[i], @"VCAM_VIP_ACTIVATED");
                            } else if ([low containsString:@"expire"]) {
                                object_setIvar(vm, ivs[i], savedExpires ?: @"2099/12/31 23:59:59");
                            } else if ([low containsString:@"status"]) {
                                object_setIvar(vm, ivs[i], @"active");
                            }
                        }
                    } @catch (NSException *e) {}
                }
                free(ivs);
            }
        }
    } @catch (NSException *e) {}
}

static void updateUI(void) {
    UIViewController *vc = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        UIViewController *root = w.rootViewController;
        if (!root) continue;
        UIViewController *p = root;
        while (p.presentedViewController) p = p.presentedViewController;
        if ([p isKindOfClass:NSClassFromString(@"VCamMenuVC")]) { vc = p; break; }
        for (UIViewController *c in root.childViewControllers) {
            if ([c isKindOfClass:NSClassFromString(@"VCamMenuVC")]) { vc = c; break; }
        }
        if (vc) break;
    }
    if (!vc) return;
    
    @try {
        id label = [vc valueForKey:@"authStatusLabel"];
        if (label && [label isKindOfClass:[UILabel class]]) {
            [(UILabel *)label setText:@"已激活"];
            [(UILabel *)label setTextColor:[UIColor greenColor]];
        }
    } @catch (NSException *e) {}
    
    for (NSString *name in @[@"btnLoop", @"btnSound", @"btnRotate", @"btnMirror", @"btnReplacement", @"btnPhotoReplacement"]) {
        @try {
            id btn = [vc valueForKey:name];
            if (btn && [btn isKindOfClass:[UIButton class]]) {
                [(UIButton *)btn setEnabled:YES];
                [(UIButton *)btn setAlpha:1.0];
            }
        } @catch (NSException *e) {}
    }
    
    @try {
        if ([vc respondsToSelector:@selector(refreshUIStates)]) {
            ((void(*)(id, SEL))objc_msgSend)(vc, @selector(refreshUIStates));
        }
    } @catch (NSException *e) {}
    
    @try {
        if ([vc respondsToSelector:@selector(showToast:)]) {
            ((void(*)(id, SEL, id))objc_msgSend)(vc, @selector(showToast:), @"激活成功");
        }
    } @catch (NSException *e) {}
}

static void startTimer(void) {
    if (vipTimer) return;
    vipTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        setVIPActive(nil);
    }];
}

static void h_requestAPI(id self, SEL _cmd,
    NSString *action, NSString *kami, BOOL isHeartbeat,
    void (^completion)(NSDictionary *)) {
    
    NSLog(@"[VCAM] reqAPI: action=%@ kami=%@ hb=%d", action, kami, (int)isHeartbeat);
    
    NSString *deviceId = [[[UIDevice currentDevice] identifierForVendor] UUIDString] ?: @"unknown";
    @try {
        if ([self respondsToSelector:@selector(getDeviceID)]) {
            id r = [self performSelector:@selector(getDeviceID)];
            if ([r isKindOfClass:[NSString class]] && [(NSString *)r length] > 0) deviceId = r;
        }
    } @catch (NSException *e) {}
    
    // POST 请求（同行一模一样格式）
    NSURL *url = [NSURL URLWithString:@"http://124.221.171.80/vcam_api.php"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15.0];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"TrollInstallerX/1.0" forHTTPHeaderField:@"User-Agent"];
    
    NSDictionary *body = @{@"appkey": @"H0U66ETGBFEC", @"card": kami ?: @"", @"device_id": deviceId, @"action": action ?: @"check"};
    [req setHTTPBody:[NSJSONSerialization dataWithJSONObject:body options:0 error:nil]];
    
    [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) {
            if (completion) completion(@{@"code": @(-1), @"msg": [NSString stringWithFormat:@"网络错误: %@", err.localizedDescription]});
            return;
        }
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSLog(@"[VCAM] result: %@", json);
        
        if (json && [json[@"code"] integerValue] == 0) {
            NSString *exp = json[@"data"][@"expires_at"];
            NSString *card = json[@"data"][@"card"];
            savedExpires = exp;
            
            setVIPActive(exp);
            
            if (card && card.length > 0) {
                [[NSUserDefaults standardUserDefaults] setObject:card forKey:@"vcam_verified_kami"];
                [[NSUserDefaults standardUserDefaults] synchronize];
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                updateUI();
                startTimer();
            });
        }
        
        if (completion) completion(json ?: @{@"code": @(-1), @"msg": @"卡密验证失败"});
    }].resume;
    // 注意: .resume 不是 [task resume]，避免和消息混淆
}

__attribute__((constructor))
static void init(void) {
    NSLog(@"[VCAM] === VCamKamiHook ===");
    
    Class cls = objc_getClass("VCamVerifyManager");
    if (cls) {
        Method m = class_getInstanceMethod(cls, NSSelectorFromString(@"requestAPIWithAction:kami:isHeartbeat:completion:"));
        if (m) {
            orig_requestAPI = (void *)method_setImplementation(m, (IMP)h_requestAPI);
            NSLog(@"[VCAM] Hooked requestAPIWithAction");
        }
    }
    
    // 自动恢复
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"vcam_vip_unlocked"]) {
        savedExpires = [[NSUserDefaults standardUserDefaults] stringForKey:@"vcam_expires"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            setVIPActive(nil);
            updateUI();
            startTimer();
        });
    }
    
    NSLog(@"[VCAM] Ready");
}
