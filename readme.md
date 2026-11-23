# MTFile（iOS 版 MT 管理器）扩展开发文档 · v2.1

想直接让 AI 帮你写扩展，看同目录的 `EXTENSION_SDK_AI.md`；想上架到扩展市场，看 `MARKET.md`。
示例：`template`（最小骨架）、`demo`（四页自绘 UI + 权限/终端/网络演示）。

---

## 1. 它是什么

MTFile 的扩展是一个 **iOS 动态库（.dylib）+ 一个 manifest.json**，打成扩展包交给 App 安装。装好后宿主 `dlopen` 这个 dylib，调用它导出的 `MTCreateExtension()` 拿到实现 `MTExtV2Extension` 协议的对象，按需向它要页面：

- **侧栏条目页**：侧栏多出一个分类，点条目 → `mt_makePageForItem:context:` 返回一个 `UIViewController`。
- **编辑器接管**：文件打开时，扩展在 manifest 里声明过后缀，宿主先问 `mt_makeEditorForPath:`，返回 nil 回退内置编辑器。

扩展跑在宿主进程里，共享宿主内存、UI 与权限，不起服务、不走 IPC。

> 不兼容官方 MT 管理器的扩展格式。MTFile 只认 `"framework": "v2.x.x"`（推荐写 `v2.1.0`）。

---

## 2. 包结构

扩展包后缀是 **`.mtextra`**（本质就是 zip，改后缀是为了让宿主不去解析普通 zip，省算力）。扩展名不对也能装，但只有 `.mtextra` 会被宿主当成“准扩展”优先识别。

单扩展（推荐）：

```
MyExt.mtextra
├── manifest.json          ← 扩展根
├── MyExt.dylib            ← manifest 的 dylib 字段指向它
├── icon.png               ← 可选，自定义图标（manifest.iconImage）
└── resources/...          ← 可选，自己按相对路径读
```

一个包多个扩展（v2.1 支持）：

```
Bundle.mtextra
├── extA/manifest.json + A.dylib + icon.png
├── extB/manifest.json + B.dylib
└── extC/manifest.json + C.dylib
```

规则：**包根有 manifest.json** → 只装根上这一个（子目录忽略）；**根上没有** → 扫一层子目录，每个含 manifest.json 的直接装；再没有就退一层（套娃目录）。所以「只套一层同名文件夹」也照样认。

安装目录：`/var/mobile/Documents/MTFile/Extensions2/<id>/`。

---

## 3. manifest.json

```json
{
  "framework": "v2.1.0",
  "id": "com.example.myext",
  "name": "我的扩展",
  "version": "1.0.0",
  "author": "你的名字",
  "description": "一句话说明",
  "dylib": "MyExt.dylib",
  "iconImage": "icon.png",
  "capabilities": ["network", "terminal"],
  "editors": [
    { "format": "md", "name": "Markdown 编辑器", "icon": "square.and.pencil" }
  ],
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
| `framework` | 是 | `v2.1.0`（任何 `v2` 前缀都收；`v1` 直接拒装） |
| `id` | 是 | 唯一标识，同时是安装目录名；建议反向域名。**市场里必须与目录名一致** |
| `name` | 否 | 管理页/侧栏显示名，缺省用 id |
| `version` | 否 | 字符串，市场用它判断可更新 |
| `dylib` | 是 | dylib 相对路径，必须在包内存在 |
| `iconImage` | 否 | **自定义图标**，相对扩展目录的 PNG（建议 96×96 或 128×128，透明底）。缺省/读不到时回退 `icon` 的 SF Symbol |
| `icon` | 否 | SF Symbol 名，侧栏兜底图标 |
| `capabilities` | 否 | 声明 `network` / `terminal`，**仅用于展示**；真正能不能用取决于用户是否在弹窗里点「允许」 |
| `editors` | 否 | 推荐。每个编辑器 `{format,name,icon}`，`name` 显示在「打开方式 → 扩展」 |
| `editorExtensions` | 否 | 老写法，纯后缀数组；与 `editors` 合并 |
| `sidebar` | 否 | `category` 分类名，`items` 每项 `{id,title,icon,iconImage?}`；条目也能单独指定 `iconImage` |

`sidebar.items[].id` 原样传给 `mt_makePageForItem:`，语义全靠你自己分派。

---

## 4. dylib 接口

```objc
#import <UIKit/UIKit.h>

@protocol MTExtV2Extension <NSObject>
- (UIViewController *)mt_makePageForItem:(NSString *)itemID context:(NSDictionary *)ctx;  // 必选
@optional
- (UIViewController *)mt_makeEditorForPath:(NSString *)path;                              // 返回 nil 不接管
@end

id<MTExtV2Extension> MTCreateExtension(void);   // 必须导出（宿主 dlsym）
```

`context` 可能带 `path`（当前目录）、`extensionDir`（扩展安装目录），按 key 取，别假设一定存在。

---

## 5. 构建

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
/path/to/ldid -S MyExt.dylib
cd MyExt && zip -r ../MyExt.mtextra manifest.json MyExt.dylib icon.png
```

- **必须** `-undefined dynamic_lookup`：宿主类在主二进制里，靠运行期解析。
- arm64 切片即可（arm64e 设备也能加载）。
- 用 `-fobjc-arc`。
- 打包用 `.mtextra`，manifest 在包根（多扩展才用子目录）。

---

## 6. 和宿主交互（可选）

`NSClassFromString` 直接拿宿主类，协议声明自己拷一份，不依赖宿主头文件。调用一律 `respondsToSelector` 保护。

| 类 | 用途 |
|---|---|
| `MTTheme` | `bg/panel/cell/text/textDim/accent`、`uiScale` |
| `MTMaterialRipple` | `enableOnButton:style:` 波纹 |
| `MTAlertCenter` | `showWithTitle:message:` |
| `MTFileStore` | 文件操作、`hexDigestOfData:algorithm:` |
| `MTExtV2Store` | 宿主侧扩展管理，扩展一般不用 |

---

## 7. 权限：联网与终端（v2.1 新增，重点）

扩展和宿主同进程，但**联网、跑命令不能自己说了算**：必须让用户在宿主弹窗里点「允许」，结果记在 `NSUserDefaults`（键 `mt_ext_consent.<id>.<cap>`）。描述文件里写 `capabilities` 只是声明，**不代表已授权**。

C 符号都在宿主主二进制里，扩展用 `dlsym(RTLD_DEFAULT, …)` 取：

```objc
#include <dlfcn.h>

typedef BOOL (*MT_ConsentQuery)(NSString *, NSString *);
typedef void (*MT_ConsentAsk)(NSString *, NSString *, NSString *, void (^)(BOOL));
typedef pid_t (*MT_ShellRun)(NSString *, NSString *, NSString *, void (^)(NSString *, BOOL), void (^)(int));
typedef void (*MT_NetGet)(NSString *, NSString *, NSDictionary *, void (^)(NSData *, NSInteger, NSError *));

MT_ConsentQuery consent = (MT_ConsentQuery)dlsym(RTLD_DEFAULT, "MTExtConsentGranted");
MT_ConsentAsk   ask     = (MT_ConsentAsk)dlsym(RTLD_DEFAULT, "MTExtRequestConsent");
MT_ShellRun     shell   = (MT_ShellRun)dlsym(RTLD_DEFAULT, "MTExtShellRun");
MT_NetGet       net     = (MT_NetGet)dlsym(RTLD_DEFAULT, "MTExtNetRequest");
```

| 能力 | 说明 |
|---|---|
| `@"network"` | 联网。首次调用 `MTExtNetRequest` 会弹「允许/拒绝」；拒绝后回调错误，下次调用再问 |
| `@"terminal"` | 跑命令。`MTExtShellRun` 内部查 shell（`/var/jb/usr/bin/bash` → `sh` → `/bin/sh`），未授权返回 -1 并在输出块里写原因 |
| `MTExtConsentGranted(eid, cap)` | 查当前状态，不弹窗 |
| `MTExtRequestConsent(eid, cap, reason, cb)` | 主动申请，`cb` 在主线程 |
| `MTExtNetRequest(eid, url, headers, cb)` | GET，带同意流程，回调主线程；**扩展自己用裸 NSURLSession 绕过去，宿主拦不住**，请自觉走这个接口 |
| `MTExtShellRun(eid, cmd, cwd, onOut, onExit)` | 走 `bash -lc`，标准输出/错误分块回调；**只有非沙盒版（deb/rootless/roothide）可用**，IPA/TrollStore 版沙盒 `posix_spawn` 被拒 |

沙盒版判断：`MTExtProcessAvailable()` / `MTExtProcessUnavailableReason()`。要给用户明确提示「终端功能需要 deb 版」，别直接白屏。

完整可跑示例见 `demo/MTDemoExt.m` 里的 `MTDemoCapsVC`。

---

## 8. 安装与调试

1. 把 `.mtextra` 拷到设备任意目录，App 里点它或「扩展管理 → 安装」选中它。
2. 一个包多个扩展时，装完会提示装了哪几个。
3. 管理页显示加载状态；失败时给出 `diagnoseExtension:` 的原因（含尝试过的路径）。
4. 重装同 id 会覆盖旧目录并清掉回退位置的旧副本；装完点一次「重新加载」。

沙盒限制：

- deb 版（rootless/roothide）：可从 `/var/mobile/Documents/...` 原地 `dlopen`。
- IPA 版：数据目录禁止 `mmap` 可执行页，宿主会把 dylib 复制到 `Library/Caches/MTExtensions` 等位置再加载。
- 别把 dylib 放只读位置。

---

## 9. 编辑器接管与按格式禁用

manifest 写了 `editors`/`editorExtensions` 才参与接管。多个扩展抢同一后缀时按安装顺序问，第一个返回非 nil 的赢。用户能在「扩展管理 → 详情 → 编辑器接管」按格式关掉某个扩展，所以返回 nil 要干脆。

---

## 10. 常见坑

| 现象 | 原因 |
|---|---|
| 装不上，框架版本不对 | `framework` 不是 `v2.x` |
| 装上了但侧栏没有 | 没写 `sidebar` 或 `items` 为空 |
| 点条目闪退 | `mt_makePageForItem:` 返回 nil，或 VC 里访问了不存在的宿主类 |
| dylib 加载失败 | 少了 `-undefined dynamic_lookup`，或切片不对 |
| 图标不显示 | `iconImage` 路径不在扩展目录内、文件不是 PNG，或 id 与目录名不一致 |
| 终端调用返回 -1 | 用户没允许 terminal；或当前是 IPA/沙盒版；或设备没有 `/var/jb` 的 bash/sh |
| 联网一直失败码 2 | 用户点了「拒绝」 |
| 编辑器不生效 | 没声明后缀 / 用户关掉了该格式 / 别的扩展先接管 |
| 页面顶部被压住 | 自定义 VC 设 `edgesForExtendedLayout = UIRectEdgeNone` |

---

## 11. 最小清单

- [ ] 包后缀 `.mtextra`，manifest 在包根（多扩展才用子目录，每层都要 manifest.json）
- [ ] `framework` = `v2.1.0`，`id` 唯一（上市场时 = 目录名）
- [ ] dylib 名与 manifest 一致，导出 `MTCreateExtension`
- [ ] 编译带 `-undefined dynamic_lookup`，arm64，已 `ldid -S`
- [ ] 侧栏每个 `items[].id` 都有分支
- [ ] 用了联网/终端 → 走 `MTExtNetRequest` / `MTExtShellRun`，并处理「拒绝」与沙盒两种情况
- [ ] 上市场：按 `MARKET.md` 放 `repo/ext/<id>/`，版本号记得改
