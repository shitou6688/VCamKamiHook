/**
 * VCamKamiHook v17.4 - 加上 UI 激活
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static void (*orig_requestAPI)(id, SEL, NSString *, NSString *, BOOL, void (^)(NSDictionary *));

static void activateVIPUI(void) {
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
                    if (vc.presentedViewController) {
                        findVC(vc.presentedViewController);
                    }
                    for (UIViewController *child in vc.childViewControllers) {
                        findVC(child);
                        if (found) return;
                    }
                };
                findVC(rootVC);
                
                if (!found) continue;
                
                NSLog(@"[VCAM] 找到 VCamMenuVC, 激活VIP");
                
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
                
                NSLog(@"[VCAM] VIP UI 激活完成");
                break;
            }
        } @catch (NSException *e) {
            NSLog(@"[VCAM] UI操作异常: %@", e);
        }
    });
}

static void h_requestAPI(id self, SEL _cmd,
    NSString *action, NSString *kami, BOOL isHeartbeat,
    void (^completion)(NSDictionary *)) {
    
    NSLog(@"[VCAM] reqAPI: action=%@ kami=%@ heartbeat=%d", action, kami, (int)isHeartbeat);
    
    NSString *udid = @"unknown";
    @try {
        SEL sel = NSSelectorFromString(@"getDeviceID");
        if ([self respondsToSelector:sel]) {
            id ret = ((id(*)(id, SEL))objc_msgSend)(self, sel);
            if ([ret isKindOfClass:[NSString class]] && [(NSString *)ret length] > 0) {
                udid = (NSString *)ret;
            }
        }
    } @catch (NSException *e) {}
    
    if ([udid isEqualToString:@"unknown"]) {
        @try {
            udid = [[[UIDevice currentDevice] identifierForVendor] UUIDString] ?: @"unknown";
        } @catch (NSException *e) {}
    }
    
    NSString *urlStr = [NSString stringWithFormat:@"http://124.221.171.80/vcam_api.php?action=%@&udid=%@&ts=%lld&sign=0",
        action ?: @"check", udid, (long long)[[NSDate date] timeIntervalSince1970]];
    if (kami && kami.length > 0) {
        urlStr = [urlStr stringByAppendingFormat:@"&kami=%@", kami];
    }
    
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:15.0];
    [request setHTTPMethod:@"GET"];
    [request setValue:@"TrollInstallerX/1.0" forHTTPHeaderField:@"User-Agent"];
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) {
                NSLog(@"[VCAM] 网络错误: %@", error.localizedDescription);
                if (completion) completion(@{@"code": @(-1), @"msg": @"网络错误"});
                return;
            }
            
            NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSLog(@"[VCAM] 返回: %@", json);
            
            if (json && [json[@"code"] integerValue] == 0) {
                // 保存状态
                [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"vcam_vip_unlocked"];
                [[NSUserDefaults standardUserDefaults] synchronize];
                
                // 激活 UI
                activateVIPUI();
            }
            
            if (completion) completion(json ?: @{@"code": @(-1), @"msg": @"格式错误"});
        }];
    [task resume];
}

__attribute__((constructor))
static void vcam_kami_init(void) {
    NSLog(@"[VCAM] === v17.4 ===");
    
    Class vmClass = objc_getClass("VCamVerifyManager");
    if (vmClass) {
        SEL apiSel = NSSelectorFromString(@"requestAPIWithAction:kami:isHeartbeat:completion:");
        Method apiMethod = class_getInstanceMethod(vmClass, apiSel);
        if (apiMethod) {
            orig_requestAPI = (void *)method_setImplementation(apiMethod, (IMP)h_requestAPI);
            NSLog(@"[VCAM] Hooked OK");
        }
    }
    
    NSLog(@"[VCAM] Ready");
}
