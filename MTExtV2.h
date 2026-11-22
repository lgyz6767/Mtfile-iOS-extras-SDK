#import <UIKit/UIKit.h>

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
+ (BOOL)isExtensionZip:(NSString *)zipPath;
+ (BOOL)installZipAtPath:(NSString *)zipPath error:(NSError **)err;
+ (BOOL)extractZip:(NSString *)zipPath toDirectory:(NSString *)dest error:(NSError **)err;
+ (BOOL)removeExtension:(NSString *)eid error:(NSError **)err;
+ (NSString *)diagnoseExtension:(NSString *)eid;   // 返回 nil 表示能正常 dlopen；否则是失败原因
@end

#pragma mark - 内置 zip 工具（虚拟目录 / 图标提取共用）

FOUNDATION_EXPORT NSArray<NSDictionary *> *MTZipListEntries(NSString *zipPath);   // [{name,size,isDir}]
FOUNDATION_EXPORT BOOL MTZipIsArchiveFile(NSString *path);                        // 按魔数判断是否 zip 容器（zip/apk/mtz/xapk…）
FOUNDATION_EXPORT NSData *MTZipReadEntryNamed(NSString *zipPath, NSString *nameSuffix);
FOUNDATION_EXPORT NSData *MTZipReadEntryAt(NSString *zipPath, NSString *innerPath);
