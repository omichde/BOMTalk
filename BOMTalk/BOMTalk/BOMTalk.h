//
//  BOMTalk
//	werk01.de
//

#import <Foundation/Foundation.h>
#import <GameKit/GameKit.h>
#import "BOMTalkPackage.h"
#import "BOMTalkPeer.h"

@protocol BOMTalkDelegate <NSObject>
@optional
- (void) talkDidShow:(BOMTalkPeer*) peer;
- (void) talkDidHide:(BOMTalkPeer*) peer;
- (void) talkDidConnect:(BOMTalkPeer*) peer;
- (void) talkDidDisconnect:(BOMTalkPeer*) peer;
- (void) talkReceived:(NSInteger) messageID fromPeer:(BOMTalkPeer*) sender withData:(id<NSCoding>) data;
- (void) talkUpdate:(BOMTalkPeer*) peer;
- (void) talkFailed:(NSError*) error;
- (void) talkProgressForReceiving:(float) progress;
- (void) talkProgressForSending:(float) progress;
@end

#define kBOMTalkDidShowNotification @"BOMTalkDidShowNotification"
#define kBOMTalkDidHideNotification @"BOMTalkDidHideNotification"
#define kBOMTalkDidConnectNotification @"BOMTalkDidConnectNotification"
#define kBOMTalkDidDisconnectNotification @"BOMTalkDidDisconnectNotification"
#define kBOMTalkReceivedNotification @"BOMTalkReceivedNotification"
#define kBOMTalkUpdateNotification @"BOMTalkUpdateNotification"
#define kBOMTalkFailedNotification @"BOMTalkFailedNotification"
#define kBOMTalkProgressForReceivingNotification @"BOMTalkProgressForReceivingNotification"
#define kBOMTalkProgressForSendingNotification @"BOMTalkProgressForSendingNotification"

typedef void (^BOMTalkBlock)(BOMTalkPeer *sender);
typedef void (^BOMTalkMessageBlock)(BOMTalkPeer *sender, id<NSCoding> data);
typedef void (^BOMTalkErrorBlock)(NSError *error);
typedef void (^BOMTalkProgressBlock)(float progress);

@interface BOMTalk : NSObject <GKSessionDelegate>

@property (nonatomic, readonly) GKSessionMode mode;
@property (nonatomic, readonly) BOOL asServer;
@property (nonatomic, strong) BOMTalkPeer *selfPeer;
@property (nonatomic, strong) BOMTalkPeer *serverPeer;
@property (nonatomic, strong) NSMutableArray *peerList;
@property (weak, nonatomic) id<BOMTalkDelegate>delegate;

#ifdef DEBUG
- (void) showDebuggerFromViewController:(UIViewController*) sourceViewController;
- (void) hideDebugger;
#endif

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
- (void) progressForReceiving: (BOMTalkProgressBlock) block;
- (void) progressForSending: (BOMTalkProgressBlock) block;

- (BOMTalkPeer*) peerForPeerID:(NSString*) peerID;

- (void) connectToPeer:(BOMTalkPeer*) peer;
- (void) connectToPeer:(BOMTalkPeer*) peer success:(BOMTalkBlock) successBlock;
- (void) connectToPeer:(BOMTalkPeer*) peer success:(BOMTalkBlock) successBlock failure:(BOMTalkErrorBlock) failureBlock;
- (void) disconnectPeer:(BOMTalkPeer*) peer;

- (void) sendToAllMessage:(int) messageID;
- (void) sendToAllMessage:(int) messageID withData:(id<NSCoding>) data;
- (void) sendMessage:(int) messageID toPeer:(BOMTalkPeer*) peer;
- (void) sendMessage:(int) messageID toPeer:(BOMTalkPeer*) peer withData:(id<NSCoding>) data;
//- (void) sendMessage:(int) messageID toPeer:(BOMTalkPeer*) peer withData:(id<NSCoding>) data progress:(BOMTalkProgressBlock) progressBlock;

@end