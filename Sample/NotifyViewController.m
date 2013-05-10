//
//  NotifyViewController.m
//  BOMTalk
//
//  Created by Oliver Michalak on 26.04.13.
//  Copyright (c) 2013 Oliver Michalak. All rights reserved.
//

#import "NotifyViewController.h"
#import "BOMTalk.h"

#define kGameStart (301)				// server starts a game
#define kGameBall (302)					// server sends coordinates of the ball, client need to reverse coordinates
#define kGameCheck (303)				// server wants client to check, wether client racket hit the ball
#define kGameClientHit (304)		// client hit the ball
#define kGameClientMissed (305)	// client missed the ball
#define kGameServerMissed (306)	// server missed the ball

#define kXFactor (3.0)

@interface NotifyViewController ()
@property (assign, nonatomic) int counter;
@property (strong, nonatomic) NSTimer *timer;
@property (assign, nonatomic) CGPoint vector;
@property (assign, nonatomic) BOOL asServer;
@property (strong, nonatomic) BOMTalkPeer *partnerPeer;
@property (assign, nonatomic) BOOL waitingForClient;
@end

@implementation NotifyViewController

- (void) viewDidLoad {
	[super viewDidLoad];
#ifdef BOMTalkDebug
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSearch target:self action:@selector(debuggerShow)];
#endif
	srandom(time(NULL));
	_slideView.value = 0.5;
	[self slide];
}

- (void) viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	_timer = [NSTimer scheduledTimerWithTimeInterval:0.05 target:self selector:@selector(update:) userInfo:nil repeats:YES];
	[self reset];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateTalk:) name:kBOMTalkUpdateNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(errorTalk:) name:kBOMTalkFailedNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(connectedTalk:) name:kBOMTalkDidConnectNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(receivedTalk:) name:kBOMTalkReceivedNotification object:nil];
	BOMTalk *talker = [BOMTalk sharedTalk];
	[talker startInMode:GKSessionModePeer];
}

- (void) viewDidDisappear:(BOOL)animated {
	[super viewDidDisappear:animated];
	[[NSNotificationCenter defaultCenter] removeObserver: self];
	[[BOMTalk sharedTalk] stop];
}

- (void) viewDidUnload {
	[_timer invalidate];
	_timer = nil;
	_ballView = nil;
	_racketView = nil;
	_slideView = nil;
	_areaView = nil;
	_listView = nil;
	[super viewDidUnload];
}

#ifdef BOMTalkDebug
- (void) debuggerShow {
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSearch target:self action:@selector(debuggerHide)];
	[[BOMTalk sharedTalk] showDebuggerFromViewController: self];
}

- (void) debuggerHide {
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSearch target:self action:@selector(debuggerShow)];
	[[BOMTalk sharedTalk] hideDebugger];
}
#endif

#pragma mark talk notifications callbacks

- (void) updateTalk: (NSNotification*) notification {
	[_listView reloadData];
	if (_partnerPeer && ![[BOMTalk sharedTalk].peerList containsObject:_partnerPeer])
		[self reset];
}

- (void) errorTalk: (NSNotification*) notification {
	[self reset];
}

- (void) connectedTalk: (NSNotification*) notification {
	[self startGameWithPeer: notification.object];
}

- (void) receivedTalk: (NSNotification*) notification {
	BOMTalk *talker = [BOMTalk sharedTalk];
	BOMTalkPeer *peer = notification.object[@"peer"];
	NSNumber *message = notification.object[@"messageID"];
	switch (message.integerValue) {
		case kGameStart: {
			[self reset];
			_listView.hidden = YES;
			_asServer = NO;
		}
			break;
		case kGameBall: {
			_ballView.center = CGPointMake(2*_areaView.frame.origin.x+_areaView.frame.size.width - [notification.object[@"data"][@"x"] floatValue], 2*_areaView.frame.origin.y+_areaView.frame.size.height - [notification.object[@"data"][@"y"] floatValue]);
		}
			break;
		case kGameCheck: {
			CGPoint pos = CGPointMake(2*_areaView.frame.origin.x+_areaView.frame.size.width - [notification.object[@"data"][@"x"] floatValue], 2*_areaView.frame.origin.y+_areaView.frame.size.height - [notification.object[@"data"][@"y"] floatValue]);
			if (CGRectContainsPoint(_racketView.frame, CGPointMake (pos.x, pos.y + CGRectGetHeight(_ballView.frame) / 2.0)))	// not precise !!!
				[talker sendMessage: kGameClientHit toPeer:peer];
			else
				[talker sendMessage: kGameClientMissed toPeer:peer];
		}
			break;
		case kGameClientHit: {
			_waitingForClient = NO;
			_vector.y -= 1;	// increase speed
			_vector.y *= -1;
			[self update:nil];
		}
			break;
		case kGameClientMissed: {
			[self reset];
			_counter++;
			self.title = [NSString stringWithFormat:@"Pong: %d", _counter];
			_asServer = YES;
			[self startGameWithPeer: peer];
		}
			break;
		case kGameServerMissed: {
			_counter++;
			self.title = [NSString stringWithFormat:@"Pong: %d", _counter];
		}
			break;
	}
}

- (void) reset {
	_waitingForClient = NO;
	_listView.hidden = NO;
	_asServer = NO;
	_partnerPeer = nil;
	_ballView.center = CGPointMake(CGRectGetMidX(_areaView.frame), CGRectGetMinY(_areaView.frame));
	_vector = CGPointMake ((0.1 + kXFactor * (CGFloat)(random() % 100) / 100.0) * (random() % 10 >= 5 ? 1 : -1), 2);
	self.title = [NSString stringWithFormat:@"Pong: %d", _counter];
}

- (void) startGameWithPeer:(BOMTalkPeer*) peer {
	_partnerPeer = peer;
	_listView.hidden = YES;
	self.title = [NSString stringWithFormat:@"Pong: %d", _counter];
	if (_asServer)
		[[BOMTalk sharedTalk] sendMessage:kGameStart toPeer:_partnerPeer];
}

- (void) update:(NSNotification*) notification {
	if (!_listView.hidden || !_asServer || _waitingForClient)
		return;
	CGPoint pos = CGPointMake(_ballView.center.x + _vector.x, _ballView.center.y + _vector.y);
	if (!CGRectContainsPoint(_areaView.frame, pos)) {
		if (pos.x < CGRectGetMinX(_areaView.frame) || pos.x > CGRectGetMaxX(_areaView.frame)) {	// horizontal shift
			_vector.x *= -1;
			pos = CGPointMake(_ballView.center.x + _vector.x, _ballView.center.y + _vector.y);
		}
		if (pos.y < CGRectGetMinY(_areaView.frame)) {	// moved out of top
			if (_asServer) {
				_waitingForClient = YES;
				[[BOMTalk sharedTalk] sendMessage:kGameCheck toPeer:_partnerPeer withData: @{@"x": [NSNumber numberWithFloat:pos.x], @"y": [NSNumber numberWithFloat:pos.y]}];
				return;
			}
			else {
				_vector.y -= 1;	// increase speed
				_vector.y *= -1;
				pos = CGPointMake(_ballView.center.x + _vector.x, _ballView.center.y + _vector.y);
			}
		}
		if (pos.y > CGRectGetMaxY(_areaView.frame)) {	// moved out of bottom
			if (CGRectContainsPoint(_racketView.frame, CGPointMake (pos.x, pos.y + CGRectGetHeight(_ballView.frame) / 2.0))) {	// not precise !!!
				_vector.y = MIN(CGRectGetHeight(_racketView.frame), _vector.y + 1);	// increase speed
				_vector.y *= -1;
				_vector.x += kXFactor * (pos.x - CGRectGetMinX(_racketView.frame) - CGRectGetWidth(_racketView.frame) / 2.0) / (CGRectGetWidth(_racketView.frame) / 2.0);
				pos = CGPointMake(_ballView.center.x + _vector.x, _ballView.center.y + _vector.y);
			}
			else {
				BOOL serving = _asServer;
				BOMTalkPeer *peer = _partnerPeer;
				[self reset];
				if (serving && peer) {
					[[BOMTalk sharedTalk] sendMessage:kGameServerMissed toPeer: peer];
					_asServer = YES;
					[self startGameWithPeer: peer];
				}
				return;
			}
		}
	}
	_ballView.center = pos;
	if (_asServer)
		[[BOMTalk sharedTalk] sendMessage:kGameBall toPeer:_partnerPeer withData: @{@"x": [NSNumber numberWithFloat:pos.x], @"y": [NSNumber numberWithFloat:pos.y]}];
}

#pragma mark move the slider

- (IBAction) slide {
	_racketView.frame = CGRectMake(_slideView.value * (self.view.frame.size.width - _racketView.frame.size.width), CGRectGetMaxY(_areaView.frame) + CGRectGetHeight(_ballView.frame)/2.0, _racketView.frame.size.width, _racketView.frame.size.height);
}

#pragma mark table view delegates

- (NSInteger) tableView:(UITableView*) tableView numberOfRowsInSection:(NSInteger) section {
	return [BOMTalk sharedTalk].peerList.count;
}

- (UITableViewCell*) tableView:(UITableView*) tableView cellForRowAtIndexPath:(NSIndexPath*) indexPath {
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PeerCell"];
	if (!cell)
		cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"PeerCell"];
	BOMTalkPeer *peer = [BOMTalk sharedTalk].peerList[indexPath.row];
	cell.textLabel.text = peer.name;
	return cell;
}

- (void) tableView:(UITableView*) tableView didSelectRowAtIndexPath:(NSIndexPath*) indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	BOMTalk *talker = [BOMTalk sharedTalk];
	BOMTalkPeer *peer = talker.peerList[indexPath.row];
	_asServer = YES;
	if (peer.state == BOMTalkPeerStateConnected)
		[self startGameWithPeer:peer];
	else
		[talker connectToPeer: peer];
}

@end