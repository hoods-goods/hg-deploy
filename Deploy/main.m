// HG Deploy — the window that opens when you run /Volumes/<drive>/run in Recovery.
#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *drive = nil;
        for (int i = 1; i < argc - 1; i++) {
            if (strcmp(argv[i], "--drive") == 0) drive = [NSString stringWithUTF8String:argv[i + 1]];
        }
        if (!drive) {
            // .../<drive>/HGDeploy/HG Deploy.app -> <drive>
            NSString *app = [[NSBundle mainBundle] bundlePath];
            drive = [[app stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
        }
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] initWithDrive:drive];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
    }
    return 0;
}
