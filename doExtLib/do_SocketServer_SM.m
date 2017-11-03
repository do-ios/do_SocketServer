//
//  do_SocketServer_SM.m
//  DoExt_API
//
//  Created by @userName on @time.
//  Copyright (c) 2015年 DoExt. All rights reserved.
//

#import "do_SocketServer_SM.h"

#import "doScriptEngineHelper.h"
#import "doIScriptEngine.h"
#import "doInvokeResult.h"
#import "doJsonHelper.h"
#import "doServiceContainer.h"
#import "doLogEngine.h"
#import "GCDAsyncSocket1.h"
#import "doSocketServerReachability.h"
#import "doIOHelper.h"
#import "doIPage.h"

#define do_ServerSocketMaxPort 65535
#define do_ServerSocketMinPort 0


@interface do_SocketServer_SM()<GCDAsyncSocketDelegate1,NSStreamDelegate>
@property (nonatomic, strong) dispatch_queue_t serverSocketQueue; // 串行队列
@property (nonatomic, strong) GCDAsyncSocket1 *serverSocket;
// 保存连接的所有客户端的socket对象
@property (nonatomic, strong) NSMutableArray<GCDAsyncSocket1*> *clientSocketsArray; // 保存当前连接进来的客户端
@property (nonatomic, strong) doSocketServerReachability *hostReach;
@property (nonatomic, assign) doSocketServerNetworkStatus currentNetworkStatus;// 当前网络环境
@property (nonatomic, strong) NSString *callBackName;
@property (nonatomic, strong) id<doIScriptEngine> curScriptEngine;
//@property (nonatomic, strong) NSInputStream *inputStream;
@property (nonatomic, strong) NSMutableArray<GCDAsyncSocket1*> *sentSocketsArray; // 保存当前需要发送数据的客户端
/**大数据写入客户端相关变量,暂时不用缓冲区的方式**/
@property (nonatomic, strong) NSMutableDictionary<NSString*,NSInputStream*> *socketInputStreamDict; // 存储socketkey(ip:port)与与之对应的流
@property (nonatomic, strong) NSMutableDictionary<NSString*,dispatch_queue_t> *socketGCDQueueDict; // 存储socketkey(ip:port)与与之对应串行队列
@end

@implementation do_SocketServer_SM

- (void)OnInit {
    [super OnInit];
    [self startObserve];
}

- (void)Dispose {
    [super Dispose];
    [self.serverSocket disconnect];
    [self clearResource];
    self.currentNetworkStatus = NotReachable;
    [_hostReach stopNotifier];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:doSocketServerReachabilityChangedNotification object:nil];
}

#pragma mark - lazy
- (dispatch_queue_t)serverSocketQueue {
    if (_serverSocketQueue == nil) {
        _serverSocketQueue = dispatch_queue_create("com.do.do_SocketServer", DISPATCH_QUEUE_SERIAL);
        return _serverSocketQueue;
    }
    return _serverSocketQueue;
}

- (GCDAsyncSocket1 *)serverSocket {
    if (_serverSocket == nil) {
        _serverSocket = [[GCDAsyncSocket1 alloc] initWithDelegate:self delegateQueue:self.serverSocketQueue];
        return _serverSocket;
    }
    return _serverSocket;
}

- (NSMutableArray *)clientSocketsArray {
    if (_clientSocketsArray == nil) {
        _clientSocketsArray = [NSMutableArray array];
        return _clientSocketsArray;
    }
    return _clientSocketsArray;
}

- (NSMutableArray<GCDAsyncSocket1 *> *)sentSocketsArray {
    if (_sentSocketsArray == nil) {
        _sentSocketsArray = [NSMutableArray array];
        return _sentSocketsArray;
    }
    return _sentSocketsArray;
}

- (NSMutableDictionary<NSString *,NSInputStream *> *)socketInputStreamDict {
    if (_socketInputStreamDict == nil) {
        _socketInputStreamDict = [NSMutableDictionary dictionary];
        return _socketInputStreamDict;
    }
    return  _socketInputStreamDict;
}

- (NSMutableDictionary<NSString *,dispatch_queue_t> *)socketGCDQueueDict {
    if (_socketGCDQueueDict == nil) {
        _socketGCDQueueDict = [NSMutableDictionary dictionary];
        return _socketGCDQueueDict;
    }
    return _socketGCDQueueDict;
}

#pragma mark - private
- (void)clearResource {
    [self.clientSocketsArray removeAllObjects];
    [self.sentSocketsArray removeAllObjects];
    [self.socketInputStreamDict removeAllObjects];
    [self.socketGCDQueueDict removeAllObjects];
}

//得到二进制字符串
-(NSString *)getHexStr:(NSData *)data
{
    Byte *testByte = (Byte *)[data bytes];
    NSString *hexStr=@"";
    for(int i=0;i<[data length];i++)
    {
        NSString *newHexStr = [NSString stringWithFormat:@"%x",testByte[i]&0xff];///16进制数
        if([newHexStr length]==1)
        {
            hexStr = [NSString stringWithFormat:@"%@0%@",hexStr,newHexStr];
        }
        else
        {
            hexStr = [NSString stringWithFormat:@"%@%@",hexStr,newHexStr];
        }
    }
    return hexStr;
}

// 开始监听
-(void)startObserve
{
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(doSocketServerReachabilityChanged:)
                                                 name: doSocketServerReachabilityChangedNotification
                                               object: nil];
    _hostReach = [doSocketServerReachability reachabilityWithHostName:@"www.baidu.com"] ;
    [_hostReach startNotifier];
    self.currentNetworkStatus = _hostReach.currentReachabilityStatus;
}

// 监听到网络变化
- (void)doSocketServerReachabilityChanged:(NSNotification *)note {
    if (_serverSocket == nil){// 当前serverSocket未初始化,不予处理
        self.currentNetworkStatus = _hostReach.currentReachabilityStatus;
        return;
    }
    if (self.clientSocketsArray.count == 0){// 当前未有客户端连接进来，不予处理
        self.currentNetworkStatus = _hostReach.currentReachabilityStatus;
        return;
    }
 
    doSocketServerReachability* curReach = [note object];
    doSocketServerNetworkStatus status = [curReach currentReachabilityStatus];
    
    switch (status) {
        case NotReachable:{
            if (self.currentNetworkStatus != NotReachable) { // 此次网络切换之前有网络
                [self netWorkChangeOperationWithCurrentNetworkStatus:status networkStr:@"当前无网络"];
            }
            break;
        }
        case kReachableVia2G: {
            if (self.currentNetworkStatus != NotReachable) { // 此次网络切换之前有网络
                if (self.currentNetworkStatus != kReachableVia2G) { // 网络发生了切换
                    [self netWorkChangeOperationWithCurrentNetworkStatus:status networkStr:@"当前切换到2G网络"];
                }
            }
            break;
        }
        case kReachableVia3G:{
            if (self.currentNetworkStatus != NotReachable) { // 此次网络切换之前有网络
                if (self.currentNetworkStatus != kReachableVia3G) { // 网络发生了切换
                    self.currentNetworkStatus = kReachableVia3G;
                    [self netWorkChangeOperationWithCurrentNetworkStatus:status networkStr:@"当前切换到3G网络"];

                }
            }
            break;
        }
        case ReachableViaWiFi:{
            if (self.currentNetworkStatus != NotReachable) { // 此次网络切换之前有网络
                if (self.currentNetworkStatus != ReachableViaWiFi) { // 网络发生了切换
                    self.currentNetworkStatus = ReachableViaWiFi;
                    [self netWorkChangeOperationWithCurrentNetworkStatus:status networkStr:@"当前切换到wifi网络"];
                }
            }
            break;
        }
        case kReachableVia4G:{
            if (self.currentNetworkStatus != NotReachable) { // 此次网络切换之前有网络
                if (self.currentNetworkStatus != kReachableVia4G) { // 网络发生了切换
                    self.currentNetworkStatus = kReachableVia4G;
                    [self netWorkChangeOperationWithCurrentNetworkStatus:status networkStr:@"当前切换到4G网络"];
                }
            }
            break;
        }
        default:{
            if (self.currentNetworkStatus != NotReachable) { // 此次网络切换之前有网络
                [self netWorkChangeOperationWithCurrentNetworkStatus:NotReachable networkStr:@"当前切换到未知网络"];
            }
            break;
        }
    }
    
}

- (void)netWorkChangeOperationWithCurrentNetworkStatus:(doSocketServerNetworkStatus)currentNetworkStatus networkStr:(NSString*)networkStr{
    self.currentNetworkStatus = currentNetworkStatus;
    // 断开连接
    for (GCDAsyncSocket1 *socket in self.clientSocketsArray) {
        [socket disconnect];
    }
    [self clearResource];
    doInvokeResult *result = [[doInvokeResult alloc] init];
    NSString *msg = [NSString stringWithFormat:@"%@，网络环境发生变化，断开连接",networkStr];
    [result SetResultNode:@{@"msg":msg}];
    [self.EventCenter FireEvent:@"error" :result];
}

- (NSData *)convertHexStrToData:(NSString *)str {
    if (!str || [str length] == 0) {
        return nil;
    }
    
    NSMutableData *hexData = [[NSMutableData alloc] initWithCapacity:8];
    NSRange range;
    if ([str length] % 2 == 0) {
        range = NSMakeRange(0, 2);
    } else {
        range = NSMakeRange(0, 1);
    }
    for (NSInteger i = range.location; i < [str length]; i += 2) {
        unsigned int anInt;
        NSString *hexCharStr = [str substringWithRange:range];
        NSScanner *scanner = [[NSScanner alloc] initWithString:hexCharStr];
        
        [scanner scanHexInt:&anInt];
        NSData *entity = [[NSData alloc] initWithBytes:&anInt length:1];
        [hexData appendData:entity];
        
        range.location += range.length;
        range.length = 2;
    }
    return hexData;
}

/// 根据socket获得对应的socketKey，格式为 ip:port
- (NSString*)getSocketKeyWithSocket:(GCDAsyncSocket1*)socket {
    NSString *socketKey = [NSString stringWithFormat:@"%@:%d",socket.localHost,socket.localPort];
    return socketKey;
}

/// 根据inputStream获取对应的socketKey
- (NSString*)getSocketKeyWithInputStream:(NSInputStream*)inputStream {
    for (NSString *key in self.socketInputStreamDict.allKeys) {
        if ([self.socketInputStreamDict objectForKey:key] == inputStream) {
            return key;
        }
    }
    return nil;
}

/// 根据socketKey获得GCDAsyncSocket实例
- (GCDAsyncSocket1*)getSocketWithSocketKey:(NSString*)socketKey {
    for (GCDAsyncSocket1 *socket in self.clientSocketsArray) {
        if ([[self getSocketKeyWithSocket:socket] isEqualToString:socketKey]) {
            return socket;
        }
    }
    return nil;
}

/// 发送大数据准备工作
- (void)setUpPrepareOperationForSendFile:(NSString *)path
{
    for (GCDAsyncSocket1 *socket in self.sentSocketsArray) {
        
        NSString *socketKey = [self getSocketKeyWithSocket:socket];
        const char *queueName = [socketKey UTF8String];
        dispatch_queue_t queue = dispatch_queue_create(queueName, DISPATCH_QUEUE_SERIAL);
        
        NSInputStream *inputStream = [[NSInputStream alloc] initWithFileAtPath:path];
        inputStream.delegate = self;
        [inputStream scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
        [inputStream open];
        
        [self.socketInputStreamDict setValue:inputStream forKey:socketKey];
        [self.socketGCDQueueDict setValue:queue forKey:socketKey];
    }
}

/// 发送小数据
- (void)setSendFileData:(NSString*)path {
    for (GCDAsyncSocket1 *socket in self.sentSocketsArray) {
        NSData *fileData = [NSData dataWithContentsOfFile:path];
        [socket writeData:fileData withTimeout:-1 tag:0];
    }
}

/// 发送数据失败回调处理
- (void)failCallBackOfSendMethod {
    doInvokeResult *result = [[doInvokeResult alloc] init];
    [result SetResultBoolean:false];
    [self.curScriptEngine Callback:self.callBackName :result];
}

/// 发送数据成功回调处理
- (void)successCallBackOfSendMethod {
    doInvokeResult *result = [[doInvokeResult alloc] init];
    [result SetResultBoolean:true];
    [self.curScriptEngine Callback:self.callBackName :result];
}

/// 检查端口号是否合法
- (BOOL)checkPortLegalWithPortString:(NSString*)portString {
    if ([portString intValue] > do_ServerSocketMaxPort || [portString intValue] < do_ServerSocketMinPort) { // 端口号非法
        return false;
    }
    return true;
}

/// 检查Ip地址是否合法
- (BOOL)checkIPAddressLegalWithIPAddressString:(NSString*)ipAddressStr {
    NSString *pattern = @"\\b(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\b";
    NSRegularExpression *regular = [[NSRegularExpression alloc] initWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
    NSArray *results = [regular matchesInString:ipAddressStr options:0 range:NSMakeRange(0, ipAddressStr.length)];
    return (results.count > 0);
}
#pragma mark - 方法
#pragma mark - 同步异步方法的实现
//同步
- (void)startListen:(NSArray *)parms
{
    [self clearResource];
    NSDictionary *_dictParas = [parms objectAtIndex:0];
    //参数字典_dictParas
    self.curScriptEngine = [parms objectAtIndex:1];
    //自己的代码实现
    
    doInvokeResult *_invokeResult = [parms objectAtIndex:2];
    //_invokeResult设置返回值
    
    // 服务端端口号
    NSString *serportString = [doJsonHelper GetOneText:_dictParas :@"serverPort" :@"9999"];
    if (![self checkPortLegalWithPortString:serportString]) { // 端口号非法
        [_invokeResult SetResultBoolean:false];
        [[doServiceContainer Instance].LogEngine WriteError:nil :@"serverPort取值范围为0-65535"];
        return;
    }
    
    NSError *error;
    // 在指定端口号接收监听
    if ([self.serverSocket acceptOnPort:serportString.intValue error:&error]) {
        if (error == nil) {
            [_invokeResult SetResultBoolean:true];
        }else {
            [_invokeResult SetResultBoolean:false];
            [[doServiceContainer Instance].LogEngine WriteError:nil :@"端口号已被占用"];
        }
    }else {
        [_invokeResult SetResultBoolean:false];
        [[doServiceContainer Instance].LogEngine WriteError:nil :@"开启监听失败或监听已开启"];
    }

}

- (void)stopListen:(NSArray *)parms
{
    [self.serverSocket disconnect];
    [self clearResource];
    self.serverSocket = nil;
}
//异步
- (void)send:(NSArray *)parms
{
    if (_serverSocket == nil) {
        [[doServiceContainer Instance].LogEngine WriteError:nil :@"尚未开启监听或已结束监听"];
        return;
    }
    NSDictionary *_dictParas = [parms objectAtIndex:0];
    self.curScriptEngine = [parms objectAtIndex:1];
    self.callBackName = [parms objectAtIndex:2];
    
    
    NSString *type = [doJsonHelper GetOneText:_dictParas :@"type" :nil];
    NSString *content = [doJsonHelper GetOneText:_dictParas :@"content" :nil];
    NSString *clientIP = [doJsonHelper GetOneText:_dictParas :@"clientIP" :nil];
    
    if (type == nil) {
        [[doServiceContainer Instance].LogEngine WriteError:nil :@"type参数必填"];
        [self failCallBackOfSendMethod];
        return;
    }
    if (content == nil) {
        [[doServiceContainer Instance].LogEngine WriteError:nil :@"content参数必填"];
        [self failCallBackOfSendMethod];
        return;
    }
    
    if(self.clientSocketsArray.count == 0) { // 优先判断
        [[doServiceContainer Instance].LogEngine WriteError:nil :@"当前没有客户端连接"];
        [self failCallBackOfSendMethod];
        return;
    }
    
    if (clientIP == nil) { // 没有传递clientIp参数，给所有客户端发送消息
        // 存储需要发送信息的socket
        self.sentSocketsArray = [self.clientSocketsArray mutableCopy];
    }else {
        if (![clientIP isEqualToString:@""]) {
            if ([self checkIPAddressLegalWithIPAddressString:clientIP]) {
                BOOL findTargetSocket = false;
                for (GCDAsyncSocket1 *socket in self.clientSocketsArray) {
                    if ([socket.connectedHost isEqualToString:clientIP]) { // 找到目标socket
                        findTargetSocket = true;
                        if (![self.sentSocketsArray containsObject:socket]) { // 没有存储过需要发送数据的socket
                            [self.sentSocketsArray addObject:socket];
                        }
                    }
                }
                if (!findTargetSocket) {
                    [[doServiceContainer Instance].LogEngine WriteError:nil :[NSString stringWithFormat:@"当前server尚未连接ip:%@ 客户端",clientIP]];
                    [self failCallBackOfSendMethod];
                    return;
                }
            }else {
                [[doServiceContainer Instance].LogEngine WriteError:nil :@"clientIP对应的ip地址不合法"];
                [self failCallBackOfSendMethod];
                return;
            }
        }else { // clientIp为空字符串
            [[doServiceContainer Instance].LogEngine WriteError:nil :@"clientIP不能为空字符串"];
            [self failCallBackOfSendMethod];
            return;
        }
    }
    
    NSData *dataToWrite;
    type = type.lowercaseString;
    if ([type isEqualToString:@"utf-8"]) {
        dataToWrite = [[NSData alloc]initWithBytes:[content UTF8String] length:[content lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
    }else if ([type isEqualToString:@"gbk"]) {
        NSStringEncoding gbkEncoding = CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000);
        dataToWrite = [content dataUsingEncoding:gbkEncoding];
    }else if ([type isEqualToString:@"hex"]){
        dataToWrite = [self convertHexStrToData:content];
    }else if ([type isEqualToString:@"file"]) {
        // 文件数据传输单独处理
        NSString *filePath = [doIOHelper GetLocalFileFullPath:self.curScriptEngine.CurrentPage.CurrentApp :content];
        [self setSendFileData:filePath]; // 小文件传输
        return;
        
    }else {
        [[doServiceContainer Instance].LogEngine WriteError:nil :@"编码格式错误"];
        return;
    }
    
    // 发送file除外的数据
    for (GCDAsyncSocket1 *socket in self.sentSocketsArray) {
        [socket writeData:dataToWrite withTimeout:-1 tag:0];
    }
}

#pragma mark - NSStreamDelegate代理回调
- (void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode
{
    NSString *socketKey = [self getSocketKeyWithInputStream:(NSInputStream*)aStream];
    GCDAsyncSocket1 *socket = [self getSocketWithSocketKey:socketKey];
    switch (eventCode) {
        case NSStreamEventOpenCompleted: {
            NSLog(@"%@-流打开完成",[self getSocketKeyWithInputStream:(NSInputStream*)aStream]);
            break;
        }
        case NSStreamEventEndEncountered:
        {
            NSLog(@"%@-流缓存完成",[self getSocketKeyWithInputStream:(NSInputStream*)aStream]);
            [aStream removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
            break;
        }
        case NSStreamEventErrorOccurred:
        {
            NSLog(@"%@-流缓存发生错误",[self getSocketKeyWithInputStream:(NSInputStream*)aStream]);
            [aStream removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
            [self failCallBackOfSendMethod];
            // 将当前InputStream从字典移除
            [self.socketInputStreamDict removeObjectForKey:socketKey];
            // 将当前inputStream对应的scoket对应的dispatch_queue_t队列从字典移除
            [self.socketGCDQueueDict removeObjectForKey:socketKey];
            // 将当前inputStream对应的需要发送数据的socket从数组中移除
            [self.sentSocketsArray removeObject:socket];
            break;
        }
        case NSStreamEventHasBytesAvailable:
        {
            dispatch_queue_t queue = [self.socketGCDQueueDict objectForKey:socketKey];
            dispatch_async(queue, ^{
                NSMutableData *fileData = [NSMutableData data];//fileData
                uint8_t buf[4096];
                unsigned long len = 0;
                len = [(NSInputStream *)aStream read:buf maxLength:4096];  // 读取数据
                if (len) {
                    [fileData appendBytes:(const void *)buf length:len];
                    [socket writeData:fileData withTimeout:-1 tag:0];
                }
            });
            break;
        }
            
    }
}

#pragma mark -  GCDAsyncSocketDelegate代理回调
/**
 *  有客户端的socket连接到服务器
 *  sock 服务端的socket
 *  newSocket 客户端连接过来的socket
 */
- (void)socket:(GCDAsyncSocket1 *)sock didAcceptNewSocket:(GCDAsyncSocket1 *)newSocket
{

    doInvokeResult *result = [[doInvokeResult alloc] init];
    NSLog(@"%d",newSocket.connectedPort);
    [result SetResultNode:@{@"ip":[NSString stringWithFormat:@"%@:%d",newSocket.connectedHost,newSocket.connectedPort]}];
    [self.EventCenter FireEvent:@"listen" :result];
    // 保存客户端的socket
    if(![self.clientSocketsArray containsObject:newSocket]) {
        [self.clientSocketsArray addObject:newSocket];
    }
    // 监听客户端有没有数据上传
    // 传递过来的客户端的socket来监听有没有数据上床
    // -1 代表不超时, tag标示作用,暂时用不到,写0
    [newSocket readDataWithTimeout:-1 tag:0];
    
}

/**
 *  读取客户端请求的数据
 *  sock 客户端的socket
 */
- (void)socket:(GCDAsyncSocket1 *)sock didReadData:(NSData *)data withTag:(long)tag
{
//    NSLog(@"接收到客户端数据");
    doInvokeResult *result = [[doInvokeResult alloc] init];
    NSDictionary *resultDict = [NSDictionary dictionaryWithObjectsAndKeys:[NSString stringWithFormat:@"%@:%d",sock.connectedHost,sock.connectedPort],@"client",[self getHexStr:data],@"receiveData",nil];
    [result SetResultNode:resultDict];
    [self.EventCenter FireEvent:@"receive" :result];
    // 每次读取完数据后, 都要调用一次监听数据的方法, 否则只会接受一次数据
    [sock readDataWithTimeout:-1 tag:0];
}


/**
 * 成功写入数据给客户端
 *  sock 客户端的socket
 */
- (void)socket:(GCDAsyncSocket1 *)sock didWriteDataWithTag:(long)tag
{
    [self successCallBackOfSendMethod];
    // 大数据文件传输的相关处理还没写
}

/**
 断开链接
 */
- (void)socketDidDisconnect:(GCDAsyncSocket1 *)sock withError:(NSError *)err
{
//    NSLog(@"断开连接");
    if ([self.clientSocketsArray containsObject:sock]) {
        [self.clientSocketsArray removeObject:sock];
    }
    // 大数据文件传输的相关处理还没写
    
}

@end
