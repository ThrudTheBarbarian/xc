; trunc iN to i1 is the low bit (#155): clang's switch-to-bit-test lowering of
; `c == 'a' || c == 'e' || c == 'i' || c == 'o' || c == 'u'` tests one bit of
; a shifted mask. Counting the vowels of the string gives 19.
@.str = private unnamed_addr constant [71 x i8] c"the quick brown fox jumps over the lazy dog and keeps running far away\00", align 1
@.fmt = private unnamed_addr constant [4 x i8] c"%d\0A\00", align 1
declare i32 @printf(ptr, ...)
define internal i32 @count(ptr %p, i64 %n) {
entry:
  br label %cond
cond:
  %acc = phi i32 [ 0, %entry ], [ %add, %end ]
  %i = phi i64 [ 0, %entry ], [ %i1, %end ]
  %c0 = icmp ult i64 %i, %n
  br i1 %c0, label %body, label %exit
exit:
  ret i32 %acc
body:
  %q = getelementptr inbounds i8, ptr %p, i64 %i
  %c = load i8, ptr %q, align 1
  %d = add i8 %c, -97
  %r1 = shl i8 %d, 7
  %r2 = lshr i8 %d, 1
  %r = or i8 %r1, %r2
  %u = icmp ult i8 %r, 8
  br i1 %u, label %hole, label %rhs
rhs:
  %e = icmp eq i8 %c, 117
  %z = zext i1 %e to i32
  br label %end
hole:
  %sh = lshr i8 -107, %r
  %bit = trunc i8 %sh to i1
  br i1 %bit, label %end, label %rhs
end:
  %v = phi i32 [ %z, %rhs ], [ 1, %hole ]
  %add = add nuw nsw i32 %v, %acc
  %i1 = add nuw nsw i64 %i, 1
  br label %cond
}
define i32 @main() {
entry:
  %r = call i32 @count(ptr @.str, i64 70)
  %x = call i32 (ptr, ...) @printf(ptr @.fmt, i32 %r)
  ret i32 0
}
