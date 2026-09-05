// Run: clang -Wall -Wextra -Werror -fsanitize=address,undefined tests/bulk-directory-entry.c -o /tmp/gp-bulk-test && /tmp/gp-bulk-test
#include "../src/tree/BulkDirectoryEntry.h"
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(void) {
  char path[] = "/tmp/gp-bulk-XXXXXX";
  assert(mkdtemp(path));
  int fd = open(path, O_RDONLY | O_DIRECTORY);
  assert(fd >= 0);
  assert(mkdirat(fd, "folder", 0700) == 0);
  int file = openat(fd, "file", O_CREAT | O_RDWR, 0600);
  assert(file >= 0 && write(file, "hello", 5) == 5);
  close(file);
  assert(linkat(fd, "file", fd, "hardlink", 0) == 0);
  assert(symlinkat("file", fd, "symlink") == 0);
  assert(mkfifoat(fd, "fifo", 0600) == 0);
  for (int logical = 0; logical <= 1; ++logical) {
    assert(lseek(fd, 0, SEEK_SET) == 0);
    struct attrlist attrs = bulkDirectoryAttributes(logical);
    char buffer[8192];
    int count, total = 0, fast = 0;
    while ((count = getattrlistbulk(fd, &attrs, buffer, sizeof(buffer), 0)) > 0) {
      char *record = buffer;
      for (int i = 0; i < count; ++i) {
        uint32_t length;
        memcpy(&length, record, sizeof(length));
        struct stat bulk, expected;
        bool complete;
        const char *name = parseBulkDirectoryEntry(record, length, &attrs, &bulk, &complete);
        assert(name && fstatat(fd, name, &expected, AT_SYMLINK_NOFOLLOW) == 0);
        ++total;
        if (S_ISREG(expected.st_mode) || S_ISDIR(expected.st_mode)) {
          assert(complete);
          ++fast;
          assert(bulk.st_mode == (expected.st_mode & S_IFMT));
          assert(bulk.st_ino == expected.st_ino && bulk.st_dev == expected.st_dev);
          assert(bulk.st_flags == expected.st_flags);
          // APFS bulk directory link counts exclude child entries.
          if (S_ISREG(expected.st_mode)) assert(bulk.st_nlink == expected.st_nlink);
          assert(bulk.st_birthtimespec.tv_sec == expected.st_birthtimespec.tv_sec);
          assert(bulk.st_mtimespec.tv_sec == expected.st_mtimespec.tv_sec);
          assert(bulk.st_atimespec.tv_sec == expected.st_atimespec.tv_sec);
          if (S_ISREG(expected.st_mode)) {
            assert(bulk.st_blocks == expected.st_blocks);
            if (logical) assert(bulk.st_size == expected.st_size);
          }
        } else assert(!complete);
        // Truncation and an out-of-range name reference must be rejected.
        assert(!parseBulkDirectoryEntry(record, 8, &attrs, &bulk, &complete));
        char copy[8192];
        memcpy(copy, record, length);
        attrreference_t bad = { .attr_dataoffset = INT32_MAX, .attr_length = 20 };
        memcpy(copy + sizeof(uint32_t) + sizeof(attribute_set_t), &bad, sizeof(bad));
        assert(!parseBulkDirectoryEntry(copy, length, &attrs, &bulk, &complete));
        record += length;
      }
    }
    assert(count == 0 && total == 5 && fast == 3);
  }
  unlinkat(fd, "file", 0); unlinkat(fd, "hardlink", 0);
  unlinkat(fd, "symlink", 0); unlinkat(fd, "fifo", 0);
  unlinkat(fd, "folder", AT_REMOVEDIR);
  close(fd); rmdir(path);
  puts("Bulk metadata matches fstatat; special-file fallback and malformed records pass.");
}
