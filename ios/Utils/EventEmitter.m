//
//  EventEmitter.m
//  HuaweiObs
//
//  Created by react-native-huawei-obs
//

#import "EventEmitter.h"
#import <React/RCTEventDispatcher.h>

@interface EventEmitter ()

@property (nonatomic, weak) RCTBridge *bridge;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *lastEmitTimes;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *lastProgress;
@property (nonatomic, strong) NSLock *lock;

@end

@implementation EventEmitter

- (instancetype)initWithBridge:(RCTBridge *)bridge {
    if (self = [super init]) {
        _bridge = bridge;
        _lastEmitTimes = [NSMutableDictionary dictionary];
        _lastProgress = [NSMutableDictionary dictionary];
        _lock = [[NSLock alloc] init];
    }
    return self;
}

- (void)emitWithEventName:(NSString *)eventName params:(NSDictionary *)params {
    if (!self.bridge) return;
    
    [[self.bridge eventDispatcher] sendAppEventWithName:eventName
                                                    body:params];
}

- (void)emitProgressWithTaskId:(NSString *)taskId
                    eventName:(NSString *)eventName
                       params:(NSDictionary *)params
                        force:(BOOL)force {
    [self.lock lock];
    
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSNumber *lastEmitTime = self.lastEmitTimes[taskId];
    NSNumber *progress = params[@"progress"];
    NSNumber *lastProg = self.lastProgress[taskId];
    
    // Monotonic guard: never emit lower progress (prevents regression from concurrent callbacks)
    if (!force && progress && lastProg && [progress doubleValue] < [lastProg doubleValue]) {
        [self.lock unlock];
        return;
    }
    
    // Throttle check (100ms + 1% threshold)
    if (!force && lastEmitTime) {
        NSTimeInterval elapsed = now - [lastEmitTime doubleValue];
        if (elapsed < 0.1) {
            if (progress && lastProg) {
                double diff = [progress doubleValue] - [lastProg doubleValue];
                if (diff < 1) {
                    [self.lock unlock];
                    return;
                }
            }
        }
    }
    
    // Update records
    self.lastEmitTimes[taskId] = @(now);
    if (progress) {
        self.lastProgress[taskId] = progress;
    }
    
    [self.lock unlock];
    
    // Emit event
    [self emitWithEventName:eventName params:params];
}

- (void)clearThrottle:(NSString *)taskId {
    [self.lock lock];
    [self.lastEmitTimes removeObjectForKey:taskId];
    [self.lastProgress removeObjectForKey:taskId];
    [self.lock unlock];
}

- (void)clearAllThrottles {
    [self.lock lock];
    [self.lastEmitTimes removeAllObjects];
    [self.lastProgress removeAllObjects];
    [self.lock unlock];
}

@end
