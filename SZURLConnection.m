//
//  SZURLConnection.h
//
//  Created by Jon Nall on 10/9/09.
//  Copyright 2009-2010 STUNTAZ!!! All rights reserved.
// 
//  Redistribution and use in source and binary forms, with or without
//  modification, are permitted provided that the following conditions are met:
//  
//  Redistributions of source code must retain the above copyright notice, this
//  list of conditions and the following disclaimer.
//
//  Redistributions in binary form must reproduce the above copyright notice, 
//  this list of conditions and the following disclaimer in the documentation 
//  and/or other materials provided with the distribution.
//  
//  Neither the name of Jon Nall  nor the names of its contributors may be used 
//  to endorse or promote products derived from this software without specific 
//  prior written permission. 
//
//  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
//  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
//  IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE 
//  ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE 
//  LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR 
//  CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF 
//  SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS 
//  INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN 
//  CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) 
//  ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE 
//  POSSIBILITY OF SUCH DAMAGE.
//
//  SZHTTPURLResponse uses code found In the connection framework
//  http://opensource.utr-software.com/connection/
//  Which is licensed under the BSD license
//  Copyright 2009 Karelia Software. All rights reserved.
//

#import "SZURLConnection.h"

NSString* const kszURLProxyHost = @"kszURLProxyHost";
NSString* const kszURLProxyPort = @"kszURLProxyPort";

static NSUInteger kszURLBufferSize = 32 * 1024;

static NSOperationQueue* urlQueue;

@interface SZURLConnection(Private)
-(void)retainQueue;
-(void)releaseQueue;
-(void)startConnection;
-(void)handleStreamEvent:(CFStreamEventType)eventType
                onStream:(CFReadStreamRef)cfStream;
@end

#pragma mark -
#pragma mark SZHTTPURLResponse Implementation
@implementation SZHTTPURLResponse
-(id)initWithURL:(NSURL*)URL
     HTTPMessage:(CFHTTPMessageRef)message
{
    _headerFields = NSMakeCollectable(CFHTTPMessageCopyAllHeaderFields(message));
    
    NSString* MIMEType = [_headerFields objectForKey:@"Content-Type"];
    NSInteger contentLength = [[_headerFields objectForKey:@"Content-Length"] intValue];
    NSString* encoding = [_headerFields objectForKey:@"Content-Encoding"];
    
    if(self = [super initWithURL:URL
                        MIMEType:MIMEType
           expectedContentLength:contentLength
                textEncodingName:encoding])
    {
        _statusCode = CFHTTPMessageGetResponseStatusCode(message);
    }
    
    return self;
}

-(void)dealloc
{
    [_headerFields release];
    [super dealloc];
}

-(NSDictionary*)allHeaderFields
{
    return _headerFields; 
}

-(NSInteger)statusCode
{
    return _statusCode;
}

-(NSString*)description
{
    return [NSString stringWithFormat:@"Status %d: <%@:0x%x>", [self statusCode], [self class], self];
}
@end

#pragma mark -
#pragma mark Synchronous Request Implementation
@interface SZURLSyncRequestDelegate : NSObject<SZURLConnectionDelegate>
{
    NSTimer* timeoutTimer;
    NSMutableData* reqData;
    NSURLResponse* reqResponse;
    NSError* reqError;
    NSCondition* condition;
    BOOL complete;
    BOOL timedOut;
}
@property (retain) NSURLResponse* reqResponse;
@property (retain) NSError* reqError;

-(NSData*)waitForCompletion:(NSURLResponse**)reponse
                withTimeout:(const NSTimeInterval)timeout
                      error:(NSError**)error;
@end

@implementation SZURLSyncRequestDelegate
@synthesize reqResponse;
@synthesize reqError;
-(id)init
{
    self = [super init];
    if(self != nil)
    {
        reqData = [[NSMutableData alloc] init];
        condition = [[NSCondition alloc] init];
        complete = NO;
        timedOut = NO;
    }
    
    return self;
}

-(void)dealloc
{
    [timeoutTimer release];
    [reqData release];
    [condition release];
    [reqError release];
    [reqResponse release];
    [super dealloc];
}

-(void)timeout:(NSTimer*)timer
{
    NSLog(@"%@ TIMEOUT!", [self class]);
    [condition lock];
    timedOut = YES;
    [condition signal];
    [condition unlock];
}

-(NSData*)waitForCompletion:(NSURLResponse**)response
                withTimeout:(const NSTimeInterval)timeout
                      error:(NSError**)error
{
    if(timeout != 0)
    {
        timeoutTimer = [[NSTimer scheduledTimerWithTimeInterval:timeout
                                                         target:self
                                                       selector:@selector(timeout:)
                                                       userInfo:nil
                                                        repeats:NO] retain];
    }
                         
    [condition lock];
    while(complete == NO && timedOut == NO)
    {
        [condition wait];
    }
    [condition unlock];
    
    [timeoutTimer invalidate];
    
    NSData* result = reqData;
    
    if(response != nil)
    {
        *response = self.reqResponse;
    }
    
    if(timedOut)
    {
        if(error != nil)
        {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:NSURLErrorTimedOut
                                     userInfo:nil];
            return nil;
        }
    }
    
    // On error, set result to nil and set error if it's non-nil
    //
    if(self.reqError != nil)
    {
        result = nil;
        if(error != nil)
        {
            *error = self.reqError;
        }
    }
    
    return result;
}

-(void)szConnection:(SZURLConnection*)connection
 didReceiveResponse:(NSURLResponse*)response
{
    self.reqResponse = response;
}

-(void)szConnection:(SZURLConnection*)connection
     didReceiveData:(NSData*)data
{
    [reqData appendData:data];
}

-(void)szConnectionDidFinishLoading:(SZURLConnection*)connection
{
    [condition lock];
    complete = YES;
    [condition signal];
    [condition unlock];
}

-(void)szConnection:(SZURLConnection*)connection
   didFailWithError:(NSError*)error
{
    [condition lock];
    self.reqError = error;
    complete = YES;
    [condition signal];
    [condition unlock];
}

@end


#pragma mark -
#pragma mark Stream Callback
static void SZStreamCallback(CFReadStreamRef stream,
                             CFStreamEventType eventType,
                             void* context)
{
    SZURLConnection* connection = (SZURLConnection*)context;
    
    [connection handleStreamEvent:eventType onStream:stream];

}

#pragma mark -
#pragma mark SZURLConnection Public Methods
@implementation SZURLConnection
@synthesize delegate = _delegate;
@synthesize minimumDataSize = _minimumDataSize;

+(void)initialize
{
    
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    NSString* host = @"";
    NSNumber* port = [NSNumber numberWithUnsignedInteger:0];
    
    NSDictionary* proxyDefaults = [NSDictionary dictionaryWithObjectsAndKeys:
                                    host, kszURLProxyHost,
                                    port, kszURLProxyPort,
                                    nil];
    [defaults registerDefaults:proxyDefaults];
}

+(NSData*)sendSynchronousRequest:(NSURLRequest*)request
               returningResponse:(NSURLResponse**)response
                           error:(NSError**)error
{
    return [SZURLConnection sendSynchronousRequest:request
                                 returningResponse:response
                                       withTimeout:0
                                             error:error];
}

+(NSData*)sendSynchronousRequest:(NSURLRequest*)request
               returningResponse:(NSURLResponse**)response
                     withTimeout:(const NSTimeInterval)timeout
                           error:(NSError**)error
{
    SZURLSyncRequestDelegate* syncDelegate = [[SZURLSyncRequestDelegate alloc] init];
    
    SZURLConnection* connection = [[SZURLConnection alloc] initWithRequest:request
                                                                  delegate:syncDelegate];
    (void)connection; // It's started implcitly in the -initWithRequest
    
    NSData* result = [syncDelegate waitForCompletion:response
                                         withTimeout:timeout
                                               error:error];
    [connection release];

    [syncDelegate release];
    return result;
}


-(id)initWithRequest:(NSURLRequest*)request
            delegate:(id)delegate
    startImmediately:(BOOL)startImmediately
{
    self = [super init];
    if(self != nil)
    {
        [self retainQueue];
        
        [self setDelegate:delegate];
        _request = [request copy];
        _currentData = [[NSMutableData alloc] initWithCapacity:kszURLBufferSize];
        _minimumDataSize = 10;
        
        if(startImmediately)
        {
            [self start];
        }
    }
    return self;    
}

-(id)initWithRequest:(NSURLRequest*)request
            delegate:(id)delegate
{
    self = [self initWithRequest:request
                        delegate:delegate
                startImmediately:YES];
    return self;
}

-(void)dealloc
{
    if(_cfStream != NULL)
    {
        CFReadStreamSetClient(_cfStream, kCFStreamEventNone, NULL, NULL);
        CFReadStreamUnscheduleFromRunLoop(_cfStream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
        CFReadStreamClose(_cfStream);
        CFRelease(_cfStream);
        _cfStream = NULL;    
    }
    
    [self releaseQueue];
    
    [_currentData release];
    [_delegate release];
    [_request release];
    [super dealloc];
}

-(void)start
{
    NSInvocationOperation* op = [[[NSInvocationOperation alloc]
                                  initWithTarget:self
                                  selector:@selector(startConnection)
                                  object:nil]
                                 autorelease];
    [urlQueue addOperation:op];
}

-(void)cancel
{
    if(_cfStream != NULL)
    {
        CFReadStreamSetClient(_cfStream, kCFStreamEventNone, NULL, NULL);
        CFReadStreamUnscheduleFromRunLoop(_cfStream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
        CFReadStreamClose(_cfStream);
        CFRelease(_cfStream);
        _cfStream = NULL;
    }
}

#pragma mark -
#pragma mark Delegate Methods
-(void)szConnection:(SZURLConnection*)connection
 didReceiveResponse:(NSURLResponse*)response
{
    [self.delegate szConnection:connection didReceiveResponse:response];
}

-(void)szConnection:(SZURLConnection*)connection
     didReceiveData:(NSData*)data
{
    [self.delegate szConnection:connection didReceiveData:data];
}

-(void)szConnectionDidFinishLoading:(SZURLConnection*)connection
{
    [self.delegate szConnectionDidFinishLoading:connection];
}

-(void)szConnection:(SZURLConnection*)connection
   didFailWithError:(NSError*)error
{
    [self.delegate szConnection:connection didFailWithError:error];
}

@end

#pragma mark -
#pragma mark SZURLConnection Private Methods
@implementation SZURLConnection(Private)
-(void)startConnection
{
    NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
    
    _sentResponse = NO;
    CFHTTPMessageRef cfRequest = 
    CFHTTPMessageCreateRequest(kCFAllocatorDefault, 
                               (CFStringRef)[_request HTTPMethod],
                               (CFURLRef)[_request URL],
                               kCFHTTPVersion1_1);
    CFHTTPMessageSetBody(cfRequest, (CFDataRef)[_request HTTPBody]);
    
    NSDictionary* headers = [_request allHTTPHeaderFields];
    for(NSString* header in [headers keyEnumerator])
    {
        CFHTTPMessageSetHeaderFieldValue(cfRequest,
                                         (CFStringRef)header, 
                                         (CFStringRef)[headers objectForKey:header]);
    }

    _cfStream = CFReadStreamCreateForHTTPRequest(kCFAllocatorDefault,
                                                 cfRequest);

    NSString* proxyHost = [[NSUserDefaults standardUserDefaults] stringForKey:kszURLProxyHost];
    if(proxyHost != nil && [proxyHost length] > 0)
    {
        SZLog(kszCompCore, INFO, @"Using HTTP proxy: %@:%@",
              proxyHost, [[NSUserDefaults standardUserDefaults] objectForKey:kszURLProxyPort]);
        NSDictionary* proxyDict = [NSDictionary dictionaryWithObjectsAndKeys:
                                    proxyHost, kCFStreamPropertySOCKSProxyHost,
                                    [[NSUserDefaults standardUserDefaults] objectForKey:kszURLProxyPort], kCFStreamPropertySOCKSProxyPort,
                                    nil];
        CFReadStreamSetProperty(_cfStream, kCFStreamPropertyHTTPProxy, proxyDict);
    }
    
    CFRelease(cfRequest);

    CFOptionFlags registeredEvents = kCFStreamEventHasBytesAvailable |
                                     kCFStreamEventErrorOccurred |
                                     kCFStreamEventEndEncountered;
    
    // Version 0
    // void* = self
    // release, retain, copy callbacks are NULL
    CFStreamClientContext context = {0, self, NULL, NULL, NULL};

    if(CFReadStreamSetClient(_cfStream, registeredEvents, &SZStreamCallback, &context))
    {
        CFReadStreamScheduleWithRunLoop(_cfStream, CFRunLoopGetCurrent(),
                                        kCFRunLoopCommonModes);
    }
       
    if(CFReadStreamOpen(_cfStream) == TRUE)
    {
        CFStreamError error = CFReadStreamGetError(_cfStream);
        if (error.error != 0)
        {
            // An error has occurred.
            if (error.domain == kCFStreamErrorDomainPOSIX)
            {
                // Interpret myErr.error as a UNIX errno.
                strerror(error.error);
            }
            else if (error.domain == kCFStreamErrorDomainMacOSStatus)
            {
                OSStatus macError = (OSStatus)error.error;
                (void)macError;
            }
            // Check other domains.
            NSLog(@"Stream error occurred: Domain: %d, Error: %d", error.domain, error.error);
        }
        else
        {
            // start the run loop
            CFRunLoopRun();
        }
    }
    else
    {
        NSLog(@"Could not open stream");
    }

    
    [pool drain];
}

-(void)handleStreamEvent:(CFStreamEventType)eventType
                onStream:(CFReadStreamRef)cfStream
{
    switch(eventType)
    {
        case kCFStreamEventErrorOccurred:
        {
            CFErrorRef cfError = CFReadStreamCopyError(cfStream);
            NSError* error = [NSError errorWithDomain:(NSString*)CFErrorGetDomain(cfError)
                                                 code:CFErrorGetCode(cfError)
                                             userInfo:nil];
            [self szConnection:self didFailWithError:error];
            
            CFReadStreamUnscheduleFromRunLoop(cfStream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
            CFReadStreamClose(cfStream);
            CFRelease(cfError);
            break;
        }
        case kCFStreamEventEndEncountered:
        {
            [self szConnectionDidFinishLoading:self];
            CFReadStreamUnscheduleFromRunLoop(cfStream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
            CFReadStreamClose(cfStream);
            break;
        }
        case kCFStreamEventHasBytesAvailable:
        {
            // Check if header is done
            if(_sentResponse == NO)
            {
                CFHTTPMessageRef cfResponse = (CFHTTPMessageRef)CFReadStreamCopyProperty(cfStream,
                                                                                         kCFStreamPropertyHTTPResponseHeader);
                
                if(cfResponse != NULL && CFHTTPMessageIsHeaderComplete(cfResponse))
                {
                    SZHTTPURLResponse* response = [[[SZHTTPURLResponse alloc] initWithURL:[_request URL]
                                                                              HTTPMessage:cfResponse]
                                                   autorelease];
                    [self szConnection:self didReceiveResponse:response];
                    _sentResponse = YES;
                }
                
                if(cfResponse != NULL)
                {
                    CFRelease(cfResponse);                    
                }
            }
            
            // Now handle data
            {
                uint8_t buffer[kszURLBufferSize];
                CFIndex bytesRead = 0;
                
                bytesRead = CFReadStreamRead(_cfStream, buffer, sizeof(buffer));
                if(bytesRead == -1)
                {
                    NSLog(@"CFReadStreamRead return -1 bytesRead");
                }
                else
                {
                    [_currentData appendBytes:buffer
                                       length:bytesRead];
                    if([_currentData length] >= self.minimumDataSize)
                    {
                        [self szConnection:self didReceiveData:[[_currentData copy] autorelease]];
                        [_currentData setLength:0];
                    }                    
                }
            }
            
            break;
        }
    }
}

-(void)retainQueue
{
    if(urlQueue == nil)
    {
        urlQueue = [[NSOperationQueue alloc] init];
    }
    else
    {
        [urlQueue retain];
    }
}

-(void)releaseQueue
{
    const BOOL setToNil = [urlQueue retainCount] == 1;
    
    [urlQueue release];
    
    if(setToNil == YES)
    {
        urlQueue = nil;
    }
}

@end
