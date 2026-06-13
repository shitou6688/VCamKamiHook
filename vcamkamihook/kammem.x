/**
 * VCamKamiMemory v3 - 卡密记忆 + 启动强制恢复VIP
 * 配合 VCamKamiHook(36).dylib 使用
 * 
 * 1. kami 为空时自动用保存的卡密补充
 * 2. 启动时直接恢复 VIP 状态（不依赖 v36 的 llyKeychain）
 * 3. 成功后保存卡密
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static void (*orig_requestAPI)(id, SEL, NSString*, NSString*, BOOL, void(^)(NSDictionary*));
static SEL g_sel = NULL;

#pragma mark - 读取保存的卡密

static NSString* getSavedKami(void) {
    NSString *kami = [[NSUserDefaults standardUserDefaults] stringForKey:@"vcam_saved_kami"];
    if (!kami) kami = [[NSUserDefaults standardUserDefaults] stringForKey:@"vcam_verified_kami"];
    return kami;
}

#pragma mark - 强制恢复 VIP 状态

static void forceRestoreVIP(NSString *kami) {
    if (!kami) return;
    NSLog(@"[KamiMem] Force restoring VIP with kami: %@", kami);
    
    // NSUserDefaults
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"vcam_vip_unlocked"];
    [[NSUserDefaults standardUserDefaults] setObject:kami forKey:@"vcam_saved_kami"];
    [[NSUserDefaults standardUserDefaults] setObject:kami forKey:@"vcam_verified_kami"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    // VCamVerifyManager ivar "vip"
    @try {
        Class cls = objc_getClass("VCamVerifyManager");
        if (cls) {
            id vm = [cls performSelector:@selector(sharedInstance)];
            if (vm) {
                unsigned int cnt = 0;
                Ivar *ivs = class_copyIvarList(cls, &cnt);
                for (unsigned int i = 0; i < cnt; i++) {
                    const char *nm = ivar_getName(ivs[i]);
                    const char *tp = ivar_getTypeEncoding(ivs[i]);
                    if (!nm) continue;
                    NSString *n = [NSString stringWithUTF8String:nm];
                    NSString *t = tp ? [NSString stringWithUTF8String:tp] : @"";
                    @try {
                        if ([n isEqualToString:@"vip"]) {
                            object_setIvar(vm, ivs[i], kami);
                            NSLog(@"[KamiMem] Set vip ivar = %@", kami);
                        } else if ([t hasPrefix:@"c"] || [t hasPrefix:@"B"]) {
                            NSString *low = n.lowercaseString;
                            if ([low containsString:@"vip"] || [low containsString:@"unlock"] || 
                                [low containsString:@"auth"] || [low containsString:@"verify"] ||
                                [low containsString:@"active"]) {
                                object_setIvar(vm, ivs[i], @YES);
                            }
                        }
                    } @catch (NSException *e) {}
                }
                free(ivs);
            }
        }
    } @catch (NSException *e) {}
    
    // UI 刷新
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
                
                // authStatusLabel
                @try {
                    UILabel *label = [menuVC valueForKey:@"authStatusLabel"];
                    if (label) {
                        label.text = @"已激活";
                        label.textColor = [UIColor greenColor];
                    }
                } @catch (NSException *e) {}
                
                // 启用按钮
                for (NSString *name in @[@"btnLoop", @"btnSound", @"btnRotate", @"btnMirror", @"btnReplacement", @"btnPhotoReplacement"]) {
                    @try {
                        UIButton *btn = [menuVC valueForKey:name];
                        if (btn) {
                            btn.enabled = YES;
                            btn.alpha = 1.0;
                        }
                    } @catch (NSException *e) {}
                }
                
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

#pragma mark - Hook

static void h_requestAPI(id self, SEL _cmd, NSString *action, NSString *kami, BOOL isHeartbeat, void(^completion)(NSDictionary*)) {
    NSString *useKami = kami;
    
    // kami 为空时自动补充
    if (!useKami || useKami.length == 0) {
        useKami = getSavedKami();
        if (useKami) {
            NSLog(@"[KamiMem] Auto-fill kami for action=%@: %@", action, useKami);
        }
    }
    
    orig_requestAPI(self, _cmd, action, useKami, isHeartbeat, ^(NSDictionary *result) {
        if (result && [result[@"code"] integerValue] == 0 && useKami.length > 0) {
            [[NSUserDefaults standardUserDefaults] setObject:useKami forKey:@"vcam_saved_kami"];
            [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"vcam_vip_unlocked"];
            [[NSUserDefaults standardUserDefaults] synchronize];
            NSLog(@"[KamiMem] Saved kami: %@", useKami);
        }
        if (completion) completion(result);
    });
}

#pragma mark - Constructor

__attribute__((constructor))
static void kami_mem_init(void) {
    NSLog(@"[KamiMem] === v3 Init ===");
    
    Class cls = objc_getClass("VCamVerifyManager");
    if (cls) {
        g_sel = NSSelectorFromString(@"requestAPIWithAction:kami:isHeartbeat:completion:");
        Method m = class_getInstanceMethod(cls, g_sel);
        if (m) {
            orig_requestAPI = (void*)method_setImplementation(m, (IMP)h_requestAPI);
            NSLog(@"[KamiMem] Hooked requestAPI");
        }
    }
    
    // 启动时强制恢复 VIP
    NSString *saved = getSavedKami();
    if (saved && [[NSUserDefaults standardUserDefaults] boolForKey:@"vcam_vip_unlocked"]) {
        // 延迟 3 秒等 UI 加载完
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            forceRestoreVIP(saved);
        });
        // 再延迟 6 秒做第二次（确保万无一失）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            forceRestoreVIP(saved);
        });
    }
    
    NSLog(@"[KamiMem] Ready, saved kami=%@", saved ?: @"(none)");
}
