#import "HGShell.h"

@implementation HGShell

+ (NSTask *)taskFor:(NSString *)path args:(NSArray *)args {
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = path;
    task.arguments = args ?: @[];
    // Recovery's Terminal environment is minimal; make sure tools that
    // shell out themselves can find the basics.
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    env[@"PATH"] = @"/usr/bin:/bin:/usr/sbin:/sbin:/usr/libexec";
    task.environment = env;
    return task;
}

+ (NSString *)run:(NSString *)path args:(NSArray *)args status:(int *)status {
    return [self run:path args:args input:nil status:status];
}

+ (NSString *)run:(NSString *)path args:(NSArray *)args input:(NSString *)input status:(int *)status {
    if (status) *status = -1;
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:path]) {
        return [NSString stringWithFormat:@"%@ not found", path];
    }
    NSTask *task = [self taskFor:path args:args];
    NSPipe *out = [NSPipe pipe];
    task.standardOutput = out;
    task.standardError = out;
    NSPipe *inPipe = nil;
    if (input) {
        inPipe = [NSPipe pipe];
        task.standardInput = inPipe;
    } else {
        task.standardInput = [NSFileHandle fileHandleWithNullDevice];
    }
    @try {
        [task launch];
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"could not run %@: %@", path, e.reason];
    }
    if (inPipe) {
        [[inPipe fileHandleForWriting] writeData:[input dataUsingEncoding:NSUTF8StringEncoding]];
        [[inPipe fileHandleForWriting] closeFile];
    }
    NSData *data = [[out fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    if (status) *status = task.terminationStatus;
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!s) s = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    return s ?: @"";
}

+ (id)plist:(NSString *)path args:(NSArray *)args {
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:path]) return nil;
    NSTask *task = [self taskFor:path args:args];
    NSPipe *out = [NSPipe pipe];
    task.standardOutput = out;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];
    @try {
        [task launch];
    } @catch (NSException *e) {
        return nil;
    }
    NSData *data = [[out fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    if (data.length == 0) return nil;
    return [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
}

+ (int)stream:(NSString *)path args:(NSArray *)args line:(void (^)(NSString *))line {
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:path]) {
        line([NSString stringWithFormat:@"%@ not found", path]);
        return -1;
    }
    NSTask *task = [self taskFor:path args:args];
    NSPipe *out = [NSPipe pipe];
    task.standardOutput = out;
    task.standardError = out;
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];
    @try {
        [task launch];
    } @catch (NSException *e) {
        line([NSString stringWithFormat:@"could not run %@: %@", path, e.reason]);
        return -1;
    }
    NSFileHandle *fh = [out fileHandleForReading];
    NSMutableData *buffer = [NSMutableData data];
    NSCharacterSet *breaks = [NSCharacterSet characterSetWithCharactersInString:@"\r\n"];
    while (YES) {
        NSData *chunk = [fh availableData];   // blocks; empty at EOF
        if (chunk.length == 0) break;
        [buffer appendData:chunk];
        NSString *text = [[NSString alloc] initWithData:buffer encoding:NSUTF8StringEncoding];
        if (!text) continue;   // partial UTF-8 sequence; wait for more
        NSRange last = [text rangeOfCharacterFromSet:breaks options:NSBackwardsSearch];
        if (last.location == NSNotFound) continue;
        NSString *complete = [text substringToIndex:last.location];
        NSString *rest = [text substringFromIndex:last.location + 1];
        for (NSString *l in [complete componentsSeparatedByCharactersInSet:breaks]) {
            NSString *t = [l stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (t.length) line(t);
        }
        [buffer setData:[rest dataUsingEncoding:NSUTF8StringEncoding]];
    }
    if (buffer.length) {
        NSString *t = [[NSString alloc] initWithData:buffer encoding:NSUTF8StringEncoding];
        t = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length) line(t);
    }
    [task waitUntilExit];
    return task.terminationStatus;
}

@end
