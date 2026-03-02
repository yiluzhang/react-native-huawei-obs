//
//  ConcurrencyManager.m
//  HuaweiObs
//
//  Created by react-native-huawei-obs
//

#import "ConcurrencyManager.h"
#import <mach/mach.h>
#import <mach/mach_host.h>

@interface ConcurrencyManager ()

@property (nonatomic, strong) dispatch_semaphore_t semaphore;
@property (nonatomic, assign) NSInteger maxConcurrency;

@end

@implementation ConcurrencyManager

- (instancetype)init {
    return [self initWithMaxConcurrency:10];
}

- (instancetype)initWithMaxConcurrency:(NSInteger)maxConcurrency {
    if (self = [super init]) {
        _maxConcurrency = MAX(1, MIN(10, maxConcurrency));
        _semaphore = dispatch_semaphore_create(_maxConcurrency);
    }
    return self;
}

- (NSInteger)calculateConcurrencyWithPartSizeMB:(NSInteger)partSizeMB
                              configConcurrency:(NSInteger)configConcurrency {
    NSInteger availableMemoryMB = [self getAvailableMemoryMB];
    
    // Calculate max concurrency based on available memory
    NSInteger memoryBasedMax = MAX(1, availableMemoryMB / partSizeMB);
    
    // Take minimum of config and memory-based calculation
    NSInteger actualConcurrency = MIN(configConcurrency, memoryBasedMax);
    
    // Clamp between 1-10
    return MAX(1, MIN(10, actualConcurrency));
}

- (NSInteger)getAvailableMemoryMB {
    mach_port_t host_port = mach_host_self();
    mach_msg_type_number_t host_size = sizeof(vm_statistics64_data_t) / sizeof(integer_t);
    vm_size_t pagesize;
    vm_statistics64_data_t vm_stat;
    
    host_page_size(host_port, &pagesize);
    
    kern_return_t result = host_statistics64(host_port, HOST_VM_INFO64,
                                             (host_info64_t)&vm_stat, &host_size);
    
    if (result != KERN_SUCCESS) {
        // Conservative fallback: 256MB
        return 256;
    }
    
    int64_t freeMemory = (int64_t)vm_stat.free_count * (int64_t)pagesize;
    int64_t inactiveMemory = (int64_t)vm_stat.inactive_count * (int64_t)pagesize;
    
    // Available = free + inactive
    int64_t availableBytes = freeMemory + inactiveMemory;
    NSInteger availableMB = (NSInteger)(availableBytes / 1024 / 1024);
    
    return availableMB;
}

- (NSInteger)getTotalMemoryMB {
    uint64_t totalBytes = [[NSProcessInfo processInfo] physicalMemory];
    return (NSInteger)(totalBytes / 1024 / 1024);
}

- (dispatch_semaphore_t)getSemaphore {
    return self.semaphore;
}

- (void)executeWithLimitAndBlock:(dispatch_block_t)block {
    dispatch_semaphore_wait(self.semaphore, DISPATCH_TIME_FOREVER);
    
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @try {
            block();
        } @finally {
            dispatch_semaphore_signal(self.semaphore);
        }
    });
}

@end
