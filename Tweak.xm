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

static BOOL gABGPreferNativeLeft = NO;

static CGFloat gABGEdgeWidth = 28.0;
static CGFloat gABGTriggerDistance = 78.0;
static CGFloat gABGMinimumVelocity = 650.0;

static NSSet<NSString *> *gABGBlacklist = nil;

#pragma mark - Preferences helpers

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
    id value =
        ABGCopyPreference(key);

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
    id value =
        ABGCopyPreference(key);

    if ([value respondsToSelector:@selector(doubleValue)]) {
        return (CGFloat)[value doubleValue];
    }

    return defaultValue;
}

static NSSet<NSString *> *
ABGParseBlacklist(id value)
{
    if (![value isKindOfClass:[NSString class]]) {
        return [NSSet set];
    }

    NSString *string =
        (NSString *)value;

    NSCharacterSet *separatorSet =
        [NSCharacterSet
            characterSetWithCharactersInString:
                @",;\n\r\t "];

    NSArray<NSString *> *components =
        [string
            componentsSeparatedByCharactersInSet:
                separatorSet];

    NSMutableSet<NSString *> *result =
        [NSMutableSet set];

    for (NSString *item in components) {

        NSString *clean =
            [item
                stringByTrimmingCharactersInSet:
                    [NSCharacterSet
                        whitespaceAndNewlineCharacterSet]];

        if (clean.length > 0) {
            [result addObject:clean];
        }
    }

    return [result copy];
}

static void ABGLoadPreferences(void)
{
    CFPreferencesAppSynchronize(
        (__bridge CFStringRef)
            ABGPreferencesDomain
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
     Chặn giá trị lỗi / bất thường.
    */

    gABGEdgeWidth =
        MAX(
            8.0,
            MIN(
                gABGEdgeWidth,
                100.0
            )
        );

    gABGTriggerDistance =
        MAX(
            30.0,
            MIN(
                gABGTriggerDistance,
                220.0
            )
        );

    gABGMinimumVelocity =
        MAX(
            100.0,
            MIN(
                gABGMinimumVelocity,
                2500.0
            )
        );

    id blacklist =
        ABGCopyPreference(
            @"blacklist"
        );

    gABGBlacklist =
        ABGParseBlacklist(
            blacklist
        );
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
     Không chạy trong SpringBoard.
    */

    if ([bundleID
            isEqualToString:
                @"com.apple.springboard"]) {

        return NO;
    }

    /*
     Không chạy trong app blacklist.
    */

    if (gABGBlacklist &&
        [gABGBlacklist
            containsObject:bundleID]) {

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

    if (window.windowLevel !=
        UIWindowLevelNormal) {

        return NO;
    }

    NSString *className =
        NSStringFromClass(
            window.class
        );

    NSArray<NSString *> *ignored = @[
        @"Keyboard",
        @"TextEffects",
        @"RemoteKeyboard",
        @"InputWindow",
        @"UITextEffects"
    ];

    for (NSString *keyword
         in ignored) {

        if ([className
                rangeOfString:keyword
                options:
                    NSCaseInsensitiveSearch]
                .location != NSNotFound) {

            return NO;
        }
    }

    return YES;
}

#pragma mark - ViewController helpers

static UIViewController *
ABGVisibleViewController(
    UIViewController *vc
)
{
    if (!vc) {
        return nil;
    }

    UIViewController *presented =
        vc.presentedViewController;

    if (presented &&
        !presented.isBeingDismissed) {

        return
            ABGVisibleViewController(
                presented
            );
    }

    if ([vc
            isKindOfClass:
                [UINavigationController class]]) {

        UINavigationController *nav =
            (UINavigationController *)vc;

        UIViewController *visible =
            nav.visibleViewController;

        return
            ABGVisibleViewController(
                visible ?: nav
            );
    }

    if ([vc
            isKindOfClass:
                [UITabBarController class]]) {

        UITabBarController *tabs =
            (UITabBarController *)vc;

        UIViewController *selected =
            tabs.selectedViewController;

        return
            ABGVisibleViewController(
                selected ?: tabs
            );
    }

    if ([vc
            isKindOfClass:
                [UISplitViewController class]]) {

        UISplitViewController *split =
            (UISplitViewController *)vc;

        UIViewController *last =
            split.viewControllers.lastObject;

        if (last) {

            return
                ABGVisibleViewController(
                    last
                );
        }
    }

    return vc;
}

static UIViewController *
ABGTopViewControllerForWindow(
    UIWindow *window
)
{
    if (!window) {
        return nil;
    }

    return
        ABGVisibleViewController(
            window.rootViewController
        );
}

#pragma mark - First responder

static __weak UIResponder *
gABGFirstResponder = nil;

@interface UIResponder
(AndroidBackGestureFirstResponder)

- (void)abg_captureFirstResponder:
    (id)sender;

@end

@implementation UIResponder
(AndroidBackGestureFirstResponder)

- (void)abg_captureFirstResponder:
    (id)sender
{
    gABGFirstResponder = self;
}

@end

static UIResponder *
ABGFindFirstResponder(void)
{
    gABGFirstResponder = nil;

    [UIApplication.sharedApplication
        sendAction:
            @selector(
                abg_captureFirstResponder:
            )
        to:nil
        from:nil
        forEvent:nil];

    return
        gABGFirstResponder;
}

static BOOL ABGKeyboardIsOpen(void)
{
    UIResponder *responder =
        ABGFindFirstResponder();

    if (!responder) {
        return NO;
    }

    if ([responder
            conformsToProtocol:
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

    if (![responder
            conformsToProtocol:
                @protocol(UITextInput)]) {

        return NO;
    }

    return
        [responder
            resignFirstResponder];
}

#pragma mark - WKWebView

static WKWebView *
ABGFindWebViewInView(
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

        return
            (WKWebView *)view;
    }

    for (UIView *subview
         in view.subviews) {

        WKWebView *result =
            ABGFindWebViewInView(
                subview
            );

        if (result) {
            return result;
        }
    }

    return nil;
}

static WKWebView *
ABGFindCurrentWebView(
    UIWindow *window
)
{
    UIViewController *vc =
        ABGTopViewControllerForWindow(
            window
        );

    if (!vc) {
        return nil;
    }

    if (!vc.isViewLoaded) {
        return nil;
    }

    return
        ABGFindWebViewInView(
            vc.view
        );
}

#pragma mark - Back actions

static BOOL ABGGoBackInWebView(
    UIWindow *window
)
{
    WKWebView *webView =
        ABGFindCurrentWebView(
            window
        );

    if (!webView) {
        return NO;
    }

    if (!webView.canGoBack) {
        return NO;
    }

    [webView goBack];

    return YES;
}

static BOOL ABGPopNavigation(
    UIWindow *window
)
{
    UIViewController *vc =
        ABGTopViewControllerForWindow(
            window
        );

    if (!vc) {
        return NO;
    }

    UINavigationController *nav =
        vc.navigationController;

    if (!nav &&
        [vc
            isKindOfClass:
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

    id<UIViewControllerTransitionCoordinator>
        coordinator =
            nav.transitionCoordinator;

    if (coordinator &&
        coordinator.isAnimated) {

        return NO;
    }

    [nav
        popViewControllerAnimated:YES];

    return YES;
}

static BOOL ABGDismissModal(
    UIWindow *window
)
{
    UIViewController *vc =
        ABGTopViewControllerForWindow(
            window
        );

    if (!vc) {
        return NO;
    }

    UIViewController *candidate =
        vc;

    if (vc.navigationController &&
        vc.navigationController
            .presentingViewController) {

        candidate =
            vc.navigationController;
    }

    if (!candidate
            .presentingViewController) {

        return NO;
    }

    if (candidate
            .isBeingDismissed) {

        return NO;
    }

    [candidate
        dismissViewControllerAnimated:YES
        completion:nil];

    return YES;
}

static BOOL
ABGPerformAccessibilityEscape(
    UIWindow *window
)
{
    UIViewController *vc =
        ABGTopViewControllerForWindow(
            window
        );

    if (!vc) {
        return NO;
    }

    return
        [vc
            accessibilityPerformEscape];
}

static BOOL ABGPerformBack(
    UIWindow *window
)
{
    /*
     Thứ tự:

     1. Đóng keyboard
     2. WKWebView goBack
     3. UINavigationController pop
     4. Modal dismiss
     5. Accessibility escape
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

    if (ABGPerformAccessibilityEscape(
            window)) {

        return YES;
    }

    return NO;
}

#pragma mark - High priority edge recognizer

/*
 Quan trọng:

 Recognizer này được ưu tiên hơn pan/scroll
 của nội dung bên trong app.

 Khi nó nhận ra edge-back:
 - scroll view bị hủy
 - collection view bị hủy
 - web view không kéo theo
 - game/app không tiếp tục nhận swipe
*/

@interface ABGEdgePanGestureRecognizer :
    UIPanGestureRecognizer
@end

@implementation ABGEdgePanGestureRecognizer

- (BOOL)canPreventGestureRecognizer:
    (UIGestureRecognizer *)
        preventedGestureRecognizer
{
    /*
     Edge Back được phép chặn recognizer khác.
    */

    return YES;
}

- (BOOL)canBePreventedByGestureRecognizer:
    (UIGestureRecognizer *)
        preventingGestureRecognizer
{
    /*
     Không cho scroll/pan bên trong chặn Edge Back.
    */

    return NO;
}

@end

#pragma mark - Back indicator

@interface ABGBackIndicatorView :
    UIView

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
        [super
            initWithFrame:
                CGRectMake(
                    0,
                    0,
                    52,
                    52
                )];

    if (self) {

        _edgeSide = side;

        self.userInteractionEnabled =
            NO;

        self.backgroundColor =
            [UIColor.systemBlueColor
                colorWithAlphaComponent:
                    0.92];

        self.layer.cornerRadius =
            26.0;

        self.layer.shadowColor =
            UIColor.blackColor.CGColor;

        self.layer.shadowOpacity =
            0.22;

        self.layer.shadowRadius =
            7.0;

        self.layer.shadowOffset =
            CGSizeMake(
                0,
                2
            );

        _arrowLayer =
            [CAShapeLayer layer];

        _arrowLayer.strokeColor =
            UIColor.whiteColor.CGColor;

        _arrowLayer.fillColor =
            nil;

        _arrowLayer.lineWidth =
            3.2;

        _arrowLayer.lineCap =
            kCALineCapRound;

        _arrowLayer.lineJoin =
            kCALineJoinRound;

        [self.layer
            addSublayer:
                _arrowLayer];

        [self rebuildArrow];
    }

    return self;
}

- (void)rebuildArrow
{
    UIBezierPath *path =
        [UIBezierPath bezierPath];

    /*
     Mép trái -> mũi tên <
     Mép phải -> mũi tên >
    */

    if (self.edgeSide ==
        ABGEdgeSideLeft) {

        [path
            moveToPoint:
                CGPointMake(
                    31,
                    16
                )];

        [path
            addLineToPoint:
                CGPointMake(
                    20,
                    26
                )];

        [path
            addLineToPoint:
                CGPointMake(
                    31,
                    36
                )];

        [path
            moveToPoint:
                CGPointMake(
                    21,
                    26
                )];

        [path
            addLineToPoint:
                CGPointMake(
                    37,
                    26
                )];

    } else {

        [path
            moveToPoint:
                CGPointMake(
                    21,
                    16
                )];

        [path
            addLineToPoint:
                CGPointMake(
                    32,
                    26
                )];

        [path
            addLineToPoint:
                CGPointMake(
                    21,
                    36
                )];

        [path
            moveToPoint:
                CGPointMake(
                    31,
                    26
                )];

        [path
            addLineToPoint:
                CGPointMake(
                    15,
                    26
                )];
    }

    self.arrowLayer.path =
        path.CGPath;
}

- (void)setProgress:
    (CGFloat)progress
{
    CGFloat normalized =
        MAX(
            0.0,
            MIN(
                progress,
                1.25
            )
        );

    CGFloat scale =
        0.72 +
        (
            MIN(
                normalized,
                1.0
            ) *
            0.28
        );

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
        (
            MIN(
                normalized,
                1.0
            ) *
            0.70
        );
}

@end

#pragma mark - Native iOS pop policy

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

        if (storedOriginal) {

            gesture.enabled =
                [storedOriginal
                    boolValue];

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

    if ([vc
            isKindOfClass:
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
    static ABGGestureHandler *handler =
        nil;

    static dispatch_once_t onceToken;

    dispatch_once(
        &onceToken,
        ^{

            handler =
                [[ABGGestureHandler alloc]
                    init];

        }
    );

    return handler;
}

#pragma mark Indicator

- (void)removeIndicatorImmediately
{
    [self.indicator
        removeFromSuperview];

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

    [self
        removeIndicatorImmediately];

    ABGBackIndicatorView *indicator =
        [[ABGBackIndicatorView alloc]
            initWithEdgeSide:
                side];

    self.indicator =
        indicator;

    self.indicatorWindow =
        window;

    CGFloat height =
        CGRectGetHeight(
            window.bounds
        );

    CGFloat y =
        MAX(
            35.0,
            MIN(
                touchY,
                height - 35.0
            )
        );

    CGFloat x;

    if (side ==
        ABGEdgeSideLeft) {

        x = -14.0;

    } else {

        x =
            CGRectGetWidth(
                window.bounds
            ) +
            14.0;
    }

    indicator.center =
        CGPointMake(
            x,
            y
        );

    [indicator
        setProgress:
            0.0];

    [window
        addSubview:
            indicator];
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
            MIN(
                progress,
                1.25
            )
        );

    CGFloat width =
        CGRectGetWidth(
            window.bounds
        );

    CGFloat height =
        CGRectGetHeight(
            window.bounds
        );

    CGFloat y =
        MAX(
            35.0,
            MIN(
                touchY,
                height - 35.0
            )
        );

    CGFloat visibleProgress =
        MIN(
            normalized,
            1.0
        );

    CGFloat x;

    if (side ==
        ABGEdgeSideLeft) {

        x =
            -14.0 +
            (
                44.0 *
                visibleProgress
            );

    } else {

        x =
            width +
            14.0 -
            (
                44.0 *
                visibleProgress
            );
    }

    CGFloat oldY =
        indicator.center.y;

    CGFloat smoothY =
        oldY +
        (
            (y - oldY) *
            0.38
        );

    indicator.center =
        CGPointMake(
            x,
            smoothY
        );

    [indicator
        setProgress:
            normalized];
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

        [self
            removeIndicatorImmediately];

        return;
    }

    CGFloat width =
        CGRectGetWidth(
            window.bounds
        );

    CGPoint target =
        indicator.center;

    if (success) {

        if (side ==
            ABGEdgeSideLeft) {

            target.x += 14.0;

        } else {

            target.x -= 14.0;
        }

    } else {

        if (side ==
            ABGEdgeSideLeft) {

            target.x =
                -30.0;

        } else {

            target.x =
                width +
                30.0;
        }
    }

    [UIView
        animateWithDuration:
            0.15
        delay:
            0
        options:
            UIViewAnimationOptionCurveEaseOut |
            UIViewAnimationOptionBeginFromCurrentState
        animations:^{

            indicator.center =
                target;

            indicator.alpha =
                0.0;

            indicator.transform =
                CGAffineTransformMakeScale(
                    0.72,
                    0.72
                );

        }
        completion:
            ^(BOOL finished) {

                [indicator
                    removeFromSuperview];

                if (self.indicator ==
                    indicator) {

                    self.indicator =
                        nil;

                    self.indicatorWindow =
                        nil;
                }
            }];
}

#pragma mark Touch down filtering

- (BOOL)gestureRecognizer:
    (UIGestureRecognizer *)
        gestureRecognizer
    shouldReceiveTouch:
    (UITouch *)touch
{
    if (!gABGEnabled) {
        return NO;
    }

    if (!ABGProcessAllowed()) {
        return NO;
    }

    if (![gestureRecognizer
            isKindOfClass:
                [UIPanGestureRecognizer class]]) {

        return NO;
    }

    UIView *gestureView =
        gestureRecognizer.view;

    if (![gestureView
            isKindOfClass:
                [UIWindow class]]) {

        return NO;
    }

    UIWindow *window =
        (UIWindow *)gestureView;

    if (!ABGWindowAllowed(
            window)) {

        return NO;
    }

    CGPoint startPoint =
        [touch
            locationInView:
                window];

    CGFloat width =
        CGRectGetWidth(
            window.bounds
        );

    if (width <= 0.0) {
        return NO;
    }

    ABGEdgeSide side =
        ABGEdgeSideNone;

    /*
     Xác định cạnh ngay khi touch-down.

     Không đợi ngón tay di chuyển rồi mới
     kiểm tra vị trí như bản cũ.
    */

    if (gABGLeftEnabled &&
        startPoint.x <=
            gABGEdgeWidth) {

        side =
            ABGEdgeSideLeft;

    } else if (
        gABGRightEnabled &&
        startPoint.x >=
            width -
            gABGEdgeWidth) {

        side =
            ABGEdgeSideRight;
    }

    if (side ==
        ABGEdgeSideNone) {

        return NO;
    }

    objc_setAssociatedObject(
        gestureRecognizer,
        &kABGSideKey,
        @(side),
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );

    objc_setAssociatedObject(
        gestureRecognizer,
        &kABGThresholdKey,
        @NO,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );

    return YES;
}

#pragma mark Gesture begin

- (BOOL)gestureRecognizerShouldBegin:
    (UIGestureRecognizer *)
        recognizer
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

    UIView *gestureView =
        recognizer.view;

    if (![gestureView
            isKindOfClass:
                [UIWindow class]]) {

        return NO;
    }

    UIWindow *window =
        (UIWindow *)gestureView;

    if (!ABGWindowAllowed(
            window)) {

        return NO;
    }

    NSNumber *sideNumber =
        objc_getAssociatedObject(
            recognizer,
            &kABGSideKey
        );

    if (!sideNumber) {
        return NO;
    }

    ABGEdgeSide side =
        (ABGEdgeSide)
            [sideNumber
                integerValue];

    if (side ==
        ABGEdgeSideNone) {

        return NO;
    }

    UIPanGestureRecognizer *pan =
        (UIPanGestureRecognizer *)
            recognizer;

    CGPoint velocity =
        [pan
            velocityInView:
                window];

    CGPoint translation =
        [pan
            translationInView:
                window];

    CGFloat horizontal =
        fabs(
            velocity.x
        );

    CGFloat vertical =
        fabs(
            velocity.y
        );

    CGFloat directionX;

    if (horizontal > 5.0) {

        directionX =
            velocity.x;

    } else {

        directionX =
            translation.x;
    }

    /*
     Mép trái:
     phải vuốt sang phải.
    */

    if (side ==
        ABGEdgeSideLeft) {

        if (directionX <= 0.0) {
            return NO;
        }
    }

    /*
     Mép phải:
     phải vuốt sang trái.
    */

    if (side ==
        ABGEdgeSideRight) {

        if (directionX >= 0.0) {
            return NO;
        }
    }

    /*
     Nếu chuyển động thiên về chiều dọc,
     để app xử lý scroll bình thường.
    */

    if (horizontal > 5.0 &&
        vertical >
            horizontal *
            1.20) {

        return NO;
    }

    /*
     Nhường cạnh trái cho gesture gốc iOS
     nếu tùy chọn này được bật.
    */

    if (side ==
            ABGEdgeSideLeft &&
        gABGPreferNativeLeft) {

        UIViewController *top =
            ABGTopViewControllerForWindow(
                window
            );

        UINavigationController *nav =
            top.navigationController;

        if (!nav &&
            [top
                isKindOfClass:
                    [UINavigationController
                        class]]) {

            nav =
                (UINavigationController *)
                    top;
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
        &kABGThresholdKey,
        @NO,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );

    return YES;
}

#pragma mark No simultaneous gesture

- (BOOL)gestureRecognizer:
    (UIGestureRecognizer *)
        gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:
    (UIGestureRecognizer *)
        otherGestureRecognizer
{
    /*
     Quan trọng:

     Khi Android Back đã nhận gesture,
     không cho UIScrollView / WKWebView /
     UICollectionView / gesture của app
     chạy song song.
    */

    return NO;
}

#pragma mark Gesture processing

- (void)handlePan:
    (UIPanGestureRecognizer *)gesture
{
    UIWindow *window =
        (UIWindow *)
            gesture.view;

    if (![window
            isKindOfClass:
                [UIWindow class]]) {

        return;
    }

    NSNumber *sideNumber =
        objc_getAssociatedObject(
            gesture,
            &kABGSideKey
        );

    if (!sideNumber) {
        return;
    }

    ABGEdgeSide side =
        (ABGEdgeSide)
            [sideNumber
                integerValue];

    if (side ==
        ABGEdgeSideNone) {

        return;
    }

    CGPoint translation =
        [gesture
            translationInView:
                window];

    CGPoint velocity =
        [gesture
            velocityInView:
                window];

    CGPoint location =
        [gesture
            locationInView:
                window];

    CGFloat distance =
        0.0;

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
            gABGTriggerDistance,
            1.0
        );

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
                showIndicatorForWindow:
                    window
                side:
                    side
                touchY:
                    location.y];

            break;
        }

        case UIGestureRecognizerStateChanged:
        {
            [self
                updateIndicatorForSide:
                    side
                progress:
                    progress
                touchY:
                    location.y];

            BOOL currentlyTriggered =
                distance >=
                    gABGTriggerDistance;

            NSNumber *previous =
                objc_getAssociatedObject(
                    gesture,
                    &kABGThresholdKey
                );

            BOOL alreadyFired =
                [previous
                    boolValue];

            if (currentlyTriggered &&
                !alreadyFired) {

                objc_setAssociatedObject(
                    gesture,
                    &kABGThresholdKey,
                    @YES,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC
                );

                if (gABGHapticsEnabled) {

                    UIImpactFeedbackGenerator
                        *generator =

                        [[UIImpactFeedbackGenerator
                            alloc]
                            initWithStyle:
                                UIImpactFeedbackStyleLight];

                    [generator prepare];

                    [generator
                        impactOccurred];
                }
            }

            break;
        }

        case UIGestureRecognizerStateEnded:
        {
            CGFloat horizontalVelocity =
                fabs(
                    velocity.x
                );

            BOOL distanceTriggered =
                distance >=
                    gABGTriggerDistance;

            BOOL velocityTriggered =
                distance >=
                    20.0 &&
                horizontalVelocity >=
                    gABGMinimumVelocity;

            BOOL directionValid =
                YES;

            if (side ==
                ABGEdgeSideLeft) {

                /*
                 Nếu cuối gesture đang flick ngược
                 ra ngoài thì hủy.
                */

                if (velocity.x <
                    -120.0) {

                    directionValid =
                        NO;
                }

            } else {

                if (velocity.x >
                    120.0) {

                    directionValid =
                        NO;
                }
            }

            BOOL shouldBack =
                directionValid &&
                (
                    distanceTriggered ||
                    velocityTriggered
                );

            BOOL actionPerformed =
                NO;

            if (shouldBack) {

                actionPerformed =
                    ABGPerformBack(
                        window
                    );
            }

            [self
                hideIndicatorForSide:
                    side
                success:
                    (
                        shouldBack &&
                        actionPerformed
                    )];

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
                hideIndicatorForSide:
                    side
                success:
                    NO];

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

#pragma mark - Gesture install

static void
ABGInstallOrUpdateGesture(
    UIWindow *window
)
{
    if (!window) {
        return;
    }

    ABGEdgePanGestureRecognizer *gesture =
        objc_getAssociatedObject(
            window,
            &kABGPanGestureKey
        );

    BOOL shouldEnable =
        gABGEnabled &&
        ABGProcessAllowed() &&
        ABGWindowAllowed(
            window
        );

    if (!gesture) {

        if (!shouldEnable) {
            return;
        }

        gesture =
            [[ABGEdgePanGestureRecognizer
                alloc]
                initWithTarget:
                    [ABGGestureHandler
                        shared]
                action:
                    @selector(
                        handlePan:
                    )];

        gesture.minimumNumberOfTouches =
            1;

        gesture.maximumNumberOfTouches =
            1;

        /*
         Quan trọng:

         Khi Edge Back được recognize,
         hủy touch của view bên dưới.
        */

        gesture.cancelsTouchesInView =
            YES;

        /*
         Touch sát cạnh sẽ được giữ lại ngắn
         cho tới khi hệ thống biết đó là
         Back hay chỉ là tap.

         Nhờ vậy nút/list/game bên dưới không
         bị nhận chạm trước rồi mới bị hủy.
        */

        gesture.delaysTouchesBegan =
            YES;

        gesture.delaysTouchesEnded =
            YES;

        gesture.delegate =
            [ABGGestureHandler shared];

        [window
            addGestureRecognizer:
                gesture];

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

#pragma mark - Refresh windows

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

#pragma mark - Preferences changed

static void
ABGPreferencesChanged(
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

- (void)setHidden:
    (BOOL)hidden
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

#pragma mark - Navigation hooks

%hook UINavigationController

- (void)viewDidAppear:
    (BOOL)animated
{
    %orig(animated);

    ABGApplyNativePopPolicy(
        self
    );
}

- (void)setViewControllers:
    (NSArray<UIViewController *> *)
        viewControllers
    animated:
    (BOOL)animated
{
    %orig(
        viewControllers,
        animated
    );

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
    animated:
    (BOOL)animated
{
    %orig(
        viewController,
        animated
    );

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
