/**
 * VCamKamiHook v17 - 完全模仿同行 v5 方案
 * 
 * 基于 vcam_kami(5).dylib 逆向：
 * - hook requestAPIWithAction，完全替换原始请求
 * - 自己发 POST 请求到卡密服务器（sharedSession + HTTPBody）
 * - 成功后操作 VCamMenuVC UI
 * - 用 NSTimer 定时检查 VIP 状态
 * - 用 presentedViewController 找 VC
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static void (*orig_requestAPI)(id, SEL, NSString *, NSString *, BOOL, void (^)(NSDictionary *));

static void h_requestAPI(id self, SEL _cmd,
    NSString *action, NSString *kami, BOOL isHeartbeat,
    void (^completion)(NSDictionary *)) {
    
    NSLog(@"[VCAM] reqAPI: action=%@ kami=%@ heartbeat=%d", action, kami, (int)isHeartbeat);
    
    // 没有 kami 的时候也自己处理（check 请求）
    if (!kami) kami = @"";
    
    // 获取设备 ID：用 IDFV
    NSString *deviceID = @"unknown";
    @try {
        deviceID = [[[UIDevice currentDevice] identifierForVendor] UUIDString] ?: @"unknown";
    } @catch (NSException *e) {}
    
    // 构造 POST 请求（同行用 POST + JSON body）
    NSURL *url = [NSURL URLWithString:@"http://124.221.171.80/vcam_api.php"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:15.0];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"TrollInstallerX/1.0" forHTTPHeaderField:@"User-Agent"];
    
    // JSON body
    NSDictionary *body = @{
        @"action": action ?: @"check",
        @"kami": kami,
        @"udid": deviceID,
        @"ts": [NSString stringWithFormat:@"%lld", (long long)[[NSDate date] timeIntervalSince1970]],
        @"sign": @"0"
    };
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [request setHTTPBody:bodyData];
    
    // 用 sharedSession（同行就是这么做的）
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) {
                NSLog(@"[VCAM] 网络错误: %@", error);
                if (completion) completion(@{
                    @"code": @(-1),
                    @"msg": [NSString stringWithFormat:@"网络错误: %@", error.localizedDescription]
                });
                return;
            }
            
            NSDictionary *json = nil;
            if (data) {
                json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            }
            
            NSLog(@"[VCAM] 服务器返回: %@", json);
            
            if (!json) {
                if (completion) completion(@{@"code": @(-1), @"msg": @"服务器返回格式错误"});
                return;
            }
            
            NSInteger code = [json[@"code"] integerValue];
            if (code == 0) {
                // 激活 VIP
                NSLog(@"[VCAM] 激活 VIP!");
                
                // NSUserDefaults
                [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"vcam_vip_unlocked"];
                [[NSUserDefaults standardUserDefaults] setObject:kami forKey:@"vcam_verified_kami"];
                [[NSUserDefaults standardUserDefaults] synchronize];
                
                // Keychain
                @try {
                    Class kcClass = objc_getClass("llyKeychain");
                    if (kcClass) {
                        SEL setPwSel = NSSelectorFromString(@"setPassword:forService:account:");
                        if ([kcClass respondsToSelector:setPwSel]) {
                            ((void(*)(id, SEL, id, id, id))objc_msgSend)(kcClass, setPwSel, kami, @"vcam_kami", @"vcam_kami");
                        }
                    }
                } @catch (NSException *e) {}
                
                // UI 操作（主线程）
                dispatch_async(dispatch_get_main_queue(), ^{
                    @try {
                        for (UIWindow *window in [UIApplication sharedApplication].windows) {
                            UIViewController *rootVC = window.rootViewController;
                            if (!rootVC) continue;
                            
                            // 用 presentedViewController 查找（同行做法）
                            UIViewController *vc = rootVC.presentedViewController ?: rootVC;
                            while (vc.presentedViewController) {
                                vc = vc.presentedViewController;
                            }
                            
                            // 也尝试 childViewControllers
                            __block UIViewController *found = nil;
                            void (^findVC)(UIViewController *) = ^(UIViewController *v) {
                                if (found) return;
                                if ([v isKindOfClass:NSClassFromString(@"VCamMenuVC")]) {
                                    found = v;
                                    return;
                                }
                                findVC(v.presentedViewController ?: v);
                                for (UIViewController *child in v.childViewControllers) {
                                    findVC(child);
                                    if (found) return;
                                }
                            };
                            findVC(rootVC);
                            
                            if (!found) found = vc;
                            
                            // authStatusLabel
                            @try {
                                id label = [found valueForKey:@"authStatusLabel"];
                                if (label && [label isKindOfClass:[UILabel class]]) {
                                    [(UILabel *)label setText:@"已激活"];
                                    [(UILabel *)label setTextColor:[UIColor greenColor]];
                                }
                            } @catch (NSException *e) {}
                            
                            // 启用按钮
                            for (NSString *name in @[@"btnLoop", @"btnSound", @"btnRotate",
                                                     @"btnMirror", @"btnReplacement", @"btnPhotoReplacement"]) {
                                @try {
                                    id btn = [found valueForKey:name];
                                    if (btn && [btn isKindOfClass:[UIButton class]]) {
                                        [(UIButton *)btn setEnabled:YES];
                                        [(UIButton *)btn setAlpha:1.0];
                                    }
                                } @catch (NSException *e) {}
                            }
                            
                            // refreshUIStates
                            @try {
                                SEL sel = NSSelectorFromString(@"refreshUIStates");
                                if ([found respondsToSelector:sel]) {
                                    ((void(*)(id, SEL))objc_msgSend)(found, sel);
                                }
                            } @catch (NSException *e) {}
                            
                            // showToast
                            @try {
                                SEL sel = NSSelectorFromString(@"showToast:");
                                if ([found respondsToSelector:sel]) {
                                    ((void(*)(id, SEL, id))objc_msgSend)(found, sel, @"激活成功");
                                }
                            } @catch (NSException *e) {}
                            
                            NSLog(@"[VCAM] VIP UI 已激活");
                            break;
                        }
                    } @catch (NSException *e) {
                        NSLog(@"[VCAM] UI操作异常: %@", e);
                    }
                });
            }
            
            if (completion) completion(json);
        }];
    [task resume];
}

#pragma mark - 初始化

__attribute__((constructor))
static void vcam_kami_init(void) {
    NSLog(@"[VCAM] === VCamKamiHook v17 ===");
    
    Class vmClass = objc_getClass("VCamVerifyManager");
    if (vmClass) {
        SEL apiSel = NSSelectorFromString(@"requestAPIWithAction:kami:isHeartbeat:completion:");
        Method apiMethod = class_getInstanceMethod(vmClass, apiSel);
        if (apiMethod) {
            orig_requestAPI = (void *)method_setImplementation(apiMethod, (IMP)h_requestAPI);
            NSLog(@"[VCAM] Hooked requestAPIWithAction");
        }
    }
    
    NSLog(@"[VCAM] VCamKamiHook v17 Ready");
}
