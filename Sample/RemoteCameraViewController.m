//
//  RemoteCameraViewController.m
//  BOMTalk
//
//  Created by Oliver Michalak on 12.05.13.
//  Copyright (c) 2013 Oliver Michalak. All rights reserved.
//

#import "RemoteCameraViewController.h"
#import <AVFoundation/AVFoundation.h>
#import "BOMTalk.h"

#define kRequestPhoto (401)
#define kSendPhoto (402)

@interface RemoteCameraViewController ()
@property (strong, nonatomic) BOMTalkPeer *peer;
@property (strong, nonatomic) UIProgressView *progressView;
@property (nonatomic, strong) AVCaptureSession *captureSession;
@property (nonatomic, strong) AVCaptureStillImageOutput *captureOutput;
@end

@implementation RemoteCameraViewController

- (void) viewDidLoad {
	[super viewDidLoad];
	self.navigationItem.titleView = _progressView = [[UIProgressView alloc] initWithFrame:CGRectMake(0, 0, 200, 44)];
	_progressView.hidden = YES;
#ifdef BOMTalkDebug
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSearch target:self action:@selector(debuggerShow)];
#endif
}

- (void) viewDidUnload {
	_imageView = nil;
	_listView = nil;
	[super viewDidUnload];
}

- (void) viewDidAppear:(BOOL) animated {
	[super viewDidAppear:animated];
	BOMTalk *talker = [BOMTalk sharedTalk];
	[talker answerToUpdate:^(BOMTalkPeer *sender) {
		[_listView reloadData];
	}];
	[talker answerToMessage:kRequestPhoto block:^(BOMTalkPeer *peer, id data) {
		_peer = peer;
		[self takePhoto];
	}];
	[talker answerToMessage:kSendPhoto block:^(BOMTalkPeer *peer, id data) {
		UIImage *image = [[UIImage alloc] initWithData: data];
		UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil);
		_imageView.image = image;
	}];
	[talker progressForReceiving:^(float progress) {
		_progressView.hidden = (progress == 1.0);
		_progressView.progress = 1 - progress;
	}];
	[talker progressForSending:^(float progress) {
		_progressView.hidden = (progress == 1.0);
		_progressView.progress = progress;
	}];
	[[BOMTalk sharedTalk] start];
}

- (void) viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];
	[[BOMTalk sharedTalk] stop];
#ifdef BOMTalkDebug
	[[BOMTalk sharedTalk] hideDebugger];
#endif
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

- (void) takePhoto {
	NSError *error = nil;
	AVCaptureDeviceInput *input;
	_captureSession = [[AVCaptureSession alloc] init];
	_captureSession.sessionPreset = AVCaptureSessionPresetHigh;
	NSArray *deviceList = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
	for (AVCaptureDevice *device in deviceList) {
		if (device.position == AVCaptureDevicePositionBack) {
			input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
			if (input)
				break;
		}
	}
	if (input) {
		[_captureSession addInput:input];
		_captureOutput = [[AVCaptureStillImageOutput alloc] init];
		_captureOutput.outputSettings = [NSDictionary dictionaryWithObjectsAndKeys:AVVideoCodecJPEG,AVVideoCodecKey,nil];
		[_captureSession addOutput:_captureOutput];
		[_captureSession addObserver: self forKeyPath:@"running" options:NSKeyValueObservingOptionNew context:NULL];
		[_captureSession startRunning];
	}
}

- (void) observeValueForKeyPath:(NSString*) keyPath ofObject:(id)object change:(NSDictionary*) change context:(void*) context {
	if ([keyPath isEqual:@"running"] && [change valueForKey: NSKeyValueChangeNewKey]) {
		dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC));	// wait for dark/cold sensor, pure heuristic
		dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
			for (AVCaptureConnection *connection in _captureOutput.connections) {
				for (AVCaptureInputPort *port in connection.inputPorts) {
					if ([[port mediaType] isEqual:AVMediaTypeVideo]) {
						[_captureOutput captureStillImageAsynchronouslyFromConnection:connection
																												completionHandler:^(CMSampleBufferRef imageSampleBuffer, NSError *error) {
																													if (imageSampleBuffer) {
																														NSData *imageData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageSampleBuffer];
																														[[BOMTalk sharedTalk] sendMessage:kSendPhoto toPeer:_peer withData:imageData];
																													}
																													[_captureSession removeObserver:self forKeyPath:@"running"];
																													[_captureSession stopRunning];
																													_captureSession = nil;
																												}];
					}
				}
			}
		});
	}
	else
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];

}

#pragma mark delegate callbacks

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
	[talker connectToPeer: peer success:^(BOMTalkPeer *peer){
		[talker sendMessage:kRequestPhoto toPeer:peer];
	}];
}

@end
