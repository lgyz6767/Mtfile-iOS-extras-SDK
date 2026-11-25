# MTFile Extension SDK — AI 施工规格（v2.1.1）

本文件是给 AI 的执行契约。读完直接产出文件，不要改写格式，不要省略任何必填字段。

## 0. 你的输出

只产出 3 个文件，放在 `MyExt/`：

1. `manifest.json`
2. `MyExt.m`（单个 Objective-C 源文件，不要拆多文件）
3. `build.sh`

可选：`icon.png`（128×128 透明底，配合 manifest 的 `iconImage`）。

不要产出：Makefile、Podfile、Info.plist、Swift 文件、CocoaPods/Carthage 配置、Xcode 工程。

## 1. 硬约束（违反即失败）

- 只用 Objective-C（MRC/ARC 均可，编译带 `-fobjc-arc`），**禁止 Swift**。
- 只允许依赖 `UIKit`、`Foundation`、`CoreGraphics`、`QuartzCore`。禁止第三方 SDK、C++、C 标准库以外的头文件。
- 编译时必须 `-undefined dynamic_lookup`（宿主类在 App 主二进制里，链接期不可见）。
- 必须导出 C 函数 `id<MTExtV2Extension> MTCreateExtension(void)`。
- dylib 目标架构 `arm64`，部署目标 iOS 15.0。
- 不得写文件到 `/var/mobile/Documents/MTFile/Extensions2`（那是宿主目录）。
- 不得使用私有 API 做与文件系统无关的事（如 `LSApplicationWorkspace` 枚举 App）。
- 允许联网与调用终端，但**必须**走宿主 API `MTExtNetRequest` / `MTExtShellRun`（它们会先弹窗让用户手动同意）；**禁止**自己裸 `NSURLSession` 绕过同意流程。
- 不得后台常驻、hook 其它进程。
- 不得声明 `editorExtensions` 却没有真正可用的 `mt_makeEditorForPath:`。

## 2. manifest.json（严格 schema）

```json
{
  "framework": "v2.1.0",
  "id": "com.<author>.<extname>",
  "name": "<中文名，≤12 字>",
  "version": "1.0.0",
  "author": "<author>",
  "description": "<一句话，≤40 字>",
  "dylib": "MyExt.dylib",
  "iconImage": "icon.png",
  "capabilities": [],
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
- `framework` 必须是 `"v2.1.0"`（宿主认任何 `v2` 前缀）。
- `iconImage` 可选，相对包路径的 PNG；侧栏优先用它，读不到回退 `icon` 的 SF Symbol。
- `capabilities` 可选，`["network","terminal"]` 只是声明；真正能用取决于用户弹窗同意。
- 用不到联网/终端就把 `capabilities` 删掉，别写空数组以外的假声明。
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
- 顶栏裁剪（下拉重叠）硬规则：
  1. `contentInsetAdjustmentBehavior = .never` 时必须自己补 `safeAreaInsets.top` + 导航栏高度（竖屏 44 / 横屏 32）。
  2. 一个 scrollView 只允许一套下拉手势/刷新控件，禁止再自绘下拉层。
  3. 自绘装饰容器 `clipsToBounds = YES`，别画进导航栏区域。
  4. 键盘弹出必须监听 frame 或 `keyboardLayoutGuide`，工具栏/输入条 `bringSubviewToFront:`。
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
zip -q -r MyExt.mtextra manifest.json MyExt.dylib icon.png   # 没有 icon.png 就去掉
```

## 6. 自检清单（输出前逐条勾）

- [ ] 只有 3 个文件，均落在 `MyExt/`
- [ ] `manifest.json` 是合法 JSON，无注释、无尾逗号
- [ ] `framework` = `"v2.1.0"`，`dylib` = `"MyExt.dylib"`
- [ ] 产物后缀 `.mtextra`；`iconImage` 指向的 PNG 真在包里
- [ ] 代码里 `MTCreateExtension` 存在且返回实现协议的对象
- [ ] `sidebar.items[].id` 每个都在 `mt_makePageForItem:` 有分支
- [ ] 无 Swift、无第三方依赖、无 Xcode 工程
- [ ] 所有宿主类调用都有 `respondsToSelector` 保护
- [ ] 每个 VC 都设了 `edgesForExtendedLayout`
- [ ] 列表页只有一套下拉手势，header 没有越界，装饰层已裁剪
- [ ] 键盘弹出时输入条/工具栏已重排，不压内容
- [ ] 没有声明 `editorExtensions`（除非确实实现了编辑器）
- [ ] 联网/终端都走宿主 API，且处理了「拒绝」与「沙盒版不可用」

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

C 符号（`dlsym(RTLD_DEFAULT, …)` 取，需 `#include <dlfcn.h>`）：

```objc
BOOL  MTExtConsentGranted(NSString *eid, NSString *cap);              // cap: @"network" / @"terminal"
void  MTExtRequestConsent(NSString *eid, NSString *cap, NSString *reason, void (^cb)(BOOL));
pid_t MTExtShellRun(NSString *eid, NSString *cmd, NSString *cwd,
                    void (^onOut)(NSString *, BOOL), void (^onExit)(int));   // 需 terminal 同意
void  MTExtNetRequest(NSString *eid, NSString *url, NSDictionary *headers,
                      void (^done)(NSData *, NSInteger, NSError *));         // 需 network 同意，自动弹窗
BOOL  MTExtProcessAvailable(void);      // 沙盒版为 NO，终端不可用
```

终端只有 deb 版（rootless/roothide）能跑；IPA/TrollStore 版 `MTExtShellRun` 返回 -1，必须给用户文字提示而不是空白页。

调用方式：`NSClassFromString` + `NSSelectorFromString` + `respondsToSelector` 判空后再调；拿不到就用自己的 fallback，**不允许**因为宿主类缺失而崩溃或返回 nil VC。

## 8. 禁止事项

- 禁止在 `mt_makePageForItem:` 里做长耗时同步 IO（>50ms），需要就 `dispatch_async`。
- 禁止 `dlopen` 其它 dylib。
- 禁止修改宿主 bundle 内文件。
- 禁止自建进程、守护、定时器常驻（要跑命令用 `MTExtShellRun`）。
- 禁止把联网代码写在自己起的 NSURLSession 里绕过 `MTExtNetRequest`。

## 9. 打包与上架市场

- 单个扩展：`manifest.json` + dylib + icon 直接放包根，输出 `.mtextra`。
- 一个包多个扩展（v2.1 支持，仅本地安装）：根目录不要放 manifest，放 `extA/`、`extB/` 各自一套；宿主扫子目录逐个装。**上市场必须拆成单扩展包。**
- 上架步骤、目录命名、CI 校验规则见 `MARKET.md`。

---

## 10. 崩溃保护 / 隔离 / 信任 / Lua（v2.1.1，写代码时必须遵守）

### 10.1 让扩展“可被隔离”

- 所有 ObjC 类名加唯一前缀：`MTX<厂商><扩展><用途>`，例如 `MTXLgyzDemoPanel`。宿主会登记类名，重复即**拒绝加载**（提示占用者），不要指望后加载覆盖。
- C 全局变量用 `static` 或加前缀；不要导出裸的 `init`、`main`、`run` 之类通用符号。
- 不在 `+load` / `__attribute__((constructor))` 里做重活，更不能在那里弹 UI、起线程、读大量文件——崩在这里同样会算到扩展头上。
- 视图控制器 `dealloc` 里把 NSTimer、通知、KVO、block 回调全部注销；悬空回调是“打开页面就闪退”的头号原因。

### 10.2 崩溃保护（宿主自动做，扩展只需配合）

宿主在 dlopen 前、页面展示时分别落盘 `pendingExt` / `activeExt`：进程死在这段区间，下次启动自动禁用该扩展；连续两次进安全模式禁用全部。扩展不需要额外代码，但要知道：
- **不要在扩展里调用 `abort()`、`exit()`、`NSAssert` 这类会主动杀进程的东西**，否则会被记为崩溃元凶。
- 长任务放后台队列，主线程只做 UI；同步网络/同步 shell 在主线程会触发 watchdog 杀掉，同样记在扩展头上。

### 10.3 信任开关与文件写删

- 写/删用户文件只能走宿主 API：`MTExtCreateFile(path, content, &err)`、`MTExtDeleteFile(path, &err)`。
- 未信任时宿主会弹窗询问；**不要**为了“体验流畅”用 `NSFileManager` 直接写，越权写入不会弹窗，但会被用户当成越狱插件乱搞，也可能在沙盒里直接失败。
- 安装成功时宿主会问一次「是否信任」，扩展不用自己做引导页。
- 扩展详情页「信任与文件权限」是唯一开关，扩展不要缓存信任状态，每次调 API 让宿主判断。

### 10.4 Lua 加载型扩展（优先推荐给沙盒用户）

- manifest 写 `"runtime": "lua"`、`"entry": "main.lua"`，不要 `dylib`。
- `main.lua` 末尾 `return { build = function(ctx) ... end }`；`build` 返回元素数组。
- 只用 `mt.*`；`io`、`dofile`、`os.execute` 已被摘掉，不要写。
- 每个页面独立 `lua_State`；要跨页面保存状态就自己写文件（写文件受信任开关约束）。
- 元素类型仅 `header/label/dim/button/textfield/spacer/divider`；按钮回调里的错误宿主会 `pcall` 兜住，但仍要自己校验参数与路径。
- 完整样例：`demo-lua/main.lua`，`demo-lua/build.sh` 打包成 `.mtextra`。

### 10.5 自检（新增项）

- [ ] 类名/全局符号有唯一前缀，没和 demo、lua、term、codeserver 撞
- [ ] 没有主动杀进程的调用，长任务不在主线程
- [ ] 写/删文件走 `MTExtCreateFile` / `MTExtDeleteFile`
- [ ] 沙盒版可用场景优先考虑 Lua 扩展
