// XTIROpcode.h — xtc new-IR opcode catalogue (IR-SPEC §6.1-§6.13)
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint16_t, XTIROpcode) {
    // ── 6.1 Constants and moves ──────────────────────────────────────
    XTIROpConst, // %r:T <- ImmI/ImmF/ConstAgg
    XTIROpCopy,  // %r:T <- %x:T

    // ── 6.2 Integer arithmetic ───────────────────────────────────────
    XTIROpAdd,
    XTIROpSub,
    XTIROpMul,
    XTIROpSDiv,
    XTIROpUDiv,
    XTIROpSRem,
    XTIROpURem,
    XTIROpNeg,

    // ── 6.2a Floating-point arithmetic ───────────────────────────────
    XTIROpFAdd,
    XTIROpFSub,
    XTIROpFMul,
    XTIROpFDiv,
    XTIROpFNeg,
    XTIROpFSqrt,

    // ── 6.3 Integer bitwise and shifts ───────────────────────────────
    XTIROpAnd,
    XTIROpOr,
    XTIROpXor,
    XTIROpNot,
    XTIROpShl,
    XTIROpLShr,
    XTIROpAShr,
    XTIROpRol,
    XTIROpRor,

    // ── 6.4 Widening, narrowing, casts ───────────────────────────────
    XTIROpSExt,
    XTIROpZExt,
    XTIROpTrunc,
    XTIROpBitcast,
    XTIROpIntToPtr,
    XTIROpPtrToInt,
    XTIROpFpToSI,
    XTIROpFpToUI,
    XTIROpSIToFp,
    XTIROpUIToFp,
    XTIROpFpExt,
    XTIROpFpTrunc,
    XTIROpClassDowncast,
    XTIROpClassDowncastFailable,

    // ── 6.5 Comparisons and selects ──────────────────────────────────
    XTIROpICmp,
    XTIROpFCmp,
    XTIROpSelect,

    // ── 6.6 Memory operations ────────────────────────────────────────
    XTIROpLoad,
    XTIROpStore,
    XTIROpLoadVolatile,
    XTIROpStoreVolatile,
    XTIROpMemCopy,
    XTIROpMemSet,
    XTIROpAddrOf,

    // ── 6.7 Aggregate operations ─────────────────────────────────────
    XTIROpAggBuild,
    XTIROpAggExtract,
    XTIROpAggInsert,
    XTIROpAggLoad,
    XTIROpAggStore,
    XTIROpFieldAddr,
    XTIROpElementAddr,

    // ── 6.8 Control flow (terminators) ───────────────────────────────
    XTIROpBranch,
    XTIROpCondBranch,
    XTIROpSwitch,
    XTIROpReturn,
    XTIROpIndirectBranch,
    XTIROpUnreachable,

    // ── 6.9 Calls ────────────────────────────────────────────────────
    XTIROpCall,
    XTIROpCallIndirect,
    XTIROpCallCloaked,
    XTIROpCallBanked,
    XTIROpCallBankedIndirect,
    XTIROpVTblDispatch,
    /************************************************************************\
    |* ProtoDispatch (recv, ImmI protoId, ImmI methodIndex, args…, mem)
    |*
    |* Dispatch through a PROTOCOL, without a global slot number.
    |*
    |* Slots are numbered per compilation unit, so two independently built
    |* libraries — neither knowing the other exists — hand the same slot to
    |* different protocol methods, and a class conforming to both cannot satisfy
    |* either. That is not fixable by renumbering: a library's vtables are already
    |* emitted and its own dispatch sites already bake its numbers in.
    |*
    |* So protocols leave the flat slot space entirely. `methodIndex` is the
    |* method's position in the protocol's OWN declaration, which depends on
    |* nothing but that declaration — every module derives it identically, with no
    |* coordination. `protoId` is a 32-bit FNV-1a hash of the protocol's name: a
    |* VALUE, not an address, so it survives a .so boundary (the loader binds a
    |* defined symbol locally — see bound-methods-across-modules.md — which is why
    |* an address-based id could not work).
    |*
    |* The receiver's vtable holds its itable at entry 0: pairs of
    |* (protoId, &Class$Proto$itab) terminated by a zero id. Dispatch scans it.
    \************************************************************************/
    XTIROpProtoDispatch,
    /************************************************************************\
    |* ProtoLoad (recv, ImmI protoId, ImmI methodIndex, mem) -> fnptr
    |*
    |* ProtoDispatch's address computation without the call — `&delegate.method`
    |* on a protocol-typed receiver. A NULL result means the class did not
    |* implement an `optional` method, which is exactly what makes `respondsTo`
    |* a plain null test on the `^`.
    \************************************************************************/
    XTIROpProtoLoad,
    // VTblLoad (recv, slot) -> fnptr — read a method out of the receiver's
    // vtable WITHOUT calling it. This is VTblDispatch's address computation
    // (vtable ptr at recv[0], method at vtbl[slot * stride]) minus the call,
    // and it is how `&obj.method` gets its code word.
    //
    // Two properties it must have, both load-bearing:
    //   - a null `recv` yields 0 rather than faulting, so `&nullDelegate.m`
    //     is falsy instead of a crash;
    //   - an empty slot yields 0, which is what makes an unimplemented
    //     `optional` protocol method come back falsy — every backend already
    //     emits an unfilled vtable slot as a null word.
    // See private:docs/Design/bound-methods.md.
    XTIROpVTblLoad,

    // ── 6.9b Variadic access (abstract) ──────────────────────────────
    // Emitted by the front end so the va_list mechanism is NOT baked into
    // the lowered IR; a per-target lowering (the default pack-buffer pass
    // for 6502/m68k, or native AAPCS in the arm9/arm64 backends) expands
    // them. Both are memory-effecting (carry a mem input, produce a mem
    // result) so they're never reordered, CSE'd, or dead-stripped.
    XTIROpVaStart, // %mem      <- VaStart cursorSlot, memIn   (reset cursor → 0)
    XTIROpVaArg,   // %val:T,%m <- VaArg   cursorSlot, memIn   (read T, advance cursor)

    // ── 6.10 Phi ─────────────────────────────────────────────────────
    XTIROpPhi,

    // ── 6.11 ARC operations ──────────────────────────────────────────
    XTIROpRetain,
    XTIROpRelease,
    XTIROpAutorelease,
    XTIROpWeakRegister,
    XTIROpWeakUnregister,
    XTIROpWeakLoad,

    // ── 6.12 Banking and bank state ──────────────────────────────────
    XTIROpBankSave,
    XTIROpBankRestore,
    XTIROpBankSelectFor,

    // ── 6.13 Inline assembly ─────────────────────────────────────────
    XTIROpAsm,

    // ── 6.14 Debug ───────────────────────────────────────────────────
    XTIROpDbgValue,

    // ── 6.15 SIMD (internal: created by the arm64 vectorizer, never
    //          round-tripped through the IR text — produced and consumed
    //          within xtcg's pipeline+backend) ───────────────────────────
    XTIROpVLoad,  // %v:Vec <- ptr, mem        (load 128 bits)
    XTIROpVStore, // %mem <- ptr, %v:Vec, mem  (store 128 bits)
    XTIROpVSplat, // %v:Vec <- scalar          (broadcast lane value)
    XTIROpVAdd,
    XTIROpVSub,
    XTIROpVMul,
    XTIROpVAnd,
    XTIROpVOr,
    XTIROpVXor,
    XTIROpVMax,       // %v:Vec <- a, b   (lane-wise max; u/s from lane type)
    XTIROpVMin,       // %v:Vec <- a, b   (lane-wise min; u/s from lane type)
    XTIROpVICmp,      // %v:Vec <- a, b   (lane-wise compare → 0/-1 mask; predicate)
    XTIROpVAddLP,     // %v:Vec(2W) <- a:Vec(W)  (unsigned add-long-pairwise/uaddlp)
    XTIROpVMulHi,     // %v:Vec(W) <- a:Vec(W), b:Vec(W)  (HIGH half of the lane product)
    XTIROpVLShr,      // %v:Vec(W) <- a:Vec(W), #imm  (logical shift right by a constant)
    XTIROpVReduceAdd, // scalar <- %v:Vec  (horizontal add of all lanes)
    XTIROpVReduceMax, // scalar <- %v:Vec  (horizontal max; u/s from result type)
    XTIROpVReduceMin, // scalar <- %v:Vec  (horizontal min; u/s from result type)
};

/// Returns YES for terminator opcodes (Branch, CondBranch, Switch,
/// Return, IndirectBranch, Unreachable).
BOOL XTIROpcodeIsTerminator(XTIROpcode op);

/// Returns YES for opcodes that take/return a memory token.
BOOL XTIROpcodeTouchesMemory(XTIROpcode op);

NS_ASSUME_NONNULL_END
