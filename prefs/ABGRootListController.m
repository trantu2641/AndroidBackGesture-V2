#import "ABGRootListController.h"

#import <Preferences/PSSpecifier.h>
#import <Foundation/Foundation.h>

static NSString * const ABGPreferencesDomain =
    @"com.chatgpt.androidbackgestureprefs";

static CFStringRef const ABGReloadNotification =
    CFSTR("com.chatgpt.androidbackgestureprefs/Reload");

@implementation ABGRootListController

- (NSArray *)specifiers
{
    if (!_specifiers) {

        _specifiers =
            [self
                loadSpecifiersFromPlistName:@"Root"
                target:self];
    }

    return _specifiers;
}

- (void)resetPreferences
{
    NSArray<NSString *> *keys = @[
        @"enabled",
        @"leftEnabled",
        @"rightEnabled",
        @"showIndicator",
        @"haptics",
        @"preferNativeLeft",
        @"edgeWidth",
        @"triggerDistance",
        @"minimumVelocity",
        @"blacklist"
    ];

    for (NSString *key in keys) {

        CFPreferencesSetAppValue(
            (__bridge CFStringRef)key,
            NULL,
            (__bridge CFStringRef)
                ABGPreferencesDomain
        );
    }

    CFPreferencesAppSynchronize(
        (__bridge CFStringRef)
            ABGPreferencesDomain
    );

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        ABGReloadNotification,
        NULL,
        NULL,
        YES
    );

    [self reloadSpecifiers];
}

@end
