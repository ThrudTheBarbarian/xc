# support/arm9 — ARMv7-A (AArch32) backend harness

Bring-up harness for the **xtc A32 backend** targeting the **Zynq-7020 Cortex-A9
(xtos)**.

This is **Tier-1** (host-only, no xtos): build A32 with the `arm-none-eabi`
toolchain, run under `qemu-system-arm -M xilinx-zynq-a9` with **semihosting** as
the deterministic stdout sink, the A32 analogue of `xts`/`xst`.

That toolchain is needed to build this harness, not to use the compiler.
`xcc -A arm9` emits ELF ARM EABI5 itself, so a downloaded toolchain compiles for
arm9 with no `arm-none-eabi` tools installed. Tier-2 is the
xtos loader (`svc #1` syscalls, `ET_DYN` + the 3 relocations); see the XTOS
loader (`LOADER` in `build.env`).

## ABI — read automatically, never hardcoded
The Cortex-A9 ABI flags come from the Vitis-generated BSP, not this tree:
```
bsp/cortexa9_toolchain.cmake  →  -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard
```
`./bsp-flags.sh` extracts them (override the search root with `$XTC_ARM9_BSP`;
documented fallback if the BSP isn't built).

## Gotchas baked into `crt0.s`
- **VFP is OFF at reset.** `-mfloat-abi=hard` ⇒ the first FP instruction traps
  unless `crt0` enables the FPU (CPACR cp10/cp11 + `FPEXC.EN`) FIRST.
- **No hardware integer divide.** Cortex-A9 lacks `sdiv`/`udiv`; the backend
  emits `__aeabi_idiv`/`__aeabi_uidiv`.
- `qemu -kernel` jumps to the ELF entry with **SP undefined** — `crt0` sets it.
- ELF symbols are **bare** (no leading underscore, unlike Mach-O): `main` is `main`.

## Run recipe (proven end-to-end)
```sh
xtc -A arm9 prog.xc -o prog.s                       # xtc-fe → xtcg-arm9
FLAGS=$(support/arm9/bsp-flags.sh)
arm-none-eabi-gcc $FLAGS -nostdlib -nostartfiles \
    -Wl,-Ttext=0x00100000 -Wl,-e,_start \
    support/arm9/crt0.s prog.s -o prog.elf
qemu-system-arm -M xilinx-zynq-a9 -cpu cortex-a9 -nographic -semihosting -kernel prog.elf
```

## Status / next
- ✅ scaffolding + `XTArm9Backend` integer/control-flow subset, verified in qemu
- ⬜ `newlib` printf path (so `Stdio.xc` lowers + the corpus runs `target=arm9`)
- ⬜ the rest of instruction selection (FP/VFP, structs, ARC runtime), PIC, DWARF
