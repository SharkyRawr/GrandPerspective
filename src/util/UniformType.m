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

#import "UniformType.h"

// The UTI that is used when the type is unknown (i.e. when there is no proper UTI associated with
// a given file or extension).
//
// It is only used as an internal UTI and not exported/visible outside the application.
NSString  *UnknownTypeUTI = @"unknown";


@implementation UTType (HelperMethods)

+ (UTType *)unknownType {
  static UTType*  unknownType;
  static dispatch_once_t  onceToken;

  dispatch_once(&onceToken, ^{
    unknownType = [[UTType typeWithFilenameExtension: @"gp-unknown-filetype"] retain];
  });

  return unknownType;
}

- (BOOL) isUnknown {
  return (self == UTType.unknownType);
}

- (NSString *)description {
  return (self.isUnknown
          ? NSLocalizedString(@"unknown file type", @"Description for 'unknown' UTI.")
          : self.localizedDescription);
}

- (NSString *)uniformTypeIdentifier {
  return (self.isUnknown ? UnknownTypeUTI : self.identifier);
}

- (NSSet *)parentUTTypes {
  if (self.isUnknown) {
    return [NSSet set];
  }

  NSSet*  ancestors = self.supertypes;
  NSMutableSet*  parents = [NSMutableSet setWithSet: ancestors];

  for (UTType* tp in ancestors) {
    [parents minusSet: tp.supertypes];
  }

  return parents;
}

@end
