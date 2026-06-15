#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Decode an iMessage `attributedBody` blob (Apple's legacy `streamtyped`
/// NSArchiver format) into an NSAttributedString, returning nil on any failure.
///
/// chat.db stores the attributed text as a typedstream, which only the
/// deprecated `NSUnarchiver` can read. `NSUnarchiver` raises an Objective-C
/// exception on malformed input rather than returning nil — and a raised
/// NSException cannot be caught from Swift. This shim wraps the call in
/// @try/@catch so a corrupt blob in the probe's inbound poll degrades to nil
/// (caller falls back to plain-text extraction) instead of crashing the probe.
NSAttributedString *_Nullable AppleToolsSafeUnarchiveAttributedString(NSData *data);

NS_ASSUME_NONNULL_END
