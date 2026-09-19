#import <Foundation/Foundation.h>

// Forward declarations of test-suite entry points.
// runCodeGenTests and runBankPageTrackerTests are not declared here —
// their suites lived in the old codegen tree that wasn't copied
//. The new-IR test harness (Layer 2 verifier,
// Layer 3 per-pass golden, Layer 4 cross-backend) is added as those
// layers come online.
extern int runPreprocessorTests(void);
extern int runLexerTests(void);
extern int runParserTests(void);
extern int runSemanticTests(void);
extern int runBankDescriptorTests(void);
extern int runXtLayoutTests(void);
extern int runRegionCBankTests(void);
extern int runXtOpcodeTests(void);
extern int runIRBuildTests(void);
extern int runIRDominatorTests(void);
extern int runIRVerifierTests(void);
extern int runIRLoweringTests(void);
extern int runArm64CodegenTests(void);
extern int runWasmCodegenTests(void);
extern int runXT6502CodegenTests(void);
extern int runDwarfReaderTests(void);
extern int runTypeWidthInvariantTests(void);
extern int runArm9ImmediateRangeTests(void);
extern int runArm64AssemblerTests(void);
extern int runM68kAssemblerTests(void);
extern int runArm64MachOTests(void);
extern int runX86_64ElfWriterTests(void);
extern int runArm64ElfWriterTests(void);

int main(int argc, const char* argv[])
    {
    @autoreleasepool
        {
        int failures = 0;

        fprintf(stderr, "=== xtc Test Suite ===\n\n");

        fprintf(stderr, "--- Preprocessor Tests ---\n");
        failures += runPreprocessorTests();

        fprintf(stderr, "\n--- Lexer Tests ---\n");
        failures += runLexerTests();

        fprintf(stderr, "\n--- Parser Tests ---\n");
        failures += runParserTests();

        fprintf(stderr, "\n--- Semantic Analyser Tests ---\n");
        failures += runSemanticTests();

        fprintf(stderr, "\n--- Bank Descriptor Tests ---\n");
        failures += runBankDescriptorTests();

        fprintf(stderr, "\n--- xt Layout Tests ---\n");
        failures += runXtLayoutTests();

        fprintf(stderr, "\n--- xta Region-C Bank Tests ---\n");
        failures += runRegionCBankTests();

        fprintf(stderr, "\n--- xta xt CPU Opcode Tests ---\n");
        failures += runXtOpcodeTests();

        fprintf(stderr, "\n--- Type Width Invariant Tests ---\n");
        failures += runTypeWidthInvariantTests();

        fprintf(stderr, "\n--- arm9 Immediate-Range Tests ---\n");
        failures += runArm9ImmediateRangeTests();

        fprintf(stderr, "\n--- AArch64 Assembler (self-host Phase 1) Tests ---\n");
        failures += runArm64AssemblerTests();
        failures += runM68kAssemblerTests();

        fprintf(stderr, "\n--- Mach-O Writer (self-host Phase 2) Tests ---\n");
        failures += runArm64MachOTests();
        failures += runX86_64ElfWriterTests();
        failures += runArm64ElfWriterTests();

        fprintf(stderr, "\n--- IR Build Tests ---\n");
        failures += runIRBuildTests();
        failures += runIRDominatorTests();

        fprintf(stderr, "\n--- IR Verifier Tests ---\n");
        failures += runIRVerifierTests();

        fprintf(stderr, "\n--- IR Lowering Tests ---\n");
        failures += runIRLoweringTests();

        fprintf(stderr, "\n--- Arm64 Codegen Tests ---\n");
        failures += runArm64CodegenTests();

        fprintf(stderr, "\n--- Wasm32 Codegen Tests ---\n");
        failures += runWasmCodegenTests();

        fprintf(stderr, "\n--- XT6502 Codegen Tests ---\n");
        failures += runXT6502CodegenTests();

        fprintf(stderr, "\n--- DWARF Reader Tests ---\n");
        failures += runDwarfReaderTests();

        fprintf(stderr, "\n=== Results: %d failure%s ===\n",
                failures, failures == 1 ? "" : "s");
        return failures > 0 ? 1 : 0;
        }
    }
