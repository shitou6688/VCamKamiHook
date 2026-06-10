/**
 * VCamKamiHook v26 - 完整激活版
 * hook requestAPIWithAction + 成功后激活VIP + 记住卡密
 * 完全模仿同行 vcam_kami(5) 的逻辑
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static void (*orig_requestAPI)(id, SEL, NSString *, NSString *, BOOL, void (^)(NSDictionary *));
static NSTimer *vipTimer = nil;

static UIViewController* findMenuVC(void) {
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        UIViewController *root = w.rootViewController;
        if (!root) continue;
        UIViewController *p = root;
        while (p.presentedViewController) p = p.presentedViewController;
        if ([p isKindOfClass:NSClassFromString(@"VCamMenuVC")]) return p;
        for (UIViewController *c in root.childViewControllers) {
            if ([c isKindOfClass:NSClassFromString(@"VCamMenuVC")]) return c;
        }
    }
    return nil;
}

static void activateVIP(NSString *kami) {
    // NSUserDefaults
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:YES forKey:@"vcam_vip_unlocked"];
    if (kami && kami.length > 0) {
        [ud setObject:kami forKey:@"vcam_verified_kami"];
        [ud setObject:kami forKey:@"vcam_saved_kami"];
    }
    [ud synchronize];
    
    // Keychain
    @try {
        Class kcClass = objc_getClass("llyKeychain");
        if (kcClass) {
            SEL sel = @selector(setPassword:forService:account:);
            if ([kcClass respondsToSelector:sel]) {
                ((void(*)(id, SEL, id, id, id))objc_msgSend)(kcClass, sel, kami ?: @"VIP", @"vcam_kami", @"vcam_kami");
            }
        }
    } @catch (NSException *e) {}
    
    // UI
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = findMenuVC();
        if (!vc) return;
        
        @try {
            UILabel *label = [vc valueForKey:@"authStatusLabel"];
            if (label && [label isKindOfClass:[UILabel class]]) {
                label.text = @"已激活";
                label.textColor = [UIColor greenColor];
            }
        } @catch (NSException *e) {}
        
        for (NSString *name in @[@"btnLoop", @"btnSound", @"btnRotate", @"btnMirror", @"btnReplacement", @"btnPhotoReplacement"]) {
            @try {
                UIButton *btn = [vc valueForKey:name];
                if (btn && [btn isKindOfClass:[UIButton class]]) {
                    btn.enabled = YES;
                    btn.alpha = 1.0;
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
    });
}

static void startVIPTimer(void) {
    if (vipTimer) return;
    vipTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"vcam_vip_unlocked"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }];
}

static void h_requestAPI(id self, SEL _cmd,
    NSString *action, NSString *kami, BOOL isHeartbeat,
    void (^completion)(NSDictionary *)) {
    
    // 没卡密就用上次保存的
    NSString *useKami = kami;
    if (!useKami || useKami.length == 0) {
        useKami = [[NSUserDefaults standardUserDefaults] stringForKey:@"vcam_saved_kami"];
    }
    
    NSLog(@"[VCAM] reqAPI: action=%@ kami=%@ saved=%@ hb=%d", action, kami, useKami, (int)isHeartbeat);
    
    NSString *deviceId = [[[UIDevice currentDevice] identifierForVendor] UUIDString] ?: @"unknown";
    @try {
        if ([self respondsToSelector:@selector(getDeviceID)]) {
            id r = [self performSelector:@selector(getDeviceID)];
            if ([r isKindOfClass:[NSString class]] && [(NSString *)r length] > 0) deviceId = r;
        }
    } @catch (NSException *e) {}
    
    // POST
    NSURL *url = [NSURL URLWithString:@"http://124.221.171.80/vc.php"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:15.0];
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
            if (!card || card.length == 0) card = useKami;
            
            // 保存卡密
            [[NSUserDefaults standardUserDefaults] setObject:card forKey:@"vcam_saved_kami"];
            [[NSUserDefaults standardUserDefaults] synchronize];
            
            // 激活 VIP
            activateVIP(card);
            
            dispatch_async(dispatch_get_main_queue(), ^{
                startVIPTimer();
            });
            
            NSLog(@"[VCAM] VIP fully unlocked");
        }
        
        if (completion) completion(json ?: @{@"code": @(-1), @"msg": @"验证失败"});
    }].resume;
}

__attribute__((constructor))
static void init(void) {
    NSLog(@"[VCAM] === v26 ===");
    
    Class cls = objc_getClass("VCamVerifyManager");
    if (cls) {
        Method m = class_getInstanceMethod(cls, NSSelectorFromString(@"requestAPIWithAction:kami:isHeartbeat:completion:"));
        if (m) {
            orig_requestAPI = (void *)method_setImplementation(m, (IMP)h_requestAPI);
            NSLog(@"[VCAM] Hooked OK");
        }
    }
    
    // 自动恢复
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"vcam_vip_unlocked"]) {
        NSString *savedKami = [[NSUserDefaults standardUserDefaults] stringForKey:@"vcam_saved_kami"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            activateVIP(savedKami);
            startVIPTimer();
        });
        NSLog(@"[VCAM] Auto-restored VIP");
    }
}
