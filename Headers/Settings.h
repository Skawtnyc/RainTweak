#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface BunnySettingsViewController
    : UIViewController <UITableViewDelegate, UITableViewDataSource>
- (instancetype)initWithVersion:(NSString *)version;
@end

extern id gBridge;

#ifdef __cplusplus
extern "C" {
#endif

void showSettingsSheet(void);

#ifdef __cplusplus
}
#endif