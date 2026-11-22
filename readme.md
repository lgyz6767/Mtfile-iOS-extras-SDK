# MTFile（iOS版MT管理器)的扩展开发文档

想直接让 AI 帮你写扩展，看同目录的 `EXTENSION_SDK_AI.md`。

---

## 1. 它是什么

MTFile 的扩展（整个架构，即这个仓库，由AI制作）是一个 **iOS 动态库（.dylib）+ 一个 manifest.json**，打成 zip 交给 App 安装。安装后宿主 `dlopen` 这个 dylib，调用它导出的 `MTCreateExtension()` 拿到一个实现 `MTExtV2Extension` 协议的对象，再按需向它要页面：

- **侧栏条目页**：侧栏会多出一个分类，点条目 → 调 `mt_makePageForItem:context:` 拿一个 `UIViewController` 弹出来。
- **编辑器接管**：某个文件被打开时，如果扩展在 manifest 里声明了这个后缀，宿主先问 `mt_makeEditorForPath:`，返回 nil 就回退内置编辑器。

扩展跑在宿主进程里，共享宿主的内存、UI 与权限，所以不用起服务、不用 IPC。

> 不兼容官方 MT 管理器的扩展格式。MTFile 只认 `"framework": "v2.0.0"`。

---

## 2. 包结构

```
MyExt.zip
├── manifest.json          ← 必须在 zip 根目录（只套一层同名文件夹也认）
├── MyExt.dylib            ← manifest 的 dylib 字段指向它
└── resources/...          ← 可选，自己按相对路径读
```

安装目录：`/var/mobile/Documents/MTFile/Extensions2/<id>/`。

---

## 3. manifest.json

```json
{
  "framework": "v2.0.0",
  "id": "com.example.myext",
  "name": "我的扩展",
  "version": "1.0.0",
  "author": "你的名字",
  "description": "一句话说明",
  "dylib": "MyExt.dylib",
  "editorExtensions": ["md", "txt"],
  "sidebar": {
    "category": "我的工具",
    "items": [
      { "id": "main", "title": "主页", "icon": "square.grid.2x2" },
      { "id": "about", "title": "关于", "icon": "info.circle" }
    ]
  }
}
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `framework` | 是 | 固定 `v2.0.0`，其它版本宿主直接拒装 |
| `id` | 是 | 唯一标识，同时是安装目录名；建议反向域名 |
| `name` | 否 | 管理页显示名，缺省用 id |
| `version` | 否 | 字符串，只用于展示与更新比较 |
| `dylib` | 是 | dylib 相对路径，必须在 zip 内存在 |
| `editorExtensions` | 否 | 允许接管的文件后缀数组（不带点，如 `md`）。不写就不接管任何编辑器 |
| `editors` | 否 | **推荐**。数组，声明每个编辑器：`{"format":"md","name":"Markdown 编辑器","icon":"square.and.pencil"}`。`icon` 用 SF Symbols 名，`name` 显示在「打开方式 → 扩展」，`format` 决定归到文本/图片/视频/压缩包哪一类。写了它就不用再写 `editorExtensions`（宿主会合并两者） |
| `sidebar` | 否 | `category` 分类名；`items` 每项 `id/title/icon`。不写则侧栏不出现 |
| `icon` | 否 | SF Symbol 名称，宿主原样用 |

`sidebar.items` 的 `id` 会原样传给 `mt_makePageForItem:`，宿主不认识它的语义，全靠你自己分派。

---

## 4. dylib 接口

```objc
#import <UIKit/UIKit.h>

@protocol MTExtV2Extension <NSObject>
// 必选：侧栏条目被点开时调用，itemID 就是 manifest 里的 sidebar.items[].id
- (UIViewController *)mt_makePageForItem:(NSString *)itemID context:(NSDictionary *)ctx;
@optional
// 可选：返回 nil 表示不接管，宿主回退内置编辑器
- (UIViewController *)mt_makeEditorForPath:(NSString *)path;
@end

// 必须导出的 C 函数（宿主按名字 dlsym）
id<MTExtV2Extension> MTCreateExtension(void);
```

`context` 目前可能带 `path`（当前目录）等信息，按 key 取，不要假设一定有。

实现示例：

```objc
#import <UIKit/UIKit.h>
#import "MTExtAPI.h"   // 见第 6 节，把协议声明拷进工程即可

@interface MyExt : NSObject <MTExtV2Extension>
@end

@implementation MyExt
- (UIViewController *)mt_makePageForItem:(NSString *)itemID context:(NSDictionary *)ctx {
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *l = [[UILabel alloc] initWithFrame:vc.view.bounds];
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    l.textAlignment = NSTextAlignmentCenter;
    l.text = [NSString stringWithFormat:@"页面：%@", itemID];
    [vc.view addSubview:l];
    return vc;
}
@end

id<MTExtV2Extension> MTCreateExtension(void) { return [MyExt new]; }
```

---

## 5. 构建

不需要完整 Theos 工程，一条 clang 就能出 dylib（Linux/macOS 都行，SDK 用 Theos 的 iPhoneOS sdk）：

```bash
SDK=/path/to/theos/sdks/iPhoneOS16.5.sdk
CLANG=/path/to/theos/toolchain/linux/iphone/bin/clang

"$CLANG" -arch arm64 -dynamiclib -fobjc-arc \
  -target arm64-apple-ios15.0 \
  -Wl,-platform_version,ios,15.0,15.0 \
  -isysroot "$SDK" \
  -framework UIKit -framework Foundation -framework CoreGraphics \
  -undefined dynamic_lookup \
  -Os -o MyExt.dylib MyExt.m
```

要点：

- **必须** `-undefined dynamic_lookup`。宿主类（`MTTheme` 之类）在 App 主二进制里，链接期找不到符号，靠运行期解析。
- arm64 即可（iPhone 7 / arm64e 设备也能加载 arm64 切片）。
- `-fobjc-arc` 打开，扩展代码按 ARC 写；宿主与扩展是同一进程同一 runtime，OC 对象可以自由传递。

签名（rootless 环境需要）：

```bash
/path/to/ldid -S MyExt.dylib
```

没有 `ldid` 时宿主安装后也会尝试签名，但提前签好更稳。

打包（**manifest.json 必须在 zip 根，不要套一层目录**）：

```bash
cd MyExt && zip -r ../MyExt.zip manifest.json MyExt.dylib
```

---

## 6. 和宿主交互（可选）

扩展里直接 `NSClassFromString` 拿宿主类，能白嫖主题、弹窗、波纹等。协议声明自己拷一份即可，不必依赖宿主头文件：

```objc
static UIColor *hostColor(NSString *sel, UIColor *fallback) {
    id cls = NSClassFromString(@"MTTheme");
    SEL s = NSSelectorFromString(sel);
    if (![cls respondsToSelector:s]) return fallback;
    IMP imp = [cls methodForSelector:s];
    UIColor *(*fn)(id, SEL) = (void *)imp;
    return fn(cls, s) ?: fallback;
}
// hostColor(@"bg", ...) / @"panel" / @"cell" / @"text" / @"textDim" / @"accent"
```

常用宿主能力（都在主二进制里，缺了就 fallback）：

| 类 | 用途 |
|---|---|
| `MTTheme` | 颜色：`bg/panel/cell/text/textDim/accent`，字体缩放 `uiScale` |
| `MTMaterialRipple` | `enableOnButton:style:` 给按钮加方形波纹 |
| `MTAlertCenter` | `showWithTitle:message:` 统一风格弹窗 |
| `MTFileStore` | 文件操作、`hexDigestOfData:algorithm:` 等 |
| `MTExtV2Store` | 宿主侧扩展管理（`installZipAtPath:` 等，扩展通常不用） |

调用宿主方法一律用 `respondsToSelector` + `NSInvocation`/IMP 保护，宿主版本升级时不至于崩。

---

## 7. 安装与调试

1. 开发者：把 zip 拷到设备任意目录，App 里点它 → 识别为扩展 → 安装。
2. 管理页会显示加载状态；失败时把 `diagnoseExtension:` 的整段原因贴出来（含尝试过的路径）。
3. 重装同一 id 会自动覆盖旧目录并清掉各回退位置的旧 dylib 副本——**扩展更新自己**是支持的，装完再点一次「重新加载」即可。

沙盒限制（重要）：

- deb 版（rootless / roothide，非沙盒）：可以从 `/var/mobile/Documents/...` 原地 `dlopen`。
- IPA 版（TrollStore / WQ / 沙盒）：数据目录被禁止 `mmap` 可执行页，宿主会自动把 dylib 复制到容器缓存目录（`Library/Caches/MTExtensions`、`/var/jb/var/mobile/Library/Caches/MTExtensions` 等）再加载。
- 别把 dylib 放进只读位置，也别假设某个回退路径一定可写。

---

## 8. 编辑器接管与按格式禁用

manifest 写了 `editorExtensions` 才参与接管。多个扩展抢同一个后缀时，宿主按安装顺序问，第一个返回非 nil 的就赢。

用户可以在「扩展管理 → 详情 → 编辑器接管」里**按格式**关掉某个扩展（不影响扩展其它功能），所以：

- 返回 nil 要干脆，别为了“占坑”随便返回一个空 VC。
- 编辑器要自己处理保存、脏状态；没有把握就别声明这个后缀。

---

## 9. 常见坑

| 现象 | 原因 |
|---|---|
| 装不上，提示框架版本不对 | `framework` 不是 `v2.0.0` |
| 装上了但侧栏没有 | manifest 没写 `sidebar`，或 `items` 为空 |
| 点条目闪退 | `mt_makePageForItem:` 返回了 nil，或返回的 VC 在 `viewDidLoad` 里访问了不存在的宿主类 |
| dylib 加载失败 | 没加 `-undefined dynamic_lookup`，或 arm64 切片对不上 |
| 编辑器不生效 | `editorExtensions` 没写 / 用户在详情页关掉了该格式 / 别的扩展先返回了 VC |
| 页面顶部被导航栏压住 | 自定义 VC 请设 `edgesForExtendedLayout = UIRectEdgeNone`，宿主会给扩展页配不透明导航栏 |

---

## 10. 最小清单

- [ ] `manifest.json` 在 zip 根，`framework` = `v2.0.0`，`id` 唯一
- [ ] dylib 名与 manifest 一致，导出 `MTCreateExtension`
- [ ] 编译带 `-undefined dynamic_lookup`，arm64
- [ ] 已 `ldid -S`
- [ ] 侧栏每个 `items[].id` 在 `mt_makePageForItem:` 里都有分支
- [ ] 所有宿主方法调用都有 `respondsToSelector` 保护
