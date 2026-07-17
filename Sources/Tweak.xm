#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <jsi/jsi.h>
#import <functional>
#import <unistd.h>

#import "LoaderConfig.h"
#import "Logger.h"
#import "Utils.h"
#import "JSI.h"
#import "RCTHost.h"
#import "RCTInstance.h"
#import "Fonts.h"

using namespace facebook;

static jsi::Runtime *gRuntime = NULL;
NSString *bunnyPatchesBundlePath;
static LoaderConfig  *loaderConfig;

static NSURL *resolveDownloadURL(void)
{
    LoaderConfig *fresh = [LoaderConfig getLoaderConfig];
    if (fresh.customLoadUrlEnabled && fresh.customLoadUrl)
    {
        return fresh.customLoadUrl;
    }
    return [NSURL URLWithString:@"https://codeberg.org/raincord/rain/releases/download/latest/rain.96.hbc"];
}

static dispatch_queue_t fsQueue(void)
{
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("app.rain.fsQueue", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static void downloadBundleForNextLaunch(NSURL *rainDir)
{
    NSURL *bundleFileURL = [rainDir URLByAppendingPathComponent:@"bundle.js"];
    NSURL *targetURL = resolveDownloadURL();

    if (!targetURL) return;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:targetURL
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData
                                                   timeoutInterval:15.0];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *etagFileURL = [rainDir URLByAppendingPathComponent:@"etag.txt"];

    __block NSString *etag = nil;
    dispatch_sync(fsQueue(), ^{
        if ([fm fileExistsAtPath:bundleFileURL.path])
            etag = [NSString stringWithContentsOfURL:etagFileURL encoding:NSUTF8StringEncoding error:nil];
    });
    if (etag)
        [req setValue:etag forHTTPHeaderField:@"If-None-Match"];

    NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
    [[session dataTaskWithRequest:req
                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if ([response isKindOfClass:[NSHTTPURLResponse class]])
        {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            if (http.statusCode == 200 && data.length > 0)
            {
                dispatch_sync(fsQueue(), ^{
                    [data writeToURL:bundleFileURL atomically:YES];
                    NSString *newEtag = [http valueForHTTPHeaderField:@"Etag"];
                    if (newEtag)
                        [newEtag writeToURL:etagFileURL atomically:YES encoding:NSUTF8StringEncoding error:nil];
                    else
                        [fm removeItemAtURL:etagFileURL error:nil];
                });
            }
        }
        else if (error)
        {
            BunnyLog(@"downloadBundleForNextLaunch: Error: %@", error.localizedDescription);
        }
        [session finishTasksAndInvalidate];
    }] resume];
}

typedef id (^BridgeHandler)(NSArray *args);

static NSDictionary<NSString *, BridgeHandler> *bridgeHandlers(void)
{
    static NSDictionary<NSString *, BridgeHandler> *handlers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handlers = @{
            @"updater.clear": ^id(NSArray *args) {
                NSURL *rainDirectory = getRainDirectory();
                NSFileManager *fm = [NSFileManager defaultManager];
                [fm removeItemAtURL:[rainDirectory URLByAppendingPathComponent:@"bundle.js"] error:nil];
                [fm removeItemAtURL:[rainDirectory URLByAppendingPathComponent:@"etag.txt"] error:nil];
                BunnyLog(@"[Updater] Cache cleared via JSI bridge");
                return [NSNull null];
            },

            @"updater.download": ^id(NSArray *args) {
                BunnyLog(@"[Updater] updater.download JSI bridge method called");
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    NSURL *rainDirectory = getRainDirectory();
                    downloadBundleForNextLaunch(rainDirectory);
                });
                return [NSNull null];
            },

            @"updater.reload": ^id(NSArray *args) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    BunnyLog(@"[Updater] Explicit JSI download + reload started");
                    NSURL *rainDirectory = getRainDirectory();
                    downloadBundleForNextLaunch(rainDirectory);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        UIWindow *w = [UIApplication sharedApplication].windows.firstObject;
                        if (w.rootViewController) {
                            reloadApp(w.rootViewController);
                        }
                    });
                });
                return [NSNull null];
            }
        };
    });
    return handlers;
}

static NSDictionary *callBridgeMethodHelper(NSString *methodName, NSArray *args)
{
    @try {
        BridgeHandler handler = bridgeHandlers()[methodName];
        if (!handler)
        {
            return @{@"error": [NSString stringWithFormat:@"Method not implemented: %@", methodName]};
        }

        __block id handlerResult;
        dispatch_sync(fsQueue(), ^{
            handlerResult = handler(args);
        });
        
        id responseVal = (handlerResult == nil) ? [NSNull null] : handlerResult;
        return @{@"result": responseVal};
    }
    @catch (NSException *exception) {
        return @{@"error": exception.reason ?: @"Unknown Objective-C exception"};
    }
}

static void injectPreBundle(jsi::Runtime &runtime)
{
    try
    {
        jsi::Object loaderObj(runtime);
        loaderObj.setProperty(runtime, "loaderName", jsi::String::createFromUtf8(runtime, "RainTweak"));
        loaderObj.setProperty(runtime, "loaderVersion", jsi::String::createFromUtf8(runtime, [PACKAGE_VERSION UTF8String]));
        loaderObj.setProperty(runtime, "hasThemeSupport", true);
        loaderObj.setProperty(runtime, "storedTheme", jsi::Value::null());
        loaderObj.setProperty(runtime, "fontPatch", 2);
        runtime.global().setProperty(runtime, "__RAIN_LOADER__", loaderObj);

        auto parsePayload = [](jsi::Runtime &rt, const jsi::Value *args, size_t count, NSString **methodOut, NSArray **argsOut) {
            if (count < 1 || !args[0].isObject()) {
                throw jsi::JSError(rt, "Expected a single payload object as argument.");
            }
            jsi::Object payload = args[0].asObject(rt);

            jsi::Value rainVal = payload.getProperty(rt, "rain");
            if (!rainVal.isObject()) throw jsi::JSError(rt, "Payload missing 'rain' object.");
            jsi::Object rain = rainVal.asObject(rt);

            jsi::Value methodVal = rain.getProperty(rt, "method");
            if (!methodVal.isString()) throw jsi::JSError(rt, "'method' property must be a string.");
            *methodOut = [JSI toNSString:methodVal runtime:rt];

            *argsOut = @[];
            jsi::Value argsVal = rain.getProperty(rt, "args");
            if (argsVal.isObject() && argsVal.asObject(rt).isArray(rt)) {
                *argsOut = [JSI toObjC:argsVal runtime:rt];
            }
        };

        auto syncCall = jsi::Function::createFromHostFunction(
            runtime,
            jsi::PropNameID::forUtf8(runtime, "__RAIN_BRIDGE_CALL_SYNC__"),
            1,
            [parsePayload](jsi::Runtime &rt, const jsi::Value &thisVal, const jsi::Value *args, size_t count) -> jsi::Value {
                NSString *methodName;
                NSArray *objcArgs;
                parsePayload(rt, args, count, &methodName, &objcArgs);

                NSDictionary *res = callBridgeMethodHelper(methodName, objcArgs);
                return [JSI fromObjC:res runtime:rt];
            }
        );
        runtime.global().setProperty(runtime, "__RAIN_BRIDGE_CALL_SYNC__", syncCall);

        auto asyncCall = jsi::Function::createFromHostFunction(
            runtime,
            jsi::PropNameID::forUtf8(runtime, "__RAIN_BRIDGE_CALL_ASYNC__"),
            1,
            [parsePayload](jsi::Runtime &rt, const jsi::Value &thisVal, const jsi::Value *args, size_t count) -> jsi::Value {
                NSString *methodName;
                NSArray *objcArgs;
                parsePayload(rt, args, count, &methodName, &objcArgs);

                jsi::Function promiseCtor = rt.global().getPropertyAsFunction(rt, "Promise");
                jsi::Function executor = jsi::Function::createFromHostFunction(rt, jsi::PropNameID::forUtf8(rt, "executor"), 2,
                    [methodName, objcArgs](jsi::Runtime &innerRt, const jsi::Value &thisVal, const jsi::Value *innerArgs, size_t innerCount) -> jsi::Value {
                        jsi::Function resolve = innerArgs[0].asObject(innerRt).asFunction(innerRt);
                        NSDictionary *res = callBridgeMethodHelper(methodName, objcArgs);
                        resolve.call(innerRt, [JSI fromObjC:res runtime:innerRt]);
                        return jsi::Value::undefined();
                    });
                return promiseCtor.callAsConstructor(rt, executor);
            }
        );
        runtime.global().setProperty(runtime, "__RAIN_BRIDGE_CALL_ASYNC__", asyncCall);

    }
    catch (const jsi::JSError &e) { BunnyLog(@"injectPreBundle: JSError: %s", e.what()); }
    catch (const std::exception &e) { BunnyLog(@"injectPreBundle: exception: %s", e.what()); }
}

static void executePreloads(jsi::Runtime &runtime, NSURL *rainDir)
{
    NSURL *preloadsDirectory = [rainDir URLByAppendingPathComponent:@"preloads"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:preloadsDirectory.path])
    {
        NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:preloadsDirectory
                                                           includingPropertiesForKeys:nil options:0 error:nil];
        for (NSURL *fileURL in contents)
        {
            if ([[fileURL pathExtension] isEqualToString:@"js"])
            {
                NSData *data = [NSData dataWithContentsOfURL:fileURL];
                if (data) [JSI evaluate:data tag:@"rain:preload" runtime:runtime];
            }
        }
    }
}

%hook RCTHost

- (void)instance:(id)instance didInitializeRuntime:(facebook::jsi::Runtime &)runtime
{
    gRuntime = &runtime;
    %orig;

    [loaderConfig loadConfig];
    NSURL *rainDir = getRainDirectory();
    injectPreBundle(runtime);

    NSURL *bundleFileURL = [rainDir URLByAppendingPathComponent:@"bundle.js"];
    NSData *bundle = [NSData dataWithContentsOfURL:bundleFileURL];

    if (bundle && bundle.length > 0)
    {
        [JSI evaluate:bundle tag:@"rain:bundle" runtime:runtime];
        executePreloads(runtime, rainDir);
    }
    else
    {
        downloadBundleForNextLaunch(rainDir);
    }
}

%end

%ctor
{
    @autoreleasepool
    {
        BOOL newArchEnabled = YES;
        @try {
            id rawVal = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"RCTNewArchEnabled"];
            if (rawVal) newArchEnabled = [rawVal boolValue];
        }
        @catch (...) {
        }

        if (!newArchEnabled)
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                showErrorAlert(@"Incompatible Discord Version",
                              @"This version of Discord is not using bridgeless "
                              @"Please update Discord to v332 or above",
                              nil);
            });
            return;
        }

        NSString *install_prefix = @"/var/jb";
        isJailbroken = [[NSFileManager defaultManager] fileExistsAtPath:install_prefix];
        BOOL jbPathExists = isJailbroken;

        NSString *bundlePath = [NSString stringWithFormat:@"%@/Library/Application Support/BunnyResources.bundle", install_prefix];
        NSString *jailedPath = [[NSBundle mainBundle].bundleURL.path stringByAppendingPathComponent:@"BunnyResources.bundle"];

        if (jbPathExists && [[NSFileManager defaultManager] fileExistsAtPath:bundlePath]) {
            bunnyPatchesBundlePath = bundlePath;
        } else {
            bunnyPatchesBundlePath = jailedPath;
        }

        loaderConfig = [[LoaderConfig alloc] init];
        [loaderConfig loadConfig];

        %init;
    }
}