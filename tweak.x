/**
 * VCamKamiHook v27 - v24 强制VIP + 卡密记忆
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static void (*orig_boolForKey)(id, SEL, NSString *);
static id (*orig_objectForKey)(id, SEL, NSString *);
static void (*orig_reqAPI)(id, SEL, NSString *, NSString *, BOOL, void (^)(NSDictionary *));
static void (*orig_presentVC)(id, SEL, id, BOOL, id);

#pragma mark - Hook NSUserDefaults（强制返回VIP）

static BOOL h_boolForKey(id self, SEL _cmd, NSString *key) {
    if (key && ([key isEqualToString:@"vcam_vip_unlocked"] ||
                [key isEqualToString:@"isVIP"] ||
                [key isEqualToString:@"isVip"] ||
                [key isEqualToString:@"vipActivated"] ||
                [key isEqualToString:@"isAuthorized"] ||
                [key isEqualToString:@"isVerified"])) {
        return YES;
    }
    return orig_boolForKey(self, _cmd, key);
}

static id h_objectForKey(id self, SEL _cmd, NSString *key) {
    if (key) {
        if ([key isEqualToString:@"vcam_vip_unlocked"]) return @YES;
        if ([key isEqualToString:@"vcam_expires"]) return @"2099/12/31 23:59:59";
        if ([key isEqualToString:@"vcam_verified_kami"]) return @"VIP_ACTIVATED";
    }
    return orig_objectForKey(self, _cmd, key);
}

#pragma mark - Hook requestAPI（卡密验证 + 记忆）

static void h_reqAPI(id self, SEL _cmd,
    NSString *action, NSString *kami, BOOL isHeartbeat,
    void (^completion)(NSDictionary *)) {
    
    // 没卡密用保存的
    NSString *useKami = kami;
    if (!useKami || useKami.length == 0) {
        useKami = [[NSUserDefaults standardUserDefaults] stringForKey:@"vcam_saved_kami"];
    }
    
    NSLog(@"[VCAM] reqAPI: action=%@ kami=%@ saved=%@ hb=%d", action, kami, useKami, (int)isHeartbeat);
    
    // 如果没卡密也不需要验证，直接返回成功（v24 逻辑）
    if (!useKami || useKami.length == 0) {
        if (completion) completion(@{@"code": @0, @"msg": @"ok", @"data": @{@"card": @"VIP", @"card_type": @"day", @"expires_at": @"2099/12/31 23:59:59", @"duration": @"365天0小时"}});
        return;
    }
    
    // 有卡密，验证
    NSString *deviceId = [[[UIDevice currentDevice] identifierForVendor] UUIDString] ?: @"unknown";
    @try {
        if ([self respondsToSelector:@selector(getDeviceID)]) {
            id r = [self performSelector:@selector(getDeviceID)];
            if ([r isKindOfClass:[NSString class]] && [(NSString *)r length] > 0) deviceId = r;
        }
    } @catch (NSException *e) {}
    
    NSURL *url = [NSURL URLWithString:@"http://124.221.171.80/vc.php"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15.0];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"TrollInstallerX/1.0" forHTTPHeaderField:@"User-Agent"];
    
    NSDictionary *body = @{@"appkey": @"H0U66ETGBFEC", @"card": useKami ?: @"", @"device_id": deviceId};
    [req setHTTPBody:[NSJSONSerialization dataWithJSONObject:body options:0 error:nil]];
    
    [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) {
            NSLog(@"[VCAM] error: %@", err.localizedDescription);
            if (completion) completion(@{@"code": @(-1), @"msg": [NSString stringWithFormat:@"网络错误: %@", err.localizedDescription]});
            return;
        }
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSLog(@"[VCAM] result: %@", json);
        
        if (json && [json[@"code"] integerValue] == 0) {
            NSString *card = json[@"data"][@"card"];
            if (card && card.length > 0) {
                [[NSUserDefaults standardUserDefaults] setObject:card forKey:@"vcam_saved_kami"];
                [[NSUserDefaults standardUserDefaults] synchronize];
            }
        }
        
        if (completion) completion(json ?: @{@"code": @(-1), @"msg": @"验证失败"});
    }].resume;
}

#pragma mark - 拦截弹窗

static void h_presentVC(id self, SEL _cmd, id vc, BOOL animated, id completion) {
    NSString *vcClass = NSStringFromClass([vc class]);
    if ([vcClass containsString:@"Alert"] || [vcClass containsString:@"auth"] || [vcClass containsString:@"Auth"]) {
        NSLog(@"[VCAM] blocked popup: %@", vcClass);
        return;
    }
    orig_presentVC(self, _cmd, vc, animated, completion);
}

#pragma mark - 强制 ivars + UI

static void forceIvars(void) {
    @try {
        Class cls = objc_getClass("VCamVerifyManager");
        if (!cls) return;
        id vm = [cls performSelector:@selector(sharedInstance)];
        if (!vm) return;
        
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
                    if ([low containsString:@"vip"] || [low containsString:@"auth"] || [low containsString:@"verify"] || [low containsString:@"active"] || [low containsString:@"unlock"] || [low containsString:@"premium"]) {
                        object_setIvar(vm, ivs[i], @YES);
                    } else if ([low containsString:@"kami"] || [low containsString:@"card"]) {
                        object_setIvar(vm, ivs[i], @"VIP_ACTIVATED");
                    } else if ([low containsString:@"expire"]) {
                        object_setIvar(vm, ivs[i], @"2099/12/31 23:59:59");
                    } else if ([low containsString:@"status"]) {
                        object_setIvar(vm, ivs[i], @"active");
                    }
                }
            } @catch (NSException *e) {}
        }
        free(ivs);
    } @catch (NSException *e) {}
}

static void forceUI(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                UIViewController *root = w.rootViewController;
                if (!root) continue;
                UIViewController *p = root;
                while (p.presentedViewController) p = p.presentedViewController;
                UIViewController *menuVC = nil;
                if ([p isKindOfClass:NSClassFromString(@"VCamMenuVC")]) menuVC = p;
                if (!menuVC) {
                    for (UIViewController *c in root.childViewControllers) {
                        if ([c isKindOfClass:NSClassFromString(@"VCamMenuVC")]) { menuVC = c; break; }
                    }
                }
                if (!menuVC) continue;
                
                @try {
                    UILabel *label = [menuVC valueForKey:@"authStatusLabel"];
                    if (label && [label isKindOfClass:[UILabel class]]) {
                        label.text = @"已激活";
                        label.textColor = [UIColor greenColor];
                    }
                } @catch (NSException *e) {}
                
                for (NSString *name in @[@"btnLoop", @"btnSound", @"btnRotate", @"btnMirror", @"btnReplacement", @"btnPhotoReplacement"]) {
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
                break;
            }
        } @catch (NSException *e) {}
    });
}

#pragma mark - Timer

static NSTimer *timer = nil;
static void startTimer(void) {
    if (timer) return;
    timer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        forceIvars();
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"vcam_vip_unlocked"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }];
}

#pragma mark - Init

__attribute__((constructor))
static void init(void) {
    NSLog(@"[VCAM] === v27 force VIP + kami save ===");
    
    // Hook NSUserDefaults
    Class udClass = [NSUserDefaults class];
    Method bm = class_getInstanceMethod(udClass, @selector(boolForKey:));
    if (bm) orig_boolForKey = (void *)method_setImplementation(bm, (IMP)h_boolForKey);
    Method om = class_getInstanceMethod(udClass, @selector(objectForKey:));
    if (om) orig_objectForKey = (void *)method_setImplementation(om, (IMP)h_objectForKey);
    
    // Hook requestAPIWithAction
    Class vmClass = objc_getClass("VCamVerifyManager");
    if (vmClass) {
        Method m = class_getInstanceMethod(vmClass, NSSelectorFromString(@"requestAPIWithAction:kami:isHeartbeat:completion:"));
        if (m) orig_reqAPI = (void *)method_setImplementation(m, (IMP)h_reqAPI);
    }
    
    // Hook presentViewController
    Method pm = class_getInstanceMethod([UIViewController class], @selector(presentViewController:animated:completion:));
    if (pm) orig_presentVC = (void *)method_setImplementation(pm, (IMP)h_presentVC);
    
    // 预设
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"vcam_vip_unlocked"];
    [[NSUserDefaults standardUserDefaults] setObject:@"2099/12/31 23:59:59" forKey:@"vcam_expires"];
    [[NSUserDefaults standardUserDefaults] setObject:@"VIP_ACTIVATED" forKey:@"vcam_verified_kami"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    // 延迟启动
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        forceIvars();
        forceUI();
        startTimer();
    });
    
    NSLog(@"[VCAM] Ready");
}
