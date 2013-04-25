//
//  BOMTalk
//	werk01.de
//

#import <Foundation/Foundation.h>
#import <GameKit/GameKit.h>
#import "BOMTalkPackage.h"
#import "BOMTalkPeer.h"

typedef void (^BOMTalkBlock)(BOMTalkPeer *sender);
typedef void (^BOMTalkMessageBlock)(BOMTalkPeer *sender, id<NSCoding> data);
typedef void (^BOMTalkErrorBlock)(NSError *error);

@protocol BOMTalkDelegate <NSObject>
@optional
- (void) talkDidShow:(BOMTalkPeer*) peer;
- (void) talkDidHide:(BOMTalkPeer*) peer;
- (void) talkDidConnect:(BOMTalkPeer*) peer;
- (void) talkDidDisconnect:(BOMTalkPeer*) peer;
- (void) talkReceived:(NSInteger) messageID fromPeer:(BOMTalkPeer*) sender withData:(id<NSCoding>) data;
- (void) talkUpdate:(BOMTalkPeer*) peer;
- (void) talkFailed:(NSError*) error;
@end

#define kBOMTalkDidShowNotification @"BOMTalkDidShowNotification"
#define kBOMTalkDidHideNotification @"BOMTalkDidHideNotification"
#define kBOMTalkDidConnectNotification @"BOMTalkDidConnectNotification"
#define kBOMTalkDidDisconnectNotification @"BOMTalkDidDisconnectNotification"
#define kBOMTalkReceivedNotification @"BOMTalkReceivedNotification"
#define kBOMTalkUpdateNotification @"BOMTalkUpdateNotification"
#define kBOMTalkFailedNotification @"BOMTalkFailedNotification"

@interface BOMTalk : NSObject <GKSessionDelegate>

@property (nonatomic, readonly) GKSessionMode mode;
@property (nonatomic, readonly) BOOL asServer;
@property (nonatomic, strong) BOMTalkPeer *selfPeer;
@property (nonatomic, strong) BOMTalkPeer *serverPeer;
@property (nonatomic, strong) NSMutableArray *peerList;
@property (weak, nonatomic) id<BOMTalkDelegate>delegate;

+ (BOMTalk*) sharedTalk;
- (void) startInMode:(GKSessionMode) mode;
- (void) startInMode:(GKSessionMode) mode didShow:(BOMTalkBlock) showBlock didHide:(BOMTalkBlock) hideBlock didConnect:(BOMTalkBlock) connectBlock didDisconnect:(BOMTalkBlock) disconnectBlock;
- (void) stop;
- (void) reset;

- (void) show;
- (void) hide;

- (void) answerToMessage:(NSInteger) messageID block: (BOMTalkMessageBlock) block;
- (void) answerToUpdate: (BOMTalkBlock) block;
- (void) answerToFailure: (BOMTalkErrorBlock) block;

- (BOMTalkPeer*) peerForPeerID:(NSString*) peerID;

- (void) connectToPeer:(BOMTalkPeer*) peer;
- (void) connectToPeer:(BOMTalkPeer*) peer success:(BOMTalkBlock) successBlock;
- (void) connectToPeer:(BOMTalkPeer*) peer success:(BOMTalkBlock) successBlock failure:(BOMTalkErrorBlock) failureBlock;
- (void) disconnectPeer:(BOMTalkPeer*) peer;

- (void) sendToAllMessage:(int) messageID;
- (void) sendToAllMessage:(int) messageID withData:(id<NSCoding>) data;
- (BOOL) sendMessage:(int) messageID toPeer:(BOMTalkPeer*) peer;
- (BOOL) sendMessage:(int) messageID toPeer:(BOMTalkPeer*) peer withData:(id<NSCoding>) data;

@end