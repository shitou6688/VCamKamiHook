# VCAM Kami Hook

VCAM 虚拟相机验证绕过 + 卡密对接插件。

## 功能

- ✅ 绕过原服务器验证（原服务器已关闭）
- ✅ 解锁声音功能和 VIP 功能
- ✅ 卡密系统对接到自定义服务器 (app=10003)
- ✅ 重定向原始域名请求 (vcam.lengye.top / xnsp.v200dd.eu.org)

## Hook 点

| 原始方法 | Hook 行为 |
|---------|----------|
| `NSURL + URLWithString:` | 重定向旧域名到新服务器 |
| `VCamVerifyManager - startVerifyProcess` | 直接设置授权，不联系服务器 |
| `VCamVerifyManager - toggleSound` | 先设置授权再调用原始方法 |
| `VCamVerifyManager - requestKamiVerify:completion:` | 对接自定义卡密服务器 |
| `VCamVerifyManager - requestAPIWithAction:kami:isHeartbeat:completion:` | 心跳直接返回成功 |
| `VCamVerifyManager - showKamiInputAlert:completion:` | 自定义卡密输入弹窗 |

## 配置

在 `vcam_kami_hook.m` 头部修改：

```objc
static NSString *const kKamiServerHost   = @"124.221.171.80";  // 卡密服务器
static NSString *const kKamiAppID        = @"10003";            // 应用 ID
```

## 编译

GitHub Actions 自动编译，push 到仓库即可。

手动编译（需 macOS + Xcode）：
```bash
xcrun -sdk iphoneos clang \
  -arch arm64 -arch arm64e \
  -shared -fobjc-arc \
  -miphoneos-version-min=14.0 \
  -o vcam_kami_hook.dylib vcam_kami_hook.m \
  -framework Foundation -framework UIKit -lobjc
ldid -S vcam_kami_hook.plist vcam_kami_hook.dylib
```

## 部署

将 `vcam_kami_hook.dylib` + `vcam_kami_hook.plist` 放入：
- `/Library/MobileSubstrate/DynamicLibraries/` (Substrate)
- 或通过 TrollStore 注入目标 App

plist 中 `Filter > Bundles` 需根据实际目标 App 修改 bundle ID。
