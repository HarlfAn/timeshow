#import <Preferences/PSListController.h>

@interface BTRootListController : PSListController
@end

@implementation BTRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

@end
