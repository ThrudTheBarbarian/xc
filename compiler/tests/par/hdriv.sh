#!/bin/bash
# hdriv.sh — loops whose header computes a value from the induction variable.
# clang's IR can put `getelementptr p, i` in a loop's condition block and read
# it in the body; xc's own lowering never does. The variable-trip unroller gave
# every copy the header's value (the address for i, never i+1..i+3), and the
# vectoriser's scalar remainder kept the vector loop's address for every trip.
# Scalar, vectorised, constant-trip, accumulator and exit-on-true loops, from
# hand-written IR read through XC_C_LL, against clang's build of the same IR.
# Skipped where there is no clang.
#
#   bash tests/par/hdriv.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PLAT=$( [ "$(uname -s)" = Darwin ] && echo osx || echo linux )
XC=${XC:-bin/$PLAT/xcc-xc}
if ! clang --version >/dev/null 2>&1; then
    echo "--- hdriv: skipped (no clang) ---"
    exit 0
fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
echo 'int main(void) { return 0; }' > "$W/h.c"
cat > "$W/h.ll" <<'LL'
@.str = private unnamed_addr constant [24 x i8] c"%.1f %ld %ld %.1f %.1f\0A\00", align 1
@fa = global [1003 x float] zeroinitializer, align 16
@ia = global [1003 x i64] zeroinitializer, align 16
@ib = global [1003 x i64] zeroinitializer, align 16
@fb = global [1003 x float] zeroinitializer, align 16
@fc = global [1024 x float] zeroinitializer, align 16

; float map through an address the header computes from i (vectorised, unrolled)
define void @fscale(ptr %p, i64 %n, float %k) noinline {
entry:
  br label %for.cond
for.cond:
  %i = phi i64 [ 0, %entry ], [ %i.next, %for.body ]
  %a = getelementptr inbounds float, ptr %p, i64 %i
  %c = icmp ult i64 %i, %n
  br i1 %c, label %for.body, label %exit
for.body:
  %x = load float, ptr %a, align 4
  %y = call float @llvm.fmuladd.f32(float %x, float %k, float 1.000000e+00)
  store float %y, ptr %a, align 4
  %i.next = add nuw nsw i64 %i, 1
  br label %for.cond
exit:
  ret void
}

; integer division (not vectorised): a scalar unroll, header address
define void @idiv(ptr %p, i64 %n, i64 %k) noinline {
entry:
  br label %for.cond
for.cond:
  %i = phi i64 [ 0, %entry ], [ %i.next, %for.body ]
  %a = getelementptr inbounds i64, ptr %p, i64 %i
  %c = icmp ult i64 %i, %n
  br i1 %c, label %for.body, label %exit
for.body:
  %x = load i64, ptr %a, align 8
  %y = udiv i64 %x, %k
  store i64 %y, ptr %a, align 8
  %i.next = add nuw nsw i64 %i, 1
  br label %for.cond
exit:
  ret void
}

; a header value from i that is not an address: q[i] = i*3 + 7, exit on true
define void @ival(ptr %q, i64 %n) noinline {
entry:
  br label %for.cond
for.cond:
  %i = phi i64 [ 0, %entry ], [ %i.next, %for.body ]
  %m = mul i64 %i, 3
  %v = add i64 %m, 7
  %a = getelementptr inbounds i64, ptr %q, i64 %i
  %c = icmp eq i64 %i, %n
  br i1 %c, label %exit, label %for.body
for.body:
  store i64 %v, ptr %a, align 8
  %i.next = add nuw nsw i64 %i, 1
  br label %for.cond
exit:
  ret void
}

; a float sum read through the header's address (a carried accumulator)
define float @fsum(ptr %p, i64 %n) noinline {
entry:
  br label %for.cond
for.cond:
  %i = phi i64 [ 0, %entry ], [ %i.next, %for.body ]
  %s = phi float [ 0.000000e+00, %entry ], [ %s.next, %for.body ]
  %a = getelementptr inbounds float, ptr %p, i64 %i
  %c = icmp ult i64 %i, %n
  br i1 %c, label %for.body, label %exit
for.body:
  %x = load float, ptr %a, align 4
  %s.next = fadd float %s, %x
  %i.next = add nuw nsw i64 %i, 1
  br label %for.cond
exit:
  ret float %s
}

; the same with a constant trip that divides by four: no guard between copies
define void @fconst(ptr %p, float %k) noinline {
entry:
  br label %for.cond
for.cond:
  %i = phi i64 [ 0, %entry ], [ %i.next, %for.body ]
  %a = getelementptr inbounds float, ptr %p, i64 %i
  %c = icmp ult i64 %i, 1024
  br i1 %c, label %for.body, label %exit
for.body:
  %x = load float, ptr %a, align 4
  %y = fmul float %x, %k
  store float %y, ptr %a, align 4
  %i.next = add nuw nsw i64 %i, 1
  br label %for.cond
exit:
  ret void
}

define i32 @main() {
entry:
  br label %init
init:
  %i = phi i64 [ 0, %entry ], [ %i.next, %init ]
  %f = uitofp i64 %i to float
  %pa = getelementptr inbounds float, ptr @fa, i64 %i
  store float %f, ptr %pa, align 4
  %pb = getelementptr inbounds float, ptr @fb, i64 %i
  store float %f, ptr %pb, align 4
  %i8 = mul i64 %i, 8
  %pi = getelementptr inbounds i64, ptr @ia, i64 %i
  store i64 %i8, ptr %pi, align 8
  %i.next = add nuw nsw i64 %i, 1
  %done = icmp eq i64 %i.next, 1003
  br i1 %done, label %run, label %init
run:
  br label %initc
initc:
  %ic = phi i64 [ 0, %run ], [ %ic.next, %initc ]
  %fcv = uitofp i64 %ic to float
  %pc = getelementptr inbounds float, ptr @fc, i64 %ic
  store float %fcv, ptr %pc, align 4
  %ic.next = add nuw nsw i64 %ic, 1
  %donec = icmp eq i64 %ic.next, 1024
  br i1 %donec, label %run2, label %initc
run2:
  call void @fconst(ptr @fc, float 2.000000e+00)
  call void @fscale(ptr @fa, i64 1003, float 3.000000e+00)
  call void @idiv(ptr @ia, i64 1003, i64 4)
  call void @ival(ptr @ib, i64 1003)
  %s = call float @fsum(ptr @fb, i64 1003)
  br label %chk
chk:
  %j = phi i64 [ 0, %run2 ], [ %j.next, %chk ]
  %fs = phi double [ 0.0, %run2 ], [ %fs.next, %chk ]
  %is = phi i64 [ 0, %run2 ], [ %is.next, %chk ]
  %bs = phi i64 [ 0, %run2 ], [ %bs.next, %chk ]
  %pf = getelementptr inbounds float, ptr @fa, i64 %j
  %vf = load float, ptr %pf, align 4
  %jf = uitofp i64 %j to double
  %vd = fpext float %vf to double
  %wd = fmul double %vd, %jf
  %fs.next = fadd double %fs, %wd
  %pi2 = getelementptr inbounds i64, ptr @ia, i64 %j
  %vi = load i64, ptr %pi2, align 8
  %wi = mul i64 %vi, %j
  %is.next = add i64 %is, %wi
  %pb2 = getelementptr inbounds i64, ptr @ib, i64 %j
  %vb = load i64, ptr %pb2, align 8
  %wb = mul i64 %vb, %j
  %bs.next = add i64 %bs, %wb
  %j.next = add nuw nsw i64 %j, 1
  %jd = icmp eq i64 %j.next, 1003
  br i1 %jd, label %out, label %chk
out:
  %e5 = load float, ptr getelementptr inbounds (float, ptr @fc, i64 1021), align 4
  %e5d = fpext float %e5 to double
  %sd = fpext float %s to double
  %r = call i32 (ptr, ...) @printf(ptr @.str, double %fs.next, i64 %is.next, i64 %bs.next, double %e5d, double %sd)
  ret i32 0
}

declare float @llvm.fmuladd.f32(float, float, float)
declare i32 @printf(ptr, ...)
LL
clang -w -O0 -o "$W/ref" "$W/h.ll" || { echo "--- hdriv: FAIL (clang cannot build the IR) ---"; exit 1; }
want=$("$W/ref")
for o in O0 O2 O3; do
    XC_C_LL="$W/h.ll" "$XC" -q -$o --par-style=cpu -H . -o "$W/p" "$W/h.c" > "$W/b" 2>&1 \
        || { echo "FAIL hdriv: -$o does not build"; head -3 "$W/b"; fail=1; continue; }
    got=$("$W/p")
    [ "$got" = "$want" ] || { echo "FAIL hdriv: -$o gives $got, clang's $want"; fail=1; }
done
[ $fail = 0 ] && echo "--- hdriv: pass ---" || echo "--- hdriv: FAIL ---"
exit $fail
