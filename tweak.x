/**
 * VCamKamiHook v16 - 完全模仿 vcam_kami(5) 方案
 * 
 * 只做一件事：hook requestAPIWithAction:kami:isHeartbeat:completion:
 * 在 hook 里自己发 POST 请求到我们服务器，成功后直接操作 UI
 * 
 * 不碰 NSURL，不调 verifyAndProceed，不碰 URLWithString
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - Hook requestAPIWithAction

static void (*orig_reqAPI)(id, SEL, NSString *, NSString *, BOOL, void (^)(NSDictionary *));

static void h_reqAPI(id self, SEL _cmd,
    NSString *action, NSString *kami, BOOL isHeartbeat,
    void (^completion)(NSDictionary *)) {
    
    NSLog(@"[VCAM] reqAPI: action=%@ kami=%@ heartbeat=%d", action, kami, (int)isHeartbeat);
    
    // 如果没有卡密，走原始流程
    if (!kami || kami.length == 0) {
        if (orig_reqAPI) orig_reqAPI(self, _cmd, action, kami, isHeartbeat, completion);
        return;
    }
    
    // 自己发请求到我们服务器
    NSString *udid = @"unknown";
    @try {
        SEL getDeviceIDSel = NSSelectorFromString(@"getDeviceID");
        if ([self respondsToSelector:getDeviceIDSel]) {
            id ret = ((id(*)(id, SEL))objc_msgSend)(self, getDeviceIDSel);
            if ([ret isKindOfClass:[NSString class]]) {
                udid = (NSString *)ret;
            }
        }
    } @catch (NSException *e) {}
    
    NSString *urlStr = [NSString stringWithFormat:@"http://124.221.171.80/vcam_api.php?action=%@&udid=%@&kami=%@&ts=%@&sign=0",
        action, udid, kami, @((long long)[[NSDate date] timeIntervalSince1970])];
    
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"GET"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"TrollInstallerX/1.0" forHTTPHeaderField:@"User-Agent"];
    
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) {
                NSLog(@"[VCAM] 网络错误: %@", error);
                NSString *errMsg = [NSString stringWithFormat:@"网络错误: %@", error.localizedDescription];
                if (completion) completion(@{@"code": @(-1), @"msg": errMsg});
                return;
            }
            
            if (!data) {
                if (completion) completion(@{@"code": @(-1), @"msg": @"服务器返回格式错误"});
                return;
            }
            
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSLog(@"[VCAM] 服务器返回: %@", json);
            
            if (json && [json[@"code"] integerValue] == 0) {
                // 成功！激活 VIP
                NSLog(@"[VCAM] 激活 VIP!");
                
                // 1. NSUserDefaults
                [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"vcam_vip_unlocked"];
                [[NSUserDefaults standardUserDefaults] setObject:kami forKey:@"vcam_verified_kami"];
                [[NSUserDefaults standardUserDefaults] synchronize];
                
                // 2. Keychain (llyKeychain)
                @try {
                    Class kcClass = objc_getClass("llyKeychain");
                    if (kcClass) {
                        SEL setPwSel = NSSelectorFromString(@"setPassword:forService:account:");
                        if ([kcClass respondsToSelector:setPwSel]) {
                            ((void(*)(id, SEL, id, id, id))objc_msgSend)(kcClass, setPwSel, kami, @"vcam_kami", @"vcam_kami");
                        }
                    }
                } @catch (NSException *e) {
                    NSLog(@"[VCAM] Keychain 异常: %@", e);
                }
                
                // 3. 操作 VCamMenuVC UI（主线程）
                dispatch_async(dispatch_get_main_queue(), ^{
                    @try {
                        for (UIWindow *window in [UIApplication sharedApplication].windows) {
                            UIViewController *rootVC = window.rootViewController;
                            if (!rootVC) continue;
                            
                            __block UIViewController *found = nil;
                            void (^findVC)(UIViewController *) = ^(UIViewController *vc) {
                                if (found) return;
                                if ([vc isKindOfClass:NSClassFromString(@"VCamMenuVC")]) {
                                    found = vc;
                                    return;
                                }
                                for (UIViewController *child in vc.childViewControllers) {
                                    findVC(child);
                                    if (found) return;
                                }
                            };
                            findVC(rootVC);
                            
                            if (found) {
                                // authStatusLabel
                                @try {
                                    id label = [found valueForKey:@"authStatusLabel"];
                                    if (label && [label isKindOfClass:[UILabel class]]) {
                                        [(UILabel *)label setText:@"已激活"];
                                        [(UILabel *)label setTextColor:[UIColor systemGreenColor]];
                                    }
                                } @catch (NSException *e) {}
                                
                                // 启用按钮
                                NSArray *btnNames = @[@"btnLoop", @"btnSound", @"btnRotate",
                                                      @"btnMirror", @"btnReplacement", @"btnPhotoReplacement"];
                                for (NSString *name in btnNames) {
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
                                    SEL refreshSel = NSSelectorFromString(@"refreshUIStates");
                                    if ([found respondsToSelector:refreshSel]) {
                                        ((void(*)(id, SEL))objc_msgSend)(found, refreshSel);
                                    }
                                } @catch (NSException *e) {}
                                
                                // showToast
                                @try {
                                    SEL toastSel = NSSelectorFromString(@"showToast:");
                                    if ([found respondsToSelector:toastSel]) {
                                        ((void(*)(id, SEL, id))objc_msgSend)(found, toastSel, @"激活成功");
                                    }
                                } @catch (NSException *e) {}
                                
                                NSLog(@"[VCAM] VIP UI 已激活");
                                break;
                            }
                        }
                    } @catch (NSException *e) {
                        NSLog(@"[VCAM] UI操作异常: %@", e);
                    }
                });
            }
            
            // 返回结果给 completion
            if (completion) completion(json ?: @{@"code": @(-1), @"msg": @"unknown"});
        }];
    [task resume];
}

#pragma mark - 初始化

__attribute__((constructor))
static void vcam_kami_init(void) {
    NSLog(@"[VCAM] === VCamKamiHook v16 ===");
    
    // 只 hook requestAPIWithAction
    Class vmClass = objc_getClass("VCamVerifyManager");
    if (vmClass) {
        SEL apiSel = NSSelectorFromString(@"requestAPIWithAction:kami:isHeartbeat:completion:");
        Method apiMethod = class_getInstanceMethod(vmClass, apiSel);
        if (apiMethod) {
            orig_reqAPI = (void *)method_setImplementation(apiMethod, (IMP)h_reqAPI);
            NSLog(@"[VCAM] Hooked requestAPIWithAction");
        } else {
            NSLog(@"[VCAM] WARNING: requestAPIWithAction not found");
        }
    } else {
        NSLog(@"[VCAM] WARNING: VCamVerifyManager not found");
    }
    
    NSLog(@"[VCAM] VCamKamiHook v16 Ready");
}
