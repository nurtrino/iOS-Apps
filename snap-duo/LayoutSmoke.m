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

@interface DuoStorageTestManager : NSFileManager
@property(nonatomic) NSUInteger nativeGroupCalls;
@property(nonatomic) BOOL failDirectoryCreation;
@end
@implementation DuoStorageTestManager
- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)identifier {
    self.nativeGroupCalls++;
    return [NSURL fileURLWithPath:@"/native-group-result" isDirectory:YES];
}
- (BOOL)createDirectoryAtURL:(NSURL *)url withIntermediateDirectories:(BOOL)intermediate
                 attributes:(NSDictionary<NSFileAttributeKey,id> *)attributes error:(NSError **)error {
    if (self.failDirectoryCreation) {
        if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError userInfo:nil];
        return NO;
    }
    return [super createDirectoryAtURL:url withIntermediateDirectories:intermediate attributes:attributes error:error];
}
@end

static void RunStorageTests(void) {
    Check(InstallPrivateGroupStorage(DuoStorageTestManager.class), @"Storage adapter failed to install");
    DuoStorageTestManager *manager = [DuoStorageTestManager new];
    NSURL *group = [manager containerURLForSecurityApplicationGroupIdentifier:@"group.snapchat.picaboo"];
    Check(group != nil, @"Missing private storage directory");
    NSString *home = [NSHomeDirectory() stringByResolvingSymlinksInPath];
    Check([[group.path stringByResolvingSymlinksInPath] hasPrefix:[home stringByAppendingString:@"/"]],
          @"Private storage escaped the application's container");
    Check(manager.nativeGroupCalls == 0, @"Target group still requested an unavailable entitlement");
    NSURL *file = [group URLByAppendingPathComponent:[NSString stringWithFormat:@"fixture-%@.txt",NSUUID.UUID.UUIDString]];
    NSError *error = nil;
    Check([@"storage-round-trip" writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:&error],
          @"Private storage write failed");
    Check([[NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:&error] isEqual:@"storage-round-trip"],
          @"Private storage read failed");
    Check([[manager containerURLForSecurityApplicationGroupIdentifier:@"group.snapchat.picaboo"] isEqual:group],
          @"Repeated group requests changed directory");
    Check([manager removeItemAtURL:file error:&error], @"Fixture file cleanup failed");
    NSURL *other = [manager containerURLForSecurityApplicationGroupIdentifier:@"group.unrelated.example"];
    Check([other.path isEqual:@"/native-group-result"] && manager.nativeGroupCalls == 1,
          @"Unrelated group lookup changed");
    manager.failDirectoryCreation = YES;
    Check([manager containerURLForSecurityApplicationGroupIdentifier:@"group.snapchat.picaboo"] == nil,
          @"Directory creation failure returned a nonexistent container");
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
        NSString *result = @"PASS: private storage read/write, stable sandbox path, unrelated-group passthrough, failure handling; five layouts, repeated transitions, safe areas, moved hit targets, hidden controls.";
        @try { RunStorageTests(); RunLayoutTests(self.window); }
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
