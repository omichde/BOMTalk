//
//  BOMTalkDebugViewController.m
//  BOMTalk
//
//  Created by Oliver Michalak on 30.04.13.
//  Copyright (c) 2013 Oliver Michalak. All rights reserved.
//

#import "BOMTalkDebugViewController.h"

#define kPeerWidth (100.0)
#define kPeerHeight (20.0)
#define kEventsize (20.0)
#define kYScale (5.0)

@interface BOMTalkDebugViewController ()
@property (strong, nonatomic) NSMutableArray *peerList;
@property (strong, nonatomic) NSMutableArray *eventList;
@end

@implementation BOMTalkDebugViewController

- (void) viewDidLoad {
	[super viewDidLoad];
	_peerList = [[NSMutableArray alloc] init];
	_eventList = [[NSMutableArray alloc] init];
}

- (void) viewDidUnload {
	_scrollContainer = nil;
	[super viewDidUnload];
}

- (IBAction) closeView {
	[self.view removeFromSuperview];
	[self removeFromParentViewController];
}

- (void) addEvent: (BOMTalkDebugEvent*) event {
	if (![_peerList containsObject: event.sourcePeer]) {
		UILabel *peerLabel = [[UILabel alloc] initWithFrame: CGRectMake (_peerList.count*kPeerWidth, 0, kPeerWidth, kPeerHeight)];
		peerLabel.adjustsFontSizeToFitWidth = YES;
		peerLabel.minimumFontSize = 6.0;
		peerLabel.backgroundColor = [UIColor colorWithRed:1 green:0 blue:0 alpha:0.5];
		peerLabel.text = event.sourcePeer.name;
		[_scrollContainer addSubview: peerLabel];
		[_peerList addObject: event.sourcePeer];
	}
	if (event.destPeer && ![_peerList containsObject: event.destPeer]) {
		UILabel *peerLabel = [[UILabel alloc] initWithFrame: CGRectMake (_peerList.count*kPeerWidth, 0, kPeerWidth, kPeerHeight)];
		peerLabel.backgroundColor = [UIColor colorWithRed:1 green:0 blue:0 alpha:0.5];
		peerLabel.text = event.destPeer.name;
		[_scrollContainer addSubview: peerLabel];
		[_peerList addObject: event.destPeer];
	}
	
	CGFloat y = kPeerHeight, x = kPeerWidth * [_peerList indexOfObject: event.sourcePeer];
	if (_eventList.count) {
		BOMTalkDebugEvent *startEvent = _eventList[0];
		y += floor([event.timestamp timeIntervalSinceDate: startEvent.timestamp] * kYScale);
	}
	CGFloat width = kEventsize;
	if (event.destPeer)
		width = kPeerWidth * [_peerList indexOfObject: event.destPeer] + kPeerWidth - x;
	UIButton *eventButton = [UIButton buttonWithType: UIButtonTypeRoundedRect];
	eventButton.frame = CGRectMake (x, y, width, kEventsize);
	eventButton.backgroundColor = [UIColor clearColor];
	eventButton.titleLabel.font = [UIFont systemFontOfSize:10];
	eventButton.titleLabel.adjustsFontSizeToFitWidth = YES;
	eventButton.titleLabel.minimumFontSize = 6.0;
	[eventButton setTitleColor: [UIColor blackColor] forState:UIControlStateNormal];
	[eventButton setTitle: event.message forState:UIControlStateNormal];
	[_scrollContainer addSubview: eventButton];
	[_eventList addObject: event];
	
	[self layout];
}

- (void) layout {
	CGFloat height = (_peerList.count ? kPeerHeight : 0);
	if (_eventList.count) {
		BOMTalkDebugEvent *startEvent = _eventList[0];
		BOMTalkDebugEvent *endEvent = [_eventList lastObject];
		NSTimeInterval span = [endEvent.timestamp timeIntervalSinceDate: startEvent.timestamp];
		height += floor(span) * kYScale + kEventsize;
	}
	_scrollContainer.contentSize = CGSizeMake(_peerList.count * kPeerWidth, height);
}
@end
