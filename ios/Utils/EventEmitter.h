//
//  EventEmitter.h
//  HuaweiObs
//
//  Created by react-native-huawei-obs
//

#import <Foundation/Foundation.h>
#import <React/RCTBridge.h>

NS_ASSUME_NONNULL_BEGIN

@interface EventEmitter : NSObject

- (instancetype)initWithBridge:(RCTBridge *)bridge;

/// 发送事件到 JS
- (void)emitWithEventName:(NSString *)eventName params:(NSDictionary *)params;

/// 发送进度事件（带节流）
- (void)emitProgressWithTaskId:(NSString *)taskId
                    eventName:(NSString *)eventName
                       params:(NSDictionary *)params
                        force:(BOOL)force;

/// 清除任务的节流记录
- (void)clearThrottle:(NSString *)taskId;

/// 清除所有节流记录
- (void)clearAllThrottles;

@end

NS_ASSUME_NONNULL_END
