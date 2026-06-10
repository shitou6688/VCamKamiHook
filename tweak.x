/**
 * VCamKamiHook v4 - 将 VCAM 卡密验证对接到自有服务器
 * 1:1 对齐 VCAM.dylib 内部类结构
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

    // llyKeychain（VCAM 自带，不依赖 Security.framework）
    Class kc = objc_getClass("llyKeychain");
    if (kc && [kc respondsToSelector:@selector(setPassword:forService:account:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [kc performSelector:@selector(setPassword:forService:account:) withObject:kami withObject:@"vcam_kami"];
        [kc performSelector:@selector(setPassword:forService:account:) withObject:kami withObject:@"appkey"];
#pragma clang diagnostic pop
    }
}

#pragma mark - 操作 VCamMenuVC

static void setupMenuVC(id menuVC) {
    @try {
        // authStatusLabel -> 绿色"已授权"
        id label = [menuVC valueForKey:@"authStatusLabel"];
        if ([label respondsToSelector:@selector(setText:)]) {
            [label setText:@"已授权"];
            if ([label respondsToSelector:@selector(setTextColor:)]) {
                [label setTextColor:[UIColor greenColor]];
            }
        }

        // 按钮启用（属性名对齐 VCAM.dylib 实际 ivar）
        NSDictionary *btns = @{
            @"btnSound": @YES,
            @"btnMirror": @YES,
            @"btnPhotoToggle": @YES,
            @"btnRotate": @YES,
            @"btnLoop": @YES
        };
        for (NSString *name in btns) {
            @try {
                id btn = [menuVC valueForKey:name];
                if ([btn respondsToSelector:@selector(setEnabled:)]) {
                    [btn setEnabled:YES];
                }
                if ([btn respondsToSelector:@selector(setAlpha:)]) {
                    [btn setAlpha:1.0];
                }
            } @catch (NSException *e) { }
        }

        // refreshUIStates
        if ([menuVC respondsToSelector:@selector(refreshUIStates)]) {
            [menuVC performSelector:@selector(refreshUIStates)];
        }
    } @catch (NSException *e) {
        NSLog(@"[VCAM] setupMenuVC err: %@", e);
    }
}

#pragma mark - VIP 解锁

static void unlockVIP(NSString *kami) {
    NSLog(@"[VCAM] VIP fully unlocked");
    saveVIPState(kami);

    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            // VCamVerifyManager - 设 use_kami
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

            // VCamMenuVC - UI 操作
            Class mcClass = objc_getClass("VCamMenuVC");
            if (mcClass && [mcClass respondsToSelector:@selector(sharedInstance)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id mc = [mcClass performSelector:@selector(sharedInstance)];
#pragma clang diagnostic pop
                if (mc) {
                    setupMenuVC(mc);
                    NSLog(@"[VCAM] menuVC via sharedInstance OK");
                }
            }
        } @catch (NSException *e) {
            NSLog(@"[VCAM] unlockVIP err: %@", e);
        }
    });
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
        if ([msgObj isKindOfClass:[NSDictionary class]]) {
            vip = msgObj[@"vip"] ?: @"4102243200";
        }

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

#pragma mark - 定时器

static NSTimer *vipTimer = nil;

static void startTimer(void) {
    if (vipTimer) return;
    vipTimer = [NSTimer scheduledTimerWithTimeInterval:30.0 repeats:YES block:^(NSTimer *t) {
        if (!isVIPExpired()) return;
        NSString *k = [[NSUserDefaults standardUserDefaults] stringForKey:@"vcam_verified_kami"];
        if (k) { NSLog(@"[VCAM] Auto-restored VIP"); unlockVIP(k); }
    }];
}

#pragma mark - 初始化

__attribute__((constructor))
static void vcam_kami_init(void) {
    NSLog(@"[VCAM] === VCAM Kami Hook ===");

    void (^doHook)(void) = ^{
        Class cls = objc_getClass("VCamVerifyManager");
        if (!cls) { NSLog(@"[VCAM] VCamVerifyManager not found"); return; }

        SEL sel1 = NSSelectorFromString(@"requestAPIWithAction:kami:isHeartbeat:completion:");
        Method m1 = class_getInstanceMethod(cls, sel1);
        if (m1) {
            orig_requestAPI = (void *)method_setImplementation(m1, (IMP)h_requestAPI);
            NSLog(@"[VCAM] Hooked requestAPIWithAction:kami:isHeartbeat:completion:");
        }

        SEL sel2 = NSSelectorFromString(@"verifyAndProceed:");
        Method m2 = class_getInstanceMethod(cls, sel2);
        if (m2) {
            orig_verifyAndProceed = (void *)method_setImplementation(m2, (IMP)h_verifyAndProceed);
            NSLog(@"[VCAM] Hooked verifyAndProceed:");
        }
    };

    if (objc_getClass("VCamVerifyManager")) {
        doHook();
    } else {
        void (^check)(void);
        __weak typeof(check) weakCheck;
        check = ^{
            if (objc_getClass("VCamVerifyManager")) { doHook(); NSLog(@"[VCAM Kami Hook] Ready"); }
            else { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), weakCheck); }
        };
        weakCheck = check;
        dispatch_async(dispatch_get_main_queue(), check);
    }

    // 自动恢复
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
