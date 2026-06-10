/**
 * VCamKamiHook v25 - 极简版
 * 只做两件事：
 * 1. hook requestAPIWithAction，发 POST 到我们服务器
 * 2. 记住卡密，下次自动填入
 * 
 * 不碰 UI、不碰 ivar、不碰 NSUserDefaults
 * VIP 激活完全交给 App 自己的代码处理
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static void (*orig_requestAPI)(id, SEL, NSString *, NSString *, BOOL, void (^)(NSDictionary *));

static void h_requestAPI(id self, SEL _cmd,
    NSString *action, NSString *kami, BOOL isHeartbeat,
    void (^completion)(NSDictionary *)) {
    
    // 如果没传卡密，从 NSUserDefaults 读取上次用的
    NSString *useKami = kami;
    if (!useKami || useKami.length == 0) {
        useKami = [[NSUserDefaults standardUserDefaults] stringForKey:@"vcam_saved_kami"];
    }
    
    NSLog(@"[VCAM] reqAPI: action=%@ kami=%@ saved=%@", action, kami, useKami);
    
    // 获取设备 ID
    NSString *deviceId = [[[UIDevice currentDevice] identifierForVendor] UUIDString] ?: @"unknown";
    @try {
        if ([self respondsToSelector:@selector(getDeviceID)]) {
            id r = [self performSelector:@selector(getDeviceID)];
            if ([r isKindOfClass:[NSString class]] && [(NSString *)r length] > 0) deviceId = r;
        }
    } @catch (NSException *e) {}
    
    // POST 到我们服务器（同行格式）
    NSURL *url = [NSURL URLWithString:@"http://124.221.171.80/vc.php"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:15.0];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    
    NSDictionary *body = @{
        @"appkey": @"H0U66ETGBFEC",
        @"card": useKami ?: @"",
        @"device_id": deviceId
    };
    [req setHTTPBody:[NSJSONSerialization dataWithJSONObject:body options:0 error:nil]];
    
    [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) {
            NSLog(@"[VCAM] error: %@", err.localizedDescription);
            if (completion) completion(@{@"code": @(-1), @"msg": [NSString stringWithFormat:@"网络错误: %@", err.localizedDescription]});
            return;
        }
        
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSLog(@"[VCAM] result: %@", json);
        
        // 成功就记住卡密
        if (json && [json[@"code"] integerValue] == 0) {
            NSString *card = json[@"data"][@"card"];
            if (card && card.length > 0) {
                [[NSUserDefaults standardUserDefaults] setObject:card forKey:@"vcam_saved_kami"];
                [[NSUserDefaults standardUserDefaults] synchronize];
                NSLog(@"[VCAM] saved kami: %@", card);
            }
        }
        
        if (completion) completion(json ?: @{@"code": @(-1), @"msg": @"验证失败"});
    }].resume;
}

__attribute__((constructor))
static void init(void) {
    NSLog(@"[VCAM] === v25 minimal ===");
    
    Class cls = objc_getClass("VCamVerifyManager");
    if (cls) {
        Method m = class_getInstanceMethod(cls, NSSelectorFromString(@"requestAPIWithAction:kami:isHeartbeat:completion:"));
        if (m) {
            orig_requestAPI = (void *)method_setImplementation(m, (IMP)h_requestAPI);
            NSLog(@"[VCAM] Hooked OK");
        }
    }
}
