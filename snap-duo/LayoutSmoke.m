// UIKit fixture for the geometry and hit-test regressions introduced by moving
// Snapchat's existing controls. This does not simulate Snapchat or Duo cameras.
#import "DuoCamera.m"

@interface SCCameraToolbarView : UIView
@end
@implementation SCCameraToolbarView
@end

@interface SCCameraOverlayView : UIView
@property(nonatomic, strong) UIControl *cameraTimer;
@property(nonatomic, strong) UIControl *galleryIcon;
@property(nonatomic, strong) UIControl *profileButton;
@property(nonatomic, strong) UIView *footer;
@property(nonatomic, strong) SCCameraToolbarView *toolbar;
@end
@implementation SCCameraOverlayView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.footer = [UIView new];
        self.footer.clipsToBounds = YES;
        [self addSubview:self.footer];
        self.cameraTimer = [UIControl new];
        self.galleryIcon = [UIControl new];
        self.profileButton = [UIControl new];
        self.toolbar = [SCCameraToolbarView new];
        [self.footer addSubview:self.cameraTimer];
        [self.footer addSubview:self.galleryIcon];
        [self addSubview:self.profileButton];
        [self addSubview:self.toolbar];
    }
    return self;
}
- (UIEdgeInsets)safeAreaInsets { return UIEdgeInsetsMake(48, 16, 24, 32); }
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width;
    CGFloat height = self.bounds.size.height;
    self.footer.frame = CGRectMake(0, height-120, width, 120);
    self.cameraTimer.frame = CGRectMake(width/2-36, 16, 72, 72);
    self.galleryIcon.frame = CGRectMake(width/2-100, 28, 44, 44);
    self.profileButton.frame = CGRectMake(12, 12, 44, 44);
    self.toolbar.frame = CGRectMake(width-60, 60, 44, 160);
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return [super hitTest:point withEvent:event];
}
@end

static void Check(BOOL condition, NSString *message) {
    if (!condition) @throw [NSException exceptionWithName:@"LayoutTest" reason:message userInfo:nil];
}

static void RunLayoutTests(UIWindow *window) {
    InstallOverlay();
    SCCameraOverlayView *overlay = [[SCCameraOverlayView alloc] initWithFrame:CGRectMake(0,0,390,844)];
    [window.rootViewController.view addSubview:overlay];
    NSArray<NSValue *> *sizes = @[
        [NSValue valueWithCGSize:CGSizeMake(390,844)],
        [NSValue valueWithCGSize:CGSizeMake(768,1024)],
        [NSValue valueWithCGSize:CGSizeMake(1024,768)],
        [NSValue valueWithCGSize:CGSizeMake(844,390)],
        [NSValue valueWithCGSize:CGSizeMake(390,844)],
    ];
    for (NSValue *value in sizes) {
        CGSize size = value.CGSizeValue;
        overlay.frame = (CGRect){CGPointZero,size};
        for (int pass = 0; pass < 3; pass++) {
            [overlay setNeedsLayout];
            [overlay layoutIfNeeded];
            CGRect safe = CGRectInset(UIEdgeInsetsInsetRect(overlay.bounds,overlay.safeAreaInsets),12,12);
            for (UIView *control in @[overlay.cameraTimer,overlay.galleryIcon,overlay.profileButton,overlay.toolbar]) {
                CGRect frame = [control convertRect:control.bounds toView:overlay];
                Check(CGRectContainsRect(CGRectInset(safe,-0.1,-0.1),frame),@"Control outside safe area");
            }
            CGRect shutter = [overlay.cameraTimer convertRect:overlay.cameraTimer.bounds toView:overlay];
            CGPoint center = CGPointMake(CGRectGetMidX(shutter),CGRectGetMidY(shutter));
            Check([overlay hitTest:center withEvent:nil] == overlay.cameraTimer,@"Moved shutter lost hit testing");
            if (size.width > size.height) {
                Check(fabs(center.y-CGRectGetMidY(safe)) < 0.5,@"Landscape shutter failed to center");
                Check(fabs(CGRectGetMaxX(shutter)-CGRectGetMaxX(safe)) < 0.5,@"Landscape shutter failed to align");
                Check(!overlay.footer.clipsToBounds,@"Parent clips moved shutter");
            } else {
                Check(fabs(center.x-size.width/2) < 0.5,@"Portrait shutter accumulated displacement");
            }
        }
    }
    overlay.footer.hidden = YES;
    CGRect shutter = [overlay.cameraTimer convertRect:overlay.cameraTimer.bounds toView:overlay];
    Check([overlay hitTest:CGPointMake(CGRectGetMidX(shutter),CGRectGetMidY(shutter)) withEvent:nil] != overlay.cameraTimer,
          @"Hidden parent still receives shutter touch");
    [overlay removeFromSuperview];
}

@interface TestDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation TestDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [UIViewController new];
    [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *result = @"PASS: five layouts, repeated transitions, safe areas, moved hit targets, hidden controls.";
        @try { RunLayoutTests(self.window); }
        @catch (NSException *error) { result = [@"FAIL: " stringByAppendingString:error.reason]; }
        NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        [result writeToURL:[documents URLByAppendingPathComponent:@"result.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        exit([result hasPrefix:@"PASS"] ? 0 : 1);
    });
    return YES;
}
@end
int main(int argc,char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(TestDelegate.class)); }
}
