//
//  BOMTalk
//	werk01.de
//

#import "BOMTalk.h"
#import "BOMTalkPackage.h"

@interface BOMTalk ()
@property (strong, nonatomic) GKSession *sessionNetwork;

@property (readwrite, nonatomic, copy) BOMTalkBlock showBlock;
@property (readwrite, nonatomic, copy) BOMTalkBlock hideBlock;
@property (readwrite, nonatomic, copy) BOMTalkBlock connectBlock;
@property (readwrite, nonatomic, copy) BOMTalkBlock disconnectBlock;

@property (strong, nonatomic) NSMutableArray *messageList;
@property (readwrite, nonatomic, copy) BOMTalkBlock updateBlock;
@property (readwrite, nonatomic, copy) BOMTalkErrorBlock failureBlock;

@property (readwrite, nonatomic, copy) BOMTalkBlock connectSuccessBlock;
@property (readwrite, nonatomic, copy) BOMTalkErrorBlock connectFailureBlock;

@end

@implementation BOMTalk

#pragma mark initializing

+ (BOMTalk*) sharedTalk {
	static BOMTalk *sessionController = nil;
	if (!sessionController)
		sessionController = [[BOMTalk alloc] init];
	return sessionController;
}

- (id) init {
	if ((self = [super init])) {
		_peerList = [[NSMutableArray alloc] init];
		_messageList = [[NSMutableArray alloc] init];
	}
#ifdef DEBUG
	[NSTimer scheduledTimerWithTimeInterval:30 target:self selector:@selector(scheduler:) userInfo:nil repeats:YES];
#endif
	return self;
}

#ifdef DEBUG
- (void) scheduler:(NSTimer*) theTimer {
	DLog(@"asServer: %d with %@", self.asServer, _selfPeer);
	DLog(@"asClient: %d with %@", !self.asServer, _serverPeer);
	for (BOMTalkPeer *peer in _peerList)
		DLog(@"%@", peer);
}
#endif

#pragma mark network handling

- (void) startInMode:(GKSessionMode) mode {
	[self startInMode:mode didShow:nil didHide:nil didConnect:nil didDisconnect:nil];
}

- (void) startInMode:(GKSessionMode) mode didShow:(BOMTalkBlock) showBlock didHide:(BOMTalkBlock) hideBlock didConnect:(BOMTalkBlock) connectBlock didDisconnect:(BOMTalkBlock) disconnectBlock {
	DLog(@"start");
	if (_sessionNetwork)
		return;

	_showBlock = showBlock;
	_hideBlock = hideBlock;
	_connectBlock = connectBlock;
	_disconnectBlock = disconnectBlock;
	_mode = mode;
	_sessionNetwork = [[GKSession alloc] initWithSessionID:nil displayName:nil sessionMode: _mode];
	_sessionNetwork.delegate = self;
	[_sessionNetwork setDataReceiveHandler:self withContext:nil];
	[self show];
	_selfPeer = [[BOMTalkPeer alloc] initWithPeer:_sessionNetwork.peerID name: [_sessionNetwork displayName]];
	DLog(@"me: connect %@", _selfPeer);
}

- (void) stop {
	DLog(@"");
	[_sessionNetwork disconnectFromAllPeers];
	[self hide];
	[_sessionNetwork setDataReceiveHandler: nil withContext: NULL];
	_sessionNetwork.delegate = nil;
	_sessionNetwork = nil;
	_selfPeer = nil;
	_serverPeer = nil;
	[_peerList removeAllObjects];
	_delegate = nil;

	_showBlock = nil;
	_hideBlock = nil;
	_connectBlock = nil;
	_disconnectBlock = nil;
	
	[_messageList removeAllObjects];
	_updateBlock = nil;
	_failureBlock = nil;

	_connectSuccessBlock = nil;
	_connectFailureBlock = nil;
}

- (void) reset {
	DLog(@"");
	GKSessionMode mode = _mode;
	[self stop];
	[self startInMode:mode];
}

- (BOOL) asServer {
	return (_mode == GKSessionModeServer || _mode == GKSessionModePeer);
}

- (void) show {
	DLog(@"");
	_sessionNetwork.available = YES;
}

- (void) hide {
	DLog(@"");
	_sessionNetwork.available = NO;
}

- (void) session:(GKSession*) session didFailWithError:(NSError*) error {
	DLog(@"%@", error.localizedDescription);
	[self stop];
	if ([_delegate respondsToSelector:@selector(talkFailed:)])
		[_delegate talkFailed:error];
	else if (_failureBlock)
		_failureBlock(error);
	else
		[[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:kBOMTalkFailedNotification object:error]];
}

#pragma mark block based callbacks

- (void) answerToMessage:(NSInteger) messageID block: (BOMTalkMessageBlock) block {
	[_messageList addObject: @{@"messageID": [NSNumber numberWithInt: messageID], @"block": block}];
}

- (void) answerToUpdate: (BOMTalkBlock) block {
	_updateBlock = block;
}

- (void) answerToFailure: (BOMTalkErrorBlock) block {
	_failureBlock = block;
}

#pragma mark client handling

- (BOMTalkPeer*) peerForPeerID:(NSString*) peerID {
	BOMTalkPeer *peer = nil;
	NSUInteger pos = [_peerList indexOfObjectPassingTest:^BOOL(id obj, NSUInteger idx, BOOL *stop) {
		if ([[(BOMTalkPeer*)obj peerID] isEqual:peerID]) {
			*stop = YES;
			return YES;
		}
		return NO;
	}];
	if (NSNotFound != pos)
		peer = _peerList[pos];
	else if ([_selfPeer.peerID isEqual: peerID])	// fetch ANY peer object
		peer = _selfPeer;
	return peer;
}

- (void) connectToPeer:(BOMTalkPeer*) peer {
	[self connectToPeer:peer success:nil failure:nil];
}

- (void) connectToPeer:(BOMTalkPeer*) peer success:(BOMTalkBlock) successBlock {
	[self connectToPeer:peer success:successBlock failure:nil];
}

- (void) connectToPeer:(BOMTalkPeer*) peer success:(BOMTalkBlock) successBlock failure:(BOMTalkErrorBlock) failureBlock {
	DLog(@"connect to %@", peer);
	if (BOMTalkPeerStateConnecting == peer.state)
		return;
	if (BOMTalkPeerStateConnected == peer.state && [_peerList containsObject:peer]) {
		if ([_delegate respondsToSelector:@selector(talkDidConnect:)])
			[_delegate talkDidConnect: peer];
		else if (successBlock)
			successBlock(peer);
	}
	else {
		_connectSuccessBlock = successBlock;
		_connectFailureBlock = failureBlock;
		peer.state = BOMTalkPeerStateConnecting;
		[_sessionNetwork connectToPeer:peer.peerID withTimeout:10.0];
	}
}

- (void) disconnectPeer:(BOMTalkPeer*) peer {
	DLog(@"disco from %@", peer);
	[_sessionNetwork disconnectPeerFromAllPeers: peer.peerID];
	if ([_delegate respondsToSelector:@selector(talkDidDisconnect:)])
		[_delegate talkDidDisconnect: peer];
	else if (_connectFailureBlock)
		_connectFailureBlock(nil);
	_connectSuccessBlock = nil;
	_connectFailureBlock = nil;
}

- (void) session:(GKSession*) session didReceiveConnectionRequestFromPeer:(NSString*) peerID {
	DLog(@"conn request: %@", peerID);
	NSError *error = nil;
	if (self.asServer) {	// auto-accept all clients as server
		if (![_sessionNetwork acceptConnectionFromPeer:peerID error:&error])
			DLog(@"conn request acc failed: %@", error.localizedDescription);
	}
	else
		[session denyConnectionFromPeer:peerID];
}

- (void) session:(GKSession*) session connectionWithPeerFailed:(NSString*) peerID withError:(NSError*) error {
	DLog(@"conn failed: %@ %@", peerID, error.localizedDescription);
	[_peerList removeObject: [self peerForPeerID:peerID]];
	if ([_delegate respondsToSelector:@selector(talkFailed:)])
		[_delegate talkFailed:error];
	else if (_connectFailureBlock) {
		_connectFailureBlock (error);
		_connectSuccessBlock = nil;
		_connectFailureBlock = nil;
	}
	else if (_failureBlock)
		_failureBlock (error);
	else
		[[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:kBOMTalkFailedNotification object:error]];
}

- (void) session:(GKSession*) session peer:(NSString*) peerID didChangeState:(GKPeerConnectionState) state {
	if ([[session displayNameForPeer:session.peerID] isEqual:[session displayNameForPeer:peerID]])	// prevent self messages due to change in peerIDs to same client
		return;

	BOMTalkPeer *peer = [self peerForPeerID:peerID];
	if (!peer)
		peer = [[BOMTalkPeer alloc] initWithPeer:peerID name: [_sessionNetwork displayNameForPeer:peerID]];

	switch (state) {
		// server states
		case GKPeerStateAvailable: {
			DLog(@"GKPeerStateAvailable %@", peer);
			peer.state = MAX(BOMTalkPeerStateVisible, peer.state);
			if (![_peerList containsObject:peer])
				[_peerList addObject:peer];
			if ([self.delegate respondsToSelector:@selector(talkDidShow:)])
				[self.delegate talkDidShow:peer];
			else if (_showBlock)
				_showBlock (peer);
			else
				[[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:kBOMTalkDidShowNotification object: peer]];
		}
		break;

		case GKPeerStateUnavailable: {
			DLog(@"GKPeerStateUnavailable %@", peer);
			[_peerList removeObject:peer];
			if ([_serverPeer.peerID isEqual:peer.peerID])
				_serverPeer = nil;
			if ([self.delegate respondsToSelector:@selector(talkDidHide:)])
				[self.delegate talkDidHide: peer];
			else if (_hideBlock)
				_hideBlock (peer);
			else
				[[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:kBOMTalkDidHideNotification object: peer]];
		}
		break;

		// client states
		case GKPeerStateConnecting: {
			DLog(@"GKPeerStateConnecting %@", peer);
			peer.state = MAX(BOMTalkPeerStateConnecting, peer.state);
		}
		break;

		case GKPeerStateConnected: {
			DLog(@"GKPeerStateConnected %@", peer);
			peer.state = MAX(BOMTalkPeerStateConnected, peer.state);
			_serverPeer = peer;
			if ([self.delegate respondsToSelector:@selector(talkDidConnect:)])
				[self.delegate talkDidConnect: peer];
			else if (_connectBlock)
				_connectBlock (peer);
			else if (_connectSuccessBlock) {
				_connectSuccessBlock (peer);
				_connectSuccessBlock = nil;
				_connectFailureBlock = nil;
			}
			else
				[[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:kBOMTalkDidConnectNotification object: peer]];
		}
		break;
			
		case GKPeerStateDisconnected: {
			DLog(@"GKPeerStateDisconnected %@", peer);
			[_peerList removeObject: peer];
			if ([_serverPeer.peerID isEqual:peer.peerID])
				_serverPeer = nil;
			if ([self.delegate respondsToSelector:@selector(talkDidDisconnect:)])
				[self.delegate talkDidDisconnect: peer];
			else if (_disconnectBlock)
				_disconnectBlock (peer);
			else
				[[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:kBOMTalkDidDisconnectNotification object: peer]];
		}
		break;
	}
	// fire general update mechanism
	if ([_delegate respondsToSelector:@selector(talkUpdate:)])
		[_delegate talkUpdate: peer];
	else if (_updateBlock)
		_updateBlock(peer);
	else
		[[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:kBOMTalkUpdateNotification object: peer]];
}

- (void) receiveData:(NSData*) data fromPeer:(NSString*) peerID inSession: (GKSession*) session context:(void*) context {
	static BOMTalkPackage *lastPackage = nil;
	static NSString *lastPeerID = nil;

	BOMTalkPeer *peer = [self peerForPeerID:peerID];
	if (!peer)
		peer = [[BOMTalkPeer alloc] initWithPeer:peerID name: [_sessionNetwork displayNameForPeer:peerID]];
	@try {
		peer.state = BOMTalkPeerStateTransfering;
		BOMTalkPackage *package = [NSKeyedUnarchiver unarchiveObjectWithData:data];
		DLog (@"received %@ from %@", package, peer);

		// models one message per peer per sequence
		if (!lastPackage || ![lastPeerID isEqual:peer.peerID] || ![lastPackage appendPackage:package]) {
			BOMTalkPeer *lastPeer = [self peerForPeerID: lastPeerID];
			if (lastPeer && lastPeer.state == BOMTalkPeerStateTransfering)
				lastPeer.state = BOMTalkPeerStateConnected;
			lastPackage = nil;
			lastPeerID = nil;
			if (!package.index) {
				lastPackage = package;
				lastPeerID = [peer.peerID copy];
			}
		}
	}
	@catch (NSException *exception) {
		lastPackage = nil;
		lastPeerID = nil;
	}
	@finally {
		if (lastPackage.isComplete) {
			id<NSCoding> lastData = nil;
			if (lastPackage.data)
				lastData = [NSKeyedUnarchiver unarchiveObjectWithData:lastPackage.data];
			if ([_delegate respondsToSelector:@selector(talkReceived:fromPeer:withData:)])
					[_delegate talkReceived:lastPackage.messageID fromPeer:peer withData: lastData];
			else {
				BOOL blockFired = NO;
				for (NSDictionary *messageDict in _messageList) {
					if (lastPackage.messageID == [messageDict[@"messageID"] integerValue]) {
						BOMTalkMessageBlock messageBlock = messageDict[@"block"];
						messageBlock(peer, lastData);
						blockFired = YES;
					}
				}
				if (!blockFired)
					[[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:kBOMTalkReceivedNotification object:@{@"messageID": [NSNumber numberWithInt:lastPackage.messageID], @"peer": peer, @"data": lastData}]];
			}
			peer.state = BOMTalkPeerStateConnected;
			lastData = nil;
			lastPackage = nil;
			lastPeerID = nil;

			// GamkeKit has maximum of 16 connections, so keep one slot free
			if (self.asServer) {
				[peer update];
				[_peerList sortUsingComparator:^NSComparisonResult(id obj1, id obj2) {
					BOMTalkPeer *peer1 = (BOMTalkPeer*) obj1;
					BOMTalkPeer *peer2 = (BOMTalkPeer*) obj2;
					if (peer1.timestamp == peer2.timestamp)
						return NSOrderedSame;
					else if (peer1.timestamp < peer2.timestamp)
						return NSOrderedDescending;
					else
						return NSOrderedAscending;
				}];
				while (_peerList.count > 15)
					[self disconnectPeer:[_peerList lastObject]];
			}
		}
	}
}

#define MAX_PACKAGE_SIZE (50*1024)	// Apple max package size recommendation

- (void) sendToAllMessage:(int) messageID {
	[self sendToAllMessage: messageID withData: nil];
}

- (void) sendToAllMessage:(int) messageID withData:(id<NSCoding>) data {
	for (BOMTalkPeer *peer in _peerList)
		[self sendMessage:messageID toPeer:peer withData:data];
}

- (BOOL) sendMessage:(int) messageID toPeer:(BOMTalkPeer*) peer {
	return [self sendMessage:messageID toPeer:(BOMTalkPeer*) peer withData:nil];
}

- (BOOL) sendMessage:(int) messageID toPeer:(BOMTalkPeer*) peer withData:(id<NSCoding>) data {
	NSError *error = nil;
	if (data) {
		NSData *blockData = [NSKeyedArchiver archivedDataWithRootObject:data];
		DLog(@"sending %d to %@ len:%d", messageID, peer, blockData.length);
		int packageCounter = (ceil)((float)blockData.length / MAX_PACKAGE_SIZE);
		for (int packageIndex=0; packageIndex < packageCounter; packageIndex++) {
			int packageLength = (packageIndex == packageCounter-1) ? blockData.length - (MAX_PACKAGE_SIZE * (packageCounter-1)) : MAX_PACKAGE_SIZE;
			DLog(@"package %d: %d", packageIndex, packageLength);
			BOMTalkPackage *package = [[BOMTalkPackage alloc] initWithMessage:messageID atIndex:packageIndex ofCounter:packageCounter data:[blockData subdataWithRange:NSMakeRange(packageIndex*MAX_PACKAGE_SIZE, packageLength)]];
			if (![_sessionNetwork sendData:[NSKeyedArchiver archivedDataWithRootObject:package] toPeers:[NSArray arrayWithObject:peer.peerID] withDataMode:GKSendDataReliable error:&error] ||
					error) {
				DLog(@"error: %@", error.localizedDescription);
				return NO;
			}
		}
	}
	else {
		DLog(@"sending %d to %@", messageID, peer);
		BOMTalkPackage *package = [[BOMTalkPackage alloc] initWithMessage:messageID];
		if (![_sessionNetwork sendData:[NSKeyedArchiver archivedDataWithRootObject:package] toPeers:[NSArray arrayWithObject:peer.peerID] withDataMode:GKSendDataReliable error:&error] ||
				error) {
			DLog(@"error: %@", error.localizedDescription);
			return NO;
		}
	}
	return YES;
}

@end
