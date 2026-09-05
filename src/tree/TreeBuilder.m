/* GrandPerspective, Version 3.8.0 
 *   A utility for macOS that graphically shows disk usage. 
 * Copyright (C) 2005-2025, Erwin Bonsma 
 * 
 * This program is free software; you can redistribute it and/or modify it 
 * under the terms of the GNU General Public License as published by the Free 
 * Software Foundation; either version 2 of the License, or (at your option) 
 * any later version. 
 * 
 * This program is distributed in the hope that it will be useful, but WITHOUT 
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or 
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for 
 * more details. 
 * 
 * You should have received a copy of the GNU General Public License along 
 * with this program; if not, write to the Free Software Foundation, Inc., 
 * 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA. 
 */

#import "TreeBuilder.h"

#include <sys/stat.h>
#include <sys/mount.h>
#include <sys/attr.h>
#include "BulkDirectoryEntry.h"
#include <dirent.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>


#import "AlertMessage.h"
#import "PlainFileItem.h"
#import "DirectoryItem.h"
#import "ScanTreeRoot.h"
#import "CompoundItem.h"
#import "TreeContext.h"
#import "FilterSet.h"
#import "FilteredTreeGuide.h"
#import "TreeBalancer.h"
#import "NSURL.h"
#import "ControlConstants.h"
#import "LogManager.h"

#import "ScanProgressTracker.h"
#import "UniformType.h"
#import "UniformTypeInventory.h"
#import "PreferencesPanelControl.h"


NSString  *LogicalFileSizeName = @"logical";
NSString  *PhysicalFileSizeName = @"physical";
NSString  *TallyFileSizeName = @"tally";

// Options for PackageCheckBehavior preference
NSString  *RobustBehavior = @"robust";
NSString  *AdaptiveBehavior = @"adaptive";
NSString  *FastBehavior = @"fast";

/* Use smaller bounds given the extra scan cost needed to determine the number of directories
 * at each level used for tracking progress.
 */
#define  NUM_SCAN_PROGRESS_ESTIMATE_LEVELS MIN(1, NUM_PROGRESS_ESTIMATE_LEVELS)

static const int AUTORELEASE_PERIOD = 1024;
static const size_t ATTR_BULK_BUFFER_SIZE = 256 * 1024;

/* Helper class that is used to temporarily store additional info for directories that are being
 * scanned. It stores the info that is not maintained by the DirectoryItem class yet is needed
 * while its contents are still being scanned.
 */
@interface ScanStackFrame : NSObject {
@public
  // The parent for the new children
  DirectoryItem  *parent;

  // The node where to collect the children. For normal scans it is the same as "parent" but for
  // shallow scans it is different, as the sizes of the sub-directory children are not yet known,
  // which is a pre-requisite before they can be added to their parent directory.
  DirectoryItem  *collector;

  // Directory file descriptor for getattrlistbulk
  int  dirfd;
  
  // Full path of the directory
  NSString  *path;

  // The collector of the parent frame, used to attach this directory when finalized.
  DirectoryItem  *parentCollector;

  // Tracks whether all entries of this directory have been enumerated.
  BOOL  contentsEnumerated;

  // Buffered getattrlistbulk state for incremental enumeration.
  char  *bulkBuffer;
  char  *bulkRecordCursor;
  int  bulkRecordCount;
  int  bulkRecordIndex;
}

- (instancetype) init NS_DESIGNATED_INITIALIZER;

// Convenience "constructors" for repeated usage
- (void) initWithParent:(DirectoryItem *)parent
                   path:(NSString *)path
                  dirfd:(int)dirfd
        parentCollector:(DirectoryItem *)parentCollector;

- (void) initWithParent:(DirectoryItem *)parent
              collector:(DirectoryItem *)collector
                   path:(NSString *)path
                  dirfd:(int)dirfd
        parentCollector:(DirectoryItem *)parentCollector;

- (void) resetFrame;

@end // @interface ScanStackFrame


@interface TreeBuilder (PrivateMethods)

+ (item_size_t) getLogicalFileSizeForPath:(NSString *)path
                                 fileSize:(item_size_t)fileSize
                                  isDir:(BOOL)isDir
                                 fileType:(UTType *)fileType;

- (NSURL *)getVolumeRoot:(NSURL *)url;

// Create alert with details of failure
- (void) scanFailed:(NSString *)details;

/* Creates a tree context for the volume containing the path.
 *
 * The path should point to a directory. Returns nil if it does not. In this case, an alert
 * message is also set.
 */
- (TreeContext *)treeContextForVolumeContaining:(NSString *)path;

- (ScanTreeRoot *)treeRootForPath:(NSString *)path
                           context:(TreeContext *)treeContext;

- (void) addToStack:(DirectoryItem *)dirItem
               path:(NSString *)path
              dirfd:(int)dirfd
    parentCollector:(DirectoryItem *)parentCollector;

- (FileItem *)finalizeStackFrame:(ScanStackFrame *)stackFrame;

- (BOOL) visitItemWithName:(NSString *)name
                      stat:(struct stat *)stat
                parentPath:(NSString *)parentPath
                    parent:(ScanStackFrame *)parent
                   recurse:(BOOL)visitDescendants;
- (BOOL) visitHardLinkedItem:(struct stat *)stat;

// Return the number of sub-folders in a directory
- (int) determineNumSubFoldersForPath:(NSString *)path;

- (int) startScan:(NSString *)path;

// Scan a directory using getattrlistbulk
- (void) scanDirectoryWithFrame:(ScanStackFrame *)frame
                        recurse:(BOOL)visitDescendants
                   numProcessed:(int *)numProcessed
                  autoreleasePool:(NSAutoreleasePool **)pool;

@end // @interface TreeBuilder (PrivateMethods)

CFAbsoluteTime convertTimespec(struct timespec ts) {
  // Ignore nanoseconds; we do not need sub-second accuracy
  return (CFAbsoluteTime)((CFTimeInterval)ts.tv_sec - kCFAbsoluteTimeIntervalSince1970);
}

@implementation ScanStackFrame

// Overrides super's designated initialiser.
- (instancetype) init {
  if (self = [super init]) {
    parent = nil;
    collector = nil;
    parentCollector = nil;
    contentsEnumerated = NO;
    bulkBuffer = malloc(ATTR_BULK_BUFFER_SIZE);
    bulkRecordCursor = bulkBuffer;
    bulkRecordCount = 0;
    bulkRecordIndex = 0;
    dirfd = -1;
    path = nil;
  }
  return self;
}

// "Constructor" intended for repeated usage. It assumes init has already been invoked
- (void) initWithParent:(DirectoryItem *)parentVal
                    path:(NSString *)pathVal
                  dirfd:(int)dirfdVal
        parentCollector:(DirectoryItem *)parentCollectorVal {
  [self initWithParent: parentVal
             collector: parentVal
                  path: pathVal
                 dirfd: dirfdVal
       parentCollector: parentCollectorVal];
}

// "Constructor" intended for repeated usage. It assumes init has already been invoked
- (void) initWithParent:(DirectoryItem *)parentVal
              collector:(DirectoryItem *)collectorVal
                   path:(NSString *)pathVal
                  dirfd:(int)dirfdVal
        parentCollector:(DirectoryItem *)parentCollectorVal {
  [parentVal retain];
  [parent release];
  parent = parentVal;

  [collectorVal retain];
  [collector release];
  collector = collectorVal;

  [pathVal retain];
  [path release];
  path = pathVal;

  [parentCollectorVal retain];
  [parentCollector release];
  parentCollector = parentCollectorVal;

  contentsEnumerated = NO;
  bulkRecordCursor = bulkBuffer;
  bulkRecordCount = 0;
  bulkRecordIndex = 0;

  if (dirfd >= 0) {
    close(dirfd);
  }
  dirfd = dirfdVal;
}

- (void) resetFrame {
  if (dirfd >= 0) close(dirfd);
  dirfd = -1;
  [path release];
  path = nil;
  [parent release];
  parent = nil;
  [collector release];
  collector = nil;
  [parentCollector release];
  parentCollector = nil;
}

- (void) dealloc {
  [self resetFrame];
  free(bulkBuffer);
  [super dealloc];
}

@end // @implementation ScanStackFrame


@implementation TreeBuilder

+ (NSArray *)fileSizeMeasureNames {
  static NSArray  *fileSizeMeasureNames = nil;
  static dispatch_once_t  onceToken;

  dispatch_once(&onceToken, ^{
    fileSizeMeasureNames = [@[LogicalFileSizeName, PhysicalFileSizeName, TallyFileSizeName] retain];
  });

  return fileSizeMeasureNames;
}

- (instancetype) init {
  return [self initWithFilterSet: nil];
}


- (instancetype) initWithFilterSet:(FilterSet *)filterSetVal {
  if (self = [super init]) {
    filterSet = [filterSetVal retain];

    treeGuide = [[FilteredTreeGuide alloc] initWithFileItemTest: filterSet.fileItemTest];
    [treeGuide setPackagesAsFiles: filterSet.packagesAsFiles];

    treeBalancer = [[TreeBalancer alloc] init];
    treeBalanceDispatchQueue = TreeBalancer.dispatchQueue;
    typeInventory = [UniformTypeInventory.defaultUniformTypeInventory retain];

    hardLinkedFileNumbers = [[NSMutableSet alloc] initWithCapacity: 32];
    abort = NO;
    
    progressTracker =
      [[ScanProgressTracker alloc] initWithMaxLevel: NUM_SCAN_PROGRESS_ESTIMATE_LEVELS];
    
    dirStack = [[NSMutableArray alloc] initWithCapacity: 16];
    dirStackTopIndex = -1;
    
    [self setFileSizeMeasure: LogicalFileSizeName];
    
    logger = LogManager.defaultLogManager.mainLog;
    trustedLogger = LogManager.defaultLogManager.trustedLog;

    NSUserDefaults *args = NSUserDefaults.standardUserDefaults;
    NSString  *behavior = [args stringForKey: PackageCheckBehaviorKey];
    fastPackageCheckEnabled = ([behavior isEqualToString: FastBehavior]
                               || ([behavior isEqualToString: AdaptiveBehavior]
                                   && !filterSet.packagesAsFiles));
    os_log_info(logger, "fastPackageCheckEnabled = %d", fastPackageCheckEnabled);

    _alertMessage = nil;
  }
  return self;
}


- (void) dealloc {
  [filterSet release];

  [treeGuide release];
  [treeBalancer release];
  [typeInventory release];

  [hardLinkedFileNumbers release];
  [fileSizeMeasureName release];
  
  [progressTracker release];
  
  [dirStack release];

  [_alertMessage release];
  
  [super dealloc];
}


- (NSString *)fileSizeMeasure {
  return fileSizeMeasureName;
}

- (void) setFileSizeMeasure:(NSString *)measure {
  if ([measure isEqualToString: LogicalFileSizeName]) {
    fileSizeMeasure = LogicalFileSize;
  }
  else if ([measure isEqualToString: PhysicalFileSizeName]) {
    fileSizeMeasure = PhysicalFileSize;
  }
  else if ([measure isEqualToString: TallyFileSizeName]) {
    fileSizeMeasure = TallyFileSize;
  }
  else {
    NSAssert(NO, @"Invalid file size measure.");
  }
  
  if (measure != fileSizeMeasureName) {
    [fileSizeMeasureName release];
    fileSizeMeasureName = [measure retain];
  }
}


- (void) abort {
  abort = YES;
}

- (TreeContext *)buildTreeForPath:(NSString *)path {
  TreeContext  *treeContext = [self treeContextForVolumeContaining: path];
  if (treeContext == nil) {
    return nil;
  }

  DirectoryItem  *scanTree = [self treeRootForPath: path context: treeContext];

  [progressTracker startingTask];

  BOOL  ok = [self buildTreeForDirectory: scanTree atPath: path];

  [progressTracker finishedTask];

  if (! ok) {
    return nil;
  }

  [treeContext setScanTree: scanTree];
  _alertMessage = [[self createAlertMessage: scanTree] retain];

  return treeContext;
}

- (NSDictionary *)progressInfo {
  // To be safe, do not return info when aborted. Auto-releasing parts of constructed tree could
  // invalidate path construction done by progressTracker. Even though it does not look that could
  // happen with current code, it could after some refactoring.
  return abort ? nil : progressTracker.progressInfo;
}

@end // @implementation TreeBuilder


@implementation TreeBuilder (ProtectedMethods)

- (BOOL) buildTreeForDirectory:(DirectoryItem *)dirItem atPath:(NSString *)path {
  return [self scanTreeForDirectory: dirItem atPath: path];
}

- (BOOL) scanTreeForDirectory:(DirectoryItem *)dirItem atPath:(NSString *)path {
  os_log_debug(logger, "scanTreeForDirectory %@", path);

  NSAutoreleasePool  *autoreleasePool = nil;
  int  i = 0;
  dirStackTopIndex = -1;
  
  int dirfd = [self startScan: path];
  if (dirfd < 0) {
    return NO;
  }

  [self addToStack: dirItem path: path dirfd: dirfd parentCollector: nil];

  autoreleasePool = [[NSAutoreleasePool alloc] init];
  @try {
    // Process directories on the stack until empty
    while (!abort && dirStackTopIndex >= 0) {
      ScanStackFrame  *parent = dirStack[dirStackTopIndex];
      [self scanDirectoryWithFrame: parent
                           recurse: YES
                      numProcessed: &i
                   autoreleasePool: &autoreleasePool];

    }

    NSAssert(abort || dirStackTopIndex == -1, @"Final stack unwind failed?");
  }
  @finally {
    while (dirStackTopIndex >= 0) {
      ScanStackFrame *frame = dirStack[dirStackTopIndex--];
      [treeGuide emergedFromDirectory: frame->parent];
      [frame resetFrame];
    }
    [autoreleasePool release];
    dispatch_sync(treeBalanceDispatchQueue, ^{});
  }

  return !abort;
}

- (DirectoryItem *)getContentsForDirectory:(DirectoryItem *)dirItem
                                     atPath:(NSString *)path {
  ScanStackFrame  *parent = [[[ScanStackFrame alloc] init] autorelease];
  DirectoryItem  *collector = (DirectoryItem *)[dirItem duplicateFileItem: dirItem.parentDirectory];

  int dirfd = [self startScan: path];
  if (dirfd < 0) {
    return collector;
  }

  [parent initWithParent: dirItem
               collector: collector
                    path: path
                   dirfd: dirfd
         parentCollector: nil];

  NSAutoreleasePool  *autoreleasePool = [[NSAutoreleasePool alloc] init];
  int  i = 0;
  
  @try {
    [self scanDirectoryWithFrame: parent recurse: NO
                   numProcessed: &i autoreleasePool: &autoreleasePool];
  } @finally {
    [parent resetFrame];
    [autoreleasePool release];
  }

  return collector;
}

- (AlertMessage *)createAlertMessage:(DirectoryItem *)scanTree {
  if (fileSizeMeasure == LogicalFileSize) {
    if (scanTree.itemSize > totalPhysicalSize) {
      AlertMessage  *alert = [[[AlertMessage alloc] init] autorelease];
      alert.messageText = NSLocalizedString
        (@"The reported total size is larger than the actual size on disk", @"Alert message");
      NSString *fmt = NSLocalizedString
        (@"The actual (physical) size is %.1f%% of the reported (logical) size. Consider rescanning using the Physical file size measure",
         @"Alert message");
      float percentage = (100.0 * totalPhysicalSize) / scanTree.itemSize;
      alert.informativeText = [NSString stringWithFormat: fmt, percentage];
      return alert;
    }

    if (numOverestimatedFiles > 0) {
      AlertMessage  *alert = [[[AlertMessage alloc] init] autorelease];
      alert.messageText = NSLocalizedString
        (@"The reported size of some files is larger than their actual size on disk",
         @"Alert message");
      NSString *fmt = NSLocalizedString
        (@"For %d files the reported (logical) size is larger than their actual (physical) size. Consider rescanning using the Physical file size measure",
         @"Alert message");
      alert.informativeText = [NSString stringWithFormat: fmt, numOverestimatedFiles];
      return alert;
    }
  }

  return nil;
}

@end // @implementation TreeBuilder (ProtectedMethods)


@implementation TreeBuilder (PrivateMethods)

+ (item_size_t) getLogicalFileSizeForPath:(NSString *)path
                                 fileSize:(item_size_t)fileSize
                                  isDir:(BOOL)isDir
                                 fileType:(UTType *)fileType {
  if ([fileType.identifier isEqualToString: @"com.apple.icloud-file-fault"]) {
    NSURL  *url = [NSURL fileURLWithFileSystemRepresentation: path.fileSystemRepresentation
                                                 isDirectory: isDir
                                               relativeToURL: NULL];
    NSDictionary  *dict = [NSDictionary dictionaryWithContentsOfURL: url];
    NSNumber  *fileSizeNum = [dict objectForKey: @"NSURLFileSizeKey"];

    return fileSizeNum.unsignedLongLongValue;
  } else {
    return fileSize;
  }
}

- (NSURL *)getVolumeRoot:(NSURL *)url {
  NSError  *error = nil;
  NSURL  *volumeRoot = nil;

  [url getResourceValue: &volumeRoot forKey: NSURLVolumeURLKey error: &error];
  if (error != nil) {
    os_log(logger, "Failed to determine volume root of %@: %@", url, error.description);
    return nil;
  }
  os_log_info(logger, "VolumeURLKey: url = %@, volumeRoot = %@", url, volumeRoot);

  if ([url.path hasPrefix: volumeRoot.path]) {
    return volumeRoot;
  }

  os_log(logger, "Volume root prefix mismatch");

  // Try to determine the volume root the hard way. Traverse up the folder hierarchy until a
  // folder is found that is a volume root.
  volumeRoot = url;
  while (true) {
    NSNumber* isVolume;
    [volumeRoot getResourceValue: &isVolume forKey: NSURLIsVolumeKey error: &error];

    if (error != nil) {
      os_log(logger, "Failed to get IsVolumeKey for %@", volumeRoot);
      return nil;
    }

    if (isVolume.boolValue) {
      os_log_info(logger, "Found volume root %@", volumeRoot);
      return volumeRoot;
    }

    NSUInteger lenBefore = volumeRoot.path.length;
    volumeRoot = volumeRoot.URLByDeletingLastPathComponent;
    if (volumeRoot.path.length >= lenBefore) {
      os_log(logger, "Terminating traversal at %@ without finding volume root", volumeRoot);
      return nil;
    }
  }

  return nil;
}

- (void) scanFailed:(NSString *)details {
  [_alertMessage release];

  _alertMessage = [[AlertMessage alloc] init];
  _alertMessage.messageText = NSLocalizedString(@"Scanning failed", @"Alert message");
  _alertMessage.informativeText = details;
}

- (TreeContext *)treeContextForVolumeContaining:(NSString *)path {
  NSURL  *url = [NSURL fileURLWithPath: path];

  if (!url.isDirectory) {
    // This may happen when the directory has been deleted (which can happen when rescanning)
    os_log(logger, "Path to scan %@ is not a directory.", path);

    NSString *fmt = NSLocalizedString
      (@"The path %@ does not exist or is not a folder", @"Alert message");
    [self scanFailed: [NSString stringWithFormat: fmt, path]];

    return nil;
  }

  NSError  *error = nil;
  NSURL  *volumeRoot = [self getVolumeRoot: url];
  if (volumeRoot == nil) {
    // TODO: Check if there is fallback logic that could be used instead

    NSString *details = NSLocalizedString(@"Failed to determine volume root", @"Alert message");
    [self scanFailed: details];

    return nil;
  }

  NSNumber  *freeSpace;
  [volumeRoot getResourceValue: &freeSpace forKey: NSURLVolumeAvailableCapacityKey error: &error];
  if (error != nil) {
    os_log(logger, "Failed to determine free space for %@: %@", volumeRoot, error.description);
  }

  NSNumber  *volumeSize;
  [volumeRoot getResourceValue: &volumeSize forKey: NSURLVolumeTotalCapacityKey error: &error];
  if (error != nil) {
    os_log(logger, "Failed to determine capacity of %@: %@", volumeRoot, error.description);
  }

  NSString  *volumeFormat;
  [volumeRoot getResourceValue: &volumeFormat forKey: NSURLVolumeLocalizedFormatDescriptionKey
                         error: &error];
  if (error == nil) {
    os_log_info(logger, "Volume format = %@", volumeFormat);
  }

  ignoreHardLinksForDirectories = NO; // Default
  struct statfs volinfo;
  if (statfs(volumeRoot.path.fileSystemRepresentation, &volinfo) == 0) {
    os_log_info(logger, "fstypename = %s", volinfo.f_fstypename);
    if (strcmp("apfs", volinfo.f_fstypename) == 0) {
      // APFS does not support hardlinking directories. However, directories will have a non-zero
      // hardlink count, as each file it contains increases the count. So ignore this count when
      // deciding if a directory should be visited in APFS
      ignoreHardLinksForDirectories = YES;
    }
  }
  os_log_info(logger, "ignoreHardLinksForDirectories = %d", ignoreHardLinksForDirectories);

  return [[[TreeContext alloc] initWithVolumePath: volumeRoot.path
                                  fileSizeMeasure: fileSizeMeasureName
                                       volumeSize: volumeSize.unsignedLongLongValue
                                        freeSpace: freeSpace.unsignedLongLongValue
                                        filterSet: filterSet
                                      monitorPath: path] autorelease];
}

- (ScanTreeRoot *)treeRootForPath:(NSString *)path
                          context:(TreeContext *)treeContext {
  // Determine relative path
  NSString  *volumePath = treeContext.volumeTree.systemPathComponent;
  NSString  *relativePath =
    volumePath.length < path.length ? [path substringFromIndex: volumePath.length] : @"";
  if (relativePath.absolutePath) {
    // Strip leading slash.
    relativePath = [relativePath substringFromIndex: 1];
  }

  NSFileManager  *manager = NSFileManager.defaultManager;
  if (relativePath.length > 0) {
    os_log_info(logger, "Scanning volume %@ [%@], starting at %@",
                volumePath, [manager displayNameAtPath: volumePath], relativePath);
  }
  else {
    os_log_info(logger, "Scanning entire volume %@ [%@].",
                volumePath, [manager displayNameAtPath: volumePath]);
  }

  // Get the properties
  NSURL  *treeRootURL = [NSURL fileURLWithPath: path];
  FileItemOptions  flags = 0;
  if (treeRootURL.isPackage) {
    flags |= FileItemIsPackage;
  }
  if (treeRootURL.isHardLinked) {
    flags |= FileItemIsHardlinked;
  }

  ScanTreeRoot  *scanTree = [[[ScanTreeRoot alloc] initWithLabel: relativePath
                                                          parent: treeContext.scanTreeParent
                                                           flags: flags
                                                    creationTime: treeRootURL.creationTime
                                                modificationTime: treeRootURL.modificationTime
                                                      accessTime: treeRootURL.accessTime
                             ] autorelease];

  // Reset other state
  totalPhysicalSize = 0;
  numOverestimatedFiles = 0;
  [hardLinkedFileNumbers removeAllObjects];
  [_alertMessage release];
  _alertMessage = nil;

  return scanTree;
}

- (void) addToStack:(DirectoryItem *)dirItem
               path:(NSString *)path
              dirfd:(int)dirfd
    parentCollector:(DirectoryItem *)parentCollector {
//  os_log_debug(logger, "Push: %@", path);

  // Expand stack if required
  if (dirStackTopIndex + 1 == (int)dirStack.count) {
    [dirStack addObject: [[[ScanStackFrame alloc] init] autorelease]];
  }
  
  // Add the item to the stack. Overwriting the previous entry.
  [dirStack[++dirStackTopIndex] initWithParent: dirItem
                                          path: path
                                         dirfd: dirfd
                               parentCollector: parentCollector];
  
  [treeGuide descendIntoDirectory: dirItem];
  [progressTracker processingFolder: dirItem];
  os_log_debug(trustedLogger, "Scanning %{public}@", path);
  if (dirStackTopIndex < NUM_SCAN_PROGRESS_ESTIMATE_LEVELS) {
    [progressTracker setNumSubFolders: [self determineNumSubFoldersForPath: path]];
  }
}

- (FileItem *)finalizeStackFrame:(ScanStackFrame *)topDir {
//  os_log_debug(logger, "Pop: %@", topDir->path);

  DirectoryItem  *dirItem = topDir->parent;
  [dirItem setSize]; // Fix the size

  [treeGuide emergedFromDirectory: dirItem];
  [progressTracker processedFolder: dirItem];

  if ([treeGuide includeFileItem: dirItem] == nil) {
    return nil;
  }

  dispatch_async(treeBalanceDispatchQueue, ^{ [dirItem balanceTree: treeBalancer]; });

  // Let it survive after scan stack frame is reset
  return [[dirItem retain] autorelease];
}

- (BOOL) visitItemWithName:(NSString *)name
                      stat:(struct stat *)statBlock
                parentPath:(NSString *)parentPath
                    parent:(ScanStackFrame *)parent
                   recurse:(BOOL)visitDescendants {
  FileItemOptions  flags = 0;
  BOOL  isDirectory = S_ISDIR(statBlock->st_mode);
  NSString *path = nil;
  NSString *extension = name.pathExtension;

  // Apple File System (APFS) does not support hard-links to directories, but has "hard links"
  // for each file a directory contains (including . and ..). So a possible optimization is to skip
  // the hardlink check for directories on APFS as this will greatly reduce the size of the set
  // used to track the hard-linked items. Note, some directories in /System/Volumes have the same
  // inode but their contents differ so there's no duplication in scanning each of these.
  if (statBlock->st_nlink > 1 && !(isDirectory && ignoreHardLinksForDirectories)) {
    flags |= FileItemIsHardlinked;

    if (![self visitHardLinkedItem: statBlock]) {
      // Do not visit descendants if the item was a directory
      if (isDirectory) {
        visitDescendants = NO;
      }

      return visitDescendants;
    }
  }

  if (isDirectory) {
    path = [parentPath stringByAppendingPathComponent: name];

    if (!fastPackageCheckEnabled || extension.length > 0) {
      BOOL isPackage = NO;

      // The package check is relatively expensive (it consumes about 30% of total scanning time).
      //
      // As most packages are identified by extension and few normal directories have an extension,
      // an optimization it to only perform this check if the path has an extension. A drawback is
      // that this fails to identify some packages. On my macOS 12.6.3 on 2023/05 this applies to
      // ~/Pictures/Photo Booth Library and ~/Library/Application Support/SyncServices/Local.
      NSURL  *url = [NSURL fileURLWithFileSystemRepresentation: path.fileSystemRepresentation
                                                   isDirectory: YES
                                                 relativeToURL: NULL];
      isPackage = url.isPackage;

      if (isPackage) {
        flags |= FileItemIsPackage;
      }
    }
    
    DirectoryItem  *dirChildItem = [[DirectoryItem alloc]
                                    initWithLabel: name
                                           parent: parent->parent
                                            flags: flags
                                     creationTime: convertTimespec(statBlock->st_birthtimespec)
                                 modificationTime: convertTimespec(statBlock->st_mtimespec)
                                       accessTime: convertTimespec(statBlock->st_atimespec)];

    NSString* skipReason = nil;
    if (statBlock->st_dev != scanRootDeviceID) {
      // Preserve legacy FTS_XDEV behavior: include mountpoint directory but do not descend into it.
      skipReason = @"Skipping scan across filesystem boundary";
    } else if (statBlock->st_flags & SF_DATALESS) {
      // Do not scan contents of folders that are not already available offline. Doing so would
      // trigger download of their contents. This is unwanted, as the state of the volume should
      // not change as a result of the scan. Additionally, it would slow down scanning
      // unnecessarily (and block scanning if there is no network access).
      skipReason = @"Skipping scan of dataless folder";
    } else if ([name isEqualToString: @"Data"] &&
               [dirChildItem.path isEqualToString: @"/System/Volumes/Data"]) {
      // Do not scan the contents of the System Data volume to prevent its contents from being
      // scanned twice (as the contents also appear inside the root via firmlinks). Ideally, we use
      // a more generic mechanism for this, similar to how hardlinks are handled, but there does
      // not yet seem to be an API to support this.
      skipReason = @"Skipping scan of data volume";
    } else if (![treeGuide shouldDescendIntoDirectory: dirChildItem]) {
      skipReason = @"Skipping filtered folder";
    }

    if (skipReason) {
      os_log_info(logger, "%@ %@", skipReason, path);
      [progressTracker skippedFolder: dirChildItem];
      visitDescendants = NO;
    } else {
      if (visitDescendants) {
        // Open the subdirectory for getattrlistbulk
        int subdirfd = openat(parent->dirfd,
                              name.fileSystemRepresentation,
                              O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        if (subdirfd < 0) {
          os_log_debug(logger, "Error opening directory %@: %s", path, strerror(errno));
          visitDescendants = NO;
        } else {
          [self addToStack: dirChildItem
                       path: path
                      dirfd: subdirfd
            parentCollector: parent->collector];
        }
      } else {
        // When performing a shallow scan, we cannot apply a filter based on its contents (size).
        [parent->collector addSubdir: dirChildItem];
      }
    }

    [dirChildItem release];
  }
  else { // A file node.
    // According to stat(2) documentation, st_blocks returns the number of 512B blocks allocated.
    item_size_t  physicalFileSize = statBlock->st_blocks * 512;
    item_size_t  fileSize;

    UTType *fileType = [typeInventory uniformTypeForExtension: extension];

    switch (fileSizeMeasure) {
      case LogicalFileSize: {
        if ([fileType.identifier isEqualToString: @"com.apple.icloud-file-fault"]) {
          path = [parentPath stringByAppendingPathComponent: name];
        }
        fileSize = [TreeBuilder getLogicalFileSizeForPath: path
                                                fileSize: statBlock->st_size
                                                  isDir: NO
                                                 fileType: fileType];
        totalPhysicalSize += physicalFileSize;

        if (fileSize > physicalFileSize) {
          if (os_log_type_enabled(logger, OS_LOG_TYPE_DEBUG)) {
            if (path == nil) {
              path = [parentPath stringByAppendingPathComponent: name];
            }
            os_log_debug(logger, "Warning: logical file size larger than physical file size for %@ (%llu > %llu)",
                  path, fileSize, physicalFileSize);
          }
          numOverestimatedFiles++;
        }
        break;
      }
      case PhysicalFileSize:
        fileSize = physicalFileSize;
        break;
      case TallyFileSize:
        fileSize = 1;
    }

    PlainFileItem  *fileChildItem =
      [[PlainFileItem alloc] initWithLabel: name
                                    parent: parent->parent
                                      size: fileSize
                                      type: fileType
                                     flags: flags
                              creationTime: convertTimespec(statBlock->st_birthtimespec)
                          modificationTime: convertTimespec(statBlock->st_mtimespec)
                                accessTime: convertTimespec(statBlock->st_atimespec)];

    // Only add file items that pass the filter test.
    if ( [treeGuide includeFileItem: fileChildItem] ) {
      [parent->collector addFile: fileChildItem];
    }

    [fileChildItem release];
  }

  return visitDescendants;
}


/* Returns YES if item should be included in the tree. It returns NO when the item is hard-linked
 * and has already been encountered.
 */
- (BOOL) visitHardLinkedItem:(struct stat *)statBlock {
  NSNumber  *fileNumber = [NSNumber numberWithUnsignedLongLong: statBlock->st_ino];
  NSUInteger  sizeBefore = hardLinkedFileNumbers.count;

  [hardLinkedFileNumbers addObject: fileNumber];

  return sizeBefore < hardLinkedFileNumbers.count; // Only scan newly encountered items
}

- (int) determineNumSubFoldersForPath:(NSString *)path {
  int  numSubDirs = 0;
  DIR *dir = opendir(path.fileSystemRepresentation);
  if (dir == NULL) {
    return 0;
  }
  
  struct dirent *entry;
  while (!abort && (entry = readdir(dir)) != NULL) {
    if (entry->d_name[0] == '.') {
      if (entry->d_name[1] == '\0' || 
          (entry->d_name[1] == '.' && entry->d_name[2] == '\0')) {
        continue; // Skip . and ..
      }
    }
    
    if (entry->d_type == DT_DIR) {
      numSubDirs++;
    } else if (entry->d_type == DT_UNKNOWN) {
      // Need to stat to determine type
      struct stat st;
      if (fstatat(dirfd(dir), entry->d_name, &st, AT_SYMLINK_NOFOLLOW) == 0 && S_ISDIR(st.st_mode)) {
        numSubDirs++;
      }
    }
  }
  
  closedir(dir);
  return numSubDirs;
}

- (int) startScan:(NSString *)path {
  int fd = open(path.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (fd < 0) {
    os_log_debug(logger, "Error: open failed for %@: %s", path, strerror(errno));
    return -1;
  }

  struct stat st;
  if (fstat(fd, &st) != 0) {
    os_log_debug(logger, "Error: fstat failed for %@: %s", path, strerror(errno));
    close(fd);
    return -1;
  }

  scanRootDeviceID = st.st_dev;

  return fd;
}

// Scan a directory using getattrlistbulk
- (void) scanDirectoryWithFrame:(ScanStackFrame *)frame
                        recurse:(BOOL)visitDescendants
                   numProcessed:(int *)numProcessed
                  autoreleasePool:(NSAutoreleasePool **)pool {
  struct attrlist attrs = bulkDirectoryAttributes(fileSizeMeasure == LogicalFileSize);
  if (frame->bulkBuffer == NULL) {
    os_log_error(logger, "Failed to allocate scan buffer for %@", frame->path);
    frame->contentsEnumerated = YES;
  }

  while (!abort && !frame->contentsEnumerated) {
    if (frame->bulkRecordIndex == frame->bulkRecordCount) {
      int count = getattrlistbulk(frame->dirfd, &attrs, frame->bulkBuffer,
                                  ATTR_BULK_BUFFER_SIZE, 0);
      if (count <= 0) {
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) {
          os_log_error(logger, "getattrlistbulk failed for %@: %s", frame->path, strerror(errno));
        }
        frame->contentsEnumerated = YES;
        break;
      }
      frame->bulkRecordCount = count;
      frame->bulkRecordIndex = 0;
      frame->bulkRecordCursor = frame->bulkBuffer;
    }

    const char *record = frame->bulkRecordCursor;
    size_t available = frame->bulkBuffer + ATTR_BULK_BUFFER_SIZE - record;
    uint32_t length = 0;
    if (available >= sizeof(length)) memcpy(&length, record, sizeof(length));
    if (length < sizeof(length) + sizeof(attribute_set_t) || length > available) {
      os_log_error(logger, "Invalid bulk record in %@", frame->path);
      frame->contentsEnumerated = YES;
      break;
    }
    frame->bulkRecordCursor += length;
    ++frame->bulkRecordIndex;

    struct stat st;
    bool complete;
    const char *name = parseBulkDirectoryEntry(record, length, &attrs, &st, &complete);
    if (name == NULL || !strcmp(name, ".") || !strcmp(name, "..")) continue;
    if (!complete && fstatat(frame->dirfd, name, &st, AT_SYMLINK_NOFOLLOW) != 0) {
      os_log_info(logger, "Metadata lookup failed for %s in %@: %s", name, frame->path, strerror(errno));
      continue;
    }
    if (++(*numProcessed) == AUTORELEASE_PERIOD) {
      [*pool release];
      *pool = [[NSAutoreleasePool alloc] init];
      *numProcessed = 0;
    }
    NSString *nameString = [NSFileManager.defaultManager
      stringWithFileSystemRepresentation: name length: strlen(name)];
    if (nameString == nil) continue;
    [self visitItemWithName: nameString stat: &st parentPath: frame->path
                     parent: frame recurse: visitDescendants];
    // A child was pushed: resume this buffer after that child has been completed.
    if (visitDescendants && dirStack[dirStackTopIndex] != frame) return;
  }

  if (!visitDescendants || abort) return;
  FileItem *finalizedDir = [self finalizeStackFrame: frame];
  if (finalizedDir != nil && frame->parentCollector != nil) {
    [frame->parentCollector addSubdir: finalizedDir];
  }
  [frame resetFrame];
  --dirStackTopIndex;
}

@end // @implementation TreeBuilder (PrivateMethods)
