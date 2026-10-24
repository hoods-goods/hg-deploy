#import <Cocoa/Cocoa.h>

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate>
- (instancetype)initWithDrive:(NSString *)drive;
@end
