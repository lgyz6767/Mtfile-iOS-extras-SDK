#import "MTDemoAPI.h"
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <string.h>
#include <stdlib.h>
#include <dlfcn.h>

#pragma mark - 宿主桥（全部走 objc runtime，不依赖宿主 C 符号）

static id MTHostClass(NSString *name) { return NSClassFromString(name); }

static UIColor *MTThemeColor(NSString *sel, UIColor *fallback) {
    id cls = MTHostClass(@"MTTheme");
    SEL s = NSSelectorFromString(sel);
    if (cls && [cls respondsToSelector:s]) {
        id v = ((id (*)(id, SEL))objc_msgSend)(cls, s);
        if ([v isKindOfClass:[UIColor class]]) return v;
    }
    return fallback;
}

static UIColor *MTBg(void)     { return MTThemeColor(@"bg",        [UIColor colorWithWhite:0.09 alpha:1]); }
static UIColor *MTPanel(void)  { return MTThemeColor(@"panel",     [UIColor colorWithWhite:0.155 alpha:1]); }
static UIColor *MTCell(void)   { return MTThemeColor(@"cell",      [UIColor colorWithWhite:0.15 alpha:1]); }
static UIColor *MTText(void)   { return MTThemeColor(@"text",      [UIColor whiteColor]); }
static UIColor *MTTextDim(void){ return MTThemeColor(@"textDim",   [UIColor colorWithWhite:0.62 alpha:1]); }
static UIColor *MTAccent(void) { return MTThemeColor(@"accent",    [UIColor colorWithRed:0.24 green:0.51 blue:0.96 alpha:1]); }

static void MTRipple(UIButton *b, NSInteger style) {
    id cls = MTHostClass(@"MTMaterialRipple");
    SEL s = NSSelectorFromString(@"enableOnButton:style:");
    if (cls && [cls respondsToSelector:s])
        ((void (*)(id, SEL, id, NSInteger))objc_msgSend)(cls, s, b, style);
}

static void MTHostAlert(NSString *title, NSString *message) {
    id cls = MTHostClass(@"MTAlertCenter");
    SEL s = NSSelectorFromString(@"showWithTitle:message:");
    if (cls && [cls respondsToSelector:s]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(cls, s, title, message);
        return;
    }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:message
                                                               preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    UIWindow *w = UIApplication.sharedApplication.keyWindow;
    [w.rootViewController presentViewController:ac animated:YES completion:nil];
}

static void MTHostHUD(NSString *title) {
    id cls = MTHostClass(@"MTProgressHUD");
    SEL shared = NSSelectorFromString(@"shared");
    if (!cls || ![cls respondsToSelector:shared]) return;
    id hud = ((id (*)(id, SEL))objc_msgSend)(cls, shared);
    SEL show = NSSelectorFromString(@"showWithTitle:");
    if ([hud respondsToSelector:show]) ((void (*)(id, SEL, id))objc_msgSend)(hud, show, title);
    SEL hide = NSSelectorFromString(@"hide");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([hud respondsToSelector:hide]) ((void (*)(id, SEL))objc_msgSend)(hud, hide);
    });
}

static NSString *MTFmtSize(unsigned long long b) {
    if (b >= 1073741824ULL) return [NSString stringWithFormat:@"%.2fG", b / 1073741824.0];
    if (b >= 1048576ULL) return [NSString stringWithFormat:@"%.2fM", b / 1048576.0];
    if (b >= 1024ULL) return [NSString stringWithFormat:@"%.1fK", b / 1024.0];
    return [NSString stringWithFormat:@"%lluB", b];
}

#pragma mark - 自绘小工具

static UILabel *MTLabel(CGRect r, NSString *text, CGFloat size, UIColor *color, UIFontWeight weight) {
    UILabel *l = [[UILabel alloc] initWithFrame:r];
    l.text = text;
    l.font = [UIFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    return l;
}

static UIView *MTCard(CGRect r) {
    UIView *v = [[UIView alloc] initWithFrame:r];
    v.backgroundColor = MTPanel();
    v.layer.cornerRadius = 12;
    v.clipsToBounds = YES;
    return v;
}

#pragma mark - 文件浏览器

@interface MTDemoFilesVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) NSArray<NSString *> *names;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UILabel *crumb;
@end

@implementation MTDemoFilesVC

- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (self) _path = [path copy];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.edgesForExtendedLayout = UIRectEdgeNone;
    self.title = self.path.lastPathComponent.length ? self.path.lastPathComponent : @"文件";
    self.view.backgroundColor = MTBg();

    self.crumb = MTLabel(CGRectMake(16, 8, self.view.bounds.size.width - 32, 20), self.path, 11, MTTextDim(), UIFontWeightRegular);
    self.crumb.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.view addSubview:self.crumb];

    self.table = [[UITableView alloc] initWithFrame:CGRectMake(0, 32, self.view.bounds.size.width, self.view.bounds.size.height - 32) style:UITableViewStylePlain];
    self.table.dataSource = self; self.table.delegate = self;
    self.table.backgroundColor = MTBg();
    self.table.rowHeight = 58;
    self.table.separatorColor = [UIColor colorWithWhite:1 alpha:0.06];
    [self.view addSubview:self.table];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"上级" style:UIBarButtonItemStylePlain target:self action:@selector(up)];
    [self reload];
}

- (void)up {
    if (self.path.length < 2) return;
    NSString *p = [self.path stringByDeletingLastPathComponent];
    if (!p.length) p = @"/";
    MTDemoFilesVC *vc = [[MTDemoFilesVC alloc] initWithPath:p];
    if (self.navigationController) [self.navigationController pushViewController:vc animated:YES];
}

- (void)reload {
    NSError *err = nil;
    NSArray *all = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.path error:&err];
    self.names = [all sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) { return [a localizedStandardCompare:b]; }];
    self.crumb.text = err ? [NSString stringWithFormat:@"%@ （%@）", self.path, err.localizedDescription] : self.path;
    self.crumb.textColor = err ? [UIColor systemRedColor] : MTTextDim();
    [self.table reloadData];
}

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return self.names.count; }

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"f"];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"f"];
        c.textLabel.textColor = MTText();
        c.detailTextLabel.textColor = MTTextDim();
        c.backgroundColor = MTCell();
        UIView *sel = [[UIView alloc] init];
        sel.backgroundColor = [MTAccent() colorWithAlphaComponent:0.16];
        c.selectedBackgroundView = sel;
    }
    NSString *name = self.names[ip.row];
    NSString *full = [self.path stringByAppendingPathComponent:name];
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:full error:NULL];
    BOOL dir = [a[NSFileType] isEqualToString:NSFileTypeDirectory];
    c.imageView.image = [UIImage systemImageNamed:(dir ? @"folder.fill" : @"doc.text")
                                withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:18]];
    c.imageView.tintColor = dir ? MTAccent() : MTTextDim();
    c.textLabel.text = name;
    c.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@ · %@",
                              dir ? @"文件夹" : @"文件", MTFmtSize([a[NSFileSize] unsignedLongLongValue]),
                              a[NSFileModificationDate] ? [NSDateFormatter localizedStringFromDate:a[NSFileModificationDate]
                                                                                        dateStyle:NSDateFormatterShortStyle
                                                                                      timeStyle:NSDateFormatterShortStyle] : @"-"];
    c.accessoryType = dir ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    return c;
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    NSString *full = [self.path stringByAppendingPathComponent:self.names[ip.row]];
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:full error:NULL];
    if ([a[NSFileType] isEqualToString:NSFileTypeDirectory]) {
        [self.navigationController pushViewController:[[MTDemoFilesVC alloc] initWithPath:full] animated:YES];
        return;
    }
    MTHostAlert(full.lastPathComponent,
                [NSString stringWithFormat:@"路径：%@\n大小：%@\n权限：%@", full, MTFmtSize([a[NSFileSize] unsignedLongLongValue]), a[NSFilePosixPermissions]]);
}
@end

#pragma mark - zip 解析（自带实现）

static uint16_t z16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t z32(const uint8_t *p) { return (uint32_t)(p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24)); }

static NSArray<NSDictionary *> *MTZipEntries(NSData *d) {
    if (d.length < 22) return @[];
    const uint8_t *p = d.bytes; NSUInteger len = d.length;
    NSUInteger eocd = NSNotFound;
    for (NSUInteger i = len - 22; i + 4 <= len; i--) {
        if (p[i] == 'P' && p[i + 1] == 'K' && p[i + 2] == 5 && p[i + 3] == 6) { eocd = i; break; }
        if (i == 0) break;
    }
    if (eocd == NSNotFound) return @[];
    uint32_t cdOff = z32(p + eocd + 16);
    uint16_t count = z16(p + eocd + 10);
    NSMutableArray *out = [NSMutableArray array];
    NSUInteger o = cdOff;
    for (uint16_t k = 0; k < count && o + 46 <= len; k++) {
        if (!(p[o] == 'P' && p[o + 1] == 'K' && p[o + 2] == 1 && p[o + 3] == 2)) break;
        uint16_t nlen = z16(p + o + 28), elen = z16(p + o + 30), clen = z16(p + o + 32);
        NSString *name = [[NSString alloc] initWithBytes:p + o + 46 length:nlen encoding:NSUTF8StringEncoding] ?: @"?";
        [out addObject:@{@"name": name, @"size": @(z32(p + o + 24)), @"csize": @(z32(p + o + 20)), @"method": @(z16(p + o + 10))}];
        o += 46 + nlen + elen + clen;
        if (out.count > 5000) break;
    }
    return out;
}

@interface MTDemoZipVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray<NSString *> *zips;
@property (nonatomic, copy) NSString *openedZip;
@property (nonatomic, strong) NSArray<NSDictionary *> *entries;
@end

@implementation MTDemoZipVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.edgesForExtendedLayout = UIRectEdgeNone;
    self.title = @"压缩包探查";
    self.view.backgroundColor = MTBg();
    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.table.dataSource = self; self.table.delegate = self;
    self.table.backgroundColor = MTBg();
    self.table.rowHeight = 56;
    self.table.separatorColor = [UIColor colorWithWhite:1 alpha:0.06];
    [self.view addSubview:self.table];

    NSMutableArray *z = [NSMutableArray array];
    for (NSString *dir in @[@"/var/mobile/Documents", @"/var/mobile/Downloads", @"/var/mobile/Library/MTFile"]) {
        for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL]) {
            NSString *ext = f.pathExtension.lowercaseString;
            if ([@[@"zip", @"ipa", @"apk", @"xapk", @"mtz", @"jar", @"deb"] containsObject:ext])
                [z addObject:[dir stringByAppendingPathComponent:f]];
        }
        if (z.count > 200) break;
    }
    self.zips = z;
    self.entries = @[];
    if (!z.count) {
        self.title = @"压缩包探查（没找到包）";
    }
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"返回列表" style:UIBarButtonItemStylePlain target:self action:@selector(backToZips)];
}

- (void)backToZips { self.openedZip = nil; self.entries = @[]; self.title = @"压缩包探查"; [self.table reloadData]; }

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    return self.openedZip ? self.entries.count : self.zips.count;
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"z"];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"z"];
        c.textLabel.textColor = MTText();
        c.detailTextLabel.textColor = MTTextDim();
        c.backgroundColor = MTCell();
        UIView *sel = [[UIView alloc] init];
        sel.backgroundColor = [MTAccent() colorWithAlphaComponent:0.16];
        c.selectedBackgroundView = sel;
    }
    if (!self.openedZip) {
        NSString *p = self.zips[ip.row];
        NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:NULL];
        c.textLabel.text = p.lastPathComponent;
        c.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", MTFmtSize([a[NSFileSize] unsignedLongLongValue]), p.stringByDeletingLastPathComponent];
        c.imageView.image = [UIImage systemImageNamed:@"archivebox" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:18]];
        c.imageView.tintColor = MTAccent();
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        NSDictionary *e = self.entries[ip.row];
        c.textLabel.text = e[@"name"];
        c.detailTextLabel.text = [NSString stringWithFormat:@"%@ · 压缩方式 %@", MTFmtSize([e[@"size"] unsignedLongLongValue]), e[@"method"]];
        c.imageView.image = [UIImage systemImageNamed:@"doc" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:18]];
        c.imageView.tintColor = MTTextDim();
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return c;
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if (!self.openedZip) {
        NSString *p = self.zips[ip.row];
        NSData *d = [NSData dataWithContentsOfFile:p options:NSDataReadingMappedIfSafe error:NULL];
        self.openedZip = p;
        self.entries = MTZipEntries(d);
        self.title = [NSString stringWithFormat:@"%@ · %lu 项", p.lastPathComponent, (unsigned long)self.entries.count];
        [self.table reloadData];
        if (!self.entries.count) MTHostAlert(@"读不出条目", @"这不是标准 zip（或 zip64 / 加密）。");
        return;
    }
    NSDictionary *e = self.entries[ip.row];
    if ([[e[@"name"] description] hasSuffix:@"/"]) { MTHostAlert(@"目录", e[@"name"]); return; }
    if ([e[@"size"] unsignedLongLongValue] > 400 * 1024) {
        MTHostAlert(@"文件太大", @"演示页只在 400KB 以内做文本预览。");
        return;
    }
    NSData *all = [NSData dataWithContentsOfFile:self.openedZip options:NSDataReadingMappedIfSafe error:NULL];
    NSString *text = [self readEntry:e[@"name"] fromData:all];
    MTHostAlert(e[@"name"], text.length ? text : @"（二进制内容，演示页不渲染）");
}

// 只支持 store/deflate 的简易读取（deflate 交给 zlib，通过压缩流 API 不依赖第三方）
- (NSString *)readEntry:(NSString *)want fromData:(NSData *)all {
    const uint8_t *p = all.bytes; NSUInteger len = all.length;
    NSUInteger eocd = NSNotFound;
    for (NSUInteger i = len - 22; i + 4 <= len; i--) {
        if (p[i] == 'P' && p[i + 1] == 'K' && p[i + 2] == 5 && p[i + 3] == 6) { eocd = i; break; }
        if (i == 0) break;
    }
    if (eocd == NSNotFound) return nil;
    uint32_t cdOff = z32(p + eocd + 16);
    uint16_t count = z16(p + eocd + 10);
    NSUInteger o = cdOff;
    for (uint16_t k = 0; k < count && o + 46 <= len; k++) {
        if (!(p[o] == 'P' && p[o + 1] == 'K' && p[o + 2] == 1 && p[o + 3] == 2)) break;
        uint16_t nlen = z16(p + o + 28), elen = z16(p + o + 30), clen = z16(p + o + 32);
        NSString *name = [[NSString alloc] initWithBytes:p + o + 46 length:nlen encoding:NSUTF8StringEncoding] ?: @"";
        if ([name isEqualToString:want]) {
            uint16_t method = z16(p + o + 10);
            uint32_t csize = z32(p + o + 20), lo = z32(p + o + 42);
            if (lo + 30 > len) return nil;
            uint16_t ln = z16(p + lo + 26), le = z16(p + lo + 28);
            NSUInteger dataOff = lo + 30 + ln + le;
            if (dataOff + csize > len) return nil;
            if (method != 0) return @"（deflate 压缩条目：演示页只预览 store 条目）";
            NSData *raw = [all subdataWithRange:NSMakeRange(dataOff, csize)];
            return [[NSString alloc] initWithData:raw encoding:NSUTF8StringEncoding];
        }
        o += 46 + nlen + elen + clen;
    }
    return nil;
}
@end

#pragma mark - 主题与波纹实验室

@interface MTDemoLabVC : UIViewController
@property (nonatomic, strong) UIView *pulse;
@end

@implementation MTDemoLabVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.edgesForExtendedLayout = UIRectEdgeNone;
    self.title = @"主题与波纹";
    self.view.backgroundColor = MTBg();
    CGFloat w = self.view.bounds.size.width;

    UILabel *h1 = MTLabel(CGRectMake(16, 16, w - 32, 20), @"宿主 MTTheme 当前配色", 13, MTTextDim(), UIFontWeightMedium);
    [self.view addSubview:h1];

    NSArray *colors = @[@[@"bg", MTBg()], @[@"panel", MTPanel()], @[@"cell", MTCell()],
                        @[@"text", MTText()], @[@"textDim", MTTextDim()], @[@"accent", MTAccent()]];
    CGFloat cw = (w - 32 - 5 * 8) / 6.0;
    for (NSInteger i = 0; i < (NSInteger)colors.count; i++) {
        UIView *sw = [[UIView alloc] initWithFrame:CGRectMake(16 + i * (cw + 8), 44, cw, cw)];
        sw.backgroundColor = colors[i][1];
        sw.layer.cornerRadius = 8;
        sw.layer.borderWidth = 0.5;
        sw.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.15].CGColor;
        [self.view addSubview:sw];
        UILabel *n = MTLabel(CGRectMake(CGRectGetMinX(sw.frame), CGRectGetMaxY(sw.frame) + 4, cw, 14), colors[i][0], 10, MTTextDim(), UIFontWeightRegular);
        n.textAlignment = NSTextAlignmentCenter;
        [self.view addSubview:n];
    }

    UILabel *h2 = MTLabel(CGRectMake(16, 110, w - 32, 20), @"宿主 Material 波纹（style 2 方形 / 1 圆形）", 13, MTTextDim(), UIFontWeightMedium);
    [self.view addSubview:h2];

    UIButton *b1 = [UIButton buttonWithType:UIButtonTypeSystem];
    b1.frame = CGRectMake(16, 138, (w - 48) / 2, 46);
    [b1 setTitle:@"方形波纹" forState:UIControlStateNormal];
    [b1 setTitleColor:MTText() forState:UIControlStateNormal];
    b1.backgroundColor = MTPanel();
    b1.layer.cornerRadius = 0;
    b1.clipsToBounds = YES;
    [b1 addTarget:self action:@selector(squareTap) forControlEvents:UIControlEventTouchUpInside];
    MTRipple(b1, 2);
    [self.view addSubview:b1];

    UIButton *b2 = [UIButton buttonWithType:UIButtonTypeSystem];
    b2.frame = CGRectMake(32 + (w - 48) / 2, 138, (w - 48) / 2, 46);
    [b2 setTitle:@"圆形波纹" forState:UIControlStateNormal];
    [b2 setTitleColor:MTText() forState:UIControlStateNormal];
    b2.backgroundColor = MTPanel();
    b2.layer.cornerRadius = 23;
    b2.clipsToBounds = YES;
    [b2 addTarget:self action:@selector(roundTap) forControlEvents:UIControlEventTouchUpInside];
    MTRipple(b2, 1);
    [self.view addSubview:b2];

    UILabel *h3 = MTLabel(CGRectMake(16, 200, w - 32, 20), @"纯 CoreAnimation：脉冲光斑", 13, MTTextDim(), UIFontWeightMedium);
    [self.view addSubview:h3];

    self.pulse = [[UIView alloc] initWithFrame:CGRectMake(w / 2 - 30, 248, 60, 60)];
    self.pulse.backgroundColor = [MTAccent() colorWithAlphaComponent:0.85];
    self.pulse.layer.cornerRadius = 30;
    self.pulse.layer.shadowColor = MTAccent().CGColor;
    self.pulse.layer.shadowOpacity = 0.75;
    self.pulse.layer.shadowRadius = 18;
    self.pulse.layer.shadowOffset = CGSizeZero;
    [self.view addSubview:self.pulse];
    [self startPulse];

    UILabel *note = MTLabel(CGRectMake(16, 330, w - 32, 40),
                            @"这些控件全部在扩展 dylib 里创建，配色与波纹直接复用宿主实现，所以和主界面完全一致。",
                            12, MTTextDim(), UIFontWeightRegular);
    note.numberOfLines = 0;
    [self.view addSubview:note];
}

- (void)startPulse {
    [UIView animateWithDuration:1.1 delay:0 options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionRepeat | UIViewAnimationOptionAutoreverse animations:^{
        self.pulse.transform = CGAffineTransformMakeScale(1.35, 1.35);
        self.pulse.alpha = 0.55;
    } completion:nil];
}

- (void)squareTap { MTHostAlert(@"方形波纹", @"这个按钮的波纹是宿主 MTMaterialRipple 提供的 style 2（直角方形蒙版）。"); }
- (void)roundTap  { MTHostAlert(@"圆形波纹", @"这个按钮的波纹是宿主 MTMaterialRipple 提供的 style 1（圆形蒙版）。"); }
@end

#pragma mark - 动效页

@interface MTDemoAnimVC : UIViewController
@property (nonatomic, strong) NSMutableArray<UIView *> *bars;
@end

@implementation MTDemoAnimVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.edgesForExtendedLayout = UIRectEdgeNone;
    self.title = @"动效";
    self.view.backgroundColor = MTBg();
    CGFloat w = self.view.bounds.size.width;
    self.bars = [NSMutableArray array];
    for (NSInteger i = 0; i < 10; i++) {
        UIView *b = [[UIView alloc] initWithFrame:CGRectMake(16, 24 + i * 52, w - 32, 44)];
        b.backgroundColor = MTPanel();
        b.layer.cornerRadius = 8;
        b.alpha = 0;
        [self.view addSubview:b];
        UILabel *l = MTLabel(CGRectMake(14, 0, w - 60, 44), [NSString stringWithFormat:@"第 %ld 条：逐条滑入", (long)i + 1], 14, MTText(), UIFontWeightRegular);
        [b addSubview:l];
        [self.bars addObject:b];
    }
    UILabel *tip = MTLabel(CGRectMake(16, 24 + 10 * 52 + 8, w - 32, 40),
                           @"下拉刷新、菜单弹出、页面入场都用同一套做法：错帧 delay + 位移淡入。", 12, MTTextDim(), UIFontWeightRegular);
    tip.numberOfLines = 0;
    [self.view addSubview:tip];
    [self replay];
}

- (void)replay {
    for (UIButton *b in self.view.subviews) if ([b isKindOfClass:[UIButton class]]) [b removeFromSuperview];
    UIButton *again = [UIButton buttonWithType:UIButtonTypeSystem];
    again.frame = CGRectMake(16, self.view.bounds.size.height - 64, self.view.bounds.size.width - 32, 44);
    [again setTitle:@"重播" forState:UIControlStateNormal];
    [again setTitleColor:MTText() forState:UIControlStateNormal];
    again.backgroundColor = MTPanel();
    again.layer.cornerRadius = 8;
    again.clipsToBounds = YES;
    [again addTarget:self action:@selector(replay) forControlEvents:UIControlEventTouchUpInside];
    MTRipple(again, 2);
    [self.view addSubview:again];
    [self.bars enumerateObjectsUsingBlock:^(UIView *v, NSUInteger idx, BOOL *stop) {
        v.alpha = 0;
        v.transform = CGAffineTransformMakeTranslation(0, -12);
        [UIView animateWithDuration:0.26 delay:0.045 * idx options:UIViewAnimationOptionCurveEaseOut animations:^{
            v.alpha = 1; v.transform = CGAffineTransformIdentity;
        } completion:nil];
    }];
}
@end

#pragma mark - 接管 Markdown / 文本编辑器

@interface MTDemoEditorVC : UIViewController <UITextViewDelegate>
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *original;
@property (nonatomic, strong) UITextView *tv;
@property (nonatomic, strong) UIButton *saveBtn;
@property (nonatomic, strong) UILabel *stat;
@end

@implementation MTDemoEditorVC

- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (self) _path = [path copy];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.edgesForExtendedLayout = UIRectEdgeNone;
    self.title = self.path.lastPathComponent;
    self.view.backgroundColor = MTBg();
    self.original = [NSString stringWithContentsOfFile:self.path encoding:NSUTF8StringEncoding error:NULL] ?: @"";

    CGFloat w = self.view.bounds.size.width;
    self.stat = MTLabel(CGRectMake(16, 6, w - 32, 18), @"", 11, MTTextDim(), UIFontWeightRegular);
    [self.view addSubview:self.stat];

    self.tv = [[UITextView alloc] initWithFrame:CGRectMake(0, 28, w, self.view.bounds.size.height - 96)];
    self.tv.backgroundColor = MTPanel();
    self.tv.textColor = MTText();
    self.tv.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    self.tv.text = self.original;
    self.tv.delegate = self;
    self.tv.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    self.tv.keyboardAppearance = UIKeyboardAppearanceDark;
    [self.view addSubview:self.tv];

    self.saveBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.saveBtn.frame = CGRectMake(16, self.view.bounds.size.height - 60, w - 32, 44);
    [self.saveBtn setTitle:@"保存（扩展写入）" forState:UIControlStateNormal];
    [self.saveBtn setTitleColor:MTText() forState:UIControlStateNormal];
    self.saveBtn.backgroundColor = MTAccent();
    self.saveBtn.layer.cornerRadius = 10;
    self.saveBtn.clipsToBounds = YES;
    [self.saveBtn addTarget:self action:@selector(save) forControlEvents:UIControlEventTouchUpInside];
    MTRipple(self.saveBtn, 2);
    [self.view addSubview:self.saveBtn];

    [self updateStat];
}

- (void)updateStat {
    self.stat.text = [NSString stringWithFormat:@"%@ · %lu 行 · %lu 字 · %@",
                      self.path.lastPathComponent, (unsigned long)[self.tv.text componentsSeparatedByString:@"\n"].count,
                      (unsigned long)self.tv.text.length,
                      [self.tv.text isEqualToString:self.original] ? @"无改动" : @"已修改"];
    self.saveBtn.enabled = ![self.tv.text isEqualToString:self.original];
    self.saveBtn.alpha = self.saveBtn.enabled ? 1.0 : 0.45;
}

- (void)textViewDidChange:(UITextView *)tv { [self updateStat]; }

- (void)save {
    NSError *err = nil;
    BOOL ok = [self.tv.text writeToFile:self.path atomically:YES encoding:NSUTF8StringEncoding error:&err];
    if (ok) {
        self.original = self.tv.text;
        [self updateStat];
        MTHostAlert(@"已保存", [NSString stringWithFormat:@"写回 %@", self.path.lastPathComponent]);
    } else {
        MTHostAlert(@"保存失败", err.localizedDescription ?: @"未知错误");
    }
}
@end

#pragma mark - 能力总览

@interface MTDemoHomeVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray<NSArray *> *rows;
@end

@implementation MTDemoHomeVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.edgesForExtendedLayout = UIRectEdgeNone;
    self.title = @"扩展能力演示";
    self.view.backgroundColor = MTBg();
    self.rows = @[
        @[@"folder",   @"文件浏览器",   @"遍历 /var/mobile，读取属性、大小、修改时间", @"files"],
        @[@"archivebox", @"压缩包探查", @"自带 zip 解析器，列条目 + 直接读文本预览", @"zip"],
        @[@"paintbrush", @"主题与波纹", @"读取宿主 MTTheme 配色，调用 MTMaterialRipple 波纹", @"lab"],
        @[@"bell.badge", @"宿主弹窗",   @"通过 objc runtime 调 MTAlertCenter，与主界面同一套弹窗", @"alert"],
        @[@"hourglass", @"宿主 HUD",    @"调 MTProgressHUD 显示进度框，扩展无需自带 UI", @"hud"],
        @[@"wand.and.stars", @"撑满一屏的动效", @"纯 CoreAnimation：光斑、脉冲、逐条滑入", @"anim"],
        @[@"doc.text", @"接管编辑器",   @"manifest 声明 md/txt，打开即用扩展自己的编辑器", @"editor"],
        @[@"cube.transparent", @"3D 演示", @"CoreAnimation 3D：透视立方体 + 环绕方块，可拖动旋转/双指缩放", @"threed"],
        @[@"arrow.down.circle", @"多线程下载", @"4 条 Range 请求并发，落地后合并，进度按字节累加", @"dl"],
        @[@"terminal", @"终端", @"MTExtShellRun 走 bash -lc，输入框 + 快捷命令 + 退出码", @"term"],
        @[@"square.grid.3x3.fill", @"2048 小游戏", @"棋盘、滑动合并、计分、最高分持久化（原独立 2048 扩展已并入）", @"g2048"],
    ];

    UIView *hero = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 128)];
    CAGradientLayer *g = [CAGradientLayer layer];
    g.frame = hero.bounds;
    g.colors = @[(id)[MTAccent() colorWithAlphaComponent:0.85].CGColor,
                 (id)[UIColor colorWithRed:0.45 green:0.22 blue:0.80 alpha:0.9].CGColor];
    g.startPoint = CGPointMake(0, 0); g.endPoint = CGPointMake(1, 1);
    [hero.layer addSublayer:g];
    [hero addSubview:MTLabel(CGRectMake(20, 34, 320, 28), @"MT 扩展 v2 · 能力演示", 22, [UIColor whiteColor], UIFontWeightBold)];
    [hero addSubview:MTLabel(CGRectMake(20, 68, 340, 20), @"一个 dylib + manifest.json，就能做到这些", 13, [UIColor colorWithWhite:1 alpha:0.8], UIFontWeightRegular)];
    [hero addSubview:MTLabel(CGRectMake(20, 92, 340, 16), @"com.lgyz.mt.ext.demo · 1.0.0", 11, [UIColor colorWithWhite:1 alpha:0.6], UIFontWeightRegular)];

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.table.dataSource = self; self.table.delegate = self;
    self.table.backgroundColor = MTBg();
    self.table.separatorColor = [UIColor colorWithWhite:1 alpha:0.06];
    self.table.tableHeaderView = hero;
    self.table.rowHeight = 64;
    [self.view addSubview:self.table];
}

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return self.rows.count; }

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"c"];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
        c.backgroundColor = MTCell();
        c.textLabel.textColor = MTText();
        c.detailTextLabel.textColor = MTTextDim();
        c.detailTextLabel.numberOfLines = 2;
        c.tintColor = MTAccent();
        UIView *sel = [[UIView alloc] init];
        sel.backgroundColor = [MTAccent() colorWithAlphaComponent:0.16];
        c.selectedBackgroundView = sel;
    }
    NSArray *r = self.rows[ip.row];
    c.imageView.image = [UIImage systemImageNamed:r[0] withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20]];
    c.textLabel.text = r[1];
    c.detailTextLabel.text = r[2];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    NSString *key = self.rows[ip.row][3];
    if ([key isEqualToString:@"files"]) { [self push:[[MTDemoFilesVC alloc] initWithPath:@"/var/mobile"]]; return; }
    if ([key isEqualToString:@"zip"])   { [self push:[MTDemoZipVC new]]; return; }
    if ([key isEqualToString:@"lab"])   { [self push:[MTDemoLabVC new]]; return; }
    if ([key isEqualToString:@"alert"]) { MTHostAlert(@"来自扩展", @"这条弹窗是扩展通过 objc runtime 调宿主 MTAlertCenter 弹出来的。"); return; }
    if ([key isEqualToString:@"hud"])   { MTHostHUD(@"扩展正在干活…"); return; }
    if ([key isEqualToString:@"anim"])  { [self push:[MTDemoAnimVC new]]; return; }
    if ([key isEqualToString:@"threed"]){ [self push:[[NSClassFromString(@"MTDemo3DVC") alloc] init]]; return; }
    if ([key isEqualToString:@"dl"])     { [self push:[[NSClassFromString(@"MTDemoDownloadVC") alloc] init]]; return; }
    if ([key isEqualToString:@"term"])   { [self push:[[NSClassFromString(@"MTDemoTermVC") alloc] init]]; return; }
    if ([key isEqualToString:@"g2048"])  { [self push:[[NSClassFromString(@"MT2048ViewController") alloc] init]]; return; }
    if ([key isEqualToString:@"editor"]) {
        MTHostAlert(@"编辑器接管", @"manifest 里声明 editorExtensions 后，在文件列表点 .md / .txt 就会进入扩展自己的编辑器，不再用宿主的内置编辑器。随便找一个 Markdown 文件试试。");
    }
}

- (void)push:(UIViewController *)vc {
    vc.view.backgroundColor = MTBg();
    UINavigationController *nav = self.navigationController;
    if (nav) [nav pushViewController:vc animated:YES];
    else { UINavigationController *n = [[UINavigationController alloc] initWithRootViewController:vc]; [self presentViewController:n animated:YES completion:nil]; }
}
@end

#pragma mark - 工厂


#pragma mark - 权限演示（v2.1）：联网 / 终端必须用户手动同意

typedef BOOL (*MT_ConsentQuery)(NSString *, NSString *);
typedef void (*MT_ConsentAsk)(NSString *, NSString *, NSString *, void (^)(BOOL));
typedef pid_t (*MT_ShellRun)(NSString *, NSString *, NSString *, void (^)(NSString *, BOOL), void (^)(int));
typedef void (*MT_NetGet)(NSString *, NSString *, NSDictionary *, void (^)(NSData *, NSInteger, NSError *));

static MT_ConsentQuery gConsentQuery;
static MT_ConsentAsk gConsentAsk;
static MT_ShellRun gShellRun;
static MT_NetGet gNetGet;
static void loadCaps(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gConsentQuery = (MT_ConsentQuery)dlsym(RTLD_DEFAULT, "MTExtConsentGranted");
        gConsentAsk   = (MT_ConsentAsk)dlsym(RTLD_DEFAULT, "MTExtRequestConsent");
        gShellRun     = (MT_ShellRun)dlsym(RTLD_DEFAULT, "MTExtShellRun");
        gNetGet       = (MT_NetGet)dlsym(RTLD_DEFAULT, "MTExtNetRequest");
    });
}

@interface MTDemoCapsVC : UIViewController
@property (nonatomic, strong) UITextView *tv;
@end

@implementation MTDemoCapsVC
- (void)viewDidLoad {
    [super viewDidLoad];
    loadCaps();
    self.title = @"权限 · 终端 · 网络";
    self.view.backgroundColor = MTBg();
    CGFloat w = self.view.bounds.size.width;

    self.tv = [[UITextView alloc] initWithFrame:CGRectMake(16, 76, w - 32, self.view.bounds.size.height - 240)];
    self.tv.editable = NO;
    self.tv.backgroundColor = MTPanel();
    self.tv.textColor = MTText();
    self.tv.font = [UIFont fontWithName:@"Menlo" size:12] ?: [UIFont systemFontOfSize:12];
    self.tv.text = @"这里的每个按钮都会先让用户看到宿主弹窗（允许 / 拒绝），\n描述文件里写一句不算授权。\n";
    [self.view addSubview:self.tv];

    NSArray *titles = @[@"终端：跑 uname -a", @"网络：GET 市场索引", @"查看当前授权状态"];
    CGFloat y = self.view.bounds.size.height - 150;
    for (NSInteger i = 0; i < titles.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(16, y, w - 32, 40);
        b.backgroundColor = MTCell();
        b.layer.cornerRadius = 10;
        [b setTitle:titles[i] forState:UIControlStateNormal];
        [b setTitleColor:MTText() forState:UIControlStateNormal];
        b.tag = i;
        [b addTarget:self action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:b];
        y += 48;
    }
}

- (void)append:(NSString *)s {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.tv.text = [self.tv.text stringByAppendingFormat:@"\n%@", s ?: @""];
        [self.tv scrollRangeToVisible:NSMakeRange(self.tv.text.length, 1)];
    });
}

- (void)tap:(UIButton *)b {
    NSString *eid = @"com.lgyz.mt.ext.demo";
    if (!gConsentQuery) { [self append:@"宿主没有 v2.1 权限 API，升级 MTFile 到 1.2.0-14+"]; return; }
    if (b.tag == 0) {
        if (!gShellRun) { [self append:@"宿主没有 MTExtShellRun"]; return; }
        [self append:@"$ uname -a"];
        pid_t pid = gShellRun(eid, @"uname -a", @"/var/mobile", ^(NSString *chunk, BOOL isErr) {
            [self append:chunk];
        }, ^(int st) {
            [self append:[NSString stringWithFormat:@"[退出码 %d]", st]];
        });
        [self append:[NSString stringWithFormat:@"pid = %d（-1 表示没权限或没 shell）", pid]];
    } else if (b.tag == 1) {
        if (!gNetGet) { [self append:@"宿主没有 MTExtNetRequest"]; return; }
        [self append:@"GET https://lgyz6767.github.io/repo/ext/index.json"];
        gNetGet(eid, @"https://lgyz6767.github.io/repo/ext/index.json", nil, ^(NSData *d, NSInteger code, NSError *e) {
            if (e) { [self append:[NSString stringWithFormat:@"失败：%@", e.localizedDescription]]; return; }
            NSString *body = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
            [self append:[NSString stringWithFormat:@"HTTP %ld，%lu 字节\n%@", (long)code, (unsigned long)d.length,
                         body.length > 400 ? [body substringToIndex:400] : body]];
        });
    } else {
        BOOL net = gConsentQuery(eid, @"network");
        BOOL term = gConsentQuery(eid, @"terminal");
        [self append:[NSString stringWithFormat:@"network = %@，terminal = %@\n（= NO 时下次调用会重新弹窗）",
                     net ? @"允许" : @"未允许", term ? @"允许" : @"未允许"]];
    }
}
@end


#pragma mark - 3D 演示（CoreAnimation，iPhone 7 上不依赖 Metal / SceneKit）

// 说明：早先用 SceneKit，在部分越狱环境里 SCNView 起不来（黑屏只剩提示文字），
// 这里改成纯 CoreAnimation 的 3D 变换：透视 + 六面立方体 + 环绕小方块，任何设备都能跑。

@interface MTDemo3DVC : UIViewController <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIView *stage;
@property (nonatomic, strong) CALayer *spin;        // 整体自转
@property (nonatomic, strong) CALayer *cube;        // 六面体
@property (nonatomic, strong) NSMutableArray<CALayer *> *sats;
@property (nonatomic, assign) CGFloat dragX, dragY, zoom;
@end

static CATransform3D MT3DPerspective(CGFloat d) {
    CATransform3D t = CATransform3DIdentity;
    t.m34 = -1.0 / d;
    return t;
}

@implementation MTDemo3DVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = MTBg();
    self.title = @"3D 演示";
    self.zoom = 1.0;
    self.sats = [NSMutableArray array];

    _stage = [[UIView alloc] initWithFrame:CGRectZero];
    _stage.backgroundColor = [UIColor clearColor];
    _stage.layer.sublayerTransform = MT3DPerspective(900);
    _stage.userInteractionEnabled = YES;
    [self.view addSubview:_stage];

    _spin = [CALayer layer];
    _spin.frame = CGRectMake(0, 0, 1, 1);
    [_stage.layer addSublayer:_spin];

    // 六面立方体
    _cube = [CALayer layer];
    _cube.bounds = CGRectMake(0, 0, 140, 140);
    _cube.anchorPoint = CGPointMake(0.5, 0.5);
    [_spin addSublayer:_cube];
    UIColor *faces[6] = {
        [UIColor colorWithRed:0.24 green:0.51 blue:0.96 alpha:0.95],
        [UIColor colorWithRed:0.20 green:0.42 blue:0.86 alpha:0.95],
        [UIColor colorWithRed:0.30 green:0.58 blue:0.98 alpha:0.9],
        [UIColor colorWithRed:0.17 green:0.36 blue:0.78 alpha:0.9],
        [UIColor colorWithRed:0.27 green:0.54 blue:0.94 alpha:0.85],
        [UIColor colorWithRed:0.22 green:0.46 blue:0.90 alpha:0.85]
    };
    CGFloat h = 70;
    CATransform3D mats[6] = {
        CATransform3DMakeTranslation(0, 0, h),
        CATransform3DMakeRotation(M_PI, 0, 1, 0),
        CATransform3DConcat(CATransform3DMakeTranslation(0, 0, -h), CATransform3DMakeRotation(M_PI, 0, 1, 0)),
        CATransform3DMakeRotation(M_PI_2, 1, 0, 0),
        CATransform3DConcat(CATransform3DMakeRotation(-M_PI_2, 1, 0, 0), CATransform3DMakeTranslation(0, 0, h)),
        CATransform3DConcat(CATransform3DMakeRotation(-M_PI_2, 1, 0, 0), CATransform3DMakeTranslation(0, 0, -h))
    };
    for (NSInteger i = 0; i < 6; i++) {
        CALayer *f = [CALayer layer];
        f.bounds = CGRectMake(0, 0, 140, 140);
        f.position = CGPointMake(0, 0);
        f.backgroundColor = faces[i].CGColor;
        f.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
        f.borderWidth = 1;
        f.cornerRadius = 10;
        f.transform = mats[i];
        [_cube addSublayer:f];
    }
    // 立方体自身缓慢翻滚（与整圈公转叠加）
    CABasicAnimation *rx = [CABasicAnimation animationWithKeyPath:@"transform.rotation.x"];
    rx.fromValue = @0; rx.toValue = @(M_PI * 2);
    rx.duration = 14; rx.repeatCount = HUGE_VALF;
    [_cube addAnimation:rx forKey:@"spinX"];
    CABasicAnimation *ry = [CABasicAnimation animationWithKeyPath:@"transform.rotation.y"];
    ry.fromValue = @0; ry.toValue = @(M_PI * 2);
    ry.duration = 9; ry.repeatCount = HUGE_VALF;
    [_cube addAnimation:ry forKey:@"spinY"];

    // 环绕的小方块
    for (NSInteger i = 0; i < 8; i++) {
        CALayer *s = [CALayer layer];
        s.bounds = CGRectMake(0, 0, 22, 22);
        s.cornerRadius = 5;
        s.backgroundColor = [UIColor colorWithWhite:0.96 alpha:1].CGColor;
        s.borderColor = [MTAccent() colorWithAlphaComponent:0.6].CGColor;
        s.borderWidth = 1;
        [_spin addSublayer:s];
        [_sats addObject:s];
    }
    CABasicAnimation *orbit = [CABasicAnimation animationWithKeyPath:@"transform.rotation.y"];
    orbit.fromValue = @0; orbit.toValue = @(M_PI * 2);
    orbit.duration = 18; orbit.repeatCount = HUGE_VALF;
    [_spin addAnimation:orbit forKey:@"orbit"];

    // 阴影底盘
    CALayer *shadow = [CALayer layer];
    shadow.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35].CGColor;
    shadow.cornerRadius = 4;
    shadow.name = @"shadow";
    [_stage.layer addSublayer:shadow];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
    pan.delegate = self;
    [self.view addGestureRecognizer:pan];
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinch:)];
    pinch.delegate = self;
    [self.view addGestureRecognizer:pinch];

    UILabel *hint = MTLabel(CGRectMake(16, 0, 10, 20),
                            @"拖动旋转 / 双指缩放", 12, MTTextDim(), UIFontWeightRegular);
    hint.tag = 9001;
    hint.textAlignment = NSTextAlignmentCenter;
    hint.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:hint];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIEdgeInsets sa = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) sa = self.view.safeAreaInsets;
    CGRect b = self.view.bounds;
    // 顶栏 + 底部安全区都扣掉，内容严格居中在可用区域
    CGFloat top = sa.top + (self.navigationController.navigationBar.translucent ? 0 : CGRectGetHeight(self.navigationController.navigationBar.frame));
    CGFloat avail = CGRectGetHeight(b) - top - sa.bottom;
    _stage.frame = CGRectMake(0, top, CGRectGetWidth(b), avail);
    _stage.layer.sublayerTransform = MT3DPerspective(900.0 * self.zoom);

    CGPoint c = CGPointMake(CGRectGetWidth(_stage.bounds) / 2.0, CGRectGetHeight(_stage.bounds) / 2.0);
    _spin.position = c;
    _spin.bounds = CGRectMake(0, 0, 1, 1);
    _spin.anchorPoint = CGPointMake(0.5, 0.5);
    _cube.position = CGPointZero;

    CGFloat R = MIN(CGRectGetWidth(_stage.bounds), CGRectGetHeight(_stage.bounds)) * 0.30;
    for (NSInteger i = 0; i < (NSInteger)_sats.count; i++) {
        CGFloat a = i / (CGFloat)_sats.count * M_PI * 2;
        CALayer *s = _sats[i];
        s.position = CGPointMake(cos(a) * R, sin(a) * 0.35 * R);
        s.transform = CATransform3DMakeTranslation(0, 0, sin(a) * R);
    }
    CALayer *shadow = nil;
    for (CALayer *l in _stage.layer.sublayers) if ([l.name isEqualToString:@"shadow"]) shadow = l;
    shadow.frame = CGRectMake(c.x - 90, c.y + R * 0.9, 180, 8);

    UILabel *hint = [self.view viewWithTag:9001];
    hint.frame = CGRectMake(16, CGRectGetMaxY(b) - sa.bottom - 28, CGRectGetWidth(b) - 32, 20);
}

- (void)pan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.view];
    if (g.state == UIGestureRecognizerStateBegan) { self.dragX = 0; self.dragY = 0; }
    self.dragX += t.x * 0.008;
    self.dragY -= t.y * 0.008;
    [g setTranslation:CGPointZero inView:self.view];
    _stage.layer.sublayerTransform = CATransform3DConcat(MT3DPerspective(900.0 * self.zoom),
        CATransform3DConcat(CATransform3DMakeRotation(self.dragY, 1, 0, 0),
                            CATransform3DMakeRotation(self.dragX, 0, 1, 0)));
}

- (void)pinch:(UIPinchGestureRecognizer *)g {
    self.zoom = MAX(0.6, MIN(2.2, self.zoom * g.scale));
    g.scale = 1;
    _stage.layer.sublayerTransform = CATransform3DConcat(MT3DPerspective(900.0 * self.zoom),
        CATransform3DConcat(CATransform3DMakeRotation(self.dragY, 1, 0, 0),
                            CATransform3DMakeRotation(self.dragX, 0, 1, 0)));
}

@end

#pragma mark - 多线程下载（分段 Range 并发 + 合并）

@interface MTDemoDownloadVC : UIViewController
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) UIProgressView *bar;
@property (nonatomic, strong) UITextView *log;
@property (nonatomic, assign) NSInteger total;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *done;
@property (nonatomic, strong) NSMutableArray<NSString *> *parts;
@property (nonatomic, assign) BOOL running;
@end

@implementation MTDemoDownloadVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.edgesForExtendedLayout = UIRectEdgeNone;
    self.title = @"多线程下载";
    self.view.backgroundColor = MTBg();
    CGFloat w = self.view.bounds.size.width;

    self.status = MTLabel(CGRectMake(16, 72, w - 32, 20), @"待开始", 13, MTTextDim(), UIFontWeightRegular);
    [self.view addSubview:self.status];

    self.bar = [[UIProgressView alloc] initWithFrame:CGRectMake(16, 100, w - 32, 4)];
    self.bar.progressTintColor = MTAccent();
    [self.view addSubview:self.bar];

    self.log = [[UITextView alloc] initWithFrame:CGRectMake(16, 118, w - 32, self.view.bounds.size.height - 260)];
    self.log.editable = NO; self.log.backgroundColor = MTPanel(); self.log.textColor = MTText();
    self.log.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
    self.log.text = @"把一个大文件切成 N 段，Range 并发下载，全部落地后再合并。\n每条 NSURLSession 任务独立，进度按字节累加。\n";
    [self.view addSubview:self.log];

    UIButton *go = [UIButton buttonWithType:UIButtonTypeSystem];
    go.frame = CGRectMake(16, self.view.bounds.size.height - 126, w - 32, 44);
    go.backgroundColor = MTCell(); go.layer.cornerRadius = 10;
    [go setTitle:@"开始 4 线程下载" forState:UIControlStateNormal];
    [go setTitleColor:MTText() forState:UIControlStateNormal];
    [go addTarget:self action:@selector(start) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:go];
}

- (void)append:(NSString *)s {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.log.text = [self.log.text stringByAppendingFormat:@"\n%@", s ?: @""];
        [self.log scrollRangeToVisible:NSMakeRange(self.log.text.length, 1)];
    });
}

- (void)start {
    if (self.running) return;
    self.running = YES;
    loadCaps();
    NSString *eid = @"com.lgyz.mt.ext.demo";
    if (!gConsentAsk) { [self append:@"宿主没有权限 API"]; self.running = NO; return; }
    gConsentAsk(eid, @"network", @"多线程下载需要联网：分段请求同一个文件再合并。", ^(BOOL granted) {
        if (!granted) { [self append:@"用户拒绝联网"]; self.running = NO; return; }
        [self runDownload];
    });
}

- (void)runDownload {
    NSString *urlStr = @"https://raw.githubusercontent.com/lgyz6767/Mtfile-iOS-extras-SDK/main/readme.md";
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *head = [NSMutableURLRequest requestWithURL:url];
    head.timeoutInterval = 15;
    [[[NSURLSession sharedSession] dataTaskWithRequest:head completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSInteger len = [(NSHTTPURLResponse *)r statusCode] == 200 ? r.expectedContentLength : -1;
        if (len <= 0) { [self append:[NSString stringWithFormat:@"拿不到长度：%@", e.localizedDescription ?: @"status != 200"]]; self.running = NO; return; }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.total = len;
            self.done = [@[@0,@0,@0,@0] mutableCopy];
            self.parts = [NSMutableArray array];
            [self append:[NSString stringWithFormat:@"文件 %ld 字节，切成 4 段", (long)len]];
            [self fetchChunk:0 of:4 url:url];
            [self fetchChunk:1 of:4 url:url];
            [self fetchChunk:2 of:4 url:url];
            [self fetchChunk:3 of:4 url:url];
        });
    }] resume];
}

- (void)fetchChunk:(NSInteger)i of:(NSInteger)n url:(NSURL *)url {
    NSInteger len = self.total;
    NSInteger start = len * i / n;
    NSInteger end = (i == n - 1) ? len - 1 : (len * (i + 1) / n - 1);
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 20;
    [req setValue:[NSString stringWithFormat:@"bytes=%ld-%ld", (long)start, (long)end] forHTTPHeaderField:@"Range"];
    NSURLSessionDataTask *t = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
            if (err || code != 206) {
                [self append:[NSString stringWithFormat:@"段 %ld 失败：HTTP %ld %@", (long)i, (long)code, err.localizedDescription ?: @""]];
                dispatch_async(dispatch_get_main_queue(), ^{ self.running = NO; });
                return;
            }
            NSString *p = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"dl_%ld.part", (long)i]];
            [data writeToFile:p atomically:YES];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.parts[i] = p;
                self.done[i] = @(data.length);
                [self updateProgress];
                [self append:[NSString stringWithFormat:@"段 %ld 完成：%lu 字节", (long)i, (unsigned long)data.length]];
                if (self.parts.count == 4 && self.parts[0] && self.parts[1] && self.parts[2] && self.parts[3]) [self merge];
            });
        }];
    [t resume];
}

- (void)updateProgress {
    double got = 0; for (NSNumber *n in self.done) got += n.doubleValue;
    float p = self.total > 0 ? (float)(got / self.total) : 0;
    self.bar.progress = p;
    self.status.text = [NSString stringWithFormat:@"%.0f%%  %ld / %ld 字节", p * 100, (long)got, (long)self.total];
}

- (void)merge {
    NSString *out = [NSTemporaryDirectory() stringByAppendingPathComponent:@"merged.md"];
    [[NSFileManager defaultManager] removeItemAtPath:out error:NULL];
    NSMutableData *all = [NSMutableData data];
    for (NSInteger i = 0; i < 4; i++) {
        NSData *d = [NSData dataWithContentsOfFile:self.parts[i]];
        if (d) [all appendData:d];
    }
    [all writeToFile:out atomically:YES];
    [self append:[NSString stringWithFormat:@"合并完成：%@（%lu 字节）", out, (unsigned long)all.length]];
    self.status.text = @"完成";
    self.running = NO;
}
@end

#pragma mark - 终端（MTExtShellRun + 命令输入）

@interface MTDemoTermVC : UIViewController <UITextFieldDelegate>
@property (nonatomic, strong) UITextView *out;
@property (nonatomic, strong) UITextField *input;
@property (nonatomic, strong) NSMutableArray<NSString *> *history;
@end

@implementation MTDemoTermVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.edgesForExtendedLayout = UIRectEdgeNone;
    self.title = @"终端";
    self.view.backgroundColor = MTBg();
    self.history = [NSMutableArray array];
    CGFloat w = self.view.bounds.size.width, h = self.view.bounds.size.height;

    self.out = [[UITextView alloc] initWithFrame:CGRectMake(0, 0, w, h - 96)];
    self.out.editable = NO; self.out.backgroundColor = MTBg(); self.out.textColor = MTText();
    self.out.font = [UIFont fontWithName:@"Menlo" size:12] ?: [UIFont systemFontOfSize:12];
    self.out.text = @"# 命令在宿主进程外由 bash -lc 执行，需要终端权限\n";
    [self.view addSubview:self.out];

    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, h - 96, w, 96)];
    bar.backgroundColor = MTPanel();
    [self.view addSubview:bar];

    self.input = [[UITextField alloc] initWithFrame:CGRectMake(12, 10, w - 100, 34)];
    self.input.backgroundColor = MTCell(); self.input.textColor = MTText();
    self.input.placeholder = @"输入命令，例如 ls /var/mobile";
    self.input.font = [UIFont fontWithName:@"Menlo" size:12] ?: [UIFont systemFontOfSize:12];
    self.input.returnKeyType = UIReturnKeyGo;
    self.input.delegate = self;
    self.input.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 34)];
    self.input.leftViewMode = UITextFieldViewModeAlways;
    self.input.layer.cornerRadius = 8;
    [bar addSubview:self.input];

    UIButton *run = [UIButton buttonWithType:UIButtonTypeSystem];
    run.frame = CGRectMake(w - 80, 10, 68, 34);
    run.backgroundColor = MTAccent(); run.layer.cornerRadius = 8;
    [run setTitle:@"运行" forState:UIControlStateNormal];
    [run setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [run addTarget:self action:@selector(runCommand) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:run];

    NSArray *quick = @[@"uname -a", @"ls /var/mobile", @"df -h", @"id"];
    CGFloat x = 12;
    for (NSString *q in quick) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(x, 54, 0, 30);
        [b setTitle:q forState:UIControlStateNormal];
        [b setTitleColor:MTTextDim() forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
        b.backgroundColor = MTCell(); b.layer.cornerRadius = 6;
        CGSize sz = [q sizeWithAttributes:@{NSFontAttributeName:b.titleLabel.font}];
        b.frame = CGRectMake(x, 54, sz.width + 16, 30);
        b.tag = quick.count; // 简单用 title 传
        [b addTarget:self action:@selector(quickTap:) forControlEvents:UIControlEventTouchUpInside];
        [bar addSubview:b];
        x += sz.width + 24;
    }

    // 键盘避让：底部输入条跟着键盘走，别让内容被顶栏/键盘夹在中间
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(kb:) name:UIKeyboardWillChangeFrameNotification object:nil];
}

- (void)kb:(NSNotification *)n {
    CGRect r = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat kbH = MAX(0, self.view.bounds.size.height - r.origin.y);
    self.input.superview.frame = CGRectMake(0, self.view.bounds.size.height - 96 - kbH, self.view.bounds.size.width, 96);
    self.out.frame = CGRectMake(0, 0, self.view.bounds.size.width, self.view.bounds.size.height - 96 - kbH);
    [self.view bringSubviewToFront:self.input.superview];
}

- (void)quickTap:(UIButton *)b { self.input.text = [b titleForState:UIControlStateNormal]; [self runCommand]; }

- (BOOL)textFieldShouldReturn:(UITextField *)tf { [self runCommand]; return YES; }

- (void)runCommand {
    NSString *cmd = [self.input.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!cmd.length) return;
    self.input.text = @"";
    [self append:[NSString stringWithFormat:@"$ %@", cmd]];
    loadCaps();
    if (!gShellRun) { [self append:@"宿主没有 MTExtShellRun（需要 1.2.0-14+）"]; return; }
    gShellRun(@"com.lgyz.mt.ext.demo", cmd, @"/var/mobile", ^(NSString *chunk, BOOL isErr) {
        [self append:chunk];
    }, ^(int st) {
        [self append:[NSString stringWithFormat:@"[退出码 %d]", st]];
    });
}

- (void)append:(NSString *)s {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.out.text = [self.out.text stringByAppendingString:s ?: @""];
        [self.out scrollRangeToVisible:NSMakeRange(self.out.text.length, 1)];
    });
}
@end

#import <UIKit/UIKit.h>

#pragma mark - 2048 小游戏（原 game2048 扩展，合并进 demo）

#pragma mark - 棋盘

@interface MT2048BoardView : UIView
@property (nonatomic, copy) void (^onScore)(NSInteger score, NSInteger best);
@property (nonatomic, copy) void (^onGameOver)(void);
@property (nonatomic, readonly) NSInteger score;
@property (nonatomic, readonly) NSInteger best;
- (void)newGame;
- (void)swipe:(UISwipeGestureRecognizerDirection)dir;
@end

@implementation MT2048BoardView {
    NSMutableArray<NSNumber *> *_grid;   // 16 个格子，0 表示空
    UILabel *_tiles[16];
    NSInteger _score;
    NSInteger _best;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _grid = [NSMutableArray arrayWithCapacity:16];
        for (NSInteger i = 0; i < 16; i++) [_grid addObject:@0];
        self.backgroundColor = [UIColor colorWithRed:0.98 green:0.96 blue:0.93 alpha:1.0];
        self.layer.cornerRadius = 10;
        self.clipsToBounds = YES;
        for (NSInteger i = 0; i < 16; i++) {
            UILabel *l = [UILabel new];
            l.textAlignment = NSTextAlignmentCenter;
            l.font = [UIFont boldSystemFontOfSize:20];
            l.layer.cornerRadius = 6;
            l.clipsToBounds = YES;
            l.adjustsFontSizeToFitWidth = YES;
            l.minimumScaleFactor = 0.5;
            [self addSubview:l];
            _tiles[i] = l;
        }
        NSNumber *b = [[NSUserDefaults standardUserDefaults] objectForKey:@"mt2048_best"];
        _best = b ? [b integerValue] : 0;
        [self newGame];
        [self addSwipeTargets];
    }
    return self;
}

- (void)addSwipeTargets {
    NSArray *dirs = @[@(UISwipeGestureRecognizerDirectionLeft), @(UISwipeGestureRecognizerDirectionRight),
                      @(UISwipeGestureRecognizerDirectionUp), @(UISwipeGestureRecognizerDirectionDown)];
    for (NSNumber *d in dirs) {
        UISwipeGestureRecognizer *g = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(handleSwipe:)];
        g.direction = d.integerValue;
        [self addGestureRecognizer:g];
    }
}

- (void)handleSwipe:(UISwipeGestureRecognizer *)g { [self swipe:g.direction]; }

- (NSInteger)score { return _score; }
- (NSInteger)best { return _best; }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat b = self.bounds.size.width;
    CGFloat gap = 8, pad = 10;
    CGFloat size = (b - pad * 2 - gap * 3) / 4.0;
    for (NSInteger i = 0; i < 16; i++) {
        NSInteger r = i / 4, c = i % 4;
        _tiles[i].frame = CGRectMake(pad + c * (size + gap), pad + r * (size + gap), size, size);
    }
    [self refresh];
}

static UIColor *TileColor(NSUInteger v) {
    switch (v) {
        case 2:    return [UIColor colorWithRed:0.93 green:0.89 blue:0.85 alpha:1];
        case 4:    return [UIColor colorWithRed:0.93 green:0.88 blue:0.78 alpha:1];
        case 8:    return [UIColor colorWithRed:0.95 green:0.69 blue:0.47 alpha:1];
        case 16:   return [UIColor colorWithRed:0.96 green:0.58 blue:0.39 alpha:1];
        case 32:   return [UIColor colorWithRed:0.96 green:0.49 blue:0.37 alpha:1];
        case 64:   return [UIColor colorWithRed:0.96 green:0.37 blue:0.23 alpha:1];
        case 128:  return [UIColor colorWithRed:0.93 green:0.80 blue:0.35 alpha:1];
        case 256:  return [UIColor colorWithRed:0.93 green:0.77 blue:0.28 alpha:1];
        case 512:  return [UIColor colorWithRed:0.93 green:0.72 blue:0.20 alpha:1];
        case 1024: return [UIColor colorWithRed:0.93 green:0.66 blue:0.16 alpha:1];
        case 2048: return [UIColor colorWithRed:0.93 green:0.59 blue:0.12 alpha:1];
        default:   return [UIColor colorWithRed:0.62 green:0.60 blue:0.58 alpha:1];
    }
}

- (void)refresh {
    for (NSInteger i = 0; i < 16; i++) {
        NSUInteger v = [_grid[i] unsignedIntegerValue];
        UILabel *l = _tiles[i];
        if (v == 0) {
            l.text = @"";
            l.backgroundColor = [UIColor colorWithRed:0.87 green:0.84 blue:0.80 alpha:1];
        } else {
            l.text = [NSString stringWithFormat:@"%lu", (unsigned long)v];
            l.backgroundColor = TileColor(v);
            l.textColor = v <= 4 ? [UIColor colorWithWhite:0.28 alpha:1] : UIColor.whiteColor;
            l.font = [UIFont boldSystemFontOfSize:(v >= 1024 ? 16 : (v >= 128 ? 18 : 20))];
        }
    }
}

- (void)newGame {
    for (NSInteger i = 0; i < 16; i++) _grid[i] = @0;
    _score = 0;
    [self spawn];
    [self spawn];
    [self refresh];
    if (self.onScore) self.onScore(_score, _best);
}

- (NSArray<NSNumber *> *)emptyCells {
    NSMutableArray *e = [NSMutableArray array];
    for (NSInteger i = 0; i < 16; i++) if ([_grid[i] integerValue] == 0) [e addObject:@(i)];
    return e;
}

- (void)spawn {
    NSArray *e = [self emptyCells];
    if (!e.count) return;
    NSInteger idx = [e[arc4random_uniform((uint32_t)e.count)] integerValue];
    _grid[idx] = (arc4random_uniform(10) == 0) ? @4 : @2;
}

// 把一行（4 个数）向左合并，返回新行与得分
static NSArray *MergeLine(NSArray<NSNumber *> *line, NSInteger *gained) {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableArray *nonzero = [NSMutableArray array];
    for (NSNumber *n in line) if (n.integerValue != 0) [nonzero addObject:n];
    NSInteger i = 0;
    while (i < (NSInteger)nonzero.count) {
        NSInteger v = [(NSNumber *)nonzero[i] integerValue];
        if (i + 1 < (NSInteger)nonzero.count && [(NSNumber *)nonzero[i + 1] integerValue] == v) {
            [out addObject:@(v * 2)];
            if (gained) *gained += v * 2;
            i += 2;
        } else {
            [out addObject:@(v)];
            i += 1;
        }
    }
    while (out.count < 4) [out addObject:@0];
    return out;
}

- (BOOL)moveDirection:(UISwipeGestureRecognizerDirection)dir {
    BOOL moved = NO;
    NSInteger gained = 0;
    for (NSInteger i = 0; i < 4; i++) {
        NSMutableArray *line = [NSMutableArray array];
        for (NSInteger j = 0; j < 4; j++) {
            NSInteger idx;
            if (dir == UISwipeGestureRecognizerDirectionLeft)  idx = i * 4 + j;
            else if (dir == UISwipeGestureRecognizerDirectionRight) idx = i * 4 + (3 - j);
            else if (dir == UISwipeGestureRecognizerDirectionUp) idx = j * 4 + i;
            else idx = (3 - j) * 4 + i;
            [line addObject:_grid[idx]];
        }
        NSArray *merged = MergeLine(line, &gained);
        for (NSInteger j = 0; j < 4; j++) {
            NSInteger idx;
            if (dir == UISwipeGestureRecognizerDirectionLeft)  idx = i * 4 + j;
            else if (dir == UISwipeGestureRecognizerDirectionRight) idx = i * 4 + (3 - j);
            else if (dir == UISwipeGestureRecognizerDirectionUp) idx = j * 4 + i;
            else idx = (3 - j) * 4 + i;
            if (![_grid[idx] isEqualToNumber:merged[j]]) moved = YES;
            _grid[idx] = merged[j];
        }
    }
    if (moved) {
        _score += gained;
        [self spawn];
        [self refresh];
        if (_score > _best) {
            _best = _score;
            [[NSUserDefaults standardUserDefaults] setObject:@(_best) forKey:@"mt2048_best"];
        }
        if (self.onScore) self.onScore(_score, _best);
        if (![self emptyCells].count && ![self canMerge]) {
            if (self.onGameOver) self.onGameOver();
        }
    }
    return moved;
}

- (BOOL)canMerge {
    for (NSInteger r = 0; r < 4; r++) {
        for (NSInteger c = 0; c < 4; c++) {
            NSInteger v = [_grid[r * 4 + c] integerValue];
            if (c < 3 && [_grid[r * 4 + c + 1] integerValue] == v) return YES;
            if (r < 3 && [_grid[(r + 1) * 4 + c] integerValue] == v) return YES;
        }
    }
    return NO;
}

- (void)swipe:(UISwipeGestureRecognizerDirection)dir {
    if (![self moveDirection:dir]) return;
    // 轻反馈：整盘轻微回弹，说明这一下吃到了
    [UIView animateWithDuration:0.08 animations:^{
        self.transform = CGAffineTransformMakeScale(0.985, 0.985);
    } completion:^(BOOL f) {
        [UIView animateWithDuration:0.10 animations:^{ self.transform = CGAffineTransformIdentity; }];
    }];
}

@end

#pragma mark - 页面

@interface MT2048ViewController : UIViewController
@end

@implementation MT2048ViewController {
    MT2048BoardView *_board;
    UILabel *_scoreLabel;
    UILabel *_bestLabel;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"2048";
    self.view.backgroundColor = [UIColor colorWithRed:0.98 green:0.96 blue:0.93 alpha:1.0];

    UILabel *title = [UILabel new];
    title.text = @"2048";
    title.font = [UIFont boldSystemFontOfSize:28];
    title.textColor = [UIColor colorWithRed:0.47 green:0.43 blue:0.40 alpha:1.0];
    title.frame = CGRectMake(16, 8, 100, 34);
    [self.view addSubview:title];

    _scoreLabel = [self badgeWithTitle:@"分数"];
    _bestLabel = [self badgeWithTitle:@"最高"];
    [self.view addSubview:_scoreLabel];
    [self.view addSubview:_bestLabel];

    UIButton *restart = [UIButton buttonWithType:UIButtonTypeSystem];
    [restart setTitle:@"重开" forState:UIControlStateNormal];
    restart.backgroundColor = [UIColor colorWithRed:0.55 green:0.51 blue:0.47 alpha:1.0];
    [restart setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    restart.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    restart.layer.cornerRadius = 6;
    [restart addTarget:self action:@selector(restart) forControlEvents:UIControlEventTouchUpInside];
    restart.frame = CGRectMake(0, 8, 56, 34);
    [self.view addSubview:restart];

    _board = [[MT2048BoardView alloc] initWithFrame:CGRectZero];
    [self.view addSubview:_board];
    __weak typeof(self) ws = self;
    _board.onScore = ^(NSInteger score, NSInteger best) {
        typeof(self) ss = ws; if (!ss) return;
        ss->_scoreLabel.text = [NSString stringWithFormat:@"分数\n%ld", (long)score];
        ss->_bestLabel.text = [NSString stringWithFormat:@"最高\n%ld", (long)best];
    };
    _board.onGameOver = ^{
        typeof(self) ss = ws; if (!ss) return;
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"游戏结束"
                                                                   message:[NSString stringWithFormat:@"本局得分 %ld，最高 %ld", (long)ss->_board.score, (long)ss->_board.best]
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"重开" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [ss->_board newGame]; }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
        [ss presentViewController:ac animated:YES completion:nil];
    };
    _scoreLabel.text = @"分数\n0";
    _bestLabel.text = [NSString stringWithFormat:@"最高\n%ld", (long)_board.best];
    [self.view addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(noop)]];
}

- (void)noop {}

- (UILabel *)badgeWithTitle:(NSString *)title {
    UILabel *l = [UILabel new];
    l.numberOfLines = 2;
    l.textAlignment = NSTextAlignmentCenter;
    l.font = [UIFont systemFontOfSize:11];
    l.textColor = [UIColor colorWithRed:0.47 green:0.43 blue:0.40 alpha:1.0];
    l.backgroundColor = [UIColor colorWithRed:0.93 green:0.90 blue:0.86 alpha:1.0];
    l.layer.cornerRadius = 6;
    l.clipsToBounds = YES;
    l.text = title;
    return l;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIEdgeInsets si = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) si = self.view.safeAreaInsets;
    CGFloat W = self.view.bounds.size.width;
    CGFloat top = si.top + 52;
    CGFloat boardW = MIN(W - 32, self.view.bounds.size.height - top - si.bottom - 32);
    _board.frame = CGRectMake((W - boardW) / 2.0, top + 8, boardW, boardW);
    CGFloat badgeW = 64;
    _scoreLabel.frame = CGRectMake(W - badgeW * 2 - 44, 8, badgeW, 42);
    _bestLabel.frame = CGRectMake(W - badgeW - 32, 8, badgeW, 42);
    for (UIView *v in self.view.subviews) {
        if ([v isKindOfClass:[UIButton class]] && CGRectGetWidth(v.frame) == 56) {
            v.frame = CGRectMake(16, 60, 56, 34);
        }
    }
}

- (void)restart { [_board newGame]; }

@end

#pragma mark - 扩展入口

@interface MTDemoExt : NSObject <MTExtV2Extension>
@end

@implementation MTDemoExt

- (UIViewController *)mt_makePageForItem:(NSString *)itemID context:(NSDictionary *)ctx {
    if ([itemID isEqualToString:@"files"]) {
        NSString *p = ctx[@"path"];
        if (![p isKindOfClass:[NSString class]] || ![[NSFileManager defaultManager] fileExistsAtPath:p]) p = @"/var/mobile";
        return [[MTDemoFilesVC alloc] initWithPath:p];
    }
    if ([itemID isEqualToString:@"zip"])   return [MTDemoZipVC new];
    if ([itemID isEqualToString:@"caps"])  return [MTDemoCapsVC new];
    if ([itemID isEqualToString:@"threed"]) return [MTDemo3DVC new];
    if ([itemID isEqualToString:@"download"]) return [MTDemoDownloadVC new];
    if ([itemID isEqualToString:@"term"])  return [MTDemoTermVC new];
    if ([itemID isEqualToString:@"g2048"]) return [MT2048ViewController new];
    if ([itemID isEqualToString:@"lab"])   return [MTDemoLabVC new];
    return [MTDemoHomeVC new];
}

- (UIViewController *)mt_makeEditorForPath:(NSString *)path {
    if (!path.length) return nil;
    NSArray *okExts = @[@"md", @"markdown", @"txt"];
    if (![okExts containsObject:path.pathExtension.lowercaseString]) return nil;
    return [[MTDemoEditorVC alloc] initWithPath:path];
}

@end

id<MTExtV2Extension> MTCreateExtension(void) {
    return [MTDemoExt new];
}
