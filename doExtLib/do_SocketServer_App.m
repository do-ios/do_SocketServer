//
//  do_SocketServer_App.m
//  DoExt_SM
//
//  Created by @userName on @time.
//  Copyright (c) 2015年 DoExt. All rights reserved.
//

#import "do_SocketServer_App.h"
static do_SocketServer_App* instance;
@implementation do_SocketServer_App
@synthesize OpenURLScheme;
+(id) Instance
{
    if(instance==nil)
        instance = [[do_SocketServer_App alloc]init];
    return instance;
}
@end
