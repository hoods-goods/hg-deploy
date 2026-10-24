#import "HGWiFi.h"
#import "HGShell.h"
#import <CoreWLAN/CoreWLAN.h>
#include <ifaddrs.h>
#include <arpa/inet.h>
#include <net/if.h>

@implementation HGWiFi

+ (CWInterface *)interface {
    Class clientClass = NSClassFromString(@"CWWiFiClient");
    if (!clientClass) return nil;
    CWWiFiClient *client = [(id)clientClass sharedWiFiClient];
    return client.interface;
}

+ (NSString *)currentNetwork {
    return [[self interface] ssid];
}

+ (NSString *)ipAddress {
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return nil;
    NSString *found = nil;
    for (struct ifaddrs *a = list; a; a = a->ifa_next) {
        if (!a->ifa_addr || a->ifa_addr->sa_family != AF_INET) continue;
        if (!(a->ifa_flags & IFF_UP) || (a->ifa_flags & IFF_LOOPBACK)) continue;
        char buf[INET_ADDRSTRLEN];
        struct sockaddr_in *sin = (struct sockaddr_in *)a->ifa_addr;
        if (!inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf))) continue;
        NSString *ip = [NSString stringWithUTF8String:buf];
        if ([ip hasPrefix:@"169.254."] || [ip hasPrefix:@"127."]) continue;
        found = ip;
        break;
    }
    freeifaddrs(list);
    return found;
}

+ (NSString *)joinNetwork:(NSString *)ssid password:(NSString *)password {
    if (ssid.length == 0) return @"No Wi-Fi network set.";
    NSString *coreWLANError = nil;
    CWInterface *iface = [self interface];
    if (iface) {
        NSError *err = nil;
        if (!iface.powerOn) [iface setPower:YES error:&err];
        if ([iface.ssid isEqualToString:ssid]) return nil;
        // Scanning right after power-on often comes back empty; try a few times.
        CWNetwork *network = nil;
        for (int i = 0; i < 3 && !network; i++) {
            NSSet *found = [iface scanForNetworksWithName:ssid error:&err];
            for (CWNetwork *n in found) {
                // Newer macOS can hide SSIDs from scan results; a directed scan
                // only returns matches, so a nil name still means our network.
                if (!n.ssid || [n.ssid isEqualToString:ssid]) { network = n; break; }
            }
            if (!network) [NSThread sleepForTimeInterval:2.0];
        }
        if (network) {
            err = nil;
            if ([iface associateToNetwork:network password:(password.length ? password : nil) error:&err]) return nil;
            coreWLANError = err.localizedDescription ?: @"couldn't join";
        } else {
            coreWLANError = [NSString stringWithFormat:@"“%@” wasn't found%@", ssid,
                             err ? [@": " stringByAppendingString:err.localizedDescription] : @""];
        }
    } else {
        coreWLANError = @"no Wi-Fi interface (or CoreWLAN isn't in this Recovery)";
    }

    // Fallback: networksetup, when this Recovery has it.
    NSString *ns = @"/usr/sbin/networksetup";
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:ns]) {
        int status = 0;
        NSString *ports = [HGShell run:ns args:@[@"-listallhardwareports"] status:&status];
        NSString *device = nil;
        NSArray *lines = [ports componentsSeparatedByString:@"\n"];
        for (NSUInteger i = 0; i + 1 < lines.count; i++) {
            if ([lines[i] rangeOfString:@"Wi-Fi"].location != NSNotFound || [lines[i] rangeOfString:@"AirPort"].location != NSNotFound) {
                NSString *d = lines[i + 1];
                if ([d hasPrefix:@"Device: "]) { device = [d substringFromIndex:8]; break; }
            }
        }
        if (device) {
            NSMutableArray *args = [NSMutableArray arrayWithObjects:@"-setairportnetwork", device, ssid, nil];
            if (password.length) [args addObject:password];
            NSString *out = [HGShell run:ns args:args status:&status];
            out = [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            // networksetup exits 0 even on failure and prints the reason instead.
            if (status == 0 && out.length == 0) return nil;
            return [NSString stringWithFormat:@"%@; networksetup: %@", coreWLANError, out.length ? out : @"failed"];
        }
    }
    return coreWLANError;
}

@end
