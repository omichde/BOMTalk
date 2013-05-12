//
//  BOMTalk
//	werk01.de
//	Oliver Michalak - oliver@werk01.de - @omichde
//
//	BOMTalk is available under the MIT license:
//
//	Permission is hereby granted, free of charge, to any person obtaining a copy
//	of this software and associated documentation files (the "Software"), to deal
//	in the Software without restriction, including without limitation the rights
//	to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//	copies of the Software, and to permit persons to whom the Software is
//	furnished to do so, subject to the following conditions:
//
//	The above copyright notice and this permission notice shall be included in
//	all copies or substantial portions of the Software.
//
//	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//	IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//	FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//	AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//	LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//	OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//	THE SOFTWARE.

#import <Foundation/Foundation.h>
#import <GameKit/GameKit.h>
#import "BOMTalkPackage.h"
#import "BOMTalkPeer.h"

//#define BOMTalkDebug 1

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

#ifdef BOMTalkDebug
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