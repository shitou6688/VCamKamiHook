/**
 * vcam_kami_hook.m
 *
 * VCAM 虚拟相机 验证 Hook v2
 *
 * 修复：
 *   - NSUserDefaults 写入 xnsp suite（原始代码用的自定义域）
 *   - 设置 VCamVerifyManager 内部授权状态 ivar
 *   - 存储服务器返回的 vip 时间戳
 *   - 完整绕过授权检查链
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ============ 配置 ============

static NSString *const kKamiServerHost    = @"124.221.171.80";
static NSString *const kKamiAppID         = @"10003";
static NSString *const kKamiApiPath       = @"/api.php";
static NSString *const kKamiRegisterPath  = @"/trollstore-device-api.php";

/// 需要重定向的旧域名
static NSString *const kOldDomain1 = @"vcam.lengye.top";
static NSString *const kOldDomain2 = @"xnsp.v200dd.eu.org";

/// NSUserDefaults 键名（与原 VCAM 一致）
static NSString *const kKeyUseKami    = @"use_kami";
static NSString *const kKeyExpireDate = @"expire_date";

/// 原始代码用的 NSUserDefaults suite 名
static NSString *const kXnspSuite = @"xnsp";

// ============ 原始实现指针 ============

static void   (*orig_startVerifyProcess)(id, SEL);
static void   (*orig_toggleSound)(id, SEL);
static void   (*orig_requestKamiVerify)(id, SEL, id, id);
static void   (*orig_requestAPIWithAction)(id, SEL, id, id, BOOL, id);
static void   (*orig_showKamiInputAlert)(id, SEL, id, id);
static void   (*orig_verifyAndProceed)(id, SEL, id);
static void   (*orig_unlock)(id, SEL);
static NSURL* (*orig_URLWithString)(id, SEL, NSString*);

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

// ============ 授权状态管理 ============

/// 获取 xnsp suite 的 NSUserDefaults
static NSUserDefaults* xnspDefaults() {
    return [[NSUserDefaults alloc] initWithSuiteName:kXnspSuite];
}

/// 设置授权状态（同时写标准域和 xnsp 域）
static void setAuthorized(NSString *vipTimestamp) {
    // 标准 NSUserDefaults
    NSUserDefaults *std = [NSUserDefaults standardUserDefaults];
    [std setBool:YES forKey:kKeyUseKami];
    if (vipTimestamp) {
        [std setObject:vipTimestamp forKey:kKeyExpireDate];
    }
    [std synchronize];

    // xnsp 域（原始代码实际读取的地方）
    NSUserDefaults *xnsp = xnspDefaults();
    [xnsp setBool:YES forKey:kKeyUseKami];
    if (vipTimestamp) {
        [xnsp setObject:vipTimestamp forKey:kKeyExpireDate];
    }
    [xnsp synchronize];

    NSLog(@"[VCAM Hook] Authorization set: use_kami=YES, expire_date=%@", vipTimestamp);
}

/// 设置 VCamVerifyManager 的内部授权 ivar
static void setInternalAuthState(id self) {
    @try {
        unsigned int ivarCount = 0;
        Ivar *ivars = class_copyIvarList(object_getClass(self), &ivarCount);
        for (unsigned int i = 0; i < ivarCount; i++) {
            const char *name = ivar_getName(ivars[i]);
            if (!name) continue;
            NSString *ivarName = [NSString stringWithUTF8String:name];

            // 常见的授权相关 ivar 名
            if ([ivarName containsString:@"kami"] ||
                [ivarName containsString:@"Kami"] ||
                [ivarName containsString:@"vip"] ||
                [ivarName containsString:@"VIP"] ||
                [ivarName containsString:@"Vip"] ||
                [ivarName containsString:@"auth"] ||
                [ivarName containsString:@"Auth"] ||
                [ivarName containsString:@"authorized"] ||
                [ivarName containsString:@"Authorized"] ||
                [ivarName containsString:@"isAuth"] ||
                [ivarName containsString:@"isVip"] ||
                [ivarName containsString:@"isKami"] ||
                [ivarName containsString:@"verified"] ||
                [ivarName containsString:@"Verified"] ||
                [ivarName containsString:@"expire"]) {

                const char *type = ivar_getTypeEncoding(ivars[i]);
                NSLog(@"[VCAM Hook] Found auth ivar: %s (%s)", name, type ?: "?");

                if (type) {
                    if (type[0] == 'B' || type[0] == 'c') {
                        // BOOL / char
                        object_setIvar(self, ivars[i], @YES);
                        NSLog(@"[VCAM Hook]   -> set to YES");
                    } else if (type[0] == 'i' || type[0] == 'I' ||
                               type[0] == 'l' || type[0] == 'L' ||
                               type[0] == 'q' || type[0] == 'Q') {
                        // Integer types -> set to 1
                        object_setIvar(self, ivars[i], @(1));
                        NSLog(@"[VCAM Hook]   -> set to 1");
                    } else if (type[0] == '@') {
                        // Object type
                        if ([ivarName containsString:@"expire"] || [ivarName containsString:@"Expire"]) {
                            object_setIvar(self, ivars[i], @"2099-12-31 23:59:59");
                            NSLog(@"[VCAM Hook]   -> set expire date string");
                        } else if ([ivarName containsString:@"kami"] || [ivarName containsString:@"Kami"]) {
                            // 可能是存储卡密的字符串，不强制修改
                            NSLog(@"[VCAM Hook]   -> skip (kami string, not a flag)");
                        } else {
                            object_setIvar(self, ivars[i], @YES);
                            NSLog(@"[VCAM Hook]   -> set to @YES");
                        }
                    }
                }
            }
        }
        if (ivars) free(ivars);

        // 同时检查父类
        Class superClass = class_getSuperclass(object_getClass(self));
        if (superClass && superClass != [NSObject class]) {
            unsigned int scCount = 0;
            Ivar *scIvars = class_copyIvarList(superClass, &scCount);
            for (unsigned int i = 0; i < scCount; i++) {
                const char *name = ivar_getName(scIvars[i]);
                if (!name) continue;
                NSString *ivarName = [NSString stringWithUTF8String:name];

                if ([ivarName containsString:@"kami"] || [ivarName containsString:@"Kami"] ||
                    [ivarName containsString:@"vip"] || [ivarName containsString:@"VIP"] ||
                    [ivarName containsString:@"auth"] || [ivarName containsString:@"Auth"] ||
                    [ivarName containsString:@"authorized"] || [ivarName containsString:@"isAuth"] ||
                    [ivarName containsString:@"isVip"] || [ivarName containsString:@"verified"]) {

                    const char *type = ivar_getTypeEncoding(scIvars[i]);
                    NSLog(@"[VCAM Hook] Found auth ivar in superclass: %s (%s)", name, type ?: "?");

                    if (type && (type[0] == 'B' || type[0] == 'c')) {
                        object_setIvar(self, scIvars[i], @YES);
                        NSLog(@"[VCAM Hook]   -> set to YES");
                    } else if (type && (type[0] == 'i' || type[0] == 'I' || type[0] == 'l' || type[0] == 'q')) {
                        object_setIvar(self, scIvars[i], @(1));
                        NSLog(@"[VCAM Hook]   -> set to 1");
                    }
                }
            }
            if (scIvars) free(scIvars);
        }
    } @catch (NSException *e) {
        NSLog(@"[VCAM Hook] Error setting internal auth state: %@", e);
    }
}

// ============ 辅助函数 ============

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
                alertControllerWithTitle:title message:message
                          preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                                      style:UIAlertActionStyleDefault handler:nil]];
            [rootVC presentViewController:alert animated:YES completion:nil];
        } @catch (NSException *e) {}
    });
}

static void tryRefreshUI(id self) {
    @try {
        if ([self respondsToSelector:@selector(refreshUIStates)]) {
            [self performSelector:@selector(refreshUIStates)];
        }
    } @catch (NSException *e) {}
}

// ============ Hook 实现 ============

#pragma mark - NSURL + URLWithString: (域名重定向)

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

#pragma mark - startVerifyProcess (绕过服务器验证)

static void hook_startVerifyProcess(id self, SEL _cmd) {
    NSLog(@"[VCAM Hook] startVerifyProcess intercepted");
    setAuthorized(@"4102243200");  // 远未来时间戳
    setInternalAuthState(self);
    tryRefreshUI(self);
}

#pragma mark - toggleSound (直接允许声音)

static void hook_toggleSound(id self, SEL _cmd) {
    NSLog(@"[VCAM Hook] toggleSound intercepted");
    // 确保授权状态已设置
    setAuthorized(@"4102243200");
    setInternalAuthState(self);

    // 调用原始方法
    if (orig_toggleSound) {
        orig_toggleSound(self, _cmd);
    }
}

#pragma mark - verifyAndProceed: (授权验证直接通过)

static void hook_verifyAndProceed(id self, SEL _cmd, id sender) {
    NSLog(@"[VCAM Hook] verifyAndProceed intercepted");
    setAuthorized(@"4102243200");
    setInternalAuthState(self);
    tryRefreshUI(self);
}

#pragma mark - unlock (直接解锁)

static void hook_unlock(id self, SEL _cmd) {
    NSLog(@"[VCAM Hook] unlock intercepted");
    setAuthorized(@"4102243200");
    setInternalAuthState(self);
    tryRefreshUI(self);
}

#pragma mark - requestKamiVerify:completion: (卡密验证对接)

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
                    // 从服务器响应中提取 vip 时间戳
                    NSString *vipTimestamp = nil;
                    if ([json[@"msg"] isKindOfClass:[NSDictionary class]]) {
                        vipTimestamp = json[@"msg"][@"vip"];
                        if (![vipTimestamp isKindOfClass:[NSString class]]) {
                            vipTimestamp = [vipTimestamp stringValue];
                        }
                    }
                    if (!vipTimestamp) vipTimestamp = @"4102243200";

                    // 设置授权
                    setAuthorized(vipTimestamp);
                    setInternalAuthState(self);

                    // 后台注册设备
                    NSString *regUrl = [NSString stringWithFormat:
                        @"http://%@%@?api=ts_register&markcode=%@&kami=%@&model=iPhone&ios=17.0",
                        kKamiServerHost, kKamiRegisterPath, encodedMarkcode, encodedKami];
                    [[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:regUrl]].resume;

                    showAlertOnMain(@"✅ 授权成功",
                                   [NSString stringWithFormat:@"到期时间: %@", vipTimestamp]);
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

#pragma mark - requestAPIWithAction:kami:isHeartbeat:completion:

static void hook_requestAPIWithAction(id self, SEL _cmd, id action, id kami,
                                       BOOL isHeartbeat, id completion) {
    if (isHeartbeat) {
        setAuthorized(@"4102243200");
        setInternalAuthState(self);
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

    setAuthorized(@"4102243200");
    setInternalAuthState(self);
    tryRefreshUI(self);
}

#pragma mark - showKamiInputAlert:completion:

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
                alertControllerWithTitle:titleStr message:@"请输入卡密"
                          preferredStyle:UIAlertControllerStyleAlert];

            [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
                textField.placeholder = @"请输入卡密";
                textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
                textField.autocorrectionType = UITextAutocorrectionTypeNo;
            }];

            [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                                      style:UIAlertActionStyleCancel handler:nil]];

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
        // 1. NSURL 域名重定向
        Class nsurlClass = objc_getClass("NSURL");
        if (nsurlClass) {
            orig_URLWithString = (void*)swizzleClassMethod(
                nsurlClass, @selector(URLWithString:), (IMP)hook_URLWithString);
            if (orig_URLWithString) {
                NSLog(@"[VCAM Hook] NSURL + URLWithString: swizzled");
            }
        }

        // 2. VCamVerifyManager
        Class vcamClass = objc_getClass("VCamVerifyManager");
        if (!vcamClass) {
            NSLog(@"[VCAM Hook] VCamVerifyManager not found, will retry");
            return;
        }

        NSLog(@"[VCAM Hook] Found VCamVerifyManager, installing hooks...");

        // 打印所有 ivar 名称（调试用）
        unsigned int ivarCount = 0;
        Ivar *ivars = class_copyIvarList(vcamClass, &ivarCount);
        NSLog(@"[VCAM Hook] VCamVerifyManager has %u ivars:", ivarCount);
        for (unsigned int i = 0; i < ivarCount; i++) {
            const char *name = ivar_getName(ivars[i]);
            const char *type = ivar_getTypeEncoding(ivars[i]);
            NSLog(@"[VCAM Hook]   ivar[%u]: %s (%s)", i, name ?: "?", type ?: "?");
        }
        if (ivars) free(ivars);

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

        // verifyAndProceed:
        SEL verifySel = NSSelectorFromString(@"verifyAndProceed:");
        if (class_getInstanceMethod(vcamClass, verifySel)) {
            orig_verifyAndProceed = (void*)swizzleInstanceMethod(
                vcamClass, verifySel, (IMP)hook_verifyAndProceed);
            NSLog(@"[VCAM Hook] verifyAndProceed: swizzled");
        }

        // unlock
        SEL unlockSel = NSSelectorFromString(@"unlock");
        if (class_getInstanceMethod(vcamClass, unlockSel)) {
            orig_unlock = (void*)swizzleInstanceMethod(
                vcamClass, unlockSel, (IMP)hook_unlock);
            NSLog(@"[VCAM Hook] unlock swizzled");
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
    NSLog(@"[VCAM Hook] v2 Initializing...");

    // 立即设置 NSUserDefaults（两个域都写）
    setAuthorized(@"4102243200");

    installHooks();

    // 延迟重试 + 再次强制设置内部状态
    if (!objc_getClass("VCamVerifyManager")) {
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                NSLog(@"[VCAM Hook] Retry 1...");
                setAuthorized(@"4102243200");
                installHooks();

                // 获取单例并设置内部状态
                Class vcamClass = objc_getClass("VCamVerifyManager");
                if (vcamClass) {
                    id shared = [vcamClass performSelector:@selector(sharedInstance)];
                    if (shared) {
                        setInternalAuthState(shared);
                        tryRefreshUI(shared);
                    }
                }

                if (!objc_getClass("VCamVerifyManager")) {
                    dispatch_after(
                        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                        dispatch_get_main_queue(), ^{
                            NSLog(@"[VCAM Hook] Retry 2...");
                            setAuthorized(@"4102243200");
                            installHooks();
                            Class cls = objc_getClass("VCamVerifyManager");
                            if (cls) {
                                id inst = [cls performSelector:@selector(sharedInstance)];
                                if (inst) {
                                    setInternalAuthState(inst);
                                    tryRefreshUI(inst);
                                }
                            }
                        });
                }
            });
    } else {
        // 类已存在，立即设置内部状态
        Class vcamClass = objc_getClass("VCamVerifyManager");
        id shared = [vcamClass performSelector:@selector(sharedInstance)];
        if (shared) {
            setInternalAuthState(shared);
        }
    }

    NSLog(@"[VCAM Hook] v2 Init complete");
}
