/**
 * VCamKamiHook v5 - 将 VCAM 卡密验证对接到自有服务器
 * 
 * 核心策略：不找 VC 实例，而是 hook VCAM 自己的 UI 刷新方法，
 * 在它尝试更新授权状态时强制覆盖为"已授权"
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>

#pragma mark - 配置

static NSString *const kAPIBase = @"http://124.221.171.80";
static NSString *const kAppID   = @"10003";

#pragma mark - 原方法指针

static void (*orig_requestAPI)(id, SEL, NSString *, NSString *, BOOL, void (^)(NSDictionary *)) = NULL;
static void (*orig_verifyAndProceed)(id, SEL, id) = NULL;
static void (*orig_refreshUIStates)(id, SEL) = NULL;
static void (*orig_setAuthStatusLabel)(id, SEL, id) = NULL;
static void (*orig_setBtnSound)(id, SEL, id) = NULL;

#pragma mark - 设备标识

static NSString *getDeviceID(void) {
    return [[UIDevice currentDevice].identifierForVendor UUIDString] ?: @"unknown";
}

#pragma mark - 设备注册

static void registerDevice(NSString *kami, NSString *markcode) {
    size_t size = 0;
    sysctlbyname("hw.machine", NULL, &size, NULL, 0);
    NSString *model = @"unknown";
    if (size > 0) {
        char *buf = (char *)malloc(size);
        sysctlbyname("hw.machine", buf, &size, NULL, 0);
        model = [NSString stringWithUTF8String:buf];
        free(buf);
    }
    NSString *url = [NSString stringWithFormat:
        @"%@/trollstore-device-api.php?api=ts_register&serial=&markcode=%@&kami=%@&model=%@&ios=%@",
        kAPIBase,
        [markcode stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
        [kami stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
        [model stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
        [[UIDevice currentDevice] systemVersion] ?: @"unknown"];

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 10;
    NSURLSession *sess = [NSURLSession sessionWithConfiguration:cfg];
    NSURLSessionDataTask *task = [sess dataTaskWithURL:[NSURL URLWithString:url]
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            NSLog(@"[VCAM] 注册: %@", e ? @"失败" : @"已发送");
        }];
    [task resume];
}

#pragma mark - 检查过期

static BOOL isVIPExpired(void) {
    NSString *exp = [[NSUserDefaults standardUserDefaults] stringForKey:@"vcam_expires"];
    if (!exp) return YES;
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy/MM/dd HH:mm:ss";
    NSDate *date = [fmt dateFromString:exp];
    return !date || [date timeIntervalSinceNow] <= 0;
}

#pragma mark - 保存 VIP

static void saveVIPState(NSString *kami) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:kami forKey:@"vcam_kami"];
    [d setObject:kami forKey:@"vcam_verified_kami"];
    [d setBool:YES forKey:@"vcam_vip_unlocked"];
    [d synchronize];

    Class kc = objc_getClass("llyKeychain");
    if (kc && [kc respondsToSelector:@selector(setPassword:forService:account:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [kc performSelector:@selector(setPassword:forService:account:) withObject:kami withObject:@"vcam_kami"];
        [kc performSelector:@selector(setPassword:forService:account:) withObject:kami withObject:@"appkey"];
#pragma clang diagnostic pop
    }
}

#pragma mark - 强制解锁（在主线程操作当前可见的 UI）

static void forceUnlockUI(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIApplication *app = [UIApplication sharedApplication];
            for (UIWindow *window in app.windows) {
                // 遍历所有 UILabel，找到包含"未授权"/"授权"文字的 label
                void (^fixLabels)(UIView *) = ^(UIView *view) {
                    if ([view isKindOfClass:[UILabel class]]) {
                        UILabel *label = (UILabel *)view;
                        NSString *text = label.text;
                        if (text && ([text containsString:@"未授权"] || [text containsString:@"未激活"] ||
                            [text containsString:@"需要授权"] || [text containsString:@"unauthorized"] ||
                            [text containsString:@"expire"])) {
                            label.text = @"✅ 已授权 - 所有功能已解锁";
                            label.textColor = [UIColor greenColor];
                            NSLog(@"[VCAM] Label fixed: '%@' -> '已授权'", text);
                        }
                    }
                    // 递归子视图
                    for (UIView *sub in view.subviews) {
                        fixLabels(sub);
                    }
                };

                // 遍历所有 UIButton，全部启用
                void (^fixButtons)(UIView *) = ^(UIView *view) {
                    if ([view isKindOfClass:[UIButton class]]) {
                        UIButton *btn = (UIButton *)view;
                        btn.enabled = YES;
                        btn.alpha = 1.0;
                    }
                    for (UIView *sub in view.subviews) {
                        fixButtons(sub);
                    }
                };

                UIViewController *rootVC = window.rootViewController;
                if (rootVC && rootVC.view) {
                    fixLabels(rootVC.view);
                    fixButtons(rootVC.view);
                }

                // 也处理 presented VC
                UIViewController *presented = nil;
                while ((presented = rootVC.presentedViewController)) {
                    if (presented.view) {
                        fixLabels(presented.view);
                        fixButtons(presented.view);
                    }
                    rootVC = presented;
                }
            }
        } @catch (NSException *e) {
            NSLog(@"[VCAM] forceUnlockUI err: %@", e);
        }
    });
}

#pragma mark - Hook: setAuthStatusLabel: （拦截 VCAM 设置授权状态文字）

static void h_setAuthStatusLabel(id self, SEL _cmd, id label) {
    NSLog(@"[VCAM] setAuthStatusLabel intercepted: %@", label);

    // 调用原始方法先让 VCAM 正常设置
    if (orig_setAuthStatusLabel) {
        orig_setAuthStatusLabel(self, _cmd, label);
    }

    // 然后立即覆盖为已授权
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if ([self respondsToSelector:@selector(setText:)]) {
                [self performSelector:@selector(setText:) withObject:@"✅ 已授权 - 所有功能已解锁"];
            }
            if ([self respondsToSelector:@selector(setTextColor:)]) {
                [self performSelector:@selector(setTextColor:) withObject:[UIColor greenColor]];
            }
        } @catch (NSException *e) { }
    });
}

#pragma mark - Hook: setBtnSound: （拦截设置声音按钮）

static void h_setBtnSound(id self, SEL _cmd, id btn) {
    if (orig_setBtnSound) orig_setBtnSound(self, _cmd, btn);
    // 确保按钮始终启用
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if ([btn respondsToSelector:@selector(setEnabled:)]) {
                [btn performSelector:@selector(setEnabled:) withObject:@YES];
            }
            if ([btn respondsToSelector:@selector(setAlpha:)]) {
                [btn performSelector:@selector(setAlpha:) withObject:@(1.0)];
            }
        } @catch (NSException *e) { }
    });
}

#pragma mark - Hook: refreshUIStates （拦截 UI 刷新）

static void h_refreshUIStates(id self, SEL _cmd) {
    NSLog(@"[VCAM] refreshUIStates intercepted");

    // 先调原始方法
    if (orig_refreshUIStates) orig_refreshUIStates(self, _cmd);

    // 然后强制覆盖
    forceUnlockUI();
}

#pragma mark - VIP 解锁

static void unlockVIP(NSString *kami) {
    NSLog(@"[VCAM] VIP fully unlocked");
    saveVIPState(kami);
    forceUnlockUI();

    // 也设 VCamVerifyManager 内部状态
    Class vmClass = objc_getClass("VCamVerifyManager");
    if (vmClass && [vmClass respondsToSelector:@selector(sharedInstance)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id vm = [vmClass performSelector:@selector(sharedInstance)];
#pragma clang diagnostic pop
        if (vm) {
            @try { [vm setValue:kami forKey:@"use_kami"]; } @catch (NSException *e) { }
            @try { [vm setValue:kami forKeyPath:@"appkey"]; } @catch (NSException *e) { }
        }
    }

    // showToast
    if (vmClass && [vmClass respondsToSelector:@selector(sharedInstance)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id mgr = [vmClass performSelector:@selector(sharedInstance)];
#pragma clang diagnostic pop
        if (mgr && [mgr respondsToSelector:@selector(showToast:)]) {
            [mgr performSelector:@selector(showToast:) withObject:@"✅ VIP 已激活"];
        }
    }
}

#pragma mark - Hook: requestAPIWithAction:kami:isHeartbeat:completion:

static void h_requestAPI(id self, SEL _cmd,
    NSString *action, NSString *kami, BOOL isHeartbeat,
    void (^completion)(NSDictionary *result)) {

    NSLog(@"[VCAM] Intercepted: action=%@, kami=%@, heartbeat=%d", action, kami, isHeartbeat);

    if (isHeartbeat) {
        if (!isVIPExpired()) {
            NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
            NSString *k = [d stringForKey:@"vcam_verified_kami"];
            NSLog(@"[VCAM] Heartbeat: VIP valid");
            unlockVIP(k);
            if (completion) completion(@{@"code": @(1), @"msg": @"验证成功", @"data": @{@"kami": k ?: @"", @"vip": @"4102243200"}});
            return;
        }
        NSLog(@"[VCAM] Heartbeat: card invalid, VIP locked");
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"vcam_vip_unlocked"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }

    if (!kami || kami.length == 0) {
        NSLog(@"[VCAM] No kami provided");
        if (completion) completion(@{@"code": @(-1), @"msg": @"请输入卡密"});
        return;
    }

    NSString *deviceID = getDeviceID();
    NSString *verifyURL = [NSString stringWithFormat:
        @"%@/api.php?api=kmlogon&app=%@&kami=%@&markcode=%@",
        kAPIBase, kAppID,
        [kami stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
        [deviceID stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:verifyURL]
                                                         cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                     timeoutInterval:15];
    [req setHTTPMethod:@"GET"];

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 15;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {

        if (error) {
            NSLog(@"[VCAM] Network error: %@", error.localizedDescription);
            if (completion) completion(@{@"code": @(-1), @"msg": @"网络连接失败"});
            return;
        }
        if (!data) {
            if (completion) completion(@{@"code": @(-1), @"msg": @"服务器无响应"});
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (!json) {
            NSLog(@"[VCAM] JSON parse error");
            if (completion) completion(@{@"code": @(-1), @"msg": @"服务器响应格式错误"});
            return;
        }

        NSInteger code = [json[@"code"] integerValue];
        id msgObj = json[@"msg"];
        NSString *vip = @"";
        if ([msgObj isKindOfClass:[NSDictionary class]]) vip = msgObj[@"vip"] ?: @"4102243200";

        NSLog(@"[VCAM] Response: code=%ld", (long)code);

        if (code == 200) {
            registerDevice(kami, deviceID);
            unlockVIP(kami);
            if (completion) completion(@{@"code": @(1), @"msg": @"验证成功", @"data": @{@"kami": kami, @"vip": vip}});
        } else {
            NSString *msg = [msgObj isKindOfClass:[NSString class]] ? msgObj : @"验证失败";
            if (completion) completion(@{@"code": @(-1), @"msg": msg});
        }
    }];
    [task resume];
}

#pragma mark - Hook: verifyAndProceed:

static void h_verifyAndProceed(id self, SEL _cmd, id caller) {
    NSLog(@"[VCAM] verifyAndProceed: VIP unlocked, proceeding");
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *kami = [d stringForKey:@"vcam_verified_kami"];
    if (kami && !isVIPExpired()) {
        unlockVIP(kami);
    } else if (orig_verifyAndProceed) {
        orig_verifyAndProceed(self, _cmd, caller);
    }
}

#pragma mark - 定时器（持续强制解锁）

static NSTimer *vipTimer = nil;

static void startTimer(void) {
    if (vipTimer) return;
    vipTimer = [NSTimer scheduledTimerWithTimeInterval:10.0 repeats:YES block:^(NSTimer *t) {
        if (!isVIPExpired()) {
            // 每 10 秒强制刷新一次 UI（对抗 VCAM 自己的重置）
            forceUnlockUI();
        }
        NSString *k = [[NSUserDefaults standardUserDefaults] stringForKey:@"vcam_verified_kami"];
        if (k && isVIPExpired()) {
            NSLog(@"[VCAM] Auto-restored VIP");
            unlockVIP(k);
        }
    }];
    NSLog(@"[VCAM] Force-unlock timer started (10s)");
}

#pragma mark - 初始化

__attribute__((constructor))
static void vcam_kami_init(void) {
    NSLog(@"[VCAM] === VCAM Kami Hook ===");

    // ======== Hook VCamVerifyManager 方法 ========
    void (^hookVerifyManager)(void) = ^{
        Class cls = objc_getClass("VCamVerifyManager");
        if (!cls) { NSLog(@"[VCAM] VCamVerifyManager not found"); return; }

        // requestAPIWithAction:kami:isHeartbeat:completion:
        SEL sel1 = NSSelectorFromString(@"requestAPIWithAction:kami:isHeartbeat:completion:");
        Method m1 = class_getInstanceMethod(cls, sel1);
        if (m1) {
            orig_requestAPI = (void *)method_setImplementation(m1, (IMP)h_requestAPI);
            NSLog(@"[VCAM] Hooked requestAPIWithAction:kami:isHeartbeat:completion:");
        }

        // verifyAndProceed:
        SEL sel2 = NSSelectorFromString(@"verifyAndProceed:");
        Method m2 = class_getInstanceMethod(cls, sel2);
        if (m2) {
            orig_verifyAndProceed = (void *)method_setImplementation(m2, (IMP)h_verifyAndProceed);
            NSLog(@"[VCAM] Hooked verifyAndProceed:");
        }
    };

    // ======== Hook VCamMenuVC 方法 ========
    void (^hookMenuVC)(void) = ^{
        Class cls = objc_getClass("VCamMenuVC");
        if (!cls) { NSLog(@"[VCAM] VCamMenuVC not found"); return; }

        // refreshUIStates
        SEL sel3 = NSSelectorFromString(@"refreshUIStates");
        Method m3 = class_getInstanceMethod(cls, sel3);
        if (m3) {
            orig_refreshUIStates = (void *)method_setImplementation(m3, (IMP)h_refreshUIStates);
            NSLog(@"[VCAM] Hooked refreshUIStates");
        }

        // setAuthStatusLabel:
        SEL sel4 = NSSelectorFromString(@"setAuthStatusLabel:");
        Method m4 = class_getInstanceMethod(cls, sel4);
        if (m4) {
            orig_setAuthStatusLabel = (void *)method_setImplementation(m4, (IMP)h_setAuthStatusLabel);
            NSLog(@"[VCAM] Hooked setAuthStatusLabel:");
        }

        // setBtnSound:
        SEL sel5 = NSSelectorFromString(@"setBtnSound:");
        Method m5 = class_getInstanceMethod(cls, sel5);
        if (m5) {
            orig_setBtnSound = (void *)method_setImplementation(m5, (IMP)h_setBtnSound);
            NSLog(@"[VCAM] Hooked setBtnSound:");
        }
    };

    // 延迟等待类加载
    Class verifyCls = objc_getClass("VCamVerifyManager");
    Class menuCls = objc_getClass("VCamMenuVC");

    if (verifyCls) hookVerifyManager();
    if (menuCls) hookMenuVC();

    if (!verifyCls || !menuCls) {
        void (^checkBlock)(void);
        __weak typeof(checkBlock) weakCheck;
        checkBlock = ^{
            BOOL done = YES;
            if (!objc_getClass("VCamVerifyManager")) { hookVerifyManager(); done = NO; }
            if (!objc_getClass("VCamMenuVC")) { hookMenuVC(); done = NO; }
            if (done) {
                NSLog(@"[VCAM Kami Hook] Ready");
            } else {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), weakCheck);
            }
        };
        weakCheck = checkBlock;
        dispatch_async(dispatch_get_main_queue(), checkBlock);
    }

    // 自动恢复 + 启动定时器
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"vcam_vip_unlocked"] && !isVIPExpired()) {
        NSString *kami = [[NSUserDefaults standardUserDefaults] stringForKey:@"vcam_verified_kami"];
        NSLog(@"[VCAM] Auto-restored VIP");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            unlockVIP(kami);
            startTimer();
        });
    }

    NSLog(@"[VCAM Kami Hook] Ready");
}
