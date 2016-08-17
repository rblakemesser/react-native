/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "RCTNetworkTask.h"

#import "RCTLog.h"
#import "RCTUtils.h"

@implementation RCTNetworkTask
{
  NSMutableData *_data;
  id<RCTURLRequestHandler> _handler;
  dispatch_queue_t _callbackQueue;

  RCTNetworkTask *_selfReference;
}

- (instancetype)initWithRequest:(NSURLRequest *)request
                        handler:(id<RCTURLRequestHandler>)handler
                  callbackQueue:(dispatch_queue_t)callbackQueue
{
  RCTAssertParam(request);
  RCTAssertParam(handler);
  RCTAssertParam(callbackQueue);

  static NSUInteger requestID = 0;

  if ((self = [super init])) {
    _requestID = @(requestID++);
    _request = request;
    _handler = handler;
    _callbackQueue = callbackQueue;
    _status = RCTNetworkTaskPending;
  }
  return self;
}

RCT_NOT_IMPLEMENTED(- (instancetype)init)

- (void)invalidate
{
  _selfReference = nil;
  _completionBlock = nil;
  _downloadProgressBlock = nil;
  _incrementalDataBlock = nil;
  _responseBlock = nil;
  _uploadProgressBlock = nil;
}

- (void)start
{
  if (_requestToken == nil) {
    id token = [_handler sendRequest:_request withDelegate:self];
    if ([self validateRequestToken:token]) {
      _selfReference = self;
      _status = RCTNetworkTaskInProgress;
    }
  }
}

- (void)cancel
{
  _status = RCTNetworkTaskFinished;
  __strong id strongToken = _requestToken;
  if (strongToken && [_handler respondsToSelector:@selector(cancelRequest:)]) {
    [_handler cancelRequest:strongToken];
  }
  [self invalidate];
}

- (BOOL)validateRequestToken:(id)requestToken
{
  BOOL valid = YES;
  if (_requestToken == nil) {
    if (requestToken == nil) {
      if (RCT_DEBUG) {
        RCTLogError(@"Missing request token for request: %@", _request);
      }
      valid = NO;
    }
    _requestToken = requestToken;
  } else if (![requestToken isEqual:_requestToken]) {
    if (RCT_DEBUG) {
      RCTLogError(@"Unrecognized request token: %@ expected: %@", requestToken, _requestToken);
    }
    valid = NO;
  }

  if (!valid) {
    _status = RCTNetworkTaskFinished;
    if (_completionBlock) {
      RCTURLRequestCompletionBlock completionBlock = _completionBlock;
      dispatch_async(_callbackQueue, ^{
        completionBlock(self->_response, nil, RCTErrorWithMessage(@"Invalid request token."));
      });
    }
    [self invalidate];
  }
  return valid;
}

- (void)URLRequest:(id)requestToken didSendDataWithProgress:(int64_t)bytesSent
{
  if (![self validateRequestToken:requestToken]) {
    return;
  }

  if (_uploadProgressBlock) {
    RCTURLRequestProgressBlock uploadProgressBlock = _uploadProgressBlock;
    int64_t length = _request.HTTPBody.length;
    dispatch_async(_callbackQueue, ^{
      uploadProgressBlock(bytesSent, length);
    });
  }
}

- (void)URLRequest:(id)requestToken didReceiveResponse:(NSURLResponse *)response
{
  if (![self validateRequestToken:requestToken]) {
    return;
  }

  _response = response;
  if (_responseBlock) {
    RCTURLRequestResponseBlock responseBlock = _responseBlock;
    dispatch_async(_callbackQueue, ^{
      responseBlock(response);
    });
  }
}

- (void)URLRequest:(id)requestToken didReceiveData:(NSData *)data
{
  if (![self validateRequestToken:requestToken]) {
    return;
  }

  if (!_data) {
    _data = [NSMutableData new];
  }
  [_data appendData:data];

  int64_t length = _data.length;
  int64_t total = _response.expectedContentLength;

  if (_incrementalDataBlock) {
    RCTURLRequestIncrementalDataBlock incrementalDataBlock = _incrementalDataBlock;
    dispatch_async(_callbackQueue, ^{
      incrementalDataBlock(data, length, total);
    });
  }
  if (_downloadProgressBlock && total > 0) {
    RCTURLRequestProgressBlock downloadProgressBlock = _downloadProgressBlock;
    dispatch_async(_callbackQueue, ^{
      downloadProgressBlock(length, total);
    });
  }
}

- (void)URLRequest:(id)requestToken didCompleteWithError:(NSError *)error
{
  if (![self validateRequestToken:requestToken]) {
    return;
  }

  _status = RCTNetworkTaskFinished;
  if (_completionBlock) {
    RCTURLRequestCompletionBlock completionBlock = _completionBlock;
    dispatch_async(_callbackQueue, ^{
      completionBlock(self->_response, self->_data, error);
    });
  }
  [self invalidate];
}

@end