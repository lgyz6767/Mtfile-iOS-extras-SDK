#import <UIKit/UIKit.h>

@protocol MTExtV2Extension <NSObject>
- (UIViewController *)mt_makePageForItem:(NSString *)itemID context:(NSDictionary *)ctx;
@optional
- (UIViewController *)mt_makeEditorForPath:(NSString *)path;
@end

static id MTCls(NSString *n) { return NSClassFromString(n); }

static UIColor *MTColor(NSString *sel, UIColor *fb) {
    id cls = MTCls(@"MTTheme");
    SEL s = NSSelectorFromString(sel);
    if (![cls respondsToSelector:s]) return fb;
    IMP imp = [cls methodForSelector:s];
    UIColor *(*fn)(id, SEL) = (void *)imp;
    return fn(cls, s) ?: fb;
}

@interface MTExtTemplate : NSObject <MTExtV2Extension>
@end

@implementation MTExtTemplate

- (UIViewController *)mt_makePageForItem:(NSString *)itemID context:(NSDictionary *)ctx {
    UIViewController *vc = [UIViewController new];
    vc.edgesForExtendedLayout = UIRectEdgeNone;
    vc.view.backgroundColor = MTColor(@"bg", [UIColor colorWithWhite:0.09 alpha:1]);

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 24, vc.view.bounds.size.width - 32, 28)];
    title.font = [UIFont boldSystemFontOfSize:20];
    title.textColor = MTColor(@"text", UIColor.whiteColor);
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    title.text = [itemID isEqualToString:@"about"] ? @"关于" : @"主页";
    [vc.view addSubview:title];

    UILabel *body = [[UILabel alloc] initWithFrame:CGRectMake(16, 64, vc.view.bounds.size.width - 32, 120)];
    body.numberOfLines = 0;
    body.font = [UIFont systemFontOfSize:14];
    body.textColor = MTColor(@"textDim", [UIColor colorWithWhite:0.62 alpha:1]);
    body.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    body.text = [itemID isEqualToString:@"about"]
        ? @"这是一个最小扩展。把 manifest.json 的 id/name/sidebar 改掉，\n然后在 build.sh 里编译、ldid 签名，打成 zip 装进 MTFile。"
        : @"在这里画你自己的界面。\n宿主类（MTTheme / MTAlertCenter / MTMaterialRipple）都能用 NSClassFromString 拿到。";
    [vc.view addSubview:body];
    return vc;
}

@end

id<MTExtV2Extension> MTCreateExtension(void) { return [MTExtTemplate new]; }
