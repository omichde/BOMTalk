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

/**
 Optional delegates to be called in their respective context.
 */
@protocol BOMTalkDelegate <NSObject>
@optional

/**
 You received a message from a peer including its data.
 @param messageID Your message ID defined somewhere as a constant.
 @param sender The sender of the message.
 @param data The data, the sender has sent to you. data may be `nil` if no data was sent.
 */
- (void) talkReceived:(NSInteger) messageID fromPeer:(BOMTalkPeer*) sender withData:(id<NSCoding>) data;

/**
 Every change in the network will result in different updates, alongside individula callsbacks, the talkUpdate delegate will be called for: connecting, disconnecting, showing or hiding peers, network availabiliy
 @param peer The peer who changed within the network.
 */
- (void) talkUpdate:(BOMTalkPeer*) peer;

/**
 Basic network errors who are not bound to a peer are handle here. Connecting to the network itself or to a peer will call this delegate.
 @param error Error object for the error.
 */
- (void) talkFailed:(NSError*) error;

/**
 Progress metric for incoming data.
 @param progress 0 is sent before the first transmission begins, 1 is sent when the transmission finished. Intermediate results are optional.
 */
- (void) talkProgressForReceiving:(float) progress;

/**
 Progress metric for outgoing data.
 @param progress 0 is sent before the first transmission begins, 1 is sent when the transmission finished. Intermediate results are optional.
 */
- (void) talkProgressForSending:(float) progress;
@end

/**
 Notification for [talkProgressForReceiving]([BOMTalkDelegate talkDidShow:])
 @param object BOMTalkPeer
 */
#define BOMTalkReceivedNotification @"BOMTalkReceivedNotification"
#define BOMTalkUpdateNotification @"BOMTalkUpdateNotification"
#define BOMTalkFailedNotification @"BOMTalkFailedNotification"
#define BOMTalkProgressForReceivingNotification @"BOMTalkProgressForReceivingNotification"
#define BOMTalkProgressForSendingNotification @"BOMTalkProgressForSendingNotification"

typedef void (^BOMTalkBlock)(BOMTalkPeer *sender);
typedef void (^BOMTalkMessageBlock)(BOMTalkPeer *sender, id<NSCoding> data);
typedef void (^BOMTalkErrorBlock)(NSError *error);
typedef void (^BOMTalkProgressBlock)(float progress);

/**
 The core object class handles network interactions and keeps list of peers.
 You need to include the GameKit.framework.
 */
@interface BOMTalk : NSObject <GKSessionDelegate>

/** @name Properties */

/**
 Peer data of the APP itself in the network.
 nil if not connected to network
 */
@property (nonatomic, strong) BOMTalkPeer *selfPeer;

/**
 List of all peers known to the network.
 */
@property (nonatomic, strong) NSMutableArray *peerList;

/**
 Reference to the delegate object.
 */
@property (weak, nonatomic) id<BOMTalkDelegate>delegate;

#ifdef BOMTalkDebug
/** @name Debugging View Controller */

/**
 Shows a basic network debugging view controller.
 @param sourceViewController Originating view controller.
 */
- (void) showDebuggerFromViewController:(UIViewController*) sourceViewController;

/**
 prints a simple message to the timeline
 @param peer Sender of the message
 @param formatString Format string with optional parameters
 @param ... optional parameters
 */
- (void) printDebugger: (BOMTalkPeer*) peer withMessage: (NSString*) formatString, ...;

/**
 Hides the network debugger.
 */
- (void) hideDebugger;
#endif

/** @name Basic Networking */

/**
 Creates the singleton BOMTalk object.
 */
+ (BOMTalk*) sharedTalk;

/**
 Starts the connection to the network
 */
- (void) start;

/**
 Stops the network connection in this APP.
 */
- (void) stop;

/** @name Blocks interface */

/**
 Assigns a new block to an incoming message.
 @param messageID ID of the message
 @param block Block to be called when the message arrives.
 */
- (void) answerToMessage:(NSInteger) messageID block: (BOMTalkMessageBlock) block;

/**
 Single block to be called when network states or peers changes (see [talkUpdate]([BOMTalkDelegate talkUpdate:])).
 @param block Block to be called after changes.
 */
- (void) answerToUpdate: (BOMTalkBlock) block;

/**
 Single block to be called in case of network failures (see [talkFailed]([BOMTalkDelegate talkFailed:])).
 @param block Block to be called after network failures occured.
 */
- (void) answerToFailure: (BOMTalkErrorBlock) block;

/**
 Single Block to be called after receiving a part of a new transmission (see [talkProgressForReceiving]([BOMTalkDelegate talkProgressForReceiving:])).
 @param block Block to be called while receiving data.
 */
- (void) progressForReceiving: (BOMTalkProgressBlock) block;

/**
 Single Block to be called after sending a part of a new transmission (see [talkProgressForSending]([BOMTalkDelegate talkProgressForSending:])).
 @param block Block to be called while sending data.
 */
- (void) progressForSending: (BOMTalkProgressBlock) block;

/** @name Miscellaneous */

/**
 Helper method to translate a GameKit to a BOMTalkPeer peer.
 @param peerID GameKit peer ID
 */
- (BOMTalkPeer*) peerForPeerID:(NSString*) peerID;

/** @name Sending messages */

/**
 Sends a message to all client peers.
 @param messageID Message to be sent
 */
- (void) sendToAllMessage:(int) messageID;

/**
 Sends a message and data to all client peers.
 @param messageID Message to be sent
 @param data NSCoding compliant data
 */
- (void) sendToAllMessage:(int) messageID withData:(id<NSCoding>) data;

/**
 Sends a message to a peer.
 @param messageID Message to be sent
 @param peer Receiver of the message
 */
- (void) sendMessage:(int) messageID toPeer:(BOMTalkPeer*) peer;

/**
 Sends a message and data to a peer.
 @param messageID Message to be sent
 @param peer Receiver of the message
 @param data NSCoding compliant data
 */
- (void) sendMessage:(int) messageID toPeer:(BOMTalkPeer*) peer withData:(id<NSCoding>) data;

//- (void) sendMessage:(int) messageID toPeer:(BOMTalkPeer*) peer withData:(id<NSCoding>) data progress:(BOMTalkProgressBlock) progressBlock;

@end