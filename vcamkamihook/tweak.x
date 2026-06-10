/**
 * VCamKamiHook v6 - 从零破解 VCAM 验证
 * 
 * 策略：
 * 1. Hook requestAPIWithAction → 对接自有服务器
 * 2. Hook toggle* 方法 → 跳过 VIP 检查，直接执行功能
 * 3. Hook showBanAlert → 拦截封禁弹窗
 * 4. 强制设置 VIP 状态
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
static void (*orig_toggleSound)(id, SEL) = NULL;
static void (*orig_toggleMirror)(id, SEL) = NULL;
static void (*orig_toggleRotate)(id, SEL) = NULL;
static void (*orig_toggleLoop)(id, SEL) = NULL;
static void (*orig_togglePhotoReplacement)(id, SEL) = NULL;
static void (*orig_toggleReplacement)(id, SEL) = NULL;
static void (*orig_showBanAlert)(id, SEL, id) = NULL;
static void (*orig_startVerifyProcess)(id, SEL) = NULL;
static void (*orig_refreshUIStates)(id, SEL) = NULL;

#pragma mark - VIP 状态

static BOOL g_vipActive = NO;
static NSString *g_kami = nil;

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

#pragma mark - 保存 VIP 状态

static void saveVIPState(NSString *kami) {
    g_vipActive = YES;
    g_kami = [kami copy];

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:kami forKey:@"vcam_kami"];
    [d setObject:kami forKey:@"vcam_verified_kami"];
    [d setBool:YES forKey:@"vcam_vip_unlocked"];
    [d synchronize];

    // llyKeychain
    Class kc = objc_getClass("llyKeychain");
    if (kc && [kc respondsToSelector:@selector(setPassword:forService:account:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [kc performSelector:@selector(setPassword:forService:account:) withObject:kami withObject:@"vcam_kami"];
        [kc performSelector:@selector(setPassword:forService:account:) withObject:kami withObject:@"appkey"];
#pragma clang diagnostic pop
    }
}

#pragma mark - 激活 VIP（设置所有内部状态）

static void activateVIP(NSString *kami) {
    saveVIPState(kami);

    // 设置 VCamVerifyManager 内部属性
    Class vmClass = objc_getClass("VCamVerifyManager");
    if (vmClass && [vmClass respondsToSelector:@selector(sharedInstance)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id vm = [vmClass performSelector:@selector(sharedInstance)];
#pragma clang diagnostic pop
        if (vm) {
            @try { [vm setValue:kami forKey:@"use_kami"]; } @catch (NSException *e) { }
        }
    }

    // 更新 UI
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            // 遍历所有 window 找到 authStatusLabel 并更新
            for (UIWindow *window in [UIApplication sharedApplication].windows) {
                UIViewController *rootVC = window.rootViewController;
                if (!rootVC) continue;

                // 尝试 VCamMenuVC.sharedInstance
                Class mcClass = objc_getClass("VCamMenuVC");
                if (mcClass && [mcClass respondsToSelector:@selector(sharedInstance)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    id mc = [mcClass performSelector:@selector(sharedInstance)];
#pragma clang diagnostic pop
                    if (mc) {
                        id label = [mc valueForKey:@"authStatusLabel"];
                        if ([label isKindOfClass:[UILabel class]]) {
                            [(UILabel *)label setText:@"✅ 已授权 - 所有功能已解锁"];
                            [(UILabel *)label setTextColor:[UIColor greenColor]];
                        }
                        // 启用所有按钮
                        for (NSString *btnName in @[@"btnSound", @"btnMirror", @"btnPhotoToggle",
                                                     @"btnRotate", @"btnLoop", @"btnReplaceToggle"]) {
                            @try {
                                id btn = [mc valueForKey:btnName];
                                if ([btn isKindOfClass:[UIButton class]]) {
                                    [(UIButton *)btn setEnabled:YES];
                                    [(UIButton *)btn setAlpha:1.0];
                                }
                            } @catch (NSException *e) { }
                        }
                        if ([mc respondsToSelector:@selector(refreshUIStates)]) {
                            [mc performSelector:@selector(refreshUIStates)];
                        }
                    }
                }
            }
        } @catch (NSException *e) {
            NSLog(@"[VCAM] activateVIP UI err: %@", e);
        }
    });
}

#pragma mark - Hook: requestAPIWithAction:kami:isHeartbeat:completion:

static void h_requestAPI(id self, SEL _cmd,
    NSString *action, NSString *kami, BOOL isHeartbeat,
    void (^completion)(NSDictionary *result)) {

    NSLog(@"[VCAM] API: action=%@ kami=%@ heartbeat=%d", action, kami, isHeartbeat);

    if (isHeartbeat) {
        if (g_vipActive || !isVIPExpired()) {
            NSString *k = g_kami ?: [[NSUserDefaults standardUserDefaults] stringForKey:@"vcam_verified_kami"];
            activateVIP(k);
            // 返回 VCAM 期望的格式
            if (completion) completion(@{
                @"code": @(1),
                @"msg": @"ok",
                @"data": @{@"expire_date": @"2099/12/31 23:59:59"},
                @"enable": @YES
            });
            return;
        }
    }

    if (!kami || kami.length == 0) {
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

        if (error || !data) {
            NSLog(@"[VCAM] Network error: %@", error.localizedDescription);
            if (completion) completion(@{@"code": @(-1), @"msg": @"网络连接失败"});
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (!json) {
            if (completion) completion(@{@"code": @(-1), @"msg": @"服务器响应格式错误"});
            return;
        }

        NSInteger code = [json[@"code"] integerValue];

        if (code == 200) {
            registerDevice(kami, deviceID);
            activateVIP(kami);

            // 返回 VCAM 期望的格式（不是 kami API 的格式！）
            NSString *expires = @"2099/12/31 23:59:59";
            id msgObj = json[@"msg"];
            if ([msgObj isKindOfClass:[NSDictionary class]]) {
                id vipVal = msgObj[@"vip"];
                if ([vipVal respondsToSelector:@selector(longLongValue)]) {
                    long long ts = [vipVal longLongValue];
                    if (ts > 0) {
                        NSDate *date = [NSDate dateWithTimeIntervalSince1970:ts];
                        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
                        fmt.dateFormat = @"yyyy/MM/dd HH:mm:ss";
                        expires = [fmt stringFromDate:date];
                    }
                }
            }

            // 同时保存到 NSUserDefaults（vcam_expires 格式）
            [[NSUserDefaults standardUserDefaults] setObject:expires forKey:@"vcam_expires"];
            [[NSUserDefaults standardUserDefaults] synchronize];

            if (completion) completion(@{
                @"code": @(1),
                @"msg": @"ok",
                @"data": @{
                    @"expire_date": expires,
                    @"expires_at": expires
                },
                @"enable": @YES,
                @"check": @"1"
            });
        } else {
            if (completion) completion(@{@"code": @(-1), @"msg": @"卡密无效"});
        }
    }];
    [task resume];
}

#pragma mark - Hook: verifyAndProceed: → 跳过验证直接执行

static void h_verifyAndProceed(id self, SEL _cmd, id caller) {
    NSLog(@"[VCAM] verifyAndProceed: skip verification, execute directly");
    // 设置内部 VIP 标志，让原始方法认为已验证通过
    @try {
        [self setValue:@YES forKey:@"isVIP"];
        [self setValue:@YES forKey:@"isVerified"];
        [self setValue:@YES forKey:@"isAuthorized"];
        [self setValue:@YES forKey:@"vipActivated"];
        [self setValue:g_kami forKey:@"use_kami"];
        [self setValue:g_kami forKey:@"kami"];
        [self setValue:@YES forKey:@"verified"];
    } @catch (NSException *e) {
        NSLog(@"[VCAM] setVIP props err: %@", e);
    }
    // 调原始方法，让它执行功能代码
    if (orig_verifyAndProceed) orig_verifyAndProceed(self, _cmd, caller);
}

#pragma mark - Hook: showBanAlert: → 拦截封禁弹窗

static void h_showBanAlert(id self, SEL _cmd, id msg) {
    NSLog(@"[VCAM] showBanAlert blocked: %@", msg);
    // 不弹窗，直接忽略
}

#pragma mark - Hook: toggle 方法 → 强制设置 VIP 状态后执行原始逻辑

// 强制设置目标对象上的所有可能的 VIP 属性
static void forceVIPOnTarget(id target) {
    if (!target) return;
    @try {
        NSArray *boolKeys = @[@"isVIP", @"isVerified", @"isAuthorized",
            @"vipActivated", @"verified", @"isVip", @"is_authorized",
            @"hasVIP", @"vipEnabled", @"isPremium", @"unlocked"];
        for (NSString *k in boolKeys) {
            [target setValue:@YES forKey:k];
        }
        NSString *kami = g_kami ?: @"";
        NSArray *kamiKeys = @[@"use_kami", @"kami", @"activeKami",
            @"currentKami", @"licenseKey", @"activationCode"];
        for (NSString *k in kamiKeys) {
            [target setValue:kami forKey:k];
        }
    } @catch (NSException *e) {
        NSLog(@"[VCAM] forceVIPOnTarget err: %@", e);
    }
    Class vmClass = objc_getClass("VCamVerifyManager");
    if (vmClass && [vmClass respondsToSelector:@selector(sharedInstance)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id vm = [vmClass performSelector:@selector(sharedInstance)];
#pragma clang diagnostic pop
        forceVIPOnTarget(vm);
    }
}

// 通用 toggle 处理：不调原始方法，直接翻转按钮和内部状态
static void doToggle(id self, SEL _cmd, NSString *btnName, NSString *stateKey,
                      void (*orig)(id, SEL)) {
    NSLog(@"[VCAM] doToggle: %@", btnName);

    forceVIPOnTarget(self);

    // 找按钮并翻转
    @try {
        id btn = [self valueForKey:btnName];
        if ([btn isKindOfClass:[UIButton class]]) {
            UIButton *b = (UIButton *)btn;
            b.enabled = YES;
            b.alpha = 1.0;
            b.selected = !b.selected;
            if (b.selected) {
                b.backgroundColor = [UIColor systemBlueColor];
            } else {
                b.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[VCAM] toggle btn err: %@", e);
    }

    // 翻转内部功能状态
    if (stateKey) {
        BOOL set = NO;
        @try {
            id current = [self valueForKey:stateKey];
            if ([current respondsToSelector:@selector(boolValue)]) {
                [self setValue:@(![current boolValue]) forKey:stateKey];
                set = YES;
            }
        } @catch (NSException *e) { }

        if (!set) {
            NSArray *altKeys = nil;
            if ([btnName isEqualToString:@"btnSound"])
                altKeys = @[@"soundEnabled", @"isSoundOn", @"soundOn", @"muteSound", @"soundMuted"];
            else if ([btnName isEqualToString:@"btnMirror"])
                altKeys = @[@"mirrorEnabled", @"isMirrorOn", @"mirrorOn"];
            else if ([btnName isEqualToString:@"btnRotate"])
                altKeys = @[@"rotateEnabled", @"isRotateOn", @"autoRotate"];
            else if ([btnName isEqualToString:@"btnLoop"])
                altKeys = @[@"loopEnabled", @"isLoopOn", @"videoLoop"];

            if (altKeys) {
                for (NSString *k in altKeys) {
                    @try {
                        id val = [self valueForKey:k];
                        if ([val respondsToSelector:@selector(boolValue)]) {
                            [self setValue:@(![val boolValue]) forKey:k];
                        } else {
                            [self setValue:@YES forKey:k];
                        }
                        break;
                    } @catch (NSException *ex) { }
                }
            }
        }
    }

    // 刷新 UI
    if ([self respondsToSelector:@selector(refreshUIStates)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self performSelector:@selector(refreshUIStates)];
#pragma clang diagnostic pop
    }
}

static void h_toggleSound(id self, SEL _cmd) {
    doToggle(self, _cmd, @"btnSound", @"soundEnabled", orig_toggleSound);
}
static void h_toggleMirror(id self, SEL _cmd) {
    doToggle(self, _cmd, @"btnMirror", @"mirrorEnabled", orig_toggleMirror);
}
static void h_toggleRotate(id self, SEL _cmd) {
    doToggle(self, _cmd, @"btnRotate", @"rotateEnabled", orig_toggleRotate);
}
static void h_toggleLoop(id self, SEL _cmd) {
    doToggle(self, _cmd, @"btnLoop", @"loopEnabled", orig_toggleLoop);
}
static void h_togglePhotoReplacement(id self, SEL _cmd) {
    doToggle(self, _cmd, @"btnPhotoToggle", @"photoReplaceEnabled", orig_togglePhotoReplacement);
}
static void h_toggleReplacement(id self, SEL _cmd) {
    doToggle(self, _cmd, @"btnReplaceToggle", @"replaceEnabled", orig_toggleReplacement);
}

#pragma mark - Hook: startVerifyProcess → 如果已激活直接通过

static void h_startVerifyProcess(id self, SEL _cmd) {
    if (g_vipActive) {
        NSLog(@"[VCAM] startVerifyProcess: already VIP, skip");
        activateVIP(g_kami);
        return;
    }
    if (orig_startVerifyProcess) orig_startVerifyProcess(self, _cmd);
}

#pragma mark - Hook: refreshUIStates → 强制已授权状态

static void h_refreshUIStates(id self, SEL _cmd) {
    forceVIPOnTarget(self);
    if (orig_refreshUIStates) orig_refreshUIStates(self, _cmd);

    if (!g_vipActive) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            id label = [self valueForKey:@"authStatusLabel"];
            if ([label isKindOfClass:[UILabel class]]) {
                [(UILabel *)label setText:@"✅ 已授权 - 所有功能已解锁"];
                [(UILabel *)label setTextColor:[UIColor greenColor]];
            }
            for (NSString *btnName in @[@"btnSound", @"btnMirror", @"btnPhotoToggle",
                                         @"btnRotate", @"btnLoop", @"btnReplaceToggle"]) {
                @try {
                    id btn = [self valueForKey:btnName];
                    if ([btn isKindOfClass:[UIButton class]]) {
                        [(UIButton *)btn setEnabled:YES];
                        [(UIButton *)btn setAlpha:1.0];
                    }
                } @catch (NSException *e) { }
            }
        } @catch (NSException *e) { }
    });
}

#pragma mark - 初始化

__attribute__((constructor))
static void vcam_kami_init(void) {
    NSLog(@"[VCAM] === VCamKamiHook v6 ===");

    void (^doHook)(void) = ^{
        // ====== VCamVerifyManager hooks ======
        Class vmClass = objc_getClass("VCamVerifyManager");
        if (vmClass) {
            // requestAPIWithAction:kami:isHeartbeat:completion:
            SEL sel1 = NSSelectorFromString(@"requestAPIWithAction:kami:isHeartbeat:completion:");
            Method m1 = class_getInstanceMethod(vmClass, sel1);
            if (m1) {
                orig_requestAPI = (void *)method_setImplementation(m1, (IMP)h_requestAPI);
                NSLog(@"[VCAM] Hooked requestAPIWithAction");
            }

            // verifyAndProceed:
            SEL sel2 = NSSelectorFromString(@"verifyAndProceed:");
            Method m2 = class_getInstanceMethod(vmClass, sel2);
            if (m2) {
                orig_verifyAndProceed = (void *)method_setImplementation(m2, (IMP)h_verifyAndProceed);
                NSLog(@"[VCAM] Hooked verifyAndProceed:");
            }
        }

        // ====== VCamMenuVC hooks ======
        Class mcClass = objc_getClass("VCamMenuVC");
        if (mcClass) {
            // toggle 方法 - 逐个 hook
            { SEL sel = NSSelectorFromString(@"toggleSound"); Method m = class_getInstanceMethod(mcClass, sel); if (m) { orig_toggleSound = (void *)method_setImplementation(m, (IMP)h_toggleSound); NSLog(@"[VCAM] Hooked toggleSound"); } }
            { SEL sel = NSSelectorFromString(@"toggleMirror"); Method m = class_getInstanceMethod(mcClass, sel); if (m) { orig_toggleMirror = (void *)method_setImplementation(m, (IMP)h_toggleMirror); NSLog(@"[VCAM] Hooked toggleMirror"); } }
            { SEL sel = NSSelectorFromString(@"toggleRotate"); Method m = class_getInstanceMethod(mcClass, sel); if (m) { orig_toggleRotate = (void *)method_setImplementation(m, (IMP)h_toggleRotate); NSLog(@"[VCAM] Hooked toggleRotate"); } }
            { SEL sel = NSSelectorFromString(@"toggleLoop"); Method m = class_getInstanceMethod(mcClass, sel); if (m) { orig_toggleLoop = (void *)method_setImplementation(m, (IMP)h_toggleLoop); NSLog(@"[VCAM] Hooked toggleLoop"); } }
            { SEL sel = NSSelectorFromString(@"togglePhotoReplacement"); Method m = class_getInstanceMethod(mcClass, sel); if (m) { orig_togglePhotoReplacement = (void *)method_setImplementation(m, (IMP)h_togglePhotoReplacement); NSLog(@"[VCAM] Hooked togglePhotoReplacement"); } }
            { SEL sel = NSSelectorFromString(@"toggleReplacement"); Method m = class_getInstanceMethod(mcClass, sel); if (m) { orig_toggleReplacement = (void *)method_setImplementation(m, (IMP)h_toggleReplacement); NSLog(@"[VCAM] Hooked toggleReplacement"); } }

            // showBanAlert:
            SEL selBan = NSSelectorFromString(@"showBanAlert:");
            Method mBan = class_getInstanceMethod(mcClass, selBan);
            if (mBan) {
                orig_showBanAlert = (void *)method_setImplementation(mBan, (IMP)h_showBanAlert);
                NSLog(@"[VCAM] Hooked showBanAlert:");
            }

            // startVerifyProcess
            SEL selStart = NSSelectorFromString(@"startVerifyProcess");
            Method mStart = class_getInstanceMethod(mcClass, selStart);
            if (mStart) {
                orig_startVerifyProcess = (void *)method_setImplementation(mStart, (IMP)h_startVerifyProcess);
                NSLog(@"[VCAM] Hooked startVerifyProcess");
            }

            // refreshUIStates
            SEL selRefresh = NSSelectorFromString(@"refreshUIStates");
            Method mRefresh = class_getInstanceMethod(mcClass, selRefresh);
            if (mRefresh) {
                orig_refreshUIStates = (void *)method_setImplementation(mRefresh, (IMP)h_refreshUIStates);
                NSLog(@"[VCAM] Hooked refreshUIStates");
            }
        }
    };

    // 等待类加载
    if (objc_getClass("VCamVerifyManager") && objc_getClass("VCamMenuVC")) {
        doHook();
    } else {
        void (^check)(void);
        __weak typeof(check) weakCheck;
        check = ^{
            if (objc_getClass("VCamVerifyManager") && objc_getClass("VCamMenuVC")) {
                doHook();
                NSLog(@"[VCAM] Hooks ready");
            } else {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                    dispatch_get_main_queue(), weakCheck);
            }
        };
        weakCheck = check;
        dispatch_async(dispatch_get_main_queue(), check);
    }

    // 自动恢复
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"vcam_vip_unlocked"] && !isVIPExpired()) {
        NSString *kami = [[NSUserDefaults standardUserDefaults] stringForKey:@"vcam_verified_kami"];
        g_vipActive = YES;
        g_kami = [kami copy];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                activateVIP(kami);
            });
    }

    NSLog(@"[VCAM] VCamKamiHook v6 Ready");
}
