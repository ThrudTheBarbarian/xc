// GProject.h — native project format: GResource <-> JSON-able NSDictionary.
// Used for .gemproj save/open and for undo snapshots.

#import "GModel.h"

NS_ASSUME_NONNULL_BEGIN

NSDictionary* GResourceToDictionary(GResource* r);
GResource* _Nullable GResourceFromDictionary(NSDictionary* d);

NSData* _Nullable GResourceToJSON(GResource* r);
GResource* _Nullable GResourceFromJSON(NSData* json);

NS_ASSUME_NONNULL_END
