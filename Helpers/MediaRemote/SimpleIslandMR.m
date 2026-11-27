// SimpleIslandMR — маленькая библиотека «что сейчас играет» для модуля «Медиа» SimpleIsland.
//
// Зачем: с macOS 15.4 MediaRemote отдаёт данные только процессам Apple (bundle id com.apple.*).
// /usr/bin/perl — платформенный бинарник Apple: perl грузит эту библиотеку (DynaLoader) и зовёт
// simpleisland_mr_run(), которая уже работает «как perl» (docs/TECH.md §1).
//
// Режим — переменная окружения SIMPLEISLAND_MR_MODE:
//   stream (по умолчанию) — JSON-строки в stdout на каждое изменение; команды — строками в stdin:
//                           play | pause | toggle | next | prev | stop | seek <сек> | speed <x>
//                           sendto <bundle id> <номер команды> — команда конкретному приложению, а не текущему
//                           Now Playing (медиаклавиши «последнему музыкальному», MRMediaRemoteSendCommandToApp)
//                           artwork — переслать данные обложки (строка "artwork"), даже если id не менялся
//                           конец stdin (родитель закрыл трубу или умер) → выход 0.
//   get                   — одна строка состояния и выход.
//   probe                 — какие символы MediaRemote нашлись (для самотеста), выход.
//   thumb                 — самотест: уменьшить картинку из файла $SIMPLEISLAND_MR_THUMB, как обложку, и выйти.
//
// Протокол stdout (одна строка — один JSON):
//   {"type":"now","playing":bool,"pid":N,"bundle":"…","parentBundle":"…","info":{Title,Artist,Album,Duration,
//    ElapsedTime,PlaybackRate,Timestamp(unix с),…},"artworkId":"…"}      info пустой — никто не играет
//   {"type":"artwork","id":"…","mime":"image/jpeg","data":"base64"}       только когда обложка сменилась; картинка
//                           уменьшена здесь же (ImageIO, ≤ 600 px, JPEG) — строка сотни КБ, а не десятки МБ
//                           base64 исходного PNG; не уменьшилась и больше 2 МБ — не шлём (id — по исходным байтам)
//   {"type":"error","message":"…"}
//   {"type":"caps","sendToApp":bool}    первой строкой режима stream: что умеет эта система
//
// Строка "now" в режиме stream выводится, только если что-то изменилось по существу (см. shouldEmit): Chrome
// присылает уведомление раз в секунду, в котором меняются лишь Timestamp/CurrentPlaybackDate/ContentItemIdentifier,
// а через раз — без самой обложки. Если ElapsedTime стоит на месте дольше 2,5 с при растущем Timestamp, трек
// считается на паузе: "playing":false, "stalled":true, PlaybackRate 0 (проверено 14.11.2026 на Chrome).
//
// Сборка: scripts/build-media-helper.sh (clang из Command Line Tools, arm64 + x86_64). Код свой.

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <unistd.h>

typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetBoolFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*MRGetClientFn)(dispatch_queue_t, void (^)(id));
typedef CFStringRef (*MRClientStringFn)(id);
typedef Boolean (*MRSendCommandFn)(int, CFDictionaryRef);
typedef void (*MRSetElapsedFn)(double);
// MRMediaRemoteSendCommandToApp — сигнатура по разбору чужих заголовков, НЕ по документации [догадка, 15.11]:
// (команда, опции, origin, bundle id, флаги, очередь, completion). Зовём с origin/очередью/completion = NULL: если
// настоящая сигнатура короче на «флаги» (6 аргументов), на места очереди и completion всё равно придут NULL — без
// вызова мусора как блока. Не подтвердилось вживую — Swift-сторона выключает `sendto` после падения помощника.
typedef Boolean (*MRSendToAppFn)(int, CFDictionaryRef, void *, CFStringRef, int, void *, void *);

static void *gMR;
static MRRegisterFn gRegister;
static MRGetInfoFn gGetInfo;
static MRGetBoolFn gGetIsPlaying;
static MRGetPIDFn gGetPID;
static MRGetClientFn gGetClient;
static MRClientStringFn gClientBundle;
static MRClientStringFn gClientParentBundle;
static MRSendCommandFn gSend;
static MRSetElapsedFn gSetElapsed;
static MRSendToAppFn gSendToApp;

static dispatch_queue_t gQueue;
static NSString *gLastArtworkId;
// Обложка, которую не удалось уменьшить (и она слишком велика): не пробовать заново на каждом уведомлении.
static NSString *gSkippedArtworkId;
static BOOL gPending;
static uint64_t gGeneration;
static dispatch_source_t gStdinSource;

// Последняя выведенная строка "now" (только gQueue): для отсева повторов.
static BOOL gHaveLast;
static NSString *gLastSig, *gLastKey, *gLastLineArtworkId;
static double gLastElapsed, gLastTs, gLastRate;
static BOOL gLastPlaying;
static BOOL gForceNext;
// Застывшая позиция: тот же трек, тот же ElapsedTime с момента gStallSince (по Timestamp источника).
static NSString *gStallKey;
static double gStallElapsed, gStallSince;

static void emit(NSDictionary *obj) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!d) return;
    fwrite(d.bytes, 1, d.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void emitError(NSString *msg) { emit(@{@"type": @"error", @"message": msg ?: @""}); }

static BOOL loadMediaRemote(void) {
    gMR = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!gMR) return NO;
    gRegister = (MRRegisterFn)dlsym(gMR, "MRMediaRemoteRegisterForNowPlayingNotifications");
    gGetInfo = (MRGetInfoFn)dlsym(gMR, "MRMediaRemoteGetNowPlayingInfo");
    gGetIsPlaying = (MRGetBoolFn)dlsym(gMR, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    gGetPID = (MRGetPIDFn)dlsym(gMR, "MRMediaRemoteGetNowPlayingApplicationPID");
    gGetClient = (MRGetClientFn)dlsym(gMR, "MRMediaRemoteGetNowPlayingClient");
    gClientBundle = (MRClientStringFn)dlsym(gMR, "MRNowPlayingClientGetBundleIdentifier");
    gClientParentBundle = (MRClientStringFn)dlsym(gMR, "MRNowPlayingClientGetParentAppBundleIdentifier");
    gSend = (MRSendCommandFn)dlsym(gMR, "MRMediaRemoteSendCommand");
    gSetElapsed = (MRSetElapsedFn)dlsym(gMR, "MRMediaRemoteSetElapsedTime");
    gSendToApp = (MRSendToAppFn)dlsym(gMR, "MRMediaRemoteSendCommandToApp");
    return gGetInfo != NULL;
}

/// FNV-1a по всем байтам: -[NSData hash] смотрит только на начало данных.
static NSString *dataId(NSData *d) {
    uint64_t h = 1469598103934665603ULL;
    const uint8_t *p = d.bytes;
    for (NSUInteger i = 0; i < d.length; i++) { h ^= p[i]; h *= 1099511628211ULL; }
    return [NSString stringWithFormat:@"%016llx-%lu", h, (unsigned long)d.length];
}

/// Обложка для приложения: миниатюра ImageIO ≤ 600 px (JPEG 0,85), если исходник больше по стороне или тяжелее
/// 512 КБ; иначе — как есть. nil — не уменьшилась, а исходник больше 2 МБ (такую строку приложение не примет).
static NSData *artworkForApp(NSData *src, NSString **mime) {
    const int maxPx = 600;
    NSData *out = nil;
    CGImageSourceRef is = CGImageSourceCreateWithData((__bridge CFDataRef)src, NULL);
    if (is) {
        int w = 0, h = 0;
        CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(is, 0, NULL);
        if (props) {
            CFNumberRef nw = CFDictionaryGetValue(props, kCGImagePropertyPixelWidth);
            CFNumberRef nh = CFDictionaryGetValue(props, kCGImagePropertyPixelHeight);
            if (nw) CFNumberGetValue(nw, kCFNumberIntType, &w);
            if (nh) CFNumberGetValue(nh, kCFNumberIntType, &h);
            CFRelease(props);
        }
        if (w > 0 && h > 0 && w <= maxPx && h <= maxPx && src.length <= 512 * 1024) {
            CFRelease(is);
            return src;
        }
        NSDictionary *opts = @{(id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                               (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
                               (id)kCGImageSourceShouldCacheImmediately: @NO,
                               (id)kCGImageSourceThumbnailMaxPixelSize: @(maxPx)};
        CGImageRef thumb = CGImageSourceCreateThumbnailAtIndex(is, 0, (__bridge CFDictionaryRef)opts);
        if (thumb) {
            NSMutableData *jpeg = [NSMutableData data];
            CGImageDestinationRef d = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)jpeg, CFSTR("public.jpeg"), 1, NULL);
            if (d) {
                CGImageDestinationAddImage(d, thumb, (__bridge CFDictionaryRef)@{(id)kCGImageDestinationLossyCompressionQuality: @0.85});
                if (CGImageDestinationFinalize(d) && jpeg.length > 0) { out = jpeg; *mime = @"image/jpeg"; }
                CFRelease(d);
            }
            CGImageRelease(thumb);
        }
        CFRelease(is);
    }
    if (!out && src.length <= 2 * 1024 * 1024) out = src;
    return out;
}

/// Значение словаря MediaRemote → JSON (строки, числа, даты; остальное пропускаем).
static id jsonValue(id v) {
    if ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]]) return v;
    if ([v isKindOfClass:[NSDate class]]) return @([(NSDate *)v timeIntervalSince1970]);
    return nil;
}

/// Собрать состояние (info + isPlaying + pid + client) и вызвать done на gQueue.
static void fetchState(void (^done)(NSDictionary *line, NSDictionary *artwork)) {
    dispatch_group_t g = dispatch_group_create();
    __block NSDictionary *rawInfo = nil;
    __block BOOL playing = NO;
    __block int pid = 0;
    __block NSString *bundle = nil, *parent = nil;

    dispatch_group_enter(g);
    gGetInfo(gQueue, ^(CFDictionaryRef info) {
        rawInfo = info ? [(__bridge NSDictionary *)info copy] : nil;
        dispatch_group_leave(g);
    });
    if (gGetIsPlaying) {
        dispatch_group_enter(g);
        gGetIsPlaying(gQueue, ^(Boolean p) { playing = p; dispatch_group_leave(g); });
    }
    if (gGetPID) {
        dispatch_group_enter(g);
        gGetPID(gQueue, ^(int p) { pid = p; dispatch_group_leave(g); });
    }
    if (gGetClient && gClientBundle) {
        dispatch_group_enter(g);
        gGetClient(gQueue, ^(id client) {
            if (client) {
                CFStringRef b = gClientBundle(client);
                if (b) bundle = [(__bridge NSString *)b copy];
                if (gClientParentBundle) {
                    CFStringRef pb = gClientParentBundle(client);
                    if (pb) parent = [(__bridge NSString *)pb copy];
                }
            }
            dispatch_group_leave(g);
        });
    }
    dispatch_group_notify(g, gQueue, ^{
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        NSDictionary *artwork = nil;
        NSString *artworkId = nil;
        NSString *prefix = @"kMRMediaRemoteNowPlayingInfo";
        for (id key in rawInfo) {
            if (![key isKindOfClass:[NSString class]]) continue;
            NSString *k = [key hasPrefix:prefix] ? [key substringFromIndex:prefix.length] : key;
            id v = rawInfo[key];
            if ([k isEqualToString:@"ArtworkData"] && [v isKindOfClass:[NSData class]] && [(NSData *)v length] > 0) {
                artworkId = dataId(v);
                if (![artworkId isEqualToString:gLastArtworkId] && ![artworkId isEqualToString:gSkippedArtworkId]) {
                    NSString *mime = rawInfo[@"kMRMediaRemoteNowPlayingInfoArtworkMIMEType"];
                    if (![mime isKindOfClass:[NSString class]]) mime = @"";
                    NSData *small = artworkForApp(v, &mime);
                    if (small) {
                        artwork = @{@"type": @"artwork", @"id": artworkId, @"mime": mime,
                                    @"data": [small base64EncodedStringWithOptions:0]};
                    } else {
                        gSkippedArtworkId = artworkId;
                    }
                }
                continue;
            }
            id j = jsonValue(v);
            if (j) info[k] = j;
        }
        NSMutableDictionary *line = [@{@"type": @"now", @"playing": @(playing), @"pid": @(pid), @"info": info} mutableCopy];
        if (bundle) line[@"bundle"] = bundle;
        if (parent) line[@"parentBundle"] = parent;
        if (artworkId) line[@"artworkId"] = artworkId;
        done(line, artwork);
    });
}

static double num(id v, double def) { return [v isKindOfClass:[NSNumber class]] ? [v doubleValue] : def; }

/// Поля, которые источник меняет без смены сути (Chrome — каждую секунду).
static NSSet *volatileKeys(void) {
    static NSSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[@"Timestamp", @"ElapsedTime", @"CurrentPlaybackDate", @"ContentItemIdentifier",
                                  @"ArtworkIdentifier", @"ArtworkDataWidth", @"ArtworkDataHeight", @"ArtworkMIMEType"]];
    });
    return s;
}

/// Поправить строку (обложка того же трека, застывшая позиция) и решить, выводить ли её.
static BOOL shouldEmit(NSMutableDictionary *line) {
    NSMutableDictionary *info = [line[@"info"] mutableCopy];
    NSString *key = [NSString stringWithFormat:@"%@|%@|%@|%@", line[@"parentBundle"] ?: line[@"bundle"] ?: @"",
                     info[@"Title"] ?: @"", info[@"Artist"] ?: @"", info[@"Album"] ?: @""];
    // Chrome через раз присылает строку без ArtworkData — у того же трека оставляем прежнюю обложку.
    if (!line[@"artworkId"] && gLastLineArtworkId && [key isEqualToString:gLastKey]) line[@"artworkId"] = gLastLineArtworkId;

    BOOL playing = [line[@"playing"] boolValue];
    double el = num(info[@"ElapsedTime"], NAN), ts = num(info[@"Timestamp"], NAN), dur = num(info[@"Duration"], 0);
    BOOL stalled = NO;
    if (playing && !isnan(el) && !isnan(ts) && dur > 0) {
        if ([key isEqualToString:gStallKey] && fabs(el - gStallElapsed) < 0.001) {
            stalled = ts - gStallSince >= 2.5;
        } else {
            gStallKey = key; gStallElapsed = el; gStallSince = ts;
        }
    } else {
        gStallKey = nil;
    }
    if (stalled) {
        playing = NO;
        line[@"playing"] = @NO;
        line[@"stalled"] = @YES;
        info[@"PlaybackRate"] = @0;
    }
    line[@"info"] = info;

    NSMutableDictionary *sigInfo = [info mutableCopy];
    [sigInfo removeObjectsForKeys:volatileKeys().allObjects];
    NSMutableDictionary *sigObj = [line mutableCopy];
    sigObj[@"info"] = sigInfo;
    NSData *sd = [NSJSONSerialization dataWithJSONObject:sigObj options:NSJSONWritingSortedKeys error:nil];
    NSString *sig = sd ? [[NSString alloc] initWithData:sd encoding:NSUTF8StringEncoding] : @"";

    double rate = num(info[@"PlaybackRate"], playing ? 1 : 0);
    BOOL emitIt = gForceNext || !gHaveLast || ![sig isEqualToString:gLastSig];
    if (!emitIt && !isnan(el) && !isnan(ts)) {
        // Позиция разошлась с той, что Swift-сторона досчитает сама (перемотка) — вывести.
        // Тот же ElapsedTime при игре — ждём вердикта «застыло», не дёргаем позицию назад.
        // Порог был 1 с (до 15.11): поправки меньше секунды не доходили, и строки текста расходились со звуком до
        // секунды. Теперь 0,15 с — источник уточняет позицию редко (на старте, после буферизации), не каждую секунду.
        // Тот же ElapsedTime у самого начала трека с новой меткой — плеер начал играть позже, чем сообщил
        // (буферизация): тоже вывести, иначе позиция убегает вперёд на время буферизации.
        BOOL sameElapsed = fabs(el - gLastElapsed) < 0.001;
        double predicted = gLastElapsed + (gLastPlaying ? (ts - gLastTs) * (gLastRate > 0 ? gLastRate : 1) : 0);
        BOOL startRestamp = playing && sameElapsed && el < 1.0 && ts - gLastTs > 0.15 && ts - gLastTs < 2.5;
        if ((!(playing && sameElapsed) || startRestamp) && fabs(predicted - el) > 0.15) emitIt = YES;
    }
    gForceNext = NO;
    if (!emitIt) return NO;
    gHaveLast = YES;
    gLastSig = sig;
    gLastKey = key;
    gLastLineArtworkId = line[@"artworkId"];
    gLastElapsed = isnan(el) ? 0 : el;
    gLastTs = isnan(ts) ? [NSDate date].timeIntervalSince1970 : ts;
    gLastRate = rate;
    gLastPlaying = playing;
    return YES;
}

static void publish(void) {
    fetchState(^(NSDictionary *line, NSDictionary *artwork) {
        // Обложка — раньше строки состояния: Swift-сторона сразу находит её по artworkId.
        if (artwork) { gLastArtworkId = artwork[@"id"]; emit(artwork); }
        NSMutableDictionary *m = [line mutableCopy];
        if (shouldEmit(m)) emit(m);
    });
}

/// Пачку уведомлений склеиваем в одно чтение (80 мс).
static void schedulePublish(void) {
    if (gPending) return;
    gPending = YES;
    uint64_t gen = ++gGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), gQueue, ^{
        if (gen != gGeneration) return;
        gPending = NO;
        publish();
    });
}

static void runCommand(NSString *line) {
    NSArray *parts = [[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                      componentsSeparatedByString:@" "];
    if (parts.count == 0 || [parts[0] length] == 0) return;
    NSString *cmd = parts[0];
    // После команды — следующая строка состояния обязательно (подтверждение для Swift-стороны).
    gForceNext = YES;
    double arg = parts.count > 1 ? [parts[1] doubleValue] : 0;
    // Номера команд MRMediaRemoteCommand: 0 play, 1 pause, 2 toggle, 3 stop, 4 next, 5 prev, 19 скорость.
    NSDictionary *codes = @{@"play": @0, @"pause": @1, @"toggle": @2, @"stop": @3, @"next": @4, @"prev": @5};
    if (codes[cmd]) {
        if (gSend) gSend([codes[cmd] intValue], NULL); else emitError(@"no MRMediaRemoteSendCommand");
    } else if ([cmd isEqualToString:@"seek"]) {
        if (gSetElapsed) gSetElapsed(arg); else emitError(@"no MRMediaRemoteSetElapsedTime");
    } else if ([cmd isEqualToString:@"speed"]) {
        if (!gSend || arg <= 0) { emitError(@"speed unavailable"); return; }
        CFStringRef *keyPtr = (CFStringRef *)dlsym(gMR, "kMRMediaRemoteOptionPlaybackRate");
        NSString *key = keyPtr && *keyPtr ? (__bridge NSString *)*keyPtr : @"kMRMediaRemoteOptionPlaybackRate";
        gSend(19, (__bridge CFDictionaryRef)@{key: @(arg)});
    } else if ([cmd isEqualToString:@"sendto"]) {
        // sendto <bundle> <код>: 2 toggle, 4 next, 5 prev, 8/9 начать/закончить «вперёд», 10/11 — «назад».
        if (!gSendToApp || parts.count < 3) { emitError(@"sendto unavailable"); return; }
        int code = [parts[2] intValue];
        if (!(code == 2 || code == 4 || code == 5 || (code >= 8 && code <= 11))) { emitError(@"sendto: bad code"); return; }
        gSendToApp(code, NULL, NULL, (__bridge CFStringRef)parts[1], 0, NULL, NULL);
    } else if ([cmd isEqualToString:@"refresh"]) {
        schedulePublish();
        return;
    } else if ([cmd isEqualToString:@"artwork"]) {
        // Переслать обложку, даже если id тот же: у треков одного альбома байты одинаковые, и Swift-сторона могла
        // её потерять между строками (16.11). Частоту ограничивает Swift-сторона.
        gLastArtworkId = nil;
        gSkippedArtworkId = nil;
        schedulePublish();
        return;
    } else {
        emitError([@"unknown command: " stringByAppendingString:cmd]);
        return;
    }
    schedulePublish();
}

static void watchStdin(void) {
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, gQueue);
    __block NSMutableData *buf = [NSMutableData data];
    dispatch_source_set_event_handler(src, ^{
        char tmp[1024];
        ssize_t n = read(STDIN_FILENO, tmp, sizeof tmp);
        if (n <= 0) exit(0);  // родитель закрыл трубу или умер
        [buf appendBytes:tmp length:(NSUInteger)n];
        while (1) {
            NSRange r = [buf rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0, buf.length)];
            if (r.location == NSNotFound) break;
            NSString *line = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, r.location)]
                                                   encoding:NSUTF8StringEncoding];
            [buf replaceBytesInRange:NSMakeRange(0, r.location + 1) withBytes:NULL length:0];
            if (line) runCommand(line);
        }
    });
    dispatch_resume(src);
    gStdinSource = src;
}

__attribute__((visibility("default")))
void simpleisland_mr_run(void) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_DFL);
        const char *m = getenv("SIMPLEISLAND_MR_MODE");
        NSString *mode = m ? @(m) : @"stream";
        if ([mode isEqualToString:@"thumb"]) {
            // Самотест: уменьшение обложки (файл — SIMPLEISLAND_MR_THUMB), без MediaRemote.
            const char *path = getenv("SIMPLEISLAND_MR_THUMB");
            NSData *src = path ? [NSData dataWithContentsOfFile:@(path)] : nil;
            NSString *mime = @"";
            NSData *out = src ? artworkForApp(src, &mime) : nil;
            int w = 0, h = 0;
            if (out) {
                CGImageSourceRef is = CGImageSourceCreateWithData((__bridge CFDataRef)out, NULL);
                CFDictionaryRef props = is ? CGImageSourceCopyPropertiesAtIndex(is, 0, NULL) : NULL;
                if (props) {
                    CFNumberRef nw = CFDictionaryGetValue(props, kCGImagePropertyPixelWidth);
                    CFNumberRef nh = CFDictionaryGetValue(props, kCGImagePropertyPixelHeight);
                    if (nw) CFNumberGetValue(nw, kCFNumberIntType, &w);
                    if (nh) CFNumberGetValue(nh, kCFNumberIntType, &h);
                    CFRelease(props);
                }
                if (is) CFRelease(is);
            }
            emit(@{@"type": @"thumb", @"in": @(src.length), @"out": @(out.length), @"mime": mime ?: @"",
                   @"w": @(w), @"h": @(h), @"b64": @((out.length + 2) / 3 * 4)});
            exit(0);
        }
        if (!loadMediaRemote()) {
            emitError(@"MediaRemote not available");
            exit(3);
        }
        gQueue = dispatch_queue_create("simpleisland.mr", DISPATCH_QUEUE_SERIAL);

        if ([mode isEqualToString:@"probe"]) {
            emit(@{@"type": @"probe", @"register": @(gRegister != NULL), @"info": @(gGetInfo != NULL),
                   @"isPlaying": @(gGetIsPlaying != NULL), @"pid": @(gGetPID != NULL),
                   @"client": @(gGetClient != NULL && gClientBundle != NULL), @"send": @(gSend != NULL),
                   @"seek": @(gSetElapsed != NULL), @"sendToApp": @(gSendToApp != NULL),
                   @"rateKey": @(dlsym(gMR, "kMRMediaRemoteOptionPlaybackRate") != NULL)});
            exit(0);
        }
        if ([mode isEqualToString:@"get"]) {
            fetchState(^(NSDictionary *line, NSDictionary *artwork) {
                if (artwork && getenv("SIMPLEISLAND_MR_ARTWORK")) emit(artwork);
                emit(line);
                exit(0);
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                emitError(@"timeout");
                exit(4);
            });
            dispatch_main();
        }

        if (gRegister) gRegister(gQueue);
        NSArray *names = @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                           @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                           @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                           @"kMRMediaRemoteNowPlayingApplicationClientStateDidChange",
                           @"kMRMediaRemoteNowPlayingPlaybackQueueChangedNotification",
                           @"kMRMediaRemotePlaybackStateDidChangeNotification",
                           @"kMRPlaybackQueueContentItemsChangedNotification"];
        for (NSString *n in names) {
            [[NSNotificationCenter defaultCenter] addObserverForName:n object:nil queue:nil
                                                          usingBlock:^(NSNotification *note) {
                dispatch_async(gQueue, ^{ schedulePublish(); });
            }];
        }
        emit(@{@"type": @"caps", @"sendToApp": @(gSendToApp != NULL)});
        watchStdin();
        dispatch_async(gQueue, ^{ publish(); });
        // Уведомления MediaRemote приходят через главный run loop.
        CFRunLoopRun();
        exit(0);
    }
}
