#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <QuartzCore/QuartzCore.h>
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

#pragma mark - Associated keys

static char kABGPanGestureKey;
static char kABGSideKey;
static char kABGThresholdKey;

#pragma mark - Preferences

static BOOL gABGEnabled = YES;

static BOOL gABGLeftEnabled = YES;
static BOOL gABGRightEnabled = YES;

static BOOL gABGShowIndicator = YES;
static BOOL gABGHapticsEnabled = YES;

static BOOL gABGPreferNativeLeft = YES;

static CGFloat gABGEdgeWidth = 28.0;
static CGFloat gABGTriggerDistance = 72.0;
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
    BOOL fallback
)
{
    id value = ABGCopyPreference(key);

    if ([value isKindOfClass:[NSNumber class]]) {
        return [value boolValue];
    }

    return fallback;
}

static CGFloat ABGFloatPreference(
    NSString *key,
    CGFloat fallback
)
{
    id value = ABGCopyPreference(key);

    if ([value respondsToSelector:@selector(doubleValue)]) {
        return (CGFloat)[value doubleValue];
    }

    return fallback;
}

static NSSet<NSString *> *
ABGParseBlacklist(id value)
{
    if (![value isKindOfClass:[NSString class]]) {
        return [NSSet set];
    }

    NSCharacterSet *separator =
        [NSCharacterSet characterSetWithCharactersInString:
            @",;\n\r\t "];

    NSArray<NSString *> *parts =
        [(NSString *)value
            componentsSeparatedByCharactersInSet:separator];

    NSMutableSet<NSString *> *result =
        [NSMutableSet set];

    for (NSString *part in parts) {

        NSString *clean =
            [part stringByTrimmingCharactersInSet:
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
        ABGBoolPreference(@"enabled", YES);

    gABGLeftEnabled =
        ABGBoolPreference(@"leftEnabled", YES);

    gABGRightEnabled =
        ABGBoolPreference(@"rightEnabled", YES);

    gABGShowIndicator =
        ABGBoolPreference(@"showIndicator", YES);

    gABGHapticsEnabled =
        ABGBoolPreference(@"haptics", YES);

    /*
     SAFE V2.2:
     mặc định nhường cạnh trái cho gesture gốc iOS
     nếu UINavigationController có hỗ trợ.

     Mép phải vẫn luôn là Android Back.
    */
    gABGPreferNativeLeft =
        ABGBoolPreference(@"preferNativeLeft", YES);

    gABGEdgeWidth =
        ABGFloatPreference(@"edgeWidth", 28.0);

    gABGTriggerDistance =
        ABGFloatPreference(@"triggerDistance", 72.0);

    gABGMinimumVelocity =
        ABGFloatPreference(@"minimumVelocity", 650.0);

    gABGEdgeWidth =
        MAX(8.0, MIN(gABGEdgeWidth, 80.0));

    gABGTriggerDistance =
        MAX(30.0, MIN(gABGTriggerDistance, 180.0));

    gABGMinimumVelocity =
        MAX(150.0, MIN(gABGMinimumVelocity, 2000.0));

    gABGBlacklist =
        ABGParseBlacklist(
            ABGCopyPreference(@"blacklist")
        );
}

#pragma mark - Process safety

static NSString *ABGBundleIdentifier(void)
{
    return NSBundle.mainBundle.bundleIdentifier;
}

static BOOL ABGIsSpringBoard(void)
{
    NSString *bundleID =
        ABGBundleIdentifier();

    return
        [bundleID
            isEqualToString:
                @"com.apple.springboard"];
}

static BOOL ABGProcessAllowed(void)
{
    NSString *bundleID =
        ABGBundleIdentifier();

    if (!bundleID) {
        return NO;
    }

    /*
     CỰC KỲ QUAN TRỌNG:
     tuyệt đối không chạy logic gesture trong SpringBoard.
    */
    if ([bundleID
            isEqualToString:
                @"com.apple.springboard"]) {

        return NO;
    }

    /*
     Tránh Preferences bundle host đặc biệt nếu không phải
     UIApplication bình thường.
    */
    if (![UIApplication class]) {
        return NO;
    }

    if (gABGBlacklist &&
        [gABGBlacklist containsObject:bundleID]) {

        return NO;
    }

    return YES;
}

#pragma mark - Window helpers

static BOOL ABGWindowAllowed(
    UIWindow *window
)
{
    if (!window) {
        return NO;
    }

    if (window.hidden) {
        return NO;
    }

    if (window.alpha <= 0.01) {
        return NO;
    }

    /*
     Không gắn vào keyboard / alert / overlay level.
    */
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
        @"UITextEffects",
        @"Alert"
    ];

    for (NSString *word in ignored) {

        if ([className
                rangeOfString:word
                options:NSCaseInsensitiveSearch]
                .location != NSNotFound) {

            return NO;
        }
    }

    return YES;
}

#pragma mark - UIViewController helpers

static UIViewController *
ABGVisibleController(
    UIViewController *controller
)
{
    if (!controller) {
        return nil;
    }

    UIViewController *presented =
        controller.presentedViewController;

    if (presented &&
        !presented.isBeingDismissed) {

        return
            ABGVisibleController(presented);
    }

    if ([controller
            isKindOfClass:
                [UINavigationController class]]) {

        UINavigationController *nav =
            (UINavigationController *)controller;

        return
            ABGVisibleController(
                nav.visibleViewController ?: nav
            );
    }

    if ([controller
            isKindOfClass:
                [UITabBarController class]]) {

        UITabBarController *tab =
            (UITabBarController *)controller;

        return
            ABGVisibleController(
                tab.selectedViewController ?: tab
            );
    }

    if ([controller
            isKindOfClass:
                [UISplitViewController class]]) {

        UISplitViewController *split =
            (UISplitViewController *)controller;

        UIViewController *last =
            split.viewControllers.lastObject;

        if (last) {
            return ABGVisibleController(last);
        }
    }

    return controller;
}

static UIViewController *
ABGTopController(
    UIWindow *window
)
{
    if (!window) {
        return nil;
    }

    return
        ABGVisibleController(
            window.rootViewController
        );
}

#pragma mark - First responder / keyboard

static __weak UIResponder *gABGFirstResponder = nil;

@interface UIResponder (ABGResponder)

- (void)abg_captureResponder:(id)sender;

@end

@implementation UIResponder (ABGResponder)

- (void)abg_captureResponder:(id)sender
{
    gABGFirstResponder = self;
}

@end

static UIResponder *
ABGFindFirstResponder(void)
{
    gABGFirstResponder = nil;

    [UIApplication.sharedApplication
        sendAction:@selector(abg_captureResponder:)
        to:nil
        from:nil
        forEvent:nil];

    return gABGFirstResponder;
}

static BOOL ABGHideKeyboardIfNeeded(void)
{
    UIResponder *responder =
        ABGFindFirstResponder();

    if (!responder) {
        return NO;
    }

    if (![responder
            conformsToProtocol:
                @protocol(UITextInput)]) {

        return NO;
    }

    return
        [responder resignFirstResponder];
}

#pragma mark - WKWebView

static WKWebView *
ABGFindWebView(
    UIView *view
)
{
    if (!view) {
        return nil;
    }

    if (view.hidden ||
        view.alpha <= 0.01) {

        return nil;
    }

    if ([view
            isKindOfClass:
                [WKWebView class]]) {

        return (WKWebView *)view;
    }

    for (UIView *subview
         in view.subviews) {

        WKWebView *found =
            ABGFindWebView(subview);

        if (found) {
            return found;
        }
    }

    return nil;
}

static BOOL ABGWebBack(
    UIWindow *window
)
{
    UIViewController *controller =
        ABGTopController(window);

    if (!controller ||
        !controller.isViewLoaded) {

        return NO;
    }

    WKWebView *web =
        ABGFindWebView(
            controller.view
        );

    if (!web ||
        !web.canGoBack) {

        return NO;
    }

    [web goBack];

    return YES;
}

#pragma mark - Navigation Back

static BOOL ABGNavigationBack(
    UIWindow *window
)
{
    UIViewController *controller =
        ABGTopController(window);

    if (!controller) {
        return NO;
    }

    UINavigationController *nav =
        controller.navigationController;

    if (!nav &&
        [controller
            isKindOfClass:
                [UINavigationController class]]) {

        nav =
            (UINavigationController *)controller;
    }

    if (!nav) {
        return NO;
    }

    if (nav.viewControllers.count <= 1) {
        return NO;
    }

    /*
     Không pop giữa lúc transition đang chạy.
    */
    if (nav.transitionCoordinator &&
        nav.transitionCoordinator.isAnimated) {

        return NO;
    }

    [nav popViewControllerAnimated:YES];

    return YES;
}

#pragma mark - Modal Back

static BOOL ABGModalBack(
    UIWindow *window
)
{
    UIViewController *controller =
        ABGTopController(window);

    if (!controller) {
        return NO;
    }

    UIViewController *dismissTarget =
        controller;

    if (controller.navigationController &&
        controller.navigationController
            .presentingViewController) {

        dismissTarget =
            controller.navigationController;
    }

    if (!dismissTarget.presentingViewController) {
        return NO;
    }

    if (dismissTarget.isBeingDismissed) {
        return NO;
    }

    [dismissTarget
        dismissViewControllerAnimated:YES
        completion:nil];

    return YES;
}

#pragma mark - Perform Back

static BOOL ABGPerformBack(
    UIWindow *window
)
{
    /*
     Android-like priority.
    */

    if (ABGHideKeyboardIfNeeded()) {
        return YES;
    }

    if (ABGWebBack(window)) {
        return YES;
    }

    if (ABGNavigationBack(window)) {
        return YES;
    }

    if (ABGModalBack(window)) {
        return YES;
    }

    /*
     Fallback an toàn.
    */
    UIViewController *top =
        ABGTopController(window);

    if (top) {
        return
            [top accessibilityPerformEscape];
    }

    return NO;
}

#pragma mark - Indicator

@interface ABGBackIndicatorView : UIView

@property(nonatomic, strong)
    CAShapeLayer *arrowLayer;

@property(nonatomic, assign)
    ABGEdgeSide side;

- (instancetype)initWithSide:
    (ABGEdgeSide)side;

- (void)setGestureProgress:
    (CGFloat)progress;

@end

@implementation ABGBackIndicatorView

- (instancetype)initWithSide:
    (ABGEdgeSide)side
{
    self =
        [super initWithFrame:
            CGRectMake(0, 0, 48, 48)];

    if (self) {

        _side = side;

        self.userInteractionEnabled = NO;

        self.backgroundColor =
            [UIColor.systemBlueColor
                colorWithAlphaComponent:0.92];

        self.layer.cornerRadius = 24.0;

        self.layer.shadowOpacity = 0.18;
        self.layer.shadowRadius = 6.0;

        self.layer.shadowOffset =
            CGSizeMake(0.0, 2.0);

        self.layer.shadowColor =
            UIColor.blackColor.CGColor;

        _arrowLayer =
            [CAShapeLayer layer];

        _arrowLayer.strokeColor =
            UIColor.whiteColor.CGColor;

        _arrowLayer.fillColor = nil;

        _arrowLayer.lineWidth = 3.0;

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

    if (self.side ==
        ABGEdgeSideLeft) {

        /*
         <
        */
        [path moveToPoint:
            CGPointMake(29, 15)];

        [path addLineToPoint:
            CGPointMake(18, 24)];

        [path addLineToPoint:
            CGPointMake(29, 33)];

        [path moveToPoint:
            CGPointMake(19, 24)];

        [path addLineToPoint:
            CGPointMake(35, 24)];

    } else {

        /*
         >
        */
        [path moveToPoint:
            CGPointMake(19, 15)];

        [path addLineToPoint:
            CGPointMake(30, 24)];

        [path addLineToPoint:
            CGPointMake(19, 33)];

        [path moveToPoint:
            CGPointMake(29, 24)];

        [path addLineToPoint:
            CGPointMake(13, 24)];
    }

    self.arrowLayer.path =
        path.CGPath;
}

- (void)setGestureProgress:
    (CGFloat)progress
{
    CGFloat p =
        MAX(0.0, MIN(progress, 1.0));

    CGFloat scale =
        0.78 +
        p * 0.22;

    self.transform =
        CGAffineTransformMakeScale(
            scale,
            scale
        );

    self.alpha =
        0.35 +
        p * 0.65;
}

@end

#pragma mark - Gesture handler

@interface ABGGestureHandler :
    NSObject
    <UIGestureRecognizerDelegate>

@property(nonatomic, strong)
    ABGBackIndicatorView *indicator;

@property(nonatomic, weak)
    UIWindow *indicatorWindow;

+ (instancetype)shared;

- (void)handlePan:
    (UIPanGestureRecognizer *)pan;

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

#pragma mark - Indicator

- (void)removeIndicator
{
    [self.indicator removeFromSuperview];

    self.indicator = nil;
    self.indicatorWindow = nil;
}

- (void)showIndicator:
    (UIWindow *)window
    side:(ABGEdgeSide)side
    y:(CGFloat)y
{
    if (!gABGShowIndicator) {
        return;
    }

    [self removeIndicator];

    ABGBackIndicatorView *view =
        [[ABGBackIndicatorView alloc]
            initWithSide:side];

    self.indicator = view;
    self.indicatorWindow = window;

    CGFloat height =
        CGRectGetHeight(window.bounds);

    CGFloat safeY =
        MAX(
            30.0,
            MIN(
                y,
                height - 30.0
            )
        );

    CGFloat x;

    if (side ==
        ABGEdgeSideLeft) {

        x = -16.0;

    } else {

        x =
            CGRectGetWidth(window.bounds)
            + 16.0;
    }

    view.center =
        CGPointMake(x, safeY);

    [view setGestureProgress:0.0];

    [window addSubview:view];
}

- (void)updateIndicator:
    (ABGEdgeSide)side
    progress:(CGFloat)progress
    y:(CGFloat)y
{
    if (!self.indicator ||
        !self.indicatorWindow) {

        return;
    }

    UIWindow *window =
        self.indicatorWindow;

    CGFloat width =
        CGRectGetWidth(window.bounds);

    CGFloat height =
        CGRectGetHeight(window.bounds);

    CGFloat p =
        MAX(
            0.0,
            MIN(progress, 1.0)
        );

    CGFloat targetX;

    if (side ==
        ABGEdgeSideLeft) {

        targetX =
            -16.0 +
            (42.0 * p);

    } else {

        targetX =
            width +
            16.0 -
            (42.0 * p);
    }

    CGFloat safeY =
        MAX(
            30.0,
            MIN(
                y,
                height - 30.0
            )
        );

    CGFloat smoothY =
        self.indicator.center.y +
        (
            safeY -
            self.indicator.center.y
        ) * 0.35;

    self.indicator.center =
        CGPointMake(
            targetX,
            smoothY
        );

    [self.indicator
        setGestureProgress:p];
}

- (void)hideIndicator:
    (ABGEdgeSide)side
    success:(BOOL)success
{
    if (!self.indicator ||
        !self.indicatorWindow) {

        [self removeIndicator];
        return;
    }

    ABGBackIndicatorView *indicator =
        self.indicator;

    UIWindow *window =
        self.indicatorWindow;

    CGPoint point =
        indicator.center;

    if (success) {

        if (side ==
            ABGEdgeSideLeft) {

            point.x += 12.0;

        } else {

            point.x -= 12.0;
        }

    } else {

        if (side ==
            ABGEdgeSideLeft) {

            point.x = -30.0;

        } else {

            point.x =
                CGRectGetWidth(window.bounds)
                + 30.0;
        }
    }

    [UIView
        animateWithDuration:0.14
        delay:0
        options:
            UIViewAnimationOptionCurveEaseOut |
            UIViewAnimationOptionBeginFromCurrentState
        animations:^{

            indicator.center = point;
            indicator.alpha = 0.0;

            indicator.transform =
                CGAffineTransformMakeScale(
                    0.75,
                    0.75
                );
        }
        completion:^(BOOL finished) {

            [indicator removeFromSuperview];

            if (self.indicator ==
                indicator) {

                self.indicator = nil;
                self.indicatorWindow = nil;
            }
        }];
}

#pragma mark - Touch filtering

- (BOOL)gestureRecognizer:
    (UIGestureRecognizer *)gesture
    shouldReceiveTouch:
    (UITouch *)touch
{
    if (!gABGEnabled ||
        !ABGProcessAllowed()) {

        return NO;
    }

    if (![gesture
            isKindOfClass:
                [UIPanGestureRecognizer class]]) {

        return NO;
    }

    UIWindow *window =
        (UIWindow *)gesture.view;

    if (![window
            isKindOfClass:
                [UIWindow class]]) {

        return NO;
    }

    if (!ABGWindowAllowed(window)) {
        return NO;
    }

    CGPoint point =
        [touch locationInView:window];

    CGFloat width =
        CGRectGetWidth(window.bounds);

    ABGEdgeSide side =
        ABGEdgeSideNone;

    if (gABGLeftEnabled &&
        point.x <= gABGEdgeWidth) {

        side =
            ABGEdgeSideLeft;

    } else if (
        gABGRightEnabled &&
        point.x >=
            width - gABGEdgeWidth) {

        side =
            ABGEdgeSideRight;
    }

    if (side ==
        ABGEdgeSideNone) {

        return NO;
    }

    objc_setAssociatedObject(
        gesture,
        &kABGSideKey,
        @(side),
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );

    objc_setAssociatedObject(
        gesture,
        &kABGThresholdKey,
        @NO,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );

    return YES;
}

#pragma mark - Begin decision

- (BOOL)gestureRecognizerShouldBegin:
    (UIGestureRecognizer *)gesture
{
    if (!gABGEnabled ||
        !ABGProcessAllowed()) {

        return NO;
    }

    NSNumber *sideObject =
        objc_getAssociatedObject(
            gesture,
            &kABGSideKey
        );

    if (!sideObject) {
        return NO;
    }

    ABGEdgeSide side =
        (ABGEdgeSide)
            sideObject.integerValue;

    if (side ==
        ABGEdgeSideNone) {

        return NO;
    }

    UIWindow *window =
        (UIWindow *)gesture.view;

    if (![window
            isKindOfClass:
                [UIWindow class]]) {

        return NO;
    }

    UIPanGestureRecognizer *pan =
        (UIPanGestureRecognizer *)gesture;

    CGPoint velocity =
        [pan velocityInView:window];

    CGPoint translation =
        [pan translationInView:window];

    CGFloat x =
        fabs(velocity.x) > 4.0
        ? velocity.x
        : translation.x;

    /*
     Trái -> sang phải.
    */
    if (side ==
            ABGEdgeSideLeft &&
        x <= 0.0) {

        return NO;
    }

    /*
     Phải -> sang trái.
    */
    if (side ==
            ABGEdgeSideRight &&
        x >= 0.0) {

        return NO;
    }

    /*
     Nếu chủ yếu kéo dọc thì nhường app.
    */
    if (fabs(velocity.y) >
        fabs(velocity.x) * 1.25) {

        return NO;
    }

    /*
     SAFE:
     Không disable interactivePopGestureRecognizer.

     Nếu bật ưu tiên Back gốc iOS và màn hình hiện tại
     có navigation pop chuẩn thì nhường cạnh trái cho iOS.
    */
    if (side ==
            ABGEdgeSideLeft &&
        gABGPreferNativeLeft) {

        UIViewController *top =
            ABGTopController(window);

        UINavigationController *nav =
            top.navigationController;

        if (!nav &&
            [top
                isKindOfClass:
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

    return YES;
}

#pragma mark - No simultaneous pan

- (BOOL)gestureRecognizer:
    (UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:
    (UIGestureRecognizer *)otherGestureRecognizer
{
    /*
     Không cho scroll/web/game pan chạy đồng thời
     sau khi gesture Back đã được nhận.
    */
    return NO;
}

#pragma mark - Handle pan

- (void)handlePan:
    (UIPanGestureRecognizer *)pan
{
    UIWindow *window =
        (UIWindow *)pan.view;

    if (![window
            isKindOfClass:
                [UIWindow class]]) {

        return;
    }

    NSNumber *sideObject =
        objc_getAssociatedObject(
            pan,
            &kABGSideKey
        );

    if (!sideObject) {
        return;
    }

    ABGEdgeSide side =
        (ABGEdgeSide)
            sideObject.integerValue;

    CGPoint translation =
        [pan translationInView:window];

    CGPoint velocity =
        [pan velocityInView:window];

    CGPoint location =
        [pan locationInView:window];

    CGFloat distance;

    if (side ==
        ABGEdgeSideLeft) {

        distance =
            MAX(
                0.0,
                translation.x
            );

    } else {

        distance =
            MAX(
                0.0,
                -translation.x
            );
    }

    CGFloat progress =
        distance /
        MAX(
            1.0,
            gABGTriggerDistance
        );

    switch (pan.state) {

        case UIGestureRecognizerStateBegan:
        {
            [self
                showIndicator:window
                side:side
                y:location.y];

            break;
        }

        case UIGestureRecognizerStateChanged:
        {
            [self
                updateIndicator:side
                progress:progress
                y:location.y];

            BOOL reached =
                distance >=
                    gABGTriggerDistance;

            NSNumber *old =
                objc_getAssociatedObject(
                    pan,
                    &kABGThresholdKey
                );

            if (reached &&
                !old.boolValue) {

                objc_setAssociatedObject(
                    pan,
                    &kABGThresholdKey,
                    @YES,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC
                );

                if (gABGHapticsEnabled) {

                    UIImpactFeedbackGenerator *feedback =
                        [[UIImpactFeedbackGenerator alloc]
                            initWithStyle:
                                UIImpactFeedbackStyleLight];

                    [feedback prepare];
                    [feedback impactOccurred];
                }
            }

            break;
        }

        case UIGestureRecognizerStateEnded:
        {
            BOOL byDistance =
                distance >=
                    gABGTriggerDistance;

            BOOL byVelocity =
                distance >= 18.0 &&
                fabs(velocity.x) >=
                    gABGMinimumVelocity;

            BOOL correctDirection = YES;

            if (side ==
                    ABGEdgeSideLeft &&
                velocity.x < -120.0) {

                correctDirection = NO;
            }

            if (side ==
                    ABGEdgeSideRight &&
                velocity.x > 120.0) {

                correctDirection = NO;
            }

            BOOL shouldBack =
                correctDirection &&
                (
                    byDistance ||
                    byVelocity
                );

            BOOL performed = NO;

            if (shouldBack) {
                performed =
                    ABGPerformBack(window);
            }

            [self
                hideIndicator:side
                success:
                    shouldBack &&
                    performed];

            objc_setAssociatedObject(
                pan,
                &kABGSideKey,
                nil,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC
            );

            objc_setAssociatedObject(
                pan,
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
                hideIndicator:side
                success:NO];

            objc_setAssociatedObject(
                pan,
                &kABGSideKey,
                nil,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC
            );

            objc_setAssociatedObject(
                pan,
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

#pragma mark - Install gesture

static void ABGInstallGesture(
    UIWindow *window
)
{
    if (!window ||
        !ABGProcessAllowed()) {

        return;
    }

    if (!ABGWindowAllowed(window)) {
        return;
    }

    UIPanGestureRecognizer *pan =
        objc_getAssociatedObject(
            window,
            &kABGPanGestureKey
        );

    if (!pan) {

        pan =
            [[UIPanGestureRecognizer alloc]
                initWithTarget:
                    [ABGGestureHandler shared]
                action:
                    @selector(handlePan:)];

        pan.minimumNumberOfTouches = 1;
        pan.maximumNumberOfTouches = 1;

        /*
         Đây là phần chống "dính cảm ứng".

         Khi recognizer xác nhận edge swipe,
         UIKit sẽ cancel touch của view bên dưới.
        */
        pan.cancelsTouchesInView = YES;

        /*
         Không cho control bên dưới nhận touch quá sớm.
        */
        pan.delaysTouchesBegan = YES;
        pan.delaysTouchesEnded = YES;

        pan.delegate =
            [ABGGestureHandler shared];

        [window addGestureRecognizer:pan];

        objc_setAssociatedObject(
            window,
            &kABGPanGestureKey,
            pan,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
    }

    pan.enabled =
        gABGEnabled &&
        ABGProcessAllowed();
}

#pragma mark - Refresh windows

static void ABGRefreshWindows(void)
{
    if (!ABGProcessAllowed()) {
        return;
    }

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

                ABGInstallGesture(window);
            }
        }
    }
}

#pragma mark - Preferences notification

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

            if (!ABGProcessAllowed()) {
                return;
            }

            ABGLoadPreferences();
            ABGRefreshWindows();

        }
    );
}

#pragma mark - SAFE Hooks group

%group ABGApplicationHooks

%hook UIWindow

- (void)makeKeyAndVisible
{
    %orig;

    if (!ABGProcessAllowed()) {
        return;
    }

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            ABGInstallGesture(self);
        }
    );
}

- (void)setRootViewController:
    (UIViewController *)controller
{
    %orig(controller);

    if (!ABGProcessAllowed()) {
        return;
    }

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            ABGInstallGesture(self);
        }
    );
}

- (void)setHidden:
    (BOOL)hidden
{
    %orig(hidden);

    if (hidden ||
        !ABGProcessAllowed()) {

        return;
    }

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            ABGInstallGesture(self);
        }
    );
}

%end

%end

#pragma mark - Constructor

%ctor
{
    @autoreleasepool {

        /*
         QUAN TRỌNG NHẤT CỦA V2.2:

         Dylib có thể được Substitute/RootHide load vào SpringBoard
         vì SpringBoard cũng dùng UIApplication.

         Nhưng chúng ta KHÔNG %init hook ở đó.

         Vì vậy UIWindow của SpringBoard hoàn toàn không bị sửa.
        */

        if (ABGIsSpringBoard()) {
            return;
        }

        if (!ABGProcessAllowed()) {
            return;
        }

        ABGLoadPreferences();

        %init(ABGApplicationHooks);

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
                ABGRefreshWindows();
            }
        );
    }
}
