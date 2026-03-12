//
//  HuaweiObs.m
//  HuaweiObs
//
//  Created by react-native-huawei-obs
//

#import "HuaweiObs.h"
#import "ObsClientHolder.h"
#import "FileStreamManager.h"
#import "ConcurrencyManager.h"
#import "EventEmitter.h"
#import "UploadManager.h"
#import "DownloadManager.h"
#import "ErrorMapper.h"
#import <OBS/OBS.h>

@interface HuaweiObs ()

@property (nonatomic, strong) ObsClientHolder *obsClientHolder;
@property (nonatomic, strong) FileStreamManager *fileStreamManager;
@property (nonatomic, strong) ConcurrencyManager *concurrencyManager;
@property (nonatomic, strong) EventEmitter *eventEmitter;
@property (nonatomic, strong) UploadManager *uploadManager;
@property (nonatomic, strong) DownloadManager *downloadManager;

@property (nonatomic, assign) BOOL isInitialized;

@end

@implementation HuaweiObs

RCT_EXPORT_MODULE()

- (NSArray<NSString *> *)supportedEvents {
    return @[
        @"uploadPreparing",
        @"uploadStart",
        @"uploadProgress",
        @"uploadSuccess",
        @"uploadError",
        @"uploadCancel",
        @"downloadStart",
        @"downloadProgress",
        @"downloadSuccess",
        @"downloadError",
        @"downloadCancel"
    ];
}

// ==================== Client Management ====================

RCT_EXPORT_METHOD(initClient:(NSDictionary *)config
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    @try {
        // Validate required parameters
        NSString *endpoint = config[@"endpoint"];
        NSString *bucket = config[@"bucket"];
        NSString *accessKeyId = config[@"accessKeyId"];
        NSString *secretAccessKey = config[@"secretAccessKey"];
        
        if (!endpoint || !bucket || !accessKeyId || !secretAccessKey) {
            reject(@"E_INVALID_CONFIG", @"Missing required config parameters", nil);
            return;
        }
        
        // Initialize managers
        self.obsClientHolder = [[ObsClientHolder alloc] init];
        self.fileStreamManager = [[FileStreamManager alloc] init];
        
        NSInteger maxConcurrency = [config[@"maxConcurrency"] integerValue] ?: 6;
        self.concurrencyManager = [[ConcurrencyManager alloc] initWithMaxConcurrency:maxConcurrency];
        
        self.eventEmitter = [[EventEmitter alloc] initWithBridge:self.bridge];
        self.uploadManager = [[UploadManager alloc] initWithFileStreamManager:self.fileStreamManager
                                                             obsClientHolder:self.obsClientHolder
                                                          concurrencyManager:self.concurrencyManager
                                                                eventEmitter:self.eventEmitter];
        self.downloadManager = [[DownloadManager alloc] initWithObsClientHolder:self.obsClientHolder
                                                                    eventEmitter:self.eventEmitter];
        
        // Create OBS client
        NSError *error = nil;
        [self.obsClientHolder createClientWithConfig:config error:&error];
        if (error) {
            reject(@"E_CLIENT_INIT_FAILED", error.localizedDescription, error);
            return;
        }
        
        self.isInitialized = YES;
        resolve(nil);
        
    } @catch (NSException *exception) {
        reject(@"E_EXCEPTION", exception.description, nil);
    }
}

RCT_EXPORT_METHOD(updateConfig:(NSDictionary *)config
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @try {
            if (![self checkInitializedWithReject:reject]) return;
            NSError *error = nil;
            [self.obsClientHolder updateConfig:config error:&error];
            if (error) {
                reject(@"E_UPDATE_CONFIG_FAILED", error.localizedDescription, error);
                return;
            }
            resolve(nil);
        } @catch (NSException *exception) {
            reject(@"E_EXCEPTION", exception.description, nil);
        }
    });
}

RCT_EXPORT_METHOD(validateConfig:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @try {
            if (![self checkInitializedWithReject:reject]) return;
            BOOL isValid = self.obsClientHolder != nil && ![self.obsClientHolder isCredentialsExpired];
            resolve(@(isValid));
        } @catch (NSException *exception) {
            reject(@"E_EXCEPTION", exception.description, nil);
        }
    });
}

RCT_EXPORT_METHOD(destroy:(RCTPromiseResolveBlock)resolve
         rejecter:(RCTPromiseRejectBlock)reject) {
    @try {
        if (self.isInitialized) {
            [self.uploadManager cancelAll];
            [self.downloadManager cancelAll];
            [self.fileStreamManager closeAllStreams];
            [self.obsClientHolder closeClient];
            self.isInitialized = NO;
        }
        resolve(nil);
    } @catch (NSException *exception) {
        reject(@"E_EXCEPTION", exception.description, nil);
    }
}

// ==================== File Stream Management ====================

RCT_EXPORT_METHOD(openFileStream:(NSString *)filePath
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    @try {
        if (![self checkInitializedWithReject:reject]) return;
        NSError *error = nil;
        FileStreamInfo *fileInfo = [self.fileStreamManager openFileStreamWithPath:filePath error:&error];
        if (!fileInfo) {
            NSDictionary *errorDict = [ErrorMapper mapError:error];
            reject(errorDict[@"code"], errorDict[@"message"], error);
            return;
        }
        
        resolve(@{
            @"streamId": fileInfo.streamId,
            @"fileSize": @(fileInfo.fileSize),
            @"fileName": fileInfo.fileName,
            @"mimeType": fileInfo.mimeType,
            @"lastModified": @(fileInfo.lastModified)
        });
    } @catch (NSException *exception) {
        reject(@"E_EXCEPTION", exception.description, nil);
    }
}

RCT_EXPORT_METHOD(closeStream:(NSString *)streamId
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    @try {
        if (![self checkInitializedWithReject:reject]) return;
        NSError *error = nil;
        [self.fileStreamManager closeStreamWithId:streamId error:&error];
        if (error) {
            NSDictionary *errorDict = [ErrorMapper mapError:error];
            reject(errorDict[@"code"], errorDict[@"message"], error);
            return;
        }
        resolve(nil);
    } @catch (NSException *exception) {
        reject(@"E_EXCEPTION", exception.description, nil);
    }
}

RCT_EXPORT_METHOD(closeAllStreams:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    @try {
        if (![self checkInitializedWithReject:reject]) return;
        [self.fileStreamManager closeAllStreams];
        resolve(nil);
    } @catch (NSException *exception) {
        reject(@"E_EXCEPTION", exception.description, nil);
    }
}

// ==================== Upload ====================

RCT_EXPORT_METHOD(upload:(NSDictionary *)params
            resolver:(RCTPromiseResolveBlock)resolve
            rejecter:(RCTPromiseRejectBlock)reject) {
    [self multipartUpload:params resolver:resolve rejecter:reject];
}

RCT_EXPORT_METHOD(multipartUpload:(NSDictionary *)params
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    @try {
        if (![self checkInitializedWithReject:reject]) return;
        
        NSString *filePath = params[@"filePath"];
        NSString *objectKey = params[@"objectKey"];
        NSString *bucket = params[@"bucket"];
        
        if (!filePath || !objectKey || !bucket) {
            reject(@"E_INVALID_PARAMS", @"Missing required parameters", nil);
            return;
        }
        
        NSString *taskId = [[NSUUID UUID] UUIDString];
        
        UploadParams *uploadParams = [[UploadParams alloc]
            initWithTaskId:taskId
                 filePath:filePath
                objectKey:objectKey
                   bucket:bucket
              contentType:params[@"contentType"]
                 metadata:params[@"metadata"]
                      acl:params[@"acl"]
             storageClass:params[@"storageClass"]
                 partSize:params[@"partSize"]
                concurrency:params[@"concurrency"]];
        
        [self.uploadManager startUploadWithParams:uploadParams];
        resolve(taskId);
        
    } @catch (NSException *exception) {
        reject(@"E_EXCEPTION", exception.description, nil);
    }
}

RCT_EXPORT_METHOD(cancelUpload:(NSString *)taskId
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @try {
            if (![self checkInitializedWithReject:reject]) return;
            NSError *error = nil;
            [self.uploadManager cancelUploadWithTaskId:taskId error:&error];
            if (error) {
                NSDictionary *errorDict = [ErrorMapper mapError:error];
                reject(errorDict[@"code"], errorDict[@"message"], error);
                return;
            }
            resolve(nil);
        } @catch (NSException *exception) {
            reject(@"E_EXCEPTION", exception.description, nil);
        }
    });
}

// ==================== Download ====================

RCT_EXPORT_METHOD(download:(NSDictionary *)params
            resolver:(RCTPromiseResolveBlock)resolve
            rejecter:(RCTPromiseRejectBlock)reject) {
    @try {
        if (![self checkInitializedWithReject:reject]) return;
        
        NSString *objectKey = params[@"objectKey"];
        NSString *bucket = params[@"bucket"];
        NSString *savePath = params[@"savePath"];
        
        if (!objectKey || !bucket || !savePath) {
            reject(@"E_INVALID_PARAMS", @"Missing required parameters", nil);
            return;
        }
        
        NSString *taskId = [[NSUUID UUID] UUIDString];
        
        DownloadParams *downloadParams = [[DownloadParams alloc]
            initWithTaskId:taskId
                objectKey:objectKey
                   bucket:bucket
                 savePath:savePath
                    range:params[@"range"]
                versionId:params[@"versionId"]];
        
        [self.downloadManager startDownloadWithParams:downloadParams];
        resolve(taskId);
        
    } @catch (NSException *exception) {
        reject(@"E_EXCEPTION", exception.description, nil);
    }
}

RCT_EXPORT_METHOD(cancelDownload:(NSString *)taskId
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @try {
            if (![self checkInitializedWithReject:reject]) return;
            NSError *error = nil;
            [self.downloadManager cancelDownloadWithTaskId:taskId error:&error];
            if (error) {
                NSDictionary *errorDict = [ErrorMapper mapError:error];
                reject(errorDict[@"code"], errorDict[@"message"], error);
                return;
            }
            resolve(nil);
        } @catch (NSException *exception) {
            reject(@"E_EXCEPTION", exception.description, nil);
        }
    });
}

// ==================== Delete ====================

RCT_EXPORT_METHOD(deleteObject:(NSDictionary *)params
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @try {
            if (!self.isInitialized || !self.obsClientHolder) {
                reject(@"E_NOT_INITIALIZED", @"OBS client not initialized. Call initClient first.", nil);
                return;
            }
            
            NSString *bucket = params[@"bucket"];
            NSString *objectKey = params[@"objectKey"];
            
            NSLog(@"[HuaweiObs] Delete request - bucket: %@, objectKey: %@", bucket, objectKey);
            
            if (!bucket || !objectKey) {
                reject(@"E_INVALID_PARAMS", @"Missing required parameters: bucket and objectKey", nil);
                return;
            }
            
            NSError *clientError = nil;
            OBSClient *client = [self.obsClientHolder getClientWithError:&clientError];
            if (!client) {
                NSLog(@"[HuaweiObs] Delete - client is nil, error: %@", clientError);
                NSDictionary *errorDict = [ErrorMapper mapError:clientError];
                reject(errorDict[@"code"], errorDict[@"message"], clientError);
                return;
            }
            
            // 创建删除请求
            OBSDeleteObjectRequest *request = [[OBSDeleteObjectRequest alloc]
                initWithBucketName:bucket objectKey:objectKey];
            
            // 使用通用 invokeRequest 入口（category 方法因缺少 -ObjC linker flag 不可用）
            OBSBFTask *task = [client invokeRequest:request];
            [task continueWithBlock:^id _Nullable(OBSBFTask * _Nonnull t) {
                if (t.error) {
                    NSDictionary *xmlBody = t.error.userInfo[@"responseXMLBodyDict"];
                    NSLog(@"[HuaweiObs] Delete failed - domain: %@, code: %ld, serverCode: %@, message: %@",
                          t.error.domain, (long)t.error.code,
                          xmlBody[@"Code"] ?: @"N/A",
                          xmlBody[@"Message"] ?: t.error.localizedDescription);
                    NSDictionary *errorDict = [ErrorMapper mapError:t.error];
                    reject(errorDict[@"code"], errorDict[@"message"], t.error);
                } else {
                    NSLog(@"[HuaweiObs] Delete succeeded - bucket: %@, objectKey: %@", bucket, objectKey);
                    resolve(@{
                        @"bucket": bucket,
                        @"objectKey": objectKey
                    });
                }
                return nil;
            }];
        } @catch (NSException *exception) {
            NSLog(@"[HuaweiObs] Delete exception: %@ - reason: %@",
                  exception.name, exception.reason);
            reject(@"E_EXCEPTION", [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason], nil);
        }
    });
}

RCT_EXPORT_METHOD(deleteMultipleObjects:(NSDictionary *)params
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @try {
            if (![self checkInitializedWithReject:reject]) return;
            
            NSString *bucket = params[@"bucket"];
            NSArray<NSString *> *objectKeys = params[@"objectKeys"];
            
            if (!bucket || !objectKeys) {
                reject(@"E_INVALID_PARAMS", @"Missing required parameters: bucket and objectKeys", nil);
                return;
            }
            
            NSError *clientError = nil;
            OBSClient *client = [self.obsClientHolder getClientWithError:&clientError];
            if (!client) {
                NSDictionary *errorDict = [ErrorMapper mapError:clientError];
                reject(errorDict[@"code"], errorDict[@"message"], clientError);
                return;
            }
            
            NSMutableArray *results = [NSMutableArray array];
            dispatch_group_t group = dispatch_group_create();
            NSLock *resultsLock = [[NSLock alloc] init];
            
            for (NSString *objectKey in objectKeys) {
                dispatch_group_enter(group);
                OBSDeleteObjectRequest *request = [[OBSDeleteObjectRequest alloc]
                    initWithBucketName:bucket objectKey:objectKey];
                
                OBSBFTask *task = [client invokeRequest:request];
                [task continueWithBlock:^id _Nullable(OBSBFTask * _Nonnull t) {
                    [resultsLock lock];
                    if (t.error) {
                        NSDictionary *errorDict = [ErrorMapper mapError:t.error];
                        [results addObject:@{
                            @"objectKey": objectKey,
                            @"success": @(NO),
                            @"errorCode": errorDict[@"code"] ?: @"E_UNKNOWN",
                            @"errorMessage": errorDict[@"message"] ?: @"Unknown error"
                        }];
                    } else {
                        [results addObject:@{
                            @"objectKey": objectKey,
                            @"success": @(YES)
                        }];
                    }
                    [resultsLock unlock];
                    dispatch_group_leave(group);
                    return nil;
                }];
            }
            
            dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
            resolve(results);
            
        } @catch (NSException *exception) {
            reject(@"E_EXCEPTION", exception.description, nil);
        }
    });
}

RCT_EXPORT_METHOD(clearCompletedTasks:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    @try {
        if (![self checkInitializedWithReject:reject]) return;
        [self.uploadManager clearCompletedTasks];
        [self.downloadManager clearCompletedTasks];
        resolve(nil);
    } @catch (NSException *exception) {
        reject(@"E_EXCEPTION", exception.description, nil);
    }
}

// ==================== Task Management ====================

RCT_EXPORT_METHOD(getTaskStatus:(NSString *)taskId
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    @try {
        if (![self checkInitializedWithReject:reject]) return;
        
        NSDictionary *uploadStatus = [self.uploadManager getTaskStatusWithTaskId:taskId];
        NSDictionary *downloadStatus = [self.downloadManager getTaskStatusWithTaskId:taskId];
        
        NSDictionary *status = uploadStatus ?: downloadStatus;
        resolve(status ?: [NSNull null]);
        
    } @catch (NSException *exception) {
        reject(@"E_EXCEPTION", exception.description, nil);
    }
}

RCT_EXPORT_METHOD(getAllTasks:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    @try {
        if (![self checkInitializedWithReject:reject]) return;
        
        NSArray *uploadTasks = [self.uploadManager getAllTasks];
        NSArray *downloadTasks = [self.downloadManager getAllTasks];
        
        NSMutableArray *allTasks = [NSMutableArray arrayWithArray:uploadTasks];
        [allTasks addObjectsFromArray:downloadTasks];
        
        resolve(allTasks);
        
    } @catch (NSException *exception) {
        reject(@"E_EXCEPTION", exception.description, nil);
    }
}

// ==================== System Info ====================

RCT_EXPORT_METHOD(getAvailableMemory:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    @try {
        if (![self checkInitializedWithReject:reject]) return;
        NSInteger memory = [self.concurrencyManager getAvailableMemoryMB];
        resolve(@(memory));
    } @catch (NSException *exception) {
        reject(@"E_EXCEPTION", exception.description, nil);
    }
}

RCT_EXPORT_METHOD(getTotalMemory:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    @try {
        if (![self checkInitializedWithReject:reject]) return;
        NSInteger memory = [self.concurrencyManager getTotalMemoryMB];
        resolve(@(memory));
    } @catch (NSException *exception) {
        reject(@"E_EXCEPTION", exception.description, nil);
    }
}

// ==================== Helper Methods ====================

- (BOOL)checkInitializedWithReject:(RCTPromiseRejectBlock)reject {
    if (!self.isInitialized || !self.obsClientHolder) {
        reject(@"E_NOT_INITIALIZED", @"OBS client not initialized. Call initClient first.", nil);
        return NO;
    }
    return YES;
}

@end
