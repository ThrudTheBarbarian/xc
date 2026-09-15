// XTIRBuildTests.m — sanity-check that IR data structures compose
// Builds the hello-world IR from EXAMPLES §1 in memory and asserts
// block/instruction count.
#import <Foundation/Foundation.h>
#import "XTIR.h"

int runIRBuildTests(void)
    {
    fprintf(stderr, "  XTIRBuildTests\n");

    // ── 1. Module ──────────────────────────────────────────────────────
    XTIRModule* mod = [[XTIRModule alloc] initWithName:@"test"];

    // ── 2. Types ───────────────────────────────────────────────────────
    XTIRType* u8Type = [XTIRType u8Type];
    XTIRType* memType = [XTIRType memoryType];

    // ── 3. Entry block ─────────────────────────────────────────────────
    XTIRBlock* entry = [[XTIRBlock alloc] init];
    entry.name = @"bb_entry";

    // ── 4. Function: fn add(%a:U8, %b:U8, %m0:Mem) -> (U8, Mem) ──────
    NSArray* paramTypes = @[ u8Type, u8Type, memType ];
    XTIRFunction* fn = [[XTIRFunction alloc] initWithName:@"add"
                                               returnType:u8Type
                                               paramTypes:paramTypes
                                               entryBlock:entry];
    [mod addFunction:fn];

    // ── 5. Parameter values ────────────────────────────────────────────
    XTIRDefSite* paramDef = [XTIRDefSite parameterDef];

    XTIRValue* valA = [[XTIRValue alloc] initWithValueId:[fn allocateValueId]
                                                    type:u8Type
                                                 defSite:paramDef];
    XTIRValue* valB = [[XTIRValue alloc] initWithValueId:[fn allocateValueId]
                                                    type:u8Type
                                                 defSite:paramDef];
    XTIRValue* valM0 = [[XTIRValue alloc] initWithValueId:[fn allocateValueId]
                                                     type:memType
                                                  defSite:paramDef];
    [fn registerValue:valA];
    [fn registerValue:valB];
    [fn registerValue:valM0];

    // ── 6. %c:U8 = Add %a, %b ─────────────────────────────────────────
    XTIRValue* valC = [[XTIRValue alloc] initWithValueId:[fn allocateValueId]
                                                    type:u8Type
                                                 defSite:[[XTIRDefSite alloc] initWithBlock:entry insnIndex:0]];
    [fn registerValue:valC];

    XTIRInsn* addInsn = [[XTIRInsn alloc] initWithOpcode:XTIROpAdd
                                                  result:valC
                                                operands:@[
                                                    [XTIROperand useWithValueId:valA.valueId],
                                                    [XTIROperand useWithValueId:valB.valueId],
                                                ]
                                                  dbgLoc:nil];
    [entry appendInstruction:addInsn];

    // ── 7. Return %c, %m0 ─────────────────────────────────────────────
    XTIRInsn* retInsn = [[XTIRInsn alloc] initWithOpcode:XTIROpReturn
                                                  result:nil
                                                operands:@[
                                                    [XTIROperand useWithValueId:valC.valueId],
                                                    [XTIROperand useWithValueId:valM0.valueId],
                                                ]
                                                  dbgLoc:nil];
    [entry setTerminator:retInsn];

    // ── 8. Assertions ──────────────────────────────────────────────────
    int failures = 0;

    // Function should have 1 block
    if (fn.blocks.count != 1)
        {
        fprintf(stderr, "  FAIL: expected 1 block, got %lu\n",
                (unsigned long)fn.blocks.count);
        failures++;
        }

    // Entry block should have 0 phis
    if (entry.phiNodes.count != 0)
        {
        fprintf(stderr, "  FAIL: expected 0 phis, got %lu\n",
                (unsigned long)entry.phiNodes.count);
        failures++;
        }

    // Entry block should have exactly 1 regular instruction (Add)
    if (entry.instructions.count != 1)
        {
        fprintf(stderr, "  FAIL: expected 1 instruction, got %lu\n",
                (unsigned long)entry.instructions.count);
        failures++;
        }

    // Entry block should have a terminator
    if (entry.terminator == nil)
        {
        fprintf(stderr, "  FAIL: expected terminator, got nil\n");
        failures++;
        }

    // Terminator should be Return
    if (entry.terminator.opcode != XTIROpReturn)
        {
        fprintf(stderr, "  FAIL: expected Return terminator, got opcode %d\n",
                (int)entry.terminator.opcode);
        failures++;
        }

    // Add instruction should have 2 operands
    if (addInsn.operands.count != 2)
        {
        fprintf(stderr, "  FAIL: expected 2 operands on Add, got %lu\n",
                (unsigned long)addInsn.operands.count);
        failures++;
        }

    // Return instruction should have 2 operands (valC, valM0)
    if (retInsn.operands.count != 2)
        {
        fprintf(stderr, "  FAIL: expected 2 operands on Return, got %lu\n",
                (unsigned long)retInsn.operands.count);
        failures++;
        }

    // Value IDs should be 0, 1, 2, 3
    if (valA.valueId != 0 || valB.valueId != 1 || valM0.valueId != 2 || valC.valueId != 3)
        {
        fprintf(stderr, "  FAIL: unexpected value id sequence (%u %u %u %u)\n",
                (unsigned)valA.valueId, (unsigned)valB.valueId,
                (unsigned)valM0.valueId, (unsigned)valC.valueId);
        failures++;
        }

    // Block should reject appending after terminator
    @try
        {
        XTIRInsn* badInsn = [[XTIRInsn alloc] initWithOpcode:XTIROpAdd
                                                      result:nil
                                                    operands:@[]
                                                      dbgLoc:nil];
        [entry appendInstruction:badInsn];
        fprintf(stderr, "  FAIL: appending after terminator should have asserted\n");
        failures++;
        }
    @catch (NSException* e)
        {
        // Expected — this is correct behaviour
        }

    // Block should reject a second terminator
    @try
        {
        XTIRInsn* dupTerm = [[XTIRInsn alloc] initWithOpcode:XTIROpReturn
                                                      result:nil
                                                    operands:@[]
                                                      dbgLoc:nil];
        [entry setTerminator:dupTerm];
        fprintf(stderr, "  FAIL: setting second terminator should have asserted\n");
        failures++;
        }
    @catch (NSException* e)
        {
        // Expected
        }

    // Function should reject duplicate value ids
    @try
        {
        XTIRValue* dupVal = [[XTIRValue alloc] initWithValueId:0 // same as valA
                                                          type:u8Type
                                                       defSite:paramDef];
        [fn registerValue:dupVal];
        fprintf(stderr, "  FAIL: registering duplicate value id should have asserted\n");
        failures++;
        }
    @catch (NSException* e)
        {
        // Expected
        }

    // Block should reject a non-terminator instruction as terminator
    @try
        {
        XTIRBlock* b2 = [[XTIRBlock alloc] init];
        XTIRInsn* nonTerm = [[XTIRInsn alloc] initWithOpcode:XTIROpAdd
                                                      result:nil
                                                    operands:@[]
                                                      dbgLoc:nil];
        [b2 setTerminator:nonTerm];
        fprintf(stderr, "  FAIL: setting non-terminator as terminator should have asserted\n");
        failures++;
        }
    @catch (NSException* e)
        {
        // Expected
        }

    if (failures == 0)
        {
        fprintf(stderr, "  PASS (%lu blocks, %lu insns, %lu phis, %u values)\n",
                (unsigned long)fn.blocks.count,
                (unsigned long)entry.instructions.count,
                (unsigned long)entry.phiNodes.count,
                (unsigned)[fn valueForId:3].valueId);
        }

    return failures;
    }
