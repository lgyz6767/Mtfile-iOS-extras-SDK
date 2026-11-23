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
