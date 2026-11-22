#import <UIKit/UIKit.h>
@protocol MTExtV2Extension <NSObject>
- (UIViewController *)mt_makePageForItem:(NSString *)itemID context:(NSDictionary *)ctx;
@optional
- (UIViewController *)mt_makeEditorForPath:(NSString *)path;
@end
typedef id<MTExtV2Extension> (*MTExtV2Factory)(void);
