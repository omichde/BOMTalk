//
//  AppDelegate.m
//  BOMTalk
//
//  Created by Oliver Michalak on 22.04.13.
//  Copyright (c) 2013 Oliver Michalak. All rights reserved.
//

#import "AppDelegate.h"
#import "ViewController.h"
#import "PasteboardViewController.h"

@implementation AppDelegate

- (BOOL) application:(UIApplication*) application didFinishLaunchingWithOptions:(NSDictionary*) launchOptions {
	self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
	self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController: [[ViewController alloc] initWithNibName:@"ViewController" bundle:nil]];
	[self.window makeKeyAndVisible];
	return YES;
}

@end
