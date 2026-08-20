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

// LaunchServices' legacy installApplication: wrapper returns unimpErr on iOS 26.
// Keep the older path as the default and use this direct InstallCoordination entry
// point only as a runtime fallback when that specific error is encountered.
static inline BOOL ALTBeginInstallWithInstallCoordination(NSURL * _Nonnull fileURL,
                                                          NSDictionary<NSString *, id> * _Nonnull options,
                                                          ALTInstallCoordinationCompletion _Nonnull completion)
{
    static void *installCoordinationHandle = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        installCoordinationHandle = dlopen("/System/Library/PrivateFrameworks/InstallCoordination.framework/InstallCoordination",
                                           RTLD_LAZY | RTLD_LOCAL);
    });

    if (installCoordinationHandle == NULL)
    {
        return NO;
    }

    Class coordinatorClass = objc_getClass("IXAppInstallCoordinator");
    SEL selector = sel_registerName("_beginInstallForURL:forPersonaUniqueString:consumeSource:options:progressBlock:completionWithIdentity:");
    if (coordinatorClass == Nil || ![(id)coordinatorClass respondsToSelector:selector])
    {
        return NO;
    }

    typedef void (*ALTBeginInstallFunction)(id, SEL, NSURL *, NSString *_Nullable, BOOL, NSDictionary *, id _Nullable, ALTInstallCoordinationCompletion);
    @try
    {
        // The source belongs to AltDaemon's request lifecycle. Ask
        // InstallCoordination to copy it rather than deleting it asynchronously.
        ((ALTBeginInstallFunction)objc_msgSend)(coordinatorClass, selector, fileURL, nil, NO, options, nil, completion);
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
