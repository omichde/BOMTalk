//
//  DelegatesViewController.m
//  BOMTalk
//
//	a simple roll-the-dice-game
//	auto-connects to all visible devices
//	one device starts, all other devices will answer with their rolls, initiating device broadcasts the results back
//	stores rolled number for all client in custom userInfo dictionary
//
//  Created by Oliver Michalak on 24.04.13.
//  Copyright (c) 2013 Oliver Michalak. All rights reserved.
//

#import "RollTheDiceViewController.h"

#define kRollStart (201)
#define kRollAnswer (202)
#define kRollWinner (203)
#define kRollLooser (204)

@interface RollTheDiceViewController ()
@end

@implementation RollTheDiceViewController

- (void) viewDidLoad {
	[super viewDidLoad];
#ifdef BOMTalkDebug
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSearch target:self action:@selector(debuggerShow)];
#endif
	srandom(time(NULL));
}

- (void) viewWillAppear:(BOOL) animated {
	[super viewWillAppear:animated];
	_loadingView.hidden = YES;
	_numberView.text = _infoView.text = @"";

	BOMTalk *talker = [BOMTalk sharedTalk];
	talker.delegate = self;
	[talker startInMode:GKSessionModePeer];
}

- (void) viewWillDisappear:(BOOL) animated {
	[super viewWillDisappear:animated];
	[[BOMTalk sharedTalk] stop];
#ifdef BOMTalkDebug
	[[BOMTalk sharedTalk] hideDebugger];
#endif
}

- (void) viewDidUnload {
	_numberView = nil;
	_rollButton = nil;
	_loadingView = nil;
	_infoView = nil;
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

#pragma mark talk delegates

- (void) talkDidConnect:(BOMTalkPeer*) peer {
	BOMTalk *talker = [BOMTalk sharedTalk];
	[talker addDebuggerMessage:@"%@", talker.selfPeer.userInfo[@"number"]];
	if ([talker.selfPeer.userInfo[@"number"] integerValue] != -1)
		[[BOMTalk sharedTalk] sendToAllMessage:kRollStart];
}

- (void) talkReceived:(NSInteger) messageID fromPeer:(BOMTalkPeer*) sender withData:(id<NSCoding>) data {
	switch (messageID) {
		case kRollStart: {
			[self reset];
			_rollButton.hidden = YES;
			_loadingView.hidden = NO;
			_numberView.text = @"";
			_numberView.textColor = [UIColor grayColor];
			NSNumber *myRoll = [NSNumber numberWithInt: random() % 100];
			_numberView.text = [NSString stringWithFormat:@"%@", myRoll];
			[[BOMTalk sharedTalk] sendMessage:kRollAnswer toPeer:sender withData: myRoll];
		}
		break;

		case kRollAnswer: {
			sender.userInfo[@"number"] = (NSNumber*) data;
			BOOL completed = YES;
			BOMTalk *talker = [BOMTalk sharedTalk];
			BOMTalkPeer *maxPeer = talker.selfPeer;
			for (BOMTalkPeer *peer in talker.peerList) {
				if ([peer.userInfo[@"number"] integerValue] < 0)
					completed = NO;
				if (!maxPeer || [peer.userInfo[@"number"] integerValue] > [maxPeer.userInfo[@"number"] integerValue])
					maxPeer = peer;
			}
			if (completed) {
				_rollButton.hidden = NO;
				_loadingView.hidden = YES;
				if ([talker.selfPeer isEqual: maxPeer])
					_numberView.textColor = [UIColor greenColor];
				else
					_numberView.textColor = [UIColor redColor];
				for (BOMTalkPeer *peer in talker.peerList) {
					if ([maxPeer isEqual: peer])
						[talker sendMessage:kRollWinner toPeer:peer];
					else
						[talker sendMessage:kRollLooser toPeer:peer];
				}
			}
		}
		break;

		case kRollWinner: {
			_rollButton.hidden = NO;
			_loadingView.hidden = YES;
			_numberView.textColor = [UIColor greenColor];
		}
		break;

		case kRollLooser: {
			_rollButton.hidden = NO;
			_loadingView.hidden = YES;
			_numberView.textColor = [UIColor redColor];
		}
		break;

		default:
			break;
	}
}

- (void) talkUpdate:(BOMTalkPeer*) peer {
	_infoView.text = [NSString stringWithFormat:@"%d players", [BOMTalk sharedTalk].peerList.count];
}

- (void) talkNetworkFailed:(NSError*) error {
	[self reset];
}

- (void) talkConnectToPeerFailed:(NSError*) error {
	[self reset];
}

- (void) reset {
	_rollButton.hidden = NO;
	_loadingView.hidden = YES;
	_numberView.text = @"";
	_numberView.textColor = [UIColor blackColor];
	BOMTalk *talker = [BOMTalk sharedTalk];
	talker.selfPeer.userInfo[@"number"] = [NSNumber numberWithInt: -1];
	for (BOMTalkPeer *peer in talker.peerList)
		peer.userInfo[@"number"] = [NSNumber numberWithInt:-1];
}

- (IBAction) roll {
	[self reset];
	_rollButton.hidden = YES;
	_loadingView.hidden = NO;
	_numberView.textColor = [UIColor grayColor];

	NSNumber *myRoll = [NSNumber numberWithInt: random() % 100];
	_numberView.text = [NSString stringWithFormat:@"%@", myRoll];
	BOMTalk *talker = [BOMTalk sharedTalk];
	talker.selfPeer.userInfo[@"number"] = myRoll;
	for (BOMTalkPeer *peer in talker.peerList)
		[talker connectToPeer: peer];
}

@end
