//
//  TVNCHttpResponse.h
//  Shared lightweight HTTP response structure for TVNCHttpServer.
//  Extracted from TVNCHttpServer.mm during the P3 maintainability refactor
//  (2026-07-20) so the handler category files (.mm) can see the full type
//  without pulling in the whole server implementation.
//

#import <Foundation/Foundation.h>

@interface TVNCHttpResponse : NSObject

@property (nonatomic, assign) NSInteger statusCode;
@property (nonatomic, copy) NSString *contentType;
@property (nonatomic, copy) NSData *body;

@end
