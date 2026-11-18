#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <sys/utsname.h>

// Scoped to the verified Snapchat 14.32.0.53 classes on the user's iPhone19,4.
static __weak UIViewController *activeCamera;
static char layoutRecordsKey;
static _Thread_local BOOL resolvingFrontDevice;

static id GetObject(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static void SetBoolIvar(id object, const char *name, BOOL value) {
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    if (!ivar || strcmp(ivar_getTypeEncoding(ivar), "B")) return;
    uint8_t *bytes = (__bridge void *)object;
    memcpy(bytes + ivar_getOffset(ivar), &value, sizeof(value));
}

static BOOL GetBoolIvar(id object, const char *name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    if (!ivar || strcmp(ivar_getTypeEncoding(ivar), "B")) return NO;
    BOOL result;
    const uint8_t *bytes = (__bridge const void *)object;
    memcpy(&result, bytes + ivar_getOffset(ivar), sizeof(result));
    return result;
}

static IMP Install(Class cls, NSString *name, const char *encoding, id block) {
    SEL selector = NSSelectorFromString(name);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || strcmp(method_getTypeEncoding(method), encoding)) {
        NSLog(@"[SnapDuo] Unsupported method %@ %@", NSStringFromClass(cls), name);
        return NULL;
    }
    IMP previous = method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(block);
    // class_replaceMethod adds an override when the method was inherited.
    class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
    return previous;
}

static void EnableFlag(NSString *className, NSString *name, BOOL classMethod) {
    Class cls = NSClassFromString(className);
    if (classMethod) cls = object_getClass(cls);
    Install(cls, name, "B16@0:8", ^BOOL(id object) { return YES; });
}

static AVCaptureDevice *VirtualFrontDevice(void) {
    if (resolvingFrontDevice) return nil;
    resolvingFrontDevice = YES;
    AVCaptureDevice *device;
    @try {
        device = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                   mediaType:AVMediaTypeVideo
                                                    position:AVCaptureDevicePositionFront];
        NSUInteger frontCameras = 0;
        for (AVCaptureDevice *part in device.constituentDevices) {
            if (part.position == AVCaptureDevicePositionFront) frontCameras++;
        }
        // Accept only a virtual camera spanning two physical selfie cameras.
        if (!device.isVirtualDevice || frontCameras < 2) device = nil;
    } @finally {
        resolvingFrontDevice = NO;
    }
    return device;
}

static void InstallFrontCamera(void) {
    Class bridge = object_getClass(NSClassFromString(@"SCCaptureDevice"));
    SEL selector = NSSelectorFromString(@"defaultDeviceWithDeviceType:mediaType:position:");
    __block IMP original;
    original = Install(bridge, NSStringFromSelector(selector), "@40@0:8@16@24q32",
        ^id(id object, NSString *type, NSString *media, AVCaptureDevicePosition position) {
            if (position == AVCaptureDevicePositionFront && [media isEqualToString:AVMediaTypeVideo]) {
                AVCaptureDevice *virtualDevice = VirtualFrontDevice();
                if (virtualDevice) return virtualDevice;
            }
            return ((id (*)(id, SEL, id, id, NSInteger))original)(object, selector, type, media, position);
        });

    // Swift device enumeration also uses DiscoverySessionDevicesImpl. Preserve
    // its rear cameras and substitute the same virtual device for selfie entries.
    Class discovery = AVCaptureDeviceDiscoverySession.class;
    Method devicesMethod = class_getInstanceMethod(discovery, @selector(devices));
    if (!devicesMethod) return;
    __block IMP originalDevices;
    originalDevices = Install(discovery, @"devices", method_getTypeEncoding(devicesMethod),
        ^NSArray *(AVCaptureDeviceDiscoverySession *session) {
            NSArray<AVCaptureDevice *> *devices =
                ((id (*)(id, SEL))originalDevices)(session, @selector(devices));
            if (resolvingFrontDevice) return devices;
            BOOL hasFront = NO;
            for (AVCaptureDevice *device in devices) {
                hasFront |= device.position == AVCaptureDevicePositionFront;
            }
            if (!hasFront) return devices;
            AVCaptureDevice *front = VirtualFrontDevice();
            if (!front) return devices;
            NSMutableArray *result = [NSMutableArray array];
            BOOL addedFront = NO;
            for (AVCaptureDevice *device in devices) {
                if (device.position != AVCaptureDevicePositionFront) {
                    [result addObject:device];
                } else if (!addedFront) {
                    [result addObject:front];
                    addedFront = YES;
                }
            }
            return result;
        });
}

@interface DuoMovedControl : NSObject
@property(nonatomic, weak) UIView *view;
@property(nonatomic) CGAffineTransform original;
@property(nonatomic) CGAffineTransform applied;
@property(nonatomic, copy) NSArray<UIView *> *clippedAncestors;
@end
@implementation DuoMovedControl
@end

static BOOL ControlVisible(UIView *view, UIView *overlay) {
    if (!view || ![view isDescendantOfView:overlay]) return NO;
    for (UIView *parent = view; parent; parent = parent.superview) {
        if (parent.hidden || parent.alpha < 0.01 || !parent.userInteractionEnabled) return NO;
        if (parent == overlay) return YES;
    }
    return NO;
}

static CGPoint ClampedCenter(CGPoint center, CGSize size, CGRect safe) {
    CGFloat halfWidth = MIN(size.width / 2, safe.size.width / 2);
    CGFloat halfHeight = MIN(size.height / 2, safe.size.height / 2);
    return CGPointMake(MAX(CGRectGetMinX(safe) + halfWidth,
                           MIN(center.x, CGRectGetMaxX(safe) - halfWidth)),
                       MAX(CGRectGetMinY(safe) + halfHeight,
                           MIN(center.y, CGRectGetMaxY(safe) - halfHeight)));
}

static void MoveControl(UIView *view, UIView *overlay, CGPoint center,
                        NSMutableArray<DuoMovedControl *> *records) {
    if (!ControlVisible(view, overlay) || CGRectIsEmpty(view.bounds)) return;
    CGRect frame = [view convertRect:view.bounds toView:overlay];
    CGPoint current = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    CGPoint from = [view.superview convertPoint:current fromView:overlay];
    CGPoint to = [view.superview convertPoint:center fromView:overlay];
    if (fabs(to.x-from.x) < 0.5 && fabs(to.y-from.y) < 0.5) return;
    DuoMovedControl *record = [DuoMovedControl new];
    record.view = view;
    record.original = view.transform;
    record.applied = CGAffineTransformConcat(view.transform,
        CGAffineTransformMakeTranslation(to.x-from.x, to.y-from.y));
    view.transform = record.applied;
    NSMutableArray<UIView *> *clipped = [NSMutableArray array];
    for (UIView *parent = view.superview; parent && parent != overlay; parent = parent.superview) {
        if (parent.clipsToBounds) {
            [clipped addObject:parent];
            parent.clipsToBounds = NO;
        }
    }
    record.clippedAncestors = clipped;
    [records addObject:record];
}

static void FindToolbars(UIView *view, NSMutableArray<UIView *> *result) {
    if ([view isKindOfClass:NSClassFromString(@"SCCameraToolbarView")]) {
        [result addObject:view];
        return;
    }
    for (UIView *child in view.subviews) FindToolbars(child, result);
}

static void LayoutControls(UIView *overlay) {
    if (!overlay.window || CGRectIsEmpty(overlay.bounds)) return;
    CGRect safe = UIEdgeInsetsInsetRect(overlay.bounds, overlay.safeAreaInsets);
    safe = CGRectInset(safe, 12, 12);
    if (safe.size.width < 180 || safe.size.height < 180) return;
    BOOL landscape = overlay.bounds.size.width > overlay.bounds.size.height;
    NSMutableArray<DuoMovedControl *> *records = [NSMutableArray array];
    UIView *shutter = GetObject(overlay, @"cameraTimer");
    UIView *gallery = GetObject(overlay, @"galleryIcon");
    UIView *profile = GetObject(overlay, @"profileButton");
    for (UIView *view in @[shutter ?: [NSNull null], gallery ?: [NSNull null], profile ?: [NSNull null]]) {
        if (![view isKindOfClass:UIView.class] || !ControlVisible(view, overlay)) continue;
        CGRect frame = [view convertRect:view.bounds toView:overlay];
        CGPoint center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
        if (landscape && view == shutter) {
            center = CGPointMake(CGRectGetMaxX(safe)-frame.size.width/2, CGRectGetMidY(safe));
        } else if (landscape && view == gallery) {
            center = CGPointMake(CGRectGetMaxX(safe)-MAX(shutter.bounds.size.width,frame.size.width)/2,
                                 CGRectGetMaxY(safe)-frame.size.height/2);
        } else if (landscape && view == profile) {
            center = CGPointMake(CGRectGetMaxX(safe)-frame.size.width/2,
                                 CGRectGetMinY(safe)+frame.size.height/2);
        }
        MoveControl(view, overlay, ClampedCenter(center, frame.size, safe), records);
    }
    NSMutableArray<UIView *> *toolbars = [NSMutableArray array];
    FindToolbars(overlay, toolbars);
    for (UIView *toolbar in toolbars) {
        CGRect frame = [toolbar convertRect:toolbar.bounds toView:overlay];
        CGPoint center = CGPointMake(CGRectGetMidX(frame),CGRectGetMidY(frame));
        if (landscape) center = CGPointMake(CGRectGetMinX(safe)+frame.size.width/2,
                                            CGRectGetMinY(safe)+frame.size.height/2);
        MoveControl(toolbar, overlay, ClampedCenter(center,frame.size,safe), records);
    }
    objc_setAssociatedObject(overlay, &layoutRecordsKey, records, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void InstallOverlay(void) {
    Class cls = NSClassFromString(@"SCCameraOverlayView");
    __block IMP originalLayout;
    originalLayout = Install(cls, @"layoutSubviews", "v16@0:8", ^(UIView *overlay) {
        NSArray<DuoMovedControl *> *records = objc_getAssociatedObject(overlay, &layoutRecordsKey);
        for (DuoMovedControl *record in records) {
            if (CGAffineTransformEqualToTransform(record.view.transform,record.applied)) {
                record.view.transform = record.original;
            }
            for (UIView *parent in record.clippedAncestors) parent.clipsToBounds = YES;
        }
        objc_setAssociatedObject(overlay, &layoutRecordsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ((void (*)(id,SEL))originalLayout)(overlay,@selector(layoutSubviews));
        LayoutControls(overlay);
    });
    __block IMP originalHit;
    originalHit = Install(cls, @"hitTest:withEvent:", "@40@0:8{CGPoint=dd}16@32",
        ^UIView *(UIView *overlay, CGPoint point, UIEvent *event) {
            if (!overlay.hidden && overlay.alpha >= 0.01 && overlay.userInteractionEnabled
                && CGRectContainsPoint(overlay.bounds,point)) {
                NSArray<DuoMovedControl *> *records = objc_getAssociatedObject(overlay,&layoutRecordsKey);
                for (DuoMovedControl *record in records.reverseObjectEnumerator) {
                    UIView *view = record.view;
                    if (!ControlVisible(view,overlay)) continue;
                    CGPoint local = [view convertPoint:point fromView:overlay];
                    UIView *hit = [view hitTest:local withEvent:event];
                    if (hit) return hit;
                }
            }
            return ((id (*)(id,SEL,CGPoint,id))originalHit)(overlay,@selector(hitTest:withEvent:),point,event);
        });
}

static void InstallOrientation(void) {
    Class cls = NSClassFromString(@"SCCameraViewController");
    __block IMP originalLoad;
    originalLoad = Install(cls, @"viewDidLoad", "v16@0:8", ^(UIViewController *vc) {
        SetBoolIvar(vc,"_enableLandscapeSupportOnIpad",YES);
        ((void (*)(id,SEL))originalLoad)(vc,@selector(viewDidLoad));
    });
    __block IMP originalAppear;
    originalAppear = Install(cls, @"viewDidAppear:", "v20@0:8B16",
        ^(UIViewController *vc, BOOL animated) {
            activeCamera = vc;
            SetBoolIvar(vc,"_enableLandscapeSupportOnIpad",YES);
            ((void (*)(id,SEL,BOOL))originalAppear)(vc,@selector(viewDidAppear:),animated);
            [vc setNeedsUpdateOfSupportedInterfaceOrientations];
        });
    __block IMP originalDisappear;
    originalDisappear = Install(cls, @"viewDidDisappear:", "v20@0:8B16",
        ^(UIViewController *vc, BOOL animated) {
            ((void (*)(id,SEL,BOOL))originalDisappear)(vc,@selector(viewDidDisappear:),animated);
            if (activeCamera == vc) activeCamera = nil;
        });
    __block IMP originalMask;
    originalMask = Install(cls, @"supportedInterfaceOrientations", "Q16@0:8",
        ^NSUInteger(UIViewController *vc) {
            if (GetBoolIvar(vc,"_shouldLockInterfaceOrientationOnIpad")) {
                return ((NSUInteger (*)(id,SEL))originalMask)(vc,@selector(supportedInterfaceOrientations));
            }
            return UIInterfaceOrientationMaskAllButUpsideDown;
        });
    Class root = NSClassFromString(@"SCMainCameraScreenRootViewController");
    __block IMP rootMask;
    rootMask = Install(root, @"supportedInterfaceOrientations", "Q16@0:8",
        ^NSUInteger(UIViewController *vc) {
            if (activeCamera && !activeCamera.presentedViewController)
                return activeCamera.supportedInterfaceOrientations;
            return ((NSUInteger (*)(id,SEL))rootMask)(vc,@selector(supportedInterfaceOrientations));
        });
    SEL appSelector = NSSelectorFromString(@"application:supportedInterfaceOrientationsForWindow:");
    __block IMP appMask;
    appMask = Install(NSClassFromString(@"SCMainAppDelegate"),NSStringFromSelector(appSelector),
        "Q32@0:8@16@24", ^NSUInteger(id delegate, UIApplication *app, UIWindow *window) {
            if (activeCamera.viewIfLoaded.window == window && window && !activeCamera.presentedViewController)
                return activeCamera.supportedInterfaceOrientations;
            return ((NSUInteger (*)(id,SEL,id,id))appMask)(delegate,appSelector,app,window);
        });
}

static void InstallNativeLayout(void) {
    Class cls = NSClassFromString(@"SCCameraViewfinderLayoutController");
    SEL selector = NSSelectorFromString(@"initWithCameraView:containingView:allowsLandscapeLayout:managesTopConstraint:managesSizeConstraints:snapshotUpdater:environmentProvider:");
    __block IMP original;
    original = Install(cls,NSStringFromSelector(selector),"@60@0:8@16@24B32B36B40@44@52",
        ^id(id object,id camera,id parent,BOOL landscape,BOOL top,BOOL size,id updater,id environment) {
            return ((id (*)(id,SEL,id,id,BOOL,BOOL,BOOL,id,id))original)(
                object,selector,camera,parent,YES,top,size,updater,environment);
        });
}

__attribute__((constructor)) static void InitializeSnapDuo(void) {
    @autoreleasepool {
        struct utsname device;
        if (uname(&device) || strcmp(device.machine,"iPhone19,4")) return;
        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
        if (![info[@"CFBundleVersion"] isEqual:@"14.32.0.53"]) return;
        if (![[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){27,1,0}]) return;
        EnableFlag(@"SCCameraSimpleUIFeatureGatingConfigurationImpl",@"runtimeViewfinderSizingEnabled",NO);
        EnableFlag(@"SCCameraViewController",@"_runtimeViewfinderSizingEnabled",NO);
        EnableFlag(@"SCCameraViewController",@"_viewportOrientationFixEnabled",NO);
        EnableFlag(@"SCCameraViewController",@"_imageCaptureOrientationFixEnabled",NO);
        EnableFlag(@"SCCameraViewController",@"_videoCaptureOrientationFixEnabled",NO);
        Install(object_getClass(NSClassFromString(@"SCCameraViewfinderLayoutExperiment")),
            @"runtimeViewfinderSizingEnabledWithAppStartExperimentReader:", "B24@0:8@16",
            ^BOOL(id object, id reader) { return YES; });
        InstallFrontCamera();
        InstallNativeLayout();
        InstallOrientation();
        InstallOverlay();
        NSLog(@"[SnapDuo] Camera and layout extension installed for Snapchat 14.32.0.53.");
    }
}
