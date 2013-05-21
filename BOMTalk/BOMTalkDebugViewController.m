//
//  BOMTalkDebugViewController.m
//  BOMTalk
//
//  Created by Oliver Michalak on 30.04.13.
//  Copyright (c) 2013 Oliver Michalak. All rights reserved.
//

#import "BOMTalkDebugViewController.h"

#define kPeerWidth (40.0)
#define kPeerHeight (100.0)
#define kTagEvent (1000)

@interface BOMTalkDebugViewController ()
@property (strong, nonatomic) NSMutableArray *peerList;
@property (strong, nonatomic) NSMutableArray *eventList;
@property (assign, nonatomic) CGFloat scale;
@property (strong, nonatomic) NSTimer *updateTimer;
@end

@implementation BOMTalkDebugViewController

- (void) viewDidLoad {
	[super viewDidLoad];
	[self.scrollContainer addGestureRecognizer:[[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinch:)]];
	self.scale = 10.0;
	self.peerList = [[NSMutableArray alloc] init];
	self.eventList = [[NSMutableArray alloc] init];
}

- (void) viewDidUnload {
	self.scrollContainer = nil;
	self.backContainer = nil;
	[super viewDidUnload];
}

- (void) pinch: (UIPinchGestureRecognizer*) gesture {
	static CGFloat scale;
	switch (gesture.state) {
		case UIGestureRecognizerStateBegan:
			scale = self.scale;
			break;
		case UIGestureRecognizerStateChanged:
			[self layout: MAX(1.0, scale * gesture.scale)];
			break;
		default:
			break;
	}
}

- (void) addPeer: (BOMTalkPeer*) peer {
	UILabel *peerLabel = [[UILabel alloc] initWithFrame: CGRectMake (self.peerList.count*kPeerWidth, 0, kPeerHeight, kPeerWidth)];
	peerLabel.transform = CGAffineTransformTranslate(CGAffineTransformRotate(CGAffineTransformMakeTranslation(-kPeerHeight/2.0, -kPeerWidth/2.0), -M_PI_2), -kPeerHeight/2.0, kPeerWidth/2.0);
	peerLabel.backgroundColor = [UIColor colorWithWhite: 0.2 + 0.1* (self.peerList.count % 5) alpha:0.8];
	peerLabel.text = peer.name;
	peerLabel.textColor = [UIColor whiteColor];
	peerLabel.textAlignment = UITextAlignmentCenter;
	peerLabel.font = [UIFont systemFontOfSize:13];
	peerLabel.numberOfLines = 0;
	peerLabel.lineBreakMode = UILineBreakModeCharacterWrap;
	peerLabel.clipsToBounds = YES;
	[self.backContainer addSubview: peerLabel];
	[self.peerList addObject: peer];
	UIView *lineView = [[UIView alloc] initWithFrame:CGRectMake(self.peerList.count*kPeerWidth-1, 0, 1, self.view.frame.size.height)];
	lineView.backgroundColor = [UIColor colorWithWhite:0.5 alpha:1];
	lineView.autoresizingMask = UIViewAutoresizingFlexibleHeight;
	[self.backContainer addSubview: lineView];
	self.backContainer.frame = CGRectMake(self.backContainer.frame.origin.x, 0, MAX(self.view.frame.size.width, self.peerList.count*kPeerWidth), self.view.frame.size.height);
}

- (void) addEvent: (BOMTalkDebugEvent*) event {
	if (!event.sourcePeer) {
		NSLog(@"Missing sourcePeer: %@", event);
		return;
	}
	if (![self.peerList containsObject: event.sourcePeer])
		[self addPeer:event.sourcePeer];
	if (event.destPeer && ![self.peerList containsObject: event.destPeer])
		[self addPeer:event.destPeer];

	// minimal difference to last event is 1 s, less precise but better visualization
	BOMTalkDebugEvent *lastEvent = [self.eventList lastObject];
	float diff = [event.timestamp timeIntervalSinceDate: lastEvent.timestamp];
	if (diff < 1.0)
		event.timestamp = [NSDate dateWithTimeInterval:1 sinceDate:lastEvent.timestamp];

	UILabel *eventLabel = [[UILabel alloc] initWithFrame:CGRectZero];
	if (event.destPeer) {
		int diff = [self.peerList indexOfObject: event.destPeer] - [self.peerList indexOfObject: event.sourcePeer];
		if (diff < 0) {
			eventLabel.frame = CGRectMake (kPeerWidth * [self.peerList indexOfObject: event.destPeer], 0, -diff * kPeerWidth + kPeerWidth, kPeerWidth);
			eventLabel.textAlignment = UITextAlignmentRight;
		}
		else {
			eventLabel.frame = CGRectMake (kPeerWidth * [self.peerList indexOfObject: event.sourcePeer], 0, diff * kPeerWidth + kPeerWidth, kPeerWidth);
			eventLabel.textAlignment = UITextAlignmentLeft;
		}
	}
	else {
		eventLabel.frame = CGRectMake (kPeerWidth * [self.peerList indexOfObject: event.sourcePeer], 0, kPeerWidth, kPeerWidth);
		eventLabel.textAlignment = UITextAlignmentCenter;
	}
	eventLabel.text = event.message;
	eventLabel.textColor = [UIColor colorWithHue:0.05*(self.eventList.count % 20) saturation:1 brightness:1 alpha:0.8];
	eventLabel.backgroundColor = [UIColor colorWithWhite: 0.2 + 0.1*([self.peerList indexOfObject: event.sourcePeer] % 5) alpha:0.8];
	eventLabel.tag = kTagEvent + self.eventList.count;
	eventLabel.font = [UIFont systemFontOfSize:10];
	eventLabel.numberOfLines = 0;
	eventLabel.lineBreakMode = UILineBreakModeCharacterWrap;
	eventLabel.clipsToBounds = YES;
	eventLabel.userInteractionEnabled = NO;
	[self.scrollContainer addSubview: eventLabel];
	[self.eventList addObject: event];

	// defer updates
	if (self.updateTimer)
		[self.updateTimer invalidate];
	self.updateTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(update) userInfo:nil repeats:NO];
}

- (void) update {
	[self layout: self.scale];
	[self.scrollContainer scrollRectToVisible:CGRectMake(self.scrollContainer.contentOffset.x, self.scrollContainer.contentSize.height-1, 1, 1) animated:NO];
	self.updateTimer = nil;
}

- (void) layout: (CGFloat) scale {
	self.scale = scale;
	CGFloat height = 0;
	if (self.eventList.count) {
		BOMTalkDebugEvent *startEvent = self.eventList[0];
		for (int index=0; index < self.eventList.count; index++) {
			UILabel *label = (UILabel*) [self.scrollContainer viewWithTag:kTagEvent + index];
			if (label) {
				BOMTalkDebugEvent *event = self.eventList[index];
				CGFloat y = [event.timestamp timeIntervalSinceDate: startEvent.timestamp] * scale;
				label.frame = CGRectMake (label.frame.origin.x, y, label.frame.size.width, label.frame.size.height);
			}
		}
		BOMTalkDebugEvent *endEvent = [self.eventList lastObject];
		height += ceil ([endEvent.timestamp timeIntervalSinceDate: startEvent.timestamp] * scale + kPeerWidth);
	}
	self.scrollContainer.contentSize = CGSizeMake(self.peerList.count * kPeerWidth, height);
}

- (void) scrollViewDidScroll:(UIScrollView*) scrollView {
	self.backContainer.frame = CGRectMake(-scrollView.contentOffset.x, 0, self.backContainer.frame.size.width, self.backContainer.frame.size.height);
}

@end
