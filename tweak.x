/**
 * VCamKamiHook v17.2 - 逐步测试：只 hook requestAPIWithAction
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static void (*orig_requestAPI)(id, SEL, NSString *, NSString *, BOOL, void (^)(NSDictionary *));

static void h_requestAPI(id self, SEL _cmd,
    NSString *action, NSString *kami, BOOL isHeartbeat,
    void (^completion)(NSDictionary *)) {
    
    NSLog(@"[VCAM] reqAPI called: action=%@ kami=%@ heartbeat=%d", action, kami, (int)isHeartbeat);
    
    // 先只调原始方法，确认 hook 本身不闪退
    if (orig_requestAPI) {
        orig_requestAPI(self, _cmd, action, kami, isHeartbeat, completion);
    }
}

__attribute__((constructor))
static void vcam_kami_init(void) {
    NSLog(@"[VCAM] === v17.2 test hook ===");
    
    Class vmClass = objc_getClass("VCamVerifyManager");
    if (vmClass) {
        SEL apiSel = NSSelectorFromString(@"requestAPIWithAction:kami:isHeartbeat:completion:");
        Method apiMethod = class_getInstanceMethod(vmClass, apiSel);
        if (apiMethod) {
            orig_requestAPI = (void *)method_setImplementation(apiMethod, (IMP)h_requestAPI);
            NSLog(@"[VCAM] Hooked requestAPIWithAction OK");
        } else {
            NSLog(@"[VCAM] requestAPIWithAction method not found");
        }
    } else {
        NSLog(@"[VCAM] VCamVerifyManager class not found");
    }
    
    NSLog(@"[VCAM] v17.2 Ready");
}
