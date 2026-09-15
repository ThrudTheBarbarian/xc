// XTIRValue.h — SSA value (IR-SPEC §4)
#import <Foundation/Foundation.h>
#import "XTIRSupport.h"

NS_ASSUME_NONNULL_BEGIN

@class XTIRType;
@class XTIRBlock;

/// Defines where a value originated: a block+instruction-index pair,
/// or nil to indicate a function/block parameter.
@interface XTIRDefSite : NSObject
@property(nonatomic, readonly, weak, nullable) XTIRBlock* block;
@property(nonatomic, readonly) NSUInteger insnIndex;
@property(nonatomic, readonly, getter=isParameter) BOOL parameter;

- (instancetype)initWithBlock:(nullable XTIRBlock*)block
                    insnIndex:(NSUInteger)insnIndex;

/// Convenience for function/block parameters.
+ (instancetype)parameterDef;
@end

@interface XTIRValue : NSObject

/// Dense, function-local, unique.  Immutable after construction.
@property(nonatomic, readonly) XTIRValueId valueId;

/// Immutable after construction.
@property(nonatomic, readonly) XTIRType* type;

/// Where this value is defined.
@property(nonatomic, readonly) XTIRDefSite* defSite;

- (instancetype)initWithValueId:(XTIRValueId)valueId
                           type:(XTIRType*)type
                        defSite:(XTIRDefSite*)defSite NS_DESIGNATED_INITIALIZER;

@end

NS_ASSUME_NONNULL_END
