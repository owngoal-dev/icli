#import <UIKit/UIKit.h>

// Test-only tvOS application. Its accessibility labels are the oracle for the
// tvOS acceptance run: the status label says what the app last received.
@interface TVTestController : UIViewController <UITextFieldDelegate>
@property(nonatomic) UILabel *status;
@property(nonatomic) UILabel *typed;
@end

@implementation TVTestController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(120, 100, 1600, 120)];
    title.text = @"icli tvOS TestHost";
    title.font = [UIFont boldSystemFontOfSize:80];
    title.textColor = UIColor.whiteColor;
    title.accessibilityIdentifier = @"screen.title";
    self.status = [[UILabel alloc] initWithFrame:CGRectMake(120, 240, 1600, 90)];
    self.status.text = @"Ready";
    self.status.font = [UIFont systemFontOfSize:56];
    self.status.textColor = UIColor.greenColor;
    self.status.accessibilityIdentifier = @"status";
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(120, 380, 600, 110);
    [button setTitle:@"Press Me" forState:UIControlStateNormal];
    button.accessibilityIdentifier = @"button.press";
    [button addTarget:self action:@selector(pressed:) forControlEvents:UIControlEventPrimaryActionTriggered];
    UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(120, 540, 900, 90)];
    field.placeholder = @"Type here";
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.delegate = self;
    field.accessibilityIdentifier = @"input.text";
    [field addTarget:self action:@selector(edited:) forControlEvents:UIControlEventEditingChanged];
    self.typed = [[UILabel alloc] initWithFrame:CGRectMake(120, 660, 1600, 80)];
    self.typed.text = @"Typed: ";
    self.typed.font = [UIFont systemFontOfSize:48];
    self.typed.textColor = UIColor.whiteColor;
    self.typed.accessibilityIdentifier = @"input.echo";
    for (UIView *view in @[title, self.status, button, field, self.typed]) [self.view addSubview:view];
}

- (void)pressed:(id)sender { self.status.text = @"Pressed"; }
- (void)edited:(UITextField *)field { self.typed.text = [@"Typed: " stringByAppendingString:field.text ?: @""]; }
- (void)textFieldDidEndEditing:(UITextField *)field { [self edited:field]; }
- (void)openedURL:(NSURL *)url { self.status.text = [@"Opened " stringByAppendingString:url.absoluteString]; }
@end

@interface TVTestDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic) UIWindow *window;
@end

@implementation TVTestDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [TVTestController new];
    [self.window makeKeyAndVisible];
    NSURL *url = options[UIApplicationLaunchOptionsURLKey];
    if (url) [(TVTestController *)self.window.rootViewController openedURL:url];
    return YES;
}

- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary *)options {
    [(TVTestController *)self.window.rootViewController openedURL:url];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(TVTestDelegate.class));
    }
}
