#import "AppleToolsObjC.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

NSAttributedString *_Nullable AppleToolsSafeUnarchiveAttributedString(NSData *data) {
    if (data.length == 0) {
        return nil;
    }
    @try {
        id obj = [NSUnarchiver unarchiveObjectWithData:data];
        if ([obj isKindOfClass:[NSAttributedString class]]) {
            return (NSAttributedString *)obj;
        }
        return nil;
    } @catch (NSException *exception) {
        return nil;
    }
}

#pragma clang diagnostic pop
