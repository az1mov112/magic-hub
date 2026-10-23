#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#import "MediaRemoteBridge.h"

// Закрытый фреймворк MediaRemote. С macOS 15.4 он отвечает только процессам Apple,
// поэтому эту библиотеку загружает системный /usr/bin/perl (com.apple.perl5).

typedef void (*MHRegisterFn)(dispatch_queue_t queue);
typedef void (*MHGetInfoFn)(dispatch_queue_t queue, void (^handler)(CFDictionaryRef info));
typedef void (*MHGetIsPlayingFn)(dispatch_queue_t queue, void (^handler)(Boolean playing));
typedef void (*MHGetClientFn)(dispatch_queue_t queue, void (^handler)(id client));
typedef CFStringRef (*MHClientStringFn)(id client);
typedef Boolean (*MHSendCommandFn)(int command, CFDictionaryRef options);
typedef void (*MHSetElapsedFn)(double elapsed);

static void *mhFramework = NULL;
static MHRegisterFn mhRegister = NULL;
static MHGetInfoFn mhGetInfo = NULL;
static MHGetIsPlayingFn mhGetIsPlaying = NULL;
static MHGetClientFn mhGetClient = NULL;
static MHClientStringFn mhClientBundleID = NULL;
static MHClientStringFn mhClientParentBundleID = NULL;
static MHSendCommandFn mhSendCommand = NULL;
static MHSetElapsedFn mhSetElapsed = NULL;

static dispatch_queue_t mhQueue = nil;
static NSData *mhLastArtwork = nil;
static BOOL mhPending = NO;
static dispatch_source_t mhTimer = nil;

static BOOL mh_load(void) {
    if (mhFramework != NULL) return mhGetInfo != NULL;
    mhFramework = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    if (mhFramework == NULL) return NO;
    mhRegister = (MHRegisterFn)dlsym(mhFramework, "MRMediaRemoteRegisterForNowPlayingNotifications");
    mhGetInfo = (MHGetInfoFn)dlsym(mhFramework, "MRMediaRemoteGetNowPlayingInfo");
    mhGetIsPlaying = (MHGetIsPlayingFn)dlsym(mhFramework, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    mhGetClient = (MHGetClientFn)dlsym(mhFramework, "MRMediaRemoteGetNowPlayingClient");
    mhClientBundleID = (MHClientStringFn)dlsym(mhFramework, "MRNowPlayingClientGetBundleIdentifier");
    mhClientParentBundleID = (MHClientStringFn)dlsym(mhFramework, "MRNowPlayingClientGetParentAppBundleIdentifier");
    mhSendCommand = (MHSendCommandFn)dlsym(mhFramework, "MRMediaRemoteSendCommand");
    mhSetElapsed = (MHSetElapsedFn)dlsym(mhFramework, "MRMediaRemoteSetElapsedTime");
    return mhGetInfo != NULL;
}

static void mh_write_json(NSDictionary *object) {
    if (![NSJSONSerialization isValidJSONObject:object]) return;
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:&error];
    if (data == nil) return;
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void mh_put_string(NSMutableDictionary *out, NSString *key, id value) {
    if ([value isKindOfClass:[NSString class]]) out[key] = value;
}

static void mh_put_number(NSMutableDictionary *out, NSString *key, id value) {
    if ([value isKindOfClass:[NSNumber class]]) {
        double v = [value doubleValue];
        if (isfinite(v)) out[key] = @(v);
    }
}

static void mh_finish(NSDictionary *info, BOOL playing, NSString *bundleID, NSString *parentBundleID) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    if (info != nil) {
        mh_put_string(out, @"title", info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
        mh_put_string(out, @"artist", info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
        mh_put_string(out, @"album", info[@"kMRMediaRemoteNowPlayingInfoAlbum"]);
        mh_put_number(out, @"duration", info[@"kMRMediaRemoteNowPlayingInfoDuration"]);
        mh_put_number(out, @"elapsed", info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]);
        mh_put_number(out, @"playbackRate", info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]);

        id ts = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
        if ([ts isKindOfClass:[NSDate class]]) {
            out[@"timestamp"] = @([(NSDate *)ts timeIntervalSince1970]);
        } else {
            out[@"timestamp"] = @([[NSDate date] timeIntervalSince1970]);
        }

        id art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        if ([art isKindOfClass:[NSData class]] && [(NSData *)art length] > 0) {
            if (mhLastArtwork != nil && [mhLastArtwork isEqualToData:(NSData *)art]) {
                out[@"artworkUnchanged"] = @YES;
            } else {
                mhLastArtwork = (NSData *)art;
                out[@"artwork"] = [(NSData *)art base64EncodedStringWithOptions:0];
            }
        } else {
            mhLastArtwork = nil;
        }
    } else {
        mhLastArtwork = nil;
        out[@"timestamp"] = @([[NSDate date] timeIntervalSince1970]);
    }
    out[@"isPlaying"] = @(playing ? YES : NO);
    if (bundleID.length > 0) out[@"bundleId"] = bundleID;
    if (parentBundleID.length > 0) out[@"parentBundleId"] = parentBundleID;
    mh_write_json(out);
}

static void mh_emit(void) {
    if (mhGetInfo == NULL) return;
    mhGetInfo(mhQueue, ^(CFDictionaryRef infoRef) {
        NSDictionary *info = infoRef != NULL ? [(__bridge NSDictionary *)infoRef copy] : nil;
        NSNumber *rate = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
        BOOL rateSaysPlaying = [rate isKindOfClass:[NSNumber class]] && [rate doubleValue] > 0;

        void (^withClient)(BOOL) = ^(BOOL playing) {
            if (mhGetClient == NULL) {
                mh_finish(info, playing, nil, nil);
                return;
            }
            mhGetClient(mhQueue, ^(id client) {
                NSString *bundleID = nil;
                NSString *parentID = nil;
                if (client != nil && mhClientBundleID != NULL) {
                    CFStringRef s = mhClientBundleID(client);
                    if (s != NULL) bundleID = [(__bridge NSString *)s copy];
                }
                if (client != nil && mhClientParentBundleID != NULL) {
                    CFStringRef s = mhClientParentBundleID(client);
                    if (s != NULL) parentID = [(__bridge NSString *)s copy];
                }
                mh_finish(info, playing, bundleID, parentID);
            });
        };

        if (mhGetIsPlaying != NULL) {
            mhGetIsPlaying(mhQueue, ^(Boolean playing) {
                withClient(playing ? YES : NO);
            });
        } else {
            withClient(rateSaysPlaying);
        }
    });
}

static void mh_schedule(void) {
    dispatch_async(mhQueue, ^{
        if (mhPending) return;
        mhPending = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)), mhQueue, ^{
            mhPending = NO;
            mh_emit();
        });
    });
}

void mh_stream(void *a, void *b) {
    (void)a;
    (void)b;
    @autoreleasepool {
        if (!mh_load()) {
            fprintf(stderr, "MediaRemote недоступен\n");
            exit(2);
        }
        mhQueue = dispatch_queue_create("app.magichub.nowplaying", DISPATCH_QUEUE_SERIAL);
        if (mhRegister != NULL) mhRegister(mhQueue);

        NSArray<NSString *> *names = @[
            @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationClientStateDidChange",
            @"kMRNowPlayingPlaybackQueueChangedNotification",
            @"kMRPlaybackQueueContentItemsChangedNotification"
        ];
        for (NSString *name in names) {
            [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
                (void)note;
                mh_schedule();
            }];
        }

        // Раз в 10 с — сверка состояния и выход, если приложение-родитель закрылось.
        mhTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, mhQueue);
        dispatch_source_set_timer(mhTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), (uint64_t)(10 * NSEC_PER_SEC), (uint64_t)(1 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(mhTimer, ^{
            if (getppid() == 1) exit(0);
            mh_emit();
        });
        dispatch_resume(mhTimer);

        mh_schedule();
    }
    CFRunLoopRun();
    exit(0);
}

void mh_send(void *a, void *b) {
    (void)a;
    (void)b;
    @autoreleasepool {
        if (mh_load()) {
            const char *seek = getenv("MH_SEEK");
            if (seek != NULL && mhSetElapsed != NULL) {
                mhSetElapsed(atof(seek));
            }
            const char *command = getenv("MH_COMMAND");
            if (command != NULL && mhSendCommand != NULL) {
                mhSendCommand(atoi(command), NULL);
            }
        }
    }
    // Даём системе доставить команду и выходим, не возвращаясь в perl.
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.3, false);
    exit(0);
}
