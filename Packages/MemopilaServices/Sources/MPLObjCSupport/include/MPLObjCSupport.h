#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`. Returns NO and sets `error` when the block raised an Objective-C exception,
/// so pasteboard reads that throw `NSPasteboardCommunicationException` become read failures.
BOOL MPLCatchException(NS_NOESCAPE void (^block)(void), NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
