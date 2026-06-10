/**
 * VCamKamiHook v17.5 - 简化 UI 激活，修复闪退
 * 修复：递归 block 需要 __block 声明
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static void (*orig_requestAPI)(id, SEL, NSString *, NSString *, BOOL, void (^)(NSDictionary *));

// 简单递归查找 VC
static UIViewController* findMenuVC(UIViewController *root) {
    if (!root) return nil;
    if ([root isKindOfClass:NSClassFromString(@"VCamMenuVC")]) return root;
    if (root.presentedViewController) {
        UIViewController *found = findMenuVC(root.presentedViewController);
        if (found) return found;
    }
    for (UIViewController *child in root.childViewControllers) {
        UIViewController *found = findMenuVC(child);
        if (found) return found;
    }
    return nil;
}

static void activateVIPUI(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIViewController *menuVC = nil;
            for (UIWindow *window in [UIApplication sharedApplication].windows) {
                menuVC = findMenuVC(window.rootViewController);
                if (menuVC) break;
            }
            if (!menuVC) {
                NSLog(@"[VCAM] VCamMenuVC 未找到");
                return;
            }
            
            NSLog(@"[VCAM] 找到 VCamMenuVC, 激活VIP");
            
            // authStatusLabel
            @try {
                UILabel *label = [menuVC valueForKey:@"authStatusLabel"];
                if (label && [label isKindOfClass:[UILabel class]]) {
                    label.text = @"已激活";
                    label.textColor = [UIColor greenColor];
                }
            } @catch (NSException *e) {}
            
            // 启用按钮
            for (NSString *name in @[@"btnLoop", @"btnSound", @"btnRotate",
                                     @"btnMirror", @"btnReplacement", @"btnPhotoReplacement"]) {
                @try {
                    UIButton *btn = [menuVC valueForKey:name];
                    if (btn && [btn isKindOfClass:[UIButton class]]) {
                        btn.enabled = YES;
                        btn.alpha = 1.0;
                    }
                } @catch (NSException *e) {}
            }
            
            // refreshUIStates
            @try {
                if ([menuVC respondsToSelector:@selector(refreshUIStates)]) {
                    ((void(*)(id, SEL))objc_msgSend)(menuVC, @selector(refreshUIStates));
                }
            } @catch (NSException *e) {}
            
            // showToast
            @try {
                if ([menuVC respondsToSelector:@selector(showToast:)]) {
                    ((void(*)(id, SEL, id))objc_msgSend)(menuVC, @selector(showToast:), @"激活成功");
                }
            } @catch (NSException *e) {}
            
            NSLog(@"[VCAM] VIP UI 激活完成");
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
        if ([self respondsToSelector:@selector(getDeviceID)]) {
            id ret = [self performSelector:@selector(getDeviceID)];
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
                [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"vcam_vip_unlocked"];
                [[NSUserDefaults standardUserDefaults] synchronize];
                activateVIPUI();
            }
            
            if (completion) completion(json ?: @{@"code": @(-1), @"msg": @"格式错误"});
        }];
    [task resume];
}

__attribute__((constructor))
static void vcam_kami_init(void) {
    NSLog(@"[VCAM] === v17.5 ===");
    
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
