// NowPlayingBridge: runs inside /usr/bin/perl (see nowplaying.pl) and talks to MediaRemote.
//
// Protocol
//   stdout: one JSON object per line, sent whenever now-playing state changes:
//     {"pid":123,"playing":true,"title":"…","artist":"…","album":"…",
//      "duration":215.0,"elapsed":12.3,"rate":1.0,"timestamp":1731600000.0 (when elapsed was sampled),
//      "hasArtwork":true,"artwork":"<base64, only when the image changed>","artworkMime":"image/jpeg"}
//   stdin: one command per line: play | pause | toggle | next | previous | seek <seconds> | refresh
//   Exits when stdin closes (the app quit).

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>

typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*MRGetIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef Boolean (*MRSendCommandFn)(int, CFDictionaryRef);
typedef void (*MRSetElapsedFn)(double);

static MRRegisterFn MRRegister;
static MRGetInfoFn MRGetInfo;
static MRGetPIDFn MRGetPID;
static MRGetIsPlayingFn MRGetIsPlaying;
static MRSendCommandFn MRSendCommand;
static MRSetElapsedFn MRSetElapsed;

enum { kCmdPlay = 0, kCmdPause = 1, kCmdToggle = 2, kCmdNext = 4, kCmdPrevious = 5 };

static NSUInteger lastArtworkHash = 0;
static BOOL lastHadArtwork = NO;
static NSString *lastLine = nil;
static BOOL refreshScheduled = NO;

static void emit(NSDictionary *payload) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!json) return;
    NSString *line = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    if ([line isEqualToString:lastLine]) return; // drop exact duplicates
    lastLine = line;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void refresh(void) {
    MRGetPID(dispatch_get_main_queue(), ^(int pid) {
        MRGetIsPlaying(dispatch_get_main_queue(), ^(Boolean playing) {
            MRGetInfo(dispatch_get_main_queue(), ^(CFDictionaryRef ref) {
                NSDictionary *info = (__bridge NSDictionary *)ref;
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                out[@"pid"] = @(pid);
                out[@"playing"] = playing ? (__bridge id)kCFBooleanTrue : (__bridge id)kCFBooleanFalse;

                id title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
                id artist = info[@"kMRMediaRemoteNowPlayingInfoArtist"];
                id album = info[@"kMRMediaRemoteNowPlayingInfoAlbum"];
                if ([title isKindOfClass:NSString.class]) out[@"title"] = title;
                if ([artist isKindOfClass:NSString.class]) out[@"artist"] = artist;
                if ([album isKindOfClass:NSString.class]) out[@"album"] = album;

                id duration = info[@"kMRMediaRemoteNowPlayingInfoDuration"];
                id elapsed = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"];
                id rate = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
                id timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                if ([duration isKindOfClass:NSNumber.class]) out[@"duration"] = duration;
                if ([elapsed isKindOfClass:NSNumber.class]) out[@"elapsed"] = elapsed;
                if ([rate isKindOfClass:NSNumber.class]) out[@"rate"] = rate;
                if ([timestamp isKindOfClass:NSDate.class]) {
                    out[@"timestamp"] = @([(NSDate *)timestamp timeIntervalSince1970]);
                }

                id artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                BOOL hasArtwork = [artwork isKindOfClass:NSData.class] && [(NSData *)artwork length] > 0;
                out[@"hasArtwork"] = hasArtwork ? (__bridge id)kCFBooleanTrue : (__bridge id)kCFBooleanFalse;
                if (hasArtwork) {
                    NSData *data = artwork;
                    NSUInteger hash = data.length ^ (data.hash << 1);
                    if (!lastHadArtwork || hash != lastArtworkHash) {
                        out[@"artwork"] = [data base64EncodedStringWithOptions:0];
                        id mime = info[@"kMRMediaRemoteNowPlayingInfoArtworkMIMEType"];
                        if ([mime isKindOfClass:NSString.class]) out[@"artworkMime"] = mime;
                        lastArtworkHash = hash;
                    }
                }
                lastHadArtwork = hasArtwork;
                emit(out);
            });
        });
    });
}

/// Coalesces bursts of MediaRemote notifications into one refresh.
static void scheduleRefresh(void) {
    if (refreshScheduled) return;
    refreshScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        refreshScheduled = NO;
        refresh();
    });
}

static void handleCommand(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSString *cmd = parts.firstObject.lowercaseString;
    if ([cmd isEqualToString:@"play"]) MRSendCommand(kCmdPlay, NULL);
    else if ([cmd isEqualToString:@"pause"]) MRSendCommand(kCmdPause, NULL);
    else if ([cmd isEqualToString:@"toggle"]) MRSendCommand(kCmdToggle, NULL);
    else if ([cmd isEqualToString:@"next"]) MRSendCommand(kCmdNext, NULL);
    else if ([cmd isEqualToString:@"previous"]) MRSendCommand(kCmdPrevious, NULL);
    else if ([cmd isEqualToString:@"seek"] && parts.count > 1) MRSetElapsed(parts[1].doubleValue);
    else if ([cmd isEqualToString:@"refresh"]) { lastLine = nil; lastHadArtwork = NO; }
    scheduleRefresh();
}

static BOOL loadMediaRemote(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!h) return NO;
    MRRegister = dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
    MRGetInfo = dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    MRGetPID = dlsym(h, "MRMediaRemoteGetNowPlayingApplicationPID");
    MRGetIsPlaying = dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    MRSendCommand = dlsym(h, "MRMediaRemoteSendCommand");
    MRSetElapsed = dlsym(h, "MRMediaRemoteSetElapsedTime");
    return MRRegister && MRGetInfo && MRGetPID && MRGetIsPlaying && MRSendCommand && MRSetElapsed;
}

/// Entry point, installed as a perl XSUB. The perl interpreter arguments are unused.
void an_bridge_run(void *interpreter, void *cv) {
    (void)interpreter; (void)cv;
    @autoreleasepool {
        if (!loadMediaRemote()) {
            fprintf(stderr, "NowPlayingBridge: MediaRemote unavailable\n");
            exit(2);
        }
        MRRegister(dispatch_get_main_queue());

        NSArray *names = @[
            @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationClientStateDidChange",
        ];
        for (NSString *name in names) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(NSNotification *note) { scheduleRefresh(); }];
        }

        // Read commands from stdin on a background thread; exit when the app closes the pipe.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            char *buf = NULL;
            size_t cap = 0;
            while (getline(&buf, &cap, stdin) > 0) {
                NSString *line = [[NSString stringWithUTF8String:buf]
                                  stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                dispatch_async(dispatch_get_main_queue(), ^{ handleCommand(line); });
            }
            exit(0);
        });

        // Elapsed time isn't always pushed; a slow heartbeat keeps the scrubber honest after seeks.
        [NSTimer scheduledTimerWithTimeInterval:5 repeats:YES block:^(NSTimer *t) { scheduleRefresh(); }];

        scheduleRefresh();
        [NSRunLoop.mainRunLoop run];
    }
}
