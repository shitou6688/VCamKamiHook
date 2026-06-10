/**
 * VCamKamiHook - 将 VCAM 卡密验证对接到自有服务器
 * 1:1 复刻原始 vcam_kami dylib 行为，替换验证服务器
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>

#pragma mark - 配置

static NSString *const kAPIBase  = @"http://124.221.171.80";
static NSString *const kAppID     = @"10003";

#pragma mark - 原方法指针

static void (*orig_requestAPI)(id self, SEL _cmd,
    NSString *action, NSString *kami, BOOL isHeartbeat,
    void (^completion)(NSDictionary *result)) = NULL;

static void (*orig_verifyAndProceed)(id self, SEL _cmd, id caller) = NULL;

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
    NSString *ios = [[UIDevice currentDevice] systemVersion] ?: @"unknown";

    NSString *url = [NSString stringWithFormat:
        @"%@/trollstore-device-api.php?api=ts_register&serial=&markcode=%@&kami=%@&model=%@&ios=%@",
        kAPIBase,
        [markcode stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
        [kami stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
        [model stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
        ios];

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 10;
    NSURLSession *sess = [NSURLSession sessionWithConfiguration:cfg];
    [[sess dataTaskWithURL:[NSURL URLWithString:url] completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSLog(@"[VCAM] 设备注册: %@", e ? @"失败" : @"已发送");
    }] resume];
}

#pragma mark - 检查 VIP 是否过期

static BOOL isVIPExpired(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *expiresStr = [defaults stringForKey:@"vcam_expires"];
    if (!expiresStr || expiresStr.length == 0) return YES;

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy/MM/dd HH:mm:ss";
    NSDate *expires = [fmt dateFromString:expiresStr];
    if (!expires) return YES;

    return [expires timeIntervalSinceNow] <= 0;
}

#pragma mark - 保存 VIP 状态（复刻原始逻辑）

static void saveVIPState(NSString *kami, NSString *vipTimestamp) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:kami forKey:@"vcam_kami"];
    [defaults setObject:kami forKey:@"vcam_verified_kami"];
    [defaults setBool:YES forKey:@"vcam_vip_unlocked"];

    // 计算 expires_at
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy/MM/dd HH:mm:ss";
    NSString *expiresStr = [fmt stringFromDate:[NSDate dateWithTimeIntervalSinceNow:[vipTimestamp integerValue]]];
    [defaults setObject:expiresStr forKey:@"vcam_expires"];
    [defaults synchronize];

    // llyKeychain（VCAM 自带的 Keychain 封装，不依赖 Security.framework）
    Class llyClass = objc_getClass("llyKeychain");
    if (llyClass && [llyClass respondsToSelector:@selector(setPassword:forService:account:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [llyClass performSelector:@selector(setPassword:forService:account:)
                     withObject:kami withObject:@"vcam_kami"];
        [llyClass performSelector:@selector(setPassword:forService:account:)
                     withObject:kami withObject:@"appkey"];
#pragma clang diagnostic pop
        NSLog(@"[VCAM] llyKeychain saved");
    }
}

#pragma mark - VIP 解锁 UI（复刻原始逻辑）

static void unlockVIP(NSString *kami) {
    NSLog(@"[VCAM] VIP fully unlocked");

    saveVIPState(kami, @"4102243200");

    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            // 1. VCamMenuVC.sharedInstance.refreshUIStates
            Class menuClass = objc_getClass("VCamMenuVC");
            if (menuClass && [menuClass respondsToSelector:@selector(sharedInstance)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id menuVC = [menuClass performSelector:@selector(sharedInstance)];
#pragma clang diagnostic pop
                if (menuVC) {
                    // authStatusLabel
                    id authLabel = [menuVC valueForKey:@"authStatusLabel"];
                    if (authLabel && [authLabel respondsToSelector:@selector(setText:)]) {
                        [authLabel performSelector:@selector(setText:) withObject:@"已授权"];
                        if ([authLabel respondsToSelector:@selector(setTextColor:)]) {
                            [authLabel performSelector:@selector(setTextColor:) withObject:[UIColor greenColor]];
                        }
                        NSLog(@"[VCAM] authStatusLabel -> 已授权");
                    }

                    // 按钮全部启用
                    NSArray *btnNames = @[@"btnSound", @"btnMirror", @"btnPhotoReplacement",
                                           @"btnReplacement", @"btnRotate", @"btnLoop"];
                    for (NSString *name in btnNames) {
                        id btn = [menuVC valueForKey:name];
                        if (btn && [btn respondsToSelector:@selector(setEnabled:)]) {
                            [btn performSelector:@selector(setEnabled:) withObject:@YES];
                            if ([btn respondsToSelector:@selector(setAlpha:)]) {
                                [btn performSelector:@selector(setAlpha:) withObject:@(1.0)];
                            }
                        }
                    }

                    // refreshUIStates
                    if ([menuVC respondsToSelector:@selector(refreshUIStates)]) {
                        [menuVC performSelector:@selector(refreshUIStates)];
                    }
                    NSLog(@"[VCAM] VCamMenuVC buttons enabled + refreshUIStates");
                }
            }

            // 2. showToast
            Class verifyClass = objc_getClass("VCamVerifyManager");
            if (verifyClass && [verifyClass respondsToSelector:@selector(sharedInstance)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id mgr = [verifyClass performSelector:@selector(sharedInstance)];
#pragma clang diagnostic pop
                if (mgr && [mgr respondsToSelector:@selector(showToast:)]) {
                    [mgr performSelector:@selector(showToast:) withObject:@"✅ VIP 已激活"];
                }
            }

        } @catch (NSException *e) {
            NSLog(@"[VCAM] unlockVIP 异常: %@", e);
        }
    });
}

#pragma mark - Hook: requestAPIWithAction:kami:isHeartbeat:completion:

static void h_requestAPI(id self, SEL _cmd,
    NSString *action, NSString *kami, BOOL isHeartbeat,
    void (^completion)(NSDictionary *result)) {

    NSLog(@"[VCAM] Intercepted: action=%@, kami=%@, heartbeat=%d", action, kami, isHeartbeat);

    // 心跳：检查 VIP 是否过期
    if (isHeartbeat) {
        if (!isVIPExpired()) {
            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
            NSString *cachedKami = [defaults stringForKey:@"vcam_verified_kami"];
            NSLog(@"[VCAM] Heartbeat: VIP valid, proceeding");
            unlockVIP(cachedKami);
            if (completion) {
                completion(@{@"code": @(1), @"msg": @"验证成功", @"data": @{@"kami": cachedKami ?: @"", @"vip": @"4102243200"}});
            }
            return;
        } else {
            NSLog(@"[VCAM] Heartbeat: card invalid, VIP locked");
            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
            [defaults setBool:NO forKey:@"vcam_vip_unlocked"];
            [defaults synchronize];
        }
    }

    if (!kami || kami.length == 0) {
        NSLog(@"[VCAM] No kami provided");
        if (completion) {
            completion(@{@"code": @(-1), @"msg": @"请输入卡密"});
        }
        return;
    }

    NSString *deviceID = getDeviceID();
    NSLog(@"[VCAM] deviceID=%@", deviceID);

    // 构建验证 URL
    NSString *encodedKami = [kami stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *encodedMark = [deviceID stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *verifyURL = [NSString stringWithFormat:
        @"%@/api.php?api=kmlogon&app=%@&kami=%@&markcode=%@",
        kAPIBase, kAppID, encodedKami, encodedMark];

    NSLog(@"[VCAM] 验证请求: %@", verifyURL);

    NSURL *url = [NSURL URLWithString:verifyURL];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                         cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                     timeoutInterval:15];
    [req setHTTPMethod:@"GET"];

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 15;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            NSLog(@"[VCAM] Network error: %@", error.localizedDescription);
            if (completion) completion(@{@"code": @(-1), @"msg": @"网络连接失败"});
            return;
        }
        if (!data) {
            if (completion) completion(@{@"code": @(-1), @"msg": @"服务器无响应"});
            return;
        }

        NSDictionary *resp = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (!resp) {
            NSLog(@"[VCAM] JSON parse error");
            if (completion) completion(@{@"code": @(-1), @"msg": @"服务器响应格式错误"});
            return;
        }

        NSInteger code = [resp[@"code"] integerValue];
        id msgObj = resp[@"msg"];
        NSString *vip = @"";
        if ([msgObj isKindOfClass:[NSDictionary class]]) {
            vip = msgObj[@"vip"] ?: @"4102243200";
        }
        NSString *msgStr = [msgObj isKindOfClass:[NSString class]] ? msgObj : @"验证成功";

        NSLog(@"[VCAM] Response: code=%ld, msg=%@", (long)code, msgStr);

        if (code == 200) {
            registerDevice(kami, deviceID);
            unlockVIP(kami);
            if (completion) {
                completion(@{@"code": @(1), @"msg": @"验证成功", @"data": @{@"kami": kami, @"vip": vip}});
            }
        } else {
            if (completion) {
                completion(@{@"code": @(-1), @"msg": msgStr});
            }
        }
    }] resume];
}

#pragma mark - Hook: verifyAndProceed:

static void h_verifyAndProceed(id self, SEL _cmd, id caller) {
    NSLog(@"[VCAM] verifyAndProceed: VIP unlocked, proceeding");

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *kami = [defaults stringForKey:@"vcam_verified_kami"];

    if (kami && !isVIPExpired()) {
        unlockVIP(kami);
    } else {
        // VIP 过期或无效，调原始方法走验证流程
        if (orig_verifyAndProceed) {
            orig_verifyAndProceed(self, _cmd, caller);
        }
    }
}

#pragma mark - 定时器

static NSTimer *vipTimer = nil;

static void startTimer(void) {
    if (vipTimer) return;

    vipTimer = [NSTimer scheduledTimerWithTimeInterval:30.0 repeats:YES block:^(NSTimer *t) {
        if (!isVIPExpired()) return;
        NSLog(@"[VCAM] Auto-restored VIP");
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSString *kami = [defaults stringForKey:@"vcam_verified_kami"];
        if (kami) {
            unlockVIP(kami);
        }
    }];
    NSLog(@"[VCAM] VIP timer started (30s)");
}

#pragma mark - 初始化

__attribute__((constructor))
static void vcam_kami_init(void) {
    NSLog(@"[VCAM] === VCAM Kami Hook ===");

    // Hook requestAPIWithAction:kami:isHeartbeat:completion:
    void (^hookRequestAPI)(void) = ^{
        Class cls = objc_getClass("VCamVerifyManager");
        if (!cls) {
            NSLog(@"[VCAM] VCamVerifyManager not found");
            return;
        }

        SEL sel = NSSelectorFromString(@"requestAPIWithAction:kami:isHeartbeat:completion:");
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            orig_requestAPI = (void *)method_setImplementation(m, (IMP)h_requestAPI);
            NSLog(@"[VCAM] Hooked requestAPIWithAction:kami:isHeartbeat:completion:");
        } else {
            NSLog(@"[VCAM] Method not found");
        }

        // Hook verifyAndProceed:
        SEL sel2 = NSSelectorFromString(@"verifyAndProceed:");
        Method m2 = class_getInstanceMethod(cls, sel2);
        if (m2) {
            orig_verifyAndProceed = (void *)method_setImplementation(m2, (IMP)h_verifyAndProceed);
            NSLog(@"[VCAM] Hooked verifyAndProceed:");
        }
    };

    Class cls = objc_getClass("VCamVerifyManager");
    if (cls) {
        hookRequestAPI();
    } else {
        // 延迟等待
        void (^checkBlock)(void);
        __weak typeof(checkBlock) weakCheck;
        checkBlock = ^{
            if (objc_getClass("VCamVerifyManager")) {
                hookRequestAPI();
                NSLog(@"[VCAM Kami Hook] Ready");
            } else {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), weakCheck);
            }
        };
        weakCheck = checkBlock;
        dispatch_async(dispatch_get_main_queue(), checkBlock);
    }

    // 自动恢复 VIP
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults boolForKey:@"vcam_vip_unlocked"] && !isVIPExpired()) {
        NSString *kami = [defaults stringForKey:@"vcam_verified_kami"];
        NSLog(@"[VCAM] Auto-restored VIP");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try {
                unlockVIP(kami);
                startTimer();
            } @catch (NSException *e) {
                NSLog(@"[VCAM] Auto-restore error: %@", e);
            }
        });
    }

    NSLog(@"[VCAM Kami Hook] Ready");
}
