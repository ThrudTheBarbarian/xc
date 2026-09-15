//
//  XTHttps.m — see XTHttps.h.
//

#import "XTHttps.h"
#import "tlsshim.h"
#import <netdb.h>
#import <sys/socket.h>
#import <unistd.h>

@implementation XTHttpsResponse
@end

@implementation XTHttps

+ (nullable NSString*)systemCABundle
    {
    NSFileManager* fm = [NSFileManager defaultManager];
    for (NSString* p in @[ @"/etc/ssl/cert.pem",                  // macOS, BSD
                           @"/etc/ssl/certs/ca-certificates.crt", // Debian/Ubuntu
                           // RHEL/Fedora
                           @"/etc/pki/tls/certs/ca-bundle.crt" ])
        {
        if ([fm fileExistsAtPath:p])
            return p;
        }
    return nil;
    }

// Decode HTTP/1.1 chunked transfer-encoding.
static NSData* dechunk(NSData* body)
    {
    NSMutableData* out = [NSMutableData data];
    const uint8_t* p = body.bytes;
    NSUInteger n = body.length, i = 0;
    while (i < n)
        {
        // chunk-size line (hex) up to CRLF
        NSUInteger j = i;
        while (j + 1 < n && !(p[j] == '\r' && p[j + 1] == '\n'))
            j++;
        if (j + 1 >= n)
            break;
        NSString* sizeLine = [[NSString alloc] initWithBytes:p + i length:j - i encoding:NSASCIIStringEncoding];
        // strip any chunk extension after ';'
        NSRange semi = [sizeLine rangeOfString:@";"];
        if (semi.location != NSNotFound)
            sizeLine = [sizeLine substringToIndex:semi.location];
        unsigned long long sz = strtoull(sizeLine.UTF8String, NULL, 16);
        i = j + 2; // past CRLF
        if (sz == 0)
            break; // last chunk
        if (i + sz > n)
            sz = n - i;
        [out appendBytes:p + i length:(NSUInteger)sz];
        i += sz;
        if (i + 1 < n && p[i] == '\r' && p[i + 1] == '\n')
            i += 2; // trailing CRLF
        }
    return out;
    }

+ (XTHttpsResponse*)request:(NSString*)method
                       host:(NSString*)host
                       path:(NSString*)path
                    headers:(nullable NSDictionary<NSString*, NSString*>*)headers
                       body:(nullable NSData*)body
    {
    XTHttpsResponse* r = [XTHttpsResponse new];
    r.status = -1;

    struct addrinfo hints;
    memset(&hints, 0, sizeof hints);
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo* ai = NULL;
    if (getaddrinfo(host.UTF8String, "443", &hints, &ai) != 0 || !ai)
        {
        r.error = [NSString stringWithFormat:@"DNS lookup failed for %@", host];
        return r;
        }
    int fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
    if (fd < 0)
        {
        freeaddrinfo(ai);
        r.error = @"socket() failed";
        return r;
        }
    if (connect(fd, ai->ai_addr, ai->ai_addrlen) != 0)
        {
        freeaddrinfo(ai);
        close(fd);
        r.error = [NSString stringWithFormat:@"connect failed to %@", host];
        return r;
        }
    freeaddrinfo(ai);

    NSString* ca = [self systemCABundle];
    void* client = xt_tls_client_new(ca ? ca.fileSystemRepresentation : NULL);
    if (!client)
        {
        close(fd);
        r.error = @"TLS client init failed";
        return r;
        }
    void* conn = xt_tls_connect(client, fd, host.UTF8String);
    if (!conn)
        {
        close(fd);
        r.error = @"TLS handshake / certificate verification failed";
        return r;
        }

    // Build the request.
    NSMutableString* req = [NSMutableString stringWithFormat:
                                                @"%@ %@ HTTP/1.1\r\nHost: %@\r\nConnection: close\r\n", method, path, host];
    for (NSString* k in headers)
        [req appendFormat:@"%@: %@\r\n", k, headers[k]];
    if (body)
        [req appendFormat:@"Content-Length: %lu\r\n", (unsigned long)body.length];
    [req appendString:@"\r\n"];
    NSMutableData* reqData = [[req dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    if (body)
        [reqData appendData:body];
    xt_tls_write(conn, reqData.bytes, (int)reqData.length);

    // Read the whole response (Connection: close).
    NSMutableData* raw = [NSMutableData data];
    uint8_t buf[16384];
    int got;
    while ((got = xt_tls_read(conn, buf, sizeof buf)) > 0)
        [raw appendBytes:buf length:got];
    xt_tls_close(conn);
    close(fd);

    // Split headers / body at the blank line.
    const uint8_t* b = raw.bytes;
    NSUInteger n = raw.length;
    NSUInteger hdrEnd = NSNotFound;
    for (NSUInteger i = 0; i + 3 < n; i++)
        if (b[i] == '\r' && b[i + 1] == '\n' && b[i + 2] == '\r' && b[i + 3] == '\n')
            {
            hdrEnd = i;
            break;
            }
    if (hdrEnd == NSNotFound)
        {
        r.error = @"malformed HTTP response";
        return r;
        }

    NSString* head = [[NSString alloc] initWithBytes:b length:hdrEnd encoding:NSUTF8StringEncoding];
    NSArray<NSString*>* lines = [head componentsSeparatedByString:@"\r\n"];
    if (lines.count)
        {
        NSArray<NSString*>* sl = [lines[0] componentsSeparatedByString:@" "];
        if (sl.count >= 2)
            r.status = [sl[1] integerValue];
        }
    NSMutableDictionary<NSString*, NSString*>* hdrs = [NSMutableDictionary dictionary];
    for (NSUInteger i = 1; i < lines.count; i++)
        {
        NSRange c = [lines[i] rangeOfString:@":"];
        if (c.location != NSNotFound)
            hdrs[[lines[i] substringToIndex:c.location].lowercaseString] =
                [[lines[i] substringFromIndex:c.location + 1]
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }
    r.headers = hdrs;

    NSData* bodyData = [raw subdataWithRange:NSMakeRange(hdrEnd + 4, n - hdrEnd - 4)];
    if ([hdrs[@"transfer-encoding"] containsString:@"chunked"])
        bodyData = dechunk(bodyData);
    r.body = bodyData;
    return r;
    }

@end
