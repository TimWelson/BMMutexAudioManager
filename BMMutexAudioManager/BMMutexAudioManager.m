//
//  BMMutexAudioManager.m
//  BMMutexAudioManager
//
//  Created by 李志强 on 2017/5/4.
//  Copyright © 2017年 Li Zhiqiang. All rights reserved.
//

#import "BMMutexAudioManager.h"
#import "BMAudioDownloadManager.h"
#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <MediaPlayer/MediaPlayer.h>

#define WEAKSELF() __weak __typeof(&*self) weakSelf = self

@interface BMMutexAudioManager () <AVAudioPlayerDelegate>

@property (nonatomic, strong) AVAudioPlayer *privatePlayer;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSMutableDictionary *cellStatusDictionary; //需要考虑到indexPath变了以后,直接重置dictionary！
@property (nonatomic, strong) NSIndexPath *currentPlayingIndexPath;
@property (nonatomic, strong) BMMutexAudioStatusModel *currentPlayingModel;
@property (nonatomic, strong) NSIndexPath *previousPlayingIndexPath;

@end

@implementation BMMutexAudioManager

#pragma mark - Singleton

+ (instancetype)sharedInstance {
    static BMMutexAudioManager *_instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _instance = [[self alloc] init];
    });
    return _instance;
}

#pragma mark - Public Method

- (void)clickPlayButtonWithAudioURL:(NSString *)URLString cellIndexPath:(NSIndexPath *)indexPath {
    WEAKSELF();
    [self queryStatusModelWithIndexPath:indexPath audioURL:URLString];
    if (self.cellStatusDictionary[[self generateCellKeyStringWithIndexPath:indexPath]]) {
        __block BMMutexAudioStatusModel *statusModel = self.cellStatusDictionary[[self generateCellKeyStringWithIndexPath:indexPath]];
        if (!statusModel.localPathURL) {
            statusModel.currentStatus = EBMPlayerStatusDownloading;
            [weakSelf cellStatusDidChanged:indexPath statusModel:statusModel];
            [self downloadAudioWithURL:URLString
            success:^(NSString *voiceName, EBMAudioDownloadStatus voiceDownloadStatus, NSString *voicePath) {
                if (voiceDownloadStatus == EBMAudioDownloadStatusSuccess) {
                    statusModel.currentStatus = EBMPlayerStatusStop;
                    statusModel.localPathURL = [NSURL fileURLWithPath:voicePath];
                    statusModel.duration = [weakSelf durationWithVaildURL:[NSURL fileURLWithPath:voicePath]];
                    [weakSelf cellStatusDidChanged:indexPath statusModel:statusModel];
                }
            }
            fail:^(EBMAudioDownloadStatus voiceDownloadStatus) {
                statusModel.currentStatus = EBMPlayerStatusRetryDownload;
                [weakSelf cellStatusDidChanged:indexPath statusModel:statusModel];
            }];
        } else {
            if (statusModel.duration <= 0) {
                statusModel.duration = [self durationWithVaildURL:statusModel.localPathURL];
            }
            [self playAudioWithStatusModel:statusModel indexPath:indexPath];
        }
    }
}

- (void)clickStopButtonWithCellIndexPath:(NSIndexPath *)indexPath {
    [self pauseOrStopAudioInIndexPath:indexPath status:EBMPlayerStatusStop];
}

- (void)setPlayerProgressByProgress:(float)progress cellIndexPath:(NSIndexPath *)indexPath {
    BMMutexAudioStatusModel *statusModel = [self.cellStatusDictionary objectForKey:[self generateCellKeyStringWithIndexPath:indexPath]];
    statusModel.currentProgress = progress;
    if ([self isTwoIndexPathEqual:self.currentPlayingIndexPath otherIndexPath:indexPath] && [self.privatePlayer isPlaying]) {
        [self.privatePlayer pause];
        self.privatePlayer.currentTime = self.privatePlayer.duration * progress;
        [self.privatePlayer play];
    }
}

- (BMMutexAudioStatusModel *)queryStatusModelWithIndexPath:(NSIndexPath *)indexPath audioURL:(NSString *)audioURL {
    BMMutexAudioStatusModel *statusModel = [self.cellStatusDictionary objectForKey:[self generateCellKeyStringWithIndexPath:indexPath]];
    if (!statusModel) {
        statusModel = [[BMMutexAudioStatusModel alloc] init];
        statusModel.audioURL = [NSURL URLWithString:audioURL];
        [self.cellStatusDictionary setObject:statusModel forKey:[self generateCellKeyStringWithIndexPath:indexPath]];
        NSString *localPathURL = [[BMAudioDownloadManager sharedInstance]
        voiceLocalSavePathAtVoiceName:[NSString stringWithFormat:@"%@.%@", [self generateMD5WithString:audioURL],
                                                                 [statusModel.audioURL pathExtension]]];
        if (localPathURL.length > 0) {
            statusModel.localPathURL = [NSURL fileURLWithPath:localPathURL];
            statusModel.currentStatus = EBMPlayerStatusStop;
            if (statusModel.duration <= 0) {
                statusModel.duration = [self durationWithVaildURL:statusModel.localPathURL];
            }
        } else {
            statusModel.currentStatus = EBMPlayerStatusUnDownload;
        }
        statusModel.currentProgress = 0;
    }
    return statusModel;
}

- (NSIndexPath *)getCurrentPlayingIndexPath {
    return self.currentPlayingIndexPath;
}

- (void)deleteAllDownloadedVoice {
    [[BMAudioDownloadManager sharedInstance] removeVoice];
}

- (void)releaseManager {
    [self pauseOrStopAudioInIndexPath:self.currentPlayingIndexPath status:EBMPlayerStatusStop];
    [self.cellStatusDictionary removeAllObjects];
    self.cellStatusDictionary = nil;
    self.previousPlayingIndexPath = nil;
    self.currentPlayingModel = nil;
    self.currentPlayingIndexPath = nil;
}

#pragma mark - Private Method

- (NSString *)generateCellKeyStringWithIndexPath:(NSIndexPath *)indexPath {
    NSString *keyString = @"keyString";
    if (indexPath) {
        keyString = [NSString stringWithFormat:@"%ld-%ld", indexPath.section, indexPath.row];
    }
    return keyString;
}

- (float)durationWithVaildURL:(NSURL *)vaildURL {
    AVURLAsset *audioAsset = [AVURLAsset URLAssetWithURL:vaildURL options:nil];
    CMTime audioDuration = audioAsset.duration;
    float audioDurationSeconds = CMTimeGetSeconds(audioDuration);
    return audioDurationSeconds;
}

- (void)playAudioWithStatusModel:(BMMutexAudioStatusModel *)statusModel indexPath:(NSIndexPath *)indexPath {
    if ([self isTwoIndexPathEqual:self.currentPlayingIndexPath otherIndexPath:indexPath]) {
        if ([self.privatePlayer isPlaying]) {
            [self pauseCurrentAudio];
        } else {
            [self startPlayNewAudioWithStatusModel:statusModel indexPath:indexPath];
        }
    } else {
        if ([self.privatePlayer isPlaying]) {
            [self pauseCurrentAudio];
        }
        [self startPlayNewAudioWithStatusModel:statusModel indexPath:indexPath];
    }
}

- (void)pauseCurrentAudio {
    [self pauseOrStopAudioInIndexPath:self.currentPlayingIndexPath status:EBMPlayerStatusPause];
    //[[NSNotificationCenter defaultCenter] removeObserver:self name:AVAudioSessionRouteChangeNotification object:nil];
}

- (void)startPlayNewAudioWithStatusModel:(BMMutexAudioStatusModel *)statusModel indexPath:(NSIndexPath *)indexPath {
    if (statusModel.currentStatus == EBMPlayerStatusPause || statusModel.currentStatus == EBMPlayerStatusStop) {
        self.currentPlayingIndexPath = indexPath;
        self.currentPlayingModel = statusModel;
        self.privatePlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:statusModel.localPathURL error:nil];
        self.privatePlayer.delegate = self;
        statusModel.currentStatus = EBMPlayerStatusPlaying;

        if (_timer == nil) {
            _timer = [NSTimer scheduledTimerWithTimeInterval:0.01
                                                      target:self
                                                    selector:@selector(updateProgress)
                                                    userInfo:nil
                                                     repeats:YES];
        }
        /*
         [[NSNotificationCenter defaultCenter] addObserver:self
         selector:@selector(routeChange:)
         name:AVAudioSessionRouteChangeNotification
         object:nil];*/
        self.privatePlayer.currentTime = self.privatePlayer.duration * statusModel.currentProgress;
        [self.privatePlayer play];
        [self cellStatusDidChanged:self.currentPlayingIndexPath statusModel:statusModel];
        //[[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayAndRecord error:nil];
    }
}

- (void)pauseOrStopAudioInIndexPath:(NSIndexPath *)indexPath status:(EBMPlayerStatus)status {
    if ([self isTwoIndexPathEqual:indexPath otherIndexPath:self.currentPlayingIndexPath] &&
        (status == EBMPlayerStatusStop || status == EBMPlayerStatusPause)) {
        self.previousPlayingIndexPath = self.currentPlayingIndexPath;
        self.currentPlayingIndexPath = nil;
        self.currentPlayingModel = nil;
        [_timer invalidate];
        _timer = nil;
        [self.privatePlayer stop];
        self.privatePlayer = nil;
        BMMutexAudioStatusModel *statusModel =
        [self.cellStatusDictionary objectForKey:[self generateCellKeyStringWithIndexPath:self.previousPlayingIndexPath]];
        statusModel.currentStatus = status;
        if (status == EBMPlayerStatusStop) {
            statusModel.currentProgress = 0;
        }
        [self cellStatusDidChanged:self.previousPlayingIndexPath statusModel:statusModel];
    }
}

/**
 * @brief 获取当前播放器的播放进度
 * @return progress播放进度
 */
- (float)getCurrentProgress {
    if (self.privatePlayer) {
        return self.privatePlayer.currentTime / self.privatePlayer.duration;
    } else {
        return 0;
    }
}

- (BOOL)isTwoIndexPathEqual:(NSIndexPath *)indexPathA otherIndexPath:(NSIndexPath *)indexPathB {
    if (indexPathA && indexPathB && indexPathA.section == indexPathB.section && indexPathA.row == indexPathB.row) {
        return YES;
    }
    return NO;
}

- (void)downloadAudioWithURL:(NSString *)URLString
                     success:(nullable void (^)(NSString *voiceName, EBMAudioDownloadStatus voiceDownloadStatus, NSString *voicePath))successBlock
                        fail:(nullable void (^)(EBMAudioDownloadStatus voiceDownloadStatus))failBlock {
    NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
    [dict setValue:URLString forKey:@"voiceUrl"];
    [dict setValue:[self generateMD5WithString:URLString] forKey:@"voiceName"];
    [[BMAudioDownloadManager sharedInstance] asynchronousVoiceDownload:dict];
    [BMAudioDownloadManager sharedInstance].voiceDownloadSuccessBlock =
    ^(NSString *voiceName, EBMAudioDownloadStatus voiceDownloadStatus, NSString *voicePath) {
        if (voiceDownloadStatus == EBMAudioDownloadStatusSuccess) {
            successBlock(voiceName, voiceDownloadStatus, voicePath);
        } else {
            failBlock(voiceDownloadStatus);
        }

    };
}

- (NSString *)generateMD5WithString:(NSString *)str {

    // Create pointer to the string as UTF8
    const char *ptr = [str UTF8String];

    // Create byte array of unsigned chars
    unsigned char md5Buffer[CC_MD5_DIGEST_LENGTH];

    // Create 16 byte MD5 hash value, store in buffer
    CC_MD5(ptr, (CC_LONG)strlen(ptr), md5Buffer);

    // Convert MD5 value in the buffer to NSString of hex values
    NSMutableString *output = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
        [output appendFormat:@"%02x", md5Buffer[i]];
    }

    return output;
}

#pragma mark - Delegate And DataSource

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    if ([self.delegate respondsToSelector:@selector(mutexAudioManagerDidChanged:statusModel:)]) {
        [self.delegate mutexAudioManagerDidChanged:self.currentPlayingIndexPath statusModel:self.currentPlayingModel];
    }
    [self pauseOrStopAudioInIndexPath:self.currentPlayingIndexPath status:EBMPlayerStatusStop];
}

#pragma mark - Event Response

/**
 * @brief 播放器在播放时实时更新播放进度（用于更新slider）
 */
- (void)updateProgress {
    if (_timer == nil) {
        return;
    }
    //进度条显示播放进度
    float progress = [self getCurrentProgress];
    self.currentPlayingModel.currentProgress = progress;
    self.currentPlayingModel.duration = self.privatePlayer.duration;
    if ([self.delegate respondsToSelector:@selector(mutexAudioManagerPlayingCell:progress:duration:)]) {
        [self.delegate mutexAudioManagerPlayingCell:self.currentPlayingIndexPath
                                           progress:progress
                                           duration:(NSInteger)self.privatePlayer.duration];
    }
}

- (void)cellStatusDidChanged:(NSIndexPath *)changedCellIndexPath statusModel:(BMMutexAudioStatusModel *)statusModel {
    if ([self.delegate respondsToSelector:@selector(mutexAudioManagerDidChanged:statusModel:)]) {
        [self.delegate mutexAudioManagerDidChanged:changedCellIndexPath statusModel:statusModel];
    }
}

#pragma mark - Lazy Load

- (NSMutableDictionary *)cellStatusDictionary {
    if (nil == _cellStatusDictionary) {
        _cellStatusDictionary = [NSMutableDictionary dictionary];
    }
    return _cellStatusDictionary;
}
@end

@implementation BMMutexAudioStatusModel

@end
