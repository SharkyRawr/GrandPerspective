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

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString  *UniformTypeAddedEvent;
extern NSString  *UniformTypeKey;


@class FileItem;
@class UTType;

/* Maintains a collection of uniform types, dynamically extended with additional types when files of
 * a new type are encountered. It maintains various look-up tables to speed-up the mapping from a
 * file to the associated uniform type.
 *
 * Note: The implementation of this class is not thread-safe. However, it has been implemented so
 * that it can be used in a background thread (in particular, it ensures that notifications are
 * always posted from the main thread).
 */
@interface UniformTypeInventory : NSObject {

  // Maps NSStrings to UniformTypes
  NSMutableDictionary  *typeForExtension;

  // Maps NSStrings to UniformTypes
  NSMutableDictionary  *typeForUTI;

  NSUInteger  numUnrecognizedExtensions;
}

@property (class, nonatomic, readonly) UniformTypeInventory *defaultUniformTypeInventory;

@property (nonatomic, readonly) NSUInteger count;
@property (nonatomic, readonly) NSUInteger numUnrecognizedExtensions;

/* Returns the type associated with the given file extension. If there is no properly defined type,
 * it returns the type the generic "unknown" type (see -unknownUniformType).
 */
- (UTType *)uniformTypeForExtension:(NSString *)ext;

/* Returns the type that corresponds to the given UTI. If the UTI is not recognized, it returns nil.
 */
- (UTType *)uniformTypeForIdentifier:(NSString *)uti;

/* Enumerates over all types maintained by this inventory. These types include those that have been
 * registered directly, as well as those that have been registered indirectly (as a result of being
 * ancestors of a registered type).
 */
- (NSEnumerator *)uniformTypeEnumerator;

@end

NS_ASSUME_NONNULL_END
