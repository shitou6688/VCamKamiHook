/**
 * VCamKamiHook v28 - URL 重定向版（模仿 v28 同行完美破解方案）
 * 
 * 方案：hook NSURL +URLWithString:
 * 把 xnsp.v200dd.eu.org 重定向到我们服务器
 * App 自己处理所有逻辑（签名、请求、响应、VIP激活）
 * 
 * 不需要 hook requestAPIWithAction、NSUserDefaults、UI 等
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSURL* (*orig_URLWithString)(id, SEL, NSString *);
static NSURL* (*orig_URLWithStrRel)(id, SEL, NSString *, NSURL *);

static NSURL* h_URLWithString(id self, SEL _cmd, NSString *urlStr) {
    if (urlStr && [urlStr isKindOfClass:[NSString class]]) {
        // 重定向原始 API 域名到我们服务器
        if ([urlStr containsString:@"xnsp.v200dd.eu.org"]) {
            NSString *newStr = [urlStr stringByReplacingOccurrencesOfString:@"xnsp.v200dd.eu.org" withString:@"124.221.171.80"];
            NSLog(@"[VCAM] redirect: %@ -> %@", urlStr, newStr);
            return orig_URLWithString(self, _cmd, newStr);
        }
        // 兼容其他可能的域名
        if ([urlStr containsString:@"vcam.lengye.top"]) {
            NSString *newStr = [urlStr stringByReplacingOccurrencesOfString:@"vcam.lengye.top" withString:@"124.221.171.80"];
            NSLog(@"[VCAM] redirect: %@ -> %@", urlStr, newStr);
            return orig_URLWithString(self, _cmd, newStr);
        }
    }
    return orig_URLWithString(self, _cmd, urlStr);
}

static NSURL* h_URLWithStrRel(id self, SEL _cmd, NSString *urlStr, NSURL *baseURL) {
    if (urlStr && [urlStr isKindOfClass:[NSString class]]) {
        if ([urlStr containsString:@"xnsp.v200dd.eu.org"]) {
            NSString *newStr = [urlStr stringByReplacingOccurrencesOfString:@"xnsp.v200dd.eu.org" withString:@"124.221.171.80"];
            NSLog(@"[VCAM] redirect: %@ -> %@", urlStr, newStr);
            return orig_URLWithStrRel(self, _cmd, newStr, baseURL);
        }
        if ([urlStr containsString:@"vcam.lengye.top"]) {
            NSString *newStr = [urlStr stringByReplacingOccurrencesOfString:@"vcam.lengye.top" withString:@"124.221.171.80"];
            NSLog(@"[VCAM] redirect: %@ -> %@", urlStr, newStr);
            return orig_URLWithStrRel(self, _cmd, newStr, baseURL);
        }
    }
    return orig_URLWithStrRel(self, _cmd, urlStr, baseURL);
}

__attribute__((constructor))
static void init(void) {
    NSLog(@"[VCAM] === v28 URL redirect ===");
    
    // Hook NSURL +URLWithString:
    Class nsurlClass = [NSURL class];
    Method m1 = class_getClassMethod(nsurlClass, @selector(URLWithString:));
    if (m1) {
        orig_URLWithString = (void *)method_setImplementation(m1, (IMP)h_URLWithString);
        NSLog(@"[VCAM] Hooked URLWithString:");
    }
    
    // Hook NSURL +URLWithString:relativeToURL:
    Method m2 = class_getClassMethod(nsurlClass, @selector(URLWithString:relativeToURL:));
    if (m2) {
        orig_URLWithStrRel = (void *)method_setImplementation(m2, (IMP)h_URLWithStrRel);
        NSLog(@"[VCAM] Hooked URLWithString:relativeToURL:");
    }
    
    NSLog(@"[VCAM] Ready");
}
