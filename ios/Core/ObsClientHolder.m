//
//  ObsClientHolder.m
//  HuaweiObs
//
//  Created by react-native-huawei-obs
//

#import "ObsClientHolder.h"
#import <OBS/OBS.h>

#define OBSLog(tag, fmt, ...) NSLog(@"[%@] " fmt, tag, ##__VA_ARGS__)
static NSString *const TAG = @"ObsClientHolder";

@interface ObsClientHolder ()

@property (nonatomic, strong) OBSClient *obsClient;
@property (nonatomic, strong) NSString *endpoint;
@property (nonatomic, strong) NSString *bucket;
@property (nonatomic, strong) NSString *accessKeyId;
@property (nonatomic, strong) NSString *secretAccessKey;
@property (nonatomic, strong) NSString *securityToken;
@property (nonatomic, assign) NSTimeInterval tokenExpiryTime;
@property (nonatomic, strong) NSLock *lock;

@end

@implementation ObsClientHolder

- (instancetype)init {
    if (self = [super init]) {
        _lock = [[NSLock alloc] init];
    }
    return self;
}

- (void)createClientWithConfig:(NSDictionary *)config error:(NSError **)error {
    [self.lock lock];
    @try {
        // Parse required config
        NSString *endpoint = config[@"endpoint"];
        NSString *bucket = config[@"bucket"];
        NSString *accessKeyId = config[@"accessKeyId"];
        NSString *secretAccessKey = config[@"secretAccessKey"];
        
        if (!endpoint || !bucket) {
            if (error) {
                *error = [NSError errorWithDomain:@"ObsClientHolder" code:-1
                                         userInfo:@{NSLocalizedDescriptionKey: @"Missing required config: endpoint or bucket"}];
            }
            return;
        }
        
        OBSLog(TAG, @"[Init] endpoint=%@  bucket=%@  timeout=%@  maxRetries=%@",
               endpoint, bucket, config[@"timeout"], config[@"maxRetries"]);
        
        // Create credential provider
        OBSStaticCredentialProvider *credentialProvider = [[OBSStaticCredentialProvider alloc]
            initWithAccessKey:accessKeyId ?: @""
                    secretKey:secretAccessKey ?: @""];
        
        // Handle security token for STS
        NSString *securityToken = config[@"securityToken"];
        if (securityToken && securityToken.length > 0) {
            credentialProvider.securityToken = securityToken;
        }
        
        // Create service configuration
        NSURL *endpointURL = [NSURL URLWithString:endpoint];
        OBSServiceConfiguration *configuration = [[OBSServiceConfiguration alloc]
            initWithURL:endpointURL
            credentialProvider:credentialProvider];
        
        // Note: SDK 3.25.9 doesn't expose timeout and retry configuration properties
        // These are managed internally by the SDK
        
        // Create OBS client
        self.obsClient = [[OBSClient alloc] initWithConfiguration:configuration];
        
        // Store config
        self.endpoint = endpoint;
        self.bucket = bucket;
        self.accessKeyId = accessKeyId;
        self.secretAccessKey = secretAccessKey;
        self.securityToken = config[@"securityToken"];
        
        NSNumber *tokenExpiryTimeNum = config[@"tokenExpiryTime"];
        self.tokenExpiryTime = tokenExpiryTimeNum ? [tokenExpiryTimeNum doubleValue] : 0;
        
        NSString *credType = (self.securityToken && self.securityToken.length > 0) ? @"STS" : @"PERMANENT";
        OBSLog(TAG, @"[Init] credential=%@  AK_prefix=%@",
               credType,
               accessKeyId.length >= 6 ? [accessKeyId substringToIndex:6] : accessKeyId);
        OBSLog(TAG, @"[Init] OBS client created successfully");
        
    } @finally {
        [self.lock unlock];
    }
}

- (void)updateConfig:(NSDictionary *)config error:(NSError **)error {
    // 合并旧配置，避免部分更新时丢失其他配置
    NSMutableDictionary *mergedConfig = [NSMutableDictionary dictionary];
    if (self.endpoint) {
        [mergedConfig addEntriesFromDictionary:@{
            @"endpoint": self.endpoint ?: @"",
            @"bucket": self.bucket ?: @"",
            @"accessKeyId": self.accessKeyId ?: @"",
            @"secretAccessKey": self.secretAccessKey ?: @"",
        }];
        if (self.securityToken) mergedConfig[@"securityToken"] = self.securityToken;
        if (self.tokenExpiryTime > 0) mergedConfig[@"tokenExpiryTime"] = @(self.tokenExpiryTime);
    }
    [mergedConfig addEntriesFromDictionary:config];
    [self createClientWithConfig:mergedConfig error:error];
}

- (OBSClient *)getClientWithError:(NSError **)error {
    [self.lock lock];
    @try {
        if (!self.obsClient) {
            if (error) {
                *error = [NSError errorWithDomain:@"ObsClientHolder" code:-1
                                         userInfo:@{NSLocalizedDescriptionKey: @"OBS client not initialized"}];
            }
            return nil;
        }
        
        // Check token expiry
        if (self.tokenExpiryTime > 0) {
            NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970] * 1000;
            if (currentTime >= self.tokenExpiryTime) {
                if (error) {
                    *error = [NSError errorWithDomain:@"ObsClientHolder" code:-1
                                             userInfo:@{NSLocalizedDescriptionKey: @"Security token expired",
                                                       @"code": @"E_AUTH_EXPIRED"}];
                }
                return nil;
            }
        }
        
        return self.obsClient;
        
    } @finally {
        [self.lock unlock];
    }
}

- (BOOL)isCredentialsExpired {
    if (self.tokenExpiryTime == 0) {
        return NO;
    }
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970] * 1000;
    return currentTime >= self.tokenExpiryTime;
}

- (NSString *)getEndpoint {
    return self.endpoint;
}

- (NSDictionary *)getCurrentConfig {
    NSMutableDictionary *config = [NSMutableDictionary dictionary];
    if (self.endpoint) config[@"endpoint"] = self.endpoint;
    if (self.bucket) config[@"bucket"] = self.bucket;
    if (self.accessKeyId) config[@"accessKeyId"] = self.accessKeyId;
    if (self.secretAccessKey) config[@"secretAccessKey"] = self.secretAccessKey;
    if (self.securityToken) config[@"securityToken"] = self.securityToken;
    if (self.tokenExpiryTime > 0) config[@"tokenExpiryTime"] = @(self.tokenExpiryTime);
    return [config copy];
}

- (void)closeClient {
    [self.lock lock];
    if (self.obsClient) {
        OBSLog(TAG, @"[Close] Closing OBS client");
    }
    self.obsClient = nil;
    self.endpoint = nil;
    self.bucket = nil;
    self.accessKeyId = nil;
    self.secretAccessKey = nil;
    self.securityToken = nil;
    self.tokenExpiryTime = 0;
    [self.lock unlock];
}

@end
