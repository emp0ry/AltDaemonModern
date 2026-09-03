#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

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

    return AAMOriginalDataTaskImplementation(object, selector, request, wrappedCompletion);
}

static NSURLSessionDataTask *AAMDataTaskWithRequest(id object,
                                                    SEL selector,
                                                    NSURLRequest *request,
                                                    void (^completionHandler)(NSData *, NSURLResponse *, NSError *))
{
    if (!AAMIsAppleAuthenticationRequest(request))
    {
        return AAMOriginalDataTaskImplementation(object, selector, request, completionHandler);
    }

    NSMutableURLRequest *updatedRequest = [request mutableCopy];
    NSString *originalClientInfo = [updatedRequest valueForHTTPHeaderField:@"X-MMe-Client-Info"];
    BOOL hadCorrectClientInfo = [originalClientInfo containsString:@"com.apple.dt.Xcode/25183.54.10"];

    // AltStore 2.2.1 identifies the GSA request as a 2018 AuthKit client.
    // Current AltSign uses this modern AuthKit form. The client-info tuple is
    // also enforced here so the request cannot accidentally reuse stale data.
    [updatedRequest setValue:@"AuthKit/1 (Macintosh; OS X 26.5.2) (com.apple.dt.Xcode/26.0)"
          forHTTPHeaderField:@"User-Agent"];
    [updatedRequest setValue:@"<Mac17,3> <macOS;27.0;26A5416b> <com.apple.AuthKit/1 (com.apple.dt.Xcode/25183.54.10)>"
          forHTTPHeaderField:@"X-MMe-Client-Info"];

    NSString *requestMessage = [NSString stringWithFormat:@"request path=%@ method=%@ correctedClientInfo=%@",
                                updatedRequest.URL.path ?: @"(none)",
                                updatedRequest.HTTPMethod ?: @"(none)",
                                hadCorrectClientInfo ? @"yes" : @"no"];
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

        AAMAppendDiagnostic([NSString stringWithFormat:@"loaded in %@ sessionClass=%@",
                             NSBundle.mainBundle.bundleIdentifier ?: @"(unknown)",
                             NSStringFromClass(sessionClass)]);
        [probeSession invalidateAndCancel];
    }
}
