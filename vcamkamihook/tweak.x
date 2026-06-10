/**
 * VCamKamiHook v17.1 - 最小测试版
 * 只输出日志，不 hook 任何东西，测试 dylib 是否能正常加载
 */

#import <Foundation/Foundation.h>

__attribute__((constructor))
static void vcam_test_init(void) {
    NSLog(@"[VCAM] === dylib 加载成功! v17.1 test ===");
}
