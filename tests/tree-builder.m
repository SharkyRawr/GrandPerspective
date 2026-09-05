#import "TreeBuilder.h"
#import "TreeContext.h"
#import "DirectoryItem.h"
#import "TreeRefresher.h"
#include <assert.h>
#include <fcntl.h>
#include <unistd.h>

@interface TreeBuilder (TestHooks)
- (BOOL)visitItemWithName:(NSString *)name stat:(struct stat *)st
              parentPath:(NSString *)path parent:(id)frame recurse:(BOOL)recurse;
@end
@interface CancellingBuilder : TreeBuilder
@end
@implementation CancellingBuilder
- (BOOL)visitItemWithName:(NSString *)name stat:(struct stat *)st
              parentPath:(NSString *)path parent:(id)frame recurse:(BOOL)recurse {
  BOOL result = [super visitItemWithName:name stat:st parentPath:path parent:frame recurse:recurse];
  if ([name isEqualToString:@"nested"]) [self abort];
  return result;
}
@end

static int openDescriptors(void) {
  int count = 0;
  for (int fd = 0; fd < 1024; ++fd) if (fcntl(fd, F_GETFD) != -1) ++count;
  return count;
}
int main(void) {
  @autoreleasepool {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *path = [@"/tmp" stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *nested = [path stringByAppendingPathComponent:@"nested"];
    assert([fm createDirectoryAtPath:nested withIntermediateDirectories:YES attributes:nil error:NULL]);
    NSData *data = [@"hello" dataUsingEncoding:NSUTF8StringEncoding];
    for (int i = 0; i < 2100; ++i) {
      assert(([data writeToFile:[nested stringByAppendingPathComponent:[NSString stringWithFormat:@"%d.txt",i]] atomically:NO]));
    }
    assert(link([[nested stringByAppendingPathComponent:@"0.txt"] fileSystemRepresentation],
                [[path stringByAppendingPathComponent:@"hardlink.txt"] fileSystemRepresentation]) == 0);
    for (NSString *measure in TreeBuilder.fileSizeMeasureNames) {
      @autoreleasepool {
        TreeBuilder *builder = [[TreeBuilder alloc] init];
        builder.fileSizeMeasure = measure;
        TreeContext *context = [builder buildTreeForPath:path];
        assert(context);
        if ([measure isEqualToString:LogicalFileSizeName]) assert(context.scanTree.itemSize == 10500);
        if ([measure isEqualToString:TallyFileSizeName]) assert(context.scanTree.itemSize == 2100);
        [context.scanTree setRescanFlag:DirectoryNeedsShallowRescan];
        TreeRefresher *refresh = [[TreeRefresher alloc] initWithFilterSet:nil oldTree:context.scanTree];
        refresh.fileSizeMeasure = measure;
        TreeContext *refreshed = [refresh buildTreeForPath:path];
        assert(refreshed && refreshed.scanTree.itemSize == context.scanTree.itemSize);
        [refresh release];
        [builder release];
      }
    }
    int before = openDescriptors();
    CancellingBuilder *cancel = [[CancellingBuilder alloc] init];
    assert([cancel buildTreeForPath:path] == nil);
    assert(openDescriptors() == before); // FDs released before builder is deallocated.
    [cancel release];
    assert([fm removeItemAtPath:path error:NULL]);
    puts("Tree sizes, hardlink deduplication, multi-buffer traversal, shallow refresh and cancellation passed.");
  }
}
