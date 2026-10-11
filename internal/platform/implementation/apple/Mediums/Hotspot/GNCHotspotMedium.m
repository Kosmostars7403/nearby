// Copyright 2025 Google LLC
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

#import "internal/platform/implementation/apple/Mediums/Hotspot/GNCHotspotMedium.h"

#import <CoreLocation/CoreLocation.h>
#import <Foundation/Foundation.h>
#import <Network/Network.h>
#if TARGET_OS_IOS
#import <NetworkExtension/NetworkExtension.h>
#elif TARGET_OS_OSX
#import <CoreWLAN/CoreWLAN.h>
#endif  // TARGET_OS_IOS
#import <SystemConfiguration/CaptiveNetwork.h>

#import "internal/platform/implementation/apple/Log/GNCLogger.h"
#import "internal/platform/implementation/apple/Mediums/WiFiCommon/GNCIPv4Address.h"
#import "internal/platform/implementation/apple/Mediums/WiFiCommon/GNCNWConnectionImpl.h"
#import "internal/platform/implementation/apple/Mediums/WiFiCommon/GNCNWFramework.h"
#import "internal/platform/implementation/apple/Mediums/WiFiCommon/GNCNWFrameworkError.h"
#import "internal/platform/implementation/apple/Mediums/WiFiCommon/GNCNWFrameworkSocket.h"

NS_ASSUME_NONNULL_BEGIN

#if TARGET_OS_IOS
// Include time for the user to approve the system prompt as well as joining Wi-Fi.
static const UInt8 kConnectionTimeoutInSeconds = 90;
#elif TARGET_OS_OSX
// The maximum number of retries for connecting to the hotspot on MacOS.
static const UInt8 kMaxRetryCount = 3;

// Timeout for connection attempt.
static const UInt8 kConnectionTimeoutInSeconds = 2;
#endif  // TARGET_OS_IOS

// An arbitrary timeout that should be pretty lenient.
static const UInt8 kConnectionToHostTimeoutInSeconds = 10;

#if TARGET_OS_IOS
#define GNC_HOTSPOT_CONSENT_SESSION 1
// A run represents explicit application consent to one system join prompt.
@interface GNCHotspotConsentRun : NSObject
@property(nonatomic, copy) NSString *identifier;
@property(atomic) BOOL active;
@property(atomic) BOOL denied;
@property(nonatomic) BOOL attempted;
@property(nonatomic, copy, nullable) NSString *joinedSSID;
@property(nonatomic, copy, nullable) void (^userDeniedHandler)(void);
@end
@implementation GNCHotspotConsentRun
@end
static GNCHotspotConsentRun *gHotspotConsentRun;

// NEHotspotConfigurationManager is process-wide and has no apply cancellation API.
// Keep its pending operation gated until the actual completion, including after
// the synchronous caller cancels or times out.
@interface GNCHotspotJoinAttempt : NSObject
@property(nonatomic, copy) NSString *ssid;
@property(nonatomic) BOOL completed;
@property(nonatomic) BOOL connected;
@property(nonatomic) BOOL abandoned;
@property(nonatomic) BOOL finishing;
@end
@implementation GNCHotspotJoinAttempt
@end

static GNCHotspotJoinAttempt *gPendingHotspotJoin;

static NSCondition *GNCHotspotJoinCondition(void) {
  static NSCondition *condition;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ condition = [[NSCondition alloc] init]; });
  return condition;
}

void GNCBeginWifiHotspotSession(NSString *identifier, void (^userDeniedHandler)(void)) {
  NSCondition *condition = GNCHotspotJoinCondition();
  [condition lock];
  gHotspotConsentRun.active = NO;
  GNCHotspotConsentRun *run = [GNCHotspotConsentRun new];
  run.identifier = identifier;
  run.active = YES;
  run.userDeniedHandler = userDeniedHandler;
  gHotspotConsentRun = run;
  [condition broadcast];
  [condition unlock];
}

void GNCEndWifiHotspotSession(NSString *identifier) {
  NSCondition *condition = GNCHotspotJoinCondition();
  [condition lock];
  if ([gHotspotConsentRun.identifier isEqualToString:identifier]) {
    // Retain the inactive tombstone so delayed BWU work cannot prompt between runs.
    gHotspotConsentRun.active = NO;
    gHotspotConsentRun.userDeniedHandler = nil;
    [condition broadcast];
  }
  [condition unlock];
}

static void GNCNotifyHotspotUserDenied(GNCHotspotConsentRun *run) {
  // Never call application code while holding the medium lock. Recheck ownership
  // on delivery: the OS callback can outlive cancellation and an explicit retry.
  dispatch_async(dispatch_get_main_queue(), ^{
    NSCondition *condition = GNCHotspotJoinCondition();
    [condition lock];
    void (^handler)(void) = (gHotspotConsentRun == run && run.active) ? run.userDeniedHandler : nil;
    [condition unlock];
    if (handler) handler();
  });
}

static void GNCFinishHotspotJoin(GNCHotspotJoinAttempt *attempt, BOOL removeConfiguration) {
  NSCondition *condition = GNCHotspotJoinCondition();
  [condition lock];
  if (gPendingHotspotJoin != attempt || attempt.finishing) {
    [condition unlock];
    return;
  }
  attempt.finishing = YES;
  [condition unlock];
  if (removeConfiguration) {
    [[NEHotspotConfigurationManager sharedManager] removeConfigurationForSSID:attempt.ssid];
  }
  [condition lock];
  gPendingHotspotJoin = nil;
  [condition broadcast];
  [condition unlock];
}
#else
// Hotspot consent prompts are an iOS behavior; keep the shared Swift API portable.
void GNCBeginWifiHotspotSession(NSString *identifier, void (^userDeniedHandler)(void)) {}
void GNCEndWifiHotspotSession(NSString *identifier) {}
#endif

@interface GNCHotspotMedium ()
@property(nonatomic) CLLocationManager *locationManager;
- (NSString *)getCurrentWifiSSIDWithCancellation:(BOOL (^_Nullable)(void))isCancelled;
@end

@implementation GNCHotspotMedium {
  dispatch_queue_t _hotspot_queue;
  GNCNWFramework *_nwFramework;
}

- (instancetype)init {
  return [self initWithQueue:dispatch_get_main_queue()];
}

- (instancetype)initWithQueue:(dispatch_queue_t)queue {
  return [self initWithQueue:queue nwFramework:[[GNCNWFramework alloc] init]];
}

- (instancetype)initWithQueue:(dispatch_queue_t)queue nwFramework:(GNCNWFramework *)nwFramework {
  self = [super init];
  if (self) {
    _hotspot_queue = queue;
    _locationManager = [[CLLocationManager alloc] init];
    _nwFramework = nwFramework;
  }
  return self;
}

- (BOOL)connectToWifiNetworkWithSSID:(NSString *)ssid password:(NSString *)password {
  return [self connectToWifiNetworkWithSSID:ssid password:password isCancelled:nil];
}

- (BOOL)connectToWifiNetworkWithSSID:(NSString *)ssid
                          password:(NSString *)password
                       isCancelled:(BOOL (^_Nullable)(void))isCancelled {
  if (ssid.length == 0) {
    GNCLoggerError(@"SSID cannot be empty.");
    return NO;
  }
  if (password.length == 0) {
    GNCLoggerError(@"Password cannot be empty.");
    return NO;
  }

#if TARGET_OS_IOS
  NSCondition *condition = GNCHotspotJoinCondition();
  [condition lock];
  GNCHotspotConsentRun *run = gHotspotConsentRun;
  // The app owns hotspot negotiation; no implicit SDK consent session.
  if (!run || !run.active) { [condition unlock]; return NO; }
  NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + kConnectionTimeoutInSeconds;
  BOOL (^shouldStop)(void) = ^BOOL{
    return (isCancelled && isCancelled()) || (run && (!run.active || run.denied)) ||
        NSProcessInfo.processInfo.systemUptime >= deadline;
  };
  // The bandwidth-upgrade handler already retries with backoff. Do not start a
  // second OS apply, or spend a new attempt's consent budget waiting for an old one.
  if (gPendingHotspotJoin || shouldStop()) {
    [condition unlock];
    return NO;
  }
  if (run.attempted) {
    // BWU may retry its socket on an existing association, but never re-prompt.
    BOOL reuse = [run.joinedSSID isEqualToString:ssid];
    [condition unlock];
    return reuse;
  }
  run.attempted = YES;
  GNCHotspotJoinAttempt *attempt = [[GNCHotspotJoinAttempt alloc] init];
  attempt.ssid = ssid;
  gPendingHotspotJoin = attempt;
  [condition unlock];

  NEHotspotConfiguration *config = [[NEHotspotConfiguration alloc] initWithSSID:ssid
                                                                     passphrase:password
                                                                          isWEP:NO];
  config.joinOnce = YES;
  GNCLoggerInfo(@"Hotspot system join requested");
  [[NEHotspotConfigurationManager sharedManager]
      applyConfiguration:config
       completionHandler:^(NSError *_Nullable error) {
         BOOL connected = error == nil ||
             ([error.domain isEqualToString:NEHotspotConfigurationErrorDomain] &&
              error.code == NEHotspotConfigurationErrorAlreadyAssociated);
         if (connected) {
           GNCLoggerInfo(@"Hotspot configuration applied");
         } else {
           GNCLoggerError(@"Hotspot connection failed: domain=%@ code=%ld", error.domain,
                          (long)error.code);
         }
         [condition lock];
         attempt.completed = YES;
         attempt.connected = connected;
         BOOL denied = [error.domain isEqualToString:NEHotspotConfigurationErrorDomain] &&
             error.code == NEHotspotConfigurationErrorUserDenied;
         BOOL notifyDenied = denied && run && run.active && !run.denied && gHotspotConsentRun == run;
         if (notifyDenied) run.denied = YES;
         BOOL abandoned = attempt.abandoned;
         [condition broadcast];
         [condition unlock];
         if (notifyDenied) GNCNotifyHotspotUserDenied(run);
         if (abandoned) {
           // Clean up this late result before allowing another apply. Never let
           // an old callback remove a newer operation's joinOnce configuration.
           GNCFinishHotspotJoin(attempt, YES);
         }
       }];

  [condition lock];
  while (!attempt.completed && !shouldStop()) {
    [condition waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
  }
  if (shouldStop()) {
    attempt.abandoned = YES;
    BOOL completed = attempt.completed;
    [condition unlock];
    if (completed) GNCFinishHotspotJoin(attempt, YES);
    // A still-pending apply owns the gate until its callback cleans up. Removing
    // its configuration here cannot cancel the OS request and causes retry races.
    GNCLoggerInfo(@"Hotspot connection wait cancelled or timed out");
    return NO;
  }
  BOOL connected = attempt.connected;
  [condition unlock];

  if (connected) {
    NSString *currentSSID = [self getCurrentWifiSSIDWithCancellation:shouldStop];
    if (currentSSID != nil && ![currentSSID isEqualToString:ssid]) {
      GNCLoggerError(@"Hotspot association verification failed");
      connected = NO;
    }
  }
  if (shouldStop()) connected = NO;
  [condition lock];
  if (connected && run.active && gHotspotConsentRun == run) run.joinedSSID = ssid;
  [condition unlock];
  GNCFinishHotspotJoin(attempt, !connected);
  return connected;
#elif TARGET_OS_OSX
  // MacOS treats access to Wi-Fi SSIDs and BSSIDs as location-sensitive information, so need to
  // make sure location authorization is granted before joining a Wi-Fi network using CoreWLAN.
  CLAuthorizationStatus status;
  if (@available(macOS 11.0, *)) {
    status = _locationManager.authorizationStatus;
  } else {
    status = [CLLocationManager authorizationStatus];
  }

  if (status != kCLAuthorizationStatusAuthorizedAlways) {
    GNCLoggerError(@"Location access permission is not granted, skipping to connect to Hotspot.");
    return NO;
  }

  CWInterface *wifiInterface = [CWWiFiClient sharedWiFiClient].interface;
  if (!wifiInterface) {
    GNCLoggerError(@"Wi-Fi interface not found.");
    return NO;
  }

  NSError *error = nil;
  NSSet<CWNetwork *> *networks =
      [wifiInterface scanForNetworksWithSSID:[ssid dataUsingEncoding:NSUTF8StringEncoding]
                                       error:&error];

  if (!networks) {
    GNCLoggerError(@"Failed to scan for networks: %@", error);
    return NO;
  }

  CWNetwork *bestNetwork = nil;
  for (CWNetwork *network in networks) {
    if (bestNetwork == nil) {
      bestNetwork = network;
    } else {
      if (network.rssiValue > bestNetwork.rssiValue) {
        bestNetwork = network;
      }
    }
  }

  if (!bestNetwork) {
    GNCLoggerError(@"Failed to find network: %@", ssid);
    return NO;
  }

  for (int i = 0; i < kMaxRetryCount; ++i) {
    BOOL success = [wifiInterface associateToNetwork:bestNetwork password:password error:&error];

    if (success) {
      GNCLoggerInfo(@"Successfully connected to %@", ssid);
      return YES;
    } else {
      GNCLoggerError(@"Failed to connect to %@ at attempt %d. Error: %@", ssid, i, error);
      [NSThread sleepForTimeInterval:kConnectionTimeoutInSeconds];
    }
  }

  return NO;
#else
  GNCLoggerError(@"Not implemented");
  return NO;
#endif  // TARGET_OS_IOS
}

- (void)disconnectToWifiNetworkWithSSID:(NSString *)ssid {
#if TARGET_OS_IOS
  if (ssid.length == 0) {
    GNCLoggerError(@"SSID cannot be empty.");
    return;
  }
  NSCondition *condition = GNCHotspotJoinCondition();
  [condition lock];
  if ([gHotspotConsentRun.joinedSSID isEqualToString:ssid]) gHotspotConsentRun.joinedSSID = nil;
  [condition unlock];
  [[NEHotspotConfigurationManager sharedManager] removeConfigurationForSSID:ssid];
#elif TARGET_OS_OSX
  CWInterface *wifiInterface = [CWWiFiClient sharedWiFiClient].interface;
  if (wifiInterface && [wifiInterface.ssid isEqualToString:ssid]) {
    [wifiInterface disassociate];
  }
#else
  GNCLoggerError(@"Not implemented");
#endif  // TARGET_OS_IOS
}

- (nullable GNCNWFrameworkSocket *)connectToHost:(GNCIPv4Address *)host
                                            port:(NSInteger)port
                                    cancelSource:(nullable dispatch_source_t)cancelSource
                                           error:(NSError *_Nullable *_Nullable)error {
  // Validate host address
  if (!host.dottedRepresentation.UTF8String) {
    if (error) {
      *error = [NSError errorWithDomain:GNCNWFrameworkErrorDomain
                                   code:GNCNWFrameworkErrorUnknown
                               userInfo:nil];
    }
    GNCLoggerError(@"Invalid host address");
    return nil;
  }

  return [_nwFramework connectToHost:host
                                port:port
                   includePeerToPeer:YES
                        cancelSource:cancelSource
                               queue:_hotspot_queue
                               error:error];
}

- (NSString *)getCurrentWifiSSID {
  return [self getCurrentWifiSSIDWithCancellation:nil];
}

- (NSString *)getCurrentWifiSSIDWithCancellation:(BOOL (^_Nullable)(void))isCancelled {
#if TARGET_OS_IOS
  dispatch_semaphore_t semaphore_internal = dispatch_semaphore_create(0);
  __block NSString *networkSSID = nil;
  CLAuthorizationStatus status;

  // Request permission
  GNCLoggerDebug(@"Request Location permission");

  if (@available(iOS 14.0, *)) {
    status = _locationManager.authorizationStatus;
  } else {
    status = [CLLocationManager authorizationStatus];
  }

  if (status != kCLAuthorizationStatusAuthorizedWhenInUse &&
      status != kCLAuthorizationStatusAuthorizedAlways) {
    GNCLoggerError(@"❌ Location access permission is not granted, skipping Hotspot SSID check");
    return nil;
  }

  if (@available(iOS 14.0, *)) {
    [NEHotspotNetwork fetchCurrentWithCompletionHandler:^(NEHotspotNetwork *_Nullable network) {
      if (network) {
        networkSSID = network.SSID;
        GNCLoggerDebug(@"Current Wi-Fi association available");
      } else {
        GNCLoggerError(@"Failed to get current Wifi SSID");
      }
      dispatch_semaphore_signal(semaphore_internal);
    }];
  } else {
    NSArray<NSString *> *interfaces = CFBridgingRelease(CNCopySupportedInterfaces());
    for (NSString *interface in interfaces) {
      id info = CFBridgingRelease(CNCopyCurrentNetworkInfo((__bridge CFStringRef)(interface)));
      networkSSID = [info valueForKey:@"SSID"];
      GNCLoggerDebug(@"Current Wi-Fi association available");
    }
    dispatch_semaphore_signal(semaphore_internal);
  }

  NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + kConnectionToHostTimeoutInSeconds;
  while (dispatch_semaphore_wait(semaphore_internal,
                                 dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) != 0) {
    if ((isCancelled && isCancelled()) || NSProcessInfo.processInfo.systemUptime >= deadline) {
      return nil;
    }
  }
  return (isCancelled && isCancelled()) ? nil : networkSSID;
#elif TARGET_OS_OSX
  return [CWWiFiClient sharedWiFiClient].interface.ssid;
#else
  GNCLoggerError(@"Not implemented");
  return nil;
#endif  // TARGET_OS_IOS
}

@end

NS_ASSUME_NONNULL_END
