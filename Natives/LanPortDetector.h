//
//  LanPortDetector.h
//  Amethyst
//
//  Minecraft "Open to LAN" port detector.
//
//  Two independent strategies are provided:
//
//  1) Log tailing (primary).  <POJAV_HOME>/latestlog.txt is polled incrementally
//     and every new line is matched against a set of patterns covering the
//     English / Simplified-Chinese / Traditional-Chinese wording used by the
//     different Minecraft versions.  This needs no entitlement and no extra
//     socket, and it is exact because the game itself prints the port.
//
//  2) Local port scan (fallback).  127.0.0.1 is probed and every port that
//     accepts a TCP connection is validated with a Minecraft Server-List-Ping
//     handshake, so only real MC listeners are reported.  Used when the log
//     never mentions a port (e.g. the log was rotated, or the launcher UI was
//     opened after the world was already published).
//
//  The previous "auto" implementation was removed because it re-scanned the
//  whole log file on every start, so a port from an *earlier* session could be
//  reported.  Both strategies here are anchored to the current session:
//  log tailing only inspects bytes appended after the anchor (and resets the
//  anchor when the file shrinks, i.e. a new game launch truncated it).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Source of the currently known port.
typedef NS_ENUM(NSInteger, LanPortSource) {
    LanPortSourceUnknown = 0,  /* no port known yet */
    LanPortSourceAuto    = 1,  /* found by log tailing or by port scan */
    LanPortSourceManual  = 2,  /* typed in by the user */
};

/// Posted on the main queue whenever a *new* port becomes known.
/// userInfo: @{ @"port": @(uint16_t), @"source": @(LanPortSource) }
extern NSString *const LanPortDetectorDidDetectPortNotification;

@interface LanPortDetector : NSObject

+ (instancetype)sharedInstance;

/// Currently known port, 0 when unknown.
@property(nonatomic, assign, readonly) uint16_t detectedPort;
@property(nonatomic, assign, readonly) LanPortSource source;
@property(nonatomic, assign, readonly, getter=isDetecting) BOOL detecting;

/// Start tailing latestlog.txt.  Repeated calls are ignored.
/// Detection stops itself as soon as a port is found.
- (void)startAutoDetection;

/// Stop tailing.  Safe to call when not detecting.
- (void)stopAutoDetection;

/// Set the port by hand.  Stops auto detection and overrides any earlier value.
- (void)setManualPort:(uint16_t)port;

/// Forget the port (keeps the detector running state untouched).
- (void)clearPort;

/// Probe 127.0.0.1 for a listening Minecraft server.
///
/// Fast ports (25565 and friends) are tried first, then the ephemeral range,
/// then -- only if nothing was found -- the remaining low range.  Every open
/// port is validated with a Server-List-Ping handshake, so the returned array
/// is normally empty or holds a single entry.
///
/// @param progress  Called on a background queue (may be nil).
/// @param completion Called on the main queue with the verified ports.
- (void)scanLocalPortsWithProgress:(void (^ _Nullable)(NSUInteger scanned, NSUInteger total))progress
                        completion:(void (^)(NSArray<NSNumber *> *ports))completion;

/// Parse a single log line.  Returns 0 when the line carries no port.
/// Exposed so callers (and tests) can feed arbitrary text.
+ (uint16_t)parsePortFromLogLine:(NSString *)line;

@end

NS_ASSUME_NONNULL_END
