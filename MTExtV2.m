#import "MTExtV2.h"
#import <dlfcn.h>
#import <zlib.h>
#import <sys/stat.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>
extern char **environ;


// 安装后自动重新签名：越狱机上的 dylib 未签名会被 dlopen 拒绝（Killed:9 / code-sign 失败）
static void MTSignDylibIfPossible(NSString *path) {
    NSString *ldid = nil;
    for (NSString *c in @[@"/var/jb/usr/bin/ldid", @"/usr/bin/ldid", @"/var/jb/usr/local/bin/ldid", @"/usr/local/bin/ldid"]) {
        if (access(c.UTF8String, X_OK) == 0) { ldid = c; break; }
    }
    if (!ldid) return;
    const char *argv[] = {ldid.UTF8String, "-S", path.UTF8String, NULL};
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);
    pid_t pid = 0;
    posix_spawn(&pid, ldid.UTF8String, &fa, NULL, (char *const *)argv, environ);
    if (pid > 0) { int st = 0; waitpid(pid, &st, 0); }
    posix_spawn_file_actions_destroy(&fa);
}


// 沙盒版 App 不允许从 /var/mobile 直接 mmap 可执行页（dyld 报 "file system sandbox blocked mmap()"）。
// 因此按“原地 → 临时目录 → Caches → App 包内”逐个试，全部失败时把每次尝试的错误留给人看。
static void *MTDlopenWithFallbacks(NSString *src, NSString *eid, NSString **usedPath, NSString **errOut) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *cands = [NSMutableArray arrayWithObject:src];
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"mtext_%@.dylib", eid]];
    NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject
                        stringByAppendingPathComponent:@"MTExtensions"];
    NSString *bundleDir = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"MTExtensions"];
    NSString *jb = [@"/var/jb/var/mobile/Library/Caches/MTExtensions" stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.dylib", eid]];
    [cands addObject:tmp];
    [cands addObject:[caches stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.dylib", eid]]];
    [cands addObject:[bundleDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.dylib", eid]]];
    [cands addObject:jb];

    NSMutableString *log = [NSMutableString string];
    for (NSString *c in cands) {
        BOOL needCopy = ![fm fileExistsAtPath:c];
        if (!needCopy) {
            // 源文件更新过（重装扩展）就刷新缓存副本，否则会一直跑旧 dylib
            NSDictionary *a = [fm attributesOfItemAtPath:c error:NULL];
            NSDictionary *b = [fm attributesOfItemAtPath:src error:NULL];
            if (a && b) {
                NSDate *ad = a[NSFileModificationDate], *bd = b[NSFileModificationDate];
                if (![a[NSFileSize] isEqual:b[NSFileSize]] || (bd && ad && [bd compare:ad] == NSOrderedDescending)) {
                    needCopy = YES;
                }
            }
        }
        if (needCopy) {
            // 不是原路径的先复制一份过去；目标已存在时先删再拷（扩展更新后必须换掉旧副本）
            NSError *cpErr = nil;
            [fm createDirectoryAtPath:[c stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:NULL];
            if ([fm fileExistsAtPath:c]) [fm removeItemAtPath:c error:NULL];
            if (![fm copyItemAtPath:src toPath:c error:&cpErr]) {
                [log appendFormat:@"%@ → 复制失败(%@)\n", c, cpErr.localizedDescription ?: @"?"];
                // 拷不过去但目标还在（只读目录等）就照样试加载
                if (![fm fileExistsAtPath:c]) continue;
            }
            chmod(c.UTF8String, 0755);
            MTSignDylibIfPossible(c);
            chmod(c.UTF8String, 0755);
        }
        void *h = dlopen(c.UTF8String, RTLD_LAZY | RTLD_LOCAL);
        if (h) { if (usedPath) *usedPath = c; return h; }
        [log appendFormat:@"%@ → %s\n", c, dlerror() ?: "unknown"];
    }
    if (errOut) *errOut = log;
    return NULL;
}

static NSMutableDictionary<NSString *, id> *gInstances = nil;
static NSMutableDictionary<NSString *, NSString *> *gResolvedPaths = nil;
static NSArray<NSDictionary *> *gCache = nil;

@implementation MTExtV2Store

+ (NSString *)rootPath {
    return @"/var/mobile/Documents/MTFile/Extensions2";
}

+ (void)ensureDir {
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:[self rootPath] withIntermediateDirectories:YES attributes:nil error:NULL];
}

#pragma mark - 扫描与校验

+ (NSArray<NSDictionary *> *)installed {
    if (gCache) return gCache;
    [self ensureDir];
    NSMutableArray *out = [NSMutableArray array];
    NSString *root = [self rootPath];
    for (NSString *dir in [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:NULL]) {
        NSString *full = [root stringByAppendingPathComponent:dir];
        NSString *mp = [full stringByAppendingPathComponent:@"manifest.json"];
        NSData *md = [NSData dataWithContentsOfFile:mp];
        if (!md) continue;
        NSDictionary *m = [NSJSONSerialization JSONObjectWithData:md options:0 error:NULL];
        if (![m isKindOfClass:[NSDictionary class]]) continue;
        NSString *fw = [m[@"framework"] description];
        if (![fw hasPrefix:@"v2"]) continue;                 // 只认 v2，忽略旧版
        NSString *eid = m[@"id"] ?: dir;
        NSString *dylib = m[@"dylib"] ?: @"";
        NSString *dp = [full stringByAppendingPathComponent:dylib];
        NSMutableDictionary *d = [m mutableCopy];
        d[@"dir"] = full;
        d[@"dylibPath"] = dp;
        d[@"id"] = eid;
        d[@"entryExists"] = @([NSFileManager.defaultManager fileExistsAtPath:dp]);
        // 编辑器注册：manifest.editors = [{format/name/icon}]，兼容旧的 editorExtensions 数组
        NSMutableArray *fmts = [NSMutableArray array];
        NSArray *eds = m[@"editors"];
        if ([eds isKindOfClass:[NSArray class]]) {
            for (id ed in eds) {
                if ([ed isKindOfClass:[NSString class]]) { [fmts addObject:[(NSString *)ed lowercaseString]]; continue; }
                if (![ed isKindOfClass:[NSDictionary class]]) continue;
                id f = ed[@"format"] ?: ed[@"ext"];
                NSArray *many = [f isKindOfClass:[NSArray class]] ? f : (f ? @[f] : @[]);
                for (id one in many) if ([one isKindOfClass:[NSString class]]) [fmts addObject:[one lowercaseString]];
            }
            if (eds.count && [[eds firstObject] isKindOfClass:[NSDictionary class]]) d[@"editorInfo"] = [eds firstObject];
        }
        NSArray *legacy = m[@"editorExtensions"];
        if ([legacy isKindOfClass:[NSArray class]])
            for (id one in legacy) if ([one isKindOfClass:[NSString class]]) [fmts addObject:[one lowercaseString]];
        d[@"editorExtensions"] = fmts;
        [out addObject:d];
    }
    gCache = out;
    return out;
}

+ (void)invalidate { gCache = nil; }

+ (NSArray<NSDictionary *> *)sidebarGroups {
    NSMutableDictionary<NSString *, NSMutableArray *> *groups = [NSMutableDictionary dictionary];
    NSMutableArray *order = [NSMutableArray array];
    for (NSDictionary *e in [self installed]) {
        NSDictionary *sb = e[@"sidebar"];
        if (![sb isKindOfClass:[NSDictionary class]]) continue;
        NSString *cat = sb[@"category"] ?: e[@"name"] ?: @"扩展";
        if (!groups[cat]) { groups[cat] = [NSMutableArray array]; [order addObject:cat]; }
        NSArray *items = sb[@"items"];
        if (![items isKindOfClass:[NSArray class]]) continue;
        for (NSDictionary *it in items) {
            if (![it isKindOfClass:[NSDictionary class]]) continue;
            [groups[cat] addObject:@{@"title": it[@"title"] ?: @"未命名",
                                     @"id": it[@"id"] ?: @"default",
                                     @"icon": it[@"icon"] ?: @"puzzlepiece",
                                     @"iconImage": it[@"iconImage"] ?: (e[@"iconImage"] ?: @""),
                                     @"extID": e[@"id"] ?: @""}];
        }
    }
    NSMutableArray *res = [NSMutableArray array];
    for (NSString *cat in order) [res addObject:@{@"title": cat, @"items": groups[cat]}];
    return res;
}

#pragma mark - dlopen

+ (id<MTExtV2Extension>)instanceForExtension:(NSString *)eid {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gInstances = [NSMutableDictionary dictionary]; });
    id cached = gInstances[eid];
    if (cached) return cached;
    NSDictionary *e = nil;
    for (NSDictionary *x in [self installed]) if ([x[@"id"] isEqualToString:eid]) { e = x; break; }
    if (!e || ![e[@"entryExists"] boolValue]) return nil;
    void *h = MTDlopenWithFallbacks(e[@"dylibPath"], eid, NULL, NULL);
    if (!h) return nil;
    MTExtV2Factory f = (MTExtV2Factory)dlsym(h, "MTCreateExtension");
    if (!f) { dlclose(h); return nil; }
    id<MTExtV2Extension> inst = f();
    if (inst) gInstances[eid] = inst;
    return inst;
}

+ (UIViewController *)pageForExtension:(NSString *)eid item:(NSString *)itemID context:(NSDictionary *)ctx {
    id<MTExtV2Extension> inst = [self instanceForExtension:eid];
    if (![inst respondsToSelector:@selector(mt_makePageForItem:context:)]) return nil;
    return [inst mt_makePageForItem:itemID context:ctx ?: @{}];
}

static NSString *const kMTExtEditorOffKey = @"mt_ext_editor_off";

+ (NSArray<NSString *> *)editorFormatsForExtension:(NSString *)eid {
    for (NSDictionary *e in [self installed]) {
        if (![e[@"id"] isEqualToString:eid]) continue;
        NSArray *exts = e[@"editorExtensions"];
        return [exts isKindOfClass:[NSArray class]] ? exts : @[];
    }
    return @[];
}

+ (BOOL)isEditorEnabledForExtension:(NSString *)eid format:(NSString *)fmt {
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kMTExtEditorOffKey];
    NSArray *off = [d[eid] isKindOfClass:[NSArray class]] ? d[eid] : nil;
    return ![off containsObject:fmt.lowercaseString];
}

+ (void)setEditorEnabled:(BOOL)enabled forExtension:(NSString *)eid format:(NSString *)fmt {
    NSMutableDictionary *d = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:kMTExtEditorOffKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableArray *off = [[d[eid] isKindOfClass:[NSArray class]] ? d[eid] : @[] mutableCopy];
    NSString *f = fmt.lowercaseString;
    [off removeObject:f];
    if (!enabled) [off addObject:f];
    if (off.count) d[eid] = off; else [d removeObjectForKey:eid];
    [[NSUserDefaults standardUserDefaults] setObject:d forKey:kMTExtEditorOffKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (NSArray<NSDictionary *> *)registeredEditors {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *e in [self installed]) {
        NSString *eid = e[@"id"];
        if (!eid.length) continue;
        NSArray *formats = e[@"editorExtensions"];
        if (![formats isKindOfClass:[NSArray class]] || !formats.count) continue;
        NSDictionary *meta = [e[@"editorInfo"] isKindOfClass:[NSDictionary class]] ? e[@"editorInfo"] : @{};
        NSString *title = meta[@"name"] ?: e[@"name"] ?: eid;
        NSString *icon = meta[@"icon"] ?: @"pencil";
        NSString *cat = meta[@"cat"] ?: [self categoryForFormats:formats];
        [out addObject:@{@"eid": eid, @"title": title, @"icon": icon, @"formats": formats,
                         @"cat": cat, @"kind": @"extension"}];
    }
    return out;
}

// 按声明的格式归类，决定在「打开方式」里落到哪一栏
+ (NSString *)categoryForFormats:(NSArray *)formats {
    NSSet *img = [NSSet setWithArray:@[@"png", @"jpg", @"jpeg", @"gif", @"webp", @"heic", @"svg"]];
    NSSet *vid = [NSSet setWithArray:@[@"mp4", @"mov", @"m4v", @"mkv", @"avi"]];
    NSSet *arc = [NSSet setWithArray:@[@"zip", @"7z", @"rar", @"tar", @"gz", @"apk", @"ipa"]];
    NSSet *code = [NSSet setWithArray:@[@"js", @"json", @"xml", @"html", @"css", @"sh", @"py", @"c", @"m", @"h", @"lua"]];
    for (NSString *f in formats) {
        NSString *x = [f lowercaseString];
        if ([img containsObject:x]) return @"image";
    }
    for (NSString *f in formats) if ([vid containsObject:[f lowercaseString]]) return @"video";
    for (NSString *f in formats) if ([arc containsObject:[f lowercaseString]]) return @"archive";
    for (NSString *f in formats) if ([code containsObject:[f lowercaseString]]) return @"text";
    return @"text";
}

+ (UIViewController *)editorForPath:(NSString *)path preferExtension:(NSString *)eid {
    if (!eid.length) return [self editorForPath:path];
    NSString *ext = path.pathExtension.lowercaseString;
    for (NSDictionary *e in [self installed]) {
        if (![e[@"id"] isEqualToString:eid]) continue;
        NSArray *exts = e[@"editorExtensions"];
        if (![exts isKindOfClass:[NSArray class]] || ![exts containsObject:ext]) continue;
        if (![self isEditorEnabledForExtension:eid format:ext]) continue;
        id<MTExtV2Extension> inst = [self instanceForExtension:eid];
        if ([inst respondsToSelector:@selector(mt_makeEditorForPath:)]) return [inst mt_makeEditorForPath:path];
    }
    return nil;
}

+ (UIViewController *)editorForPath:(NSString *)path {
    NSString *ext = path.pathExtension.lowercaseString;
    for (NSDictionary *e in [self installed]) {
        NSArray *exts = e[@"editorExtensions"];
        if (![exts isKindOfClass:[NSArray class]]) continue;
        if (![exts containsObject:ext]) continue;
        if (![self isEditorEnabledForExtension:e[@"id"] format:ext]) continue;
        id<MTExtV2Extension> inst = [self instanceForExtension:e[@"id"]];
        if ([inst respondsToSelector:@selector(mt_makeEditorForPath:)]) {
            UIViewController *vc = [inst mt_makeEditorForPath:path];
            if (vc) return vc;
        }
    }
    return nil;
}

#pragma mark - zip 解压（内置，不依赖外部 unzip）

static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t rd32(const uint8_t *p) { return (uint32_t)(p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24)); }

+ (BOOL)extractZip:(NSString *)zipPath toDirectory:(NSString *)dest error:(NSError **)err {
    NSData *zip = [NSData dataWithContentsOfFile:zipPath options:NSDataReadingMappedIfSafe error:err];
    if (!zip || zip.length < 22) {
        if (err) *err = [NSError errorWithDomain:@"MTExtV2" code:1 userInfo:@{NSLocalizedDescriptionKey: @"无法读取 zip 文件"}];
        return NO;
    }
    const uint8_t *b = zip.bytes;
    NSUInteger len = zip.length;
    NSUInteger eocd = NSNotFound;
    for (NSUInteger i = len - 22; i + 4 <= len; i--) {
        if (b[i] == 0x50 && b[i+1] == 0x4b && b[i+2] == 0x05 && b[i+3] == 0x06) { eocd = i; break; }
        if (i == 0) break;
    }
    if (eocd == NSNotFound) {
        if (err) *err = [NSError errorWithDomain:@"MTExtV2" code:2 userInfo:@{NSLocalizedDescriptionKey: @"不是有效的 zip（找不到中央目录）"}];
        return NO;
    }
    uint16_t entries = rd16(b + eocd + 10);
    uint32_t cdOff = rd32(b + eocd + 16);
    if (cdOff >= len) return NO;
    [NSFileManager.defaultManager createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:NULL];
    NSUInteger p = cdOff;
    for (uint16_t n = 0; n < entries; n++) {
        if (p + 46 > len || rd32(b + p) != 0x02014b50) break;
        uint16_t method = rd16(b + p + 10);
        uint32_t csize = rd32(b + p + 20), usize = rd32(b + p + 24);
        uint16_t nameLen = rd16(b + p + 28), extraLen = rd16(b + p + 30), cmtLen = rd16(b + p + 32);
        uint32_t lo = rd32(b + p + 42);
        NSString *name = [[NSString alloc] initWithBytes:b + p + 46 length:nameLen encoding:NSUTF8StringEncoding];
        if (!name) name = [[NSString alloc] initWithBytes:b + p + 46 length:nameLen encoding:NSISOLatin1StringEncoding];
        p += 46 + nameLen + extraLen + cmtLen;
        if (!name.length || [name containsString:@"../"]) continue;
        if (lo + 30 > len) continue;
        uint16_t lnLen = rd16(b + lo + 26), lExtra = rd16(b + lo + 28);
        NSUInteger dataOff = lo + 30 + lnLen + lExtra;
        if (dataOff + csize > len) continue;
        NSString *outPath = [dest stringByAppendingPathComponent:name];
        if ([name hasSuffix:@"/"]) {
            [NSFileManager.defaultManager createDirectoryAtPath:outPath withIntermediateDirectories:YES attributes:nil error:NULL];
            continue;
        }
        [NSFileManager.defaultManager createDirectoryAtPath:outPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
        NSData *payload = nil;
        if (method == 0) {
            payload = [zip subdataWithRange:NSMakeRange(dataOff, csize)];
        } else if (method == 8) {
            NSMutableData *out = [NSMutableData dataWithLength:MAX(usize, 1)];
            z_stream zs; memset(&zs, 0, sizeof(zs));
            zs.next_in = (Bytef *)(b + dataOff); zs.avail_in = csize;
            zs.next_out = out.mutableBytes; zs.avail_out = (uInt)out.length;
            if (inflateInit2(&zs, -15) != Z_OK) continue;
            int rc = inflate(&zs, Z_FINISH);
            inflateEnd(&zs);
            if (rc != Z_STREAM_END) continue;
            out.length = zs.total_out;
            payload = out;
        } else {
            continue;
        }
        if (![payload writeToFile:outPath atomically:YES]) continue;
    }
    return YES;
}

#pragma mark - 安装 / 卸载

+ (BOOL)isExtensionZip:(NSString *)zipPath {
    return [[zipPath.pathExtension lowercaseString] isEqualToString:@"zip"] && [self isExtensionArchive:zipPath];
}

// .mtextra 本质是 zip：只看魔数与目录，不整包解压，普通 zip 不会被误判/白算
+ (BOOL)isExtensionArchive:(NSString *)path {
    if (!path.length || ![[NSFileManager defaultManager] fileExistsAtPath:path]) return NO;
    if (!MTZipIsArchiveFile(path)) return NO;
    for (NSDictionary *e in MTZipListEntries(path)) {
        NSString *n = e[@"name"] ?: @"";
        if (![n hasSuffix:@"manifest.json"]) continue;
        // 根目录 / 一层子目录 / 两层子目录（一个 zip 多扩展时常见多一层）
        if ([n isEqualToString:@"manifest.json"] || n.pathComponents.count <= 3) return YES;
    }
    return NO;
}

+ (UIImage *)iconForItem:(NSDictionary *)item {
    if (![item isKindOfClass:[NSDictionary class]]) return nil;
    UIImage *custom = [self iconImageForExtension:item[@"extID"] file:item[@"iconImage"]];
    if (custom) return [custom imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    return [UIImage systemImageNamed:[item[@"icon"] description]];
}

+ (UIImage *)iconImageForExtension:(NSString *)eid file:(NSString *)rel {
    if (!eid.length || !rel.length) return nil;
    if ([rel containsString:@".."]) return nil;
    NSString *p = [[[self rootPath] stringByAppendingPathComponent:eid] stringByAppendingPathComponent:rel];
    if (![[NSFileManager defaultManager] fileExistsAtPath:p]) return nil;
    return [UIImage imageWithContentsOfFile:p];
}

// 从一个解压好的目录安装单个扩展；成功返回 {id, name, version, target}
+ (NSDictionary *)installSingleFromDir:(NSString *)dir error:(NSError **)err {
    NSString *mp = [dir stringByAppendingPathComponent:@"manifest.json"];
    NSData *md = [NSData dataWithContentsOfFile:mp];
    NSDictionary *m = md ? [NSJSONSerialization JSONObjectWithData:md options:0 error:NULL] : nil;
    if (![m isKindOfClass:[NSDictionary class]]) {
        if (err) *err = [NSError errorWithDomain:@"MTExtV2" code:3 userInfo:@{NSLocalizedDescriptionKey: @"zip 内缺少 manifest.json 或 JSON 格式错误"}];
        return nil;
    }
    if (![[m[@"framework"] description] hasPrefix:@"v2"]) {
        if (err) *err = [NSError errorWithDomain:@"MTExtV2" code:4 userInfo:@{NSLocalizedDescriptionKey: @"扩展框架版本不是 v2.0.0，属于旧版扩展，请使用旧安装方式"}];
        return nil;
    }
    NSString *dylib = m[@"dylib"] ?: @"";
    if (!dylib.length || ![[NSFileManager defaultManager] fileExistsAtPath:[dir stringByAppendingPathComponent:dylib]]) {
        if (err) *err = [NSError errorWithDomain:@"MTExtV2" code:5 userInfo:@{NSLocalizedDescriptionKey: @"manifest 指定的 dylib 不存在"}];
        return nil;
    }
    NSString *eid = m[@"id"] ?: m[@"name"];
    if (!eid.length) {
        if (err) *err = [NSError errorWithDomain:@"MTExtV2" code:6 userInfo:@{NSLocalizedDescriptionKey: @"manifest 缺少 id"}];
        return nil;
    }
    NSString *target = [[self rootPath] stringByAppendingPathComponent:eid];
    [[NSFileManager defaultManager] removeItemAtPath:target error:NULL];
    NSError *mvErr = nil;
    if (![[NSFileManager defaultManager] moveItemAtPath:dir toPath:target error:&mvErr]) {
        if (err) *err = mvErr;
        return nil;
    }
    NSString *dylibPath = [target stringByAppendingPathComponent:dylib];
    chmod(dylibPath.UTF8String, 0755);
    MTSignDylibIfPossible(dylibPath);
    chmod(dylibPath.UTF8String, 0755);
    [self purgeCacheForExtension:eid];
    [self invalidate];
    return @{@"id": eid, @"name": m[@"name"] ?: eid, @"version": m[@"version"] ?: @"", @"target": target};
}

+ (NSArray<NSDictionary *> *)installArchiveAtPath:(NSString *)path error:(NSError **)err {
    [self ensureDir];
    if (![self isExtensionArchive:path]) {
        if (err) *err = [NSError errorWithDomain:@"MTExtV2" code:2 userInfo:@{NSLocalizedDescriptionKey: @"这不是扩展包：zip 里（含一层子目录）找不到 manifest.json"}];
        return nil;
    }
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"_mt_ext2"];
    [NSFileManager.defaultManager removeItemAtPath:tmp error:NULL];
    NSError *e = nil;
    if (![self extractZip:path toDirectory:tmp error:&e]) { if (err) *err = e; return nil; }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *cands = [NSMutableArray array];
    if ([fm fileExistsAtPath:[tmp stringByAppendingPathComponent:@"manifest.json"]]) {
        [cands addObject:tmp];      // 根上有就是单扩展，忽略子目录
    } else {
        // 根上没有 → 一层子目录都试一遍，实现一个 zip 装多个扩展
        for (NSString *n in [fm contentsOfDirectoryAtPath:tmp error:NULL] ?: @[]) {
            NSString *sub = [tmp stringByAppendingPathComponent:n];
            BOOL isDir = NO;
            [fm fileExistsAtPath:sub isDirectory:&isDir];
            if (isDir && [fm fileExistsAtPath:[sub stringByAppendingPathComponent:@"manifest.json"]]) [cands addObject:sub];
        }
        if (!cands.count) {
            // 再退一层：套娃目录
            for (NSString *n in [fm contentsOfDirectoryAtPath:tmp error:NULL] ?: @[]) {
                NSString *sub = [tmp stringByAppendingPathComponent:n];
                BOOL isDir = NO;
                [fm fileExistsAtPath:sub isDirectory:&isDir];
                if (!isDir) continue;
                for (NSString *n2 in [fm contentsOfDirectoryAtPath:sub error:NULL] ?: @[]) {
                    NSString *sub2 = [sub stringByAppendingPathComponent:n2];
                    BOOL d2 = NO;
                    [fm fileExistsAtPath:sub2 isDirectory:&d2];
                    if (d2 && [fm fileExistsAtPath:[sub2 stringByAppendingPathComponent:@"manifest.json"]]) [cands addObject:sub2];
                }
            }
        }
    }
    if (!cands.count) {
        if (err) *err = [NSError errorWithDomain:@"MTExtV2" code:3 userInfo:@{NSLocalizedDescriptionKey: @"zip 里找不到 manifest.json"}];
        return nil;
    }
    NSMutableArray *done = [NSMutableArray array];
    NSMutableArray *fails = [NSMutableArray array];
    for (NSString *d in cands) {
        NSError *one = nil;
        NSDictionary *r = [self installSingleFromDir:d error:&one];
        if (r) [done addObject:r];
        else [fails addObject:one.localizedDescription ?: @"未知错误"];
    }
    [NSFileManager.defaultManager removeItemAtPath:tmp error:NULL];
    if (!done.count) {
        if (err) *err = [NSError errorWithDomain:@"MTExtV2" code:7 userInfo:@{NSLocalizedDescriptionKey: [fails componentsJoinedByString:@"；"]}];
        return nil;
    }
    if (fails.count) NSLog(@"[MTExtV2] 部分扩展安装失败：%@", fails);
    return done;
}

+ (BOOL)installZipAtPath:(NSString *)zipPath error:(NSError **)err {
    NSArray *r = [self installArchiveAtPath:zipPath error:err];
    return r.count > 0;
}

// 诊断缓存：dylib 的 mtime+大小没变就直接返回上次结果，避免每次进扩展管理都把所有 dylib 重新 dlopen 一遍
static NSMutableDictionary *gMTDiagCache = nil;

+ (NSString *)diagnoseExtension:(NSString *)eid {
    NSMutableDictionary *cache = nil;
    @synchronized (self.class) {
        if (!gMTDiagCache) gMTDiagCache = [NSMutableDictionary dictionary];
        cache = gMTDiagCache;
    }
    NSDictionary *e = nil;
    for (NSDictionary *x in [self installed]) if ([x[@"id"] isEqualToString:eid]) { e = x; break; }
    if (!e) return @"扩展未安装（manifest.json 缺失或不是 v2）";
    if (![e[@"entryExists"] boolValue]) return [NSString stringWithFormat:@"dylib 不存在：%@", e[@"dylibPath"]];
    NSString *path = e[@"dylibPath"];
    NSDictionary *attr = [NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL];
    NSString *sig = [NSString stringWithFormat:@"%@-%@", attr[NSFileModificationDate], attr[NSFileSize]];
    NSString *cached = nil;
    @synchronized (self.class) {
        NSDictionary *c = cache[eid];
        if (c && [c[@"sig"] isEqualToString:sig]) cached = c[@"res"] ?: @"";
    }
    if (cached) return cached.length ? cached : nil;
    NSString *arch = [NSString stringWithFormat:@"dylib 大小 %@", attr[NSFileSize]];
    if (![[NSFileManager defaultManager] isReadableFileAtPath:path]) return @"dylib 不可读（权限问题）";
    NSString *usedPath = nil, *detail = nil;
    void *h = MTDlopenWithFallbacks(path, eid, &usedPath, &detail);
    if (!h) {
        NSString *why = @"";
        if ([detail containsString:@"sandbox blocked mmap"]) {
            why = @"\n→ 当前这个 App 是沙盒版（IPA），系统禁止从数据目录映射可执行代码，扩展 dylib 无法进程内加载。换用 deb 版（rootless/roothide，非沙盒）即可，或等我把扩展改成独立进程模式。";
        }
        NSString *res = [NSString stringWithFormat:@"dlopen 全部失败（%@）%@\n%@", arch, why, detail ?: @""];
        @synchronized (self.class) { cache[eid] = @{@"sig": sig, @"res": res}; }
        return res;
    }
    @synchronized (MTExtV2Store.class) {
        if (!gResolvedPaths) gResolvedPaths = [NSMutableDictionary dictionary];
        gResolvedPaths[eid] = usedPath ?: path;
    }
    void *sym = dlsym(h, "MTCreateExtension");
    if (!sym) {
        dlclose(h);
        NSString *res = [NSString stringWithFormat:@"dylib 里没有 MTCreateExtension 导出（%@）", arch];
        @synchronized (self.class) { cache[eid] = @{@"sig": sig, @"res": res}; }
        return res;
    }
    dlclose(h);
    @synchronized (self.class) { cache[eid] = @{@"sig": sig, @"res": @""}; }
    return nil;
}

+ (NSString *)loadedPathForExtension:(NSString *)eid {
    @synchronized (self.class) { return gResolvedPaths[eid]; }
}

+ (void)purgeCacheForExtension:(NSString *)eid {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *name = [NSString stringWithFormat:@"%@.dylib", eid];
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"mtext_%@.dylib", eid]];
    NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject
                        stringByAppendingPathComponent:@"MTExtensions"];
    NSString *bundleCopy = [[[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"MTExtensions"] stringByAppendingPathComponent:name];
    for (NSString *p in @[tmp,
                          [caches stringByAppendingPathComponent:name],
                          bundleCopy,
                          [@"/var/jb/var/mobile/Library/Caches/MTExtensions" stringByAppendingPathComponent:name]]) {
        [fm removeItemAtPath:p error:NULL];
    }
    @synchronized (self.class) { [gInstances removeObjectForKey:eid]; [gResolvedPaths removeObjectForKey:eid]; }
}

+ (BOOL)removeExtension:(NSString *)eid error:(NSError **)err {
    NSString *dir = [[self rootPath] stringByAppendingPathComponent:eid];
    BOOL ok = [NSFileManager.defaultManager removeItemAtPath:dir error:err];
    [self invalidate];
    return ok;
}

@end

#pragma mark - zip 目录列举 / 单条目读取

static NSUInteger MTZipEOCDInRange(NSData *zip, NSUInteger from, NSUInteger to) {
    const uint8_t *b = zip.bytes;
    NSUInteger len = zip.length;
    if (to > len) to = len;
    if (from >= to || to < 22) return NSNotFound;
    for (NSUInteger i = to - 22; ; i--) {
        if (i + 4 <= len && b[i] == 0x50 && b[i+1] == 0x4b && b[i+2] == 0x05 && b[i+3] == 0x06) return i;
        if (i == from) break;
    }
    return NSNotFound;
}

static NSUInteger MTZipEOCD(NSData *zip) {
    NSUInteger len = zip.length;
    if (len < 22) return NSNotFound;
    // 先只扫尾部 66000 字节（EOCD 注释最长 65535），避免大包全文件倒扫
    NSUInteger from = len > 66000 ? len - 66000 : 0;
    NSUInteger hit = MTZipEOCDInRange(zip, from, len);
    if (hit != NSNotFound) return hit;
    return MTZipEOCDInRange(zip, 0, len);
}

// ZIP64：entries/cdSize/cdOffset 溢出 32 位时，从 Zip64 EOCD Locator 取真实值
static BOOL MTZip64CentralDir(NSData *zip, NSUInteger eocd, uint64_t *cdOff, uint64_t *cdSize, uint64_t *entries) {
    const uint8_t *b = zip.bytes;
    NSUInteger len = zip.length;
    if (eocd < 20) return NO;
    NSUInteger lim = eocd > 264 ? eocd - 264 : 0;
    NSUInteger loc = NSNotFound;
    for (NSUInteger i = eocd - 20; ; i--) {
        if (i + 4 <= len && b[i] == 0x50 && b[i+1] == 0x4b && b[i+2] == 0x06 && b[i+3] == 0x07) { loc = i; break; }
        if (i == lim) break;
    }
    if (loc == NSNotFound || loc + 20 > len) return NO;
    uint64_t off64 = 0;
    memcpy(&off64, b + loc + 8, 8);
    if (off64 == 0 || off64 + 56 > len) return NO;
    if (!(b[off64] == 0x50 && b[off64+1] == 0x4b && b[off64+2] == 0x06 && b[off64+3] == 0x06)) return NO;
    uint64_t ent = 0, cds = 0, cdo = 0;
    memcpy(&ent, b + off64 + 32, 8);
    memcpy(&cds, b + off64 + 40, 8);
    memcpy(&cdo, b + off64 + 48, 8);
    *entries = ent; *cdSize = cds; *cdOff = cdo;
    return YES;
}

static NSString *MTZipDecodeName(const uint8_t *p, uint16_t len) {
    NSString *n = [[NSString alloc] initWithBytes:p length:len encoding:NSUTF8StringEncoding];
    if (n) return n;
    CFStringEncoding gb = CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000);
    n = [[NSString alloc] initWithBytes:p length:len encoding:gb];
    if (n) return n;
    return [[NSString alloc] initWithBytes:p length:len encoding:NSISOLatin1StringEncoding];
}

static NSDate *MTZipDOSDate(uint16_t dosDate, uint16_t dosTime) {
    if (!dosDate) return nil;
    NSDateComponents *c = [[NSDateComponents alloc] init];
    c.year = ((dosDate >> 9) & 0x7F) + 1980;
    c.month = (dosDate >> 5) & 0x0F;
    c.day = dosDate & 0x1F;
    c.hour = (dosTime >> 11) & 0x1F;
    c.minute = (dosTime >> 5) & 0x3F;
    c.second = (dosTime & 0x1F) * 2;
    NSCalendar *cal = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    return [cal dateFromComponents:c];
}

// 无中央目录（或解析失败）时顺序扫 local header 兜底
static NSArray<NSDictionary *> *MTZipScanLocalHeaders(NSData *zip) {
    NSMutableArray *out = [NSMutableArray array];
    const uint8_t *b = zip.bytes;
    NSUInteger len = zip.length, p = 0;
    while (p + 30 <= len) {
        while (p + 4 <= len && !(b[p] == 0x50 && b[p+1] == 0x4b && b[p+2] == 0x03 && b[p+3] == 0x04)) p++;
        if (p + 30 > len) break;
        uint16_t flags = rd16(b + p + 6);
        uint32_t csize = rd32(b + p + 18), usize = rd32(b + p + 22);
        uint16_t nl = rd16(b + p + 26), el = rd16(b + p + 28);
        NSString *name = MTZipDecodeName(b + p + 30, nl);
        NSUInteger dataOff = p + 30 + nl + el;
        NSDate *mt = MTZipDOSDate(rd16(b + p + 12), rd16(b + p + 10));
        if (name.length && dataOff <= len) {
            NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:@{@"name": name, @"size": @(usize), @"isDir": @([name hasSuffix:@"/"])}];
            if (mt) d[@"mtime"] = mt;
            [out addObject:d];
        }
        if (csize == 0 && (flags & 8)) {
            NSUInteger q = dataOff;
            while (q + 4 <= len && !(b[q] == 0x50 && b[q+1] == 0x4b &&
                                     (b[q+2] == 0x03 || b[q+2] == 0x01 ||
                                      (b[q+2] == 0x07 && b[q+3] == 0x08)))) q++;
            if (q + 4 > len) break;
            p = q;
        } else {
            p = dataOff + csize;
        }
    }
    return out;
}

BOOL MTZipIsArchiveFile(NSString *path) {
    // IPA 是 zip 容器，但语义上是安装包，交给 IPA 详情处理，不当压缩包打开
    if ([[path.pathExtension lowercaseString] isEqualToString:@"ipa"]) return NO;
    NSData *head = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];
    if (!head.length) head = [NSData dataWithContentsOfFile:path];
    if (head.length < 4) return NO;
    const uint8_t *b = head.bytes;
    NSUInteger n = MIN(head.length, 2048);   // 兼容自解压(exe)头，前 2KB 内找 local header
    for (NSUInteger i = 0; i + 4 <= n; i++) {
        if (b[i] == 0x50 && b[i+1] == 0x4b && b[i+2] == 0x03 && b[i+3] == 0x04) return YES;
        if (b[i] == 0x50 && b[i+1] == 0x4b && b[i+2] == 0x05 && b[i+3] == 0x06) return YES;
    }
    return NO;
}


NSData *MTZipReadEntryAt(NSString *zipPath, NSString *innerPath) {
    if (!zipPath.length || !innerPath.length) return nil;
    NSData *zip = [NSData dataWithContentsOfFile:zipPath options:NSDataReadingMappedIfSafe error:NULL];
    if (!zip) zip = [NSData dataWithContentsOfFile:zipPath];
    if (!zip.length) return nil;
    const uint8_t *b = zip.bytes;
    NSUInteger len = zip.length;
    NSUInteger eocd = MTZipEOCD(zip);
    if (eocd == NSNotFound) return nil;
    uint16_t entries = rd16(b + eocd + 10);
    uint32_t cdOff = rd32(b + eocd + 16);
    if (cdOff >= len) return nil;
    NSUInteger p = cdOff;
    for (uint16_t n = 0; n < entries; n++) {
        if (p + 46 > len || rd32(b + p) != 0x02014b50) break;
        uint16_t method = rd16(b + p + 10);
        uint32_t csize = rd32(b + p + 20), usize = rd32(b + p + 24);
        uint16_t nameLen = rd16(b + p + 28), extraLen = rd16(b + p + 30), cmtLen = rd16(b + p + 32);
        uint32_t lo = rd32(b + p + 42);
        NSString *name = MTZipDecodeName(b + p + 46, nameLen);
        p += 46 + nameLen + extraLen + cmtLen;
        if (!name.length) continue;
        if (![name isEqualToString:innerPath] && ![name isEqualToString:[innerPath stringByAppendingString:@"/"]]) continue;
        if (lo + 30 > len) continue;
        uint16_t lnLen = rd16(b + lo + 26), lExtra = rd16(b + lo + 28);
        NSUInteger dataOff = lo + 30 + lnLen + lExtra;
        if (dataOff + csize > len) continue;
        if (method == 0) return [zip subdataWithRange:NSMakeRange(dataOff, csize)];
        if (method != 8) return nil;
        NSMutableData *out = [NSMutableData dataWithLength:MAX(usize, 1)];
        z_stream zs; memset(&zs, 0, sizeof(zs));
        zs.next_in = (Bytef *)(b + dataOff); zs.avail_in = csize;
        zs.next_out = out.mutableBytes; zs.avail_out = (uInt)out.length;
        if (inflateInit2(&zs, -15) != Z_OK) return nil;
        int rc = inflate(&zs, Z_FINISH);
        inflateEnd(&zs);
        if (rc != Z_STREAM_END) return nil;
        out.length = zs.total_out;
        return out;
    }
    return nil;
}

NSArray<NSDictionary *> *MTZipListEntries(NSString *zipPath) {
    NSMutableArray *out = [NSMutableArray array];
    NSData *zip = [NSData dataWithContentsOfFile:zipPath options:NSDataReadingMappedIfSafe error:NULL];
    if (!zip) zip = [NSData dataWithContentsOfFile:zipPath];
    if (!zip.length) return out;
    const uint8_t *b = zip.bytes;
    NSUInteger len = zip.length;
    NSUInteger eocd = MTZipEOCD(zip);
    if (eocd == NSNotFound) return MTZipScanLocalHeaders(zip);
    uint64_t entries = rd16(b + eocd + 10);
    uint64_t cdSize = rd32(b + eocd + 12);
    uint64_t cdOff = rd32(b + eocd + 16);
    if (entries == 0xFFFF || cdSize == 0xFFFFFFFF || cdOff == 0xFFFFFFFF) {
        uint64_t e2 = entries, s2 = cdSize, o2 = cdOff;
        if (MTZip64CentralDir(zip, eocd, &o2, &s2, &e2)) { entries = e2; cdSize = s2; cdOff = o2; }
    }
    // 有些工具写的偏移带自解压头，用 "EOCD - 中央目录长度" 纠正
    if (cdOff >= len || (cdOff && rd32(b + (NSUInteger)cdOff) != 0x02014b50)) {
        if (cdSize && eocd >= cdSize) cdOff = (uint32_t)(eocd - cdSize);
    }
    if (cdOff >= len) return MTZipScanLocalHeaders(zip);
    NSUInteger p = (NSUInteger)cdOff;
    NSMutableSet *seen = [NSMutableSet set];
    for (uint64_t n = 0; n < entries && p + 46 <= len; n++) {
        if (rd32(b + p) != 0x02014b50) break;
        uint32_t usize = rd32(b + p + 24);
        uint16_t nameLen = rd16(b + p + 28), extraLen = rd16(b + p + 30), cmtLen = rd16(b + p + 32);
        if (p + 46 + nameLen + extraLen + cmtLen > len) break;
        NSString *name = MTZipDecodeName(b + p + 46, nameLen);
        p += 46 + nameLen + extraLen + cmtLen;
        if (!name.length || [name containsString:@"../"]) continue;
        NSDate *mt = MTZipDOSDate(rd16(b + p + 12), rd16(b + p + 10));
        if (![seen containsObject:name]) {
            [seen addObject:name];
            NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:@{@"name": name, @"size": @(usize), @"isDir": @([name hasSuffix:@"/"])}];
            if (mt) d[@"mtime"] = mt;
            [out addObject:d];
        }
    }
    if (out.count < entries) {   // 中央目录缺条目 → 用 local header 补齐
        NSMutableSet *names = [NSMutableSet set];
        for (NSDictionary *e in out) [names addObject:e[@"name"]];
        for (NSDictionary *e in MTZipScanLocalHeaders(zip)) {
            if (![names containsObject:e[@"name"]]) { [names addObject:e[@"name"]]; [out addObject:e]; }
        }
    }
    if (!out.count) return MTZipScanLocalHeaders(zip);   // 中央目录坏了 → 退回扫 local header
    return out;
}

NSData *MTZipReadEntryNamed(NSString *zipPath, NSString *nameSuffix) {
    NSData *zip = [NSData dataWithContentsOfFile:zipPath options:NSDataReadingMappedIfSafe error:NULL];
    if (!zip || !nameSuffix.length) return nil;
    const uint8_t *b = zip.bytes;
    NSUInteger len = zip.length;
    NSUInteger eocd = MTZipEOCD(zip);
    if (eocd == NSNotFound) return nil;
    uint16_t entries = rd16(b + eocd + 10);
    uint32_t cdOff = rd32(b + eocd + 16);
    if (cdOff >= len) return nil;
    NSUInteger p = cdOff;
    for (uint16_t n = 0; n < entries; n++) {
        if (p + 46 > len || rd32(b + p) != 0x02014b50) break;
        uint16_t method = rd16(b + p + 10);
        uint32_t csize = rd32(b + p + 20), usize = rd32(b + p + 24);
        uint16_t nameLen = rd16(b + p + 28), extraLen = rd16(b + p + 30), cmtLen = rd16(b + p + 32);
        uint32_t lo = rd32(b + p + 42);
        NSString *name = [[NSString alloc] initWithBytes:b + p + 46 length:nameLen encoding:NSUTF8StringEncoding];
        if (!name) name = [[NSString alloc] initWithBytes:b + p + 46 length:nameLen encoding:NSISOLatin1StringEncoding];
        p += 46 + nameLen + extraLen + cmtLen;
        if (!name.length) continue;
        if (![name hasSuffix:nameSuffix] && ![name isEqualToString:nameSuffix]) continue;
        if (lo + 30 > len) continue;
        uint16_t lnLen = rd16(b + lo + 26), lExtra = rd16(b + lo + 28);
        NSUInteger dataOff = lo + 30 + lnLen + lExtra;
        if (dataOff + csize > len) continue;
        if (method == 0) return [zip subdataWithRange:NSMakeRange(dataOff, csize)];
        if (method != 8) return nil;
        NSMutableData *out = [NSMutableData dataWithLength:MAX(usize, 1)];
        z_stream zs; memset(&zs, 0, sizeof(zs));
        zs.next_in = (Bytef *)(b + dataOff); zs.avail_in = csize;
        zs.next_out = out.mutableBytes; zs.avail_out = (uInt)out.length;
        if (inflateInit2(&zs, -15) != Z_OK) return nil;
        int rc = inflate(&zs, Z_FINISH);
        inflateEnd(&zs);
        if (rc != Z_STREAM_END) return nil;
        out.length = zs.total_out;
        return out;
    }
    return nil;
}

#pragma mark - 宿主进程 API（v2.1）

#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <signal.h>
#import <spawn.h>

extern char **environ;

// ObjC 壳：主可执行文件的符号默认不导出，但 ObjC 类名一定会注册进运行时。
// 扩展用 NSClassFromString(@"MTExtProcessHost") 拿到它再 objc_msgSend 调用即可。
@interface MTExtProcessHost : NSObject
@end

@implementation MTExtProcessHost
+ (BOOL)available { return MTExtProcessAvailable(); }
+ (NSString *)unavailableReason { return MTExtProcessUnavailableReason(); }
+ (NSInteger)spawn:(NSString *)exe args:(NSArray *)args env:(NSDictionary *)env cwd:(NSString *)cwd out:(id)out exit:(id)exitBlk {
    return (NSInteger)MTExtProcessSpawn(exe, args, env, cwd, (MTExtProcessOutputBlock)out, (MTExtProcessExitBlock)exitBlk);
}
+ (void)kill:(NSInteger)pid { MTExtProcessKill((pid_t)pid); }
+ (BOOL)portOpen:(NSInteger)port { return MTExtPortIsListening(port); }
@end

static NSInteger gMTProcProbe = -1;      // -1 未探测, 0 不可用, 1 可用
static NSString *gMTProcProbeWhy = nil;

// 探测策略（原来用 /usr/bin/true 探测，iOS 上根本没这个文件，ENOENT 被误判成“沙盒”，
// rootless 装了 deb 也会报“只能用 deb 版”）：
// 1) 先拿自己的可执行文件加 -MTExtSpawnProbe 参数试跑（main.m 里见到这个参数立即 return 0），
//    沙盒里 exec 自己的二进制会被拒（EPERM/EACCES），非沙盒能正常跑起来。
// 2) 自探测失败再试几个真实存在的 shell / true 路径。只有 EPERM/EACCES 才算沙盒，
//    ENOENT 之类一律不算。
static BOOL MTProbeTrySpawn(NSString *path, NSArray<NSString *> *args, NSString **why) {
    if (!path.length) return NO;
    if (access(path.fileSystemRepresentation, X_OK) != 0) return NO;
    NSMutableArray *a = [NSMutableArray arrayWithObject:path];
    [a addObjectsFromArray:args ?: @[]];
    NSUInteger n = a.count;
    char **argv = calloc(n + 1, sizeof(char *));
    for (NSUInteger i = 0; i < n; i++) argv[i] = (char *)[(NSString *)a[i] UTF8String];
    argv[n] = NULL;
    pid_t pid = 0;
    int rc = posix_spawn(&pid, path.fileSystemRepresentation, NULL, NULL, argv, environ);
    free(argv);
    if (rc == 0) {
        int st = 0;
        waitpid(pid, &st, 0);
        return YES;
    }
    if (why) {
        if (rc == EPERM || rc == EACCES)
            *why = [NSString stringWithFormat:@"沙盒拒绝创建子进程（errno %d），这是 IPA/TrollStore 版的限制", rc];
        else
            *why = [NSString stringWithFormat:@"无法启动 %@（errno %d）", path.lastPathComponent, rc];
    }
    return NO;
}

BOOL MTExtProcessAvailable(void) {
    if (gMTProcProbe >= 0) return gMTProcProbe == 1;

    NSString *why = nil;
    // 1) 自探测：跑自己一次，正常退出即说明 exec 可用
    NSString *selfExe = NSBundle.mainBundle.executablePath;
    if (MTProbeTrySpawn(selfExe, @[@"-MTExtSpawnProbe"], &why)) {
        gMTProcProbe = 1; gMTProcProbeWhy = nil;
        return YES;
    }
    // 2) 自探测失败：再找设备上真实存在的 shell / true
    NSArray *cands = @[@"/var/jb/usr/bin/sh", @"/var/jb/bin/sh", @"/bin/sh", @"/usr/bin/sh", @"/usr/bin/true"];
    for (NSString *p in cands) {
        NSString *w2 = nil;
        NSArray *args = [p hasSuffix:@"/sh"] ? @[@"-c", @"exit 0"] : @[];
        if (MTProbeTrySpawn(p, args, &w2)) {
            gMTProcProbe = 1; gMTProcProbeWhy = nil;
            return YES;
        }
        if (!why) why = w2;
    }
    gMTProcProbe = 0;
    gMTProcProbeWhy = why ?: @"无法创建子进程";
    return NO;
}

NSString *MTExtProcessUnavailableReason(void) {
    MTExtProcessAvailable();
    return gMTProcProbeWhy ?: @"";
}

pid_t MTExtProcessSpawn(NSString *exe, NSArray<NSString *> *args, NSDictionary<NSString *, NSString *> *envAdditions, NSString *cwd, MTExtProcessOutputBlock onOutput, MTExtProcessExitBlock onExit) {
    if (!exe.length) return -1;
    if (!MTExtProcessAvailable()) {
        if (onOutput) onOutput(@"宿主处于沙盒环境，无法创建子进程（需要 deb 版）", YES);
        if (onExit) onExit(-2);
        return -1;
    }
    int pfd[2];
    if (pipe(pfd) != 0) return -1;

    // 组装 argv
    NSMutableArray *full = [NSMutableArray arrayWithObject:exe];
    for (NSString *a in args) [full addObject:a ?: @""];
    NSUInteger n = full.count;
    char **cargv = calloc(n + 1, sizeof(char *));
    for (NSUInteger i = 0; i < n; i++) cargv[i] = (char *)[(NSString *)full[i] UTF8String];
    cargv[n] = NULL;

    // 环境：继承宿主，再叠加扩展给的；cwd 通过 PWD 提示（posix_spawn 无法 chdir）
    NSMutableDictionary *envd = [NSMutableDictionary dictionary];
    for (char **e = environ; e && *e; e++) {
        NSString *kv = [NSString stringWithUTF8String:*e];
        NSRange r = [kv rangeOfString:@"="];
        if (r.location != NSNotFound) envd[[kv substringToIndex:r.location]] = [kv substringFromIndex:r.location + 1];
    }
    if (cwd.length) envd[@"PWD"] = cwd;
    for (NSString *k in envAdditions) envd[k] = envAdditions[k];
    NSMutableArray *envArr = [NSMutableArray array];
    for (NSString *k in envd) [envArr addObject:[NSString stringWithFormat:@"%@=%@", k, envd[k]]];
    char **cenv = calloc(envArr.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < envArr.count; i++) cenv[i] = (char *)[(NSString *)envArr[i] UTF8String];
    cenv[envArr.count] = NULL;

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, pfd[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&fa, pfd[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&fa, pfd[0]);
    posix_spawn_file_actions_addclose(&fa, pfd[1]);

    pid_t pid = 0;
    int rc = posix_spawn(&pid, exe.fileSystemRepresentation, &fa, NULL, cargv, cenv);
    posix_spawn_file_actions_destroy(&fa);
    free(cargv); free(cenv);
    close(pfd[1]);
    if (rc != 0) {
        close(pfd[0]);
        if (onOutput) onOutput([NSString stringWithFormat:@"启动失败：%@ (errno %d)", exe, rc], YES);
        if (onExit) onExit(-1);
        return -1;
    }

    // 流式读 stdout/stderr，并等退出
    int rfd = pfd[0];
    pid_t cpid = pid;
    dispatch_queue_t q = dispatch_queue_create("mt.extproc", DISPATCH_QUEUE_SERIAL);
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)rfd, 0, q);
    dispatch_source_set_event_handler(src, ^{
        uint8_t buf[4096];
        ssize_t r = read(rfd, buf, sizeof(buf));
        if (r > 0) {
            NSString *s = [[NSString alloc] initWithBytes:buf length:(NSUInteger)r encoding:NSUTF8StringEncoding];
            if (!s) s = [[NSString alloc] initWithBytes:buf length:(NSUInteger)r encoding:NSISOLatin1StringEncoding];
            if (s.length && onOutput) onOutput(s, NO);
        } else {
            dispatch_source_cancel(src);
        }
    });
    dispatch_source_set_cancel_handler(src, ^{
        close(rfd);
        int st = 0;
        waitpid(cpid, &st, 0);
        int code = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
        if (onExit) onExit(code);
    });
    dispatch_resume(src);
    return pid;
}

void MTExtProcessKill(pid_t pid) {
    if (pid <= 0) return;
    kill(pid, SIGTERM);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_global_queue(0, 0), ^{
        kill(pid, SIGKILL);
    });
}

BOOL MTExtPortIsListening(NSInteger port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    struct sockaddr_in a; memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons((uint16_t)port);
    a.sin_addr.s_addr = inet_addr("127.0.0.1");
    BOOL ok = (connect(fd, (struct sockaddr *)&a, sizeof(a)) == 0);
    close(fd);
    return ok;
}

#pragma mark - 扩展权限：联网 / 终端（用户手动同意，不是 manifest 里写一句）

static NSString *MTConsentKey(NSString *eid, NSString *cap) {
    return [NSString stringWithFormat:@"mt_ext_consent.%@.%@", eid.lowercaseString, cap.lowercaseString];
}

BOOL MTExtConsentGranted(NSString *eid, NSString *cap) {
    if (!eid.length || !cap.length) return NO;
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:MTConsentKey(eid, cap)];
    return v ? [v boolValue] : NO;
}

static UIViewController *MTTopViewController(void) {
    UIWindow *win = nil;
    for (UIWindow *w in UIApplication.sharedApplication.windows) if (w.isKeyWindow) { win = w; break; }
    UIViewController *vc = win.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static NSString *MTCapabilityTitle(NSString *cap) {
    if ([cap isEqualToString:@"network"]) return @"网络访问";
    if ([cap isEqualToString:@"terminal"]) return @"运行终端命令";
    return cap;
}

void MTExtRequestConsent(NSString *eid, NSString *cap, NSString *reason, void (^callback)(BOOL)) {
    if (!eid.length || !cap.length) { if (callback) callback(NO); return; }
    if (MTExtConsentGranted(eid, cap)) { if (callback) dispatch_async(dispatch_get_main_queue(), ^{ callback(YES); }); return; }
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *title = [NSString stringWithFormat:@"“%@”请求%@权限", eid];
        NSString *msg = reason.length ? reason : [NSString stringWithFormat:@"这个扩展要使用%@。拒绝后相关功能不可用，直到你重新允许。", MTCapabilityTitle(cap)];
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"拒绝" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
            [[NSUserDefaults standardUserDefaults] setBool:NO forKey:MTConsentKey(eid, cap)];
            if (callback) callback(NO);
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"允许" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [[NSUserDefaults standardUserDefaults] setBool:YES forKey:MTConsentKey(eid, cap)];
            if (callback) callback(YES);
        }]];
        UIViewController *top = MTTopViewController();
        if (!top) { if (callback) callback(NO); return; }
        [top presentViewController:ac animated:YES completion:nil];
    });
}

static NSString *MTShellPath(void) {
    NSArray *c = @[@"/var/jb/usr/bin/bash", @"/var/jb/bin/sh", @"/var/jb/usr/bin/sh",
                   @"/bin/sh", @"/usr/bin/sh", @"/var/jb/usr/bin/zsh"];
    for (NSString *p in c) if ([[NSFileManager defaultManager] isExecutableFileAtPath:p]) return p;
    return nil;
}

pid_t MTExtShellRun(NSString *eid, NSString *command, NSString *cwd,
                    MTExtProcessOutputBlock onOutput, MTExtProcessExitBlock onExit) {
    if (!command.length) return -1;
    if (!MTExtConsentGranted(eid, @"terminal")) {
        if (onOutput) onOutput(@"扩展没有终端权限：先调用 MTExtRequestConsent(extID, @\"terminal\", …) 让用户同意。", YES);
        if (onExit) onExit(-3);
        return -1;
    }
    NSString *shell = MTShellPath();
    if (!shell.length) {
        if (onOutput) onOutput(@"设备上找不到 shell（/var/jb/usr/bin/bash 等）", YES);
        if (onExit) onExit(-4);
        return -1;
    }
    return MTExtProcessSpawn(shell, @[@"-lc", command], nil, cwd ?: @"/var/mobile", onOutput, onExit);
}

void MTExtNetRequest(NSString *eid, NSString *urlString, NSDictionary<NSString *, NSString *> *headers,
                     void (^done)(NSData *, NSInteger, NSError *)) {
    NSURL *url = [NSURL URLWithString:urlString ?: @""];
    if (!url || !url.scheme.length) {
        if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(nil, 0, [NSError errorWithDomain:@"MTExtNet" code:1 userInfo:@{NSLocalizedDescriptionKey: @"URL 不合法"}]); });
        return;
    }
    void (^fire)(void) = ^{
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        req.timeoutInterval = 20;
        for (NSString *k in headers) [req setValue:headers[k] forHTTPHeaderField:k];
        NSURLSessionDataTask *t = [[NSURLSession sharedSession] dataTaskWithRequest:req
            completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
                NSInteger code = [(NSHTTPURLResponse *)r statusCode];
                dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(d, code, e); });
            }];
        [t resume];
    };
    if (MTExtConsentGranted(eid, @"network")) { fire(); return; }
    MTExtRequestConsent(eid, @"network", @"扩展需要联网下载或上传数据。", ^(BOOL granted) {
        if (granted) fire();
        else if (done) done(nil, 0, [NSError errorWithDomain:@"MTExtNet" code:2 userInfo:@{NSLocalizedDescriptionKey: @"用户拒绝了网络访问"}]);
    });
}

