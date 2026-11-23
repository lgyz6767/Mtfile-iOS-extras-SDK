#import <UIKit/UIKit.h>

// ============================================================
//  宿主进程 API（v2.1）：扩展是 dlopen 进宿主进程的 dylib，自己不能 fork/exec，
//  由宿主代跑外部可执行文件。**只有非沙盒（deb/rootless/roothide）环境可用**，
//  IPA/TrollStore 版会返回 NO（沙盒里 posix_spawn 直接 EPERM）。
//
//  在扩展 dylib 里这样拿符号（扩展构建用 -undefined dynamic_lookup）：
//      pid_t (*spawn)(NSString *, NSArray *, NSDictionary *, NSString *,
//                     void(^)(NSString *, BOOL), void(^)(int)) =
//          (void *)dlsym(RTLD_DEFAULT, "MTExtProcessSpawn");
// ============================================================

typedef void (^MTExtProcessOutputBlock)(NSString *chunk, BOOL isStderr);
typedef void (^MTExtProcessExitBlock)(int status);

/// 宿主能否起子进程（沙盒版返回 NO）
FOUNDATION_EXPORT BOOL MTExtProcessAvailable(void);
FOUNDATION_EXPORT NSString *MTExtProcessUnavailableReason(void);   // 不可用时的原因（沙盒 / 缺文件）
/// 起一个子进程；返回 pid，失败返回 -1。cwd 由 posix_spawn 无法设置，请把路径都写成绝对路径。
FOUNDATION_EXPORT pid_t MTExtProcessSpawn(NSString *exe,
                                          NSArray<NSString *> *args,
                                          NSDictionary<NSString *, NSString *> *envAdditions,
                                          NSString *cwd,
                                          MTExtProcessOutputBlock onOutput,
                                          MTExtProcessExitBlock onExit);
/// 结束子进程（SIGTERM → 300ms 后 SIGKILL）
FOUNDATION_EXPORT void MTExtProcessKill(pid_t pid);
/// 端口用途：给扩展做「等端口起来」的轮询
FOUNDATION_EXPORT BOOL MTExtPortIsListening(NSInteger port);

// ============================================================
//  扩展权限 / 终端 / 网络（v2.1）
//  扩展要联网、要跑命令，必须先拿到用户同意（弹窗，存在 NSUserDefaults），
//  描述文件里写一句不算数。
// ============================================================

/// 能力：@"network" / @"terminal"
FOUNDATION_EXPORT BOOL MTExtConsentGranted(NSString *extID, NSString *capability);
/// 没有授权就弹窗问用户；授权结果异步回调（主线程）
FOUNDATION_EXPORT void MTExtRequestConsent(NSString *extID, NSString *capability, NSString *reason, void (^callback)(BOOL granted));
/// 跑一条 shell 命令（需要 terminal 权限）。返回 pid，失败 -1（未授权时输出里会写原因）
FOUNDATION_EXPORT pid_t MTExtShellRun(NSString *extID, NSString *command, NSString *cwd,
                                       MTExtProcessOutputBlock onOutput, MTExtProcessExitBlock onExit);
/// 联网请求（需要 network 权限），首次调用会弹窗；回调在主线程
FOUNDATION_EXPORT void MTExtNetRequest(NSString *extID, NSString *urlString, NSDictionary<NSString *, NSString *> *headers,
                                       void (^done)(NSData *data, NSInteger status, NSError *error));

// ============================================================
//  MT EXTENSION FRAMEWORK v2.0.0
//  扩展包格式：zip（manifest.json + *.dylib + 资源）
//  宿主通过 dlopen 加载 dylib，调用 MTCreateExtension() 取得实例
// ============================================================

@protocol MTExtV2Extension <NSObject>
// 侧栏分类中某个条目的自定义页面（设置项 / 功能页）
- (UIViewController *)mt_makePageForItem:(NSString *)itemID context:(NSDictionary *)ctx;
@optional
// 注入编辑器：返回 nil 表示不接管，宿主回退到内置编辑器
- (UIViewController *)mt_makeEditorForPath:(NSString *)path;
@end

typedef id<MTExtV2Extension> (*MTExtV2Factory)(void);

@interface MTExtV2Store : NSObject
+ (NSString *)rootPath;                                   // 扩展安装目录（与旧版隔离）
+ (NSArray<NSDictionary *> *)installed;                   // {manifest, dir, dylibPath, id}
+ (NSArray<NSDictionary *> *)sidebarGroups;               // [{title, items:[{title,id,extID,icon}]}]
+ (UIViewController *)pageForExtension:(NSString *)eid item:(NSString *)itemID context:(NSDictionary *)ctx;
+ (NSArray<NSString *> *)editorFormatsForExtension:(NSString *)eid;   // manifest 声明的可接管格式
+ (BOOL)isEditorEnabledForExtension:(NSString *)eid format:(NSString *)fmt;
+ (void)setEditorEnabled:(BOOL)enabled forExtension:(NSString *)eid format:(NSString *)fmt;
+ (UIViewController *)editorForPath:(NSString *)path;     // 无扩展接管时返回 nil
+ (UIViewController *)editorForPath:(NSString *)path preferExtension:(NSString *)eid;
// 注册过的编辑器（打开方式「扩展」专栏用）：{eid,title,icon,formats,cat,enabled}
+ (NSArray<NSDictionary *> *)registeredEditors;
+ (void)purgeCacheForExtension:(NSString *)eid;   // 重装扩展后清掉回退位置的旧副本
+ (NSString *)loadedPathForExtension:(NSString *)eid;   // 实际 dlopen 成功的路径（可能是回退位置）
+ (void)invalidate;   // 清扫描缓存（安装/卸载后调）
+ (BOOL)isExtensionZip:(NSString *)zipPath;     // 老接口：.zip 且含 manifest.json（兼容保留）
+ (BOOL)isExtensionArchive:(NSString *)path;    // .mtextra 或 zip 魔数，且包内（含一层子目录）有 manifest.json
+ (BOOL)installZipAtPath:(NSString *)zipPath error:(NSError **)err;   // 单扩展安装，只装第一个
+ (NSArray<NSDictionary *> *)installArchiveAtPath:(NSString *)path error:(NSError **)err;  // 支持一个包多个扩展
+ (UIImage *)iconImageForExtension:(NSString *)eid file:(NSString *)rel;   // 自定义图标（相对扩展目录）
+ (UIImage *)iconForItem:(NSDictionary *)item;   // 有 iconImage 用自定义图，否则 SF Symbol（item 里要有 extID）
+ (BOOL)extractZip:(NSString *)zipPath toDirectory:(NSString *)dest error:(NSError **)err;
+ (BOOL)removeExtension:(NSString *)eid error:(NSError **)err;
+ (NSString *)diagnoseExtension:(NSString *)eid;   // 返回 nil 表示能正常 dlopen；否则是失败原因
@end

#pragma mark - 内置 zip 工具（虚拟目录 / 图标提取共用）

FOUNDATION_EXPORT NSArray<NSDictionary *> *MTZipListEntries(NSString *zipPath);   // [{name,size,isDir}]
FOUNDATION_EXPORT BOOL MTZipIsArchiveFile(NSString *path);                        // 按魔数判断是否 zip 容器（zip/apk/mtz/xapk…）
FOUNDATION_EXPORT NSData *MTZipReadEntryNamed(NSString *zipPath, NSString *nameSuffix);
FOUNDATION_EXPORT NSData *MTZipReadEntryAt(NSString *zipPath, NSString *innerPath);
