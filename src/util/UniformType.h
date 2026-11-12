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

#import <UniformTypeIdentifiers/UTType.h>

@interface UTType (HelperMethods)

/* Creates a shared file type instance that should be used for all unknown file types
 * (irrespective of their file extension).
 */
+ (UTType *)unknownType;

@property (nonatomic, readonly) BOOL isUnknown;

/* Thin wrapper around UTType.identifier. For the unknown type, it returns a fixed, human-readable
 * identifier.
 */
@property (nonatomic, readonly, copy) NSString *uniformTypeIdentifier;

/* Convenience method that constructs a set of all direct parents from the set of all ancestors.
 */
@property (nonatomic, readonly, copy) NSSet *parentUTTypes;

@end
