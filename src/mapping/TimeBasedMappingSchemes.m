/* GrandPerspective, Version 3.8.1 
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

#import "TimeBasedMappingSchemes.h"

#import "FileItem.h"
#import "TimeBasedMapping.h"

@interface MappingByCreation : TimeBasedMapping
@end // @interface MappingByCreation

@interface MappingByModification : TimeBasedMapping
@end // @interface MappingByModification

@interface MappingByAccess : TimeBasedMapping
@end // @interface MappingByAccess


@implementation CreationMappingScheme

- (FileItemMapping *)fileItemMappingForTree:(DirectoryItem *)tree {
  return [[[MappingByCreation alloc] initWithTree: tree] autorelease];
}

@end // @implementation CreationMappingScheme

@implementation ModificationMappingScheme

- (FileItemMapping *)fileItemMappingForTree:(DirectoryItem *)tree {
  return [[[MappingByModification alloc] initWithTree: tree] autorelease];
}

@end // @implementation ModificationMappingScheme

@implementation AccessMappingScheme

- (FileItemMapping *)fileItemMappingForTree:(DirectoryItem *)tree {
  return [[[MappingByAccess alloc] initWithTree: tree] autorelease];
}

@end // @implementation AccessMappingScheme


@implementation MappingByCreation

- (CFAbsoluteTime) timeForFileItem:(FileItem *)fileItem {
  return fileItem.creationTime;
}

@end // @implementation MappingByCreation

@implementation MappingByModification

- (CFAbsoluteTime) timeForFileItem:(FileItem *)fileItem {
  return fileItem.modificationTime;
}

@end // @implementation MappingByModification


@implementation MappingByAccess

- (CFAbsoluteTime) timeForFileItem:(FileItem *)fileItem {
  return fileItem.accessTime;
}

@end // @implementation MappingByAccess
