#import <Foundation/Foundation.h>
#import <objc/message.h>

#import "Logger.h"
#import "Utils.h"

void initializeThemeColors(NSDictionary *semanticColors, NSDictionary *rawColors);

#define CURRENT_THEME [NSString stringWithFormat:@"%@/%@", NSHomeDirectory(), @"Documents/rain/current-theme.json"]
