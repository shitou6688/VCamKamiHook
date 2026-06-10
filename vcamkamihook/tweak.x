/**
 * VCamKamiHook v36 - 恢复自 VCamKamiHook(36).dylib 反编译
 * 
 * 方案：hook requestAPIWithAction:kami:isHeartbeat:completion:
 * 自己发 POST 到 http://124.221.171.80/vc.php
 * 成功后：setBool, llyKeychain, set ivar "vip", UI 刷新
 * 启动时自动恢复 VIP（从 NSUserDefaults/llyKeychain 读）
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Original function pointer
static void (*orig_requestAPI)(id, SEL, NSString*, NSString*, BOOL, void(^)(NSDictionary*));

#pragma mark - Helper: get device ID

static NSString* getDeviceID(void) {
    NSString *udid = nil;
    @try {
        id identifier = [[UIDevice currentDevice] performSelector:@selector(identifierForVendor)];
        if (identifier) udid = [identifier performSelector:@selector(UUIDString)];
    } @catch (NSException *e) {}
    if (!udid) udid = @"unknown";
    return udid;
}

#pragma mark - Helper: save kami to Keychain

static void saveToKeychain(NSString *kami) {
    @try {
        Class kcClass = NSClassFromString(@"llyKeychain");
        if (kcClass) {
            SEL saveSel = NSSelectorFromString(@"setPassword:forService:account:");
            if ([kcClass respondsToSelector:saveSel]) {
                ((void(*)(id,SEL,id,id,id))objc_msgSend)(kcClass, saveSel, kami, @"vcam_kami", @"vcam_kami");
            }
        }
    } @catch (NSException *e) {}
}

#pragma mark - Helper: load kami from Keychain

static NSString* loadFromKeychain(void) {
    @try {
        Class kcClass = NSClassFromString(@"llyKeychain");
        if (kcClass) {
            SEL loadSel = NSSelectorFromString(@"passwordForService:account:");
            if ([kcClass respondsToSelector:loadSel]) {
                return ((id(*)(id,SEL,id,id))objc_msgSend)(kcClass, loadSel, @"vcam_kami", @"vcam_kami");
            }
        }
    } @catch (NSException *e) {}
    return nil;
}

#pragma mark - Helper: activate VIP fully

static void activateVIP(NSString *kami) {
    NSLog(@"[VCAM] VIP fully unlocked");
    
    // NSUserDefaults
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"vcam_vip_unlocked"];
    [[NSUserDefaults standardUserDefaults] setObject:kami forKey:@"vcam_verified_kami"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    // llyKeychain
    saveToKeychain(kami);
    
    // Set VCamVerifyManager ivar "vip"
    @try {
        Class cls = objc_getClass("VCamVerifyManager");
        if (cls) {
            id vm = [cls performSelector:@selector(sharedInstance)];
            if (vm) {
                Ivar vipIvar = class_getInstanceVariable(cls, "vip");
                if (vipIvar) {
                    object_setIvar(vm, vipIvar, kami);
                }
            }
        }
    } @catch (NSException *e) {}
    
    // UI
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                UIViewController *root = w.rootViewController;
                if (!root) continue;
                UIViewController *p = root;
                while (p.presentedViewController) p = p.presentedViewController;
                
                // Find VCamMenuVC
                UIViewController *menuVC = nil;
                if ([p isKindOfClass:NSClassFromString(@"VCamMenuVC")]) menuVC = p;
                if (!menuVC) {
                    for (UIViewController *c in root.childViewControllers) {
                        if ([c isKindOfClass:NSClassFromString(@"VCamMenuVC")]) { menuVC = c; break; }
                    }
                }
                if (!menuVC) continue;
                
                // authStatusLabel
                @try {
                    UILabel *label = [menuVC valueForKey:@"authStatusLabel"];
                    if (label) {
                        label.text = @"已激活";
                        label.textColor = [UIColor greenColor];
                    }
                } @catch (NSException *e) {}
                
                // Enable buttons
                for (NSString *name in @[@"btnLoop", @"btnSound", @"btnRotate", @"btnMirror", @"btnReplacement", @"btnPhotoReplacement"]) {
                    @try {
                        UIButton *btn = [menuVC valueForKey:name];
                        if (btn) {
                            [btn setEnabled:YES];
                            [btn setAlpha:1.0];
                        }
                    } @catch (NSException *e) {}
                }
                
                // showToast
                @try {
                    if ([menuVC respondsToSelector:@selector(showToast:)]) {
                        [menuVC performSelector:@selector(showToast:) withObject:@"VIP已激活"];
                    }
                } @catch (NSException *e) {}
                
                // refreshUIStates
                @try {
                    if ([menuVC respondsToSelector:@selector(refreshUIStates)]) {
                        [menuVC performSelector:@selector(refreshUIStates)];
                    }
                } @catch (NSException *e) {}
                
                break;
            }
        } @catch (NSException *e) {}
    });
}

#pragma mark - Hook: requestAPIWithAction

static void h_requestAPIWithAction(id self, SEL _cmd, NSString *action, NSString *kami, BOOL isHeartbeat, void(^completion)(NSDictionary*)) {
    NSLog(@"[VCAM] Intercepted: action=%@, kami=%@, heartbeat=%d", action, kami, isHeartbeat);
    
    // 如果是心跳且已有 VIP，直接返回成功
    if (isHeartbeat) {
        NSString *savedKami = [[NSUserDefaults standardUserDefaults] stringForKey:@"vcam_verified_kami"];
        if (!savedKami) savedKami = loadFromKeychain();
        if (savedKami) {
            activateVIP(savedKami);
            if (completion) completion(@{@"code": @0, @"msg": @"ok", @"data": @{@"status": @"active"}});
            return;
        }
    }
    
    NSString *useKami = kami;
    if (!useKami || useKami.length == 0) {
        // 尝试恢复已保存的卡密
        useKami = [[NSUserDefaults standardUserDefaults] stringForKey:@"vcam_verified_kami"];
        if (!useKami) useKami = loadFromKeychain();
        if (!useKami) {
            NSLog(@"[VCAM] No kami provided");
            if (completion) completion(@{@"code": @(-1), @"msg": @"请输入卡密"});
            return;
        }
    }
    
    NSString *deviceID = getDeviceID();
    NSLog(@"[VCAM] deviceID=%@", deviceID);
    
    // 构建 POST 请求到我们服务器
    NSDictionary *body = @{
        @"appkey": @"H0U66ETGBFEC",
        @"card": useKami,
        @"device_id": deviceID
    };
    
    NSError *jsonErr = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonErr];
    if (jsonErr) {
        if (completion) completion(@{@"code": @(-1), @"msg": @"JSON error"});
        return;
    }
    
    NSString *urlStr = @"http://124.221.171.80/vc.php";
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    [req setHTTPMethod:@"POST"];
    [req setHTTPBody:bodyData];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"TrollInstallerX/1.0" forHTTPHeaderField:@"User-Agent"];
    
    [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            NSLog(@"[VCAM] Network error: %@", error.localizedDescription);
            if (completion) completion(@{@"code": @(-1), @"msg": @"网络错误"});
            return;
        }
        
        if (!data) {
            NSLog(@"[VCAM] JSON parse error");
            if (completion) completion(@{@"code": @(-1), @"msg": @"空响应"});
            return;
        }
        
        NSError *parseErr = nil;
        NSDictionary *result = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseErr];
        if (parseErr || ![result isKindOfClass:[NSDictionary class]]) {
            NSLog(@"[VCAM] JSON parse error");
            if (completion) completion(@{@"code": @(-1), @"msg": @"解析错误"});
            return;
        }
        
        NSInteger code = [result[@"code"] integerValue];
        NSString *msg = result[@"msg"] ?: @"";
        NSLog(@"[VCAM] Response: code=%ld, msg=%@", (long)code, msg);
        
        if (code == 0) {
            activateVIP(useKami);
        }
        
        if (completion) completion(result);
    }].resume];
}

#pragma mark - Auto-restore VIP on launch

static void autoRestoreVIP(void) {
    NSString *savedKami = [[NSUserDefaults standardUserDefaults] stringForKey:@"vcam_verified_kami"];
    if (!savedKami) savedKami = loadFromKeychain();
    if (savedKami && [[NSUserDefaults standardUserDefaults] boolForKey:@"vcam_vip_unlocked"]) {
        NSLog(@"[VCAM] Auto-restored VIP");
        activateVIP(savedKami);
    }
}

#pragma mark - Constructor

__attribute__((constructor))
static void vcam_kami_init(void) {
    NSLog(@"[VCAM] === VCAM Kami Hook ===");
    
    Class cls = objc_getClass("VCamVerifyManager");
    if (!cls) {
        NSLog(@"[VCAM] VCamVerifyManager not found");
        return;
    }
    
    SEL sel = NSSelectorFromString(@"requestAPIWithAction:kami:isHeartbeat:completion:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        NSLog(@"[VCAM] Method not found");
        return;
    }
    
    orig_requestAPI = (void*)method_setImplementation(m, (IMP)h_requestAPIWithAction);
    NSLog(@"[VCAM] Hooked requestAPIWithAction:kami:isHeartbeat:completion:");
    
    // 延迟自动恢复
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        autoRestoreVIP();
    });
    
    NSLog(@"[VCAM Kami Hook] Ready");
}
