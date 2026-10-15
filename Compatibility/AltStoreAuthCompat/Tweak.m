#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

// 0: GSA and developer-services requests are rewritten to one coherent Mac identity
//    (see below). Required with on-device anisette: Apple answers /services/v1/certificates
//    with 403 FORBIDDEN_ERROR when the iPhone's own client info is sent.
// 1: pure logger; requests are not modified.
#define AAM_LOG_ONLY 0

// Client info used for every GSA request when AAM_LOG_ONLY is 0.
// 1: legacy MacBookPro13,2 tuple (matched the old public anisette servers).
// 2: Mac15,7 / macOS 15.7.9 tuple (the one observed from a working Mac AltServer run).
#define AAM_IDENTITY 2

// Same tuple for developerservices2.apple.com requests. It must match the GSA identity:
// mixing an iPhone sign-in with a Mac developer-services request is answered with
// "session expired" (AltStore error 1100).
// 1: apply the override (working configuration). 0: leave AltSign's value untouched.
#define AAM_DEV_IDENTITY 1
#define AAM_DEV_CLIENT_INFO @"<Mac15,7> <macOS;15.7.9;24G830> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"

#if AAM_IDENTITY == 1
#define AAM_CLIENT_INFO @"<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
#else
#define AAM_CLIENT_INFO @"<Mac15,7> <macOS;15.7.9;24G830> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"
#endif

// The User-Agent AltSign sends (unmodified). It contains com.apple.dt.Xcode/26.0 and
// is accepted; only X-MMe-Client-Info is filtered.
#define AAM_USER_AGENT @"AuthKit/1 (Macintosh; OS X 26.5.2) (com.apple.dt.Xcode/26.0)"

typedef NSURLSessionDataTask *(*AAMDataTaskImplementation)(id,
                                                           SEL,
                                                           NSURLRequest *,
                                                           void (^)(NSData *, NSURLResponse *, NSError *));

static AAMDataTaskImplementation AAMOriginalDataTaskImplementation;
static const NSUInteger AAMMaximumRetryCount = 3;

static BOOL AAMIsAppleAuthenticationRequest(NSURLRequest *request)
{
    NSURL *url = request.URL;
    return [url.host.lowercaseString isEqualToString:@"gsa.apple.com"] &&
           [url.path hasPrefix:@"/grandslam/GsService2"];
}

static void AAMAppendDiagnostic(NSString *message)
{
    if (message.length == 0) return;

    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"AltStoreAuthCompat.log"];
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (data == nil) return;

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSDictionary<NSFileAttributeKey, id> *attributes = [fileManager attributesOfItemAtPath:path error:nil];
    if ([attributes[NSFileSize] unsignedLongLongValue] > 65536)
    {
        [data writeToFile:path options:NSDataWritingAtomic error:nil];
        return;
    }

    if (![fileManager fileExistsAtPath:path])
    {
        [data writeToFile:path options:NSDataWritingAtomic error:nil];
        return;
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (handle == nil) return;
    @try
    {
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle closeFile];
    }
    @catch (__unused NSException *exception)
    {
        [handle closeFile];
    }
}

static BOOL AAMShouldRetry(NSHTTPURLResponse *response, NSError *error)
{
    if (error != nil)
    {
        if (![error.domain isEqualToString:NSURLErrorDomain]) return NO;

        switch (error.code)
        {
            case NSURLErrorTimedOut:
            case NSURLErrorCannotFindHost:
            case NSURLErrorCannotConnectToHost:
            case NSURLErrorDNSLookupFailed:
            case NSURLErrorNetworkConnectionLost:
            case NSURLErrorNotConnectedToInternet:
                return YES;

            default:
                return NO;
        }
    }

    switch (response.statusCode)
    {
        case 429:
        case 500:
        case 502:
        case 503:
        case 504:
            return YES;

        default:
            return NO;
    }
}

static NSTimeInterval AAMRetryDelay(NSHTTPURLResponse *response, NSUInteger attempt)
{
    static const NSTimeInterval delays[] = {5.0, 15.0, 30.0};
    NSTimeInterval delay = delays[MIN(attempt, AAMMaximumRetryCount - 1)];

    NSString *retryAfter = [response valueForHTTPHeaderField:@"Retry-After"];
    NSTimeInterval serverDelay = retryAfter.doubleValue;
    if (serverDelay > delay)
    {
        delay = MIN(serverDelay, 60.0);
    }
    return delay;
}

static NSError *AAMAppleServiceError(NSHTTPURLResponse *response)
{
    NSInteger statusCode = response.statusCode;
    NSString *description = [NSString stringWithFormat:
        @"Apple authentication is temporarily unavailable (HTTP %ld). Please wait a few minutes and try again.",
        (long)statusCode];
    return [NSError errorWithDomain:@"com.emp0ry.altdaemon.apple-auth"
                               code:statusCode
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

// Logs only Apple's status fields (ec / em / hsc). Never the response body.
static NSString *AAMStatusSummary(NSData *data)
{
    if (data.length == 0) return @"status (empty body)";

    id plist = [NSPropertyListSerialization propertyListWithData:data
                                                         options:NSPropertyListImmutable
                                                          format:NULL
                                                           error:NULL];
    if (![plist isKindOfClass:[NSDictionary class]]) return @"status (not a property list)";

    NSDictionary *root = (NSDictionary *)plist;
    NSDictionary *response = [root[@"Response"] isKindOfClass:[NSDictionary class]] ? root[@"Response"] : root;
    NSDictionary *status = [response[@"Status"] isKindOfClass:[NSDictionary class]] ? response[@"Status"] : nil;

    NSString *em = [status[@"em"] description];
    if (em.length > 200) em = [em substringToIndex:200];

    return [NSString stringWithFormat:@"status ec=%@ em=%@ hsc=%@",
            status[@"ec"] ?: @"(none)", em ?: @"(none)", status[@"hsc"] ?: @"(none)"];
}

// Retries run seconds later on a background queue. By then the session that issued
// the original request may already be invalidated, and creating a task on an
// invalidated NSURLSession throws an Objective-C exception (which crashed AltStore).
// Try the original session first, then a fresh ephemeral session. Returns nil only
// if neither works; the exception name and reason are logged for diagnosis.
static NSURLSessionDataTask *AAMCreateRetryTask(id object,
                                                SEL selector,
                                                NSURLRequest *request,
                                                void (^completion)(NSData *, NSURLResponse *, NSError *))
{
    @try
    {
        return AAMOriginalDataTaskImplementation(object, selector, request, completion);
    }
    @catch (NSException *exception)
    {
        AAMAppendDiagnostic([NSString stringWithFormat:@"retry task creation threw %@: %@",
                             exception.name, exception.reason ?: @"(no reason)"]);
    }

    NSURLSession *freshSession = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
    @try
    {
        NSURLSessionDataTask *task = AAMOriginalDataTaskImplementation(freshSession, selector, request, completion);
        [freshSession finishTasksAndInvalidate];
        AAMAppendDiagnostic(@"retry task created on a fresh session");
        return task;
    }
    @catch (NSException *exception)
    {
        AAMAppendDiagnostic([NSString stringWithFormat:@"fresh-session task creation threw %@: %@",
                             exception.name, exception.reason ?: @"(no reason)"]);
        [freshSession invalidateAndCancel];
        return nil;
    }
}

static NSURLSessionDataTask *AAMCreateAppleAuthenticationTask(id object,
                                                               SEL selector,
                                                               NSURLRequest *request,
                                                               void (^completionHandler)(NSData *, NSURLResponse *, NSError *),
                                                               NSUInteger attempt)
{
    void (^wrappedCompletion)(NSData *, NSURLResponse *, NSError *) =
    ^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? (NSHTTPURLResponse *)response
            : nil;
        NSString *contentType = [httpResponse valueForHTTPHeaderField:@"Content-Type"] ?: httpResponse.MIMEType;

        NSUInteger firstByte = NSNotFound;
        if (data.length > 0)
        {
            const unsigned char *bytes = data.bytes;
            for (NSUInteger index = 0; index < data.length; index++)
            {
                if (![[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:bytes[index]])
                {
                    firstByte = bytes[index];
                    break;
                }
            }
        }

        NSString *responseMessage = [NSString stringWithFormat:@"response attempt=%lu status=%ld type=%@ bytes=%lu firstByte=%@ transportError=%@",
                                     (unsigned long)(attempt + 1),
                                     (long)httpResponse.statusCode,
                                     contentType ?: @"(none)",
                                     (unsigned long)data.length,
                                     firstByte == NSNotFound ? @"none" : [NSString stringWithFormat:@"0x%02lx", (unsigned long)firstByte],
                                     error == nil ? @"none" : [NSString stringWithFormat:@"%@/%ld", error.domain, (long)error.code]];
        AAMAppendDiagnostic(responseMessage);
        AAMAppendDiagnostic(AAMStatusSummary(data));

        if (attempt < AAMMaximumRetryCount && AAMShouldRetry(httpResponse, error))
        {
            NSTimeInterval delay = AAMRetryDelay(httpResponse, attempt);
            AAMAppendDiagnostic([NSString stringWithFormat:@"retry scheduled attempt=%lu delay=%.0fs",
                                 (unsigned long)(attempt + 2), delay]);

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                NSURLSessionDataTask *retryTask = AAMCreateAppleAuthenticationTask(object,
                                                                                    selector,
                                                                                    request,
                                                                                    completionHandler,
                                                                                    attempt + 1);
                if (retryTask == nil)
                {
                    // The task could not be created at all (see AAMCreateRetryTask).
                    // Complete the caller with the last Apple error instead of hanging.
                    AAMAppendDiagnostic(@"retry aborted: could not create a task");
                    if (completionHandler != nil)
                    {
                        completionHandler(nil, response, error ?: AAMAppleServiceError(httpResponse));
                    }
                    return;
                }
                [retryTask resume];
            });
            return;
        }

        if (httpResponse.statusCode < 200 || httpResponse.statusCode > 299)
        {
            if (completionHandler != nil)
            {
                completionHandler(nil, response, error ?: AAMAppleServiceError(httpResponse));
            }
            return;
        }

        if (completionHandler != nil)
        {
            completionHandler(data, response, error);
        }
    };

    if (attempt == 0)
    {
        return AAMOriginalDataTaskImplementation(object, selector, request, wrappedCompletion);
    }

    return AAMCreateRetryTask(object, selector, request, wrappedCompletion);
}

// developerservices2.apple.com (certificates, App IDs, profiles) is a separate host from GSA.
static BOOL AAMIsDeveloperServicesRequest(NSURLRequest *request)
{
    NSString *host = request.URL.host.lowercaseString;
    return [host isEqualToString:@"developerservices2.apple.com"] ||
           [host hasSuffix:@".developerservices2.apple.com"];
}

static NSURLSessionDataTask *AAMDataTaskWithRequest(id object,
                                                    SEL selector,
                                                    NSURLRequest *request,
                                                    void (^completionHandler)(NSData *, NSURLResponse *, NSError *))
{
    if (AAMIsDeveloperServicesRequest(request))
    {
#if AAM_DEV_IDENTITY == 1
        NSMutableURLRequest *devRequest = [request mutableCopy];
        [devRequest setValue:AAM_DEV_CLIENT_INFO forHTTPHeaderField:@"X-MMe-Client-Info"];
        return AAMOriginalDataTaskImplementation(object, selector, devRequest, completionHandler);
#else
        return AAMOriginalDataTaskImplementation(object, selector, request, completionHandler);
#endif
    }

    if (!AAMIsAppleAuthenticationRequest(request))
    {
        return AAMOriginalDataTaskImplementation(object, selector, request, completionHandler);
    }

    NSMutableURLRequest *updatedRequest = [request mutableCopy];
    NSString *originalClientInfo = [updatedRequest valueForHTTPHeaderField:@"X-MMe-Client-Info"];
    BOOL hadCorrectClientInfo = [originalClientInfo containsString:@"com.apple.akd/1.0"];

    // AltStore 2.2.1 identifies the GSA request as a 2018 AuthKit client.
    // Apple now rejects GSA requests identifying as Xcode. The client-info
    // header is enforced here so the request cannot reuse that blocked token.
#if !AAM_LOG_ONLY
    [updatedRequest setValue:AAM_USER_AGENT forHTTPHeaderField:@"User-Agent"];
    [updatedRequest setValue:AAM_CLIENT_INFO forHTTPHeaderField:@"X-MMe-Client-Info"];
#endif

    NSString *requestMessage = [NSString stringWithFormat:@"request path=%@ method=%@ correctedClientInfo=%@ headersOverridden=%@",
                                updatedRequest.URL.path ?: @"(none)",
                                updatedRequest.HTTPMethod ?: @"(none)",
                                hadCorrectClientInfo ? @"yes" : @"no",
                                AAM_LOG_ONLY ? @"no" : @"yes"];
    AAMAppendDiagnostic(requestMessage);

    return AAMCreateAppleAuthenticationTask(object, selector, updatedRequest, completionHandler, 0);
}

__attribute__((constructor))
static void AAMInitialize(void)
{
    @autoreleasepool
    {
        NSURLSession *probeSession = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]];
        Class sessionClass = object_getClass(probeSession);
        SEL selector = @selector(dataTaskWithRequest:completionHandler:);
        Method method = class_getInstanceMethod(sessionClass, selector);
        if (method == NULL)
        {
            AAMAppendDiagnostic(@"hook failed: NSURLSession method missing");
            [probeSession invalidateAndCancel];
            return;
        }

        AAMOriginalDataTaskImplementation = (AAMDataTaskImplementation)method_getImplementation(method);
        const char *types = method_getTypeEncoding(method);
        if (!class_addMethod(sessionClass, selector, (IMP)AAMDataTaskWithRequest, types))
        {
            method_setImplementation(class_getInstanceMethod(sessionClass, selector), (IMP)AAMDataTaskWithRequest);
        }

        AAMAppendDiagnostic([NSString stringWithFormat:@"loaded build=native-final in %@ sessionClass=%@",
                             NSBundle.mainBundle.bundleIdentifier ?: @"(unknown)",
                             NSStringFromClass(sessionClass)]);
        [probeSession invalidateAndCancel];
    }
}
