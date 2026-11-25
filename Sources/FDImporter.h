//
//  FDImporter.h — asks for study folders, repairs their DICOM files and adds them to the database.
//

#import <Cocoa/Cocoa.h>

@interface FDImporter : NSObject
+ (instancetype)sharedImporter;
// Shows the folder dialog; the work then runs in the background with a progress window.
- (void)chooseAndImport;
@end
