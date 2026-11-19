// XTIROpcode.m
#import "XTIROpcode.h"

BOOL XTIROpcodeIsTerminator(XTIROpcode op)
    {
    switch (op)
        {
    case XTIROpBranch:
    case XTIROpCondBranch:
    case XTIROpSwitch:
    case XTIROpReturn:
    case XTIROpIndirectBranch:
    case XTIROpUnreachable:
        return YES;
    default:
        return NO;
        }
    }

BOOL XTIROpcodeTouchesMemory(XTIROpcode op)
    {
    switch (op)
        {
    case XTIROpLoad:
    case XTIROpStore:
    case XTIROpLoadVolatile:
    case XTIROpStoreVolatile:
    case XTIROpMemCopy:
    case XTIROpMemSet:
    case XTIROpAggLoad:
    case XTIROpAggStore:
    case XTIROpCall:
    case XTIROpCallIndirect:
    case XTIROpCallCloaked:
    case XTIROpCallBanked:
    case XTIROpCallBankedIndirect:
    case XTIROpVTblDispatch:
    case XTIROpProtoDispatch:
    // VTblLoad reads the receiver's vtable pointer out of recv[0]. The
    // vtable's CONTENTS are constant, but that pointer is written by
    // `new` — so this must carry a memory token, or a pass could hoist
    // the load above the allocation that installs it.
    case XTIROpVTblLoad:
    case XTIROpProtoLoad:
    case XTIROpRetain:
    case XTIROpRelease:
    case XTIROpAutorelease:
    case XTIROpWeakRegister:
    case XTIROpWeakUnregister:
    case XTIROpWeakLoad:
    case XTIROpAsm:
    case XTIROpVLoad:
    case XTIROpVStore:
        return YES;
    default:
        return NO;
        }
    }

BOOL XTIROpcodeMayWriteMemory(XTIROpcode op)
    {
    switch (op)
        {
    case XTIROpStore:
    case XTIROpStoreVolatile:
    case XTIROpMemCopy:
    case XTIROpMemSet:
    case XTIROpAggStore:
    case XTIROpVStore:
    case XTIROpRetain:
    case XTIROpRelease:
    case XTIROpAutorelease:
    case XTIROpWeakRegister:
    case XTIROpWeakUnregister:
    case XTIROpAsm:
    case XTIROpVaStart:
    case XTIROpVaArg:
        return YES;
    default:
        return XTIROpcodeCallsOut(op);
        }
    }

BOOL XTIROpcodeCallsOut(XTIROpcode op)
    {
    switch (op)
        {
    case XTIROpCall:
    case XTIROpCallIndirect:
    case XTIROpCallCloaked:
    case XTIROpCallBanked:
    case XTIROpCallBankedIndirect:
    case XTIROpVTblDispatch:
    case XTIROpProtoDispatch:
        return YES;
    default:
        return NO;
        }
    }

BOOL XTIROpcodeClobbersCallerSaved(XTIROpcode op)
    {
    switch (op)
        {
    case XTIROpMemCopy:
    case XTIROpMemSet:
    case XTIROpRelease:
    case XTIROpAutorelease:
    case XTIROpWeakRegister:
    case XTIROpWeakUnregister:
    case XTIROpWeakLoad:
        return YES;
    default:
        return XTIROpcodeCallsOut(op);
        }
    }
