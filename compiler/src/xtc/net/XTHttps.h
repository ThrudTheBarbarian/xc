//
//  XTHttps.h — a minimal HTTPS/1.1 client for xcc-sign's Route 1.
//
//  Outbound requests to a REST API (App Store Connect) over TLS, via the
//  vendored tlsshim (Mbed TLS). Host-neutral: DNS + TCP + TLS + HTTP with
//  chunked-response decoding. Certificate verification is on by default
//  (the system CA bundle). No NSURLSession, so it works on Linux/Windows too.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface XTHttpsResponse : NSObject
@property(nonatomic) NSInteger status; // HTTP status code, or -1 on transport failure
@property(nonatomic, strong, nullable) NSData* body;
@property(nonatomic, copy, nullable) NSString* error;                             // set on transport/TLS failure
@property(nonatomic, copy, nullable) NSDictionary<NSString*, NSString*>* headers; // lowercased keys
@end

@interface XTHttps : NSObject

// One request. `method` is "GET"/"POST"/etc. `host` is the bare hostname (TLS
// SNI + Host header); `path` includes the query. `headers` are extra request
// headers; `body` is the request entity (nil for none). Returns a response
// (never nil); check .error for transport failures, .status for HTTP.
+ (XTHttpsResponse*)request:(NSString*)method
                       host:(NSString*)host
                       path:(NSString*)path
                    headers:(nullable NSDictionary<NSString*, NSString*>*)headers
                       body:(nullable NSData*)body;

// The system CA bundle path for this host, or nil if none is found.
+ (nullable NSString*)systemCABundle;

@end

NS_ASSUME_NONNULL_END
