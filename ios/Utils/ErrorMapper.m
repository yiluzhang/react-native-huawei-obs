//
//  ErrorMapper.m
//  HuaweiObs
//
//  Created by react-native-huawei-obs
//

#import "ErrorMapper.h"
#import <OBS/OBS.h>

@implementation ErrorMapper

+ (NSDictionary *)mapError:(NSError *)error {
    // OBS SDK 服务端错误 (com.obs.serverError)
    if ([error.domain isEqualToString:@"com.obs.serverError"]) {
        return [self mapOBSServerError:error];
    }
    
    // OBS SDK 客户端错误 (com.obs.services.error)
    if ([error.domain isEqualToString:@"com.obs.services.error"]) {
        return [self mapOBSError:error];
    }
    
    // URL 错误
    if ([error.domain isEqualToString:NSURLErrorDomain]) {
        return [self mapURLError:error];
    }
    
    // 文件错误
    if ([error.domain isEqualToString:NSCocoaErrorDomain]) {
        return [self mapFileError:error];
    }
    
    // 自定义错误
    NSString *code = error.userInfo[@"code"];
    if (code) {
        return @{
            @"code": code,
            @"message": error.localizedDescription,
            @"isRetryable": @([self isRetryableErrorCode:code])
        };
    }
    
    // 未知错误
    return @{
        @"code": @"E_UNKNOWN",
        @"message": error.localizedDescription ?: @"Unknown error",
        @"isRetryable": @NO
    };
}

+ (NSDictionary *)mapOBSServerError:(NSError *)error {
    // com.obs.serverError 格式：
    // userInfo 包含 statusCode, requestID, responseXMLBodyDict (含 Code, Message, RequestId)
    NSDictionary *xmlBody = error.userInfo[@"responseXMLBodyDict"];
    NSString *errorCode = xmlBody[@"Code"] ?: @"";
    NSNumber *statusCode = error.userInfo[@"statusCode"] ?: @0;
    NSString *requestId = error.userInfo[@"xRequestID"] ?: xmlBody[@"RequestId"] ?: @"";
    NSString *serverMessage = xmlBody[@"Message"] ?: error.localizedDescription ?: @"OBS server error";
    
    NSString *code;
    BOOL isRetryable = NO;
    
    // Map OBS error codes
    if ([errorCode isEqualToString:@"InvalidAccessKeyId"]) {
        code = @"E_AUTH_INVALID_CREDENTIAL";
    } else if ([errorCode isEqualToString:@"SignatureDoesNotMatch"]) {
        code = @"E_AUTH_SIGNATURE_MISMATCH";
    } else if ([errorCode isEqualToString:@"RequestTimeTooSkewed"]) {
        code = @"E_AUTH_TIME_SKEWED";
    } else if ([errorCode isEqualToString:@"AccessDenied"]) {
        code = @"E_AUTH_ACCESS_DENIED";
    } else if ([errorCode isEqualToString:@"ExpiredToken"]) {
        code = @"E_AUTH_EXPIRED";
    } else if ([errorCode isEqualToString:@"NoSuchBucket"]) {
        code = @"E_BUCKET_NOT_FOUND";
    } else if ([errorCode isEqualToString:@"NoSuchKey"]) {
        code = @"E_FILE_NOT_FOUND";
    } else if ([errorCode isEqualToString:@"TooManyRequests"]) {
        code = @"E_CONCURRENCY_LIMIT_EXCEEDED";
        isRetryable = YES;
    } else if ([errorCode isEqualToString:@"RequestTimeout"]) {
        code = @"E_NETWORK_TIMEOUT";
        isRetryable = YES;
    } else if ([errorCode isEqualToString:@"InternalError"] ||
               [errorCode isEqualToString:@"ServiceUnavailable"]) {
        code = @"E_HTTP_5XX";
        isRetryable = YES;
    } else {
        code = [self mapHTTPStatus:[statusCode intValue]];
        isRetryable = [self isRetryableHTTPStatus:[statusCode intValue]];
    }
    
    return @{
        @"code": code,
        @"message": [NSString stringWithFormat:@"[%@] %@", errorCode, serverMessage],
        @"statusCode": statusCode,
        @"requestId": requestId,
        @"isRetryable": @(isRetryable)
    };
}

+ (NSDictionary *)mapOBSError:(NSError *)error {
    NSString *errorCode = error.userInfo[@"ErrorCode"] ?: @"";
    NSNumber *statusCode = error.userInfo[@"StatusCode"] ?: @0;
    NSString *requestId = error.userInfo[@"RequestId"] ?: @"";
    NSString *hostId = error.userInfo[@"HostId"] ?: @"";
    
    NSString *code;
    BOOL isRetryable = NO;
    
    // Map OBS error codes
    if ([errorCode isEqualToString:@"InvalidAccessKeyId"]) {
        code = @"E_AUTH_INVALID_CREDENTIAL";
    } else if ([errorCode isEqualToString:@"SignatureDoesNotMatch"]) {
        code = @"E_AUTH_SIGNATURE_MISMATCH";
    } else if ([errorCode isEqualToString:@"RequestTimeTooSkewed"]) {
        code = @"E_AUTH_TIME_SKEWED";
    } else if ([errorCode isEqualToString:@"AccessDenied"]) {
        code = @"E_AUTH_ACCESS_DENIED";
    } else if ([errorCode isEqualToString:@"ExpiredToken"]) {
        code = @"E_AUTH_EXPIRED";
    } else if ([errorCode isEqualToString:@"NoSuchBucket"]) {
        code = @"E_BUCKET_NOT_FOUND";
    } else if ([errorCode isEqualToString:@"NoSuchKey"]) {
        code = @"E_FILE_NOT_FOUND";
    } else if ([errorCode isEqualToString:@"TooManyRequests"]) {
        code = @"E_CONCURRENCY_LIMIT_EXCEEDED";
        isRetryable = YES;
    } else if ([errorCode isEqualToString:@"RequestTimeout"]) {
        code = @"E_NETWORK_TIMEOUT";
        isRetryable = YES;
    } else if ([errorCode isEqualToString:@"InternalError"] || 
               [errorCode isEqualToString:@"ServiceUnavailable"]) {
        code = @"E_HTTP_5XX";
        isRetryable = YES;
    } else {
        // Map by HTTP status code
        code = [self mapHTTPStatus:[statusCode intValue]];
        isRetryable = [self isRetryableHTTPStatus:[statusCode intValue]];
    }
    
    return @{
        @"code": code,
        @"message": error.localizedDescription ?: @"OBS error",
        @"statusCode": statusCode,
        @"requestId": requestId,
        @"hostId": hostId,
        @"isRetryable": @(isRetryable)
    };
}

+ (NSDictionary *)mapURLError:(NSError *)error {
    NSString *code;
    BOOL isRetryable = NO;
    
    switch (error.code) {
        case NSURLErrorTimedOut:
            code = @"E_NETWORK_TIMEOUT";
            isRetryable = YES;
            break;
        case NSURLErrorNotConnectedToInternet:
        case NSURLErrorNetworkConnectionLost:
            code = @"E_NETWORK_CONNECTION_LOST";
            isRetryable = YES;
            break;
        case NSURLErrorDNSLookupFailed:
            code = @"E_NETWORK_DNS_FAILED";
            isRetryable = YES;
            break;
        case NSURLErrorCannotFindHost:
            code = @"E_NETWORK_HOST_UNREACHABLE";
            isRetryable = YES;
            break;
        case NSURLErrorCancelled:
            code = @"E_TASK_CANCELLED";
            break;
        default:
            code = @"E_NETWORK_REQUEST_FAILED";
            isRetryable = YES;
            break;
    }
    
    return @{
        @"code": code,
        @"message": error.localizedDescription ?: @"Network error",
        @"isRetryable": @(isRetryable)
    };
}

+ (NSDictionary *)mapFileError:(NSError *)error {
    NSString *code;
    
    switch (error.code) {
        case NSFileNoSuchFileError:
            code = @"E_FILE_NOT_FOUND";
            break;
        case NSFileReadNoPermissionError:
            code = @"E_FILE_NOT_READABLE";
            break;
        case NSFileWriteNoPermissionError:
            code = @"E_FILE_NOT_WRITABLE";
            break;
        case NSFileWriteOutOfSpaceError:
            code = @"E_FILE_NO_SPACE";
            break;
        default:
            code = @"E_FILE_IO_ERROR";
            break;
    }
    
    return @{
        @"code": code,
        @"message": error.localizedDescription ?: @"File error",
        @"isRetryable": @NO
    };
}

+ (NSString *)mapHTTPStatus:(NSInteger)statusCode {
    switch (statusCode) {
        case 400:
            return @"E_HTTP_BAD_REQUEST";
        case 401:
            return @"E_AUTH_INVALID_CREDENTIAL";
        case 403:
            return @"E_AUTH_ACCESS_DENIED";
        case 404:
            return @"E_FILE_NOT_FOUND";
        case 409:
            return @"E_HTTP_CONFLICT";
        case 429:
            return @"E_CONCURRENCY_LIMIT_EXCEEDED";
        case 500 ... 599:
            return @"E_HTTP_5XX";
        default:
            return @"E_HTTP_UNKNOWN";
    }
}

+ (BOOL)isRetryableHTTPStatus:(NSInteger)statusCode {
    return statusCode >= 500 || statusCode == 429;
}

+ (BOOL)isRetryableErrorCode:(NSString *)code {
    NSSet *retryableCodes = [NSSet setWithArray:@[
        @"E_NETWORK_TIMEOUT",
        @"E_NETWORK_CONNECTION_LOST",
        @"E_NETWORK_REQUEST_FAILED",
        @"E_HTTP_5XX",
        @"E_CONCURRENCY_LIMIT_EXCEEDED",
        @"E_UPLOAD_PART_FAILED"
    ]];
    return [retryableCodes containsObject:code];
}

@end
