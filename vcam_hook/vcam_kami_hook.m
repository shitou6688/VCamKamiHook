/**
 * vcam_kami_hook.m
 * 
 * VCAM 虚拟相机 验证 Hook v3
 * 
 * 核心策略变更：不再绕过验证，而是让原始验证流程走通
 * 
 * 1. Hook aesDecrypt:key: 拦截并记录原始服务器 URL
 * 2. Hook NSURL+URLWithString: 重定向旧域名到我们的服务器
 * 3. 让我们的服务器返回原始 VCAM 期望的响应格式
 * 4. 原始代码自行解析响应并设置内部授权状态
 * 5. 不再手动设置 ivar / NSUserDefaults，让原始代码自己设
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ============ 配置 ============

static NSString *const kKamiServerHost    = @"124.221.171.80";
static NSString *const kKamiAppID         = @"10003";
static NSString *const kKamiApiPath       = @"/api.php";
static NSString *const kKamiRegisterPath  = @"/trollstore-device-api.php";

/// 需要重定向的旧域名
static NSString *const kOldDomain1 = @"vcam.lengye.top";
static NSString *const kOldDomain2 = @"xnsp.v200dd.eu.org";

// ============ 原始实现指针 ============

static id    (*orig_aesDecrypt)(id, SEL, id, id);
static NSURL* (*orig_URLWithString)(id, SEL, NSString*);

// ============ Swizzle 辅助 ============

static IMP swizzleInstanceMethod(Class cls, SEL sel, IMP newImp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NULL;
    return method_setImplementation(m, newImp);
}

static IMP swizzleClassMethod(Class cls, SEL sel, IMP newImp) {
    Method m = class_getClassMethod(cls, sel);
    if (!m) return NULL;
    return method_setImplementation(m, newImp);
}

// ============ Hook 实现 ============

#pragma mark - Hook: aesDecrypt:key: (记录解密后的URL)

static id hook_aesDecrypt(id self, SEL _cmd, id encryptedData, id key) {
    id result = orig_aesDecrypt(self, _cmd, encryptedData, key);
    
    if ([result isKindOfClass:[NSString class]]) {
        NSString *decrypted = (NSString *)result;
        if ([decrypted hasPrefix:@"http"]) {
            NSLog(@"[VCAM Hook] 🔓 aesDecrypt 解密出URL: %@", decrypted);
        }
    } else if ([result isKindOfClass:[NSData class]]) {
        NSData *data = (NSData *)result;
        NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (str && [str hasPrefix:@"http"]) {
            NSLog(@"[VCAM Hook] 🔓 aesDecrypt 解密出URL(data): %@", str);
        }
    }
    
    return result;
}

#pragma mark - Hook: NSURL + URLWithString: (域名重定向)

static NSURL* hook_URLWithString(id self, SEL _cmd, NSString *urlString) {
    if (urlString) {
        // 记录所有 VCAM 相关的 URL 请求
        if ([urlString containsString:@"lengye"] || 
            [urlString containsString:@"xnsp"] ||
            [urlString containsString:@"vcam"] ||
            [urlString containsString:@"kami"]) {
            NSLog(@"[VCAM Hook] 🌐 URL请求: %@", urlString);
        }
        
        // 重定向旧域名到我们的服务器
        if ([urlString containsString:kOldDomain1]) {
            NSString *newUrl = [urlString stringByReplacingOccurrencesOfString:kOldDomain1
                                                                   withString:kKamiServerHost];
            NSLog(@"[VCAM Hook] 🔄 重定向: %@ -> %@", urlString, newUrl);
            urlString = newUrl;
        }
        if ([urlString containsString:kOldDomain2]) {
            NSString *newUrl = [urlString stringByReplacingOccurrencesOfString:kOldDomain2
                                                                   withString:kKamiServerHost];
            NSLog(@"[VCAM Hook] 🔄 重定向: %@ -> %@", urlString, newUrl);
            urlString = newUrl;
        }
    }
    return orig_URLWithString(self, _cmd, urlString);
}

// ============ 安装 Hooks ============

static void installHooks() {
    @autoreleasepool {
        // 1. Hook NSURL + URLWithString: (域名重定向)
        Class nsurlClass = objc_getClass("NSURL");
        if (nsurlClass) {
            orig_URLWithString = (void*)swizzleClassMethod(
                nsurlClass, @selector(URLWithString:), (IMP)hook_URLWithString);
            if (orig_URLWithString) {
                NSLog(@"[VCAM Hook] ✅ NSURL + URLWithString: swizzled");
            }
        }
        
        // 2. Hook aesDecrypt:key: (记录解密后的URL)
        Class vcamClass = objc_getClass("VCamVerifyManager");
        if (!vcamClass) {
            NSLog(@"[VCAM Hook] ⏳ VCamVerifyManager not found yet");
            return;
        }
        
        NSLog(@"[VCAM Hook] ✅ Found VCamVerifyManager");
        
        // 打印所有 ivar（调试）
        unsigned int ivarCount = 0;
        Ivar *ivars = class_copyIvarList(vcamClass, &ivarCount);
        NSLog(@"[VCAM Hook] 📋 VCamVerifyManager ivars (%u):", ivarCount);
        for (unsigned int i = 0; i < ivarCount; i++) {
            const char *name = ivar_getName(ivars[i]);
            const char *type = ivar_getTypeEncoding(ivars[i]);
            NSLog(@"[VCAM Hook]   [%u] %s (%s)", i, name ?: "?", type ?: "?");
        }
        if (ivars) free(ivars);
        
        // 打印所有方法（调试）
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(vcamClass, &methodCount);
        NSLog(@"[VCAM Hook] 📋 VCamVerifyManager methods (%u):", methodCount);
        for (unsigned int i = 0; i < methodCount; i++) {
            SEL sel = method_getName(methods[i]);
            NSLog(@"[VCAM Hook]   - %s", sel_getName(sel));
        }
        if (methods) free(methods);
        
        // Hook aesDecrypt:key:
        SEL aesSel = NSSelectorFromString(@"aesDecrypt:key:");
        if (class_getInstanceMethod(vcamClass, aesSel)) {
            orig_aesDecrypt = (void*)swizzleInstanceMethod(
                vcamClass, aesSel, (IMP)hook_aesDecrypt);
            NSLog(@"[VCAM Hook] ✅ aesDecrypt:key: swizzled");
        }
        
        NSLog(@"[VCAM Hook] ✅ v3 hooks installed (observer mode)");
    }
}

// ============ 构造函数 ============

__attribute__((constructor))
static void vcam_hook_init() {
    NSLog(@"[VCAM Hook] v3 Initializing (observer + redirect mode)...");
    
    installHooks();
    
    // 延迟重试
    if (!objc_getClass("VCamVerifyManager")) {
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                NSLog(@"[VCAM Hook] Retry 1...");
                installHooks();
                
                if (!objc_getClass("VCamVerifyManager")) {
                    dispatch_after(
                        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                        dispatch_get_main_queue(), ^{
                            NSLog(@"[VCAM Hook] Retry 2...");
                            installHooks();
                        });
                }
            });
    }
    
    NSLog(@"[VCAM Hook] v3 Init complete - 观察模式，等待原始验证流程");
}
