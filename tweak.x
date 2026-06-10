/**
 * VCamKamiHook v29 - URL 重定向 + 强制 VIP
 * 
 * 1. hook NSURL +URLWithString: 重定向到我们服务器
 * 2. hook NSUserDefaults 强制返回 VIP
 * 3. hook presentViewController 拦截未授权弹窗
 * 4. 定时器持续刷新 ivars
 * 5. 卡密验证 + 记忆
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - URL 重定向

static NSURL* (*orig_URLWithString)(id, SEL, NSString *);
static NSURL* (*orig_URLWithStrRel)(id, SEL, NSString *, NSURL *);

static NSString* redirectURL(NSString *urlStr) {
    if (!urlStr || ![urlStr isKindOfClass:[NSString class]]) return urlStr;
    if ([urlStr containsString:@"xnsp.v200dd.eu.org"]) {
        NSString *newStr = [urlStr stringByReplacingOccurrencesOfString:@"https://yz.xnsp.v200dd.eu.org/api.php" withString:@"http://124.221.171.80/vc.php"];
        if ([newStr containsString:@"xnsp.v200dd.eu.org"]) {
            newStr = [newStr stringByReplacingOccurrencesOfString:@"https://yz.xnsp.v200dd.eu.org" withString:@"http://124.221.171.80"];
            newStr = [newStr stringByReplacingOccurrencesOfString:@"xnsp.v200dd.eu.org" withString:@"124.221.171.80"];
            newStr = [newStr stringByReplacingOccurrencesOfString:@"https://124.221.171.80" withString:@"http://124.221.171.80"];
        }
        NSLog(@"[VCAM] redirect: %@ -> %@", urlStr, newStr);
        return newStr;
    }
    if ([urlStr containsString:@"lengye.top"]) {
        NSString *newStr = [urlStr stringByReplacingOccurrencesOfString:@"https://yz.lengye.top/api.php" withString:@"http://124.221.171.80/vc.php"];
        if ([newStr containsString:@"lengye.top"]) {
            newStr = [newStr stringByReplacingOccurrencesOfString:@"lengye.top" withString:@"124.221.171.80"];
            newStr = [newStr stringByReplacingOccurrencesOfString:@"https://124.221.171.80" withString:@"http://124.221.171.80"];
        }
        NSLog(@"[VCAM] redirect: %@ -> %@", urlStr, newStr);
        return newStr;
    }
    return urlStr;
}

static NSURL* h_URLWithString(id self, SEL _cmd, NSString *urlStr) {
    return orig_URLWithString(self, _cmd, redirectURL(urlStr));
}

static NSURL* h_URLWithStrRel(id self, SEL _cmd, NSString *urlStr, NSURL *baseURL) {
    return orig_URLWithStrRel(self, _cmd, redirectURL(urlStr), baseURL);
}

#pragma mark - Hook NSUserDefaults

static BOOL (*orig_boolForKey)(id, SEL, NSString *);
static id (*orig_objectForKey)(id, SEL, NSString *);

static BOOL h_boolForKey(id self, SEL _cmd, NSString *key) {
    if (key && ([key isEqualToString:@"vcam_vip_unlocked"] ||
                [key isEqualToString:@"isVIP"] || [key isEqualToString:@"isVip"] ||
                [key isEqualToString:@"vipActivated"] ||
                [key isEqualToString:@"isAuthorized"] || [key isEqualToString:@"isVerified"])) {
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

#pragma mark - Hook requestAPI（卡密记忆）

static void (*orig_reqAPI)(id, SEL, NSString *, NSString *, BOOL, void (^)(NSDictionary *));

static void h_reqAPI(id self, SEL _cmd, NSString *action, NSString *kami, BOOL isHeartbeat, void (^completion)(NSDictionary *)) {
    NSString *useKami = kami;
    if (!useKami || useKami.length == 0) {
        useKami = [[NSUserDefaults standardUserDefaults] stringForKey:@"vcam_saved_kami"];
    }
    
    // 调原始方法（URL 会被重定向到我们服务器）
    orig_reqAPI(self, _cmd, action, useKami, isHeartbeat, ^(NSDictionary *result) {
        NSLog(@"[VCAM] API result: %@", result);
        
        if (result && [result[@"code"] integerValue] == 0) {
            NSString *card = result[@"data"][@"card"];
            if (card && card.length > 0) {
                [[NSUserDefaults standardUserDefaults] setObject:card forKey:@"vcam_saved_kami"];
                [[NSUserDefaults standardUserDefaults] synchronize];
            }
        }
        
        if (completion) completion(result);
    });
}

#pragma mark - 拦截弹窗

static void (*orig_presentVC)(id, SEL, id, BOOL, id);

static void h_presentVC(id self, SEL _cmd, id vc, BOOL animated, id completion) {
    NSString *vcClass = NSStringFromClass([vc class]);
    if ([vcClass containsString:@"Alert"] || [vcClass containsString:@"auth"] || [vcClass containsString:@"Auth"]) {
        NSLog(@"[VCAM] blocked popup: %@", vcClass);
        return;
    }
    orig_presentVC(self, _cmd, vc, animated, completion);
}

#pragma mark - 强制 ivars

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
                    if ([low containsString:@"vip"] || [low containsString:@"auth"] || [low containsString:@"verify"] ||
                        [low containsString:@"active"] || [low containsString:@"unlock"] || [low containsString:@"premium"]) {
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

#pragma mark - UI 强制

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
    NSLog(@"[VCAM] === v29 URL redirect + force VIP ===");
    
    // 1. URL 重定向
    Class nsurlClass = [NSURL class];
    Method m1 = class_getClassMethod(nsurlClass, @selector(URLWithString:));
    if (m1) orig_URLWithString = (void *)method_setImplementation(m1, (IMP)h_URLWithString);
    Method m2 = class_getClassMethod(nsurlClass, @selector(URLWithString:relativeToURL:));
    if (m2) orig_URLWithStrRel = (void *)method_setImplementation(m2, (IMP)h_URLWithStrRel);
    NSLog(@"[VCAM] Hooked NSURL");
    
    // 2. NSUserDefaults
    Class udClass = [NSUserDefaults class];
    Method bm = class_getInstanceMethod(udClass, @selector(boolForKey:));
    if (bm) orig_boolForKey = (void *)method_setImplementation(bm, (IMP)h_boolForKey);
    Method om = class_getInstanceMethod(udClass, @selector(objectForKey:));
    if (om) orig_objectForKey = (void *)method_setImplementation(om, (IMP)h_objectForKey);
    NSLog(@"[VCAM] Hooked NSUserDefaults");
    
    // 3. requestAPIWithAction（卡密记忆 + 拦截结果）
    Class vmClass = objc_getClass("VCamVerifyManager");
    if (vmClass) {
        Method m = class_getInstanceMethod(vmClass, NSSelectorFromString(@"requestAPIWithAction:kami:isHeartbeat:completion:"));
        if (m) orig_reqAPI = (void *)method_setImplementation(m, (IMP)h_reqAPI);
    }
    NSLog(@"[VCAM] Hooked requestAPI");
    
    // 4. presentViewController
    Method pm = class_getInstanceMethod([UIViewController class], @selector(presentViewController:animated:completion:));
    if (pm) orig_presentVC = (void *)method_setImplementation(pm, (IMP)h_presentVC);
    NSLog(@"[VCAM] Hooked presentViewController");
    
    // 5. 预设
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"vcam_vip_unlocked"];
    [[NSUserDefaults standardUserDefaults] setObject:@"2099/12/31 23:59:59" forKey:@"vcam_expires"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    // 6. 延迟启动
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        forceIvars();
        forceUI();
        startTimer();
    });
    
    NSLog(@"[VCAM] Ready");
}
