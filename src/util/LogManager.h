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

@import os.log;

@interface LogManager : NSObject {
  os_log_t mainLog;
  os_log_t trustedLog;
}

@property (nonatomic, readonly) os_log_t mainLog;

// The trusted log should be used to log (potentially) private strings annotated as public
// (to avoid anonymization). This enables the log messages to be viewed without requiring
// users to grant explicit permissions (which is complex, and has the risk that it is not
// undone after it is not needed anymore).
//
// This log should only be used for debug messages (so that the messages are not persisted).
//
// By default this log is disabled. The log is only enabled via an explicit command-line
// parameter.
@property (nonatomic, readonly) os_log_t trustedLog;

@property (class, nonatomic, readonly) LogManager *defaultLogManager;

- (id)init;

@end
