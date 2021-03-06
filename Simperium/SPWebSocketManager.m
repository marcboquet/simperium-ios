//
//  SPWebSocketManager
//  Simperium
//
//  Created by Michael Johnston on 11-03-07.
//  Copyright 2011 Simperium. All rights reserved.
//
#import "SPWebSocketManager.h"
#import "Simperium.h"
#import "SPUser.h"
#import "SPBucket.h"
#import "JSONKit.h"
#import "NSString+Simperium.h"
#import "DDLog.h"
#import "DDLogDebug.h"
#import "SRWebSocket.h"
#import "SPWebSocketChannel.h"

#define INDEX_PAGE_SIZE 500
#define INDEX_BATCH_SIZE 10
#define INDEX_QUEUE_SIZE 5

NSString * const COM_AUTH = @"auth";
NSString * const COM_INDEX = @"i";
NSString * const COM_CHANGE = @"c";
NSString * const COM_ENTITY = @"e";

//static NSUInteger numTransfers = 0;
static BOOL useNetworkActivityIndicator = 0;
static int ddLogLevel = LOG_LEVEL_INFO;
NSString * const WebSocketAuthenticationDidFailNotification = @"AuthenticationDidFailNotification";

@interface SPWebSocketManager() <SRWebSocketDelegate>
@property (nonatomic, assign) Simperium *simperium;
@property (nonatomic, retain) NSMutableDictionary *channels;
@property (nonatomic, copy) NSString *clientID;
@property (nonatomic, retain) NSDictionary *bucketNameOverrides;
@end

@implementation SPWebSocketManager
@synthesize simperium;
@synthesize channels;
@synthesize clientID;
@synthesize webSocket;

+ (int)ddLogLevel {
    return ddLogLevel;
}

+ (void)ddSetLogLevel:(int)logLevel {
    ddLogLevel = logLevel;
}

+ (void)updateNetworkActivityIndictator
{
#if TARGET_OS_IPHONE    
//    BOOL visible = useNetworkActivityIndicator && numTransfers > 0;
//	[[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:visible];
    //DDLogInfo(@"Simperium numTransfers = %d", numTransfers);
#endif
}

+ (void)setNetworkActivityIndicatorEnabled:(BOOL)enabled
{
    useNetworkActivityIndicator = enabled;
}

-(id)initWithSimperium:(Simperium *)s appURL:(NSString *)url clientID:(NSString *)cid
{
	if ((self = [super init])) {
        self.simperium = s;
        self.clientID = cid;
        self.channels = [NSMutableDictionary dictionaryWithCapacity:20];
	}
	
	return self;
}

-(void)dealloc
{
    self.clientID = nil;
    self.channels = nil;
    self.webSocket.delegate = nil;
    self.webSocket = nil;
	[super dealloc];
}

-(SPWebSocketChannel *)channelForName:(NSString *)str {
    return [self.channels objectForKey:str];
}

-(SPWebSocketChannel *)channelForNumber:(NSNumber *)num {
    for (SPWebSocketChannel *channel in [self.channels allValues]) {
        if ([num intValue] == channel.number)
            return channel;
    }
    return nil;
}

-(SPWebSocketChannel *)loadChannelForBucket:(SPBucket *)bucket {
    int channelNumber = [self.channels count];
    SPWebSocketChannel *channel = [[SPWebSocketChannel alloc] initWithSimperium:simperium clientID:clientID];
    channel.number = channelNumber;
    channel.name = bucket.name;
    [self.channels setObject:channel forKey:bucket.name];
    
    return channel;
}

-(void)loadChannelsForBuckets:(NSDictionary *)bucketList overrides:(NSDictionary *)overrides {
    self.bucketNameOverrides = overrides;
    
    for (SPBucket *bucket in [bucketList allValues])
        [self loadChannelForBucket:bucket];
}


-(void)sendObjectDeletion:(id<SPDiffable>)object
{
    SPWebSocketChannel *channel = [self channelForName:object.bucket.name];
    [channel sendObjectDeletion:object];
}

-(void)sendObjectChanges:(id<SPDiffable>)object
{
    SPWebSocketChannel *channel = [self channelForName:object.bucket.name];
    [channel sendObjectChanges:object];
}


//- (int)nextRetryDelay {
//    int currentDelay = retryDelay;
//    retryDelay *= 2;
//    if (retryDelay > 24)
//        retryDelay = 24;
//    
//    return currentDelay;
//}
//
//- (void)resetRetryDelay {
//    retryDelay = 2;
//}

-(void)authenticationDidFail {
    DDLogWarn(@"Simperium authentication failed for token %@", simperium.user.authToken);
    [[NSNotificationCenter defaultCenter] postNotificationName:WebSocketAuthenticationDidFailNotification object:self];
}

-(void)authenticateChannel:(SPWebSocketChannel *)channel {
    //    NSString *message = @"1:command:parameters";
    NSString *remoteBucketName = [self.bucketNameOverrides objectForKey:channel.name];
    if (!remoteBucketName || remoteBucketName.length == 0)
        remoteBucketName = channel.name;
    
    NSDictionary *jsonData = [NSDictionary dictionaryWithObjectsAndKeys:
                              [NSNumber numberWithInt:1], @"api",
                              simperium.clientID, @"clientid",
                              simperium.appID, @"app_id",
                              simperium.user.authToken, @"token",
                              remoteBucketName, @"name",
                              //@"i", @"cmd",
                              nil];
    
    DDLogVerbose(@"Simperium initializing websocket channel %d:%@", channel.number, remoteBucketName);
    NSString *message = [NSString stringWithFormat:@"%d:init:%@", channel.number, [jsonData JSONString]];
    [self.webSocket send:message];
}

-(void)openWebSocket
{
    NSString *url = @"wss://api.simperium.com/sock/websocket";
    SRWebSocket *newWebSocket = [[SRWebSocket alloc] initWithURLRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:url]]];
    self.webSocket = newWebSocket;
    [newWebSocket release];
    self.webSocket.delegate = self;
    
    NSLog(@"Opening Connection...");
    [self.webSocket open];
}

-(void)start:(SPBucket *)bucket name:(NSString *)name
{
    //[self resetRetryDelay];
    
    SPWebSocketChannel *channel = [self channelForName:bucket.name];
    if (!channel)
        channel = [self loadChannelForBucket:bucket];
    
    if (self.webSocket == nil) {
        [self openWebSocket];
        // Channels will get setup after successfully connection
    } else if (open) {
        [self authenticateChannel:channel];
    }
}

-(void)stop:(SPBucket *)bucket
{
    SPWebSocketChannel *channel = [self channelForName:bucket.name];
    channel.started = NO;
    channel.webSocket = nil;
    
    // Can't remove the channel because it's needed for offline changes; this is weird and should be fixed
    //[channels removeObjectForKey:bucket.name];
    
    if (!open)
        return;
    
    DDLogVerbose(@"Simperium stopping network manager (%@)", bucket.name);
    
    // Mark it closed so it doesn't reopen
    open = NO;
    [self.webSocket close];
    
    // TODO: Consider ensuring threads are done their work and sending a notification
}

- (void)webSocketDidOpen:(SRWebSocket *)webSocket;
{
    //NSLog(@"Websocket Connected");
    open = YES;
    
    // Start all channels
    for (SPWebSocketChannel *channel in [self.channels allValues]) {
        channel.webSocket = self.webSocket;
        [self authenticateChannel:channel];
    }
}

- (void)webSocket:(SRWebSocket *)webSocket didFailWithError:(NSError *)error;
{
    NSLog(@"Simperium websocket failed with error %@", error);
    
    self.webSocket = nil;
    open = NO;
}

// todo: send h:# for heartbeat

- (void)webSocket:(SRWebSocket *)webSocket didReceiveMessage:(id)message;
{
    //DDLogVerbose(@"Received \"%@\"", message);
    
    // Parse CHANNELNUM:COMMAND:DATA
    NSRange range = [message rangeOfString:@":"];
    NSString *channelStr = [message substringToIndex:range.location];
    NSNumber *channelNumber = [NSNumber numberWithInt:[channelStr intValue]];
    SPWebSocketChannel *channel = [self channelForNumber:channelNumber];
    SPBucket *bucket = [self.simperium bucketForName:channel.name];
    
    NSString *commandStr = [message substringFromIndex:range.location+range.length];    
    range = [commandStr rangeOfString:@":"];
    if (range.location == NSNotFound) {
        DDLogWarn(@"Simperium received unrecognized websocket message: %@", message);
    }
    NSString *command = [commandStr substringToIndex:range.location];
    NSString *data = [commandStr substringFromIndex:range.location+range.length];
    
    if ([command isEqualToString:COM_AUTH]) {
        // todo: handle "expired"
        channel.started = YES;
        BOOL bFirstStart = bucket.lastChangeSignature == nil;
        if (bFirstStart) {
            [channel getLatestVersionsForBucket:bucket];
        } else
            [channel startProcessingChangesForBucket:bucket];
    } else if ([command isEqualToString:COM_INDEX]) {
        // todo: handle ? if bad command
        [channel handleIndexResponse:data bucket:bucket];
    } else if ([command isEqualToString:COM_CHANGE]) {
        // todo: handle ? if cv doesn't exist
        NSArray *changes = [data objectFromJSONStringWithParseOptions:JKParseOptionLooseUnicode];
        if ([changes count] > 0) {
            DDLogVerbose(@"Simperium handling changes %@", changes);
            [channel handleRemoteChanges: changes bucket:bucket];
        }
    } else if ([command isEqualToString:COM_ENTITY]) {
        // todo: handle ? if entity doesn't exist or it has been deleted
        [channel handleVersionResponse:data bucket:bucket];
    }
}

- (void)webSocket:(SRWebSocket *)webSocket didCloseWithCode:(NSInteger)code reason:(NSString *)reason wasClean:(BOOL)wasClean;
{
    if (open) {
        // Closed unexpectedly, retry
        [self performSelector:@selector(openWebSocket) withObject:nil afterDelay:2];
        DDLogVerbose(@"Simperium connection closed (will retry): %d, %@", code, reason);
    } else {
        // Closed on purpose
        DDLogInfo(@"Simperium connection closed");
    }

    self.webSocket = nil;
    open = NO;
}


-(void)resetBucketAndWait:(SPBucket *)bucket
{
    // Careful, this will block if the queue has work on it; however, enqueued tasks should empty quickly if the
    // started flag is set to false
    dispatch_sync(bucket.processorQueue, ^{
        [bucket.changeProcessor reset];
    });
    [bucket setLastChangeSignature:nil];

//    numTransfers = 0;
//    [[self class] updateNetworkActivityIndictator];
}

-(void)getVersions:(int)numVersions forObject:(id<SPDiffable>)object
{
    SPWebSocketChannel *channel = [self channelForName:object.bucket.name];
    [channel getVersions:numVersions forObject:object];
}

-(void)shareObject:(id<SPDiffable>)object withEmail:(NSString *)email
{
    SPWebSocketChannel *channel = [self channelForName:object.bucket.name];
    [channel shareObject:object withEmail:email];
}

-(void)getLatestVersionsForBucket:(SPBucket *)b {
    // Not yet implemented
}

@end
