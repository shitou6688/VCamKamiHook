/**
 * vcam_kami_hook.m
 *
 * VCAM 虚拟相机 验证 Hook
 *
 * 功能：
 *   1. 绕过原始服务器验证（原服务器已关闭），直接设置授权状态
 *   2. 解锁声音功能和 VIP 功能
 *   3. 将卡密系统对接到自定义服务器 (app=10003)
 *   4. 重定向原始域名 (vcam.lengye.top / xnsp.v200dd.eu.org) 的请求
 *
 * 编译: GitHub Actions 自动编译
 * 部署: dylib + plist 注入目标 App
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ============ 配置 ============

/// 卡密验证服务器地址
static NSString *const kKamiServerHost   = @"124.221.171.80";
/// 应用 ID (VCAM = 10003)
static NSString *const kKamiAppID        = @"10003";
/// 卡密验证 API 路径
static NSString *const kKamiApiPath      = @"/api.php";
/// 设备注册 API 路径
static NSString *const kKamiRegisterPath = @"/trollstore-device-api.php";

/// 需要重定向的旧域名
static NSString *const kOldDomain1 = @"vcam.lengye.top";
static NSString *const kOldDomain2 = @"xnsp.v200dd.eu.org";

/// NSUserDefaults 键名 (与原 VCAM 一致)
static NSString *const kKeyUseKami    = @"use_kami";
static NSString *const kKeyExpireDate = @"expire_date";

/// 永不过期的授权日期
static NSString *const kForeverExpire = @"2099-12-31 23:59:59";

// ============ Swizzle 辅助 ============

static IMP swizzleInstanceMethod(Class cls, SEL sel, IMP newImp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NULL;
    return method_setImplementation(m, newImp);
}

static IMP swizzleClassMethod(Class cls, SEL sel, IMP newImp) {
    Method m = class_getClassMethod(cls, sel);
    if (!m) return NULL;
    return method_setImplementation(m, newImp);
}

// ============ 原始实现指针 ============

static void  (*orig_startVerifyProcess)(id, SEL);
static void  (*orig_toggleSound)(id, SEL);
static void  (*orig_requestKamiVerify)(id, SEL, id, id);
static void  (*orig_requestAPIWithAction)(id, SEL, id, id, BOOL, id);
static void  (*orig_showKamiInputAlert)(id, SEL, id, id);
static NSURL* (*orig_URLWithString)(id, SEL, NSString*);

// ============ 辅助函数 ============

/// 设置授权状态
static void setAuthorized() {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:YES forKey:kKeyUseKami];
    [defaults setObject:kForeverExpire forKey:kKeyExpireDate];
    [defaults synchronize];
}

/// 获取设备标识 (markcode)
static NSString* getDeviceID() {
    @try {
        Class UIDeviceClass = objc_getClass("UIDevice");
        if (UIDeviceClass) {
            id device = [UIDeviceClass currentDevice];
            if ([device respondsToSelector:@selector(identifierForVendor)]) {
                NSUUID *uuid = [device performSelector:@selector(identifierForVendor)];
                if (uuid) return [uuid UUIDString];
            }
        }
    } @catch (NSException *e) {}
    return [[NSUUID UUID] UUIDString];
}

/// 主线程弹窗
static void showAlertOnMain(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIViewController *rootVC = nil;
            @try {
                rootVC = [UIApplication sharedApplication].keyWindow.rootViewController;
            } @catch (NSException *e) { return; }
            while (rootVC.presentedViewController) {
                rootVC = rootVC.presentedViewController;
            }
            if (!rootVC) return;

            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:title
                                 message:message
                          preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                                      style:UIAlertActionStyleDefault
                                                    handler:nil]];
            [rootVC presentViewController:alert animated:YES completion:nil];
        } @catch (NSException *e) {}
    });
}

/// 尝试刷新 VCamVerifyManager 的 UI
static void tryRefreshUI(id self) {
    @try {
        if ([self respondsToSelector:@selector(refreshUIStates)]) {
            [self performSelector:@selector(refreshUIStates)];
        }
    } @catch (NSException *e) {}
}

// ============ Hook 实现 ============

#pragma mark - Hook: NSURL + URLWithString: (域名重定向)

static NSURL* hook_URLWithString(id self, SEL _cmd, NSString *urlString) {
    if (urlString) {
        if ([urlString containsString:kOldDomain1]) {
            urlString = [urlString stringByReplacingOccurrencesOfString:kOldDomain1
                                                            withString:kKamiServerHost];
        }
        if ([urlString containsString:kOldDomain2]) {
            urlString = [urlString stringByReplacingOccurrencesOfString:kOldDomain2
                                                            withString:kKamiServerHost];
        }
    }
    return orig_URLWithString(self, _cmd, urlString);
}

#pragma mark - Hook: startVerifyProcess (绕过服务器验证)

static void hook_startVerifyProcess(id self, SEL _cmd) {
    setAuthorized();
    tryRefreshUI(self);
}

#pragma mark - Hook: toggleSound (总是允许声音)

static void hook_toggleSound(id self, SEL _cmd) {
    setAuthorized();
    if (orig_toggleSound) {
        orig_toggleSound(self, _cmd);
    }
}

#pragma mark - Hook: requestKamiVerify:completion: (卡密验证对接)

static void hook_requestKamiVerify(id self, SEL _cmd, NSString *kami, id completion) {
    if (!kami || ![kami isKindOfClass:[NSString class]] || kami.length == 0) {
        showAlertOnMain(@"提示", @"卡密不能为空");
        return;
    }

    NSString *deviceID = getDeviceID();
    NSString *encodedKami = [kami stringByAddingPercentEncodingWithAllowedCharacters:
                             [NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *encodedMarkcode = [deviceID stringByAddingPercentEncodingWithAllowedCharacters:
                                 [NSCharacterSet URLQueryAllowedCharacterSet]];

    NSString *urlStr = [NSString stringWithFormat:
        @"http://%@%@?api=kmlogon&app=%@&kami=%@&markcode=%@",
        kKamiServerHost, kKamiApiPath, kKamiAppID, encodedKami, encodedMarkcode];

    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        showAlertOnMain(@"验证失败", @"请求地址无效");
        return;
    }

    NSURLRequest *request = [NSURLRequest requestWithURL:url
                                             cachePolicy:NSURLRequestReloadIgnoringCacheData
                                         timeoutInterval:15.0];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || !data) {
                showAlertOnMain(@"验证失败", @"网络连接失败，请检查网络");
                return;
            }
            @try {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSInteger code = [json[@"code"] integerValue];

                if (code == 200) {
                    setAuthorized();

                    // 后台静默注册设备
                    NSString *model = @"iPhone";
                    NSString *iosVer = @"17.0";
                    NSString *regUrl = [NSString stringWithFormat:
                        @"http://%@%@?api=ts_register&markcode=%@&kami=%@&model=%@&ios=%@",
                        kKamiServerHost, kKamiRegisterPath,
                        encodedMarkcode, encodedKami, model, iosVer];
                    [[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:regUrl]].resume;

                    showAlertOnMain(@"✅ 授权成功",
                                   [NSString stringWithFormat:@"到期时间: %@", kForeverExpire]);
                    tryRefreshUI(self);
                } else {
                    NSString *msg = json[@"msg"] ?: json[@"message"] ?: @"卡密无效或已过期";
                    showAlertOnMain(@"验证失败", [NSString stringWithFormat:@"%@", msg]);
                }
            } @catch (NSException *e) {
                showAlertOnMain(@"验证失败", @"服务器响应格式错误");
            }
        });
    }] resume];
}

#pragma mark - Hook: requestAPIWithAction:kami:isHeartbeat:completion: (拦截心跳和API)

static void hook_requestAPIWithAction(id self, SEL _cmd, id action, id kami,
                                       BOOL isHeartbeat, id completion) {
    if (isHeartbeat) {
        setAuthorized();
        tryRefreshUI(self);
        return;
    }

    NSString *actionStr = nil;
    if ([action isKindOfClass:[NSString class]]) {
        actionStr = (NSString *)action;
    }

    if (actionStr && [actionStr containsString:@"kami"]) {
        hook_requestKamiVerify(self, @selector(requestKamiVerify:completion:), kami, completion);
        return;
    }

    setAuthorized();
    tryRefreshUI(self);
}

#pragma mark - Hook: showKamiInputAlert:completion: (卡密输入弹窗)

static void hook_showKamiInputAlert(id self, SEL _cmd, id title, id completion) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIViewController *rootVC = nil;
            @try {
                rootVC = [UIApplication sharedApplication].keyWindow.rootViewController;
            } @catch (NSException *e) { return; }
            while (rootVC.presentedViewController) {
                rootVC = rootVC.presentedViewController;
            }
            if (!rootVC) return;

            NSString *titleStr = @"激活授权";
            if ([title isKindOfClass:[NSString class]] && [(NSString*)title length] > 0) {
                titleStr = (NSString*)title;
            }

            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:titleStr
                                 message:@"请输入卡密"
                          preferredStyle:UIAlertControllerStyleAlert];

            [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
                textField.placeholder = @"请输入卡密";
                textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
                textField.autocorrectionType = UITextAutocorrectionTypeNo;
            }];

            [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                                      style:UIAlertActionStyleCancel
                                                    handler:nil]];

            [alert addAction:[UIAlertAction actionWithTitle:@"验证"
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction *a) {
                NSString *kami = alert.textFields.firstObject.text;
                hook_requestKamiVerify(self,
                    @selector(requestKamiVerify:completion:), kami, nil);
            }]];

            [rootVC presentViewController:alert animated:YES completion:nil];
        } @catch (NSException *e) {}
    });
}

// ============ 安装 Hooks ============

static void installHooks() {
    @autoreleasepool {
        // 1. Swizzle NSURL + URLWithString: (域名重定向)
        Class nsurlClass = objc_getClass("NSURL");
        if (nsurlClass) {
            orig_URLWithString = (void*)swizzleClassMethod(
                nsurlClass,
                @selector(URLWithString:),
                (IMP)hook_URLWithString);
            if (orig_URLWithString) {
                NSLog(@"[VCAM Hook] NSURL + URLWithString: swizzled");
            }
        }

        // 2. Swizzle VCamVerifyManager 方法
        Class vcamClass = objc_getClass("VCamVerifyManager");
        if (!vcamClass) {
            NSLog(@"[VCAM Hook] VCamVerifyManager not found, will retry");
            return;
        }

        NSLog(@"[VCAM Hook] Found VCamVerifyManager, installing hooks...");

        // startVerifyProcess
        SEL startSel = NSSelectorFromString(@"startVerifyProcess");
        if (class_getInstanceMethod(vcamClass, startSel)) {
            orig_startVerifyProcess = (void*)swizzleInstanceMethod(
                vcamClass, startSel, (IMP)hook_startVerifyProcess);
            NSLog(@"[VCAM Hook] startVerifyProcess swizzled");
        }

        // toggleSound
        SEL soundSel = NSSelectorFromString(@"toggleSound");
        if (class_getInstanceMethod(vcamClass, soundSel)) {
            orig_toggleSound = (void*)swizzleInstanceMethod(
                vcamClass, soundSel, (IMP)hook_toggleSound);
            NSLog(@"[VCAM Hook] toggleSound swizzled");
        }

        // requestKamiVerify:completion:
        SEL kamiSel = NSSelectorFromString(@"requestKamiVerify:completion:");
        if (class_getInstanceMethod(vcamClass, kamiSel)) {
            orig_requestKamiVerify = (void*)swizzleInstanceMethod(
                vcamClass, kamiSel, (IMP)hook_requestKamiVerify);
            NSLog(@"[VCAM Hook] requestKamiVerify:completion: swizzled");
        }

        // requestAPIWithAction:kami:isHeartbeat:completion:
        SEL apiSel = NSSelectorFromString(@"requestAPIWithAction:kami:isHeartbeat:completion:");
        if (class_getInstanceMethod(vcamClass, apiSel)) {
            orig_requestAPIWithAction = (void*)swizzleInstanceMethod(
                vcamClass, apiSel, (IMP)hook_requestAPIWithAction);
            NSLog(@"[VCAM Hook] requestAPIWithAction swizzled");
        }

        // showKamiInputAlert:completion:
        SEL showSel = NSSelectorFromString(@"showKamiInputAlert:completion:");
        if (class_getInstanceMethod(vcamClass, showSel)) {
            orig_showKamiInputAlert = (void*)swizzleInstanceMethod(
                vcamClass, showSel, (IMP)hook_showKamiInputAlert);
            NSLog(@"[VCAM Hook] showKamiInputAlert swizzled");
        }

        NSLog(@"[VCAM Hook] All hooks installed");
    }
}

// ============ 构造函数 ============

__attribute__((constructor))
static void vcam_hook_init() {
    NSLog(@"[VCAM Hook] Initializing...");

    // 立即设置授权
    setAuthorized();
    NSLog(@"[VCAM Hook] Authorization set in NSUserDefaults");

    // 安装 hooks
    installHooks();

    // 如果 VCamVerifyManager 还没加载，延迟重试
    if (!objc_getClass("VCamVerifyManager")) {
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                NSLog(@"[VCAM Hook] Retry 1...");
                installHooks();
                if (!objc_getClass("VCamVerifyManager")) {
                    dispatch_after(
                        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                        dispatch_get_main_queue(), ^{
                            NSLog(@"[VCAM Hook] Retry 2...");
                            installHooks();
                        });
                }
            });
    }

    NSLog(@"[VCAM Hook] Init complete");
}
