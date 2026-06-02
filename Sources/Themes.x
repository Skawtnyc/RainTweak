#import "Themes.h"

static NSDictionary *gSemanticColors = nil;
static NSDictionary *gRawColors      = nil;
static NSMutableSet *loggedColors    = nil;


static NSInteger getThemeIndex(void) {
    Class DCDTheme = NSClassFromString(@"DCDTheme");
    if (!DCDTheme)
        return 0;

    SEL themeIndexSelector = NSSelectorFromString(@"themeIndex");
    if (![DCDTheme respondsToSelector:themeIndexSelector])
        return 0;

    typedef NSInteger (*ThemeIndexFunc)(id, SEL);
    return ((ThemeIndexFunc)objc_msgSend)(DCDTheme, themeIndexSelector);
}

static NSString *camelToSnakeCase(NSString *input) {
    NSMutableString *output   = [NSMutableString string];
    NSCharacterSet *uppercase = [NSCharacterSet uppercaseLetterCharacterSet];

    for (NSUInteger i = 0; i < input.length; i++) {
        unichar c = [input characterAtIndex:i];
        if (i > 0 && [uppercase characterIsMember:c]) {
            [output appendString:@"_"];
        }
        [output appendFormat:@"%c", toupper(c)];
    }
    return output;
}

static void swizzleRawColorMethods(void) {
    Class targetClass = [UIColor class];
    if (!targetClass)
        return;

    BunnyLog(@"Processing %lu raw color methods", (unsigned long)gRawColors.count);

    for (NSString *key in gRawColors) {
        SEL selector          = NSSelectorFromString(key);
        Method existingMethod = class_getClassMethod(targetClass, selector);

        IMP implementation = imp_implementationWithBlock(^UIColor *(id self) {
            NSString *hexColor = gRawColors[key];
            UIColor *color     = hexToUIColor(hexColor);
            if (color && ![loggedColors containsObject:key]) {
                [loggedColors addObject:key];
                BunnyLog(@"Applied raw color: %@ -> %@", key, hexColor);
            }
            return color ?: [UIColor clearColor];
        });

        if (existingMethod) {
            method_setImplementation(existingMethod, implementation);
        } else {
            class_addMethod(object_getClass(targetClass), selector, implementation, "@16@0:8");
        }
    }
}

static void swizzleDCDThemeColorMethods(void) {
    Class targetClass = objc_getClass("DCDThemeColor");
    if (!targetClass)
        return;

    unsigned int methodCount = 0;
    Method *methods          = class_copyMethodList(object_getClass(targetClass), &methodCount);
    if (!methods)
        return;

    BunnyLog(@"Processing %lu semantic color methods", (unsigned long)gSemanticColors.count);
    loggedColors = [NSMutableSet new];

    for (unsigned int i = 0; i < methodCount; i++) {
        Method method = methods[i];
        char returnType[256];
        method_getReturnType(method, returnType, sizeof(returnType));
        if (strcmp(returnType, @encode(UIColor *)) != 0)
            continue;

        SEL selector   = method_getName(method);
        NSString *name = NSStringFromSelector(selector);
        IMP original   = method_getImplementation(method);

        IMP replacement = imp_implementationWithBlock(^UIColor *(id self) {
            NSString *snakeKey = camelToSnakeCase(name);
            NSArray *colors    = gSemanticColors[snakeKey];

            if (colors && [colors isKindOfClass:[NSArray class]]) {
                NSInteger themeIndex = getThemeIndex();
                if (themeIndex < colors.count) {
                    UIColor *color = hexToUIColor(colors[themeIndex]);
                    if (color) {
                        if (![loggedColors containsObject:name]) {
                            [loggedColors addObject:name];
                            BunnyLog(@"Applied theme color: %@ -> %@", name, colors[themeIndex]);
                        }
                        return color;
                    }
                }
            }
            return ((UIColor * (*)(id, SEL)) original)(self, selector);
        });

        method_setImplementation(method, replacement);
    }

    free(methods);
}

// Get current theme mode from NSUserDefaults (0 = dark, 1 = light)
int getMode() {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSNumber *mode = [defaults objectForKey:@"theme_mode"];
    return mode ? [mode intValue] : 0; // default to dark
}

NSDictionary* getCurrentTheme() {
   	NSFileManager *fileManager = [NSFileManager defaultManager];
   if (![fileManager fileExistsAtPath:CURRENT_THEME]) {
       BunnyLog(@"Theme file does not exist at: %@", CURRENT_THEME);
       return nil;
   }

   NSError *readError = nil;
   NSData *jsonData = [NSData dataWithContentsOfFile:CURRENT_THEME options:0 error:&readError];
   if (readError) {
       BunnyLog(@"Failed to read theme file: %@", readError);
       return nil;
   }

   NSError *jsonError = nil;
   NSDictionary *themeDict = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&jsonError];
   if (jsonError) {
       BunnyLog(@"Failed to parse theme JSON: %@", jsonError);
       return nil;
   }

   BunnyLog(@"Theme loaded: %@", themeDict);
   return [themeDict copy];
}



// Returns a dictionary of semantic color names -> hex strings for the current mode
NSDictionary* getSemantic() {
    NSDictionary *theme = getCurrentTheme();
    if (!theme) {
        BunnyLog(@"No theme loaded");
        return nil;
    }

    NSDictionary *data = theme[@"data"];
    if (![data isKindOfClass:[NSDictionary class]]) {
        BunnyLog(@"Invalid theme data");
        return nil;
    }

    NSNumber *spec = data[@"spec"];
    NSDictionary *semanticSource = nil;

    if ([spec intValue] == 3 || !spec) {
        semanticSource = theme[@"main"][@"semantic"];
    } else if ([spec intValue] == 2) {
        semanticSource = data[@"semanticColors"];
    } else if ([spec intValue] == 1 || !spec) {
        semanticSource = data[@"theme_color_map"];
    } else {
        BunnyLog(@"Unsupported theme spec: %@", spec);
        return nil;
    }

    if (![semanticSource isKindOfClass:[NSDictionary class]]) {
        BunnyLog(@"No semantic colors found");
        return nil;
    }

    int mode = getMode(); // 0 = dark, 1 = light

    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    for (NSString *key in semanticSource) {
        id value = semanticSource[key];
        if ([value isKindOfClass:[NSArray class]]) {
            NSArray *arr = (NSArray *)value;
            if (arr.count > mode) {
                NSString *colorStr = arr[mode];
                if ([colorStr isKindOfClass:[NSString class]]) {
                    result[key] = colorStr;
                }
            }
        }
    }

    return [result copy];
}

UIColor* colorFromHexString(NSString *hexString) {
	unsigned rgbValue = 0;
	NSScanner *scanner = [NSScanner scannerWithString:hexString];
	[scanner setScanLocation: 1];
	[scanner scanHexInt: &rgbValue];

	return [UIColor colorWithRed:((rgbValue & 0xFF0000) >> 16)/255.0 green:((rgbValue & 0xFF00) >> 8)/255.0 blue:(rgbValue & 0xFF)/255.0 alpha:1.0];
}

UIColor* getColor(NSString *name, NSString *kind) {
	if ([kind isEqual:@"semantic"]) {
	    NSDictionary *semanticColors = nil;
		if (!semanticColors) {
			semanticColors = getSemantic();
		}

		if (![semanticColors objectForKey:name]) {
			return NULL;
		}

		NSString *value = semanticColors[name];
		UIColor *color;

		color = colorFromHexString(value);
		return color;
	}
	return nil;
}

//Perform Black Magic
BOOL isThemeLight(UIColor *color) {
  CGFloat r, g, b;
  [color getRed:&r green:&g blue:&b alpha:NULL];
  CGFloat luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  if (luminance > 0.70) {
    return TRUE;
  }
  return FALSE;
}

@interface UIKeyboard : UIView
@end

@interface UIKeyboardDockView : UIView
@end

@interface TUIPredictionView : UIView
@end

@interface TUIEmojiSearchInputView : UIView
@end

@interface UIKBRenderConfig : NSObject
-(void)setLightKeyboard:(BOOL)light;
+(void)refreshKeyboard;
+(id)darkConfig;
+(id)defaultConfig;
+(id)defaultEmojiConfig;
+(id)lowQualityDarkConfig;
@end


%group KEYBOARD

	id originalKeyboardColor;

	%hook UIKeyboard
	- (void)didMoveToWindow {
		%orig;

		id color = getColor(@"KEYBOARD", @"semantic") ?: getColor(@"BACKGROUND_PRIMARY", @"semantic");

        [%c(UIKBRenderConfig) refreshKeyboard];

		if (originalKeyboardColor != nil && originalKeyboardColor != color) {
			originalKeyboardColor = [self backgroundColor];
		}
		if (color != nil) {
				[self setBackgroundColor:color];
			} else {
			[self setBackgroundColor:originalKeyboardColor];
		}
	}

	%end

	%hook UIKeyboardDockView

	- (void)didMoveToWindow {
		%orig;

		id color = getColor(@"KEYBOARD", @"semantic") ?: getColor(@"BACKGROUND_PRIMARY", @"semantic");
		if (originalKeyboardColor != nil && originalKeyboardColor != color) {
			originalKeyboardColor = [self backgroundColor];
		}
		if (color != nil) {
				[self setBackgroundColor:color];
			} else {
			[self setBackgroundColor:originalKeyboardColor];
		}
	}

	%end

	%hook UIKBRenderConfig

	- (void)setLightKeyboard:(BOOL)arg1 {
	    %orig(isThemeLight(getColor(@"KEYBOARD", @"semantic") ?: getColor(@"BACKGROUND_PRIMARY", @"semantic")));
    }

    %new
    +(void)refreshKeyboard {
       	[[self darkConfig] setLightKeyboard:TRUE];
    	[[self defaultConfig] setLightKeyboard:TRUE];
    	[[self defaultEmojiConfig] setLightKeyboard:TRUE];
    	[[self lowQualityDarkConfig] setLightKeyboard:TRUE];

    }

	%end

	%hook TUIPredictionView
	- (void)didMoveToWindow {
		%orig;


		id color = getColor(@"KEYBOARD", @"semantic") ?: getColor(@"BACKGROUND_PRIMARY", @"semantic");
		if (originalKeyboardColor != nil && originalKeyboardColor != color) {
			originalKeyboardColor = [self backgroundColor];
		}
		if (color != nil) {
			[self setBackgroundColor:color];

			for (UIView *subview in self.subviews) {
				[subview setBackgroundColor:color];
			}
		} else {
			[self setBackgroundColor:originalKeyboardColor];

			for (UIView *subview in self.subviews) {
				[subview setBackgroundColor:originalKeyboardColor];
			}
		}
	}
	%end

	%hook TUIEmojiSearchInputView

	- (void)didMoveToWindow {
		%orig;

		id color = getColor(@"KEYBOARD", @"semantic") ?: getColor(@"BACKGROUND_PRIMARY", @"semantic");
		if (originalKeyboardColor != nil && originalKeyboardColor != color) {
			originalKeyboardColor = [self backgroundColor];
		}
		if (color != nil) {
				[self setBackgroundColor:color];
			} else {
			[self setBackgroundColor:originalKeyboardColor];
		}
	}
	%end

%end

void initializeThemeColors(NSDictionary *semanticColors, NSDictionary *rawColors) {
    if (!semanticColors || !rawColors)
        return;

    BunnyLog(@"Initializing theme (%lu semantic colors, %lu raw colors)",
             (unsigned long)semanticColors.count, (unsigned long)rawColors.count);

    gSemanticColors = [semanticColors copy];
    gRawColors      = [rawColors copy];
    loggedColors    = [NSMutableSet new];

    swizzleDCDThemeColorMethods();
    swizzleRawColorMethods();
}

%ctor {

    NSBundle* bundle = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/TextInputUI.framework"];
	if (!bundle.loaded) [bundle load];

	%init(KEYBOARD);

}
