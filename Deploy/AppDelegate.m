#import "AppDelegate.h"
#import "HGShell.h"
#import "HGSystem.h"
#import "HGWiFi.h"

static NSString *const kNVRAMKey = @"com.hgcellular.deploy";

#pragma mark - Small view helpers (10.11-safe: no labelWithString:/checkboxWithTitle:)

@interface HGFlippedView : NSView
@end
@implementation HGFlippedView
- (BOOL)isFlipped { return YES; }
@end

static NSTextField *HGLabel(NSString *text, NSRect frame, CGFloat size, BOOL bold) {
    NSTextField *t = [[NSTextField alloc] initWithFrame:frame];
    t.stringValue = text ?: @"";
    t.bezeled = NO;
    t.drawsBackground = NO;
    t.editable = NO;
    t.selectable = NO;
    t.font = bold ? [NSFont boldSystemFontOfSize:size] : [NSFont systemFontOfSize:size];
    t.lineBreakMode = NSLineBreakByTruncatingTail;
    return t;
}

static NSTextField *HGValue(NSRect frame) {
    NSTextField *t = HGLabel(@"", frame, 12, NO);
    t.selectable = YES;
    return t;
}

static NSButton *HGCheckbox(NSString *title, NSRect frame, id target, SEL action) {
    NSButton *b = [[NSButton alloc] initWithFrame:frame];
    [b setButtonType:NSSwitchButton];
    b.title = title;
    b.target = target;
    b.action = action;
    return b;
}

static NSButton *HGPushButton(NSString *title, NSRect frame, id target, SEL action) {
    NSButton *b = [[NSButton alloc] initWithFrame:frame];
    b.bezelStyle = NSRoundedBezelStyle;
    b.title = title;
    b.target = target;
    b.action = action;
    return b;
}

static NSBox *HGSeparator(CGFloat y, CGFloat width) {
    NSBox *box = [[NSBox alloc] initWithFrame:NSMakeRect(20, y, width - 40, 1)];
    box.boxType = NSBoxSeparator;
    return box;
}

static NSString *HGB64(NSString *s) {
    return [[(s ?: @"") dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
}

#pragma mark - AppDelegate

@interface AppDelegate ()
@property (nonatomic, copy) NSString *drive;
@property (nonatomic, copy) NSDictionary *config;
@property (nonatomic, strong) HGMac *mac;
@property (nonatomic, strong) NSArray *installers;
@property (nonatomic, strong) NSArray *disks;
@property (nonatomic, assign) BOOL installing;
@property (nonatomic, assign) BOOL shortNameEdited;
@property (nonatomic, strong) NSFileHandle *logFile;

@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) NSTextField *clockValue;
@property (nonatomic, strong) NSTextField *networkValue;
@property (nonatomic, strong) NSPopUpButton *osPopup;
@property (nonatomic, strong) NSButton *allowUnsupported;
@property (nonatomic, strong) NSTextField *osNote;
@property (nonatomic, strong) NSPopUpButton *diskPopup;
@property (nonatomic, strong) NSButton *eraseCheck;
@property (nonatomic, strong) NSTextField *volumeName;
@property (nonatomic, strong) NSButton *createAccount;
@property (nonatomic, strong) NSTextField *fullName;
@property (nonatomic, strong) NSTextField *shortName;
@property (nonatomic, strong) NSSecureTextField *password;
@property (nonatomic, strong) NSSecureTextField *verify;
@property (nonatomic, strong) NSButton *adminCheck;
@property (nonatomic, strong) NSButton *autoLoginCheck;
@property (nonatomic, strong) NSTextField *computerName;
@property (nonatomic, strong) NSButton *sshCheck;
@property (nonatomic, strong) NSTextView *logView;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSProgressIndicator *progress;
@property (nonatomic, strong) NSButton *installButton;
@property (nonatomic, strong) NSButton *quitButton;
@property (nonatomic, strong) NSButton *restartButton;
@property (nonatomic, strong) NSMutableArray *lockableControls;
@end

@implementation AppDelegate

- (instancetype)initWithDrive:(NSString *)drive {
    if ((self = [super init])) {
        _drive = [drive copy];
        _lockableControls = [NSMutableArray array];
    }
    return self;
}

- (NSString *)deployDir { return [self.drive stringByAppendingPathComponent:@"HGDeploy"]; }

- (NSString *)appVersion {
    return [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"dev";
}

#pragma mark Launch

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [self buildMenu];
    NSString *models = [[NSBundle mainBundle] pathForResource:@"models" ofType:@"json"];
    self.mac = [HGMac currentWithModelsFile:models];
    NSData *cfg = [NSData dataWithContentsOfFile:[[self deployDir] stringByAppendingPathComponent:@"config.json"]];
    id json = cfg ? [NSJSONSerialization JSONObjectWithData:cfg options:0 error:NULL] : nil;
    self.config = [json isKindOfClass:[NSDictionary class]] ? json : @{};

    [self buildWindow];
    [self openLogFile];
    [self log:[NSString stringWithFormat:@"HG Deploy %@ on %@ (%@), serial %@, Recovery %@",
               [self appVersion], self.mac.displayName, self.mac.modelIdentifier, self.mac.serial, self.mac.recoveryVersion]];
    [self log:[NSString stringWithFormat:@"Drive: %@", self.drive]];

    [self reloadInstallers];
    [self reloadDisks];
    [self applyConfig];
    [self updateClock];
    [self connectNetworkInBackground];

    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    if ([self.mac.architecture isEqualToString:@"arm64"]) {
        [self alert:@"This is an Apple silicon Mac" info:@"HG Deploy is for Intel Macs. Use your Apple silicon tool for this one."];
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return YES; }

- (BOOL)windowShouldClose:(NSWindow *)sender { return !self.installing; }

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    return self.installing ? NSTerminateCancel : NSTerminateNow;
}

- (void)buildMenu {
    NSMenu *bar = [[NSMenu alloc] init];
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    [bar addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"HG Deploy"];
    [appMenu addItemWithTitle:@"Quit HG Deploy" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;

    // Without an Edit menu, Command-C / Command-V don't work in text fields.
    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    [bar addItem:editItem];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    [edit addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = edit;
    NSApp.mainMenu = bar;
}

#pragma mark Window

- (void)buildWindow {
    const CGFloat W = 800, H = 700;
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, W, H)
                                              styleMask:NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask
                                                backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"HG Deploy";
    self.window.delegate = self;
    HGFlippedView *v = [[HGFlippedView alloc] initWithFrame:NSMakeRect(0, 0, W, H)];
    self.window.contentView = v;

    [v addSubview:HGLabel(@"HG Deploy", NSMakeRect(20, 14, 300, 28), 20, YES)];
    NSTextField *ver = HGLabel([NSString stringWithFormat:@"Version %@", [self appVersion]], NSMakeRect(W - 220, 22, 200, 18), 11, NO);
    ver.alignment = NSRightTextAlignment;
    ver.textColor = [NSColor secondaryLabelColor];
    [v addSubview:ver];

    // This Mac
    [v addSubview:HGLabel(@"This Mac", NSMakeRect(20, 50, 200, 18), 13, YES)];
    HGMac *m = self.mac;
    NSString *mem = [NSString stringWithFormat:@"%llu GB", m.memoryBytes / 1024 / 1024 / 1024];
    NSString *newest = m.maxOS ? [m osName:m.maxOS] : (m.isVirtualMachine ? @"Virtual machine — any" : @"Unknown model");
    NSArray *rows = @[@[@"Model:", m.displayName, @"Identifier:", m.modelIdentifier],
                      @[@"Serial:", m.serial, @"Memory:", mem],
                      @[@"Processor:", m.cpu, @"Recovery:", [NSString stringWithFormat:@"macOS %@", m.recoveryVersion]],
                      @[@"Newest macOS:", newest, @"Clock:", @""],
                      @[@"Network:", @"Checking…", @"", @""]];
    CGFloat y = 70;
    for (NSArray *row in rows) {
        NSTextField *l1 = HGLabel(row[0], NSMakeRect(20, y, 100, 18), 12, NO);
        l1.textColor = [NSColor secondaryLabelColor];
        [v addSubview:l1];
        NSTextField *v1 = HGValue(NSMakeRect(120, y, 290, 18));
        v1.stringValue = row[1];
        if ([row[0] isEqualToString:@"Newest macOS:"]) v1.font = [NSFont boldSystemFontOfSize:12];
        [v addSubview:v1];
        NSTextField *l2 = HGLabel(row[2], NSMakeRect(420, y, 80, 18), 12, NO);
        l2.textColor = [NSColor secondaryLabelColor];
        [v addSubview:l2];
        NSTextField *v2 = HGValue(NSMakeRect(500, y, 200, 18));
        v2.stringValue = row[3];
        [v addSubview:v2];
        if ([row[2] isEqualToString:@"Clock:"]) {
            self.clockValue = v2;
            NSButton *set = HGPushButton(@"Set…", NSMakeRect(704, y - 2, 76, 22), self, @selector(setClock:));
            [set.cell setControlSize:NSControlSizeSmall];
            set.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
            [v addSubview:set];
            [self.lockableControls addObject:set];
        }
        if ([row[0] isEqualToString:@"Network:"]) {
            v1.frame = NSMakeRect(120, y, 560, 18);
            self.networkValue = v1;
            NSButton *join = HGPushButton(@"Wi-Fi…", NSMakeRect(704, y - 2, 76, 22), self, @selector(joinWiFiClicked:));
            [join.cell setControlSize:NSControlSizeSmall];
            join.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
            [v addSubview:join];
            [self.lockableControls addObject:join];
        }
        y += 19;
    }

    [v addSubview:HGSeparator(168, W)];

    // Install
    [v addSubview:HGLabel(@"Install", NSMakeRect(20, 178, 200, 18), 13, YES)];
    [v addSubview:HGLabel(@"macOS:", NSMakeRect(20, 206, 90, 18), 12, NO)];
    self.osPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(116, 200, 470, 26) pullsDown:NO];
    self.osPopup.autoenablesItems = NO;
    self.osPopup.target = self;
    self.osPopup.action = @selector(osChanged:);
    [v addSubview:self.osPopup];
    self.allowUnsupported = HGCheckbox(@"Allow unsupported", NSMakeRect(600, 203, 180, 20), self, @selector(allowUnsupportedChanged:));
    [v addSubview:self.allowUnsupported];

    self.osNote = HGLabel(@"", NSMakeRect(118, 230, 662, 32), 11, NO);
    self.osNote.lineBreakMode = NSLineBreakByWordWrapping;
    [self.osNote.cell setWraps:YES];
    self.osNote.textColor = [NSColor secondaryLabelColor];
    [v addSubview:self.osNote];

    [v addSubview:HGLabel(@"Disk:", NSMakeRect(20, 272, 90, 18), 12, NO)];
    self.diskPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(116, 266, 470, 26) pullsDown:NO];
    [v addSubview:self.diskPopup];
    self.eraseCheck = HGCheckbox(@"Erase disk first", NSMakeRect(600, 269, 180, 20), self, @selector(eraseChanged:));
    self.eraseCheck.state = NSOnState;
    [v addSubview:self.eraseCheck];

    [v addSubview:HGLabel(@"Volume name:", NSMakeRect(20, 304, 95, 18), 12, NO)];
    self.volumeName = [[NSTextField alloc] initWithFrame:NSMakeRect(118, 301, 230, 22)];
    self.volumeName.stringValue = @"Macintosh HD";
    [v addSubview:self.volumeName];

    [v addSubview:HGSeparator(336, W)];

    // Setup
    [v addSubview:HGLabel(@"Setup", NSMakeRect(20, 346, 200, 18), 13, YES)];
    self.createAccount = HGCheckbox(@"Create an account and skip Setup Assistant", NSMakeRect(18, 370, 400, 20), self, @selector(accountToggled:));
    [v addSubview:self.createAccount];
    NSTextField *saHint = HGLabel(@"Leave off to hand the Mac over at the Setup Assistant (“Hello”) screen.",
                                  NSMakeRect(420, 372, 360, 16), 11, NO);
    saHint.textColor = [NSColor secondaryLabelColor];
    [v addSubview:saHint];

    [v addSubview:HGLabel(@"Full name:", NSMakeRect(40, 402, 80, 18), 12, NO)];
    self.fullName = [[NSTextField alloc] initWithFrame:NSMakeRect(130, 399, 230, 22)];
    self.fullName.delegate = self;
    [v addSubview:self.fullName];
    [v addSubview:HGLabel(@"Account name:", NSMakeRect(380, 402, 100, 18), 12, NO)];
    self.shortName = [[NSTextField alloc] initWithFrame:NSMakeRect(485, 399, 230, 22)];
    self.shortName.delegate = self;
    [v addSubview:self.shortName];

    [v addSubview:HGLabel(@"Password:", NSMakeRect(40, 432, 80, 18), 12, NO)];
    self.password = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(130, 429, 230, 22)];
    [v addSubview:self.password];
    [v addSubview:HGLabel(@"Verify:", NSMakeRect(380, 432, 100, 18), 12, NO)];
    self.verify = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(485, 429, 230, 22)];
    [v addSubview:self.verify];

    self.adminCheck = HGCheckbox(@"Administrator", NSMakeRect(128, 459, 150, 20), nil, NULL);
    self.adminCheck.state = NSOnState;
    [v addSubview:self.adminCheck];
    self.autoLoginCheck = HGCheckbox(@"Log in automatically", NSMakeRect(290, 459, 200, 20), nil, NULL);
    [v addSubview:self.autoLoginCheck];

    [v addSubview:HGLabel(@"Computer name:", NSMakeRect(20, 494, 105, 18), 12, NO)];
    self.computerName = [[NSTextField alloc] initWithFrame:NSMakeRect(130, 491, 230, 22)];
    [self.computerName.cell setPlaceholderString:@"Leave blank for the default"];
    [v addSubview:self.computerName];
    NSTextField *cnHint = HGLabel(@"{serial} and {model} are filled in, e.g. HG-{serial}", NSMakeRect(372, 494, 400, 16), 11, NO);
    cnHint.textColor = [NSColor secondaryLabelColor];
    [v addSubview:cnHint];
    self.sshCheck = HGCheckbox(@"Turn on Remote Login (SSH)", NSMakeRect(128, 520, 300, 20), nil, NULL);
    [v addSubview:self.sshCheck];

    [v addSubview:HGSeparator(550, W)];

    // Log
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 560, W - 40, 76)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    self.logView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, W - 44, 76)];
    self.logView.editable = NO;
    self.logView.font = [NSFont userFixedPitchFontOfSize:10];
    self.logView.autoresizingMask = NSViewWidthSizable;
    scroll.documentView = self.logView;
    [v addSubview:scroll];

    self.statusLabel = HGLabel(@"Ready.", NSMakeRect(20, 646, 440, 18), 12, NO);
    [v addSubview:self.statusLabel];
    self.progress = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 668, 440, 16)];
    self.progress.style = NSProgressIndicatorBarStyle;
    self.progress.indeterminate = NO;
    self.progress.minValue = 0;
    self.progress.maxValue = 100;
    self.progress.hidden = YES;
    [v addSubview:self.progress];

    self.restartButton = HGPushButton(@"Restart", NSMakeRect(470, 650, 95, 32), self, @selector(restart:));
    [v addSubview:self.restartButton];
    self.quitButton = HGPushButton(@"Quit", NSMakeRect(565, 650, 85, 32), self, @selector(quit:));
    [v addSubview:self.quitButton];
    self.installButton = HGPushButton(@"Erase & Install", NSMakeRect(650, 650, 135, 32), self, @selector(install:));
    self.installButton.keyEquivalent = @"\r";
    [v addSubview:self.installButton];

    [self.lockableControls addObjectsFromArray:@[self.osPopup, self.allowUnsupported, self.diskPopup, self.eraseCheck,
        self.volumeName, self.createAccount, self.fullName, self.shortName, self.password, self.verify,
        self.adminCheck, self.autoLoginCheck, self.computerName, self.sshCheck, self.installButton,
        self.quitButton, self.restartButton]];
}

- (void)applyConfig {
    NSDictionary *c = self.config;
    NSDictionary *a = [c[@"account"] isKindOfClass:[NSDictionary class]] ? c[@"account"] : @{};
    self.createAccount.state = [a[@"create"] boolValue] ? NSOnState : NSOffState;
    self.fullName.stringValue = a[@"fullName"] ?: @"";
    self.shortName.stringValue = a[@"shortName"] ?: @"";
    self.shortNameEdited = [a[@"shortName"] length] > 0;
    self.password.stringValue = a[@"password"] ?: @"";
    self.verify.stringValue = a[@"password"] ?: @"";
    if (a[@"admin"]) self.adminCheck.state = [a[@"admin"] boolValue] ? NSOnState : NSOffState;
    self.autoLoginCheck.state = [a[@"autoLogin"] boolValue] ? NSOnState : NSOffState;
    self.computerName.stringValue = c[@"computerName"] ?: @"";
    self.sshCheck.state = [c[@"enableSSH"] boolValue] ? NSOnState : NSOffState;
    if ([c[@"volumeName"] length]) self.volumeName.stringValue = c[@"volumeName"];
    if (c[@"eraseByDefault"] && ![c[@"eraseByDefault"] boolValue]) {
        self.eraseCheck.state = NSOffState;
        [self reloadDisks];
    }
    [self accountToggled:nil];
}

#pragma mark Installers

- (void)reloadInstallers {
    self.installers = [HGInstaller installersOnDrive:self.drive osNames:self.mac.osNames];
    [self log:[NSString stringWithFormat:@"Found %lu installer(s) on the drive", (unsigned long)self.installers.count]];
    [self rebuildOSMenu];
}

/// Why the booted Recovery can't run this installer, or nil. Twocanoes' tested rules
/// (MDS): an installer older than the Recovery fails, and a Recovery older than
/// Big Sur can install up to Big Sur but not Monterey or later.
- (NSString *)recoveryProblem:(HGInstaller *)i {
    NSString *rec = HGMajorVersion(self.mac.recoveryVersion);
    if (!rec) return nil;
    if (HGCompareVersions(i.major, rec) == NSOrderedAscending) return @"older than this Recovery";
    if (HGCompareVersions(rec, @"11") == NSOrderedAscending && HGCompareVersions(i.major, @"12") != NSOrderedAscending)
        return @"needs Recovery from Big Sur or later";
    return nil;
}

- (HGInstaller *)recommendedInstaller {
    HGInstaller *betaPick = nil;
    for (HGInstaller *i in self.installers) {
        if (![self.mac supports:i.major] || [i problem] || [self recoveryProblem:i]) continue;
        if (!i.beta) return i;
        if (!betaPick) betaPick = i;
    }
    return betaPick;
}

- (void)rebuildOSMenu {
    [self.osPopup removeAllItems];
    HGInstaller *pick = [self recommendedInstaller];
    BOOL allow = self.allowUnsupported.state == NSOnState;
    for (HGInstaller *i in self.installers) {
        NSString *recProblem = [self recoveryProblem:i];
        BOOL ok = [self.mac supports:i.major] && !recProblem;
        NSString *problem = [i problem];
        NSString *title = [i title];
        if (i == pick) title = [title stringByAppendingString:@"  — recommended"];
        else if (problem) title = [title stringByAppendingFormat:@"  — %@", problem];
        else if (![self.mac supports:i.major]) title = [title stringByAppendingString:@"  — not supported on this Mac"];
        else if (recProblem) title = [title stringByAppendingFormat:@"  — %@", recProblem];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:NULL keyEquivalent:@""];
        item.representedObject = i;
        item.enabled = !problem && (ok || allow);
        [self.osPopup.menu addItem:item];
    }
    if (self.installers.count == 0) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"No installers found on this drive" action:NULL keyEquivalent:@""];
        item.enabled = NO;
        [self.osPopup.menu addItem:item];
    }
    if (pick) [self.osPopup selectItemAtIndex:[self.osPopup indexOfItemWithRepresentedObject:pick]];
    [self osChanged:nil];
}

- (HGInstaller *)selectedInstaller {
    NSMenuItem *item = self.osPopup.selectedItem;
    return item.enabled ? item.representedObject : nil;
}

- (void)osChanged:(id)sender {
    HGMac *m = self.mac;
    HGInstaller *pick = [self recommendedInstaller];
    HGInstaller *sel = [self selectedInstaller];
    NSMutableArray *notes = [NSMutableArray array];
    if (!m.modelInfo) {
        [notes addObject:[NSString stringWithFormat:@"%@ isn't in the model list, so every installer is allowed. Check compatibility yourself.", m.modelIdentifier]];
    } else if (!pick) {
        [notes addObject:[NSString stringWithFormat:@"None of the installers on this drive work on this Mac. It runs %@ through %@.",
                          [m osName:m.minOS], [m osName:m.maxOS]]];
    } else if (HGCompareVersions(pick.major, m.maxOS) == NSOrderedAscending) {
        [notes addObject:[NSString stringWithFormat:@"This Mac can run %@, but the newest on this drive is %@. Add it with HG Deploy Builder.",
                          [m osName:m.maxOS], [pick title]]];
    } else {
        [notes addObject:[NSString stringWithFormat:@"%@ is the newest macOS this Mac supports.", [m osName:m.maxOS]]];
    }
    if (m.note) [notes addObject:m.note];
    // Recovery limits: say which startup keys get a Recovery that can install what's blocked.
    NSString *rec = HGMajorVersion(m.recoveryVersion);
    BOOL olderBlocked = NO, newerBlocked = NO;
    for (HGInstaller *i in self.installers) {
        if (![m supports:i.major] || [i problem]) continue;
        NSString *rp = [self recoveryProblem:i];
        if ([rp hasPrefix:@"older"]) olderBlocked = YES;
        else if (rp) newerBlocked = YES;
    }
    if (newerBlocked) {
        [notes insertObject:[NSString stringWithFormat:@"This Recovery (macOS %@) can't install Monterey or later. For a newer macOS, restart holding Option-Command-R (Internet Recovery).",
                             m.recoveryVersion] atIndex:0];
    }
    if (olderBlocked) {
        [notes addObject:[NSString stringWithFormat:@"Versions older than this Recovery (macOS %@) won't install; for one of those, restart holding Shift-Option-Command-R.", rec]];
    }
    NSString *selRec = sel ? [self recoveryProblem:sel] : nil;
    if (selRec) [notes insertObject:[NSString stringWithFormat:@"⚠️ The selected version is %@, so the install will likely fail.", selRec] atIndex:0];
    if (sel && m.modelInfo && ![m supports:sel.major]) [notes insertObject:@"⚠️ The selected version isn't supported on this Mac." atIndex:0];
    if (sel.beta) [notes addObject:@"The selected installer is a beta."];
    self.osNote.stringValue = [notes componentsJoinedByString:@" "];
    self.osNote.textColor = (sel && m.modelInfo && ![m supports:sel.major]) || selRec || !pick || newerBlocked
        ? [NSColor systemOrangeColor] : [NSColor secondaryLabelColor];
}

- (void)allowUnsupportedChanged:(id)sender {
    HGInstaller *current = self.osPopup.selectedItem.representedObject;
    [self rebuildOSMenu];
    NSInteger idx = current ? [self.osPopup indexOfItemWithRepresentedObject:current] : -1;
    if (idx >= 0 && [self.osPopup itemAtIndex:idx].enabled) [self.osPopup selectItemAtIndex:idx];
    [self osChanged:nil];
}

#pragma mark Disks

- (void)eraseChanged:(id)sender {
    [self reloadDisks];
    self.installButton.title = self.eraseCheck.state == NSOnState ? @"Erase & Install" : @"Install";
}

- (void)reloadDisks {
    [self.diskPopup removeAllItems];
    if (self.eraseCheck.state == NSOnState) {
        NSArray *disks = [HGDisks internalDisksExcluding:self.drive];
        self.disks = disks;
        // A Fusion Drive is an SSD plus a hard drive that work as one disk.
        HGDisk *ssd = nil, *hdd = nil;
        for (HGDisk *d in disks) { if (d.solidState) ssd = ssd ?: d; else hdd = hdd ?: d; }
        if (ssd && hdd && ssd.size < 300ULL * 1000 * 1000 * 1000) {
            NSMenuItem *f = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Fusion Drive (%@ + %@) — reset and erase both",
                                                               ssd.identifier, hdd.identifier] action:NULL keyEquivalent:@""];
            f.representedObject = @{@"kind": @"fusion", @"disks": @[ssd.identifier, hdd.identifier]};
            [self.diskPopup.menu addItem:f];
        }
        for (HGDisk *d in disks) {
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[d label] action:NULL keyEquivalent:@""];
            item.representedObject = @{@"kind": @"disk", @"disk": d};
            [self.diskPopup.menu addItem:item];
        }
        if (disks.count == 0) [self.diskPopup addItemWithTitle:@"No internal disk found"];
    } else {
        NSArray *vols = [HGDisks internalVolumesExcluding:self.drive];
        for (HGVolume *vol in vols) {
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[vol label] action:NULL keyEquivalent:@""];
            item.representedObject = @{@"kind": @"volume", @"volume": vol};
            [self.diskPopup.menu addItem:item];
        }
        if (vols.count == 0) [self.diskPopup addItemWithTitle:@"No mounted internal volume — mount it in Disk Utility"];
    }
    self.volumeName.enabled = self.eraseCheck.state == NSOnState && !self.installing;
}

#pragma mark Account fields

- (void)accountToggled:(id)sender {
    BOOL on = self.createAccount.state == NSOnState && !self.installing;
    for (NSControl *c in @[self.fullName, self.shortName, self.password, self.verify, self.adminCheck, self.autoLoginCheck]) {
        c.enabled = on;
    }
}

- (void)controlTextDidChange:(NSNotification *)note {
    if (note.object == self.shortName) {
        self.shortNameEdited = self.shortName.stringValue.length > 0;
    } else if (note.object == self.fullName && !self.shortNameEdited) {
        self.shortName.stringValue = [self shortNameFrom:self.fullName.stringValue];
    }
}

- (NSString *)shortNameFrom:(NSString *)full {
    NSMutableString *s = [NSMutableString string];
    NSString *lower = [[full lowercaseString] stringByFoldingWithOptions:NSDiacriticInsensitiveSearch locale:nil];
    for (NSUInteger i = 0; i < lower.length; i++) {
        unichar c = [lower characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) [s appendFormat:@"%C", c];
    }
    return s;
}

#pragma mark Clock

- (void)updateClock {
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"MMM d, yyyy h:mm a";
    NSDate *now = [NSDate date];
    self.clockValue.stringValue = [f stringFromDate:now];
    // A Mac with a dead clock battery boots in 2000-something, and old installers then report "damaged".
    NSDateComponents *c = [[NSCalendar currentCalendar] components:NSCalendarUnitYear fromDate:now];
    self.clockValue.textColor = c.year < 2024 ? [NSColor systemRedColor] : [NSColor labelColor];
}

- (BOOL)networkUp {
    int status = 0;
    NSString *out = [HGShell run:@"/sbin/ifconfig" args:@[@"-a", @"inet"] status:&status];
    for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
        NSString *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([t hasPrefix:@"inet "] && ![t hasPrefix:@"inet 127."] && ![t hasPrefix:@"inet 169.254."]) return YES;
    }
    return NO;
}

- (void)updateNetworkLabel {
    NSString *ip = [HGWiFi ipAddress];
    NSString *ssid = [HGWiFi currentNetwork];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (ip && ssid) self.networkValue.stringValue = [NSString stringWithFormat:@"Wi-Fi “%@” · %@", ssid, ip];
        else if (ip) self.networkValue.stringValue = [NSString stringWithFormat:@"Connected · %@", ip];
        else self.networkValue.stringValue = @"Not connected (not needed to install)";
        self.networkValue.textColor = ip ? [NSColor labelColor] : [NSColor secondaryLabelColor];
    });
}

- (void)syncClock {
    int status = -1;
    NSString *out = nil;
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:@"/usr/bin/sntp"]) {
        out = [HGShell run:@"/usr/bin/sntp" args:@[@"-sS", @"time.apple.com"] status:&status];
    } else if ([[NSFileManager defaultManager] isExecutableFileAtPath:@"/usr/sbin/ntpdate"]) {
        out = [HGShell run:@"/usr/sbin/ntpdate" args:@[@"-u", @"time.apple.com"] status:&status];
    }
    [self log:status == 0 ? @"Clock synced with time.apple.com" : [NSString stringWithFormat:@"Clock sync failed: %@", out ?: @"no sntp"]];
    dispatch_async(dispatch_get_main_queue(), ^{ [self updateClock]; });
}

/// Joins `ssid` (if not already online), waits for an address, then syncs the clock.
- (void)joinWiFi:(NSString *)ssid password:(NSString *)password {
    if (ssid.length && ![self networkUp]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.networkValue.stringValue = [NSString stringWithFormat:@"Joining “%@”…", ssid];
        });
        [self log:[NSString stringWithFormat:@"Joining Wi-Fi “%@”", ssid]];
        NSString *err = [HGWiFi joinNetwork:ssid password:password];
        if (err) {
            [self log:[@"Wi-Fi: " stringByAppendingString:err]];
        } else {
            for (int i = 0; i < 20 && ![self networkUp]; i++) [NSThread sleepForTimeInterval:1.0];
            [self log:[self networkUp] ? [NSString stringWithFormat:@"Joined “%@” (%@)", ssid, [HGWiFi ipAddress] ?: @"no address yet"]
                                       : @"Joined Wi-Fi but got no address."];
        }
    }
    [self updateNetworkLabel];
    if ([self networkUp]) [self syncClock];
    else [self log:@"No network: clock not synced (use Set… if it's wrong)."];
}

- (void)connectNetworkInBackground {
    NSDictionary *wifi = [self.config[@"wifi"] isKindOfClass:[NSDictionary class]] ? self.config[@"wifi"] : nil;
    NSString *ssid = wifi[@"ssid"];
    NSString *password = wifi[@"password"];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self joinWiFi:ssid password:password];
    });
}

/// The Wi-Fi… button: join the drive's network or another one.
- (void)joinWiFiClicked:(id)sender {
    NSDictionary *wifi = [self.config[@"wifi"] isKindOfClass:[NSDictionary class]] ? self.config[@"wifi"] : nil;
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"Join a Wi-Fi network";
    a.informativeText = @"Only used in Recovery, to set the clock. Installing doesn't need a network.";
    NSView *box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 260, 54)];
    NSTextField *ssidField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 30, 260, 22)];
    [ssidField.cell setPlaceholderString:@"Network name"];
    ssidField.stringValue = wifi[@"ssid"] ?: @"";
    NSSecureTextField *pwField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 22)];
    [pwField.cell setPlaceholderString:@"Password"];
    pwField.stringValue = wifi[@"password"] ?: @"";
    [box addSubview:ssidField];
    [box addSubview:pwField];
    a.accessoryView = box;
    [a addButtonWithTitle:@"Join"];
    [a addButtonWithTitle:@"Cancel"];
    [a.window setInitialFirstResponder:ssidField];
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    NSString *ssid = [ssidField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *pw = pwField.stringValue;
    if (!ssid.length) return;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Join even if another network is up: the tech asked for this one.
        dispatch_async(dispatch_get_main_queue(), ^{
            self.networkValue.stringValue = [NSString stringWithFormat:@"Joining “%@”…", ssid];
        });
        NSString *err = [HGWiFi joinNetwork:ssid password:pw];
        if (err) {
            [self log:[@"Wi-Fi: " stringByAppendingString:err]];
            dispatch_async(dispatch_get_main_queue(), ^{ [self alert:@"Couldn't join the Wi-Fi network." info:err]; });
        } else {
            for (int i = 0; i < 20 && ![self networkUp]; i++) [NSThread sleepForTimeInterval:1.0];
            [self log:[NSString stringWithFormat:@"Joined “%@”", ssid]];
        }
        [self updateNetworkLabel];
        if ([self networkUp]) [self syncClock];
    });
}

- (void)setClock:(id)sender {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"Set the date and time";
    a.informativeText = @"Format: YYYY-MM-DD HH:MM (24-hour, local time)";
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 220, 22)];
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"yyyy-MM-dd HH:mm";
    field.stringValue = [f stringFromDate:[NSDate date]];
    a.accessoryView = field;
    [a addButtonWithTitle:@"Set"];
    [a addButtonWithTitle:@"Cancel"];
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    NSDate *d = [f dateFromString:[field.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
    if (!d) { [self alert:@"That date isn't in the right format." info:@"Use YYYY-MM-DD HH:MM, e.g. 2026-10-23 14:30"]; return; }
    NSDateFormatter *bsd = [[NSDateFormatter alloc] init];
    bsd.dateFormat = @"MMddHHmmyyyy";   // date(1): mmddHHMMccyy
    int status = 0;
    NSString *out = [HGShell run:@"/bin/date" args:@[[bsd stringFromDate:d]] status:&status];
    [self log:[NSString stringWithFormat:@"Set clock: %@", [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]]];
    [self updateClock];
}

#pragma mark Logging & UI state

- (void)openLogFile {
    NSString *dir = [[self deployDir] stringByAppendingPathComponent:@"Logs"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_%@.log", self.mac.serial, [f stringFromDate:[NSDate date]]]];
    if ([[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil]) {
        self.logFile = [NSFileHandle fileHandleForWritingAtPath:path];
    }
}

- (void)log:(NSString *)message {
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"%@  %@\n", [f stringFromDate:[NSDate date]], message];
    fprintf(stdout, "%s", line.UTF8String);
    fflush(stdout);
    dispatch_async(dispatch_get_main_queue(), ^{
        @try { [self.logFile writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; } @catch (NSException *e) {}
        NSAttributedString *as = [[NSAttributedString alloc] initWithString:line attributes:@{
            NSFontAttributeName: [NSFont userFixedPitchFontOfSize:10],
            NSForegroundColorAttributeName: [NSColor labelColor]}];
        [self.logView.textStorage appendAttributedString:as];
        [self.logView scrollRangeToVisible:NSMakeRange(self.logView.string.length, 0)];
    });
}

- (void)status:(NSString *)text progress:(double)value {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.stringValue = text;
        if (value < 0) {
            self.progress.hidden = NO;
            self.progress.indeterminate = YES;
            [self.progress startAnimation:nil];
        } else {
            self.progress.hidden = NO;
            self.progress.indeterminate = NO;
            [self.progress stopAnimation:nil];
            self.progress.doubleValue = value;
        }
    });
}

- (void)setLocked:(BOOL)locked {
    self.installing = locked;
    for (NSControl *c in self.lockableControls) c.enabled = !locked;
    if (!locked) {
        [self accountToggled:nil];
        self.volumeName.enabled = self.eraseCheck.state == NSOnState;
        self.progress.hidden = YES;
    } else {
        for (NSControl *c in @[self.fullName, self.shortName, self.password, self.verify, self.adminCheck, self.autoLoginCheck]) c.enabled = NO;
    }
}

- (void)alert:(NSString *)message info:(NSString *)info {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = message;
    a.informativeText = info ?: @"";
    [a runModal];
}

#pragma mark Buttons

- (void)quit:(id)sender { [NSApp terminate:nil]; }

- (void)restart:(id)sender {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"Restart this Mac?";
    [a addButtonWithTitle:@"Restart"];
    [a addButtonWithTitle:@"Cancel"];
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    int status = 0;
    [HGShell run:@"/sbin/shutdown" args:@[@"-r", @"now"] status:&status];
    if (status != 0) [HGShell run:@"/sbin/reboot" args:@[] status:&status];
}

- (NSString *)resolveComputerName {
    NSString *name = [self.computerName.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    name = [name stringByReplacingOccurrencesOfString:@"{serial}" withString:self.mac.serial];
    name = [name stringByReplacingOccurrencesOfString:@"{model}" withString:
            [self.mac.modelIdentifier stringByReplacingOccurrencesOfString:@"," withString:@"-"]];
    return name;
}

- (void)install:(id)sender {
    HGInstaller *inst = [self selectedInstaller];
    if (!inst) { [self alert:@"Choose a macOS version to install." info:nil]; return; }
    NSDictionary *target = self.diskPopup.selectedItem.representedObject;
    if (!target) { [self alert:@"There's no disk to install on." info:@"Check the internal disk in Disk Utility."]; return; }
    BOOL erase = [target[@"kind"] isEqualToString:@"disk"] || [target[@"kind"] isEqualToString:@"fusion"];
    NSString *volName = [self.volumeName.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (erase && volName.length == 0) volName = @"Macintosh HD";

    BOOL create = self.createAccount.state == NSOnState;
    if (create) {
        NSString *sn = self.shortName.stringValue;
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^[a-z_][a-z0-9_.-]{0,30}$" options:0 error:NULL];
        if (self.fullName.stringValue.length == 0) { [self alert:@"Enter a full name for the account." info:nil]; return; }
        if (![re firstMatchInString:sn options:0 range:NSMakeRange(0, sn.length)]) {
            [self alert:@"The account name isn't valid." info:@"Use lowercase letters and numbers, starting with a letter (e.g. hgcellular)."];
            return;
        }
        if ([@[@"root", @"admin", @"daemon", @"nobody", @"guest"] containsObject:sn]) {
            [self alert:@"That account name is reserved by macOS." info:@"Pick a different account name."];
            return;
        }
        if (![self.password.stringValue isEqualToString:self.verify.stringValue]) {
            [self alert:@"The passwords don't match." info:nil];
            return;
        }
        if (self.password.stringValue.length == 0) {
            NSAlert *a = [[NSAlert alloc] init];
            a.messageText = @"Create the account with no password?";
            [a addButtonWithTitle:@"No Password"];
            [a addButtonWithTitle:@"Cancel"];
            if ([a runModal] != NSAlertFirstButtonReturn) return;
        }
    }

    NSString *what = nil;
    if ([target[@"kind"] isEqualToString:@"fusion"]) {
        what = [NSString stringWithFormat:@"This resets the Fusion Drive (%@) and erases everything on both disks, then installs %@.",
                [target[@"disks"] componentsJoinedByString:@" + "], [inst title]];
    } else if (erase) {
        HGDisk *d = target[@"disk"];
        what = [NSString stringWithFormat:@"This erases everything on %@ (%@, %@), then installs %@.",
                d.mediaName ?: @"the disk", d.identifier, [HGDisks formatBytes:d.size], [inst title]];
    } else {
        HGVolume *vol = target[@"volume"];
        what = [NSString stringWithFormat:@"This installs %@ on “%@” without erasing it. Files on it are kept.", [inst title], vol.name];
    }
    NSAlert *confirm = [[NSAlert alloc] init];
    confirm.messageText = erase ? @"Erase and install?" : @"Install macOS?";
    confirm.informativeText = [what stringByAppendingString:@" The Mac restarts by itself when the installer is ready."];
    confirm.alertStyle = erase ? NSCriticalAlertStyle : NSWarningAlertStyle;
    [confirm addButtonWithTitle:erase ? @"Erase & Install" : @"Install"];
    [confirm addButtonWithTitle:@"Cancel"];
    if ([confirm runModal] != NSAlertFirstButtonReturn) return;

    // Everything the first-boot package needs, passed through NVRAM.
    NSMutableDictionary *cfg = [NSMutableDictionary dictionary];
    if (create) {
        cfg[@"CREATE_USER"] = @"1";
        cfg[@"FULLNAME"] = self.fullName.stringValue;
        cfg[@"SHORTNAME"] = self.shortName.stringValue;
        cfg[@"PASSWORD"] = self.password.stringValue;
        cfg[@"ADMIN"] = self.adminCheck.state == NSOnState ? @"1" : @"0";
        cfg[@"AUTOLOGIN"] = self.autoLoginCheck.state == NSOnState ? @"1" : @"0";
    }
    NSString *cn = [self resolveComputerName];
    if (cn.length) cfg[@"COMPUTERNAME"] = cn;
    if (self.sshCheck.state == NSOnState) cfg[@"SSH"] = @"1";

    [self setLocked:YES];
    [self log:[NSString stringWithFormat:@"Starting: %@ → %@", [inst title], self.diskPopup.selectedItem.title]];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *error = [self runInstall:inst target:target volumeName:volName config:cfg];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                [self log:[@"FAILED: " stringByAppendingString:error]];
                [self setLocked:NO];
                self.statusLabel.stringValue = @"Install failed — see the log.";
                [self reloadDisks];
                [self alert:@"The install didn't finish." info:error];
            }
        });
    });
}

#pragma mark Install (background thread)

- (NSString *)writeNVRAM:(NSDictionary *)cfg {
    int status = 0;
    if (cfg.count == 0) {
        [HGShell run:@"/usr/sbin/nvram" args:@[@"-d", kNVRAMKey] status:&status];
        [self log:@"No account or settings to apply after install."];
        return nil;
    }
    NSMutableArray *lines = [NSMutableArray array];
    for (NSString *k in cfg) [lines addObject:[NSString stringWithFormat:@"%@=%@", k, HGB64(cfg[k])]];
    NSString *blob = HGB64([lines componentsJoinedByString:@"\n"]);
    NSString *out = [HGShell run:@"/usr/sbin/nvram" args:@[[NSString stringWithFormat:@"%@=%@", kNVRAMKey, blob]] status:&status];
    if (status != 0) return [NSString stringWithFormat:@"Couldn't save the account settings to NVRAM: %@", out];
    [self log:[NSString stringWithFormat:@"Saved first-boot settings (%@)",
               [[[cfg allKeys] sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@", "]]];
    return nil;
}

- (NSString *)eraseTarget:(NSDictionary *)target installer:(HGInstaller *)inst volumeName:(NSString *)volName mountPoint:(NSString **)mountPoint {
    NSString *diskutil = @"/usr/sbin/diskutil";
    BOOL recoveryHasAPFS = HGCompareVersions(self.mac.recoveryVersion, @"10.13") != NSOrderedAscending;
    int status = 0;
    NSArray *disks = nil;
    NSString *createdName = volName;

    if ([target[@"kind"] isEqualToString:@"fusion"]) {
        disks = target[@"disks"];
        [self status:@"Resetting the Fusion Drive…" progress:-1];
        [self log:@"diskutil resetFusion"];
        NSString *out = [HGShell run:diskutil args:@[@"resetFusion"] input:@"Yes\n" status:&status];
        [self log:out];
        if (status != 0) return @"diskutil resetFusion failed.";
        createdName = @"Macintosh HD";
    } else {
        HGDisk *d = target[@"disk"];
        disks = @[d.identifier];
        // High Sierra can't go on APFS on a hard drive; Recovery older than 10.13 can't make APFS at all.
        BOOL hfs = !recoveryHasAPFS || ([inst.major isEqualToString:@"10.13"] && !d.solidState);
        NSString *format = hfs ? @"JHFS+" : @"APFS";
        [self status:[NSString stringWithFormat:@"Erasing %@…", d.identifier] progress:-1];
        // Volumes from the old install (or a mounted Data volume) block the erase.
        [self log:[HGShell run:diskutil args:@[@"unmountDisk", @"force", d.identifier] status:&status]];
        [self log:[NSString stringWithFormat:@"diskutil eraseDisk %@ \"%@\" GPT %@", format, volName, d.identifier]];
        __block NSString *last = nil;
        status = [HGShell stream:diskutil args:@[@"eraseDisk", format, volName, @"GPT", d.identifier] line:^(NSString *l) {
            last = l;
            [self log:l];
        }];
        if (status != 0) return [NSString stringWithFormat:@"Erasing %@ failed: %@", d.identifier, last ?: @""];
    }

    NSString *mp = nil;
    for (int i = 0; i < 10 && !mp; i++) {
        mp = [HGDisks mountPointForVolumeNamed:createdName onDisks:disks];
        if (!mp) [NSThread sleepForTimeInterval:1.0];
    }
    if (!mp) return [NSString stringWithFormat:@"Erased, but couldn't find the new “%@” volume.", createdName];

    if (![createdName isEqualToString:volName]) {
        NSString *out = [HGShell run:diskutil args:@[@"rename", mp, volName] status:&status];
        [self log:out];
        NSString *renamed = [HGDisks mountPointForVolumeNamed:volName onDisks:disks];
        if (renamed) mp = renamed;
    }
    *mountPoint = mp;
    [self log:[NSString stringWithFormat:@"Target volume: %@", mp]];
    return nil;
}

- (NSString *)runInstall:(HGInstaller *)inst target:(NSDictionary *)target volumeName:(NSString *)volName config:(NSDictionary *)cfg {
    NSString *problem = [inst problem];
    if (problem) return [NSString stringWithFormat:@"%@: %@", inst.appName, problem];

    NSString *err = [self writeNVRAM:cfg];
    if (err) return err;

    NSString *mountPoint = nil;
    if ([target[@"kind"] isEqualToString:@"volume"]) {
        mountPoint = ((HGVolume *)target[@"volume"]).mountPoint;
    } else {
        err = [self eraseTarget:target installer:inst volumeName:volName mountPoint:&mountPoint];
        if (err) return err;
    }

    NSMutableArray *args = [NSMutableArray arrayWithObjects:@"--agreetolicense", @"--nointeraction", @"--volume", mountPoint, nil];
    if ([inst.major isEqualToString:@"10.13"]) [args addObjectsFromArray:@[@"--applicationpath", inst.path]];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *firstBoot = [[self deployDir] stringByAppendingPathComponent:@"HGFirstBoot.pkg"];
    if (cfg.count) {
        if ([fm fileExistsAtPath:firstBoot]) {
            [args addObjectsFromArray:@[@"--installpackage", firstBoot]];
        } else {
            [self log:@"WARNING: HGFirstBoot.pkg is missing from the drive, so the account and settings won't be applied."];
        }
    }
    // Extra packages to install with macOS (must be product archives / distribution packages).
    NSString *pkgDir = [[self deployDir] stringByAppendingPathComponent:@"Packages"];
    for (NSString *p in [[fm contentsOfDirectoryAtPath:pkgDir error:NULL] sortedArrayUsingSelector:@selector(compare:)]) {
        if ([p.pathExtension isEqualToString:@"pkg"]) {
            [args addObjectsFromArray:@[@"--installpackage", [pkgDir stringByAppendingPathComponent:p]]];
            [self log:[@"Extra package: " stringByAppendingString:p]];
        }
    }

    [self status:@"Preparing the installer…" progress:-1];
    [self log:[NSString stringWithFormat:@"startosinstall %@", [args componentsJoinedByString:@" "]]];
    NSRegularExpression *pct = [NSRegularExpression regularExpressionWithPattern:@"Preparing:?\\s*([0-9]+(\\.[0-9]+)?)" options:0 error:NULL];
    __block NSString *lastLine = nil;
    __block double lastLogged = -10;
    int status = [HGShell stream:[inst startosinstall] args:args line:^(NSString *l) {
        NSTextCheckingResult *m = [pct firstMatchInString:l options:0 range:NSMakeRange(0, l.length)];
        if (m) {
            double v = [[l substringWithRange:[m rangeAtIndex:1]] doubleValue];
            [self status:[NSString stringWithFormat:@"Preparing %@… %.0f%%", [inst title], v] progress:v];
            if (v - lastLogged >= 10) { lastLogged = v; [self log:l]; }
            return;
        }
        lastLine = l;
        [self log:l];
        if ([l rangeOfString:@"restart" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            [self status:@"Done preparing — the Mac will restart and finish installing." progress:100];
        }
    }];
    if (status != 0) {
        return [NSString stringWithFormat:@"startosinstall exited with code %d. %@", status, lastLine ?: @""];
    }
    [self status:@"Restarting to finish the install…" progress:100];
    [self log:@"startosinstall finished; restarting."];
    return nil;
}

@end
