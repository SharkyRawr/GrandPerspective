/* GrandPerspective, Version 3.6.3 
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
#include <sys/vnode.h>
#include <dirent.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef FSOPT_PACK_INVAL_ATTRS
#define FSOPT_PACK_INVAL_ATTRS 0
#endif

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
static const uint64_t ATTR_BULK_OPTIONS = FSOPT_PACK_INVAL_ATTRS;

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
  // which is a pre-requisite before then can be added to their parent directory.
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

@end // @interface ScanStackFrame


@interface TreeBuilder (PrivateMethods)

+ (item_size_t) getLogicalFileSizeForPath:(NSString *)path
                                 fileSize:(item_size_t)fileSize
                                  isDir:(BOOL)isDir
                                 fileType:(UniformType *)fileType;

+ (NSURL *)getVolumeRoot:(NSURL *)url;

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
- (BOOL) unwindStackToParent:(NSString *)parentPath;

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
- (void) stopScan:(int)fd;

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

static BOOL readBulkField(const char **cursor,
                          const char *recordEnd,
                          void *dest,
                          size_t size) {
  if ((size_t)(recordEnd - *cursor) < size) {
    return NO;
  }

  memcpy(dest, *cursor, size);
  *cursor += size;
  return YES;
}

static mode_t modeForObjectType(fsobj_type_t objType) {
  switch (objType) {
    case VREG:
      return S_IFREG;
    case VDIR:
      return S_IFDIR;
    case VBLK:
      return S_IFBLK;
    case VCHR:
      return S_IFCHR;
    case VLNK:
      return S_IFLNK;
    case VSOCK:
      return S_IFSOCK;
    case VFIFO:
      return S_IFIFO;
    default:
      return 0;
  }
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
  if (parent != parentVal) {
    [parent release];
  }
  parent = [parentVal retain];

  if (collector != collectorVal) {
    [collector release];
  }
  collector = [collectorVal retain];

  if (path != pathVal) {
    [path release];
  }
  path = [pathVal retain];

  if (parentCollector != parentCollectorVal) {
    [parentCollector release];
  }
  parentCollector = [parentCollectorVal retain];

  contentsEnumerated = NO;
  bulkRecordCursor = bulkBuffer;
  bulkRecordCount = 0;
  bulkRecordIndex = 0;

  if (dirfd >= 0) {
    close(dirfd);
  }
  dirfd = dirfdVal;
}

- (void) dealloc {
  if (dirfd >= 0) {
    close(dirfd);
    dirfd = -1;
  }
  [path release];
  [parent release];
  [collector release];
  [parentCollector release];
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
    uniformTypeCacheByExtension = [[NSMutableDictionary alloc] initWithCapacity: 128];
    scanRootDeviceIDKnown = NO;
    abort = NO;
    
    progressTracker =
      [[ScanProgressTracker alloc] initWithMaxLevel: NUM_SCAN_PROGRESS_ESTIMATE_LEVELS];
    
    dirStack = [[NSMutableArray alloc] initWithCapacity: 16];
    dirStackTopIndex = -1;
    
    [self setFileSizeMeasure: LogicalFileSizeName];
    
    NSUserDefaults *args = NSUserDefaults.standardUserDefaults;
    debugLogEnabled = [args boolForKey: @"logAll"] || [args boolForKey: @"logScanning"];

    NSString  *behavior = [args stringForKey: PackageCheckBehaviorKey];
    fastPackageCheckEnabled = ([behavior isEqualToString: FastBehavior]
                               || ([behavior isEqualToString: AdaptiveBehavior]
                                   && !filterSet.packagesAsFiles));
    NSLog(@"fastPackageCheckEnabled = %d", fastPackageCheckEnabled);

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
  [uniformTypeCacheByExtension release];
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
//  NSLog(@"scanTreeForDirectory %@", path);

  NSAutoreleasePool  *autoreleasePool = nil;
  int  i = 0;
  dirStackTopIndex = -1;
  
  int dirfd = [self startScan: path];
  if (dirfd < 0) {
    return NO;
  }

  [self addToStack: dirItem path: path dirfd: dirfd parentCollector: nil];

  @try {
    // Process directories on the stack until empty
    while (dirStackTopIndex >= 0) {
      ScanStackFrame  *parent = dirStack[dirStackTopIndex];
      [self scanDirectoryWithFrame: parent
                           recurse: YES
                      numProcessed: &i
                   autoreleasePool: &autoreleasePool];
      
      if (abort) {
        return NO;
      }
    }

    NSAssert(dirStackTopIndex == -1, @"Final stack unwind failed?");
  }
  @finally {
    [autoreleasePool release];
  }

  // Wait for the tree balancing to end
  dispatch_sync(treeBalanceDispatchQueue, ^{});

  return YES;
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

  NSAutoreleasePool  *autoreleasePool = nil;
  int  i = 0;
  
  [self scanDirectoryWithFrame: parent
                        recurse: NO
                   numProcessed: &i
                autoreleasePool: &autoreleasePool];
  
  [autoreleasePool release];

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
                                 fileType:(UniformType *)fileType {
  if ([fileType.uniformTypeIdentifier isEqualToString: @"com.apple.icloud-file-fault"]) {
    NSURL  *url = [NSURL fileURLWithFileSystemRepresentation: path.UTF8String
                                                 isDirectory: isDir
                                               relativeToURL: NULL];
    NSDictionary  *dict = [NSDictionary dictionaryWithContentsOfURL: url];
    NSNumber  *fileSizeNum = [dict objectForKey: @"NSURLFileSizeKey"];

    return fileSizeNum.unsignedLongLongValue;
  } else {
    return fileSize;
  }
}

+ (NSURL *)getVolumeRoot:(NSURL *)url {
  NSError  *error = nil;
  NSURL  *volumeRoot = nil;

  [url getResourceValue: &volumeRoot forKey: NSURLVolumeURLKey error: &error];
  if (error != nil) {
    NSLog(@"Failed to determine volume root of %@: %@", url, error.description);
    return nil;
  }
  NSLog(@"VolumeURLKey: url = %@, volumeRoot = %@", url, volumeRoot);

  if ([url.path hasPrefix: volumeRoot.path]) {
    return volumeRoot;
  }

  NSLog(@"Volume root prefix mismatch");

  // Try to determine the volume root the hard way. Traverse up the folder hierarchy until a
  // folder is found that is a volume root.
  volumeRoot = url;
  while (true) {
    NSNumber* isVolume;
    [volumeRoot getResourceValue: &isVolume forKey: NSURLIsVolumeKey error: &error];

    if (error != nil) {
      NSLog(@"Failed to get IsVolumeKey for %@", volumeRoot);
      return nil;
    }

    if (isVolume.boolValue) {
      NSLog(@"Found volume root %@", volumeRoot);
      return volumeRoot;
    }

    NSUInteger lenBefore = volumeRoot.path.length;
    volumeRoot = volumeRoot.URLByDeletingLastPathComponent;
    if (volumeRoot.path.length >= lenBefore) {
      NSLog(@"Terminating traversal at %@ without finding volume root", volumeRoot);
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
    NSLog(@"Path to scan %@ is not a directory.", path);

    NSString *fmt = NSLocalizedString
      (@"The path %@ does not exist or is not a folder", @"Alert message");
    [self scanFailed: [NSString stringWithFormat: fmt, path]];

    return nil;
  }

  NSError  *error = nil;
  NSURL  *volumeRoot = [TreeBuilder getVolumeRoot: url];
  if (volumeRoot == nil) {
    // TODO: Check if there is fallback logic that could be used instead

    NSString *details = NSLocalizedString(@"Failed to determine volume root", @"Alert message");
    [self scanFailed: details];

    return nil;
  }

  NSNumber  *freeSpace;
  [volumeRoot getResourceValue: &freeSpace forKey: NSURLVolumeAvailableCapacityKey error: &error];
  if (error != nil) {
    NSLog(@"Failed to determine free space for %@: %@", volumeRoot, error.description);
  }

  NSNumber  *volumeSize;
  [volumeRoot getResourceValue: &volumeSize forKey: NSURLVolumeTotalCapacityKey error: &error];
  if (error != nil) {
    NSLog(@"Failed to determine capacity of %@: %@", volumeRoot, error.description);
  }

  NSString  *volumeFormat;
  [volumeRoot getResourceValue: &volumeFormat forKey: NSURLVolumeLocalizedFormatDescriptionKey
                         error: &error];
  if (error == nil) {
    NSLog(@"Volume format = %@", volumeFormat);
  }

  ignoreHardLinksForDirectories = NO; // Default
  struct statfs volinfo;
  if (statfs(volumeRoot.path.fileSystemRepresentation, &volinfo) == 0) {
    NSLog(@"fstypename = %s", volinfo.f_fstypename);
    if (strcmp("apfs", volinfo.f_fstypename) == 0) {
      // APFS does not support hardlinking directories. However, directories will have a non-zero
      // hardlink count, as each file it contains increases the count. So ignore this count when
      // deciding if a directory should be visited in APFS
      ignoreHardLinksForDirectories = YES;
    }
  }
  NSLog(@"ignoreHardLinksForDirectories = %d", ignoreHardLinksForDirectories);

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
    NSLog(@"Scanning volume %@ [%@], starting at %@", volumePath,
          [manager displayNameAtPath: volumePath], relativePath);
  }
  else {
    NSLog(@"Scanning entire volume %@ [%@].", volumePath,
          [manager displayNameAtPath: volumePath]);
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
//  NSLog(@"Push: %@", path);

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
  if (debugLogEnabled) {
    NSLog(@"Scanning %@", path);
  }
  if (dirStackTopIndex < NUM_SCAN_PROGRESS_ESTIMATE_LEVELS) {
    [progressTracker setNumSubFolders: [self determineNumSubFoldersForPath: path]];
  }
}

- (BOOL) unwindStackToParent:(NSString *)parentPath {
  FileItem  *finalizedSubdir = nil;
  while (dirStackTopIndex >= 0) {
    ScanStackFrame  *topDir = dirStack[dirStackTopIndex];
    if (finalizedSubdir != nil) {
      [topDir->collector addSubdir: finalizedSubdir];
    }
    if ((parentPath == nil && topDir == nil) || 
        (parentPath != nil && [topDir->path isEqualToString: parentPath])) {
      return YES;
    }

    finalizedSubdir = [self finalizeStackFrame: topDir];
    dirStackTopIndex--;
  }

  return parentPath == nil;
}

- (FileItem *)finalizeStackFrame:(ScanStackFrame *)topDir {
//  NSLog(@"Pop: %@", topDir->path);

  DirectoryItem  *dirItem = topDir->parent;
  [dirItem setSize]; // Fix the size

  [treeGuide emergedFromDirectory: dirItem];
  [progressTracker processedFolder: dirItem];

  if ([treeGuide includeFileItem: dirItem] == nil) {
    return nil;
  }

  dispatch_async(treeBalanceDispatchQueue, ^{ [dirItem balanceTree: treeBalancer]; });

  return dirItem;
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
      NSURL  *url = [NSURL fileURLWithFileSystemRepresentation: path.UTF8String
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
    if (scanRootDeviceIDKnown && statBlock->st_dev != (dev_t)scanRootDeviceID) {
      // Preserve legacy FTS_XDEV behavior: include mountpoint directory but do not descend into it.
      skipReason = @"Skipping scan across filesystem boundary at %@";
    } else if (statBlock->st_flags & SF_DATALESS) {
      // Do not scan contents of folders that are not already available offline. Doing so would
      // trigger download of their contents. This is unwanted, as the state of the volume should
      // not change as a result of the scan. Additionally, it would slow down scanning
      // unnecessarily (and block scanning if there is no network access).
      skipReason = @"Skipping scan of dataless folder %@";
    } else if ([name isEqualToString: @"Data"] &&
               [dirChildItem.path isEqualToString: @"/System/Volumes/Data"]) {
      // Do not scan the contents of the System Data volume to prevent its contents from being
      // scanned twice (as the contents also appear inside the root via firmlinks). Ideally, we use
      // a more generic mechanism for this, similar to how hardlinks are handled, but there does
      // not yet seem to be an API to support this.
      skipReason = @"Skipping scan of data volume %@";
    } else if (![treeGuide shouldDescendIntoDirectory: dirChildItem]) {
      skipReason = @"Skipping scan of %@ (filtered out)";
    }

    if (skipReason) {
      NSLog(skipReason, path);
      [progressTracker skippedFolder: dirChildItem];
      visitDescendants = NO;
    } else {
      if (visitDescendants) {
        // Open the subdirectory for getattrlistbulk
        int subdirfd = openat(parent->dirfd,
                              name.UTF8String,
                              O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        if (subdirfd < 0) {
          NSLog(@"Error opening directory %@: %s", path, strerror(errno));
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

    UniformType  *fileType = nil;
    if (extension.length > 0) {
      fileType = uniformTypeCacheByExtension[extension];
    }
    if (fileType == nil) {
      fileType = [typeInventory uniformTypeForExtension: extension];
      if (extension.length > 0 && fileType != nil) {
        uniformTypeCacheByExtension[extension] = fileType;
      }
    }

    switch (fileSizeMeasure) {
      case LogicalFileSize: {
        if ([fileType.uniformTypeIdentifier isEqualToString: @"com.apple.icloud-file-fault"]) {
          path = [parentPath stringByAppendingPathComponent: name];
        }
        fileSize = [TreeBuilder getLogicalFileSizeForPath: path
                                                fileSize: statBlock->st_size
                                                  isDir: NO
                                                 fileType: fileType];
        totalPhysicalSize += physicalFileSize;

        if (fileSize > physicalFileSize) {
          if (debugLogEnabled) {
            if (path == nil) {
              path = [parentPath stringByAppendingPathComponent: name];
            }
            NSLog(@"Warning: logical file size larger than physical file size for %@ (%llu > %llu)",
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
  DIR *dir = opendir(path.UTF8String);
  if (dir == NULL) {
    return 0;
  }
  
  struct dirent *entry;
  while ((entry = readdir(dir)) != NULL) {
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
      NSString *fullPath = [path stringByAppendingPathComponent:[NSString stringWithUTF8String:entry->d_name]];
      if (lstat(fullPath.UTF8String, &st) == 0 && S_ISDIR(st.st_mode)) {
        numSubDirs++;
      }
    }
  }
  
  closedir(dir);
  return numSubDirs;
}

- (int) startScan:(NSString *)path {
  int fd = open(path.UTF8String, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (fd < 0) {
    NSLog(@"Error: open failed for %@: %s", path, strerror(errno));
    return -1;
  }

  struct stat st;
  if (fstat(fd, &st) != 0) {
    NSLog(@"Error: fstat failed for %@: %s", path, strerror(errno));
    close(fd);
    return -1;
  }

  scanRootDeviceID = (uint64_t)st.st_dev;
  scanRootDeviceIDKnown = YES;

  return fd;
}

- (void) stopScan:(int)fd {
  if (fd >= 0) {
    close(fd);
  }
}

// Scan a directory using getattrlistbulk
- (void) scanDirectoryWithFrame:(ScanStackFrame *)frame
                        recurse:(BOOL)visitDescendants
                   numProcessed:(int *)numProcessed
                  autoreleasePool:(NSAutoreleasePool **)pool {
  BOOL scanFailed = NO;

  if (!frame->contentsEnumerated) {
    if (frame->bulkBuffer == NULL) {
      NSLog(@"Failed to allocate bulk scan buffer for %@", frame->path);
      frame->contentsEnumerated = YES;
      scanFailed = YES;
    }

    struct attrlist attrList;
    memset(&attrList, 0, sizeof(attrList));
    attrList.bitmapcount = ATTR_BIT_MAP_COUNT;
    attrList.commonattr = ATTR_CMN_RETURNED_ATTRS
                          | ATTR_CMN_NAME
                          | ATTR_CMN_OBJTYPE
                          | ATTR_CMN_DEVID
                          | ATTR_CMN_CRTIME
                          | ATTR_CMN_MODTIME
                          | ATTR_CMN_ACCTIME
                          | ATTR_CMN_FLAGS
                          | ATTR_CMN_FILEID;
    attrList.dirattr = ATTR_DIR_LINKCOUNT;
    attrList.fileattr = ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE;
    if (fileSizeMeasure == LogicalFileSize) {
      attrList.fileattr |= ATTR_FILE_DATALENGTH;
    }

    while (!abort && !frame->contentsEnumerated && !scanFailed) {
      if (frame->bulkRecordIndex >= frame->bulkRecordCount) {
        int numEntries = getattrlistbulk(frame->dirfd,
                                         &attrList,
                                         frame->bulkBuffer,
                                         ATTR_BULK_BUFFER_SIZE,
                                         ATTR_BULK_OPTIONS);
        if (numEntries == 0) {
          frame->contentsEnumerated = YES;
          break;
        }
        if (numEntries < 0) {
          NSLog(@"getattrlistbulk failed for %@: %s", frame->path, strerror(errno));
          frame->contentsEnumerated = YES;
          scanFailed = YES;
          break;
        }

        frame->bulkRecordCount = numEntries;
        frame->bulkRecordIndex = 0;
        frame->bulkRecordCursor = frame->bulkBuffer;
      }

      const char *recordStart = frame->bulkRecordCursor;
      const char *bufferEnd = frame->bulkBuffer + ATTR_BULK_BUFFER_SIZE;
      uint32_t entryLength = *(const uint32_t *)recordStart;

      if (entryLength < (sizeof(uint32_t) + sizeof(attribute_set_t))
          || recordStart + entryLength > bufferEnd) {
        if (debugLogEnabled) {
          NSLog(@"Unexpected getattrlistbulk record size %u for %@", entryLength, frame->path);
        }
        frame->contentsEnumerated = YES;
        scanFailed = YES;
        break;
      }

      const char *recordEnd = recordStart + entryLength;

      frame->bulkRecordCursor += entryLength;
      frame->bulkRecordIndex++;

      const char *field = recordStart + sizeof(uint32_t);
      attribute_set_t returnedAttrs;
      attrreference_t nameRef;
      const char *nameRefField = NULL;
      fsobj_type_t objType = VNON;
      struct timespec creationTime = {0, 0};
      struct timespec modificationTime = {0, 0};
      struct timespec accessTime = {0, 0};
      uint32_t itemFlags = 0;
      uint64_t fileId = 0;
      dev_t deviceId = 0;
      uint32_t dirLinkCount = 0;
      uint32_t fileLinkCount = 0;
      off_t fileAllocSize = 0;
      off_t fileDataLength = 0;
      BOOL hasNameRef = NO;
      BOOL metadataParseFailed = NO;

      if (!readBulkField(&field, recordEnd, &returnedAttrs, sizeof(returnedAttrs))) {
        if (debugLogEnabled) {
          NSLog(@"Failed to parse getattrlistbulk record for %@", frame->path);
        }
        scanFailed = YES;
        break;
      }

      if ((returnedAttrs.commonattr & ATTR_CMN_NAME) != 0) {
        nameRefField = field;
        if (!readBulkField(&field, recordEnd, &nameRef, sizeof(nameRef))) {
          if (debugLogEnabled) {
            NSLog(@"Failed to parse name in getattrlistbulk record for %@", frame->path);
          }
          continue;
        }
        hasNameRef = YES;
      }
      if ((returnedAttrs.commonattr & ATTR_CMN_OBJTYPE) != 0
          && !readBulkField(&field, recordEnd, &objType, sizeof(objType))) {
        metadataParseFailed = YES;
      }
      if ((returnedAttrs.commonattr & ATTR_CMN_CRTIME) != 0
          && !readBulkField(&field, recordEnd, &creationTime, sizeof(creationTime))) {
        metadataParseFailed = YES;
      }
      if ((returnedAttrs.commonattr & ATTR_CMN_MODTIME) != 0
          && !readBulkField(&field, recordEnd, &modificationTime, sizeof(modificationTime))) {
        metadataParseFailed = YES;
      }
      if ((returnedAttrs.commonattr & ATTR_CMN_ACCTIME) != 0
          && !readBulkField(&field, recordEnd, &accessTime, sizeof(accessTime))) {
        metadataParseFailed = YES;
      }
      if ((returnedAttrs.commonattr & ATTR_CMN_FLAGS) != 0
          && !readBulkField(&field, recordEnd, &itemFlags, sizeof(itemFlags))) {
        metadataParseFailed = YES;
      }
      if ((returnedAttrs.commonattr & ATTR_CMN_FILEID) != 0
          && !readBulkField(&field, recordEnd, &fileId, sizeof(fileId))) {
        metadataParseFailed = YES;
      }
      if ((returnedAttrs.commonattr & ATTR_CMN_DEVID) != 0
          && !readBulkField(&field, recordEnd, &deviceId, sizeof(deviceId))) {
        metadataParseFailed = YES;
      }
      if ((returnedAttrs.dirattr & ATTR_DIR_LINKCOUNT) != 0
          && !readBulkField(&field, recordEnd, &dirLinkCount, sizeof(dirLinkCount))) {
        metadataParseFailed = YES;
      }
      if ((returnedAttrs.fileattr & ATTR_FILE_LINKCOUNT) != 0
          && !readBulkField(&field, recordEnd, &fileLinkCount, sizeof(fileLinkCount))) {
        metadataParseFailed = YES;
      }
      if ((returnedAttrs.fileattr & ATTR_FILE_ALLOCSIZE) != 0
          && !readBulkField(&field, recordEnd, &fileAllocSize, sizeof(fileAllocSize))) {
        metadataParseFailed = YES;
      }
      if ((returnedAttrs.fileattr & ATTR_FILE_DATALENGTH) != 0
          && !readBulkField(&field, recordEnd, &fileDataLength, sizeof(fileDataLength))) {
        metadataParseFailed = YES;
      }

      if (metadataParseFailed && debugLogEnabled) {
        if (debugLogEnabled) {
          NSLog(@"Could not parse full bulk metadata for %@; falling back to fstatat", frame->path);
        }
      }

      const char *name = NULL;
      size_t maxNameBytes = 0;
      if (hasNameRef) {
        name = nameRefField + nameRef.attr_dataoffset;
      }
      if (hasNameRef && nameRef.attr_dataoffset >= 0 && name >= recordStart && name < recordEnd) {
        size_t availableBytes = (size_t)(recordEnd - name);
        maxNameBytes = MIN(availableBytes, (size_t)nameRef.attr_length);
      }

      if (!hasNameRef
          || name < recordStart
          || name >= recordEnd
          || maxNameBytes == 0
          || memchr(name, '\0', maxNameBytes) == NULL) {
        if (debugLogEnabled) {
          NSLog(@"Invalid entry in getattrlistbulk record for %@", frame->path);
        }
        continue;
      }

      if (++(*numProcessed) == AUTORELEASE_PERIOD) {
        [*pool release];
        *pool = [[NSAutoreleasePool alloc] init];
        *numProcessed = 0;
      }

      if (abort) {
        if (frame->dirfd >= 0) {
          close(frame->dirfd);
          frame->dirfd = -1;
        }
        return;
      }

      if (name[0] == '.' &&
          (name[1] == '\0' || (name[1] == '.' && name[2] == '\0'))) {
        continue;
      }

      NSString *nameStr = [NSString stringWithUTF8String: name];
      if (nameStr == nil) {
        if (debugLogEnabled) {
          NSLog(@"Failed to decode entry name in %@", frame->path);
        }
        continue;
      }

      struct stat statBuf;
      BOOL hasObjectType = (returnedAttrs.commonattr & ATTR_CMN_OBJTYPE) != 0;
      BOOL isDirectory = hasObjectType && objType == VDIR;
      BOOL isRegularFile = hasObjectType && objType == VREG;
      BOOL hasLinkCount = isDirectory
        ? (returnedAttrs.dirattr & ATTR_DIR_LINKCOUNT) != 0
        : (returnedAttrs.fileattr & ATTR_FILE_LINKCOUNT) != 0;
      BOOL needsDataLength = fileSizeMeasure == LogicalFileSize;
      BOOL hasFileSizes = isDirectory
        || ((returnedAttrs.fileattr & ATTR_FILE_ALLOCSIZE) != 0
            && (!needsDataLength || (returnedAttrs.fileattr & ATTR_FILE_DATALENGTH) != 0));
      BOOL hasCreationTime = (returnedAttrs.commonattr & ATTR_CMN_CRTIME) != 0;
      BOOL hasModificationTime = (returnedAttrs.commonattr & ATTR_CMN_MODTIME) != 0;
      BOOL hasAccessTime = (returnedAttrs.commonattr & ATTR_CMN_ACCTIME) != 0;
      BOOL hasDeviceID = (returnedAttrs.commonattr & ATTR_CMN_DEVID) != 0;
      BOOL hasFlags = (returnedAttrs.commonattr & ATTR_CMN_FLAGS) != 0;
      BOOL canUseBulkMetadata =
        !metadataParseFailed
        &&
        hasObjectType
        && (isDirectory || isRegularFile)
        && (returnedAttrs.commonattr & ATTR_CMN_FILEID) != 0
        && hasLinkCount
        && hasFileSizes
        &&
        // For directories we must know these to preserve behavior:
        // - st_dev for cross-filesystem skip
        // - st_flags for dataless skip
        (!isDirectory || (hasDeviceID && hasFlags));

      memset(&statBuf, 0, sizeof(statBuf));
      if (canUseBulkMetadata) {
        mode_t mode = modeForObjectType(objType);
        if (mode == 0) {
          canUseBulkMetadata = NO;
        } else {
          statBuf.st_mode = mode;
          statBuf.st_nlink = isDirectory ? dirLinkCount : fileLinkCount;
          if (statBuf.st_nlink == 0) {
            statBuf.st_nlink = 1;
          }
          if (hasCreationTime) {
            statBuf.st_birthtimespec = creationTime;
          }
          if (hasModificationTime) {
            statBuf.st_mtimespec = modificationTime;
          }
          if (hasAccessTime) {
            statBuf.st_atimespec = accessTime;
          }
          if (hasFlags) {
            statBuf.st_flags = itemFlags;
          }
          statBuf.st_ino = fileId;
          if (hasDeviceID) {
            statBuf.st_dev = deviceId;
          } else {
            statBuf.st_dev = (dev_t)scanRootDeviceID;
          }

          if (!isDirectory) {
            off_t allocSize = fileAllocSize > 0 ? fileAllocSize : 0;
            statBuf.st_size = fileDataLength > 0 ? fileDataLength : 0;
            statBuf.st_blocks = (blkcnt_t)((allocSize + 511) / 512);
          }
        }
      }

      if (!canUseBulkMetadata
          && fstatat(frame->dirfd, name, &statBuf, AT_SYMLINK_NOFOLLOW) != 0) {
        if (debugLogEnabled) {
          NSLog(@"Metadata lookup failed for %s in %@: %s", name, frame->path, strerror(errno));
        }
        continue;
      }

      [self visitItemWithName: nameStr
                         stat: &statBuf
                   parentPath: frame->path
                       parent: frame
                       recurse: visitDescendants];

      if (visitDescendants) {
        BOOL hasActiveStackFrame = dirStackTopIndex >= 0 && dirStackTopIndex < (int)dirStack.count;
        if (!hasActiveStackFrame || dirStack[dirStackTopIndex] != frame) {
          return;
        }
      }
    }
  }

  if (!visitDescendants) {
    if ((abort || frame->contentsEnumerated) && frame->dirfd >= 0) {
      close(frame->dirfd);
      frame->dirfd = -1;
    }
    return;
  }

  BOOL hasActiveStackFrame = dirStackTopIndex >= 0 && dirStackTopIndex < (int)dirStack.count;
  if (abort || !hasActiveStackFrame || dirStack[dirStackTopIndex] != frame) {
    if ((abort || frame->contentsEnumerated) && frame->dirfd >= 0) {
      close(frame->dirfd);
      frame->dirfd = -1;
    }
    return;
  }

  // Finalize and pop this directory from the stack
  FileItem *finalizedDir = [self finalizeStackFrame:frame];

  if (frame->dirfd >= 0) {
    close(frame->dirfd);
    frame->dirfd = -1;
  }

  dirStackTopIndex--;

  if (finalizedDir != nil && frame->parentCollector != nil) {
    [frame->parentCollector addSubdir:(DirectoryItem *)finalizedDir];
  }
}

@end // @implementation TreeBuilder (PrivateMethods)
