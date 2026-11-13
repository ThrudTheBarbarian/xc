; A field of element [i] of an array of structs in one getelementptr,
; `%struct.V2, ptr %w, i64 %i, i32 k` (p[i].k), as clang writes it: the reader
; took it as p[0].k. Summing x + y over 20000 elements gives 1019901.
%struct.V2 = type { float, float }
@.fmt = private unnamed_addr constant [5 x i8] c"%ld\0A\00", align 1
declare i32 @printf(ptr, ...)
declare ptr @malloc(i64)
define internal i64 @sumV(ptr %w, i64 %n) {
entry:
  br label %cond
cond:
  %s = phi i64 [ 0, %entry ], [ %s1, %body ]
  %i = phi i64 [ 0, %entry ], [ %i1, %body ]
  %c = icmp ult i64 %i, %n
  br i1 %c, label %body, label %exit
exit:
  ret i64 %s
body:
  %px = getelementptr inbounds %struct.V2, ptr %w, i64 %i, i32 0
  %x = load float, ptr %px, align 4
  %py = getelementptr inbounds %struct.V2, ptr %w, i64 %i, i32 1
  %y = load float, ptr %py, align 4
  %a = fadd float %x, %y
  %v = fptosi float %a to i64
  %s1 = add i64 %s, %v
  %i1 = add i64 %i, 1
  br label %cond
}
define i32 @main() {
entry:
  %w = call ptr @malloc(i64 160000)
  br label %fill
fill:
  %i = phi i64 [ 0, %entry ], [ %i1, %fill ]
  %px = getelementptr inbounds %struct.V2, ptr %w, i64 %i, i32 0
  %py = getelementptr inbounds %struct.V2, ptr %w, i64 %i, i32 1
  %m = urem i64 %i, 101
  %fx = uitofp i64 %m to float
  store float %fx, ptr %px, align 4
  store float 1.0, ptr %py, align 4
  %i1 = add i64 %i, 1
  %d = icmp ult i64 %i1, 20000
  br i1 %d, label %fill, label %go
go:
  %r = call i64 @sumV(ptr %w, i64 20000)
  %p = call i32 (ptr, ...) @printf(ptr @.fmt, i64 %r)
  ret i32 0
}
