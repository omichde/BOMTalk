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

#define BOMTalkDebug 1

/**
 Optional delegates to be called in their respective context.
 */
@protocol BOMTalkDelegate <NSObject>
@optional
/**
 A peer appeared on the network. You are not connected to this peer automatically.
 @param peer The peer visible to the network.
 */
- (void) talkDidShow:(BOMTalkPeer*) peer;

/**
 A peer hides from the network, which can either happen by the peer hiding itself or the peer being disconnected from the network entirely.
 @param peer The peer hiding from the network.
 */
- (void) talkDidHide:(BOMTalkPeer*) peer;

/**
 A peer connected to the network, probably as an answer to your connectToPeer: call.
 @param peer The newly connected peer.
 */
- (void) talkDidConnect:(BOMTalkPeer*) peer;

/**
 A peer disconnected from the network.
 @param peer The recently disconnected peer.
 */
- (void) talkDidDisconnect:(BOMTalkPeer*) peer;

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

/**
 The core object class handles network interactions and keeps list of peers.
 You need to include the GameKit.framework.
 */
@interface BOMTalk : NSObject <GKSessionDelegate>

/** @name Properties */

/**
 This mode mimics the GameKit mode you connect your APP with the network.
 */
@property (nonatomic, readonly) GKSessionMode mode;

/**
 Wether the connection runs as server.
 */
@property (nonatomic, readonly) BOOL asServer;

/**
 Peer data of the APP itself in the network.
 */
@property (nonatomic, strong) BOMTalkPeer *selfPeer;

/**
 In case the APP is connected to a server, this is the server peer object.
 */
@property (nonatomic, strong) BOMTalkPeer *serverPeer;

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
 Adds a simple message to the timeline
 @param formatString Format string with optional parameters
 */
- (void) addDebuggerMessage: (NSString*) formatString, ...;

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
 Starts the connection to the network.
 @param mode GKSessionModeServer = act as server, GKSessionModeClient = act as client, GKSessionModePeer = act as both server and peer
 */
- (void) startInMode:(GKSessionMode) mode;

/**
 Starts the connection to the network with block callbacks.
 @param mode GKSessionModeServer = act as server, GKSessionModeClient = act as client, GKSessionModePeer = act as both server and peer
 @param showBlock Block to be called after peer is visible on the network
 @param hideBlock Block to be called when peer disappears
 @param connectBlock Block to be called when peer connects to network
 @param disconnectBlock Block to be called when peer disconnects from network
 */
- (void) startInMode:(GKSessionMode) mode didShow:(BOMTalkBlock) showBlock didHide:(BOMTalkBlock) hideBlock didConnect:(BOMTalkBlock) connectBlock didDisconnect:(BOMTalkBlock) disconnectBlock;

/**
 Stops the network connection in this APP.
 */
- (void) stop;

/**
 Temporarily stops the network and re-connect to it again.
 */
- (void) reset;

/**
 As a server, you can show yourself to the network.
 */
- (void) show;

/**
 As a server, you can hide from the network.
 */
- (void) hide;

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

/** @name Connecting, Disconnecting */

/**
 Connecto to a peer.
 @param peer Connect to this peer
 */
- (void) connectToPeer:(BOMTalkPeer*) peer;

/**
 Connect to a peer with a success block callback.
 @param peer Connect to this peer
 @param successBlock Block to be called after successfull connected
 */
- (void) connectToPeer:(BOMTalkPeer*) peer success:(BOMTalkBlock) successBlock;

/**
 Connect to a peer with a success and failure block callback.
 @param peer Connect to this peer
 @param successBlock Block to be called after successfull connected
 @param failureBlock Block to be called when a connection failed
 */
- (void) connectToPeer:(BOMTalkPeer*) peer success:(BOMTalkBlock) successBlock failure:(BOMTalkErrorBlock) failureBlock;

/**
 Disconnect from a peer.
 @param peer Peer to be disconnected.
 */
- (void) disconnectPeer:(BOMTalkPeer*) peer;

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