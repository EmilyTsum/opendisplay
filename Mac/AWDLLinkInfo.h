#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Best-effort, read-only metadata for the live AWDL interface. The
/// implementation dynamically loads CoreWiFi at runtime and returns nil when
/// the private diagnostics API is absent, blocked, or there is no awdl0.
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable ODCopyAWDLLinkInfo(void);

NS_ASSUME_NONNULL_END
