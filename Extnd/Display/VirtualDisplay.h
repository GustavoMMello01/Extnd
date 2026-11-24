#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface ExtndVirtualDisplay : NSObject
@property (nonatomic, readonly) CGDirectDisplayID displayID;
+ (nullable instancetype)makeDisplay;
@end
NS_ASSUME_NONNULL_END
