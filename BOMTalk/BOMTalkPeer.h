//
//  SessionPeerClass.h
//  werk01.de
//

#import <Foundation/Foundation.h>

typedef enum {
	BOMTalkPeerStateIdle = 1,
	BOMTalkPeerStateVisible,
	BOMTalkPeerStateConnecting,
	BOMTalkPeerStateConnected,
	BOMTalkPeerStateTransfering
} BOMTalkPeerState;

/**
 A peer, its states and additional data are held in this class.
 */
@interface BOMTalkPeer : NSObject

/**
 The internal GameKit peerID.
 */
@property (strong, nonatomic) NSString *peerID;

/**
 The visible display name of the network.
 */
@property (strong, nonatomic) NSString *name;

/**
 The internal state of the peer.
 */
@property (assign, nonatomic) BOMTalkPeerState state;

/**
 A mutable dictionary to be used by the APP to assign, retrieve or remove custom properties to/from a peer.
 */
@property (strong, nonatomic) NSMutableDictionary *userInfo;

/**
 Internal timestamp of the last interaction of a peer with the network. Used to cut off the oldest peer to keep one slot free.
 */
@property (assign, nonatomic) NSTimeInterval timestamp;

/**
 Create a new peer.
 @param peer GameKit peer id
 @param name Visible name
 */
- (id) initWithPeer: (NSString*) peer name: (NSString*) name;

/**
 Updates the peer and its timestamp
 */
- (void) update;


@end
