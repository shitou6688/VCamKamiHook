/**
 * VCamKamiMemory v2 - 卡密记忆 + 自动补充
 * 配合 VCamKamiHook(36).dylib 使用
 * 
 * 核心功能：
 * 1. 当 kami 为空时，自动用已保存的卡密补充
 * 2. 成功后保存卡密到 NSUserDefaults
 * 3. 从 v36 保存的 vcam_verified_kami 读取（兼容）
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static void (*orig_requestAPI)(id, SEL, NSString*, NSString*, BOOL, void(^)(NSDictionary*));
static SEL g_sel = NULL;

static void h_requestAPI(id self, SEL _cmd, NSString *action, NSString *kami, BOOL isHeartbeat, void(^completion)(NSDictionary*)) {
    NSString *useKami = kami;
    
    // 关键修复：kami 为空时，自动用保存的卡密补充
    if (!useKami || useKami.length == 0) {
        // 先从自己保存的 key 读
        useKami = [[NSUserDefaults standardUserDefaults] stringForKey:@"vcam_saved_kami"];
        // 再从 v36 保存的 key 读
        if (!useKami) {
            useKami = [[NSUserDefaults standardUserDefaults] stringForKey:@"vcam_verified_kami"];
        }
        if (useKami) {
            NSLog(@"[KamiMem] Auto-fill kami: %@", useKami);
        }
    }
    
    // 调原始方法（v36 的 hook 或 App 原始方法）
    orig_requestAPI(self, _cmd, action, useKami, isHeartbeat, ^(NSDictionary *result) {
        // 成功时保存卡密
        if (result && [result[@"code"] integerValue] == 0 && useKami.length > 0) {
            [[NSUserDefaults standardUserDefaults] setObject:useKami forKey:@"vcam_saved_kami"];
            [[NSUserDefaults standardUserDefaults] synchronize];
            NSLog(@"[KamiMem] Saved kami: %@", useKami);
        }
        if (completion) completion(result);
    });
}

__attribute__((constructor))
static void kami_mem_init(void) {
    NSLog(@"[KamiMem] === v2 Init ===");
    
    Class cls = objc_getClass("VCamVerifyManager");
    if (cls) {
        g_sel = NSSelectorFromString(@"requestAPIWithAction:kami:isHeartbeat:completion:");
        Method m = class_getInstanceMethod(cls, g_sel);
        if (m) {
            orig_requestAPI = (void*)method_setImplementation(m, (IMP)h_requestAPI);
            NSLog(@"[KamiMem] Hooked requestAPI, orig=%p", orig_requestAPI);
        }
    }
    
    NSLog(@"[KamiMem] Ready");
}
