//
//  BOMTalk
//	werk01.de
//

#import "BOMTalk.h"
#import "BOMTalkPackage.h"
#import "BOMTalkDebugViewController.h"
#import "BOMTalkDebugEvent.h"

#define BOMTalkTimeout (10)

@interface BOMTalk ()

- (void) connectToPeer:(BOMTalkPeer*) peer;

@property (strong, nonatomic) GKSession *sessionNetwork;
@property (strong, nonatomic) NSMutableArray *openPeerList;
@property (strong, nonatomic) BOMTalkDebugViewController *debugViewController;

@property (strong, nonatomic) NSMutableArray *messageList;
@property (readwrite, nonatomic, copy) BOMTalkBlock updateBlock;
@property (readwrite, nonatomic, copy) BOMTalkErrorBlock failureBlock;

@property (readwrite, nonatomic, copy) BOMTalkProgressBlock progressReceivingBlock;
@property (readwrite, nonatomic, copy) BOMTalkProgressBlock progressSendingBlock;

@end

@implementation BOMTalk

#pragma mark initializing

+ (BOMTalk*) sharedTalk {
	static dispatch_once_t once;
	static BOMTalk *sessionController = nil;
	dispatch_once (&once, ^{
		sessionController = [[BOMTalk alloc] init];
	});
	return sessionController;
}

- (id) init {
	if ((self = [super init])) {
		self.peerList = [[NSMutableArray alloc] init];
		self.openPeerList = [[NSMutableArray alloc] init];
		self.messageList = [[NSMutableArray alloc] init];
#ifdef BOMTalkDebug
		self.debugViewController = [[BOMTalkDebugViewController alloc] initWithNibName:@"BOMTalkDebugViewController" bundle:nil];
		self.debugViewController.view.tag = 0;	// force load of view and hence viewDidLoad
#endif
	}
	return self;
}

#ifdef BOMTalkDebug
- (void) showDebuggerFromViewController:(UIViewController*) sourceViewController {
	[sourceViewController.view addSubview: self.debugViewController.view];
	[sourceViewController addChildViewController: self.debugViewController];
	self.debugViewController.view.frame = CGRectMake (0, -sourceViewController.view.bounds.size.height, sourceViewController.view.bounds.size.width, sourceViewController.view.bounds.size.height);
	[UIView animateWithDuration:0.2 animations:^{
		self.debugViewController.view.frame = sourceViewController.view.bounds;
	} completion:^(BOOL finished) {
		[self.debugViewController didMoveToParentViewController: sourceViewController];
	}];
}

- (void) printDebugger: (BOMTalkPeer*) peer withMessage: (NSString*) formatString, ... {
	va_list args;
	va_start(args, formatString);
	NSString *message = [[NSString alloc] initWithFormat:formatString arguments:args];
	va_end(args);
	[self.debugViewController addEvent: [BOMTalkDebugEvent eventFromPeer: peer toPeer:nil message: message]];
}

- (void) hideDebugger {
	[UIView animateWithDuration:0.2 animations:^{
		self.debugViewController.view.frame = CGRectMake (0, -self.debugViewController.view.superview.bounds.size.height, self.debugViewController.view.superview.bounds.size.width, self.debugViewController.view.superview.bounds.size.height);
	} completion:^(BOOL finished) {
		[self.debugViewController.view removeFromSuperview];
		[self.debugViewController removeFromParentViewController];
	}];
}
#endif

#pragma mark network handling

- (void) start {
	if (self.sessionNetwork)
		return;

	self.sessionNetwork = [[GKSession alloc] initWithSessionID:nil displayName:nil sessionMode: GKSessionModePeer];
	self.sessionNetwork.delegate = self;
	[self.sessionNetwork setDataReceiveHandler:self withContext:nil];
	self.sessionNetwork.available = YES;
	self.selfPeer = [[BOMTalkPeer alloc] initWithPeer:self.sessionNetwork.peerID name: [self.sessionNetwork displayName]];
	[self.debugViewController addEvent: [BOMTalkDebugEvent eventFromPeer:self.selfPeer toPeer:nil message:@"Start"]];
}

- (void) stop {
	[self.debugViewController addEvent: [BOMTalkDebugEvent eventFromPeer:self.selfPeer toPeer:nil message:@"Stop"]];
	[self.sessionNetwork disconnectFromAllPeers];
	self.sessionNetwork.available = NO;
	[self.sessionNetwork setDataReceiveHandler: nil withContext: NULL];
	self.sessionNetwork.delegate = nil;
	self.sessionNetwork = nil;
	self.selfPeer = nil;
	[self.peerList removeAllObjects];
	[self.openPeerList removeAllObjects];
	self.delegate = nil;
	[self.messageList removeAllObjects];
	self.updateBlock = nil;
	self.failureBlock = nil;
	self.progressReceivingBlock = nil;
	self.progressSendingBlock = nil;
}

- (void) session:(GKSession*) session didFailWithError:(NSError*) error {
	[self.debugViewController addEvent: [BOMTalkDebugEvent eventFromPeer:self.selfPeer toPeer:nil message:@"Session failed"]];
	[self stop];
	if ([self.delegate respondsToSelector:@selector(talkFailed:)])
		[self.delegate talkFailed:error];
	if (self.failureBlock)
		self.failureBlock(error);
	[[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:BOMTalkFailedNotification object:error]];
}

#pragma mark block based callbacks

- (void) answerToMessage:(NSInteger) messageID block: (BOMTalkMessageBlock) block {
	[self.messageList addObject: @{@"messageID": [NSNumber numberWithInt: messageID], @"block": block}];
}

- (void) answerToUpdate: (BOMTalkBlock) block {
	self.updateBlock = block;
}

- (void) answerToFailure: (BOMTalkErrorBlock) block {
	self.failureBlock = block;
}

- (void) progressForReceiving: (BOMTalkProgressBlock) block {
	self.progressReceivingBlock = block;
}

- (void) progressForSending: (BOMTalkProgressBlock) block {
	self.progressSendingBlock = block;
}

#pragma mark client handling

- (BOMTalkPeer*) peerForPeerID:(NSString*) peerID {
	BOMTalkPeer *peer = nil;
	NSUInteger pos = [self.peerList indexOfObjectPassingTest:^BOOL(id obj, NSUInteger idx, BOOL *stop) {
		if ([[(BOMTalkPeer*)obj peerID] isEqual:peerID]) {
			*stop = YES;
			return YES;
		}
		return NO;
	}];
	if (NSNotFound != pos)
		peer = self.peerList[pos];
	else {
		pos = [self.openPeerList indexOfObjectPassingTest:^BOOL(id obj, NSUInteger idx, BOOL *stop) {
			if ([[(BOMTalkPeer*)obj peerID] isEqual:peerID]) {
				*stop = YES;
				return YES;
			}
			return NO;
		}];
		if (NSNotFound != pos)
			peer = self.openPeerList[pos];
		else if ([self.selfPeer.peerID isEqual: peerID])	// fetch ANY peer object
			peer = self.selfPeer;
	}
	return peer;
}

- (void) connectToPeer:(BOMTalkPeer*) peer {
}

- (void) disconnectPeer:(BOMTalkPeer*) peer {
	[self.debugViewController addEvent: [BOMTalkDebugEvent eventFromPeer:self.selfPeer toPeer: peer message:@"Disconnecting"]];
	[self.sessionNetwork disconnectPeerFromAllPeers: peer.peerID];
}

- (void) session:(GKSession*) session didReceiveConnectionRequestFromPeer:(NSString*) peerID {
	[self.debugViewController addEvent: [BOMTalkDebugEvent eventFromPeer:self.selfPeer toPeer: nil message:@"Conn-Request from %@", [session displayNameForPeer: peerID]]];
	NSError *error = nil;
	[self.sessionNetwork acceptConnectionFromPeer:peerID error:&error];
}

- (void) session:(GKSession*) session connectionWithPeerFailed:(NSString*) peerID withError:(NSError*) error {
	BOMTalkPeer *peer = [self peerForPeerID:peerID];
	[self.debugViewController addEvent: [BOMTalkDebugEvent eventFromPeer: peer toPeer: nil message:@"Failed %@", peerID]];
	[self.openPeerList removeObject: peer];

	if ([self.delegate respondsToSelector:@selector(talkFailed:)])
		[self.delegate talkFailed:error];
	if (self.failureBlock)
		self.failureBlock (error);
	[[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:BOMTalkFailedNotification object:error]];
}

- (void) session:(GKSession*) session peer:(NSString*) peerID didChangeState:(GKPeerConnectionState) state {
	if ([[session displayNameForPeer:session.peerID] isEqual:[session displayNameForPeer:peerID]])	// prevent self messages due to change in peerIDs to same client
		return;

	BOMTalkPeer *peer = [self peerForPeerID:peerID];
	if (!peer)
		peer = [[BOMTalkPeer alloc] initWithPeer:peerID name: [self.sessionNetwork displayNameForPeer:peerID]];

	switch (state) {
		// server states
		case GKPeerStateAvailable: {
			[self.debugViewController addEvent: [BOMTalkDebugEvent eventFromPeer: peer toPeer: self.selfPeer message:@"Avail"]];
			peer.state = MAX(BOMTalkPeerStateVisible, peer.state);
			if (![self.peerList containsObject:peer] && ![self.openPeerList containsObject:peer]) {
				[self.openPeerList addObject:peer];
				if (peer.state < BOMTalkPeerStateConnecting) {
					peer.state = BOMTalkPeerStateConnecting;
					[self.sessionNetwork connectToPeer:peer.peerID withTimeout:BOMTalkTimeout];
				}
			}
		}
		break;

		case GKPeerStateUnavailable: {
			[self.debugViewController addEvent: [BOMTalkDebugEvent eventFromPeer: peer toPeer: self.selfPeer message:@"Un-Avail"]];
			peer.state = MIN(BOMTalkPeerStateVisible, peer.state);
			[self.openPeerList removeObject: peer];
			[self.peerList removeObject: peer];
		}
		break;

		// client states
		case GKPeerStateConnecting: {
			[self.debugViewController addEvent: [BOMTalkDebugEvent eventFromPeer: peer toPeer: self.selfPeer message:@"Connecting"]];
			peer.state = MAX(BOMTalkPeerStateConnecting, peer.state);
		}
		break;

		case GKPeerStateConnected: {
			[self.debugViewController addEvent: [BOMTalkDebugEvent eventFromPeer: peer toPeer: self.selfPeer message:@"Connected"]];
			peer.state = MAX(BOMTalkPeerStateConnected, peer.state);
			[self.peerList addObject: peer];
			[self.openPeerList removeObject: peer];
		}
		break;

		case GKPeerStateDisconnected: {
			[self.debugViewController addEvent: [BOMTalkDebugEvent eventFromPeer: peer toPeer: self.selfPeer message:@"Disconnected"]];
			peer.state = MIN(BOMTalkPeerStateIdle, peer.state);
			[self.openPeerList removeObject: peer];
			[self.peerList removeObject: peer];
		}
		break;
	}
	// fire general update mechanism
	if ([self.delegate respondsToSelector:@selector(talkUpdate:)])
		[self.delegate talkUpdate: peer];
	if (self.updateBlock)
		self.updateBlock(peer);
	[[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:BOMTalkUpdateNotification object: peer]];
}

- (void) receiveData:(NSData*) data fromPeer:(NSString*) peerID inSession: (GKSession*) session context:(void*) context {
	static BOMTalkPackage *lastPackage = nil;
	static NSString *lastPeerID = nil;

	BOMTalkPeer *peer = [self peerForPeerID:peerID];
	if (!peer)
		peer = [[BOMTalkPeer alloc] initWithPeer:peerID name: [self.sessionNetwork displayNameForPeer:peerID]];

	@try {
		BOOL startReceiving = NO;	// keep notifications out of release pool
		@autoreleasepool {
			peer.state = BOMTalkPeerStateTransfering;
			BOMTalkPackage *package = [NSKeyedUnarchiver unarchiveObjectWithData:data];
			[self.debugViewController addEvent: [BOMTalkDebugEvent eventFromPeer: peer toPeer: self.selfPeer message:@"Received %d (%.2f)", package.messageID, package.progress]];
			
			// models one message per peer per sequence
			if (!lastPackage || ![lastPeerID isEqual:peer.peerID] || ![lastPackage appendPackage:package]) {
				BOMTalkPeer *lastPeer = [self peerForPeerID: lastPeerID];
				if (lastPeer && lastPeer.state == BOMTalkPeerStateTransfering)
					lastPeer.state = BOMTalkPeerStateConnected;
				lastPackage = nil;
				lastPeerID = nil;
				if (package.isHead) {
					lastPackage = package;
					lastPeerID = [peer.peerID copy];
					startReceiving = YES;
				}
			}
		}
		if (startReceiving) {
			if ([self.delegate respondsToSelector:@selector(talkProgressForReceiving:)])
				[self.delegate talkProgressForReceiving:0.0];
			if (self.progressReceivingBlock)
				self.progressReceivingBlock (0.0);
			[[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:BOMTalkProgressForReceivingNotification object: [NSNumber numberWithFloat:0.0]]];
		}
	}
	@catch (NSException *exception) {
		lastPackage = nil;
		lastPeerID = nil;
	}
	@finally {
		if (lastPackage.isComplete) {
			if ([self.delegate respondsToSelector:@selector(talkProgressForReceiving:)])
				[self.delegate talkProgressForReceiving:1.0];
			if (self.progressReceivingBlock)
				self.progressReceivingBlock (1.0);
			[[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:BOMTalkProgressForReceivingNotification object: [NSNumber numberWithFloat:1.0]]];

			id<NSCoding> lastData = nil;
			if (lastPackage.data)
				lastData = [NSKeyedUnarchiver unarchiveObjectWithData:lastPackage.data];
			if ([self.delegate respondsToSelector:@selector(talkReceived:fromPeer:withData:)])
					[self.delegate talkReceived:lastPackage.messageID fromPeer:peer withData: lastData];
			for (NSDictionary *messageDict in self.messageList) {
				if (lastPackage.messageID == [messageDict[@"messageID"] integerValue]) {
					BOMTalkMessageBlock messageBlock = messageDict[@"block"];
					messageBlock(peer, lastData);
				}
			}
			NSMutableDictionary *dataDict = [@{@"messageID": [NSNumber numberWithInt:lastPackage.messageID], @"peer": peer} mutableCopy];
			if (lastData)
				[dataDict setObject:lastData forKey:@"data"];
			[[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:BOMTalkReceivedNotification object: dataDict]];

			peer.state = BOMTalkPeerStateConnected;
			lastData = nil;
			lastPackage = nil;
			lastPeerID = nil;

			// GamkeKit has maximum of 16 connections, so keep one slot free
			[peer update];
			if (self.peerList.count > 15) {
				NSArray *sortedList = [self.peerList sortedArrayUsingComparator:^NSComparisonResult(id obj1, id obj2) {
					BOMTalkPeer *peer1 = (BOMTalkPeer*) obj1;
					BOMTalkPeer *peer2 = (BOMTalkPeer*) obj2;
					if (peer1.timestamp == peer2.timestamp)
						return NSOrderedSame;
					else if (peer1.timestamp < peer2.timestamp)
						return NSOrderedDescending;
					else
						return NSOrderedAscending;
				}];
				while (self.peerList.count > 15)
					[self.peerList removeObject: sortedList[self.peerList.count-1]];
			}
		}
		else {
			peer.state = BOMTalkPeerStateTransfering;
			float progress = lastPackage.progress;
			if ([self.delegate respondsToSelector:@selector(talkProgressForReceiving:)])
				[self.delegate talkProgressForReceiving:progress];
			if (self.progressReceivingBlock)
				self.progressReceivingBlock (progress);
			[[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:BOMTalkProgressForReceivingNotification object: [NSNumber numberWithFloat:progress]]];
		}
	}
}

#define MAX_PACKAGE_SIZE (50*1024)	// Apple max package size recommendation

- (void) sendToAllMessage:(int) messageID {
	[self sendToAllMessage: messageID withData: nil];
}

- (void) sendToAllMessage:(int) messageID withData:(id<NSCoding>) data {
	for (BOMTalkPeer *peer in self.peerList)
		[self sendMessage:messageID toPeer:peer withData:data];
}

- (void) sendMessage:(int) messageID toPeer:(BOMTalkPeer*) peer {
	[self sendMessage:messageID toPeer:(BOMTalkPeer*) peer withData:nil];
}

- (void) notifyProgress: (float) progress {
	if ([self.delegate respondsToSelector:@selector(talkProgressForSending:)])
		[self.delegate talkProgressForSending: progress];
	if (self.progressSendingBlock)
		self.progressSendingBlock (progress);
	[[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:BOMTalkProgressForSendingNotification object: [NSNumber numberWithFloat: progress]]];
}

- (void) sendMessage:(int) messageID toPeer:(BOMTalkPeer*) peer withData:(id<NSCoding>) data {
	peer.state = BOMTalkPeerStateTransfering;
	[self notifyProgress: 0.0];

	if (data) {
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
			NSError *error = nil;
			NSData *blockData = [NSKeyedArchiver archivedDataWithRootObject:data];
			int packageCounter = (ceil)((float)blockData.length / MAX_PACKAGE_SIZE);
			for (int packageIndex=0; packageIndex < packageCounter; packageIndex++) {
				@autoreleasepool {
					[self.debugViewController addEvent: [BOMTalkDebugEvent eventFromPeer:self.selfPeer toPeer:peer message:@"Sending %d (%.2f)", messageID, ((float)packageIndex+1) / (float)packageCounter]];
					int packageLength = (packageIndex == packageCounter-1) ? blockData.length - (MAX_PACKAGE_SIZE * (packageCounter-1)) : MAX_PACKAGE_SIZE;
					BOMTalkPackage *package = [[BOMTalkPackage alloc] initWithMessage:messageID atIndex:packageIndex ofCounter:packageCounter data:[blockData subdataWithRange:NSMakeRange(packageIndex*MAX_PACKAGE_SIZE, packageLength)]];
					if (![self.sessionNetwork sendData:[NSKeyedArchiver archivedDataWithRootObject:package] toPeers:[NSArray arrayWithObject:peer.peerID] withDataMode:GKSendDataReliable error:&error])
						break;
				}
				float progress = ((float)packageIndex+1) / (float)packageCounter;
				if (progress < 1.0) {
					dispatch_async(dispatch_get_main_queue(), ^{
						peer.state = BOMTalkPeerStateTransfering;
						[self notifyProgress: progress];
					});
				}
			}
			dispatch_async(dispatch_get_main_queue(), ^{
				peer.state = BOMTalkPeerStateConnected;
				[self notifyProgress: 1.0];
			});
		});
	}
	else {
		NSError *error = nil;
		[self.debugViewController addEvent: [BOMTalkDebugEvent eventFromPeer:self.selfPeer toPeer: peer message:@"Sending %d", messageID]];
		BOMTalkPackage *package = [[BOMTalkPackage alloc] initWithMessage:messageID];
		[self.sessionNetwork sendData:[NSKeyedArchiver archivedDataWithRootObject:package] toPeers:[NSArray arrayWithObject:peer.peerID] withDataMode:GKSendDataReliable error:&error];
		peer.state = BOMTalkPeerStateConnected;
		[self notifyProgress: 1.0];
	}
}

@end
