//
//  FDImporter.m
//
//  Same job as the shell function it replaces:
//      for every file of the study folder (DICOMDIR and hidden files aside), copy it, and if DCMTK
//      would say "Sequence Delimitation Item missing", append FE FF DD E0 00 00 00 00.
//  The check is done here by FDRepair (no DCMTK needed), which also closes an open undefined-length
//  item (FE FF 0D E0 ...) and handles big endian files. The copies go straight into the database's
//  INCOMING folder, which the viewer imports into its database as it does files received over the
//  network; nothing is written next to the original study.
//

#import "FDImporter.h"
#import "FDRepair.h"

// The database API is declared here instead of importing DicomDatabase.h, whose dependencies differ
// between IsiX and Horos. Every call is checked with -respondsToSelector: first.
@interface NSObject (FDDicomDatabase)
+ (id)activeLocalDatabase;
- (NSString *)incomingDirPath;
- (const char *)incomingDirPathC;
- (void)initiateImportFilesFromIncomingDirUnlessAlreadyImporting;
- (NSInteger)importFilesFromIncomingDir;
- (NSArray *)addFilesAtPaths:(NSArray *)paths postNotifications:(BOOL)postNotifications dicomOnly:(BOOL)dicomOnly
         rereadExistingItems:(BOOL)rereadExistingItems generatedByOsiriX:(BOOL)generatedByOsiriX;
- (NSArray *)addFilesAtPaths:(NSArray *)paths;
@end

static NSString *FDSupportDirectory(void)
{
    NSString *base = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    NSString *dir = [base stringByAppendingPathComponent:@"FixDICOM"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return dir;
}

static NSString *FDLogPath(void) { return [FDSupportDirectory() stringByAppendingPathComponent:@"log.txt"]; }

static void FDAppendLog(NSString *text)
{
    NSString *path = FDLogPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path])
        [[NSData data] writeToFile:path atomically:YES];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    [h seekToEndOfFile];
    [h writeData:[text dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}

@interface FDImporter ()
@property (atomic) BOOL busy;
@property (atomic) BOOL cancelled;
@property (nonatomic, strong) NSPanel *panel;
@property (nonatomic, strong) NSTextField *label;
@property (nonatomic, strong) NSProgressIndicator *bar;
@end

@implementation FDImporter

+ (instancetype)sharedImporter
{
    static FDImporter *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[FDImporter alloc] init]; });
    return shared;
}

#pragma mark - Folder dialog

- (void)chooseAndImport
{
    if (self.busy) { [self.panel makeKeyAndOrderFront:nil]; return; }

    NSOpenPanel *open = [NSOpenPanel openPanel];
    open.canChooseDirectories = YES;
    open.canChooseFiles = NO;
    open.allowsMultipleSelection = YES;
    open.title = @"Fix and Import DICOM Study";
    open.message = @"Choose the folder of the study to repair and import (several folders: hold ⌘).";
    open.prompt = @"Repair and Import";
    if ([open runModal] != NSModalResponseOK || open.URLs.count == 0) return;

    // The database is asked on the main thread.
    Class databaseClass = NSClassFromString(@"DicomDatabase");
    id database = [databaseClass respondsToSelector:@selector(activeLocalDatabase)] ? [databaseClass activeLocalDatabase] : nil;
    if (!database) { [self alert:@"The viewer database is not available." info:nil]; return; }
    NSString *incoming = nil;
    if ([database respondsToSelector:@selector(incomingDirPath)]) incoming = [database incomingDirPath];
    else if ([database respondsToSelector:@selector(incomingDirPathC)]) {
        const char *c = [database incomingDirPathC];
        if (c && *c) incoming = [NSString stringWithUTF8String:c];
    }
    if (incoming.length) [[NSFileManager defaultManager] createDirectoryAtPath:incoming withIntermediateDirectories:YES attributes:nil error:NULL];
    BOOL useIncoming = incoming.length && [[NSFileManager defaultManager] isWritableFileAtPath:incoming];

    // Without an INCOMING folder, the repaired copies are kept here and added in place.
    NSString *destination = incoming;
    if (!useIncoming) {
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyyMMdd-HHmmss";
        destination = [[FDSupportDirectory() stringByAppendingPathComponent:@"Imported"]
                       stringByAppendingPathComponent:[df stringFromDate:[NSDate date]]];
        [[NSFileManager defaultManager] createDirectoryAtPath:destination withIntermediateDirectories:YES attributes:nil error:NULL];
    }

    self.busy = YES;
    self.cancelled = NO;
    [self showProgress];
    NSArray<NSURL *> *folders = [open.URLs copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self processFolders:folders into:destination useIncoming:useIncoming database:database];
    });
}

#pragma mark - Work (background)

- (NSArray<NSString *> *)filesInFolder:(NSURL *)folder
{
    NSMutableArray *files = [NSMutableArray array];
    NSDirectoryEnumerator *e = [[NSFileManager defaultManager] enumeratorAtURL:folder
        includingPropertiesForKeys:@[NSURLIsRegularFileKey]
        options:NSDirectoryEnumerationSkipsHiddenFiles | NSDirectoryEnumerationSkipsPackageDescendants
        errorHandler:^BOOL(NSURL *url, NSError *error) { return YES; }];
    for (NSURL *url in e) {
        NSNumber *regular = nil;
        [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:NULL];
        if (![regular boolValue]) continue;
        if ([[url lastPathComponent] caseInsensitiveCompare:@"DICOMDIR"] == NSOrderedSame) continue;
        [files addObject:url.path];
    }
    [files sortUsingSelector:@selector(compare:)];
    return files;
}

- (void)processFolders:(NSArray<NSURL *> *)folders into:(NSString *)destination useIncoming:(BOOL)useIncoming database:(id)database
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *all = [NSMutableArray array];
    NSMutableArray<NSString *> *roots = [NSMutableArray array];
    for (NSURL *folder in folders) {
        [self setStatus:[NSString stringWithFormat:@"Listing %@…", folder.lastPathComponent] done:0 total:0];
        NSArray *files = [self filesInFolder:folder];
        [all addObjectsFromArray:files];
        for (NSUInteger i = 0; i < files.count; i++) [roots addObject:folder.path];
    }

    NSUInteger total = all.count, imported = 0, repaired = 0, damaged = 0, skipped = 0, failed = 0;
    NSMutableString *log = [NSMutableString string];
    NSMutableArray<NSString *> *written = [NSMutableArray array];
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    [log appendFormat:@"\n=== %@  %@\n", [df stringFromDate:[NSDate date]],
        [[folders valueForKey:@"path"] componentsJoinedByString:@", "]];

    for (NSUInteger i = 0; i < total; i++) {
        if (self.cancelled) break;
        @autoreleasepool {
            NSString *src = all[i];
            NSString *rel = [src hasPrefix:roots[i]] ? [src substringFromIndex:MIN(src.length, roots[i].length + 1)] : src;
            if (i % 20 == 0) [self setStatus:[NSString stringWithFormat:@"%@", rel] done:i total:total];

            NSData *data = [NSData dataWithContentsOfFile:src options:NSDataReadingMappedIfSafe error:NULL];
            if (!data) { failed++; [log appendFormat:@"  cannot read: %@\n", rel]; continue; }
            fd_result r;
            fd_analyze(data.bytes, data.length, &r);
            if (r.status == FD_NOT_DICOM) { skipped++; continue; }

            // Written under a hidden name first, so the viewer never picks up a half-written file.
            NSString *name = [NSString stringWithFormat:@"fixdicom-%@.dcm", [[NSUUID UUID] UUIDString]];
            NSString *tmp = [destination stringByAppendingPathComponent:[@"." stringByAppendingString:name]];
            NSString *final = [destination stringByAppendingPathComponent:name];
            BOOL ok = [data writeToFile:tmp options:0 error:NULL];
            if (ok && r.status == FD_NEEDS_FIX) {
                NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:tmp];
                @try {
                    [h seekToEndOfFile];
                    [h writeData:[NSData dataWithBytes:r.tail length:r.tailLength]];
                    [h closeFile];
                } @catch (NSException *e) { ok = NO; }
                ok = ok && h != nil;
            }
            if (ok) ok = [fm moveItemAtPath:tmp toPath:final error:NULL];
            if (!ok) { [fm removeItemAtPath:tmp error:NULL]; failed++; [log appendFormat:@"  cannot write copy of: %@\n", rel]; continue; }

            imported++;
            [written addObject:final];
            if (r.status == FD_NEEDS_FIX) { repaired++; [log appendFormat:@"  fixed: %@ (%s)\n", rel, r.message]; }
            else if (r.status == FD_DAMAGED || r.status == FD_UNSUPPORTED) {
                damaged++; [log appendFormat:@"  NOT repaired, imported as is: %@ (%s)\n", rel, r.message];
            }
        }
    }
    BOOL cancelled = self.cancelled;
    [log appendFormat:@"  %lu files: %lu sent to the database (%lu repaired, %lu not repairable), %lu not DICOM, %lu errors%@\n",
        (unsigned long)total, (unsigned long)imported, (unsigned long)repaired, (unsigned long)damaged,
        (unsigned long)skipped, (unsigned long)failed, cancelled ? @", STOPPED" : @""];
    FDAppendLog(log);

    dispatch_async(dispatch_get_main_queue(), ^{
        if (imported) {
            if (useIncoming) {
                [self importIncoming:database];
                // An import already running may have listed the folder before the last files arrived.
                for (int delay = 5; delay <= 20; delay += 15)
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delay * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                        [self importIncoming:database];
                    });
            } else if ([database respondsToSelector:@selector(addFilesAtPaths:postNotifications:dicomOnly:rereadExistingItems:generatedByOsiriX:)]) {
                (void)[database addFilesAtPaths:written postNotifications:YES dicomOnly:YES rereadExistingItems:YES generatedByOsiriX:NO];
            } else if ([database respondsToSelector:@selector(addFilesAtPaths:)]) {
                (void)[database addFilesAtPaths:written];
            }
        }
        [self.panel orderOut:nil];
        self.busy = NO;

        NSString *names = [[folders valueForKey:@"lastPathComponent"] componentsJoinedByString:@", "];
        if (imported == 0 && !cancelled) {
            [self alert:[NSString stringWithFormat:@"No DICOM files found in %@.", names]
                   info:failed ? [NSString stringWithFormat:@"%lu file(s) could not be read.", (unsigned long)failed] : nil];
            return;
        }
        NSMutableString *info = [NSMutableString string];
        [info appendFormat:@"%lu DICOM file%@ added to the database; %lu repaired (missing delimiters added).",
            (unsigned long)imported, imported == 1 ? @"" : @"s", (unsigned long)repaired];
        if (damaged) [info appendFormat:@"\n\n%lu file%@ could not be repaired (cut short or not understood) and %@ added as %@: see the log.",
            (unsigned long)damaged, damaged == 1 ? @"" : @"s", damaged == 1 ? @"was" : @"were", damaged == 1 ? @"it is" : @"they are"];
        if (skipped) [info appendFormat:@"\n\n%lu file%@ skipped: not DICOM.", (unsigned long)skipped, skipped == 1 ? @"" : @"s"];
        if (failed) [info appendFormat:@"\n\n%lu file%@ could not be read or copied: see the log.", (unsigned long)failed, failed == 1 ? @"" : @"s"];
        if (useIncoming) [info appendString:@"\n\nThe study appears in the database within a few seconds."];
        NSString *title = cancelled ? [NSString stringWithFormat:@"Stopped. Part of %@ was imported.", names]
                                    : [NSString stringWithFormat:@"%@ imported.", names];
        [self alert:title info:info];
    });
}

- (void)importIncoming:(id)database
{
    if ([database respondsToSelector:@selector(initiateImportFilesFromIncomingDirUnlessAlreadyImporting)])
        [database initiateImportFilesFromIncomingDirUnlessAlreadyImporting];
    else if ([database respondsToSelector:@selector(importFilesFromIncomingDir)])
        (void)[database importFilesFromIncomingDir];
}

#pragma mark - Progress window and messages

- (void)showProgress
{
    if (!self.panel) {
        NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 440, 118)
                                                    styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        panel.title = @"Fix and Import DICOM Study";
        panel.releasedWhenClosed = NO;
        panel.hidesOnDeactivate = NO;
        NSView *v = panel.contentView;

        NSTextField *label = [NSTextField labelWithString:@""];
        label.frame = NSMakeRect(20, 78, 400, 20);
        label.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [v addSubview:label];

        NSProgressIndicator *bar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 52, 400, 20)];
        bar.style = NSProgressIndicatorStyleBar;
        bar.minValue = 0;
        [v addSubview:bar];

        NSButton *stop = [NSButton buttonWithTitle:@"Stop" target:self action:@selector(stop:)];
        stop.frame = NSMakeRect(330, 12, 96, 32);
        stop.keyEquivalent = @"\e";
        [v addSubview:stop];

        self.panel = panel; self.label = label; self.bar = bar;
    }
    self.label.stringValue = @"Starting…";
    self.bar.indeterminate = YES;
    [self.bar startAnimation:nil];
    [self.panel center];
    [self.panel makeKeyAndOrderFront:nil];
}

- (void)stop:(id)sender
{
    self.cancelled = YES;
    self.label.stringValue = @"Stopping…";
}

- (void)setStatus:(NSString *)text done:(NSUInteger)done total:(NSUInteger)total
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.cancelled) return;
        self.label.stringValue = total ? [NSString stringWithFormat:@"%lu of %lu — %@", (unsigned long)done + 1, (unsigned long)total, text] : text;
        if (total) {
            if (self.bar.indeterminate) { [self.bar stopAnimation:nil]; self.bar.indeterminate = NO; }
            self.bar.maxValue = total;
            self.bar.doubleValue = done;
        }
    });
}

- (void)alert:(NSString *)message info:(NSString *)info
{
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = message;
    if (info) alert.informativeText = info;
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Show Log"];
    if ([alert runModal] == NSAlertSecondButtonReturn)
        [[NSWorkspace sharedWorkspace] openFile:FDLogPath()];
}

@end
