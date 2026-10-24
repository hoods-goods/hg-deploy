// Joins a Wi-Fi network from Recovery. CoreWLAN is weak-linked: if a
// Recovery doesn't have it, HG Deploy still runs and falls back to
// networksetup when that exists.
#import <Foundation/Foundation.h>

@interface HGWiFi : NSObject
/// Name of the Wi-Fi network the Mac is on, or nil (also nil when macOS hides it).
+ (NSString *)currentNetwork;
/// Turns Wi-Fi on and joins `ssid`. Blocks (call off the main thread). Returns nil on success, else why not.
+ (NSString *)joinNetwork:(NSString *)ssid password:(NSString *)password;
/// The Mac's IPv4 address (not loopback / self-assigned), or nil.
+ (NSString *)ipAddress;
@end
