//
//  DownloadManager.h
//  HuaweiObs
//
//  Created by react-native-huawei-obs
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DownloadParams : NSObject

@property (nonatomic, copy) NSString *taskId;
@property (nonatomic, copy) NSString *objectKey;
@property (nonatomic, copy) NSString *bucket;
@property (nonatomic, copy) NSString *savePath;
@property (nonatomic, copy, nullable) NSString *range;
@property (nonatomic, copy, nullable) NSString *versionId;
@property (nonatomic, assign) NSTimeInterval startTimeMs;

- (instancetype)initWithTaskId:(NSString *)taskId
                     objectKey:(NSString *)objectKey
                        bucket:(NSString *)bucket
                      savePath:(NSString *)savePath
                         range:(nullable NSString *)range
                     versionId:(nullable NSString *)versionId;

@end

@interface DownloadResult : NSObject

@property (nonatomic, copy) NSString *taskId;
@property (nonatomic, copy) NSString *objectKey;
@property (nonatomic, copy) NSString *savePath;
@property (nonatomic, assign) int64_t size;
@property (nonatomic, copy) NSString *etag;
@property (nonatomic, assign) NSTimeInterval duration;
@property (nonatomic, assign) double avgSpeed;

- (instancetype)initWithTaskId:(NSString *)taskId
                     objectKey:(NSString *)objectKey
                      savePath:(NSString *)savePath
                          size:(int64_t)size
                         etag:(NSString *)etag
                      duration:(NSTimeInterval)duration
                      avgSpeed:(double)avgSpeed;

@end

@class EventEmitter, ObsClientHolder;

@interface DownloadManager : NSObject

- (instancetype)initWithObsClientHolder:(ObsClientHolder *)obsClientHolder
                           eventEmitter:(EventEmitter *)eventEmitter;

/// Start download
- (NSString *)startDownloadWithParams:(DownloadParams *)params;

/// Cancel download
- (void)cancelDownloadWithTaskId:(NSString *)taskId error:(NSError **)error;

/// Cancel all downloads
- (void)cancelAll;

/// Get task status
- (nullable NSDictionary *)getTaskStatusWithTaskId:(NSString *)taskId;

/// Get all tasks
- (NSArray<NSDictionary *> *)getAllTasks;

/// Clear completed tasks
- (void)clearCompletedTasks;

/// Cleanup resources
- (void)destroy;

@end

NS_ASSUME_NONNULL_END
