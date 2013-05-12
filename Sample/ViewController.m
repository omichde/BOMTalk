//
//  ViewController.m
//  BOMTalk
//
//  Created by Oliver Michalak on 22.04.13.
//  Copyright (c) 2013 Oliver Michalak. All rights reserved.
//

#import "ViewController.h"
#import "PasteboardViewController.h"
#import "RemoteCameraViewController.h"
#import "RollTheDiceViewController.h"
#import "PongViewController.h"

@interface ViewController ()
@property (strong, nonatomic) NSArray *list;
@end

@implementation ViewController

#pragma mark view callbacks

- (void) viewDidLoad {
	[super viewDidLoad];
	_list = @[@"Pasteboard (Blocks)", @"Roll the Dice (Delegates)", @"Pong (Notifications)", @"Remote Camera (Blocks)"];
}

- (void) viewDidUnload {
	[[NSNotificationCenter defaultCenter] removeObserver: self];
	_list = nil;
	[super viewDidUnload];
}

#pragma mark delegate callbacks

- (NSInteger) tableView:(UITableView*) tableView numberOfRowsInSection:(NSInteger) section {
	return _list.count;
}

- (UITableViewCell*) tableView:(UITableView*) tableView cellForRowAtIndexPath:(NSIndexPath*) indexPath {
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"SampleCell"];
	if (!cell)
		cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"SampleCell"];
	cell.textLabel.text = _list[indexPath.row];
	return cell;
}

- (void) tableView:(UITableView*) tableView didSelectRowAtIndexPath:(NSIndexPath*) indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	switch (indexPath.row) {
		case 0:
			[self.navigationController pushViewController:[[PasteboardViewController alloc] initWithNibName:@"PasteboardViewController" bundle:nil] animated:YES];
			break;
		case 1:
			[self.navigationController pushViewController:[[RollTheDiceViewController alloc] initWithNibName:@"RollTheDiceViewController" bundle:nil] animated:YES];
			break;
		case 2:
			[self.navigationController pushViewController:[[PongViewController alloc] initWithNibName:@"PongViewController" bundle:nil] animated:YES];
			break;
		case 3:
			[self.navigationController pushViewController:[[RemoteCameraViewController alloc] initWithNibName:@"RemoteCameraViewController" bundle:nil] animated:YES];
			break;
	}
}

@end
