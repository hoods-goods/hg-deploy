// Runs command-line tools (diskutil, nvram, startosinstall...).
// Written against the macOS 10.11 SDK surface so it runs in every Recovery
// HG Deploy supports.
#import <Foundation/Foundation.h>

@interface HGShell : NSObject

/// Runs a tool and returns stdout+stderr. `status` gets the exit code (-1 if it couldn't start).
+ (NSString *)run:(NSString *)path args:(NSArray *)args status:(int *)status;

/// Same, writing `input` to the tool's stdin first.
+ (NSString *)run:(NSString *)path args:(NSArray *)args input:(NSString *)input status:(int *)status;

/// Runs a tool that prints a property list (e.g. `diskutil info -plist`) and parses stdout.
+ (id)plist:(NSString *)path args:(NSArray *)args;

/// Runs a tool and calls `line` for every line of output (split on \n and \r)
/// as it arrives. Blocks until the tool exits; returns its exit code.
/// `line` is called on the calling thread.
+ (int)stream:(NSString *)path args:(NSArray *)args line:(void (^)(NSString *line))line;

@end
