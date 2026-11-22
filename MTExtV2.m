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
    if (![zipPath.pathExtension.lowercaseString isEqualToString:@"zip"]) return NO;
    NSData *d = [NSData dataWithContentsOfFile:zipPath options:NSDataReadingMappedIfSafe error:NULL];
    return d && [d rangeOfData:[@"manifest.json" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0, MIN(d.length, 200000))].location != NSNotFound;
}

+ (BOOL)installZipAtPath:(NSString *)zipPath error:(NSError **)err {
    [self ensureDir];
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"_mt_ext2"];
    [NSFileManager.defaultManager removeItemAtPath:tmp error:NULL];
    NSError *e = nil;
    if (![self extractZip:zipPath toDirectory:tmp error:&e]) {
        if (err) *err = e;
        return NO;
    }
    // 兼容“整个扩展被套在一个顶层文件夹里”的 zip
    NSString *mp = [tmp stringByAppendingPathComponent:@"manifest.json"];
    if (![NSFileManager.defaultManager fileExistsAtPath:mp]) {
        NSArray *subs = [NSFileManager.defaultManager contentsOfDirectoryAtPath:tmp error:NULL];
        NSMutableArray *dirs = [NSMutableArray array];
        for (NSString *n in subs) {
            BOOL isDir = NO;
            [NSFileManager.defaultManager fileExistsAtPath:[tmp stringByAppendingPathComponent:n] isDirectory:&isDir];
            if (isDir) [dirs addObject:n];
        }
        if (dirs.count == 1) {
            NSString *cand = [tmp stringByAppendingPathComponent:dirs.firstObject];
            if ([NSFileManager.defaultManager fileExistsAtPath:[cand stringByAppendingPathComponent:@"manifest.json"]]) {
                tmp = cand;
                mp = [tmp stringByAppendingPathComponent:@"manifest.json"];
            }
        }
    }
    NSData *md = [NSData dataWithContentsOfFile:mp];
    NSDictionary *m = md ? [NSJSONSerialization JSONObjectWithData:md options:0 error:NULL] : nil;
    if (![m isKindOfClass:[NSDictionary class]]) {
        if (err) *err = [NSError errorWithDomain:@"MTExtV2" code:3 userInfo:@{NSLocalizedDescriptionKey: @"zip 内缺少 manifest.json 或 JSON 格式错误"}];
        return NO;
    }
    if (![[m[@"framework"] description] hasPrefix:@"v2"]) {
        if (err) *err = [NSError errorWithDomain:@"MTExtV2" code:4 userInfo:@{NSLocalizedDescriptionKey: @"扩展框架版本不是 v2.0.0，属于旧版扩展，请使用旧安装方式"}];
        return NO;
    }
    NSString *dylib = m[@"dylib"] ?: @"";
    if (!dylib.length || ![NSFileManager.defaultManager fileExistsAtPath:[tmp stringByAppendingPathComponent:dylib]]) {
        if (err) *err = [NSError errorWithDomain:@"MTExtV2" code:5 userInfo:@{NSLocalizedDescriptionKey: @"manifest 指定的 dylib 不存在"}];
        return NO;
    }
    NSString *eid = m[@"id"] ?: m[@"name"];
    if (!eid.length) {
        if (err) *err = [NSError errorWithDomain:@"MTExtV2" code:6 userInfo:@{NSLocalizedDescriptionKey: @"manifest 缺少 id"}];
        return NO;
    }
    NSString *target = [[self rootPath] stringByAppendingPathComponent:eid];
    [NSFileManager.defaultManager removeItemAtPath:target error:NULL];
    NSError *mvErr = nil;
    if (![NSFileManager.defaultManager moveItemAtPath:tmp toPath:target error:&mvErr]) {
        if (err) *err = mvErr;
        return NO;
    }
    NSString *dylibPath = [target stringByAppendingPathComponent:dylib];
    chmod(dylibPath.UTF8String, 0755);
    MTSignDylibIfPossible(dylibPath);
    chmod(dylibPath.UTF8String, 0755);
    [self purgeCacheForExtension:eid];
    [self invalidate];
    return YES;
}

+ (NSString *)diagnoseExtension:(NSString *)eid {
    NSDictionary *e = nil;
    for (NSDictionary *x in [self installed]) if ([x[@"id"] isEqualToString:eid]) { e = x; break; }
    if (!e) return @"扩展未安装（manifest.json 缺失或不是 v2）";
    if (![e[@"entryExists"] boolValue]) return [NSString stringWithFormat:@"dylib 不存在：%@", e[@"dylibPath"]];
    NSString *path = e[@"dylibPath"];
    NSDictionary *attr = [NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL];
    NSString *arch = [NSString stringWithFormat:@"dylib 大小 %@", attr[NSFileSize]];
    if (![[NSFileManager defaultManager] isReadableFileAtPath:path]) return @"dylib 不可读（权限问题）";
    NSString *usedPath = nil, *detail = nil;
    void *h = MTDlopenWithFallbacks(path, eid, &usedPath, &detail);
    if (!h) {
        NSString *why = @"";
        if ([detail containsString:@"sandbox blocked mmap"]) {
            why = @"\n→ 当前这个 App 是沙盒版（IPA），系统禁止从数据目录映射可执行代码，扩展 dylib 无法进程内加载。换用 deb 版（rootless/roothide，非沙盒）即可，或等我把扩展改成独立进程模式。";
        }
        return [NSString stringWithFormat:@"dlopen 全部失败（%@）%@\n%@", arch, why, detail ?: @""];
    }
    @synchronized (MTExtV2Store.class) {
        if (!gResolvedPaths) gResolvedPaths = [NSMutableDictionary dictionary];
        gResolvedPaths[eid] = usedPath ?: path;
    }
    void *sym = dlsym(h, "MTCreateExtension");
    if (!sym) { dlclose(h); return [NSString stringWithFormat:@"dylib 里没有 MTCreateExtension 导出（%@）", arch]; }
    dlclose(h);
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
