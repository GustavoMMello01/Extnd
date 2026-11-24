#import "VirtualDisplay.h"

// Local declarations for the undocumented CoreGraphics virtual display API.
// Resolve the classes at runtime so the app can report an unsupported system.
@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic) unsigned int vendorID, productID, serialNum, serialNumber;
@property (nonatomic) unsigned int maxPixelsWide, maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, copy) NSArray<CGVirtualDisplayMode *> *modes;
@end

@interface CGVirtualDisplay : NSObject
@property (nonatomic, readonly) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

@implementation ExtndVirtualDisplay {
    CGVirtualDisplay *_display;
}

+ (instancetype)makeDisplay {
    CGVirtualDisplayDescriptor *descriptor = [NSClassFromString(@"CGVirtualDisplayDescriptor") new];
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    CGVirtualDisplaySettings *settings = [NSClassFromString(@"CGVirtualDisplaySettings") new];
    if (!descriptor || !displayClass || !modeClass || !settings ||
        ![displayClass instancesRespondToSelector:@selector(initWithDescriptor:)] ||
        ![displayClass instancesRespondToSelector:@selector(applySettings:)] ||
        ![modeClass instancesRespondToSelector:@selector(initWithWidth:height:refreshRate:)]) {
        return nil;
    }

    descriptor.name = @"Extnd";
    descriptor.queue = dispatch_get_main_queue();
    descriptor.vendorID = 0x4558;
    descriptor.productID = 1;
    unsigned int serial = arc4random_uniform(UINT32_MAX - 1) + 1;
    descriptor.serialNum = serial;
    if ([descriptor respondsToSelector:@selector(setSerialNumber:)]) {
        descriptor.serialNumber = serial;
    }
    descriptor.maxPixelsWide = 1024;
    descriptor.maxPixelsHigh = 768;
    descriptor.sizeInMillimeters = CGSizeMake(160, 120);
    descriptor.redPrimary = CGPointMake(0.64, 0.33);
    descriptor.greenPrimary = CGPointMake(0.30, 0.60);
    descriptor.bluePrimary = CGPointMake(0.15, 0.06);
    descriptor.whitePoint = CGPointMake(0.3127, 0.3290);

    CGVirtualDisplayMode *mode = [[modeClass alloc] initWithWidth:1024 height:768 refreshRate:60];
    if (!mode) {
        return nil;
    }
    settings.modes = @[mode];
    CGVirtualDisplay *display = [[displayClass alloc] initWithDescriptor:descriptor];
    if (!display || ![display applySettings:settings] || display.displayID == 0) {
        return nil;
    }

    ExtndVirtualDisplay *result = [self new];
    result->_display = display;
    return result;
}

- (CGDirectDisplayID)displayID {
    return _display.displayID;
}
@end
