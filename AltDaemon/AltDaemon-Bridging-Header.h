//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//

#import <Foundation/Foundation.h>

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
