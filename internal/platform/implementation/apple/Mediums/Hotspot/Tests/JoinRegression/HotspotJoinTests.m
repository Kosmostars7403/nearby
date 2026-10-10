// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#import <Foundation/Foundation.h>
#import <XCTest/XCTest.h>
#import <TargetConditionals.h>

// Compile the actual iOS join method on macOS. No radio or device is accessed.
#undef TARGET_OS_IOS
#undef TARGET_OS_OSX
#define TARGET_OS_IOS 1
#define TARGET_OS_OSX 0
#define GNCLoggerInfo(...) do {} while (0)
#define GNCLoggerError(...) do {} while (0)
#define GNCLoggerDebug(...) do {} while (0)
// XCTest can load real NetworkExtension transitively; unique names are essential.
#define NEHotspotConfiguration SvrkaFakeHotspotConfiguration
#define NEHotspotConfigurationManager SvrkaFakeHotspotConfigurationManager
static NSString *const NEHotspotConfigurationErrorDomain = @"NEHotspotConfigurationErrorDomain";
static const NSInteger NEHotspotConfigurationErrorAlreadyAssociated = 13;

@interface SvrkaTestClock : NSObject
@property(atomic) NSTimeInterval offset;
@property(readonly) NSTimeInterval systemUptime;
+ (instancetype)processInfo;
@end
@implementation SvrkaTestClock
+ (instancetype)processInfo {
  static SvrkaTestClock *clock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ clock = [[self alloc] init]; });
  return clock;
}
- (NSTimeInterval)systemUptime { return NSProcessInfo.processInfo.systemUptime + self.offset; }
@end

@interface NEHotspotConfiguration : NSObject
@property(nonatomic) BOOL joinOnce;
@property(nonatomic, copy) NSString *ssid;
- (instancetype)initWithSSID:(NSString *)ssid passphrase:(NSString *)passphrase isWEP:(BOOL)isWEP;
@end
@implementation NEHotspotConfiguration
- (instancetype)initWithSSID:(NSString *)ssid passphrase:(NSString *)passphrase isWEP:(BOOL)isWEP {
  if ((self = [super init])) _ssid = [ssid copy];
  return self;
}
@end

typedef void (^Completion)(NSError *error);
@interface NEHotspotConfigurationManager : NSObject
+ (instancetype)sharedManager;
- (void)reset;
- (void)applyConfiguration:(NEHotspotConfiguration *)config completionHandler:(Completion)completion;
- (void)removeConfigurationForSSID:(NSString *)ssid;
- (BOOL)waitForApplyCount:(NSUInteger)count timeout:(NSTimeInterval)timeout;
- (void)completeAtIndex:(NSUInteger)index error:(NSError *)error;
@property(readonly) NSUInteger applyCount;
@property(readonly) NSUInteger removeCount;
@property(readonly) NSArray<NSString *> *events;
@end
@implementation NEHotspotConfigurationManager {
  NSCondition *_condition;
  NSMutableArray *_completions;
  NSMutableArray<NSString *> *_events;
  NSUInteger _removeCount;
}
+ (instancetype)sharedManager {
  static NEHotspotConfigurationManager *instance;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ instance = [[self alloc] init]; });
  return instance;
}
- (instancetype)init {
  if ((self = [super init])) { _condition = [[NSCondition alloc] init]; [self reset]; }
  return self;
}
- (void)reset {
  [_condition lock];
  _completions = [NSMutableArray array];
  _events = [NSMutableArray array];
  _removeCount = 0;
  [_condition unlock];
}
- (void)applyConfiguration:(NEHotspotConfiguration *)config completionHandler:(Completion)completion {
  [_condition lock];
  [_events addObject:[@"apply:" stringByAppendingString:config.ssid]];
  [_completions addObject:[completion copy]];
  [_condition broadcast];
  [_condition unlock];
}
- (void)removeConfigurationForSSID:(NSString *)ssid {
  [_condition lock];
  [_events addObject:[@"remove:" stringByAppendingString:ssid]];
  _removeCount++;
  [_condition unlock];
}
- (BOOL)waitForApplyCount:(NSUInteger)count timeout:(NSTimeInterval)timeout {
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
  [_condition lock];
  while (_completions.count < count && [_condition waitUntilDate:deadline]) {}
  BOOL reached = _completions.count >= count;
  [_condition unlock];
  return reached;
}
- (void)completeAtIndex:(NSUInteger)index error:(NSError *)error {
  [_condition lock];
  Completion completion = _completions[index];
  _completions[index] = [NSNull null];
  [_condition unlock];
  completion(error);
}
- (NSUInteger)applyCount { [_condition lock]; NSUInteger n = _completions.count; [_condition unlock]; return n; }
- (NSUInteger)removeCount { [_condition lock]; NSUInteger n = _removeCount; [_condition unlock]; return n; }
- (NSArray *)events { [_condition lock]; NSArray *events = [_events copy]; [_condition unlock]; return events; }
@end

// Boundary for the real SSID lookup helper, including a held asynchronous fetch.
#define CLLocationManager SvrkaFakeLocationManager
#define NEHotspotNetwork SvrkaFakeHotspotNetwork
typedef NSInteger CLAuthorizationStatus;
static const CLAuthorizationStatus kCLAuthorizationStatusAuthorizedWhenInUse = 4;
static const CLAuthorizationStatus kCLAuthorizationStatusAuthorizedAlways = 3;
@interface CLLocationManager : NSObject
@property(readonly) CLAuthorizationStatus authorizationStatus;
+ (CLAuthorizationStatus)authorizationStatus;
@end
@implementation CLLocationManager
- (CLAuthorizationStatus)authorizationStatus { return kCLAuthorizationStatusAuthorizedWhenInUse; }
+ (CLAuthorizationStatus)authorizationStatus { return kCLAuthorizationStatusAuthorizedWhenInUse; }
@end
// Pre-iOS 14 branch is compiled but not selected on this host.
static CFArrayRef CNCopySupportedInterfaces(void) { return NULL; }
static CFDictionaryRef CNCopyCurrentNetworkInfo(CFStringRef interface) { return NULL; }

@interface NEHotspotNetwork : NSObject
@property(nonatomic, copy) NSString *SSID;
+ (void)fetchCurrentWithCompletionHandler:(void (^)(NEHotspotNetwork *))completion;
+ (void)reset;
+ (void)setCurrentSSID:(NSString *)ssid;
+ (void)setHoldFetch:(BOOL)hold;
+ (BOOL)waitForFetch;
+ (void)completeFetch;
@end
@implementation NEHotspotNetwork
static NSCondition *fetchCondition;
static NSString *currentSSID;
static BOOL holdFetch;
static void (^heldFetch)(NEHotspotNetwork *);
+ (void)initialize { if (self == [NEHotspotNetwork class]) fetchCondition = [NSCondition new]; }
+ (void)reset {
  [fetchCondition lock]; currentSSID = nil; holdFetch = NO; heldFetch = nil; [fetchCondition unlock];
}
+ (void)setCurrentSSID:(NSString *)ssid { [fetchCondition lock]; currentSSID = ssid; [fetchCondition unlock]; }
+ (void)setHoldFetch:(BOOL)hold { [fetchCondition lock]; holdFetch = hold; [fetchCondition unlock]; }
+ (void)fetchCurrentWithCompletionHandler:(void (^)(NEHotspotNetwork *))completion {
  [fetchCondition lock];
  if (holdFetch) {
    heldFetch = [completion copy]; [fetchCondition broadcast]; [fetchCondition unlock]; return;
  }
  NEHotspotNetwork *network = [self new]; network.SSID = currentSSID;
  [fetchCondition unlock];
  completion(network);
}
+ (BOOL)waitForFetch {
  [fetchCondition lock]; NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
  while (!heldFetch && [fetchCondition waitUntilDate:deadline]) {}
  BOOL found = heldFetch != nil; [fetchCondition unlock]; return found;
}
+ (void)completeFetch {
  [fetchCondition lock];
  void (^completion)(NEHotspotNetwork *) = heldFetch; heldFetch = nil;
  [fetchCondition unlock];
  if (completion) completion(nil);
}
@end

@interface GNCHotspotMedium : NSObject
@property(nonatomic) CLLocationManager *locationManager;
- (BOOL)connectToWifiNetworkWithSSID:(NSString *)ssid password:(NSString *)password;
- (BOOL)connectToWifiNetworkWithSSID:(NSString *)ssid password:(NSString *)password isCancelled:(BOOL (^)(void))cancel;
- (NSString *)getCurrentWifiSSID;
- (NSString *)getCurrentWifiSSIDWithCancellation:(BOOL (^)(void))cancel;
@end
#define NSProcessInfo SvrkaTestClock
#include "ActualHotspotJoin.inc"
#undef NSProcessInfo

@interface JoinCall : NSObject
@property(atomic) BOOL cancelled;
@property(atomic) BOOL result;
@property(nonatomic) dispatch_semaphore_t returned;
- (instancetype)initWithMedium:(GNCHotspotMedium *)medium ssid:(NSString *)ssid cancelled:(BOOL)cancelled;
- (BOOL)wait:(NSTimeInterval)seconds;
@end
@implementation JoinCall
- (instancetype)initWithMedium:(GNCHotspotMedium *)medium ssid:(NSString *)ssid cancelled:(BOOL)cancelled {
  if ((self = [super init])) {
    self.cancelled = cancelled;
    self.returned = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
      // Baseline revisions have only the legacy selector, allowing the same
      // behavioral regression to run RED without changing their source.
      if ([medium respondsToSelector:@selector(connectToWifiNetworkWithSSID:password:isCancelled:)]) {
        self.result = [medium connectToWifiNetworkWithSSID:ssid password:@"fixture-password"
            isCancelled:^{ return self.cancelled; }];
      } else {
        self.result = [medium connectToWifiNetworkWithSSID:ssid password:@"fixture-password"];
      }
      dispatch_semaphore_signal(self.returned);
    });
  }
  return self;
}
- (BOOL)wait:(NSTimeInterval)seconds {
  return dispatch_semaphore_wait(self.returned, dispatch_time(DISPATCH_TIME_NOW, seconds * NSEC_PER_SEC)) == 0;
}
@end

@interface HotspotJoinTests : XCTestCase
@end
@implementation HotspotJoinTests
- (void)setUp {
  [super setUp];
  [[NEHotspotConfigurationManager sharedManager] reset];
  [SvrkaTestClock processInfo].offset = 0;
  [NEHotspotNetwork reset];
}
- (void)testConsentCanTakeLongerThan18Seconds {
  NEHotspotConfigurationManager *os = [NEHotspotConfigurationManager sharedManager];
  JoinCall *call = [[JoinCall alloc] initWithMedium:[GNCHotspotMedium new] ssid:@"first" cancelled:NO];
  XCTAssertTrue([os waitForApplyCount:1 timeout:2]);
  // Real wall time: do not rewrite the SDK timeout to make this test pass.
  [NSThread sleepForTimeInterval:20];
  BOOL returnedBeforeConsent = [call wait:0];
  NSUInteger earlyRemovals = os.removeCount;
  [os completeAtIndex:0 error:nil];
  if (!returnedBeforeConsent) XCTAssertTrue([call wait:2]);
  XCTAssertFalse(returnedBeforeConsent);
  XCTAssertEqual(earlyRemovals, 0u);
  XCTAssertTrue(call.result);
  XCTAssertEqual(os.applyCount, 1u);
}
- (void)testAlreadyCancelledDoesNotApply {
  NEHotspotConfigurationManager *os = [NEHotspotConfigurationManager sharedManager];
  JoinCall *call = [[JoinCall alloc] initWithMedium:[GNCHotspotMedium new] ssid:@"first" cancelled:YES];
  BOOL returned = [call wait:0.5];
  NSUInteger applies = os.applyCount;
  // Release baseline pending work so RED never leaves a dangling operation.
  if (applies) [os completeAtIndex:0 error:nil];
  if (!returned) XCTAssertTrue([call wait:2]);
  XCTAssertTrue(returned);
  XCTAssertEqual(applies, 0u);
  XCTAssertFalse(call.result);
}
- (void)testCancellationReturnsPromptlyWithoutAbandoningOSOwnership {
  NEHotspotConfigurationManager *os = [NEHotspotConfigurationManager sharedManager];
  JoinCall *call = [[JoinCall alloc] initWithMedium:[GNCHotspotMedium new] ssid:@"first" cancelled:NO];
  XCTAssertTrue([os waitForApplyCount:1 timeout:2]);
  call.cancelled = YES;
  BOOL returned = [call wait:0.5];
  NSUInteger earlyRemovals = os.removeCount;
  [os completeAtIndex:0 error:nil];
  if (!returned) XCTAssertTrue([call wait:2]);
  XCTAssertTrue(returned);
  XCTAssertFalse(call.result);
  XCTAssertEqual(earlyRemovals, 0u);
  XCTAssertEqual(os.removeCount, 1u);
}
- (void)testCancelledPendingApplyBlocksOtherMediumUntilCleanup {
  NEHotspotConfigurationManager *os = [NEHotspotConfigurationManager sharedManager];
  JoinCall *first = [[JoinCall alloc] initWithMedium:[GNCHotspotMedium new] ssid:@"first" cancelled:NO];
  XCTAssertTrue([os waitForApplyCount:1 timeout:2]);
  first.cancelled = YES;
  XCTAssertTrue([first wait:0.5]);
  JoinCall *collision = [[JoinCall alloc] initWithMedium:[GNCHotspotMedium new] ssid:@"second" cancelled:NO];
  XCTAssertTrue([collision wait:0.5]);
  XCTAssertFalse(collision.result);
  XCTAssertEqual(os.applyCount, 1u);
  XCTAssertEqual(os.removeCount, 0u);
  [os completeAtIndex:0 error:nil];
  JoinCall *retry = [[JoinCall alloc] initWithMedium:[GNCHotspotMedium new] ssid:@"second" cancelled:NO];
  XCTAssertTrue([os waitForApplyCount:2 timeout:2]);
  [os completeAtIndex:1 error:nil];
  XCTAssertTrue([retry wait:2]);
  XCTAssertTrue(retry.result);
  XCTAssertEqualObjects(os.events, (@[@"apply:first", @"remove:first", @"apply:second"]));
}
- (void)testConcurrentJoinDoesNotStartAnotherApply {
  NEHotspotConfigurationManager *os = [NEHotspotConfigurationManager sharedManager];
  JoinCall *first = [[JoinCall alloc] initWithMedium:[GNCHotspotMedium new] ssid:@"first" cancelled:NO];
  XCTAssertTrue([os waitForApplyCount:1 timeout:2]);
  JoinCall *second = [[JoinCall alloc] initWithMedium:[GNCHotspotMedium new] ssid:@"second" cancelled:NO];
  XCTAssertTrue([second wait:0.5]);
  XCTAssertFalse(second.result);
  XCTAssertEqual(os.applyCount, 1u);
  [os completeAtIndex:0 error:nil];
  XCTAssertTrue([first wait:2]);
  XCTAssertTrue(first.result);
  XCTAssertEqual(os.removeCount, 0u);
}
- (void)testDeadlineKeepsPendingOwnershipAndNextApplyGetsFullBudget {
  NEHotspotConfigurationManager *os = [NEHotspotConfigurationManager sharedManager];
  JoinCall *first = [[JoinCall alloc] initWithMedium:[GNCHotspotMedium new] ssid:@"first" cancelled:NO];
  XCTAssertTrue([os waitForApplyCount:1 timeout:2]);
  // Move only the monotonic clock boundary, keeping the production 90 s constant.
  [SvrkaTestClock processInfo].offset = 91;
  XCTAssertTrue([first wait:0.5]);
  XCTAssertFalse(first.result);
  XCTAssertEqual(os.removeCount, 0u);
  [os completeAtIndex:0 error:nil];
  JoinCall *retry = [[JoinCall alloc] initWithMedium:[GNCHotspotMedium new] ssid:@"second" cancelled:NO];
  XCTAssertTrue([os waitForApplyCount:2 timeout:2]);
  [SvrkaTestClock processInfo].offset = 171; // New attempt is only 80 s old.
  XCTAssertFalse([retry wait:0.2]);
  [os completeAtIndex:1 error:nil];
  XCTAssertTrue([retry wait:2]);
  XCTAssertTrue(retry.result);
  XCTAssertEqualObjects(os.events, (@[@"apply:first", @"remove:first", @"apply:second"]));
}
- (void)testAlreadyAssociatedSucceedsWithoutRemoval {
  NEHotspotConfigurationManager *os = [NEHotspotConfigurationManager sharedManager];
  JoinCall *call = [[JoinCall alloc] initWithMedium:[GNCHotspotMedium new] ssid:@"first" cancelled:NO];
  XCTAssertTrue([os waitForApplyCount:1 timeout:2]);
  [os completeAtIndex:0 error:[NSError errorWithDomain:NEHotspotConfigurationErrorDomain code:13 userInfo:nil]];
  XCTAssertTrue([call wait:2]);
  XCTAssertTrue(call.result);
  XCTAssertEqual(os.removeCount, 0u);
}
- (void)testUserDeniedReturnsFailureWithSingleApply {
  NEHotspotConfigurationManager *os = [NEHotspotConfigurationManager sharedManager];
  JoinCall *call = [[JoinCall alloc] initWithMedium:[GNCHotspotMedium new] ssid:@"first" cancelled:NO];
  XCTAssertTrue([os waitForApplyCount:1 timeout:2]);
  [os completeAtIndex:0 error:[NSError errorWithDomain:NEHotspotConfigurationErrorDomain code:7 userInfo:nil]];
  XCTAssertTrue([call wait:2]);
  XCTAssertFalse(call.result);
  XCTAssertEqual(os.applyCount, 1u);
  XCTAssertEqual(os.removeCount, 1u);
}
- (void)testWrongSSIDReturnsFailureAndRemovesConfiguration {
  NEHotspotConfigurationManager *os = [NEHotspotConfigurationManager sharedManager];
  GNCHotspotMedium *medium = [GNCHotspotMedium new];
  [NEHotspotNetwork setCurrentSSID:@"wrong"];
  JoinCall *call = [[JoinCall alloc] initWithMedium:medium ssid:@"first" cancelled:NO];
  XCTAssertTrue([os waitForApplyCount:1 timeout:2]);
  [os completeAtIndex:0 error:nil];
  XCTAssertTrue([call wait:2]);
  XCTAssertFalse(call.result);
  XCTAssertEqual(os.removeCount, 1u);
}
- (void)testCancellationDuringHeldSSIDFetchReturnsPromptly {
  NEHotspotConfigurationManager *os = [NEHotspotConfigurationManager sharedManager];
  [NEHotspotNetwork setHoldFetch:YES];
  JoinCall *call = [[JoinCall alloc] initWithMedium:[GNCHotspotMedium new] ssid:@"first" cancelled:NO];
  XCTAssertTrue([os waitForApplyCount:1 timeout:2]);
  [os completeAtIndex:0 error:nil];
  XCTAssertTrue([NEHotspotNetwork waitForFetch]);
  call.cancelled = YES;
  BOOL returned = [call wait:0.5];
  [NEHotspotNetwork completeFetch]; // Late OS completion must be harmless.
  if (!returned) XCTAssertTrue([call wait:2]);
  XCTAssertTrue(returned);
  XCTAssertFalse(call.result);
  XCTAssertEqual(os.removeCount, 1u);
}
- (void)testLegacySelectorStillSucceeds {
  NEHotspotConfigurationManager *os = [NEHotspotConfigurationManager sharedManager];
  dispatch_semaphore_t returned = dispatch_semaphore_create(0);
  __block BOOL success = NO;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    success = [[GNCHotspotMedium new] connectToWifiNetworkWithSSID:@"first" password:@"fixture-password"];
    dispatch_semaphore_signal(returned);
  });
  XCTAssertTrue([os waitForApplyCount:1 timeout:2]);
  [os completeAtIndex:0 error:nil];
  XCTAssertEqual(dispatch_semaphore_wait(returned, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)), 0L);
  XCTAssertTrue(success);
}
@end
