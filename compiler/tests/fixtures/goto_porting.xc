//xtc-flags: target=arm64
// goto — a C-porting aid (undocumented language feature). Forward, backward,
// nested-loop-out, and multi-label gotos with scalar locals.
#import "Stdio.xc"
i32 nested(void){ i32 s=0;
  for (i32 i=0;i<5;i=i+1){ for (i32 j=0;j<5;j=j+1){ if (i*j>6) goto done; s=s+1; } }
done: return s; }
i32 retry(i32 n){ i32 t=0;
top: t=t+1; if (t<n) goto top; return t; }
i32 skips(i32 x){ i32 r=0;
  if (x==1) goto one; if (x==2) goto two; r=100; goto end;
one: r=1; goto end;
two: r=2;
end: return r; }
i32 fwd(void){ i32 v=1; goto s; v=99; s: return v; }
void main(void){
  Stdio.printf("%d %d %d %d %d %d\n", nested(), retry(4), skips(0), skips(1), skips(2), fwd());
}
