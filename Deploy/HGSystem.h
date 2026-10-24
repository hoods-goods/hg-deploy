// What HG Deploy knows about the Mac, its disks, and the installers on the drive.
#import <Foundation/Foundation.h>

/// Compares macOS versions numerically ("10.13" < "10.15.7" < "11" < "26").
NSComparisonResult HGCompareVersions(NSString *a, NSString *b);

/// "10.15.7" -> "10.15", "15.7.1" -> "15".
NSString *HGMajorVersion(NSString *version);

#pragma mark - This Mac

@interface HGMac : NSObject
@property (nonatomic, copy) NSString *modelIdentifier;   // MacBookPro15,1
@property (nonatomic, copy) NSString *serial;
@property (nonatomic, copy) NSString *cpu;
@property (nonatomic, assign) unsigned long long memoryBytes;
@property (nonatomic, copy) NSString *recoveryVersion;   // the OS we're running on (Recovery)
@property (nonatomic, copy) NSString *architecture;      // x86_64 / arm64
/// Entry from models.json, or nil for a Mac that isn't in the list.
@property (nonatomic, copy) NSDictionary *modelInfo;
/// "10.13" -> "High Sierra"
@property (nonatomic, copy) NSDictionary *osNames;

+ (instancetype)currentWithModelsFile:(NSString *)path;
- (NSString *)displayName;           // "MacBook Pro (15-inch, 2018 / 2019)" or the identifier
- (NSString *)minOS;                 // nil when unknown
- (NSString *)maxOS;                 // nil when unknown
- (NSString *)note;                  // optional model note
- (NSString *)osName:(NSString *)major;   // "macOS Sequoia 15"
- (BOOL)supports:(NSString *)major;  // YES when unknown model
- (BOOL)isVirtualMachine;
@end

#pragma mark - Disks

@interface HGDisk : NSObject
@property (nonatomic, copy) NSString *identifier;   // disk0
@property (nonatomic, copy) NSString *mediaName;
@property (nonatomic, assign) unsigned long long size;
@property (nonatomic, assign) BOOL solidState;
@property (nonatomic, copy) NSString *busProtocol;
- (NSString *)label;
@end

@interface HGVolume : NSObject
@property (nonatomic, copy) NSString *identifier;   // disk1s1
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *mountPoint;
- (NSString *)label;
@end

@interface HGDisks : NSObject
/// Internal physical disks (not disk images, not the deploy drive).
+ (NSArray *)internalDisksExcluding:(NSString *)drivePath;
/// Mounted internal volumes that could take an in-place install.
+ (NSArray *)internalVolumesExcluding:(NSString *)drivePath;
/// The mount point of the volume called `name` that lives on one of `disks` (after an erase).
+ (NSString *)mountPointForVolumeNamed:(NSString *)name onDisks:(NSArray *)diskIdentifiers;
/// Whole-disk identifier of the volume at `path` (to keep the deploy drive out of lists).
+ (NSString *)wholeDiskForPath:(NSString *)path;
+ (NSString *)formatBytes:(unsigned long long)bytes;
@end

#pragma mark - Installers

@interface HGInstaller : NSObject
@property (nonatomic, copy) NSString *path;      // full path to Install macOS ....app
@property (nonatomic, copy) NSString *appName;   // Install macOS Sequoia.app
@property (nonatomic, copy) NSString *major;     // "15", "10.15"
@property (nonatomic, copy) NSString *version;   // "15.7.1" (may equal major when unknown)
@property (nonatomic, copy) NSString *build;     // may be nil
@property (nonatomic, assign) BOOL beta;
- (NSString *)title;                             // macOS Sequoia 15.7.1 (24G231)
- (NSString *)startosinstall;
/// nil when the installer looks complete, otherwise what's wrong.
- (NSString *)problem;
/// Installers on the drive, newest first.
+ (NSArray *)installersOnDrive:(NSString *)drive osNames:(NSDictionary *)osNames;
@end
