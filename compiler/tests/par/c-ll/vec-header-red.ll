target datalayout = "e-m:o-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "arm64-apple-macosx15.0.0"

@.str = private unnamed_addr constant [10 x i8] c"%u %.17g\0A\00", align 1

; Function Attrs: mustprogress noinline norecurse ssp uwtable(sync)

declare i32 @__gxx_personality_v0(...)

; Function Attrs: nofree nounwind
declare noundef i32 @printf(ptr nocapture noundef readonly, ...) local_unnamed_addr #1

; Function Attrs: mustprogress noinline nounwind ssp uwtable(sync)
define i32 @_Z3redIPKjjET0_T_S3_S2_(ptr noundef %first, ptr noundef %last, i32 noundef %init) local_unnamed_addr #2 {
entry:
  %sub.ptr.lhs.cast = ptrtoint ptr %last to i64
  %xrr0.s = ptrtoint ptr %first to i64
  %xrr0.d = sub i64 %sub.ptr.lhs.cast, %xrr0.s
  %xrr0.t = add i64 %xrr0.d, -9
  %xrr0.n = sdiv i64 %xrr0.t, 4
  %xrr0.pos = icmp sgt i64 %xrr0.n, 0
  %xrr0.m = select i1 %xrr0.pos, i64 %xrr0.n, i64 0
  %xrr0.pe = getelementptr inbounds i32, ptr %first, i64 %xrr0.m
  br label %while.cond

while.cond:                                       ; preds = %while.body, %entry
  %init.addr.0 = phi i32 [ %init, %entry ], [ %add, %while.body ]
  %xrr0.i = phi i64 [ 0, %entry ], [ %xrr0.next, %while.body ]
  %first.addr.0 = getelementptr inbounds i32, ptr %first, i64 %xrr0.i
  %sub.ptr.rhs.cast = ptrtoint ptr %first.addr.0 to i64
  %sub.ptr.sub = sub i64 %sub.ptr.lhs.cast, %sub.ptr.rhs.cast
  %cmp = icmp slt i64 %xrr0.i, %xrr0.n
  br i1 %cmp, label %while.body, label %xrr0.exit

while.body:                                       ; preds = %while.cond
  %0 = load i32, ptr %first.addr.0, align 4
  %add = add i32 %0, %init.addr.0










  %xrr0.next = add nuw nsw i64 %xrr0.i, 1
  br label %while.cond
xrr0.exit:
  br label %for.cond

for.cond:                                         ; preds = %while.cond, %for.body
  %init.addr.1 = phi i32 [ %add8, %for.body ], [ %init.addr.0, %xrr0.exit ]
  %first.addr.1 = phi ptr [ %incdec.ptr, %for.body ], [ %xrr0.pe, %xrr0.exit ]
  %cmp7.not = icmp eq ptr %first.addr.1, %last
  br i1 %cmp7.not, label %for.end, label %for.body

for.body:                                         ; preds = %for.cond
  %4 = load i32, ptr %first.addr.1, align 4
  %add8 = add i32 %4, %init.addr.1
  %incdec.ptr = getelementptr inbounds i8, ptr %first.addr.1, i64 4
  br label %for.cond

for.end:                                          ; preds = %for.cond
  ret i32 %init.addr.1
}

; Function Attrs: mustprogress noinline nounwind ssp uwtable(sync)
define double @_Z3redIPKddET0_T_S3_S2_(ptr noundef %first, ptr noundef %last, double noundef %init) local_unnamed_addr #2 {
entry:
  %sub.ptr.lhs.cast = ptrtoint ptr %last to i64
  %xrr0.s = ptrtoint ptr %first to i64
  %xrr0.d = sub i64 %sub.ptr.lhs.cast, %xrr0.s
  %xrr0.t = add i64 %xrr0.d, -17
  %xrr0.n = sdiv i64 %xrr0.t, 8
  %xrr0.pos = icmp sgt i64 %xrr0.n, 0
  %xrr0.m = select i1 %xrr0.pos, i64 %xrr0.n, i64 0
  %xrr0.pe = getelementptr inbounds double, ptr %first, i64 %xrr0.m
  br label %while.cond

while.cond:                                       ; preds = %while.body, %entry
  %init.addr.0 = phi double [ %init, %entry ], [ %add, %while.body ]
  %xrr0.i = phi i64 [ 0, %entry ], [ %xrr0.next, %while.body ]
  %first.addr.0 = getelementptr inbounds double, ptr %first, i64 %xrr0.i
  %sub.ptr.rhs.cast = ptrtoint ptr %first.addr.0 to i64
  %sub.ptr.sub = sub i64 %sub.ptr.lhs.cast, %sub.ptr.rhs.cast
  %cmp = icmp slt i64 %xrr0.i, %xrr0.n
  br i1 %cmp, label %while.body, label %xrr0.exit

while.body:                                       ; preds = %while.cond
  %0 = load double, ptr %first.addr.0, align 8
  %add = fadd double %init.addr.0, %0










  %xrr0.next = add nuw nsw i64 %xrr0.i, 1
  br label %while.cond
xrr0.exit:
  br label %for.cond

for.cond:                                         ; preds = %while.cond, %for.body
  %init.addr.1 = phi double [ %add8, %for.body ], [ %init.addr.0, %xrr0.exit ]
  %first.addr.1 = phi ptr [ %incdec.ptr, %for.body ], [ %xrr0.pe, %xrr0.exit ]
  %cmp7.not = icmp eq ptr %first.addr.1, %last
  br i1 %cmp7.not, label %for.end, label %for.body

for.body:                                         ; preds = %for.cond
  %4 = load double, ptr %first.addr.1, align 8
  %add8 = fadd double %init.addr.1, %4
  %incdec.ptr = getelementptr inbounds i8, ptr %first.addr.1, i64 8
  br label %for.cond

for.end:                                          ; preds = %for.cond
  ret double %init.addr.1
}

; Function Attrs: nobuiltin allocsize(0)
declare nonnull ptr @_Znwm(i64 noundef) local_unnamed_addr #3

; Function Attrs: nobuiltin nounwind
declare void @_ZdlPv(ptr noundef) local_unnamed_addr #4

attributes #0 = { mustprogress noinline norecurse ssp uwtable(sync) "frame-pointer"="non-leaf" "no-trapping-math"="true" "probe-stack"="__chkstk_darwin" "stack-protector-buffer-size"="8" "target-cpu"="apple-m1" "target-features"="+aes,+altnzcv,+bti,+ccdp,+ccidx,+complxnum,+crc,+dit,+dotprod,+flagm,+fp-armv8,+fp16fml,+fptoint,+fullfp16,+jsconv,+lse,+neon,+pauth,+perfmon,+predres,+ras,+rcpc,+rdm,+sb,+sha2,+sha3,+specrestrict,+ssbs,+v8.1a,+v8.2a,+v8.3a,+v8.4a,+v8.5a,+v8a,+zcm,+zcz" }
attributes #1 = { nofree nounwind "frame-pointer"="non-leaf" "no-trapping-math"="true" "probe-stack"="__chkstk_darwin" "stack-protector-buffer-size"="8" "target-cpu"="apple-m1" "target-features"="+aes,+altnzcv,+bti,+ccdp,+ccidx,+complxnum,+crc,+dit,+dotprod,+flagm,+fp-armv8,+fp16fml,+fptoint,+fullfp16,+jsconv,+lse,+neon,+pauth,+perfmon,+predres,+ras,+rcpc,+rdm,+sb,+sha2,+sha3,+specrestrict,+ssbs,+v8.1a,+v8.2a,+v8.3a,+v8.4a,+v8.5a,+v8a,+zcm,+zcz" }
attributes #2 = { mustprogress noinline nounwind ssp uwtable(sync) "frame-pointer"="non-leaf" "no-trapping-math"="true" "probe-stack"="__chkstk_darwin" "stack-protector-buffer-size"="8" "target-cpu"="apple-m1" "target-features"="+aes,+altnzcv,+bti,+ccdp,+ccidx,+complxnum,+crc,+dit,+dotprod,+flagm,+fp-armv8,+fp16fml,+fptoint,+fullfp16,+jsconv,+lse,+neon,+pauth,+perfmon,+predres,+ras,+rcpc,+rdm,+sb,+sha2,+sha3,+specrestrict,+ssbs,+v8.1a,+v8.2a,+v8.3a,+v8.4a,+v8.5a,+v8a,+zcm,+zcz" }
attributes #3 = { nobuiltin allocsize(0) "frame-pointer"="non-leaf" "no-trapping-math"="true" "probe-stack"="__chkstk_darwin" "stack-protector-buffer-size"="8" "target-cpu"="apple-m1" "target-features"="+aes,+altnzcv,+bti,+ccdp,+ccidx,+complxnum,+crc,+dit,+dotprod,+flagm,+fp-armv8,+fp16fml,+fptoint,+fullfp16,+jsconv,+lse,+neon,+pauth,+perfmon,+predres,+ras,+rcpc,+rdm,+sb,+sha2,+sha3,+specrestrict,+ssbs,+v8.1a,+v8.2a,+v8.3a,+v8.4a,+v8.5a,+v8a,+zcm,+zcz" }
attributes #4 = { nobuiltin nounwind "frame-pointer"="non-leaf" "no-trapping-math"="true" "probe-stack"="__chkstk_darwin" "stack-protector-buffer-size"="8" "target-cpu"="apple-m1" "target-features"="+aes,+altnzcv,+bti,+ccdp,+ccidx,+complxnum,+crc,+dit,+dotprod,+flagm,+fp-armv8,+fp16fml,+fptoint,+fullfp16,+jsconv,+lse,+neon,+pauth,+perfmon,+predres,+ras,+rcpc,+rdm,+sb,+sha2,+sha3,+specrestrict,+ssbs,+v8.1a,+v8.2a,+v8.3a,+v8.4a,+v8.5a,+v8a,+zcm,+zcz" }
attributes #5 = { builtin allocsize(0) }
attributes #6 = { builtin nounwind }





@arr = global [1003 x i32] zeroinitializer, align 4
@darr = global [1003 x double] zeroinitializer, align 8
@.fmtx = private unnamed_addr constant [9 x i8] c"%u %.1f\0A\00", align 1
define i32 @main() {
entry:
  br label %fill
fill:
  %i = phi i64 [ 0, %entry ], [ %i1, %fill ]
  %p = getelementptr inbounds [1003 x i32], ptr @arr, i64 0, i64 %i
  %t = trunc i64 %i to i32
  %v = mul i32 %t, 7
  store i32 %v, ptr %p, align 4
  %q = getelementptr inbounds [1003 x double], ptr @darr, i64 0, i64 %i
  %f = uitofp i64 %i to double
  store double %f, ptr %q, align 8
  %i1 = add i64 %i, 1
  %c = icmp ult i64 %i1, 1003
  br i1 %c, label %fill, label %done
done:
  %end = getelementptr inbounds [1003 x i32], ptr @arr, i64 0, i64 1003
  %s = call i32 @_Z3redIPKjjET0_T_S3_S2_(ptr @arr, ptr %end, i32 5)
  %dend = getelementptr inbounds [1003 x double], ptr @darr, i64 0, i64 1003
  %d = call double @_Z3redIPKddET0_T_S3_S2_(ptr @darr, ptr %dend, double 0.5)
  %r = call i32 (ptr, ...) @printf(ptr @.fmtx, i32 %s, double %d)
  ret i32 0
}
