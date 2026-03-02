//
//  ConcurrencyManager.h
//  HuaweiObs
//
//  Created by react-native-huawei-obs
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ConcurrencyManager : NSObject

/// 初始化，指定最大并发数
- (instancetype)initWithMaxConcurrency:(NSInteger)maxConcurrency;

/// 计算实际并发度 (1-10之间)
- (NSInteger)calculateConcurrencyWithPartSizeMB:(NSInteger)partSizeMB
                              configConcurrency:(NSInteger)configConcurrency;

/// 获取可用内存 (MB)
- (NSInteger)getAvailableMemoryMB;

/// 获取总内存 (MB)
- (NSInteger)getTotalMemoryMB;

/// 获取信号量（用于并发控制）
- (dispatch_semaphore_t)getSemaphore;

/// 执行带并发限制的任务
- (void)executeWithLimitAndBlock:(dispatch_block_t)block;

@end

NS_ASSUME_NONNULL_END
