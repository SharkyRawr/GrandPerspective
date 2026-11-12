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

#import "TreeDrawer.h"

#import "DirectoryItem.h"
#import "FileItemMapping.h"
#import "FileItemMappingScheme.h"
#import "FilteredTreeGuide.h"
#import "GradientRectangleDrawer.h"
#import "TreeDrawerSettings.h"


@interface TreeDrawer (PrivateMethods)

- (void) colorSchemeChanged:(NSNotification *)notification;
- (void) updateColorMapper:(BOOL)forceRedraw;
- (void) updateColorMapperForSettings:(TreeDrawerSettings *)settings;

@end // @interface TreeDrawer (PrivateMethod)

@implementation TreeDrawer

// Overrides designated initialiser of base class
- (instancetype) initWithScanTree:(DirectoryItem *)scanTreeVal
                     colorPalette:(NSColorList *)colorPalette {
  TreeDrawerSettings  *settings = [[[TreeDrawerSettings alloc] init] autorelease];
  if (colorPalette) {
    settings = [settings settingsWithChangedColorPalette: colorPalette];
  }

  return [self initWithScanTree: scanTreeVal treeDrawerSettings: settings];
}

- (instancetype) initWithScanTree:(DirectoryItem *)scanTreeVal
               treeDrawerSettings:(TreeDrawerSettings *)settings {
  if (self = [super initWithScanTree: scanTreeVal
                        colorPalette: settings.colorPalette]) {
    [self updateSettings: settings];
    
    freeSpaceColor = [rectangleDrawer intValueForColor: NSColor.blackColor];
    usedSpaceColor = [rectangleDrawer intValueForColor: NSColor.darkGrayColor];
    visibleTreeBackgroundColor = [rectangleDrawer intValueForColor: NSColor.grayColor];
  }
  return self;
}

- (void) dealloc {
  [NSNotificationCenter.defaultCenter removeObserver: self];

  [_colorMapper release];
  [_colorScheme release];

  [super dealloc];
}


- (void) setColorScheme:(NSObject <FileItemMappingScheme> *)colorScheme {
  if (colorScheme != _colorScheme) {
    NSNotificationCenter  *nc = NSNotificationCenter.defaultCenter;

    [nc removeObserver: self
                  name: MappingSchemeChangedEvent
                object: _colorScheme];

    [_colorScheme release];
    _colorScheme = [colorScheme retain];

    [nc addObserver: self
           selector: @selector(colorSchemeChanged:)
               name: MappingSchemeChangedEvent
             object: _colorScheme];

    if (!colorScheme.dependsOnTreeDrawerSettings) {
      [self updateColorMapper: NO];
    }
  }
}


- (void) setMaskTest:(FileItemTest *)maskTest {
  [treeGuide setFileItemTest: maskTest];
}

- (FileItemTest *)maskTest {
  return treeGuide.fileItemTest;
}


- (void) updateSettings:(TreeDrawerSettings *)settings {
  [super updateSettings: settings];

  if (self.colorScheme != settings.colorScheme) {
    self.colorScheme = settings.colorScheme;
  }

  if (self.colorScheme.dependsOnTreeDrawerSettings) {
    [self updateColorMapperForSettings: settings];
  }

  [rectangleDrawer setColorPalette: settings.colorPalette];
  [rectangleDrawer setColorGradient: settings.colorGradient];
  [self setMaskTest: settings.maskTest];
}


// Overrides of protected methods

- (void) drawVisibleTreeAtRect:(FileItem *)visibleTree rect:(NSRect) rect {
  [rectangleDrawer drawBasicFilledRect: rect intColor: visibleTreeBackgroundColor];
}

- (void) drawUsedSpaceAtRect:(NSRect) rect {
  [rectangleDrawer drawBasicFilledRect: rect intColor: usedSpaceColor];
}

- (void) drawFreeSpaceAtRect:(NSRect) rect {
  [rectangleDrawer drawBasicFilledRect: rect intColor: freeSpaceColor];
}

- (void) drawFreedSpaceAtRect:(NSRect) rect {
  [rectangleDrawer drawBasicFilledRect: rect intColor: freeSpaceColor];
}

- (void) drawFileItem:(FileItem *)fileItem atRect:(NSRect) rect depth:(int) depth {
  NSUInteger  hash = [_colorMapper hashForFileItem: fileItem atDepth: depth];
  NSUInteger  colorIndex = [_colorMapper colorIndexForHash: hash
                                                 numColors: rectangleDrawer.numGradientColors];

  [rectangleDrawer drawGradientFilledRect: rect colorIndex: colorIndex];
}

@end // @implementation TreeDrawer

@implementation TreeDrawer (PrivateMethods)

- (void) colorSchemeChanged:(NSNotification *)notification {
  // Force a redraw as the mapping change was due to an internal change impacting the scheme,
  // instead of a settings change that the view is aware of.
  [self updateColorMapper: YES];
}

- (void) updateColorMapper:(BOOL)forceRedraw {
  self.colorMapper = [self.colorScheme fileItemMappingForTree: scanTree];

  NSNotificationCenter  *nc = NSNotificationCenter.defaultCenter;
  [nc postNotificationName: ColorMappingChangedEvent
                    object: self
                  userInfo: @{@"forceRedraw": [NSNumber numberWithBool: forceRedraw]}];
}

- (void) updateColorMapperForSettings:(TreeDrawerSettings *)settings {
  self.colorMapper = [self.colorScheme fileItemMappingForTree: scanTree settings: settings];

  NSNotificationCenter  *nc = NSNotificationCenter.defaultCenter;
  [nc postNotificationName: ColorMappingChangedEvent
                    object: self
                  userInfo: @{@"forceRedraw": [NSNumber numberWithBool: NO]}];
}

@end // @implementation TreeDrawer (PrivateMethod)
