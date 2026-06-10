/**
 * VCamKamiHook v19 - URL 替换方案（不替换 requestAPIWithAction）
 * 
 * 让 App 走自己的完整流程，只替换 URL 域名
 * 之前闪退是因为缺 -flat_namespace -undefined suppress，现在已修复
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSURL* (*orig_URLWithString)(id, SEL, NSString *);
static NSURL* (*orig_URLWithString_rel)(id, SEL, NSString *, NSURL *);

static NSURL* new_URLWithString(id self, SEL _cmd, NSString *string) {
    if (string && [string containsString:@"xnsp"]) {
        NSString *newStr = [string stringByReplacingOccurrencesOfString:@"https://yz.xnsp.v200dd.eu.org"
                                                            withString:@"http://124.221.171.80"];
        newStr = [newStr stringByReplacingOccurrencesOfString:@"/api.php"
                                                  withString:@"/vcam_api.php"];
        NSLog(@"[VCAM] URL: %@ -> %@", string, newStr);
        return orig_URLWithString(self, _cmd, newStr);
    }
    if (string && [string containsString:@"qiaohe"]) {
        NSString *newStr = [string stringByReplacingOccurrencesOfString:@"https://sq.qiaohe.site"
                                                            withString:@"http://124.221.171.80"];
        NSLog(@"[VCAM] URL: %@ -> %@", string, newStr);
        return orig_URLWithString(self, _cmd, newStr);
    }
    return orig_URLWithString(self, _cmd, string);
}

static NSURL* new_URLWithString_rel(id self, SEL _cmd, NSString *string, NSURL *baseURL) {
    if (string && ([string containsString:@"xnsp"] || [string containsString:@"qiaohe"])) {
        return new_URLWithString(self, @selector(URLWithString:), string);
    }
    return orig_URLWithString_rel(self, _cmd, string, baseURL);
}

__attribute__((constructor))
static void vcam_kami_init(void) {
    NSLog(@"[VCAM] === v19 URL redirect ===");
    
    Class nsurlClass = [NSURL class];
    
    Method m1 = class_getClassMethod(nsurlClass, @selector(URLWithString:));
    if (m1) {
        orig_URLWithString = (void *)method_setImplementation(m1, (IMP)new_URLWithString);
        NSLog(@"[VCAM] Hooked URLWithString:");
    }
    
    Method m2 = class_getClassMethod(nsurlClass, @selector(URLWithString:relativeToURL:));
    if (m2) {
        orig_URLWithString_rel = (void *)method_setImplementation(m2, (IMP)new_URLWithString_rel);
        NSLog(@"[VCAM] Hooked URLWithString:relativeToURL:");
    }
    
    NSLog(@"[VCAM] Ready");
}
