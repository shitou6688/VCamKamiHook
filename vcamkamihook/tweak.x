/**
 * VCamKamiHook v7 - 极简版
 * 
 * 策略：
 * 1. Hook requestAPIWithAction → 对接自有服务器，返回 App 期望的格式
 * 2. 不 hook 任何 toggle/verify/UI 方法，让 App 原生流程正常工作
 * 3. 拦截 showBanAlert 防止弹窗
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
static void (*orig_showBanAlert)(id, SEL, id) = NULL;

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

#pragma mark - Hook: requestAPIWithAction:kami:isHeartbeat:completion:

static void h_requestAPI(id self, SEL _cmd,
    NSString *action, NSString *kami, BOOL isHeartbeat,
    void (^completion)(NSDictionary *result)) {

    NSLog(@"[VCAM] API: action=%@ kami=%@ heartbeat=%d", action, kami, isHeartbeat);

    // 心跳包：如果已激活，直接返回成功
    if (isHeartbeat && g_vipActive) {
        if (completion) completion(@{
            @"code": @(0),
            @"msg": @"ok",
            @"data": @{
                @"vip": @([[[NSDate date] dateByAddingTimeInterval:365*24*3600] timeIntervalSince1970]),
                @"expire_date": @"2099/12/31 23:59:59"
            }
        });
        return;
    }

    if (!kami || kami.length == 0) {
        if (completion) completion(@{@"code": @(-1), @"msg": @"请输入卡密"});
        return;
    }

    // 调自有服务器验证
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
            // 验证成功
            registerDevice(kami, deviceID);
            g_vipActive = YES;
            g_kami = [kami copy];

            // 保存到 UserDefaults
            NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
            [d setObject:kami forKey:@"vcam_kami"];
            [d setObject:kami forKey:@"vcam_verified_kami"];
            [d setBool:YES forKey:@"vcam_vip_unlocked"];

            // 计算过期时间
            NSString *expires = @"2099/12/31 23:59:59";
            long long vipTs = 0;
            id msgObj = json[@"msg"];
            if ([msgObj isKindOfClass:[NSDictionary class]]) {
                id vipVal = msgObj[@"vip"];
                if ([vipVal respondsToSelector:@selector(longLongValue)]) {
                    vipTs = [vipVal longLongValue];
                }
            }
            if (vipTs > 0) {
                NSDate *date = [NSDate dateWithTimeIntervalSince1970:vipTs];
                NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
                fmt.dateFormat = @"yyyy/MM/dd HH:mm:ss";
                expires = [fmt stringFromDate:date];
            }
            [d setObject:expires forKey:@"vcam_expires"];
            [d synchronize];

            // 保存到 Keychain
            Class kc = objc_getClass("llyKeychain");
            if (kc && [kc respondsToSelector:@selector(setPassword:forService:account:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [kc performSelector:@selector(setPassword:forService:account:) withObject:kami withObject:@"vcam_kami"];
                [kc performSelector:@selector(setPassword:forService:account:) withObject:kami withObject:@"appkey"];
#pragma clang diagnostic pop
            }

            // 返回 App 期望的格式（模拟 kami.lengye.top/api/login 成功响应）
            // 原始 API 返回 {"code": 0, "msg": "ok", "data": {"vip": timestamp}}
            NSMutableDictionary *result = [@{
                @"code": @(0),
                @"msg": @"ok"
            } mutableCopy];

            NSMutableDictionary *dataDict = [@{} mutableCopy];
            if (vipTs > 0) {
                [dataDict setObject:@(vipTs) forKey:@"vip"];
            } else {
                // 没有过期时间，给一个很远的未来
                [dataDict setObject:@([[[NSDate date] dateByAddingTimeInterval:365*24*3600] timeIntervalSince1970]) forKey:@"vip"];
            }
            [dataDict setObject:expires forKey:@"expire_date"];
            [result setObject:dataDict forKey:@"data"];

            NSLog(@"[VCAM] 验证成功, 返回: %@", result);
            if (completion) completion([result copy]);
        } else {
            if (completion) completion(@{@"code": @(-1), @"msg": @"卡密无效"});
        }
    }];
    [task resume];
}

#pragma mark - Hook: showBanAlert: → 拦截封禁弹窗

static void h_showBanAlert(id self, SEL _cmd, id msg) {
    NSLog(@"[VCAM] showBanAlert blocked: %@", msg);
}

#pragma mark - 初始化

__attribute__((constructor))
static void vcam_kami_init(void) {
    NSLog(@"[VCAM] === VCamKamiHook v7 (minimal) ===");

    void (^doHook)(void) = ^{
        Class vmClass = objc_getClass("VCamVerifyManager");
        if (vmClass) {
            SEL sel1 = NSSelectorFromString(@"requestAPIWithAction:kami:isHeartbeat:completion:");
            Method m1 = class_getInstanceMethod(vmClass, sel1);
            if (m1) {
                orig_requestAPI = (void *)method_setImplementation(m1, (IMP)h_requestAPI);
                NSLog(@"[VCAM] Hooked requestAPIWithAction");
            }
        }

        Class mcClass = objc_getClass("VCamMenuVC");
        if (mcClass) {
            SEL selBan = NSSelectorFromString(@"showBanAlert:");
            Method mBan = class_getInstanceMethod(mcClass, selBan);
            if (mBan) {
                orig_showBanAlert = (void *)method_setImplementation(mBan, (IMP)h_showBanAlert);
                NSLog(@"[VCAM] Hooked showBanAlert:");
            }
        }
    };

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

    // 自动恢复上次激活状态
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"vcam_vip_unlocked"]) {
        NSString *kami = [[NSUserDefaults standardUserDefaults] stringForKey:@"vcam_verified_kami"];
        if (kami) {
            g_vipActive = YES;
            g_kami = [kami copy];
            NSLog(@"[VCAM] 已恢复 VIP 状态: %@", kami);
        }
    }

    NSLog(@"[VCAM] VCamKamiHook v7 Ready");
}
