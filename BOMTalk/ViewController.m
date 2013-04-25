//
//  ViewController.m
//  BOMTalk
//
//  Created by Oliver Michalak on 22.04.13.
//  Copyright (c) 2013 Oliver Michalak. All rights reserved.
//

#import "ViewController.h"
#import "BlocksViewController.h"
#import "DelegatesViewController.h"

@interface ViewController ()
@property (strong, nonatomic) NSArray *list;
@end

@implementation ViewController

#pragma mark view callbacks

- (void) viewDidLoad {
	[super viewDidLoad];
	_list = @[@"Pasteboard (Blocks)", @"Roll the Dice (Delegates)"];
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
		case 1:
			[self.navigationController pushViewController:[[DelegatesViewController alloc] initWithNibName:@"DelegatesViewController" bundle:nil] animated:YES];
			break;
		default: [self.navigationController pushViewController:[[BlocksViewController alloc] initWithNibName:@"BlocksViewController" bundle:nil] animated:YES];
	}
}

@end
