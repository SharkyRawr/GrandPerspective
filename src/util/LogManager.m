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

#import "LogManager.h"

@implementation LogManager

+ (LogManager *)defaultLogManager {
  static LogManager  *defaultLogManagerInstance = nil;
  static dispatch_once_t onceToken;

  dispatch_once(&onceToken, ^{
    defaultLogManagerInstance = [[LogManager alloc] init];
  });

  return defaultLogManagerInstance;
}

- (id) init {
  if (self = [super init]) {
    NSUserDefaults *args = NSUserDefaults.standardUserDefaults;
    bool enableTrustedLog = [args boolForKey: @"logAll"];

    mainLog = os_log_create("net.sf.grandperspectiv", "main");
    trustedLog = (enableTrustedLog
                  ? os_log_create("net.sf.grandperspectiv", "trusted")
                  : OS_LOG_DISABLED);

    os_log(mainLog, "trusted log enabled = %d", enableTrustedLog);
  }

  return self;
}

- (os_log_t)mainLog {
  return mainLog;
}

- (os_log_t)trustedLog {
  return trustedLog;
}

@end // @implementation LogManager
