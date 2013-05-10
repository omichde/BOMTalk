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
@end

@implementation BOMTalkDebugViewController

- (void) viewDidLoad {
	[super viewDidLoad];
	[_scrollContainer addGestureRecognizer:[[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinch:)]];
	_scale = 10.0;
	_peerList = [[NSMutableArray alloc] init];
	_eventList = [[NSMutableArray alloc] init];
}

- (void) viewDidUnload {
	_scrollContainer = nil;
	[self setBackContainer:nil];
    [self setBackContainer:nil];
	[super viewDidUnload];
}

- (void) pinch: (UIPinchGestureRecognizer*) gesture {
	static CGFloat scale;
	switch (gesture.state) {
		case UIGestureRecognizerStateBegan:
			scale = _scale;
			break;
		case UIGestureRecognizerStateChanged:
			[self layout: MAX(1.0, scale * gesture.scale)];
			break;
		default:
			break;
	}
}

- (void) addPeer: (BOMTalkPeer*) peer {
	UILabel *peerLabel = [[UILabel alloc] initWithFrame: CGRectMake (_peerList.count*kPeerWidth, 0, kPeerHeight, kPeerWidth)];
	peerLabel.transform = CGAffineTransformTranslate(CGAffineTransformRotate(CGAffineTransformMakeTranslation(-kPeerHeight/2.0, -kPeerWidth/2.0), -M_PI_2), -kPeerHeight/2.0, kPeerWidth/2.0);
	peerLabel.backgroundColor = [UIColor colorWithWhite: 0.2 + 0.1* (_peerList.count % 5) alpha:0.8];
	peerLabel.text = peer.name;
	peerLabel.textColor = [UIColor whiteColor];
	peerLabel.textAlignment = UITextAlignmentCenter;
	peerLabel.font = [UIFont systemFontOfSize:13];
	peerLabel.numberOfLines = 0;
	peerLabel.lineBreakMode = UILineBreakModeCharacterWrap;
	peerLabel.clipsToBounds = YES;
	[_backContainer addSubview: peerLabel];
	[_peerList addObject: peer];
	UIView *lineView = [[UIView alloc] initWithFrame:CGRectMake(_peerList.count*kPeerWidth-1, 0, 1, self.view.frame.size.height)];
	lineView.backgroundColor = [UIColor colorWithWhite:0.5 alpha:1];
	lineView.autoresizingMask = UIViewAutoresizingFlexibleHeight;
	[_backContainer addSubview: lineView];
	_backContainer.frame = CGRectMake(_backContainer.frame.origin.x, 0, MAX(self.view.frame.size.width, _peerList.count*kPeerWidth), self.view.frame.size.height);
}

- (void) addEvent: (BOMTalkDebugEvent*) event {
	if (event.sourcePeer && ![_peerList containsObject: event.sourcePeer])
		[self addPeer:event.sourcePeer];
	if (event.destPeer && ![_peerList containsObject: event.destPeer])
		[self addPeer:event.destPeer];

	// minimal difference to last event is 1 s, less precise but better visualization
	BOMTalkDebugEvent *lastEvent = [_eventList lastObject];
	float diff = [event.timestamp timeIntervalSinceDate: lastEvent.timestamp];
	if (diff < 1.0)
		event.timestamp = [NSDate dateWithTimeInterval:1 sinceDate:lastEvent.timestamp];

	UILabel *eventLabel = [[UILabel alloc] initWithFrame:CGRectZero];
	if (event.destPeer) {
		int diff = [_peerList indexOfObject: event.destPeer] - [_peerList indexOfObject: event.sourcePeer];
		if (diff < 0) {
			eventLabel.frame = CGRectMake (kPeerWidth * [_peerList indexOfObject: event.destPeer], 0, -diff * kPeerWidth + kPeerWidth, kPeerWidth);
			eventLabel.textAlignment = UITextAlignmentRight;
		}
		else {
			eventLabel.frame = CGRectMake (kPeerWidth * [_peerList indexOfObject: event.sourcePeer], 0, diff * kPeerWidth + kPeerWidth, kPeerWidth);
			eventLabel.textAlignment = UITextAlignmentLeft;
		}
	}
	else {
		eventLabel.frame = CGRectMake (kPeerWidth * [_peerList indexOfObject: event.sourcePeer], 0, kPeerWidth, kPeerWidth);
		eventLabel.textAlignment = UITextAlignmentCenter;
	}
	eventLabel.text = event.message;
	eventLabel.textColor = [UIColor colorWithHue:0.1*(_eventList.count % 10) saturation:1 brightness:1 alpha:0.8];
	eventLabel.backgroundColor = [UIColor colorWithWhite: 0.2 + 0.1*([_peerList indexOfObject: event.sourcePeer] % 5) alpha:0.8];
	eventLabel.tag = kTagEvent + _eventList.count;
	eventLabel.font = [UIFont systemFontOfSize:10];
	eventLabel.numberOfLines = 0;
	eventLabel.lineBreakMode = UILineBreakModeCharacterWrap;
	eventLabel.clipsToBounds = YES;
	eventLabel.userInteractionEnabled = NO;
	[_scrollContainer addSubview: eventLabel];
	[_eventList addObject: event];
	
	[self layout: _scale];
	[_scrollContainer scrollRectToVisible:CGRectMake(_scrollContainer.contentOffset.x, _scrollContainer.contentSize.height-1, 1, 1) animated:NO];
}

- (void) layout: (CGFloat) scale {
	_scale = scale;
	CGFloat height = 0;
	if (_eventList.count) {
		BOMTalkDebugEvent *startEvent = _eventList[0];
		for (int index=0; index < _eventList.count; index++) {
			UILabel *label = (UILabel*) [_scrollContainer viewWithTag:kTagEvent + index];
			BOMTalkDebugEvent *event = _eventList[index];
			CGFloat y = [event.timestamp timeIntervalSinceDate: startEvent.timestamp] * scale;
			label.frame = CGRectMake (label.frame.origin.x, y, label.frame.size.width, label.frame.size.height);
		}
		BOMTalkDebugEvent *endEvent = [_eventList lastObject];
		height += ceil ([endEvent.timestamp timeIntervalSinceDate: startEvent.timestamp] * scale + kPeerWidth);
	}
	_scrollContainer.contentSize = CGSizeMake(_peerList.count * kPeerWidth, height);
}

- (void) scrollViewDidScroll:(UIScrollView*) scrollView {
	_backContainer.frame = CGRectMake(-scrollView.contentOffset.x, 0, _backContainer.frame.size.width, _backContainer.frame.size.height);
}

@end
