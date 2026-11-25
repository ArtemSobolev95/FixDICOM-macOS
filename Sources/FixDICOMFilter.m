//
//  FixDICOMFilter.m — plugin entry point.
//
//  A "Database" plugin: Plugins › Database › Fix and Import DICOM Study… works from the database
//  window, without a viewer. Also a toolbar button for the database window and the viewer.
//

#import "FixDICOMFilter.h"
#import "FDImporter.h"

static NSString * const FDMenuTitle = @"Fix and Import DICOM Study…";

@implementation FixDICOMFilter

- (void)initPlugin
{
}

- (long)filterImage:(NSString *)menuName
{
    // Let the menu close before the folder dialog opens.
    dispatch_async(dispatch_get_main_queue(), ^{ [[FDImporter sharedImporter] chooseAndImport]; });
    return 0;
}

+ (NSImage *)toolbarImage
{
    NSString *path = [[NSBundle bundleForClass:self] pathForImageResource:@"FixDICOM-icon"];
    NSImage *image = path ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
    return image ?: [NSImage imageWithSystemSymbolName:@"cross.case" accessibilityDescription:@"Fix DICOM"];
}

- (NSToolbarItem *)toolbarItemFor:(NSString *)identifier controller:(id)controller
{
    // The window asks every plugin about every toolbar item: answer only for ours.
    if (![identifier isEqualToString:FDMenuTitle]) return nil;
    if (!controller || ![controller respondsToSelector:@selector(executeFilterFromToolbar:)]) return nil;
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
    // The window finds the plugin to run from the button's label: it must be the menu title.
    item.label = identifier;
    item.paletteLabel = identifier;
    item.toolTip = @"Choose a study folder; repair files with a missing Sequence Delimitation Item and import them";
    item.image = [FixDICOMFilter toolbarImage];
    item.target = controller;
    item.action = @selector(executeFilterFromToolbar:);
    return item;
}

- (NSArray *)toolbarAllowedIdentifiersForBrowserController:(id)controller { return @[FDMenuTitle]; }
- (NSToolbarItem *)toolbarItemForItemIdentifier:(NSString *)identifier forBrowserController:(id)controller
{
    return [self toolbarItemFor:identifier controller:controller];
}

- (NSToolbarItem *)toolbarItemForItemIdentifier:(NSString *)identifier forViewer:(id)controller
{
    return [self toolbarItemFor:identifier controller:controller];
}

@end
