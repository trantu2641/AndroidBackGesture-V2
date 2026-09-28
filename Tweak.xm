#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

#pragma mark - Constants

static NSString * const ABGPreferencesDomain =
    @"com.chatgpt.androidbackgestureprefs";

static CFStringRef const ABGReloadNotification =
    CFSTR("com.chatgpt.androidbackgestureprefs/Reload");

typedef NS_ENUM(NSInteger, ABGEdgeSide) {
    ABGEdgeSideNone  = 0,
    ABGEdgeSideLeft  = 1,
    ABGEdgeSideRight = 2
};

#pragma mark - Associated object keys

static char kABGPanGestureKey;
static char kABGSideKey;
static char kABGThresholdKey;

static char kABGNativePopOriginalKey;

#pragma mark - Preferences

static BOOL gABGEnabled = YES;

static BOOL gABGLeftEnabled = YES;
static BOOL gABGRightEnabled = YES;

static BOOL gABGShowIndicator = YES;
static BOOL gABGHapticsEnabled = YES;

/*
 YES:
 Nếu UINavigationController đang có gesture swipe-back
 chuẩn của iOS, nhường cạnh trái cho gesture gốc.

 NO:
 AndroidBackGesture sẽ thay gesture đó bằng cơ chế
 Android của tweak.
*/
static BOOL gABGPreferNativeLeft = NO;

/*
 Vùng tính từ cạnh màn hình được phép bắt đầu gesture.
*/
static CGFloat gABGEdgeWidth = 28.0;

/*
 Khoảng cách phải kéo để xác nhận Back.
*/
static CGFloat gABGTriggerDistance = 78.0;

/*
 Nếu vuốt rất nhanh, có thể Back dù chưa đạt đủ
 triggerDistance.
*/
static CGFloat gABGMinimumVelocity = 650.0;

static NSSet<NSString *> *gABGBlacklist = nil;

#pragma mark - Preference helpers

static id ABGCopyPreference(NSString *key)
{
    CFPropertyListRef value =
        CFPreferencesCopyAppValue(
            (__bridge CFStringRef)key,
            (__bridge CFStringRef)ABGPreferencesDomain
        );

    if (!value) {
        return nil;
    }

    return CFBridgingRelease(value);
}

static BOOL ABGBoolPreference(
    NSString *key,
    BOOL defaultValue
)
{
    id value = ABGCopyPreference(key);

    if ([value isKindOfClass:[NSNumber class]]) {
        return [value boolValue];
    }

    return defaultValue;
}

static CGFloat ABGFloatPreference(
    NSString *key,
    CGFloat defaultValue
)
{
    id value = ABGCopyPreference(key);

    if ([value respondsToSelector:@selector(doubleValue)]) {
        return (CGFloat)[value doubleValue];
    }

    return defaultValue;
}

static NSSet<NSString *> *ABGParseBlacklist(id value)
{
    if (![value isKindOfClass:[NSString class]]) {
        return [NSSet set];
    }

    NSString *string = (NSString *)value;

    NSCharacterSet *separatorSet =
        [NSCharacterSet characterSetWithCharactersInString:
            @",;\n\r\t "];

    NSArray<NSString *> *components =
        [string componentsSeparatedByCharactersInSet:separatorSet];

    NSMutableSet<NSString *> *result =
        [NSMutableSet set];

    for (NSString *item in components) {

        NSString *clean =
            [item stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];

        if (clean.length > 0) {
            [result addObject:clean];
        }
    }

    return [result copy];
}

static void ABGLoadPreferences(void)
{
    CFPreferencesAppSynchronize(
        (__bridge CFStringRef)ABGPreferencesDomain
    );

    gABGEnabled =
        ABGBoolPreference(
            @"enabled",
            YES
        );

    gABGLeftEnabled =
        ABGBoolPreference(
            @"leftEnabled",
            YES
        );

    gABGRightEnabled =
        ABGBoolPreference(
            @"rightEnabled",
            YES
        );

    gABGShowIndicator =
        ABGBoolPreference(
            @"showIndicator",
            YES
        );

    gABGHapticsEnabled =
        ABGBoolPreference(
            @"haptics",
            YES
        );

    gABGPreferNativeLeft =
        ABGBoolPreference(
            @"preferNativeLeft",
            NO
        );

    gABGEdgeWidth =
        ABGFloatPreference(
            @"edgeWidth",
            28.0
        );

    gABGTriggerDistance =
        ABGFloatPreference(
            @"triggerDistance",
            78.0
        );

    gABGMinimumVelocity =
        ABGFloatPreference(
            @"minimumVelocity",
            650.0
        );

    /*
     Tránh giá trị bất thường do preference bị lỗi.
    */

    gABGEdgeWidth =
        MAX(8.0, MIN(gABGEdgeWidth, 100.0));

    gABGTriggerDistance =
        MAX(30.0, MIN(gABGTriggerDistance, 220.0));

    gABGMinimumVelocity =
        MAX(100.0, MIN(gABGMinimumVelocity, 2500.0));

    id blacklist =
        ABGCopyPreference(@"blacklist");

    gABGBlacklist =
        ABGParseBlacklist(blacklist);
}

#pragma mark - Process checking

static BOOL ABGProcessAllowed(void)
{
    NSString *bundleID =
        NSBundle.mainBundle.bundleIdentifier;

    if (!bundleID) {
        return NO;
    }

    /*
     Không chạy gesture trong SpringBoard.
    */

    if ([bundleID isEqualToString:@"com.apple.springboard"]) {
        return NO;
    }

    if (gABGBlacklist &&
        [gABGBlacklist containsObject:bundleID]) {

        return NO;
    }

    return YES;
}

#pragma mark - Window helpers

static BOOL ABGWindowAllowed(UIWindow *window)
{
    if (!window) {
        return NO;
    }

    if (window.windowLevel != UIWindowLevelNormal) {
        return NO;
    }

    NSString *className =
        NSStringFromClass(window.class);

    NSArray<NSString *> *ignored = @[
        @"Keyboard",
        @"TextEffects",
        @"RemoteKeyboard",
        @"InputWindow",
        @"UITextEffects"
    ];

    for (NSString *keyword in ignored) {

        if ([className
                rangeOfString:keyword
                options:NSCaseInsensitiveSearch].location
            != NSNotFound) {

            return NO;
        }
    }

    return YES;
}

#pragma mark - ViewController helpers

static UIViewController *
ABGVisibleViewController(UIViewController *vc)
{
    if (!vc) {
        return nil;
    }

    UIViewController *presented =
        vc.presentedViewController;

    if (presented &&
        !presented.isBeingDismissed) {

        return ABGVisibleViewController(presented);
    }

    if ([vc isKindOfClass:
            [UINavigationController class]]) {

        UINavigationController *nav =
            (UINavigationController *)vc;

        UIViewController *visible =
            nav.visibleViewController;

        return ABGVisibleViewController(
            visible ?: nav
        );
    }

    if ([vc isKindOfClass:
            [UITabBarController class]]) {

        UITabBarController *tabs =
            (UITabBarController *)vc;

        UIViewController *selected =
            tabs.selectedViewController;

        return ABGVisibleViewController(
            selected ?: tabs
        );
    }

    if ([vc isKindOfClass:
            [UISplitViewController class]]) {

        UISplitViewController *split =
            (UISplitViewController *)vc;

        UIViewController *last =
            split.viewControllers.lastObject;

        if (last) {
            return ABGVisibleViewController(last);
        }
    }

    return vc;
}

static UIViewController *
ABGTopViewControllerForWindow(UIWindow *window)
{
    if (!window) {
        return nil;
    }

    return ABGVisibleViewController(
        window.rootViewController
    );
}

#pragma mark - Find first responder

static __weak UIResponder *gABGFirstResponder = nil;

@interface UIResponder (ABGFirstResponder)

- (void)abg_captureFirstResponder:(id)sender;

@end

@implementation UIResponder (ABGFirstResponder)

- (void)abg_captureFirstResponder:(id)sender
{
    gABGFirstResponder = self;
}

@end

static UIResponder *ABGFindFirstResponder(void)
{
    gABGFirstResponder = nil;

    [UIApplication.sharedApplication
        sendAction:@selector(abg_captureFirstResponder:)
        to:nil
        from:nil
        forEvent:nil];

    return gABGFirstResponder;
}

static BOOL ABGKeyboardIsOpen(void)
{
    UIResponder *responder =
        ABGFindFirstResponder();

    if (!responder) {
        return NO;
    }

    if ([responder conformsToProtocol:
            @protocol(UITextInput)]) {

        return YES;
    }

    return NO;
}

static BOOL ABGHideKeyboard(void)
{
    UIResponder *responder =
        ABGFindFirstResponder();

    if (!responder) {
        return NO;
    }

    if (![responder conformsToProtocol:
            @protocol(UITextInput)]) {

        return NO;
    }

    return [responder resignFirstResponder];
}

#pragma mark - WKWebView

static WKWebView *
ABGFindWebViewInView(UIView *view)
{
    if (!view) {
        return nil;
    }

    if (view.hidden ||
        view.alpha <= 0.01) {

        return nil;
    }

    if ([view isKindOfClass:
            [WKWebView class]]) {

        return (WKWebView *)view;
    }

    for (UIView *subview in view.subviews) {

        WKWebView *result =
            ABGFindWebViewInView(subview);

        if (result) {
            return result;
        }
    }

    return nil;
}

static WKWebView *
ABGFindCurrentWebView(UIWindow *window)
{
    UIViewController *vc =
        ABGTopViewControllerForWindow(window);

    if (!vc) {
        return nil;
    }

    if (!vc.isViewLoaded) {
        return nil;
    }

    return ABGFindWebViewInView(vc.view);
}

#pragma mark - Back implementation

static BOOL ABGGoBackInWebView(UIWindow *window)
{
    WKWebView *webView =
        ABGFindCurrentWebView(window);

    if (!webView) {
        return NO;
    }

    if (!webView.canGoBack) {
        return NO;
    }

    [webView goBack];

    return YES;
}

static BOOL ABGPopNavigation(UIWindow *window)
{
    UIViewController *vc =
        ABGTopViewControllerForWindow(window);

    if (!vc) {
        return NO;
    }

    UINavigationController *nav =
        vc.navigationController;

    if (!nav &&
        [vc isKindOfClass:
            [UINavigationController class]]) {

        nav =
            (UINavigationController *)vc;
    }

    if (!nav) {
        return NO;
    }

    if (nav.viewControllers.count <= 1) {
        return NO;
    }

    /*
     Tránh pop khi navigation đang transition.
    */

    id<UIViewControllerTransitionCoordinator>
        coordinator =
        nav.transitionCoordinator;

    if (coordinator &&
        coordinator.isAnimated) {

        return NO;
    }

    [nav popViewControllerAnimated:YES];

    return YES;
}

static BOOL ABGDismissModal(UIWindow *window)
{
    UIViewController *vc =
        ABGTopViewControllerForWindow(window);

    if (!vc) {
        return NO;
    }

    UIViewController *candidate = vc;

    /*
     Nếu navigation controller cả cụm được present
     dạng modal thì dismiss navigation controller.
    */

    if (vc.navigationController &&
        vc.navigationController.presentingViewController) {

        candidate =
            vc.navigationController;
    }

    if (!candidate.presentingViewController) {
        return NO;
    }

    if (candidate.isBeingDismissed) {
        return NO;
    }

    [candidate
        dismissViewControllerAnimated:YES
        completion:nil];

    return YES;
}

static BOOL ABGPerformAccessibilityEscape(
    UIWindow *window
)
{
    UIViewController *vc =
        ABGTopViewControllerForWindow(window);

    if (!vc) {
        return NO;
    }

    return [vc accessibilityPerformEscape];
}

static BOOL ABGPerformBack(UIWindow *window)
{
    /*
     Thứ tự gần hành vi Android:

     1. Keyboard
     2. Web history
     3. Navigation stack
     4. Modal
     5. Accessibility escape fallback
    */

    if (ABGKeyboardIsOpen()) {

        if (ABGHideKeyboard()) {
            return YES;
        }
    }

    if (ABGGoBackInWebView(window)) {
        return YES;
    }

    if (ABGPopNavigation(window)) {
        return YES;
    }

    if (ABGDismissModal(window)) {
        return YES;
    }

    if (ABGPerformAccessibilityEscape(window)) {
        return YES;
    }

    return NO;
}

#pragma mark - Android-style indicator

@interface ABGBackIndicatorView : UIView

@property (nonatomic, strong)
    CAShapeLayer *arrowLayer;

@property (nonatomic, assign)
    ABGEdgeSide edgeSide;

- (instancetype)initWithEdgeSide:
    (ABGEdgeSide)side;

- (void)setProgress:
    (CGFloat)progress;

@end

@implementation ABGBackIndicatorView

- (instancetype)initWithEdgeSide:
    (ABGEdgeSide)side
{
    self =
        [super initWithFrame:
            CGRectMake(0, 0, 52, 52)];

    if (self) {

        _edgeSide = side;

        self.userInteractionEnabled = NO;

        self.backgroundColor =
            [UIColor.systemBlueColor
                colorWithAlphaComponent:0.92];

        self.layer.cornerRadius = 26.0;

        self.layer.shadowColor =
            UIColor.blackColor.CGColor;

        self.layer.shadowOpacity = 0.22;
        self.layer.shadowRadius = 7.0;

        self.layer.shadowOffset =
            CGSizeMake(0, 2);

        _arrowLayer =
            [CAShapeLayer layer];

        _arrowLayer.strokeColor =
            UIColor.whiteColor.CGColor;

        _arrowLayer.fillColor = nil;

        _arrowLayer.lineWidth = 3.2;

        _arrowLayer.lineCap =
            kCALineCapRound;

        _arrowLayer.lineJoin =
            kCALineJoinRound;

        [self.layer
            addSublayer:_arrowLayer];

        [self rebuildArrow];
    }

    return self;
}

- (void)rebuildArrow
{
    UIBezierPath *path =
        [UIBezierPath bezierPath];

    /*
     Mũi tên hướng vào giữa màn hình.

     Vuốt từ trái:
         >

     Vuốt từ phải:
         <
    */

    if (self.edgeSide ==
        ABGEdgeSideLeft) {

        [path moveToPoint:
            CGPointMake(20, 16)];

        [path addLineToPoint:
            CGPointMake(31, 26)];

        [path addLineToPoint:
            CGPointMake(20, 36)];

        [path moveToPoint:
            CGPointMake(30, 26)];

        [path addLineToPoint:
            CGPointMake(15, 26)];

    } else {

        [path moveToPoint:
            CGPointMake(32, 16)];

        [path addLineToPoint:
            CGPointMake(21, 26)];

        [path addLineToPoint:
            CGPointMake(32, 36)];

        [path moveToPoint:
            CGPointMake(22, 26)];

        [path addLineToPoint:
            CGPointMake(37, 26)];
    }

    self.arrowLayer.path =
        path.CGPath;
}

- (void)setProgress:(CGFloat)progress
{
    CGFloat normalized =
        MAX(0.0, MIN(progress, 1.25));

    CGFloat scale =
        0.72 +
        (MIN(normalized, 1.0) * 0.28);

    if (normalized >= 1.0) {
        scale = 1.08;
    }

    self.transform =
        CGAffineTransformMakeScale(
            scale,
            scale
        );

    self.alpha =
        0.30 +
        MIN(normalized, 1.0) * 0.70;
}

@end

#pragma mark - Native iOS pop control

static void
ABGApplyNativePopPolicy(
    UINavigationController *nav
)
{
    if (!nav) {
        return;
    }

    UIGestureRecognizer *gesture =
        nav.interactivePopGestureRecognizer;

    if (!gesture) {
        return;
    }

    BOOL useCustomLeft =
        gABGEnabled &&
        gABGLeftEnabled &&
        !gABGPreferNativeLeft &&
        ABGProcessAllowed();

    NSNumber *storedOriginal =
        objc_getAssociatedObject(
            nav,
            &kABGNativePopOriginalKey
        );

    if (useCustomLeft) {

        /*
         Lưu trạng thái ban đầu của app trước
         khi vô hiệu hóa gesture iOS.
        */

        if (!storedOriginal) {

            objc_setAssociatedObject(
                nav,
                &kABGNativePopOriginalKey,
                @(gesture.enabled),
                OBJC_ASSOCIATION_RETAIN_NONATOMIC
            );
        }

        gesture.enabled = NO;

    } else {

        /*
         Khôi phục đúng trạng thái ban đầu của app,
         không tự ý bật một gesture mà app vốn tắt.
        */

        if (storedOriginal) {

            gesture.enabled =
                [storedOriginal boolValue];

            objc_setAssociatedObject(
                nav,
                &kABGNativePopOriginalKey,
                nil,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC
            );
        }
    }
}

static void
ABGApplyNativePopPolicyRecursively(
    UIViewController *vc
)
{
    if (!vc) {
        return;
    }

    if ([vc isKindOfClass:
            [UINavigationController class]]) {

        ABGApplyNativePopPolicy(
            (UINavigationController *)vc
        );
    }

    for (UIViewController *child
         in vc.childViewControllers) {

        ABGApplyNativePopPolicyRecursively(
            child
        );
    }

    if (vc.presentedViewController) {

        ABGApplyNativePopPolicyRecursively(
            vc.presentedViewController
        );
    }
}

#pragma mark - Gesture handler

@interface ABGGestureHandler :
    NSObject
    <UIGestureRecognizerDelegate>

@property (nonatomic, strong)
    ABGBackIndicatorView *indicator;

@property (nonatomic, weak)
    UIWindow *indicatorWindow;

+ (instancetype)shared;

- (void)handlePan:
    (UIPanGestureRecognizer *)gesture;

@end

@implementation ABGGestureHandler

+ (instancetype)shared
{
    static ABGGestureHandler *handler = nil;

    static dispatch_once_t onceToken;

    dispatch_once(
        &onceToken,
        ^{

            handler =
                [[ABGGestureHandler alloc] init];

        }
    );

    return handler;
}

#pragma mark Indicator

- (void)removeIndicatorImmediately
{
    [self.indicator removeFromSuperview];

    self.indicator = nil;
    self.indicatorWindow = nil;
}

- (void)showIndicatorForWindow:
    (UIWindow *)window
    side:(ABGEdgeSide)side
    touchY:(CGFloat)touchY
{
    if (!gABGShowIndicator) {
        return;
    }

    [self removeIndicatorImmediately];

    ABGBackIndicatorView *indicator =
        [[ABGBackIndicatorView alloc]
            initWithEdgeSide:side];

    self.indicator = indicator;
    self.indicatorWindow = window;

    CGFloat height =
        CGRectGetHeight(window.bounds);

    CGFloat y =
        MAX(
            35.0,
            MIN(
                touchY,
                height - 35.0
            )
        );

    CGFloat x;

    if (side == ABGEdgeSideLeft) {

        x = -14.0;

    } else {

        x =
            CGRectGetWidth(window.bounds)
            + 14.0;
    }

    indicator.center =
        CGPointMake(x, y);

    [indicator setProgress:0.0];

    [window addSubview:indicator];
}

- (void)updateIndicatorForSide:
    (ABGEdgeSide)side
    progress:(CGFloat)progress
    touchY:(CGFloat)touchY
{
    ABGBackIndicatorView *indicator =
        self.indicator;

    UIWindow *window =
        self.indicatorWindow;

    if (!indicator ||
        !window) {

        return;
    }

    CGFloat normalized =
        MAX(
            0.0,
            MIN(progress, 1.25)
        );

    CGFloat width =
        CGRectGetWidth(window.bounds);

    CGFloat height =
        CGRectGetHeight(window.bounds);

    CGFloat y =
        MAX(
            35.0,
            MIN(
                touchY,
                height - 35.0
            )
        );

    /*
     Bubble ban đầu nằm hơi ngoài màn hình.

     Khi vuốt sâu hơn nó trượt vào trong.
    */

    CGFloat visibleProgress =
        MIN(normalized, 1.0);

    CGFloat x;

    if (side == ABGEdgeSideLeft) {

        x =
            -14.0 +
            (44.0 * visibleProgress);

    } else {

        x =
            width +
            14.0 -
            (44.0 * visibleProgress);
    }

    /*
     Y chuyển động có damping nhẹ.
    */

    CGFloat oldY =
        indicator.center.y;

    CGFloat smoothY =
        oldY +
        ((y - oldY) * 0.38);

    indicator.center =
        CGPointMake(
            x,
            smoothY
        );

    [indicator
        setProgress:normalized];
}

- (void)hideIndicatorForSide:
    (ABGEdgeSide)side
    success:(BOOL)success
{
    ABGBackIndicatorView *indicator =
        self.indicator;

    UIWindow *window =
        self.indicatorWindow;

    if (!indicator ||
        !window) {

        [self removeIndicatorImmediately];
        return;
    }

    CGFloat width =
        CGRectGetWidth(window.bounds);

    CGPoint target =
        indicator.center;

    if (success) {

        /*
         Nếu Back thành công, bubble đi thêm một chút
         vào màn hình rồi mờ đi.
        */

        if (side == ABGEdgeSideLeft) {
            target.x += 14.0;
        } else {
            target.x -= 14.0;
        }

    } else {

        /*
         Gesture bị hủy -> bubble quay về cạnh.
        */

        if (side == ABGEdgeSideLeft) {
            target.x = -30.0;
        } else {
            target.x = width + 30.0;
        }
    }

    [UIView
        animateWithDuration:0.15
        delay:0
        options:
            UIViewAnimationOptionCurveEaseOut |
            UIViewAnimationOptionBeginFromCurrentState
        animations:^{

            indicator.center = target;
            indicator.alpha = 0.0;

            indicator.transform =
                CGAffineTransformMakeScale(
                    0.72,
                    0.72
                );

        }
        completion:^(BOOL finished) {

            [indicator removeFromSuperview];

            if (self.indicator == indicator) {

                self.indicator = nil;
                self.indicatorWindow = nil;
            }
        }];
}

#pragma mark Gesture delegate

- (BOOL)gestureRecognizerShouldBegin:
    (UIGestureRecognizer *)recognizer
{
    if (!gABGEnabled) {
        return NO;
    }

    if (!ABGProcessAllowed()) {
        return NO;
    }

    if (![recognizer
            isKindOfClass:
                [UIPanGestureRecognizer class]]) {

        return NO;
    }

    UIWindow *window =
        (UIWindow *)recognizer.view;

    if (![window isKindOfClass:
            [UIWindow class]]) {

        return NO;
    }

    if (!ABGWindowAllowed(window)) {
        return NO;
    }

    UIPanGestureRecognizer *pan =
        (UIPanGestureRecognizer *)recognizer;

    CGPoint location =
        [pan locationInView:window];

    CGPoint velocity =
        [pan velocityInView:window];

    CGPoint translation =
        [pan translationInView:window];

    CGFloat width =
        CGRectGetWidth(window.bounds);

    if (width <= 0.0) {
        return NO;
    }

    ABGEdgeSide side =
        ABGEdgeSideNone;

    if (gABGLeftEnabled &&
        location.x <= gABGEdgeWidth) {

        side = ABGEdgeSideLeft;

    } else if (
        gABGRightEnabled &&
        location.x >= width - gABGEdgeWidth) {

        side = ABGEdgeSideRight;
    }

    if (side == ABGEdgeSideNone) {
        return NO;
    }

    CGFloat directionX =
        fabs(velocity.x) > 1.0
        ? velocity.x
        : translation.x;

    /*
     Phải vuốt vào giữa màn hình.
    */

    if (side == ABGEdgeSideLeft &&
        directionX <= 0.0) {

        return NO;
    }

    if (side == ABGEdgeSideRight &&
        directionX >= 0.0) {

        return NO;
    }

    /*
     Loại thao tác vuốt chủ yếu theo chiều dọc.
    */

    if (fabs(velocity.y) >
        fabs(velocity.x) * 1.15) {

        return NO;
    }

    /*
     Nếu người dùng chọn giữ Back gốc iOS,
     nhường cho interactivePopGestureRecognizer
     khi navigation stack thực sự có thể pop.
    */

    if (side == ABGEdgeSideLeft &&
        gABGPreferNativeLeft) {

        UIViewController *top =
            ABGTopViewControllerForWindow(
                window
            );

        UINavigationController *nav =
            top.navigationController;

        if (!nav &&
            [top isKindOfClass:
                [UINavigationController class]]) {

            nav =
                (UINavigationController *)top;
        }

        if (nav &&
            nav.viewControllers.count > 1 &&
            nav.interactivePopGestureRecognizer &&
            nav.interactivePopGestureRecognizer.enabled) {

            return NO;
        }
    }

    objc_setAssociatedObject(
        pan,
        &kABGSideKey,
        @(side),
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );

    objc_setAssociatedObject(
        pan,
        &kABGThresholdKey,
        @NO,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );

    return YES;
}

- (BOOL)gestureRecognizer:
    (UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:
    (UIGestureRecognizer *)otherGestureRecognizer
{
    /*
     Không khóa scroll view / table view của app.

     Vì gesture của chúng ta chỉ được bắt đầu ở
     vùng mép màn hình.
    */

    return YES;
}

#pragma mark Gesture processing

- (void)handlePan:
    (UIPanGestureRecognizer *)gesture
{
    UIWindow *window =
        (UIWindow *)gesture.view;

    if (![window isKindOfClass:
            [UIWindow class]]) {

        return;
    }

    NSNumber *sideNumber =
        objc_getAssociatedObject(
            gesture,
            &kABGSideKey
        );

    ABGEdgeSide side =
        (ABGEdgeSide)[sideNumber integerValue];

    if (side == ABGEdgeSideNone) {
        return;
    }

    CGPoint translation =
        [gesture translationInView:window];

    CGPoint velocity =
        [gesture velocityInView:window];

    CGPoint location =
        [gesture locationInView:window];

    CGFloat distance = 0.0;

    if (side == ABGEdgeSideLeft) {

        distance =
            MAX(0.0, translation.x);

    } else {

        distance =
            MAX(0.0, -translation.x);
    }

    CGFloat progress =
        distance /
        MAX(gABGTriggerDistance, 1.0);

    switch (gesture.state) {

        case UIGestureRecognizerStateBegan:
        {
            objc_setAssociatedObject(
                gesture,
                &kABGThresholdKey,
                @NO,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC
            );

            [self
                showIndicatorForWindow:window
                side:side
                touchY:location.y];

            break;
        }

        case UIGestureRecognizerStateChanged:
        {
            [self
                updateIndicatorForSide:side
                progress:progress
                touchY:location.y];

            BOOL currentlyTriggered =
                distance >=
                gABGTriggerDistance;

            NSNumber *previous =
                objc_getAssociatedObject(
                    gesture,
                    &kABGThresholdKey
                );

            BOOL alreadyFired =
                [previous boolValue];

            /*
             Rung đúng một lần khi vượt ngưỡng.
            */

            if (currentlyTriggered &&
                !alreadyFired) {

                objc_setAssociatedObject(
                    gesture,
                    &kABGThresholdKey,
                    @YES,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC
                );

                if (gABGHapticsEnabled) {

                    UIImpactFeedbackGenerator *generator =
                        [[UIImpactFeedbackGenerator alloc]
                            initWithStyle:
                                UIImpactFeedbackStyleLight];

                    [generator prepare];
                    [generator impactOccurred];
                }
            }

            break;
        }

        case UIGestureRecognizerStateEnded:
        {
            CGFloat horizontalVelocity =
                fabs(velocity.x);

            /*
             Bình thường:
             kéo đủ triggerDistance.

             Flick:
             kéo ít nhất 20pt nhưng tốc độ rất cao.
            */

            BOOL distanceTriggered =
                distance >=
                gABGTriggerDistance;

            BOOL velocityTriggered =
                distance >= 20.0 &&
                horizontalVelocity >=
                    gABGMinimumVelocity;

            BOOL directionValid;

            if (side == ABGEdgeSideLeft) {

                directionValid =
                    velocity.x >= -20.0;

            } else {

                directionValid =
                    velocity.x <= 20.0;
            }

            BOOL shouldBack =
                directionValid &&
                (
                    distanceTriggered ||
                    velocityTriggered
                );

            BOOL actionPerformed = NO;

            if (shouldBack) {

                actionPerformed =
                    ABGPerformBack(window);
            }

            [self
                hideIndicatorForSide:side
                success:
                    (shouldBack &&
                     actionPerformed)];

            objc_setAssociatedObject(
                gesture,
                &kABGSideKey,
                nil,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC
            );

            objc_setAssociatedObject(
                gesture,
                &kABGThresholdKey,
                nil,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC
            );

            break;
        }

        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
        {
            [self
                hideIndicatorForSide:side
                success:NO];

            objc_setAssociatedObject(
                gesture,
                &kABGSideKey,
                nil,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC
            );

            objc_setAssociatedObject(
                gesture,
                &kABGThresholdKey,
                nil,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC
            );

            break;
        }

        default:
            break;
    }
}

@end

#pragma mark - Gesture installation

static void ABGInstallOrUpdateGesture(
    UIWindow *window
)
{
    if (!window) {
        return;
    }

    UIPanGestureRecognizer *gesture =
        objc_getAssociatedObject(
            window,
            &kABGPanGestureKey
        );

    BOOL shouldEnable =
        gABGEnabled &&
        ABGProcessAllowed() &&
        ABGWindowAllowed(window);

    if (!gesture) {

        if (!shouldEnable) {
            return;
        }

        gesture =
            [[UIPanGestureRecognizer alloc]
                initWithTarget:
                    [ABGGestureHandler shared]
                action:
                    @selector(handlePan:)];

        gesture.minimumNumberOfTouches = 1;
        gesture.maximumNumberOfTouches = 1;

        gesture.cancelsTouchesInView = NO;
        gesture.delaysTouchesBegan = NO;
        gesture.delaysTouchesEnded = NO;

        gesture.delegate =
            [ABGGestureHandler shared];

        [window
            addGestureRecognizer:gesture];

        objc_setAssociatedObject(
            window,
            &kABGPanGestureKey,
            gesture,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
    }

    gesture.enabled =
        shouldEnable;
}

#pragma mark - Refresh all windows

static void ABGRefreshAllWindows(void)
{
    UIApplication *application =
        UIApplication.sharedApplication;

    if (@available(iOS 13.0, *)) {

        for (UIScene *scene
             in application.connectedScenes) {

            if (![scene
                    isKindOfClass:
                        [UIWindowScene class]]) {

                continue;
            }

            UIWindowScene *windowScene =
                (UIWindowScene *)scene;

            for (UIWindow *window
                 in windowScene.windows) {

                ABGInstallOrUpdateGesture(
                    window
                );

                ABGApplyNativePopPolicyRecursively(
                    window.rootViewController
                );
            }
        }

    } else {

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

        for (UIWindow *window
             in application.windows) {

            ABGInstallOrUpdateGesture(
                window
            );

            ABGApplyNativePopPolicyRecursively(
                window.rootViewController
            );
        }

#pragma clang diagnostic pop
    }
}

#pragma mark - Preference notification

static void ABGPreferencesChanged(
    CFNotificationCenterRef center,
    void *observer,
    CFStringRef name,
    const void *object,
    CFDictionaryRef userInfo
)
{
    dispatch_async(
        dispatch_get_main_queue(),
        ^{

            ABGLoadPreferences();

            ABGRefreshAllWindows();

        }
    );
}

#pragma mark - UIWindow hooks

%hook UIWindow

- (void)makeKeyAndVisible
{
    %orig;

    dispatch_async(
        dispatch_get_main_queue(),
        ^{

            ABGInstallOrUpdateGesture(
                self
            );

            ABGApplyNativePopPolicyRecursively(
                self.rootViewController
            );

        }
    );
}

- (void)setRootViewController:
    (UIViewController *)controller
{
    %orig(controller);

    dispatch_async(
        dispatch_get_main_queue(),
        ^{

            ABGInstallOrUpdateGesture(
                self
            );

            ABGApplyNativePopPolicyRecursively(
                controller
            );

        }
    );
}

- (void)setHidden:(BOOL)hidden
{
    %orig(hidden);

    if (!hidden) {

        dispatch_async(
            dispatch_get_main_queue(),
            ^{

                ABGInstallOrUpdateGesture(
                    self
                );

            }
        );
    }
}

%end

#pragma mark - UINavigationController hooks

%hook UINavigationController

- (void)viewDidAppear:(BOOL)animated
{
    %orig(animated);

    ABGApplyNativePopPolicy(self);
}

- (void)setViewControllers:
    (NSArray<UIViewController *> *)viewControllers
    animated:(BOOL)animated
{
    %orig(viewControllers, animated);

    dispatch_async(
        dispatch_get_main_queue(),
        ^{

            ABGApplyNativePopPolicy(
                self
            );

        }
    );
}

- (void)pushViewController:
    (UIViewController *)viewController
    animated:(BOOL)animated
{
    %orig(viewController, animated);

    dispatch_async(
        dispatch_get_main_queue(),
        ^{

            ABGApplyNativePopPolicy(
                self
            );

        }
    );
}

%end

#pragma mark - Constructor

%ctor
{
    @autoreleasepool {

        ABGLoadPreferences();

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            ABGPreferencesChanged,
            ABGReloadNotification,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );

        dispatch_async(
            dispatch_get_main_queue(),
            ^{

                ABGRefreshAllWindows();

            }
        );
    }
}
