#import "HGSystem.h"
#import "HGShell.h"
#import <IOKit/IOKitLib.h>
#include <sys/sysctl.h>

static NSString *const kDiskutil = @"/usr/sbin/diskutil";

NSComparisonResult HGCompareVersions(NSString *a, NSString *b) {
    return [(a ?: @"0") compare:(b ?: @"0") options:NSNumericSearch];
}

NSString *HGMajorVersion(NSString *version) {
    NSArray *parts = [version componentsSeparatedByString:@"."];
    if (parts.count == 0 || [parts[0] length] == 0) return nil;
    if ([parts[0] isEqualToString:@"10"] && parts.count > 1) {
        return [NSString stringWithFormat:@"10.%@", parts[1]];
    }
    return parts[0];
}

static NSString *HGSysctlString(const char *name) {
    size_t len = 0;
    if (sysctlbyname(name, NULL, &len, NULL, 0) != 0 || len == 0) return nil;
    char *buf = malloc(len);
    if (!buf) return nil;
    NSString *s = nil;
    if (sysctlbyname(name, buf, &len, NULL, 0) == 0) s = [NSString stringWithUTF8String:buf];
    free(buf);
    return s;
}

#pragma mark - HGMac

@implementation HGMac

+ (instancetype)currentWithModelsFile:(NSString *)path {
    HGMac *m = [[HGMac alloc] init];
    m.modelIdentifier = HGSysctlString("hw.model") ?: @"Unknown";
    m.cpu = HGSysctlString("machdep.cpu.brand_string") ?: @"";
    uint64_t mem = 0; size_t len = sizeof(mem);
    if (sysctlbyname("hw.memsize", &mem, &len, NULL, 0) == 0) m.memoryBytes = mem;

    io_service_t platform = IOServiceGetMatchingService(MACH_PORT_NULL, IOServiceMatching("IOPlatformExpertDevice"));
    if (platform) {
        CFTypeRef serial = IORegistryEntryCreateCFProperty(platform, CFSTR("IOPlatformSerialNumber"), kCFAllocatorDefault, 0);
        if (serial) {
            if (CFGetTypeID(serial) == CFStringGetTypeID()) m.serial = (__bridge NSString *)serial;
            CFRelease(serial);
        }
        IOObjectRelease(platform);
    }
    if (!m.serial) m.serial = @"UNKNOWN";

    NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
    m.recoveryVersion = v.patchVersion
        ? [NSString stringWithFormat:@"%ld.%ld.%ld", (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion]
        : [NSString stringWithFormat:@"%ld.%ld", (long)v.majorVersion, (long)v.minorVersion];

#if defined(__x86_64__)
    m.architecture = @"x86_64";
    // Running under Rosetta would mean an Apple silicon Mac.
    int translated = 0; size_t tlen = sizeof(translated);
    if (sysctlbyname("sysctl.proc_translated", &translated, &tlen, NULL, 0) == 0 && translated == 1) m.architecture = @"arm64";
#else
    m.architecture = @"arm64";
#endif

    NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
    NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if ([json isKindOfClass:[NSDictionary class]]) {
        m.osNames = json[@"osNames"];
        NSDictionary *models = json[@"models"];
        if ([models isKindOfClass:[NSDictionary class]]) m.modelInfo = models[m.modelIdentifier];
    }
    if (!m.osNames) {
        m.osNames = @{@"10.13": @"High Sierra", @"10.14": @"Mojave", @"10.15": @"Catalina", @"11": @"Big Sur",
                      @"12": @"Monterey", @"13": @"Ventura", @"14": @"Sonoma", @"15": @"Sequoia", @"26": @"Tahoe"};
    }
    return m;
}

- (NSString *)displayName { return self.modelInfo[@"name"] ?: self.modelIdentifier; }
- (NSString *)minOS { return self.modelInfo[@"min"]; }
- (NSString *)maxOS { return self.modelInfo[@"max"]; }
- (NSString *)note { return self.modelInfo[@"note"]; }

- (NSString *)osName:(NSString *)major {
    NSString *name = self.osNames[major];
    return name ? [NSString stringWithFormat:@"macOS %@ %@", name, major] : [NSString stringWithFormat:@"macOS %@", major];
}

- (BOOL)isVirtualMachine {
    NSString *m = self.modelIdentifier;
    return [m hasPrefix:@"VMware"] || [m hasPrefix:@"Parallels"] || [m hasPrefix:@"VirtualBox"];
}

- (BOOL)supports:(NSString *)major {
    if (!self.modelInfo) return YES;
    return HGCompareVersions(major, self.minOS) != NSOrderedAscending &&
           HGCompareVersions(major, self.maxOS) != NSOrderedDescending;
}

@end

#pragma mark - Disks

@implementation HGDisk
- (NSString *)label {
    return [NSString stringWithFormat:@"%@ — %@ — %@%@", self.identifier, self.mediaName ?: @"Disk",
            [HGDisks formatBytes:self.size], self.solidState ? @" (SSD)" : @" (hard drive)"];
}
@end

@implementation HGVolume
- (NSString *)label {
    return [NSString stringWithFormat:@"%@ (%@)", self.name, self.identifier];
}
@end

@implementation HGDisks

+ (NSString *)formatBytes:(unsigned long long)bytes {
    double gb = bytes / 1000.0 / 1000.0 / 1000.0;
    if (gb >= 1000) return [NSString stringWithFormat:@"%.1f TB", gb / 1000.0];
    return [NSString stringWithFormat:@"%.0f GB", gb];
}

+ (NSDictionary *)info:(NSString *)identifier {
    id p = [HGShell plist:kDiskutil args:@[@"info", @"-plist", identifier]];
    return [p isKindOfClass:[NSDictionary class]] ? p : nil;
}

+ (NSString *)wholeDiskForPath:(NSString *)path {
    return [self info:path][@"ParentWholeDisk"];
}

+ (BOOL)infoIsInternalPhysical:(NSDictionary *)info {
    if (!info) return NO;
    if (![info[@"Internal"] boolValue]) return NO;
    NSString *bus = info[@"BusProtocol"] ?: @"";
    if ([bus isEqualToString:@"Disk Image"]) return NO;
    NSString *vp = info[@"VirtualOrPhysical"] ?: @"";
    if ([vp isEqualToString:@"Virtual"]) return NO;
    return YES;
}

+ (NSArray *)internalDisksExcluding:(NSString *)drivePath {
    NSString *driveDisk = drivePath ? [self wholeDiskForPath:drivePath] : nil;
    NSDictionary *list = [HGShell plist:kDiskutil args:@[@"list", @"-plist"]];
    NSMutableArray *disks = [NSMutableArray array];
    for (NSString *ident in list[@"WholeDisks"]) {
        if (driveDisk && [ident isEqualToString:driveDisk]) continue;
        NSDictionary *info = [self info:ident];
        if (![self infoIsInternalPhysical:info]) continue;
        HGDisk *d = [[HGDisk alloc] init];
        d.identifier = ident;
        d.mediaName = info[@"MediaName"] ?: info[@"IORegistryEntryName"];
        d.size = [(info[@"TotalSize"] ?: info[@"Size"]) unsignedLongLongValue];
        d.solidState = [info[@"SolidState"] boolValue];
        d.busProtocol = info[@"BusProtocol"];
        [disks addObject:d];
    }
    return disks;
}

+ (NSArray *)internalVolumesExcluding:(NSString *)drivePath {
    NSDictionary *list = [HGShell plist:kDiskutil args:@[@"list", @"-plist"]];
    NSSet *skipNames = [NSSet setWithArray:@[@"Preboot", @"Recovery", @"VM", @"Update", @"EFI",
                                             @"macOS Base System", @"OS X Base System", @"Mac OS X Base System"]];
    NSMutableArray *volumes = [NSMutableArray array];
    for (NSDictionary *entry in list[@"AllDisksAndPartitions"]) {
        NSMutableArray *candidates = [NSMutableArray array];
        if ([entry[@"Partitions"] isKindOfClass:[NSArray class]]) [candidates addObjectsFromArray:entry[@"Partitions"]];
        if ([entry[@"APFSVolumes"] isKindOfClass:[NSArray class]]) [candidates addObjectsFromArray:entry[@"APFSVolumes"]];
        for (NSDictionary *v in candidates) {
            NSString *mp = v[@"MountPoint"];
            NSString *name = v[@"VolumeName"];
            if (!mp.length || !name.length) continue;
            if (![mp hasPrefix:@"/Volumes/"]) continue;
            if (drivePath && [mp isEqualToString:drivePath]) continue;
            if ([skipNames containsObject:name] || [name hasSuffix:@" - Data"]) continue;
            NSDictionary *info = [self info:v[@"DeviceIdentifier"]];
            if (!info || ![info[@"Internal"] boolValue]) continue;
            if ([info[@"BusProtocol"] isEqualToString:@"Disk Image"]) continue;
            HGVolume *vol = [[HGVolume alloc] init];
            vol.identifier = v[@"DeviceIdentifier"];
            vol.name = name;
            vol.mountPoint = mp;
            [volumes addObject:vol];
        }
    }
    return volumes;
}

+ (BOOL)identifier:(NSString *)ident isOnDisks:(NSArray *)disks {
    for (NSString *d in disks) {
        if ([ident isEqualToString:d] || [ident hasPrefix:[d stringByAppendingString:@"s"]]) return YES;
    }
    return NO;
}

+ (NSString *)mountPointForVolumeNamed:(NSString *)name onDisks:(NSArray *)diskIdentifiers {
    NSDictionary *list = [HGShell plist:kDiskutil args:@[@"list", @"-plist"]];
    for (NSDictionary *entry in list[@"AllDisksAndPartitions"]) {
        // An APFS container (synthesized disk) lists the physical partitions it lives on.
        BOOL entryOnTarget = [self identifier:(entry[@"DeviceIdentifier"] ?: @"") isOnDisks:diskIdentifiers];
        for (NSDictionary *store in entry[@"APFSPhysicalStores"]) {
            if ([self identifier:(store[@"DeviceIdentifier"] ?: @"") isOnDisks:diskIdentifiers]) entryOnTarget = YES;
        }
        NSMutableArray *candidates = [NSMutableArray array];
        if ([entry[@"Partitions"] isKindOfClass:[NSArray class]]) [candidates addObjectsFromArray:entry[@"Partitions"]];
        if ([entry[@"APFSVolumes"] isKindOfClass:[NSArray class]]) [candidates addObjectsFromArray:entry[@"APFSVolumes"]];
        for (NSDictionary *v in candidates) {
            if (![v[@"VolumeName"] isEqualToString:name]) continue;
            NSString *mp = v[@"MountPoint"];
            if (!mp.length) continue;
            BOOL onTarget = entryOnTarget || [self identifier:(v[@"DeviceIdentifier"] ?: @"") isOnDisks:diskIdentifiers];
            if (!onTarget) {
                // Fall back to asking diskutil about the volume itself.
                NSDictionary *info = [self info:v[@"DeviceIdentifier"]];
                if ([self identifier:(info[@"ParentWholeDisk"] ?: @"") isOnDisks:diskIdentifiers]) onTarget = YES;
                for (NSDictionary *store in info[@"APFSPhysicalStores"]) {
                    if ([self identifier:(store[@"APFSPhysicalStore"] ?: @"") isOnDisks:diskIdentifiers]) onTarget = YES;
                }
            }
            if (onTarget) return mp;
        }
    }
    return nil;
}

@end

#pragma mark - Installers

@implementation HGInstaller

- (NSString *)title {
    NSString *base = [self.version isEqualToString:self.major] || !self.version
        ? [self majorTitle] : [NSString stringWithFormat:@"%@ %@", [self nameOnly], self.version];
    if (self.build.length) base = [base stringByAppendingFormat:@" (%@)", self.build];
    if (self.beta) base = [base stringByAppendingString:@" beta"];
    return base;
}

static NSDictionary *gOSNames;

- (NSString *)nameOnly {
    NSString *n = gOSNames[self.major];
    return n ? [NSString stringWithFormat:@"macOS %@", n] : @"macOS";
}

- (NSString *)majorTitle {
    return [NSString stringWithFormat:@"%@ %@", [self nameOnly], self.major];
}

- (NSString *)startosinstall {
    return [self.path stringByAppendingPathComponent:@"Contents/Resources/startosinstall"];
}

- (NSString *)problem {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm isExecutableFileAtPath:[self startosinstall]]) return @"startosinstall is missing";
    NSString *shared = [self.path stringByAppendingPathComponent:@"Contents/SharedSupport"];
    BOOL modern = HGCompareVersions(self.major, @"11") != NSOrderedAscending;
    if (modern) {
        if (![fm fileExistsAtPath:[shared stringByAppendingPathComponent:@"SharedSupport.dmg"]])
            return @"SharedSupport.dmg is missing (incomplete download)";
    } else {
        if (![fm fileExistsAtPath:[shared stringByAppendingPathComponent:@"InstallESD.dmg"]])
            return @"InstallESD.dmg is missing (incomplete download)";
    }
    return nil;
}

+ (NSString *)majorFromName:(NSString *)name osNames:(NSDictionary *)osNames {
    // Longest names first so "High Sierra" can't be shadowed by a shorter match.
    NSArray *keys = [osNames.allKeys sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        return [@([osNames[b] length]) compare:@([osNames[a] length])];
    }];
    for (NSString *major in keys) {
        if ([name rangeOfString:[@" " stringByAppendingString:osNames[major]]].location != NSNotFound) return major;
    }
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"macOS (1[0-9]|2[0-9])\\b" options:0 error:NULL];
    NSTextCheckingResult *m = [re firstMatchInString:name options:0 range:NSMakeRange(0, name.length)];
    if (m) return [name substringWithRange:[m rangeAtIndex:1]];
    return nil;
}

+ (NSArray *)installersOnDrive:(NSString *)drive osNames:(NSDictionary *)osNames {
    gOSNames = osNames;
    NSFileManager *fm = [NSFileManager defaultManager];

    // installers.json, written by HG Deploy Builder, has exact versions and builds.
    NSMutableDictionary *manifest = [NSMutableDictionary dictionary];
    NSData *mdata = [NSData dataWithContentsOfFile:[drive stringByAppendingPathComponent:@"HGDeploy/installers.json"]];
    NSDictionary *mjson = mdata ? [NSJSONSerialization JSONObjectWithData:mdata options:0 error:NULL] : nil;
    if ([mjson isKindOfClass:[NSDictionary class]]) {
        for (NSDictionary *e in mjson[@"installers"]) {
            if ([e isKindOfClass:[NSDictionary class]] && e[@"path"]) manifest[[e[@"path"] lastPathComponent]] = e;
        }
    }

    NSMutableArray *found = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSString *dir in @[@"Installers", @"Applications", @""]) {
        NSString *full = dir.length ? [drive stringByAppendingPathComponent:dir] : drive;
        for (NSString *item in [fm contentsOfDirectoryAtPath:full error:NULL]) {
            if (![item hasPrefix:@"Install "] || ![item hasSuffix:@".app"]) continue;
            NSString *path = [full stringByAppendingPathComponent:item];
            if ([seen containsObject:path]) continue;
            [seen addObject:path];

            HGInstaller *inst = [[HGInstaller alloc] init];
            inst.path = path;
            inst.appName = item;
            NSDictionary *m = manifest[item];
            NSString *version = m[@"version"];
            NSString *build = m[@"build"];

            if (!version) {
                // Older installers carry their version in InstallInfo.plist.
                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                    [path stringByAppendingPathComponent:@"Contents/SharedSupport/InstallInfo.plist"]];
                version = info[@"System Image Info"][@"version"];
            }
            if (!version) {
                NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\\b(1[0-9]|2[0-9])\\.([0-9]+)(\\.[0-9]+)?" options:0 error:NULL];
                NSTextCheckingResult *r = [re firstMatchInString:item options:0 range:NSMakeRange(0, item.length)];
                if (r) version = [item substringWithRange:r.range];
            }
            if (!build) {
                NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"-([0-9]{2}[A-Z][0-9]+[a-z]?)" options:0 error:NULL];
                NSTextCheckingResult *r = [re firstMatchInString:item options:0 range:NSMakeRange(0, item.length)];
                if (r) build = [item substringWithRange:[r rangeAtIndex:1]];
            }
            NSString *major = m[@"major"] ?: [self majorFromName:item osNames:osNames] ?: HGMajorVersion(version);
            if (!major) continue;   // not a macOS installer we understand
            inst.major = major;
            inst.version = version ?: major;
            inst.build = build;
            inst.beta = [m[@"beta"] boolValue] || [item rangeOfString:@"beta" options:NSCaseInsensitiveSearch].location != NSNotFound;
            [found addObject:inst];
        }
    }
    [found sortUsingComparator:^NSComparisonResult(HGInstaller *a, HGInstaller *b) {
        NSComparisonResult r = HGCompareVersions(b.version, a.version);
        if (r == NSOrderedSame) r = [@(a.beta) compare:@(b.beta)];
        return r;
    }];
    return found;
}

@end
