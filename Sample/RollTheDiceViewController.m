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
	self.loadingView.hidden = self.rollButton.hidden = YES;
	self.numberView.text = self.infoView.text = @"";

	BOMTalk *talker = [BOMTalk sharedTalk];
	talker.delegate = self;
	[talker start];
}

- (void) viewWillDisappear:(BOOL) animated {
	[super viewWillDisappear:animated];
	BOMTalk *talker = [BOMTalk sharedTalk];
	[talker stop];
	talker.delegate = nil;
#ifdef BOMTalkDebug
	[[BOMTalk sharedTalk] hideDebugger];
#endif
}

- (void) viewDidUnload {
	self.numberView = nil;
	self.rollButton = nil;
	self.loadingView = nil;
	self.infoView = nil;
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
	// wait until all connected...
	for (BOMTalkPeer *peer in talker.peerList)
		if (peer.state < BOMTalkPeerStateConnected)
			return;
#ifdef BOMTalkDebug
	[talker addDebuggerMessage:@"%@", talker.selfPeer.userInfo[@"number"]];
#endif
	if ([talker.selfPeer.userInfo[@"starter"] boolValue]) {
		DLog(@"starting...");
		[[BOMTalk sharedTalk] sendToAllMessage:kRollStart];
	}
	else
		DLog(@"%@", talker.selfPeer);
}

- (void) talkReceived:(NSInteger) messageID fromPeer:(BOMTalkPeer*) sender withData:(id<NSCoding>) data {
	switch (messageID) {
		case kRollStart: {
			DLog(@"rec: %d %@ %@", messageID, sender, [BOMTalk sharedTalk].selfPeer);
			[self reset];
			self.rollButton.hidden = YES;
			self.loadingView.hidden = NO;
			self.numberView.text = @"";
			self.numberView.textColor = [UIColor grayColor];
			NSNumber *myRoll = [NSNumber numberWithInt: random() % 100];
			self.numberView.text = [NSString stringWithFormat:@"%@", myRoll];
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
				self.rollButton.hidden = NO;
				self.loadingView.hidden = YES;
				if ([talker.selfPeer isEqual: maxPeer])
					self.numberView.textColor = [UIColor greenColor];
				else
					self.numberView.textColor = [UIColor redColor];
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
			self.rollButton.hidden = NO;
			self.loadingView.hidden = YES;
			self.numberView.textColor = [UIColor greenColor];
		}
		break;

		case kRollLooser: {
			self.rollButton.hidden = NO;
			self.loadingView.hidden = YES;
			self.numberView.textColor = [UIColor redColor];
		}
		break;

		default:
			break;
	}
}

- (void) talkUpdate:(BOMTalkPeer*) peer {
	BOMTalk *talker = [BOMTalk sharedTalk];
	self.rollButton.hidden = (talker.peerList.count == 0 || !self.loadingView.hidden);
	self.infoView.text = [NSString stringWithFormat:@"%d players", talker.peerList.count];
}

- (void) talkNetworkFailed:(NSError*) error {
	[self reset];
}

- (void) talkConnectToPeerFailed:(NSError*) error {
	[self reset];
}

- (void) reset {
	self.rollButton.hidden = NO;
	self.loadingView.hidden = YES;
	self.numberView.text = @"";
	self.numberView.textColor = [UIColor blackColor];
	BOMTalk *talker = [BOMTalk sharedTalk];
	talker.selfPeer.userInfo[@"number"] = [NSNumber numberWithInt: -1];
	for (BOMTalkPeer *peer in talker.peerList)
		peer.userInfo[@"number"] = [NSNumber numberWithInt:-1];
	talker.selfPeer.userInfo[@"starter"] = [NSNumber numberWithBool:NO];
}

- (IBAction) roll {
	[self reset];

	NSNumber *myRoll = [NSNumber numberWithInt: random() % 100];
	self.numberView.text = [NSString stringWithFormat:@"%@", myRoll];
	self.rollButton.hidden = YES;
	self.loadingView.hidden = NO;
	self.numberView.textColor = [UIColor grayColor];

	BOMTalk *talker = [BOMTalk sharedTalk];
	talker.selfPeer.userInfo[@"number"] = myRoll;
	talker.selfPeer.userInfo[@"starter"] = [NSNumber numberWithBool:YES];
	DLog(@"%@\n%@", talker.selfPeer, talker.peerList);
	for (BOMTalkPeer *peer in talker.peerList)
		[talker connectToPeer: peer];
}

@end
