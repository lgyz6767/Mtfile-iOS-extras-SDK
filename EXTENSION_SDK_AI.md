# MTFile Extension SDK — AI 施工规格（v2.0.0）

本文件是给 AI 的执行契约。读完直接产出文件，不要改写格式，不要省略任何必填字段。

## 0. 你的输出

只产出 3 个文件，放在 `MyExt/`：

1. `manifest.json`
2. `MyExt.m`（单个 Objective-C 源文件，不要拆多文件）
3. `build.sh`

不要产出：Makefile、Podfile、Info.plist、Swift 文件、CocoaPods/Carthage 配置、Xcode 工程。

## 1. 硬约束（违反即失败）

- 只用 Objective-C（MRC/ARC 均可，编译带 `-fobjc-arc`），**禁止 Swift**。
- 只允许依赖 `UIKit`、`Foundation`、`CoreGraphics`、`QuartzCore`。禁止第三方 SDK、C++、C 标准库以外的头文件。
- 编译时必须 `-undefined dynamic_lookup`（宿主类在 App 主二进制里，链接期不可见）。
- 必须导出 C 函数 `id<MTExtV2Extension> MTCreateExtension(void)`。
- dylib 目标架构 `arm64`，部署目标 iOS 15.0。
- 不得写文件到 `/var/mobile/Documents/MTFile/Extensions2`（那是宿主目录）。
- 不得使用私有 API 做与文件系统无关的事（如 `LSApplicationWorkspace` 枚举 App）。
- 不得包含网络请求、后台常驻、hook 其它进程。
- 不得声明 `editorExtensions` 却没有真正可用的 `mt_makeEditorForPath:`。

## 2. manifest.json（严格 schema）

```json
{
  "framework": "v2.0.0",
  "id": "com.<author>.<extname>",
  "name": "<中文名，≤12 字>",
  "version": "1.0.0",
  "author": "<author>",
  "description": "<一句话，≤40 字>",
  "dylib": "MyExt.dylib",
  "editors": [
    { "format": "<ext1>", "name": "<编辑器显示名>", "icon": "<SF Symbols 名>" }
  ],
  "sidebar": {
    "category": "<分类名，≤8 字>",
    "items": [
      { "id": "<pageid>", "title": "<中文标题，≤8 字>", "icon": "<SF Symbol 名>" }
    ]
  }
}
```

规则：
- `framework` 必须是字符串 `"v2.0.0"`。
- `id` 必须唯一、小写、点分；安装目录名等于 id。
- `editorExtensions` 每项不带点、小写。没有编辑器能力时**必须省略该字段**。
- `sidebar.items` 至少 1 项、至多 6 项；每项 `id` 在代码里必须有对应分支。
- `icon` 用真实存在的 SF Symbol（如 `square.grid.2x2`、`folder`、`doc.text`、`gearshape`、`info.circle`）。

## 3. 代码骨架（照抄结构）

```objc
#import <UIKit/UIKit.h>

@protocol MTExtV2Extension <NSObject>
- (UIViewController *)mt_makePageForItem:(NSString *)itemID context:(NSDictionary *)ctx;
@optional
- (UIViewController *)mt_makeEditorForPath:(NSString *)path;
@end

// 宿主能力（可选，必须 respondsToSelector 保护）
static id MTCls(NSString *n) { return NSClassFromString(n); }

static UIColor *MTColor(NSString *sel, UIColor *fb) {
    id cls = MTCls(@"MTTheme");
    SEL s = NSSelectorFromString(sel);
    if (![cls respondsToSelector:s]) return fb;
    IMP imp = [cls methodForSelector:s];
    UIColor *(*fn)(id, SEL) = (void *)imp;
    return fn(cls, s) ?: fb;
}

@interface MyExt : NSObject <MTExtV2Extension>
@end

@implementation MyExt

- (UIViewController *)mt_makePageForItem:(NSString *)itemID context:(NSDictionary *)ctx {
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = MTColor(@"bg", [UIColor colorWithWhite:0.09 alpha:1]);
    if ([itemID isEqualToString:@"main"]) {
        // ...
    } else {
        // ...
    }
    return vc;
}

// 仅在 manifest 声明了 editorExtensions 时实现
- (UIViewController *)mt_makeEditorForPath:(NSString *)path {
    return nil;   // 不接管就返回 nil
}

@end

id<MTExtV2Extension> MTCreateExtension(void) { return [MyExt new]; }
```

## 4. UI 规范

- 每个自定义 VC 都要：`vc.edgesForExtendedLayout = UIRectEdgeNone;`（否则内容被宿主导航栏压住）。
- 颜色一律走 `MTColor()` 并给 fallback，不要硬编码纯黑纯白当主题色。
- 深色底 + 中性灰文字：`bg #171717`、`cell #262626`、`text #FFFFFF`、`textDim #9E9E9E`、`accent #3D82F6`（fallback 用这些）。
- 不要用 Storyboard / XIB；不要用 `UIAlertController` 之外的第三方弹窗。
- 列表用 `UITableView` + `UITableViewCell`，行高 ≥ 52。

## 5. build.sh（照抄，只改文件名）

```bash
#!/bin/bash
set -e
SDK=${THEOS_SDK:-/home/user/theos/sdks/iPhoneOS16.5.sdk}
CLANG=${THEOS_CLANG:-/home/user/theos/toolchain/linux/iphone/bin/clang}
cd "$(dirname "$0")"
"$CLANG" -arch arm64 -dynamiclib -fobjc-arc -target arm64-apple-ios15.0 \
  -Wl,-platform_version,ios,15.0,15.0 -isysroot "$SDK" \
  -framework UIKit -framework Foundation -framework CoreGraphics \
  -undefined dynamic_lookup -Os -o MyExt.dylib MyExt.m
LDID=${LDID:-/home/user/ios-toolchain/ldid}
[ -x "$LDID" ] && "$LDID" -S MyExt.dylib || true
zip -q -r MyExt.zip manifest.json MyExt.dylib
```

## 6. 自检清单（输出前逐条勾）

- [ ] 只有 3 个文件，均落在 `MyExt/`
- [ ] `manifest.json` 是合法 JSON，无注释、无尾逗号
- [ ] `framework` = `"v2.0.0"`，`dylib` = `"MyExt.dylib"`
- [ ] 代码里 `MTCreateExtension` 存在且返回实现协议的对象
- [ ] `sidebar.items[].id` 每个都在 `mt_makePageForItem:` 有分支
- [ ] 无 Swift、无第三方依赖、无 Xcode 工程
- [ ] 所有宿主类调用都有 `respondsToSelector` 保护
- [ ] 每个 VC 都设了 `edgesForExtendedLayout`
- [ ] 没有声明 `editorExtensions`（除非确实实现了编辑器）

## 7. 宿主 API 速查

```objc
// 主题
MTTheme: bg / panel / cell / text / textDim / accent  // 类方法，UIColor*
MTTheme: uiScale                                       // 类方法，CGFloat

// 弹窗
MTAlertCenter: + showWithTitle:message:

// 波纹
MTMaterialRipple: + enableOnButton:style:   // style 0=方形 1=圆形

// 文件
MTFileStore: + attributes / + hexDigestOfData:algorithm: / 读目录等
```

调用方式：`NSClassFromString` + `NSSelectorFromString` + `respondsToSelector` 判空后再调；拿不到就用自己的 fallback，**不允许**因为宿主类缺失而崩溃或返回 nil VC。

## 8. 禁止事项

- 禁止在 `mt_makePageForItem:` 里做长耗时同步 IO（>50ms），需要就 `dispatch_async`。
- 禁止 `dlopen` 其它 dylib。
- 禁止修改宿主 bundle 内文件。
- 禁止自建进程、守护、定时器常驻。
