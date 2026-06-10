/**
 * VCamKamiMemory - 卡密记忆补丁
 * 配合 VCamKamiHook(36).dylib 使用
 * 
 * 功能：
 * 1. 拦截 requestAPIWithAction，成功后保存卡密到 NSUserDefaults
 * 2. 启动时自动恢复已保存的卡密
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static void (*orig_requestAPI)(id, SEL, NSString*, NSString*, BOOL, void(^)(NSDictionary*));

static void h_requestAPI(id self, SEL _cmd, NSString *action, NSString *kami, BOOL isHeartbeat, void(^completion)(NSDictionary*)) {
    orig_requestAPI(self, _cmd, action, kami, isHeartbeat, ^(NSDictionary *result) {
        if (result && [result[@"code"] integerValue] == 0 && kami.length > 0) {
            [[NSUserDefaults standardUserDefaults] setObject:kami forKey:@"vcam_saved_kami"];
            [[NSUserDefaults standardUserDefaults] synchronize];
            NSLog(@"[KamiMem] Saved kami: %@", kami);
        }
        if (completion) completion(result);
    });
}

__attribute__((constructor))
static void kami_mem_init(void) {
    NSLog(@"[KamiMem] === Init ===");
    
    Class cls = objc_getClass("VCamVerifyManager");
    if (cls) {
        SEL sel = NSSelectorFromString(@"requestAPIWithAction:kami:isHeartbeat:completion:");
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            orig_requestAPI = (void*)method_setImplementation(m, (IMP)h_requestAPI);
            NSLog(@"[KamiMem] Hooked requestAPI");
        }
    }
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:@"vcam_saved_kami"];
        if (saved) {
            NSLog(@"[KamiMem] Restoring kami: %@", saved);
            Class cls2 = objc_getClass("VCamVerifyManager");
            if (cls2) {
                id vm = [cls2 performSelector:@selector(sharedInstance)];
                if (vm) {
                    ((void(*)(id,SEL,NSString*,NSString*,BOOL,void(^)(NSDictionary*)))objc_msgSend)(vm, NSSelectorFromString(@"requestAPIWithAction:kami:isHeartbeat:completion:"), @"check", saved, NO, ^(NSDictionary *result) {
                        NSLog(@"[KamiMem] Restore result: %@", result);
                    });
                }
            }
        }
    });
    
    NSLog(@"[KamiMem] Ready");
}
