#import "IcliPrivate.h"
#import "IcliJSON.h"
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <objc/message.h>

// locationd's simulation client (the one Xcode's location simulation uses).
// The simulated location lives in locationd and outlives this connection;
// one manager per process lets a long-running host keep its session.
static id simulationManager(void) {
    static id manager;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ manager = [NSClassFromString(@"CLSimulationManager") new]; });
    return manager;
}

static NSString *sendAll(id manager, NSArray<NSString *> *selectors, CLLocation *location) {
    if (!manager) return @"CoreLocation's location simulation is unavailable on this device";
    for (NSString *name in selectors) {
        if (![manager respondsToSelector:NSSelectorFromString(name)]) return [NSString stringWithFormat:@"CoreLocation's location simulation does not support %@", name];
    }
    for (NSString *name in selectors) {
        SEL selector = NSSelectorFromString(name);
        if ([name hasSuffix:@":"]) ((void (*)(id, SEL, id))objc_msgSend)(manager, selector, location);
        else ((void (*)(id, SEL))objc_msgSend)(manager, selector);
    }
    return nil;
}

char *icli_location_simulate_json(double latitude, double longitude, double altitude, double horizontal_accuracy, double vertical_accuracy, double speed, double course) {
    CLLocation *location = [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(latitude, longitude)
                                                         altitude:altitude
                                               horizontalAccuracy:horizontal_accuracy
                                                 verticalAccuracy:vertical_accuracy
                                                           course:course
                                                            speed:speed
                                                        timestamp:[NSDate date]];
    NSString *error = sendAll(simulationManager(), @[@"stopLocationSimulation", @"clearSimulatedLocations", @"appendSimulatedLocation:", @"flush", @"startLocationSimulation"], location);
    return icli_json(error ? @{@"error": error} : @{});
}

char *icli_location_clear_json(void) {
    NSString *error = sendAll(simulationManager(), @[@"stopLocationSimulation", @"clearSimulatedLocations", @"flush"], nil);
    return icli_json(error ? @{@"error": error} : @{});
}

@interface IcliLocationReader : NSObject <CLLocationManagerDelegate>
@property (nonatomic, strong) CLLocation *latest;
@property (nonatomic, strong) NSError *error;
@end

@implementation IcliLocationReader
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations { self.latest = locations.lastObject; }
- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error { self.error = error; }
@end

// locationd defers authorization for a bare executable until it names a
// bundle, so icli reads as one of the System Services location bundles,
// which are authorized unless turned off in Settings.
static CLLocationManager *systemServiceManager(NSString **bundlePath) {
    for (NSString *name in @[@"SystemCustomization", @"TimeZone", @"CompassCalibration"]) {
        NSString *path = [NSString stringWithFormat:@"/System/Library/LocationBundles/%@.bundle", name];
        CLLocationManager *manager = ((id (*)(id, SEL, id))objc_msgSend)([CLLocationManager alloc], NSSelectorFromString(@"initWithEffectiveBundlePath:"), path);
        CLAuthorizationStatus status = manager.authorizationStatus;
        if (status == kCLAuthorizationStatusAuthorizedAlways || status == kCLAuthorizationStatusAuthorizedWhenInUse) {
            *bundlePath = path;
            return manager;
        }
    }
    return nil;
}

char *icli_location_read_json(double timeout, bool match, double latitude, double longitude) {
    if (![CLLocationManager locationServicesEnabled]) return icli_json(@{@"error": @"Location Services are turned off"});
    NSString *bundlePath = nil;
    CLLocationManager *manager = systemServiceManager(&bundlePath);
    if (!manager) return icli_json(@{@"error": @"no System Services location bundle is authorized to read the location"});
    IcliLocationReader *reader = [IcliLocationReader new];
    manager.delegate = reader;
    manager.desiredAccuracy = kCLLocationAccuracyBest;
    manager.distanceFilter = kCLDistanceFilterNone;
    NSDate *start = [NSDate date];
    NSDate *deadline = [start dateByAddingTimeInterval:timeout];
    // A fresh fix carries a timestamp from this read; locationd first hands
    // out its last known location, which may be much older.
    BOOL (^fresh)(CLLocation *) = ^BOOL(CLLocation *location) { return location && [location.timestamp timeIntervalSinceDate:start] >= -1; };
    BOOL (^satisfied)(CLLocation *) = ^BOOL(CLLocation *location) {
        return fresh(location) && (!match || (fabs(location.coordinate.latitude - latitude) < 1e-7 && fabs(location.coordinate.longitude - longitude) < 1e-7));
    };
    [manager startUpdatingLocation];
    while (!satisfied(reader.latest) && reader.error.code != kCLErrorDenied && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:MIN(0.1, deadline.timeIntervalSinceNow)]];
    }
    [manager stopUpdatingLocation];
    manager.delegate = nil;
    CLLocation *location = reader.latest ?: manager.location;
    if (reader.error.code == kCLErrorDenied) return icli_json(@{@"error": @"locationd denied access to the location"});
    if (!location) return icli_json(@{@"error": [NSString stringWithFormat:@"no location within %g s", timeout]});
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions |= NSISO8601DateFormatWithFractionalSeconds;
    return icli_json(@{
        @"latitude": @(location.coordinate.latitude),
        @"longitude": @(location.coordinate.longitude),
        @"altitude": @(location.altitude),
        @"horizontal_accuracy": @(location.horizontalAccuracy),
        @"vertical_accuracy": @(location.verticalAccuracy),
        @"speed": @(location.speed),
        @"course": @(location.course),
        @"timestamp": [formatter stringFromDate:location.timestamp],
        @"age_seconds": @(MAX(0, -location.timestamp.timeIntervalSinceNow)),
        @"fresh": @(fresh(location)),
        @"simulated": @(location.sourceInformation.isSimulatedBySoftware),
        @"client": bundlePath,
    });
}
