//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

// Shared
#import "ALTConstants.h"
#import "ALTConnection.h"
#import "NSError+ALTServerError.h"
#import "CFNotificationName+AltStore.h"

// libproc
int proc_pidpath(int pid, void * _Nonnull buffer, uint32_t buffersize);

// Security.framework
CF_ENUM(uint32_t) {
    kSecCSInternalInformation = 1 << 0,
    kSecCSSigningInformation = 1 << 1,
    kSecCSRequirementInformation = 1 << 2,
    kSecCSDynamicInformation = 1 << 3,
    kSecCSContentInformation = 1 << 4,
    kSecCSSkipResourceDirectory = 1 << 5,
    kSecCSCalculateCMSDigest = 1 << 6,
};

typedef CFTypeRef ALTSecStaticCodeRef;

OSStatus SecStaticCodeCreateWithPath(CFURLRef _Nonnull path, uint32_t flags, ALTSecStaticCodeRef _Nullable * __nonnull staticCode);
OSStatus SecCodeCopySigningInformation(ALTSecStaticCodeRef _Nonnull code, uint32_t flags, CFDictionaryRef _Nullable * __nonnull information);

NS_ASSUME_NONNULL_BEGIN

@interface LSApplicationWorkspace : NSObject

@property (class, readonly) LSApplicationWorkspace *defaultWorkspace;

- (BOOL)installApplication:(NSURL *)fileURL withOptions:(nullable NSDictionary<NSString *, id> *)options error:(NSError *_Nullable *)error;
- (BOOL)uninstallApplication:(NSString *)bundleIdentifier withOptions:(nullable NSDictionary *)options;

@end

NS_ASSUME_NONNULL_END

typedef void (^ALTInstallCoordinationCompletion)(id _Nullable identity, NSError *_Nullable error);

// MIInstallOptions is private API, so describe only the initializer we use and
// resolve the class at runtime. This avoids a hard link against MobileInstallation
// while still giving ARC the correct Objective-C ownership semantics.
@protocol ALTMIInstallOptionsRuntime <NSObject>
- (instancetype _Nonnull)initWithLegacyOptionsDictionary:(NSDictionary<NSString *, id> * _Nonnull)dictionary;
@end

// LaunchServices' legacy installApplication: wrapper returns unimpErr on iOS 26.
// Keep the older path as the default and use this direct InstallCoordination entry
// point only as a runtime fallback when that specific error is encountered.
static inline BOOL ALTBeginInstallWithInstallCoordination(NSURL * _Nonnull fileURL,
                                                          NSDictionary<NSString *, id> * _Nonnull options,
                                                          ALTInstallCoordinationCompletion _Nonnull completion)
{
    static void *installCoordinationHandle = NULL;
    static void *mobileInstallationHandle = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        installCoordinationHandle = dlopen("/System/Library/PrivateFrameworks/InstallCoordination.framework/InstallCoordination",
                                           RTLD_LAZY | RTLD_LOCAL);
        mobileInstallationHandle = dlopen("/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation",
                                          RTLD_LAZY | RTLD_LOCAL);
    });

    if (installCoordinationHandle == NULL || mobileInstallationHandle == NULL)
    {
        return NO;
    }

    Class coordinatorClass = objc_getClass("IXAppInstallCoordinator");
    Class installOptionsClass = objc_getClass("MIInstallOptions");
    SEL selector = sel_registerName("_beginInstallForURL:forPersonaUniqueString:consumeSource:options:progressBlock:completionWithIdentity:");
    SEL optionsInitializer = sel_registerName("initWithLegacyOptionsDictionary:");
    if (coordinatorClass == Nil || installOptionsClass == Nil ||
        ![(id)coordinatorClass respondsToSelector:selector] ||
        ![installOptionsClass instancesRespondToSelector:optionsInitializer])
    {
        return NO;
    }

    typedef void (*ALTBeginInstallFunction)(id, SEL, NSURL *, NSString *_Nullable, BOOL, id, id _Nullable, ALTInstallCoordinationCompletion);
    @try
    {
        // The private iOS 26 entry point expects MIInstallOptions, not the
        // legacy NSDictionary accepted by LSApplicationWorkspace. Passing the
        // dictionary directly causes an asynchronous unrecognized-selector
        // exception (installTargetType), which terminates AltDaemon and appears
        // in AltStore as ServerError 2002.
        id<ALTMIInstallOptionsRuntime> allocatedOptions = (id<ALTMIInstallOptionsRuntime>)[installOptionsClass alloc];
        id installOptions = [allocatedOptions initWithLegacyOptionsDictionary:options];
        if (installOptions == nil)
        {
            NSDictionary *userInfo = @{
                NSLocalizedDescriptionKey: @"The iOS 26 installation options could not be created.",
            };
            completion(nil, [NSError errorWithDomain:@"io.altstore.altdaemon.InstallCoordination"
                                                 code:2
                                             userInfo:userInfo]);
            return YES;
        }

        // AltStore owns the temporary IPA, so ask InstallCoordination to copy
        // it instead of consuming (deleting) the source asynchronously.
        ((ALTBeginInstallFunction)objc_msgSend)(coordinatorClass, selector, fileURL, nil, NO, installOptions, nil, completion);
    }
    @catch (NSException *exception)
    {
        NSDictionary *userInfo = @{
            NSLocalizedDescriptionKey: @"The iOS 26 installation service raised an exception.",
            NSLocalizedFailureReasonErrorKey: exception.reason ?: exception.name,
        };
        completion(nil, [NSError errorWithDomain:@"io.altstore.altdaemon.InstallCoordination"
                                             code:1
                                         userInfo:userInfo]);
    }

    return YES;
}
