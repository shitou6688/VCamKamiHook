/**
 * VCamKamiHook v28.1 - URL 重定向版
 * 
 * hook NSURL +URLWithString:
 * 把 https://yz.xnsp.v200dd.eu.org 重定向到 http://124.221.171.80
 * App 自己处理所有逻辑
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSURL* (*orig_URLWithString)(id, SEL, NSString *);
static NSURL* (*orig_URLWithStrRel)(id, SEL, NSString *, NSURL *);

static NSString* redirectURL(NSString *urlStr) {
    if (!urlStr || ![urlStr isKindOfClass:[NSString class]]) return urlStr;
    
    // 原始 URL: https://yz.xnsp.v200dd.eu.org/api.php?...
    // 目标: http://124.221.171.80/vc.php?...
    // 注意：服务器 /api.php 是 kmlogon 系统，必须重定向到 /vc.php
    if ([urlStr containsString:@"xnsp.v200dd.eu.org"]) {
        NSString *newStr = [urlStr stringByReplacingOccurrencesOfString:@"https://yz.xnsp.v200dd.eu.org/api.php" withString:@"http://124.221.171.80/vc.php"];
        // 兼容其他子域名/路径
        if ([newStr containsString:@"xnsp.v200dd.eu.org"]) {
            newStr = [newStr stringByReplacingOccurrencesOfString:@"https://yz.xnsp.v200dd.eu.org" withString:@"http://124.221.171.80"];
            newStr = [newStr stringByReplacingOccurrencesOfString:@"xnsp.v200dd.eu.org" withString:@"124.221.171.80"];
            newStr = [newStr stringByReplacingOccurrencesOfString:@"https://124.221.171.80" withString:@"http://124.221.171.80"];
        }
        NSLog(@"[VCAM] redirect: %@ -> %@", urlStr, newStr);
        return newStr;
    }
    // 兼容 lengye.top
    if ([urlStr containsString:@"lengye.top"]) {
        NSString *newStr = [urlStr stringByReplacingOccurrencesOfString:@"https://yz.lengye.top/api.php" withString:@"http://124.221.171.80/vc.php"];
        if ([newStr containsString:@"lengye.top"]) {
            newStr = [newStr stringByReplacingOccurrencesOfString:@"https://yz.lengye.top" withString:@"http://124.221.171.80"];
            newStr = [newStr stringByReplacingOccurrencesOfString:@"lengye.top" withString:@"124.221.171.80"];
            newStr = [newStr stringByReplacingOccurrencesOfString:@"https://124.221.171.80" withString:@"http://124.221.171.80"];
        }
        NSLog(@"[VCAM] redirect: %@ -> %@", urlStr, newStr);
        return newStr;
    }
    return urlStr;
}

static NSURL* h_URLWithString(id self, SEL _cmd, NSString *urlStr) {
    return orig_URLWithString(self, _cmd, redirectURL(urlStr));
}

static NSURL* h_URLWithStrRel(id self, SEL _cmd, NSString *urlStr, NSURL *baseURL) {
    return orig_URLWithStrRel(self, _cmd, redirectURL(urlStr), baseURL);
}

__attribute__((constructor))
static void init(void) {
    NSLog(@"[VCAM] === v28.1 URL redirect ===");
    
    Class nsurlClass = [NSURL class];
    Method m1 = class_getClassMethod(nsurlClass, @selector(URLWithString:));
    if (m1) {
        orig_URLWithString = (void *)method_setImplementation(m1, (IMP)h_URLWithString);
        NSLog(@"[VCAM] Hooked URLWithString:");
    }
    
    Method m2 = class_getClassMethod(nsurlClass, @selector(URLWithString:relativeToURL:));
    if (m2) {
        orig_URLWithStrRel = (void *)method_setImplementation(m2, (IMP)h_URLWithStrRel);
        NSLog(@"[VCAM] Hooked URLWithString:relativeToURL:");
    }
    
    NSLog(@"[VCAM] Ready");
}
