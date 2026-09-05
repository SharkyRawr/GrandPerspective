/* getattrlistbulk's wire format uses four-byte alignment, not C struct alignment.
 * Request only valid attributes (options = 0) and consume them in attr.h order.
 */
#ifndef GP_BULK_DIRECTORY_ENTRY_H
#define GP_BULK_DIRECTORY_ENTRY_H

#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/vnode.h>
#include <string.h>
#include <stdbool.h>

static inline struct attrlist bulkDirectoryAttributes(bool logicalSize) {
  struct attrlist attrs = { .bitmapcount = ATTR_BIT_MAP_COUNT };
  attrs.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_DEVID
    | ATTR_CMN_OBJTYPE | ATTR_CMN_CRTIME | ATTR_CMN_MODTIME | ATTR_CMN_ACCTIME
    | ATTR_CMN_FLAGS | ATTR_CMN_FILEID;
  attrs.dirattr = ATTR_DIR_LINKCOUNT | ATTR_DIR_MOUNTSTATUS;
  attrs.fileattr = ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE;
  if (logicalSize) attrs.fileattr |= ATTR_FILE_DATALENGTH;
  return attrs;
}

/* NULL means an invalid record. A valid name with complete == false requires
 * fstatat: missing metadata, special files, mount points and firmlink targets.
 */
static inline const char *parseBulkDirectoryEntry(const char *record, size_t length,
                                                 const struct attrlist *requested,
                                                 struct stat *st, bool *complete) {
  attribute_set_t attrs;
  attrreference_t name;
  fsobj_type_t type = VNON;
  uint32_t dirLinks = 0, fileLinks = 0, mountStatus = 0;
  off_t allocated = 0;
  const char *cursor = record + sizeof(uint32_t);
  const char *end = record + length;
  *complete = false;
  memset(st, 0, sizeof(*st));
  if (length < sizeof(uint32_t) + sizeof(attrs)) return NULL;
  memcpy(&attrs, cursor, sizeof(attrs));
  cursor += sizeof(attrs);
  const char *nameField = cursor;

#define READ_BULK(group, bit, value) do { \
  if (attrs.group & (bit)) { \
    if ((size_t)(end - cursor) < sizeof(value)) return NULL; \
    memcpy(&(value), cursor, sizeof(value)); \
    cursor += sizeof(value); \
  } \
} while (0)
  if (!(attrs.commonattr & ATTR_CMN_NAME)) return NULL;
  READ_BULK(commonattr, ATTR_CMN_NAME, name);
  READ_BULK(commonattr, ATTR_CMN_DEVID, st->st_dev);
  READ_BULK(commonattr, ATTR_CMN_OBJTYPE, type);
  READ_BULK(commonattr, ATTR_CMN_CRTIME, st->st_birthtimespec);
  READ_BULK(commonattr, ATTR_CMN_MODTIME, st->st_mtimespec);
  READ_BULK(commonattr, ATTR_CMN_ACCTIME, st->st_atimespec);
  READ_BULK(commonattr, ATTR_CMN_FLAGS, st->st_flags);
  READ_BULK(commonattr, ATTR_CMN_FILEID, st->st_ino);
  READ_BULK(dirattr, ATTR_DIR_LINKCOUNT, dirLinks);
  READ_BULK(dirattr, ATTR_DIR_MOUNTSTATUS, mountStatus);
  READ_BULK(fileattr, ATTR_FILE_LINKCOUNT, fileLinks);
  READ_BULK(fileattr, ATTR_FILE_ALLOCSIZE, allocated);
  READ_BULK(fileattr, ATTR_FILE_DATALENGTH, st->st_size);
#undef READ_BULK

  if (name.attr_dataoffset < 0 || name.attr_length == 0
      || (size_t)name.attr_dataoffset > (size_t)(end - nameField)) return NULL;
  const char *filename = nameField + name.attr_dataoffset;
  if (filename < cursor || name.attr_length > (size_t)(end - filename)
      || filename[name.attr_length - 1] != '\0') return NULL;

  bool directory = type == VDIR;
  st->st_mode = directory ? S_IFDIR : S_IFREG;
  st->st_nlink = directory ? dirLinks : fileLinks;
  st->st_blocks = allocated / 512;
  *complete = (type == VDIR || type == VREG)
    && (attrs.commonattr & requested->commonattr) == requested->commonattr
    && (directory ? (attrs.dirattr & requested->dirattr) == requested->dirattr
                  : (attrs.fileattr & requested->fileattr) == requested->fileattr)
    && !(mountStatus & DIR_MNTSTATUS_MNTPOINT)
    && !(st->st_flags & SF_FIRMLINK);
  return filename;
}
#endif
