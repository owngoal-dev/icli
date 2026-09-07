#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <os/log.h>
#import <Vision/Vision.h>
#import <Security/Security.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

// Test-only application. Its state file is an independent oracle for CLI tests.
static NSString *const StatePath = @"/var/mobile/Library/Caches/icli-testhost/state.json";

@interface TestController : UIViewController <UITextViewDelegate, UIScrollViewDelegate>
@property(nonatomic) NSMutableDictionary *state;
@property(nonatomic) UITextView *input;
@property(nonatomic) UILabel *status;
@property(nonatomic) UILabel *delayed;
@property(nonatomic) UIView *dragTarget;
@property(nonatomic) CGPoint dragStart;
@property(nonatomic) UIImage *ocrImage;
@property(nonatomic) AVAudioPlayer *player;
- (void)save;
- (void)reset;
- (void)handleURL:(NSURL *)url;
@end

@implementation TestController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.state = [NSMutableDictionary dictionary];
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(24, 65, 370, 40)];
    title.text = @"icli TestHost";
    title.font = [UIFont boldSystemFontOfSize:28];
    title.accessibilityIdentifier = @"screen.title";
    [self.view addSubview:title];
    self.input = [[UITextView alloc] initWithFrame:CGRectMake(24, 120, 360, 90)];
    self.input.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.input.font = [UIFont systemFontOfSize:20];
    self.input.autocorrectionType = UITextAutocorrectionTypeNo;
    self.input.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.input.smartQuotesType = UITextSmartQuotesTypeNo;
    self.input.smartDashesType = UITextSmartDashesTypeNo;
    self.input.delegate = self;
    self.input.accessibilityLabel = @"Test input";
    self.input.accessibilityIdentifier = @"input.text";
    [self.view addSubview:self.input];
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(24, 225, 170, 44);
    [button setTitle:@"Increment" forState:UIControlStateNormal];
    button.accessibilityIdentifier = @"counter.increment";
    [button addTarget:self action:@selector(increment:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:button];
    UIButton *toggle = [UIButton buttonWithType:UIButtonTypeSystem];
    toggle.frame = CGRectMake(210, 225, 174, 44);
    [toggle setTitle:@"Delayed element" forState:UIControlStateNormal];
    toggle.accessibilityIdentifier = @"element.toggle";
    [toggle addTarget:self action:@selector(toggleDelayed:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:toggle];
    self.status = [[UILabel alloc] initWithFrame:CGRectMake(24, 275, 360, 28)];
    self.status.accessibilityIdentifier = @"counter.status";
    [self.view addSubview:self.status];
    self.delayed = [[UILabel alloc] initWithFrame:CGRectMake(24, 307, 360, 30)];
    self.delayed.text = @"Ready element";
    self.delayed.accessibilityIdentifier = @"element.ready";
    [self.view addSubview:self.delayed];
    UIView *gestures = [[UIView alloc] initWithFrame:CGRectMake(24, 350, 360, 100)];
    gestures.backgroundColor = UIColor.systemTealColor;
    gestures.isAccessibilityElement = YES;
    gestures.accessibilityLabel = @"Gesture area";
    gestures.accessibilityIdentifier = @"gesture.area";
    [self.view addSubview:gestures];
    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(doubleTapped:)];
    doubleTap.numberOfTapsRequired = 2;
    [gestures addGestureRecognizer:doubleTap];
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressed:)];
    longPress.minimumPressDuration = 0.4;
    [gestures addGestureRecognizer:longPress];
    self.dragTarget = [[UIView alloc] initWithFrame:CGRectMake(24, 470, 60, 60)];
    self.dragTarget.backgroundColor = UIColor.systemOrangeColor;
    self.dragTarget.isAccessibilityElement = YES;
    self.dragTarget.accessibilityLabel = @"Drag target";
    self.dragTarget.accessibilityIdentifier = @"drag.target";
    [self.dragTarget addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragged:)]];
    [self.view addSubview:self.dragTarget];
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(24, 550, 360, 100)];
    scroll.contentSize = CGSizeMake(360, 900);
    scroll.backgroundColor = UIColor.secondarySystemBackgroundColor;
    scroll.accessibilityIdentifier = @"scroll.list";
    scroll.delegate = self;
    for(int i=0;i<20;i++) {
        UILabel *row = [[UILabel alloc] initWithFrame:CGRectMake(10, i*44, 330, 40)];
        row.text = [NSString stringWithFormat:@"Row %d",i];
        [scroll addSubview:row];
    }
    [self.view addSubview:scroll];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(360, 80)];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [UIColor.whiteColor setFill]; [context fillRect:CGRectMake(0,0,360,80)];
        [@"HELLO 123" drawAtPoint:CGPointMake(8,4) withAttributes:@{NSFontAttributeName:[UIFont boldSystemFontOfSize:28],NSForegroundColorAttributeName:UIColor.blackColor}];
        [@"中文测试" drawAtPoint:CGPointMake(8,40) withAttributes:@{NSFontAttributeName:[UIFont systemFontOfSize:26],NSForegroundColorAttributeName:UIColor.blackColor}];
    }];
    self.ocrImage = image;
    UIImageView *ocr = [[UIImageView alloc] initWithImage:image];
    ocr.frame = CGRectMake(24, 670, 360, 80);
    ocr.isAccessibilityElement = NO;
    [self.view addSubview:ocr];
    [self reset];
    [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_ERROR, "icli-testhost-heartbeat");
    }];
}
- (void)save {
    self.state[@"text"] = self.input.text ?: @"";
    self.state[@"delayed_visible"] = @(!self.delayed.hidden);
    self.state[@"drag_x"] = @(self.dragTarget.center.x);
    self.state[@"drag_y"] = @(self.dragTarget.center.y);
    self.state[@"counter"] = self.state[@"counter"] ?: @0;
    self.status.text = [NSString stringWithFormat:@"Count: %@",self.state[@"counter"]];
    [[NSFileManager defaultManager] createDirectoryAtPath:StatePath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSJSONSerialization dataWithJSONObject:self.state options:NSJSONWritingSortedKeys error:nil] writeToFile:StatePath atomically:YES];
}
- (void)reset {
    [self.input resignFirstResponder];
    [self.state removeAllObjects];
    self.input.text = @"";
    self.delayed.hidden = YES;
    self.dragTarget.center = CGPointMake(54,500);
    for (UIView *view in self.view.subviews) {
        if ([view isKindOfClass:UIScrollView.class] && view != self.input) [(UIScrollView *)view setContentOffset:CGPointZero animated:NO];
    }
    [self save];
}
- (void)increment:(id)sender { self.state[@"counter"] = @([self.state[@"counter"] intValue]+1); [self.input resignFirstResponder]; [self save]; }
- (void)toggleDelayed:(id)sender {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ self.delayed.hidden = !self.delayed.hidden; [self save]; });
}
- (void)doubleTapped:(id)sender { self.state[@"double_taps"] = @([self.state[@"double_taps"] intValue]+1); [self save]; }
- (void)longPressed:(UILongPressGestureRecognizer *)recognizer { if(recognizer.state==UIGestureRecognizerStateBegan){ self.state[@"long_presses"] = @([self.state[@"long_presses"] intValue]+1); [self save]; } }
- (void)dragged:(UIPanGestureRecognizer *)recognizer {
    if(recognizer.state==UIGestureRecognizerStateBegan)self.dragStart=self.dragTarget.center;
    CGPoint delta=[recognizer translationInView:self.view];
    self.dragTarget.center=CGPointMake(self.dragStart.x+delta.x,self.dragStart.y+delta.y);
    self.state[@"drag_events"]=@([self.state[@"drag_events"] intValue]+1);
    [self save];
}
- (void)scrollViewDidScroll:(UIScrollView *)scrollView { if(scrollView==self.input)return; self.state[@"scroll_y"]=@(scrollView.contentOffset.y); [self save]; }
- (void)textViewDidChange:(UITextView *)textView { [self save]; }
- (void)handleURL:(NSURL *)url {
    if([url.host isEqual:@"reset"]) [self reset];
    else if([url.host isEqual:@"focus"]) [self.input becomeFirstResponder];
    else if([url.host isEqual:@"blur"]) [self.input resignFirstResponder];
    else if([url.host isEqual:@"toggle"]) [self toggleDelayed:nil];
    else if([url.host isEqual:@"clipboard-set"]) UIPasteboard.generalPasteboard.string = @"TestHost clipboard 中文 🌱";
    else if([url.host isEqual:@"clipboard-read"]) self.state[@"clipboard"] = UIPasteboard.generalPasteboard.string ?: @"";
    else if([url.host isEqual:@"brightness-set"]) UIScreen.mainScreen.brightness = 0.25;
    else if([url.host isEqual:@"brightness-reset"]) UIScreen.mainScreen.brightness = 0.5;
    else if([url.host isEqual:@"audio-start"]) {
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
        [[AVAudioSession sharedInstance] setActive:YES error:nil];
        unsigned char header[44] = {'R','I','F','F',0x24,0x7d,0,0,'W','A','V','E','f','m','t',' ',16,0,0,0,1,0,1,0,0x40,0x1f,0,0,0x80,0x3e,0,0,2,0,16,0,'d','a','t','a',0,0x7d,0,0};
        NSMutableData *wave=[NSMutableData dataWithBytes:header length:44]; [wave increaseLengthBy:32000];
        self.player=[[AVAudioPlayer alloc] initWithData:wave error:nil]; self.player.numberOfLoops=-1;
        self.state[@"audio_playing"]=@([self.player play]);
    }
    else if([url.host isEqual:@"audio-stop"]) { [self.player stop]; [[AVAudioSession sharedInstance] setActive:NO error:nil]; }
    else if([url.host isEqual:@"ocr"]) {
        VNRecognizeTextRequest *request = [VNRecognizeTextRequest new];
        request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
        request.recognitionLanguages = @[@"en-US", @"zh-Hans"];
        NSError *error = nil;
        BOOL ok = [[[VNImageRequestHandler alloc] initWithCGImage:self.ocrImage.CGImage options:@{}] performRequests:@[request] error:&error];
        NSMutableArray *texts = [NSMutableArray array];
        for(VNRecognizedTextObservation *result in request.results) [texts addObject:[result topCandidates:1].firstObject.string ?: @""];
        self.state[@"ocr"] = @{@"ok": @(ok), @"error": error.description ?: @"", @"texts": texts};
    }
    else if([url.host isEqual:@"network-probe"]) {
        int fd = socket(AF_INET, SOCK_DGRAM, 0);
        struct sockaddr_in address = {0};
        address.sin_len = sizeof(address);
        address.sin_family = AF_INET;
        address.sin_port = htons(54321);
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        const char payload[] = "icli acceptance packet";
        ssize_t sent = sendto(fd, payload, sizeof(payload), 0, (struct sockaddr *)&address, sizeof(address));
        if (fd >= 0) close(fd);
        self.state[@"network_bytes"] = @(sent);
    }
    else if([url.host isEqual:@"keychain-probe"]) {
        NSString *service = [@"icli.testhost." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSDictionary *query = @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService:service, (__bridge id)kSecAttrAccount:@"acceptance"};
        NSMutableDictionary *item = [query mutableCopy];
        item[(__bridge id)kSecValueData] = [@"testhost-fixture" dataUsingEncoding:NSUTF8StringEncoding];
        OSStatus added = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
        NSMutableDictionary *lookup = [query mutableCopy];
        lookup[(__bridge id)kSecReturnData] = @YES;
        CFTypeRef found = NULL;
        OSStatus read = SecItemCopyMatching((__bridge CFDictionaryRef)lookup, &found);
        BOOL matches = found && [(__bridge id)found isEqual:item[(__bridge id)kSecValueData]];
        if (found) CFRelease(found);
        OSStatus removed = SecItemDelete((__bridge CFDictionaryRef)query);
        self.state[@"keychain"] = @{@"add_status":@(added), @"read_status":@(read), @"matches":@(matches), @"delete_status":@(removed)};
    }
    else if([url.host isEqual:@"crash"]) abort();
    self.state[@"last_url"] = url.absoluteString;
    [self save];
}
@end

@interface TestDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic) UIWindow *window;
@property(nonatomic) TestController *controller;
@end
@implementation TestDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.controller=[TestController new];
    self.window.rootViewController=self.controller;
    [self.window makeKeyAndVisible];
    return YES;
}
- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url options:(NSDictionary *)options { [self.controller handleURL:url]; return YES; }
@end
int main(int argc,char **argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(TestDelegate.class)); } }
