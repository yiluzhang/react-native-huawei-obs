//
//  LocalTimeUtils.h
//  test
//
//  Created by ruanhanzhou on 2024/9/12.
//  Copyright © 2024 Lprison. All rights reserved.
//

#ifndef OBSLocalTimeUtils_h
#define OBSLocalTimeUtils_h
@interface OBSLocalTimeUtils : NSObject
+ (NSDate*) dateWithTimeDiff: (NSDate*) date;
+ (void) setTimeDiffInSecond:(long) timeDiffSecondsInLong;
+ (void) setTimeDiffInSecondFromServerTime:(NSDictionary *) headers
                              xmlErrorDict:(NSDictionary *) xmlErrorDict;

+ (Boolean) isAutoRetryEnabled;
+ (void) setIfAutoRetryEnabled:(Boolean) isAutoRetryEnabled;
@end
#endif /* OBSLocalTimeUtils_h */
