#include <sys/stat.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <signal.h>
#include <sys/mman.h>
/* An allocation too large to satisfy FAILS — it does not quietly become a
   small one. This used to read `if (b < 256 || b > (16UL<<20)) b = 256;`, so a
   request over 16 MB returned a 256-byte block and the caller wrote straight
   past it: a String growing past ~1 MB (its capacity doubling to 2 M elements,
   times the stride below) segfaulted in its own copy loop, a long way from the
   cause. A minimum block size is fine; a silent maximum is not. */
/* ── the object header, defined ONCE ──────────────────────────────────────
   [magic:4][stride:8][count:8][dealloc:8][weak_head:8][refcount:4] = 40 bytes,
   and `obj` points just past it. The refcount is LAST so it sits at a small
   fixed negative offset the back ends can spell inline (obj-4).

   The refcount is 32-bit ON THE HOSTS. It was 16-bit, and a u16 WRAPS at
   65,536 — bug 025 and bug 079 were both an object freed while still live
   because its count went round. 65,536 references is not a hypothetical
   ceiling: one String retained per lexer token reached it in an ordinary
   compile. The 6502 and arm9 keep 16 bits, where two bytes an object is a real
   cost and no program gets near the ceiling.

   Every consumer of these numbers derives them from here. They used to be
   spelled as literals in this file, in rt-freestanding.c, in rt-checked.c and
   inline in four back ends — the "duplicated contract lists drift" shape of
   bug 027. */
#define XT_RC_BYTES   4
/* The magic sits next to the refcount, at payload-8, so a class instance's
   8-byte header (magic + refcount) and an array's 40-byte one put it in the
   same place; the 8-byte fields are 8-aligned (2026-10-31,
   private:docs/Design/compact-object-header.md). */
#define XT_STRIDE_OFF 0
#define XT_COUNT_OFF  8
#define XT_DEALLOC_OFF 16
#define XT_WEAKH_OFF  24
#define XT_MAGIC_OFF  32
#define XT_RC_OFF     36
#define XT_HDR        (XT_RC_OFF + XT_RC_BYTES)          /* 40 */
#define XT_RC_T       uint32_t
#define XT_RC_DYING   0x80000000U   /* poison: a nested release cannot reach 0 */

/* A count of 0 is stored as 0. It used to be raised to 1, which made freeing
   `new C[0]` run one dealloc on an element that does not exist and gave the
   empty array a `.length` of 1 (bug 472). The block keeps its 16-byte minimum. */
/* count * stride must not wrap: a wrapped product is a SMALL block whose header
   still says `count`, so every bounds check trusts it and the program writes past
   the end (a `new T[n]` with n from input is the classic heap overflow). The
   margin keeps the header and an aligned block's pages from wrapping it too. */
static void xt_size_check(unsigned long count,unsigned long stride){
    if(stride&&count>(~0UL-(1UL<<20))/stride){fprintf(stderr,"xcc: an allocation of %lu x %lu bytes overflows\n",count,stride);abort();}}
void *_xtc_alloc(unsigned long count,unsigned long stride,void(*dealloc)(void*)){
    xt_size_check(count,stride);
    unsigned long b=count*stride;if(b<16)b=16;
    uint8_t*p=(uint8_t*)calloc(1,b+XT_HDR);
    if(!p){fprintf(stderr,"xcc: out of memory allocating %lu x %lu bytes\n",count,stride);abort();}
    *(uint32_t*)(p+XT_MAGIC_OFF)=0x58544F42U;*(unsigned long*)(p+XT_STRIDE_OFF)=stride;
    *(unsigned long*)(p+XT_COUNT_OFF)=count;*(void(**)(void*))(p+XT_DEALLOC_OFF)=dealloc;
    *(void**)(p+XT_WEAKH_OFF)=0;*(XT_RC_T*)(p+XT_RC_OFF)=1;return p+XT_HDR;}
/* A class instance (`new C`) has an 8-byte header: the magic and the
   refcount, at payload-8 and payload-4 as in an array's header. It is one
   element by definition, so it has no count or stride; its dealloc is the
   vtable's header word XT_VT_DEALLOC (an instance's first word is its vtable
   pointer); and the head of its weak list, when a weak reference has ever
   pointed at it, lives in a side table, flagged by the second magic.
   private:docs/Design/compact-object-header.md. */
#define XT_MAGIC_OBJ  0x58544F4EU
#define XT_MAGIC_OBJW 0x58544F4FU   /* OBJ | 1: a weak reference has pointed here */
#define XT_OBJ_HDR    8
#define XT_VT_DEALLOC 3
#define XT_IS_OBJ(m)  (((m)|1U)==XT_MAGIC_OBJW)
#define XT_MAGIC_AT(o) (*(uint32_t*)((uint8_t*)(o)-8))
void *_xtc_alloc_object(unsigned long size){
    xt_size_check(1,size);
    uint8_t*p=(uint8_t*)calloc(1,size+XT_OBJ_HDR);
    if(!p){fprintf(stderr,"xcc: out of memory allocating %lu bytes\n",size);abort();}
    *(uint32_t*)p=XT_MAGIC_OBJ;*(XT_RC_T*)(p+4)=1;return p+XT_OBJ_HDR;}
/* One element is its own width, not eight. Every primitive array used to
   allocate 8 bytes per element — an 8x waste that also hit the (now removed)
   size ceiling eight times sooner than the element count suggested. */
void *_xtc_alloc_aligned(unsigned long count,unsigned long stride,void(*dealloc)(void*));
/* A numeric array of XT_SIMD_FROM bytes or more is page-aligned without being
   asked (par-blocks.md §3, "auto-simd"): a par block that captures it is then
   sized from the block and shared with a unified-memory GPU in place, as a
   `simd:` array is. Below that the GPU is never chosen, and the alignment's
   waste (up to two pages) would be out of proportion. Pointer and string
   arrays are never GPU data and stay as they were. */
#define XT_SIMD_FROM 65536UL
/* Below that, a numeric array of XT_LINE_FROM bytes or more starts on a
   64-byte cache line. calloc gives 16, and the header puts the data 40 past
   that, so a vector loop's 64-byte loads split across two lines for most
   placements (an AVX-512 sum ran at half speed on some runs: the stack and
   global arrays had the same fault). The block has the page-aligned shape —
   magic XT_MAGIC_ALIGNED, the allocator's base 8 bytes before the header —
   without the registry: it is never shared with a GPU, and _xtc_dealloc
   frees it by the same path. Smaller arrays keep the plain block, where the
   72 bytes of slack would be out of proportion. */
#define XT_LINE_FROM 1024UL
void *_xtc_alloc_line(unsigned long count,unsigned long stride);
#define XT_NEW_PRIM(n,st) ((n)*(st)>=XT_SIMD_FROM?_xtc_alloc_aligned((n),(st),0):(n)*(st)>=XT_LINE_FROM?_xtc_alloc_line((n),(st)):_xtc_alloc((n),(st),0))
void *_xtc_new_u8(unsigned long n){return XT_NEW_PRIM(n,1);}
void *_xtc_new_i8(unsigned long n){return XT_NEW_PRIM(n,1);}
void *_xtc_new_u16(unsigned long n){return XT_NEW_PRIM(n,2);}
void *_xtc_new_i16(unsigned long n){return XT_NEW_PRIM(n,2);}
void *_xtc_new_u32(unsigned long n){return XT_NEW_PRIM(n,4);}
void *_xtc_new_i32(unsigned long n){return XT_NEW_PRIM(n,4);}
void *_xtc_new_u64(unsigned long n){return XT_NEW_PRIM(n,8);}
void *_xtc_new_i64(unsigned long n){return XT_NEW_PRIM(n,8);}
void *_xtc_new_pointer(unsigned long n){return _xtc_alloc(n,8,0);}
void *_xtc_new_bool(unsigned long n){return XT_NEW_PRIM(n,1);}
void *_xtc_new_float(unsigned long n){return XT_NEW_PRIM(n,4);}
void *_xtc_new_double(unsigned long n){return XT_NEW_PRIM(n,8);}
void *_xtc_new_string(unsigned long n){return _xtc_alloc(n,8,0);}
/* `simd:` — a PAGE-ALIGNED payload (par-blocks.md): a unified-memory GPU wraps it
   in place, with no copy. The header still sits at payload-XT_HDR, so .length,
   release and the weak list read it as any block's; the allocator's own base is
   kept 8 bytes before the header, and a distinct magic marks the shape so
   _xtc_dealloc frees that base and not the header. 16 KB covers Apple Silicon's
   16 KB pages as well as 4 KB ones. */
#define XT_MAGIC_ALIGNED 0x58544F43U
#define XT_PAGE 16384UL
/* Every page-aligned block, so that a pointer INTO one can be traced to it:
   par's runtime sizes a captured pointer from the block it points into and
   shares the block with a unified-memory GPU in place (par-blocks.md §3), and
   a `simd:` pointer may be offset by arithmetic. A table of (payload, end)
   pairs sorted by payload, kept under the runtime lock; a lookup is a binary
   search. _xtc_simd_base gives the block's payload (0 outside every block),
   _xtc_simd_span the bytes from the pointer to the block's end (-1 outside). */
void _xt_rt_lock(void); void _xt_rt_unlock(void);
static uint8_t **xt_simd_tab; static unsigned char *xt_simd_flag; static unsigned long xt_simd_n, xt_simd_cap;
#define XT_SIMD_WATCHED 1
/* The first entry whose payload is above p. */
static unsigned long xt_simd_find(const uint8_t *p){unsigned long lo=0,hi=xt_simd_n;while(lo<hi){unsigned long m=(lo+hi)/2;if(xt_simd_tab[2*m]<=p)lo=m+1;else hi=m;}return lo;}
/* Always inlined: a second caller (_xtc_simd_register) must not change how
   clang compiles the allocator that has always inlined it. */
static inline __attribute__((always_inline)) void xt_simd_reg(uint8_t *payload,unsigned long bytes){_xt_rt_lock();
    if(xt_simd_n==xt_simd_cap){unsigned long c=xt_simd_cap?xt_simd_cap*2:64;uint8_t**t=(uint8_t**)calloc(2*c,sizeof(uint8_t*));unsigned char*g=(unsigned char*)calloc(c,1);if(!t||!g){free(t);free(g);_xt_rt_unlock();return;}
        for(unsigned long k=0;k<2*xt_simd_n;k++)t[k]=xt_simd_tab[k];for(unsigned long k=0;k<xt_simd_n;k++)g[k]=xt_simd_flag[k];free(xt_simd_tab);free(xt_simd_flag);xt_simd_tab=t;xt_simd_flag=g;xt_simd_cap=c;}
    unsigned long i=xt_simd_find(payload);for(unsigned long k=xt_simd_n;k>i;k--){xt_simd_tab[2*k]=xt_simd_tab[2*k-2];xt_simd_tab[2*k+1]=xt_simd_tab[2*k-1];xt_simd_flag[k]=xt_simd_flag[k-1];}
    xt_simd_tab[2*i]=payload;xt_simd_tab[2*i+1]=payload+bytes;xt_simd_flag[i]=0;xt_simd_n++;_xt_rt_unlock();}
static void xt_simd_unreg(uint8_t *payload){_xt_rt_lock();unsigned long i=xt_simd_find(payload);
    if(i>0&&xt_simd_tab[2*(i-1)]==payload){i--;for(unsigned long k=i;k+1<xt_simd_n;k++){xt_simd_tab[2*k]=xt_simd_tab[2*k+2];xt_simd_tab[2*k+1]=xt_simd_tab[2*k+3];xt_simd_flag[k]=xt_simd_flag[k+1];}xt_simd_n--;}
    _xt_rt_unlock();}
/* A global array the compiler gave pages of its own (its gpu-globals pass:
   numeric, 64 KB and more, on a 16 KB boundary and padded to whole pages),
   registered on the par runtime's first use of the registry so par's runtime shares
   and watches it as it does a heap block. bytes is the padded length.
   Not on a 4 KB page (a layout the image writer did not keep), it is left
   out: the watch protects whole pages, and one shared with a neighbour would
   fault outside every block. The array is then copied, as before. */
void _xtc_simd_register(void *p,unsigned long bytes){if(p&&bytes&&((unsigned long)p&4095UL)==0&&(bytes&4095UL)==0)xt_simd_reg((uint8_t*)p,bytes);}
void *_xtc_simd_base(void *p){_xt_rt_lock();unsigned long i=xt_simd_find((uint8_t*)p);uint8_t*b=0;if(i>0&&(uint8_t*)p<xt_simd_tab[2*(i-1)+1])b=xt_simd_tab[2*(i-1)];_xt_rt_unlock();return b;}
long _xtc_simd_span(void *p){_xt_rt_lock();unsigned long i=xt_simd_find((uint8_t*)p);long s=-1;if(i>0&&(uint8_t*)p<xt_simd_tab[2*(i-1)+1])s=(long)(xt_simd_tab[2*(i-1)+1]-(uint8_t*)p);_xt_rt_unlock();return s;}
/* Dirty tracking for a GPU runtime's resident copies (par-blocks.md §3,
   "resident data"). After an upload the runtime WATCHES the block: its pages
   are made read-only, and the first host write faults, which the handler
   absorbs — the block is marked written and made writable again — so a
   watched block that never faulted is one the host has not touched since,
   and need not be sent again. One fault per block per upload, from any code
   at all (a library, a memcpy), with no compiler involvement. A fault
   anywhere else is not ours: the action that was installed before is put
   back and the instruction re-run, so it lands where it always did. macOS
   reports a protection fault as SIGBUS, Linux as SIGSEGV; both are taken.
   The header (payload-40) is in the page before the payload and stays
   writable, so reference counts and the weak list are unaffected. */
static struct sigaction xt_simd_old[2]; static int xt_simd_installed;
static unsigned long xt_simd_pages(unsigned long i){return ((unsigned long)(xt_simd_tab[2*i+1]-xt_simd_tab[2*i])+XT_PAGE-1)&~(XT_PAGE-1);}
static void xt_simd_fault(int sig,siginfo_t*si,void*uc){(void)uc;uint8_t*a=(uint8_t*)si->si_addr;int ours=0;
    _xt_rt_lock();unsigned long i=xt_simd_find(a);
    /* Inside a block no longer watched: another thread's write faulted first
       and made it writable under this lock, so this one is retried (several
       CPU lanes writing an array a GPU run had watched, 2026-10-26). */
    if(i>0&&a<xt_simd_tab[2*(i-1)+1]){ours=1;if(xt_simd_flag[i-1]&XT_SIMD_WATCHED){xt_simd_flag[i-1]&=(unsigned char)~XT_SIMD_WATCHED;mprotect(xt_simd_tab[2*(i-1)],xt_simd_pages(i-1),PROT_READ|PROT_WRITE);}}
    _xt_rt_unlock();
    if(!ours)sigaction(sig,&xt_simd_old[sig==SIGSEGV?0:1],0);}
/* Watch the block at payload p (its start): 1 when it is one and its pages
   could be protected, else 0. */
int _xtc_simd_watch(void *p){int ok=0;_xt_rt_lock();unsigned long i=xt_simd_find((uint8_t*)p);
    if(i>0&&xt_simd_tab[2*(i-1)]==(uint8_t*)p){
        /* Field by field, not a memset: the NDK's clang zeroes a struct with `movi`, which XAArm64Assembler does not take. */
        if(!xt_simd_installed){struct sigaction sa;sa.sa_sigaction=xt_simd_fault;sa.sa_flags=SA_SIGINFO|SA_NODEFER;sigemptyset(&sa.sa_mask);
#ifdef __linux__
            sa.sa_restorer=0;
#endif
            sigaction(SIGSEGV,&sa,&xt_simd_old[0]);sigaction(SIGBUS,&sa,&xt_simd_old[1]);xt_simd_installed=1;}
        if(mprotect(p,xt_simd_pages(i-1),PROT_READ)==0){xt_simd_flag[i-1]|=XT_SIMD_WATCHED;ok=1;}}
    _xt_rt_unlock();return ok;}
/* The block is about to be written by the runtime itself (a copy back): its
   pages are made writable and it reads as written until watched again. */
void _xtc_simd_unwatch(void *p){_xt_rt_lock();unsigned long i=xt_simd_find((uint8_t*)p);
    if(i>0&&xt_simd_tab[2*(i-1)]==(uint8_t*)p&&(xt_simd_flag[i-1]&XT_SIMD_WATCHED)){xt_simd_flag[i-1]&=(unsigned char)~XT_SIMD_WATCHED;mprotect(p,xt_simd_pages(i-1),PROT_READ|PROT_WRITE);}
    _xt_rt_unlock();}
/* 0 when the block at p is watched and no write has faulted since; 1 when it
   has been written, is not watched, or is no block at all. */
int _xtc_simd_dirty(void *p){int d=1;_xt_rt_lock();unsigned long i=xt_simd_find((uint8_t*)p);
    if(i>0&&xt_simd_tab[2*(i-1)]==(uint8_t*)p&&(xt_simd_flag[i-1]&XT_SIMD_WATCHED))d=0;
    _xt_rt_unlock();return d;}
void *_xtc_alloc_aligned(unsigned long count,unsigned long stride,void(*dealloc)(void*)){
    xt_size_check(count,stride);
    /* The payload is rounded up to whole pages too: a GPU wrapping it in
       place (Metal's newBufferWithBytesNoCopy) needs a page-multiple length. */
    unsigned long b=count*stride;if(b<16)b=16;b=(b+XT_PAGE-1)&~(XT_PAGE-1);
    uint8_t*raw=(uint8_t*)calloc(1,b+XT_HDR+XT_PAGE+8);
    if(!raw){fprintf(stderr,"xcc: out of memory allocating %lu x %lu bytes\n",count,stride);abort();}
    uint8_t*payload=(uint8_t*)(((unsigned long)(raw+XT_HDR+8)+XT_PAGE-1)&~(XT_PAGE-1));uint8_t*p=payload-XT_HDR;
    *(uint32_t*)(p+XT_MAGIC_OFF)=XT_MAGIC_ALIGNED;*(unsigned long*)(p+XT_STRIDE_OFF)=stride;
    *(unsigned long*)(p+XT_COUNT_OFF)=count;*(void(**)(void*))(p+XT_DEALLOC_OFF)=dealloc;
    *(void**)(p+XT_WEAKH_OFF)=0;*(XT_RC_T*)(p+XT_RC_OFF)=1;*(void**)(p-8)=raw;xt_simd_reg(payload,count*stride);return payload;}
void *_xtc_alloc_line(unsigned long count,unsigned long stride){
    xt_size_check(count,stride);
    uint8_t*raw=(uint8_t*)calloc(1,count*stride+XT_HDR+64+8);
    if(!raw){fprintf(stderr,"xcc: out of memory allocating %lu x %lu bytes\n",count,stride);abort();}
    uint8_t*payload=(uint8_t*)(((unsigned long)(raw+XT_HDR+8)+63)&~63UL);uint8_t*p=payload-XT_HDR;
    *(uint32_t*)(p+XT_MAGIC_OFF)=XT_MAGIC_ALIGNED;*(unsigned long*)(p+XT_STRIDE_OFF)=stride;
    *(unsigned long*)(p+XT_COUNT_OFF)=count;*(void(**)(void*))(p+XT_DEALLOC_OFF)=0;
    *(void**)(p+XT_WEAKH_OFF)=0;*(XT_RC_T*)(p+XT_RC_OFF)=1;*(void**)(p-8)=raw;return payload;}
void *_xtc_new_simd_u8(unsigned long n){return _xtc_alloc_aligned(n,1,0);}
void *_xtc_new_simd_i8(unsigned long n){return _xtc_alloc_aligned(n,1,0);}
void *_xtc_new_simd_bool(unsigned long n){return _xtc_alloc_aligned(n,1,0);}
void *_xtc_new_simd_u16(unsigned long n){return _xtc_alloc_aligned(n,2,0);}
void *_xtc_new_simd_i16(unsigned long n){return _xtc_alloc_aligned(n,2,0);}
void *_xtc_new_simd_u32(unsigned long n){return _xtc_alloc_aligned(n,4,0);}
void *_xtc_new_simd_i32(unsigned long n){return _xtc_alloc_aligned(n,4,0);}
void *_xtc_new_simd_float(unsigned long n){return _xtc_alloc_aligned(n,4,0);}
void *_xtc_new_simd_u64(unsigned long n){return _xtc_alloc_aligned(n,8,0);}
void *_xtc_new_simd_i64(unsigned long n){return _xtc_alloc_aligned(n,8,0);}
void *_xtc_new_simd_double(unsigned long n){return _xtc_alloc_aligned(n,8,0);}
void *_xtc_new_simd_pointer(unsigned long n){return _xtc_alloc_aligned(n,8,0);}
void *_xtc_new_simd_string(unsigned long n){return _xtc_alloc_aligned(n,8,0);}
void _xtc_weak_zero_for(void*);
/* The element count of a `new T[N]` allocation, read from the header the
   allocator wrote (count at base+XT_COUNT_OFF, payload at base+XT_HDR). The `.length` of a
   runtime-sized heap array — private:docs/bugs/045 remedy 1.

   NOT u16: that truncated every array over 65535 elements, and for-in takes
   this same call, so it shortened ITERATION too and not merely a reported
   length (bug 234). The header field is `unsigned long` and is returned
   whole. */
unsigned long _xtc_count(void *o){return *(unsigned long*)((uint8_t*)o-XT_HDR+XT_COUNT_OFF);}
void _xtc_dealloc(void *o){
    uint32_t m0=XT_MAGIC_AT(o);
    if(XT_IS_OBJ(m0)){
        if(m0==XT_MAGIC_OBJW)_xtc_weak_zero_for(o);
        void(*d)(void*)=(*(void(***)(void*))o)[XT_VT_DEALLOC];
        if(d){*(XT_RC_T*)((uint8_t*)o-XT_RC_BYTES)=XT_RC_DYING;d(o);}
        free((uint8_t*)o-XT_OBJ_HDR);return;}
    _xtc_weak_zero_for(o);uint8_t*base=(uint8_t*)o-XT_HDR;
    unsigned long stride=*(unsigned long*)(base+XT_STRIDE_OFF);
    unsigned long count=*(unsigned long*)(base+XT_COUNT_OFF);
    void(*d)(void*)=*(void(**)(void*))(base+XT_DEALLOC_OFF);
    /* A page-aligned block holds numbers, never objects, so its dealloc slot
       is free for a ONCE hook: a GPU runtime that pinned the block for its
       copies (ParCuda.pinned) stores the unpin there, and it is called once
       with the payload before the block goes. The block's header is not its
       allocator base either (see _xtc_alloc_aligned). */
    if(*(uint32_t*)(base+XT_MAGIC_OFF)==XT_MAGIC_ALIGNED){if(d)d(o);
        /* Only a block on a page can be in the registry (a cache-line block
           of _xtc_alloc_line never is): the others skip the lock and search. */
        if(((unsigned long)o&(XT_PAGE-1))==0){_xtc_simd_unwatch(o);xt_simd_unreg((uint8_t*)o);}free(*(void**)(base-8));return;}
    if(d){*(XT_RC_T*)((uint8_t*)o-XT_RC_BYTES)=XT_RC_DYING;for(unsigned long i=0;i<count;i++)d((uint8_t*)o+i*stride);}
    free(base);}
#define _XT_WH(o) (*(void***)((uint8_t*)(o)-(XT_HDR-XT_WEAKH_OFF)))
/* The weak-reference intrusive list (private:docs/Design/weak-refs-intrusive.md) is the
   one piece of runtime state two xtc threads can mutate at once: registering,
   unregistering and dealloc-time zeroing all splice the same per-object chain.
   private:docs/Design/threading.md §4.4 calls this out as the thread-safety item the
   atomic refcount does NOT cover, so every list operation takes the runtime
   lock. _xt_rt_lock/unlock are a no-op until the first thread is spawned, so a
   single-threaded program pays one load and a branch, not a mutex. */
void _xt_rt_lock(void); void _xt_rt_unlock(void);
/* The intrusive weak chain keeps a back-pointer invariant: for a validly-linked
   slot, *(slot[-2]) == slot — pprev is &weak_head or &prev->next, and both hold
   `slot`. Stale bytes in a REUSED union member (a callback stored where a double
   / string / return address last sat) can leave slot[-2] non-null but BOGUS;
   the old code wrote *pp=nx straight through it and faulted in code (a return
   address unlinked as a chain node: bug 176). Verify the back-pointer first —
   a mismatch means the slot was never really linked here, so clear and bail. */
static void xt_weak_unreg(void **slot){void ***pp=(void***)slot[-2];if(!pp)return;if(*pp!=slot){slot[-2]=0;slot[-1]=0;return;}void **nx=(void**)slot[-1];*pp=nx;if(nx)nx[-2]=(void*)pp;slot[-2]=0;slot[-1]=0;}
void _xtc_weak_unregister(void **slot){_xt_rt_lock();xt_weak_unreg(slot);_xt_rt_unlock();}
/* An instance's weak-list head: a cell of its own (so slot[-2], which points
   at the head, stays valid when the table grows), found through an
   open-addressed table keyed by the object's address. Only objects a weak
   reference has pointed at are in it; all of it is under the runtime lock. */
typedef struct{void *obj;void ***cell;}xt_wtab_e;
static xt_wtab_e *xt_wtab;static unsigned long xt_wtab_cap,xt_wtab_n,xt_wtab_used;
#define XT_WTAB_DEAD ((void*)1)
static unsigned long xt_wtab_h(void *o){unsigned long x=(unsigned long)o>>3;x^=x>>17;x*=0xed5ad4bbUL;x^=x>>11;return x;}
static xt_wtab_e *xt_wtab_find(void *o){if(!xt_wtab_cap)return 0;unsigned long i=xt_wtab_h(o)&(xt_wtab_cap-1);
    for(;;){xt_wtab_e*e=&xt_wtab[i];if(e->obj==o)return e;if(!e->obj)return 0;i=(i+1)&(xt_wtab_cap-1);}}
static void xt_wtab_put(void *o,void ***cell);
static void xt_wtab_grow(void){unsigned long oc=xt_wtab_cap;xt_wtab_e*old=xt_wtab;
    xt_wtab_cap=oc?oc*2:64;while(xt_wtab_n*2>=xt_wtab_cap)xt_wtab_cap*=2;
    xt_wtab=(xt_wtab_e*)calloc(xt_wtab_cap,sizeof(xt_wtab_e));
    if(!xt_wtab){fprintf(stderr,"xcc: out of memory (weak references)\n");abort();}
    xt_wtab_n=0;xt_wtab_used=0;
    for(unsigned long i=0;i<oc;i++)if(old[i].obj&&old[i].obj!=XT_WTAB_DEAD)xt_wtab_put(old[i].obj,old[i].cell);free(old);}
static void xt_wtab_put(void *o,void ***cell){if((xt_wtab_used+1)*2>xt_wtab_cap)xt_wtab_grow();
    unsigned long i=xt_wtab_h(o)&(xt_wtab_cap-1);while(xt_wtab[i].obj&&xt_wtab[i].obj!=XT_WTAB_DEAD)i=(i+1)&(xt_wtab_cap-1);
    if(!xt_wtab[i].obj)xt_wtab_used++;xt_wtab[i].obj=o;xt_wtab[i].cell=cell;xt_wtab_n++;}
/* Head cells come from a free list, carved from blocks of 512, so a weakly
   referenced object costs no malloc and free of its own (weak_churn on a Pi 5:
   a calloc and a free each object's life were most of the side table's cost).
   A free cell's one word links the list. Under the lock. */
static void **xt_wcell_free;
static void ***xt_wcell_get(void){
    if(!xt_wcell_free){void **blk=(void**)calloc(512,sizeof(void*));
        if(!blk){fprintf(stderr,"xcc: out of memory (weak references)\n");abort();}
        for(int i=0;i<511;i++)blk[i]=(void*)&blk[i+1];blk[511]=0;xt_wcell_free=blk;}
    void **c=xt_wcell_free;xt_wcell_free=(void**)*c;*c=0;return (void***)c;}
static void xt_wcell_put(void ***c){*(void**)c=(void*)xt_wcell_free;xt_wcell_free=(void**)c;}
/* The address of obj's weak-list head, or 0 when obj is not a heap object
   (a stack instance, memory C made). Under the lock. */
static void ***xt_weak_head(void *obj,int make){
    uint32_t m=XT_MAGIC_AT(obj);
    if(m==0x58544F42U||m==XT_MAGIC_ALIGNED)return (void***)&_XT_WH(obj);
    if(!XT_IS_OBJ(m))return 0;
    xt_wtab_e*e=m==XT_MAGIC_OBJW?xt_wtab_find(obj):0;
    if(e)return e->cell;
    if(!make)return 0;
    void ***cell=xt_wcell_get();
    xt_wtab_put(obj,cell);XT_MAGIC_AT(obj)=XT_MAGIC_OBJW;return cell;}
void _xtc_weak_register(void **slot,void *obj){_xt_rt_lock();xt_weak_unreg(slot);void ***hd=obj?xt_weak_head(obj,1):0;if(!hd){_xt_rt_unlock();return;}void **nx=*hd;slot[-2]=(void*)hd;slot[-1]=(void*)nx;if(nx)nx[-2]=(void*)&slot[-1];*hd=slot;_xt_rt_unlock();}
void *_xtc_weak_load(void **slot){return *slot;}
/* Zero every weak slot naming obj. An instance's entry is found once and
   taken out as its slots are zeroed. */
static void xt_weak_zero_list(void ***hd){void **s=*hd;while(s){void **nx=(void**)s[-1];*s=0;s[-2]=0;s[-1]=0;s=nx;}*hd=0;}
void _xtc_weak_zero_for(void *obj){if(!obj)return;_xt_rt_lock();
    uint32_t m=XT_MAGIC_AT(obj);
    if(m==XT_MAGIC_OBJW){xt_wtab_e*e=xt_wtab_find(obj);
        if(e){void ***hd=e->cell;e->obj=XT_WTAB_DEAD;e->cell=0;xt_wtab_n--;xt_weak_zero_list(hd);xt_wcell_put(hd);}}
    else if(m==0x58544F42U||m==XT_MAGIC_ALIGNED)xt_weak_zero_list((void***)&_XT_WH(obj));
    _xt_rt_unlock();}
/* `write` comes from <unistd.h>, included below with the file helpers. It used
   to be declared here by hand, which made the header's own declaration a
   redefinition and stopped this file compiling on its own — inconvenient,
   since support/arm64/runtime/rt-macos.s is GENERATED from it. */
#include <unistd.h>
#include <errno.h>
void _putc(uint8_t c){char b=(char)c;write(1,&b,1);}
static void _emit(const char*b){unsigned long n=0;while(b[n])n++;write(1,b,n);}
static void _xtc_truncf(double v,uint8_t p){char b[64];snprintf(b,sizeof b,"%.*f",(int)(p+1),v);unsigned long L=0;while(b[L])L++;if(L)b[L-1]=0;_emit(b);}
void _xtc_pf(float f){char b[64];snprintf(b,sizeof b,"%.6f",(double)f);_emit(b);}
void _xtc_pd(double d){char b[64];snprintf(b,sizeof b,"%.10f",d);_emit(b);}
void _xtc_pfp(float f,uint8_t p){if(!p){char b[64];snprintf(b,sizeof b,"%.6f",(double)f);_emit(b);}else _xtc_truncf((double)f,p);}
void _xtc_pdp(double d,uint8_t p){if(!p){char b[64];snprintf(b,sizeof b,"%.10f",d);_emit(b);}else _xtc_truncf(d,p);}
float _xm_sqrtf(float x){return sqrtf(x);} double _xm_sqrt(double x){return sqrt(x);}
float _xm_sinf(float x){return sinf(x);} double _xm_sin(double x){return sin(x);}
float _xm_cosf(float x){return cosf(x);} double _xm_cos(double x){return cos(x);}
float _xm_tanf(float x){return tanf(x);} double _xm_tan(double x){return tan(x);}
float _xm_atanf(float x){return atanf(x);} double _xm_atan(double x){return atan(x);}
float _xm_lnf(float x){return logf(x);} double _xm_ln(double x){return log(x);}
float _xm_expf(float x){return expf(x);} double _xm_exp(double x){return exp(x);}
float _xm_powf(float a,float b){return powf(a,b);} double _xm_pow(double a,double b){return pow(a,b);}
// ── Time / PRNG (ported from support/arm64/runtime/libxt.c) ──
#include <time.h>
static int xt_rand_seeded=0;
static void xt_rand_init(void){if(!xt_rand_seeded){srandom(1u);xt_rand_seeded=1;}}
void _xt_srand(uint32_t seed){srandom(seed);xt_rand_seeded=1;}
uint32_t _xt_rand_u32(void){xt_rand_init();return ((uint32_t)random()<<16)^(uint32_t)random();}
float _xt_rand_f(void){xt_rand_init();return 0.5f+((float)random()/((float)RAND_MAX+1.0f))*0.5f;}
double _xt_rand_d(void){xt_rand_init();return 0.5+((double)random()/((double)RAND_MAX+1.0))*0.5;}
static double xt_clk_origin;
static double xt_now_secs(void){struct timespec ts;clock_gettime(CLOCK_MONOTONIC,&ts);return (double)ts.tv_sec+(double)ts.tv_nsec*1e-9;}
void _xt_clk_reset(void){xt_clk_origin=xt_now_secs();}
uint32_t _xt_clk_ticks(void){return (uint32_t)((xt_now_secs()-xt_clk_origin)*1.0e6);}
void _xt_clk_delay(uint32_t jiffies){double s=(double)jiffies/60.0;struct timespec req;req.tv_sec=(time_t)s;req.tv_nsec=(long)((s-(double)req.tv_sec)*1.0e9);nanosleep(&req,(struct timespec*)0);}
// ── bank regions (from arm64StubSourceEx) ──
static void *_xtc_bank_regions[3][256]={{0}};
void *_xtc_bank(uint8_t type,uint8_t idx){if(type>1)return 0;if(!_xtc_bank_regions[type][idx])_xtc_bank_regions[type][idx]=calloc(1,12288);return _xtc_bank_regions[type][idx];}
// ── Files, argv, exit (self-hosting M4; mirrored in support/arm64/runtime/libxt.c) ──
// A compiler written in xtc has to open its input and see its command line.
// Files are integer HANDLES so no xtc declaration names a host FILE*.
//
// NOTE the argv globals are filled by crt-macos.s, NOT by a constructor: the
// self-hosted link path has no __mod_init_func processing, so a constructor here
// would silently never run. The clang path's libxt.c does use a constructor,
// because there the crt is libSystem's.
#include <unistd.h>
#define XT_MAX_FILES 8
static FILE *xt_files[XT_MAX_FILES];
int32_t _xt_file_open(const char *path,const char *mode){for(int i=0;i<XT_MAX_FILES;i++){if(xt_files[i])continue;FILE*f=fopen(path,mode);if(!f)return -1;xt_files[i]=f;return i;}return -1;}
int32_t _xt_file_read(int32_t h,uint8_t *buf,uint32_t n){if(h<0||h>=XT_MAX_FILES||!xt_files[h])return -1;return (int32_t)fread(buf,1,(size_t)n,xt_files[h]);}
int32_t _xt_file_write(int32_t h,const uint8_t *buf,uint32_t n){if(h<0||h>=XT_MAX_FILES||!xt_files[h])return -1;return (int32_t)fwrite(buf,1,(size_t)n,xt_files[h]);}
void _xt_file_close(int32_t h){if(h<0||h>=XT_MAX_FILES||!xt_files[h])return;fclose(xt_files[h]);xt_files[h]=0;}
int32_t _xt_file_size(const char *path){FILE*f=fopen(path,"rb");if(!f)return -1;if(fseek(f,0,SEEK_END)!=0){fclose(f);return -1;}long n=ftell(f);fclose(f);return (n<0)?-1:(int32_t)n;}
int32_t _xt_file_exists(const char *path){FILE*f=fopen(path,"rb");if(!f)return 0;fclose(f);return 1;}

// The environment, read-only. A shipped compiler has to find things a user
// names by convention rather than by flag — the signing-key cache under
// $HOME/.xcc first among them — and without this the xtc driver had no way to
// ask, so the path had to be passed on every command line.
//
// Read-only on purpose: setting a variable in a process that is about to write
// a file helps nobody, and the surface stays one function.
const char *_xt_getenv(const char *name){ const char *v = getenv(name); return v ? v : ""; }

// Create a directory (and tolerate one that already exists). The signing-key
// cache lives under $HOME/.xcc, which on a fresh machine is not there yet — and
// a compiler that can generate a key but not the directory to put it in has
// only moved the failure.
int32_t _xt_mkdir(const char *path){
    if (mkdir(path, 0700) == 0) return 1;
    return (errno == EEXIST) ? 1 : 0;
}


// Mark a file executable (0755). The clang-path runtime (support/arm64/runtime/
// libxt.c) carries the same primitive: the two runtimes are alternative bodies
// for ONE contract, so a name added to either has to be added to both, or the
// self-hosted link fails to resolve it while the clang link succeeds.
#include <sys/stat.h>
int32_t _xt_file_chmod_exec(const char *path){return chmod(path,0755)==0?1:0;}
// The globals are STATIC and reached through _xt_set_args, which crt-macos.s
// calls with the (argc, argv) the LC_MAIN entry was handed. A non-static global
// would be interposable, so clang addresses it through the GOT — and the
// in-house assembler has no GOT relocation. Static keeps it adrp/add direct.
static int    xt_argc_v;
static char **xt_argv_v;
/* The stack canary (the back ends' frames with a local array or a taken
   address): a random word stored between those locals and the saved registers
   on entry and compared on every return. Its low byte is zero, as glibc's is,
   so a string copy cannot write the whole of it back. Every crt calls
   _xt_stack_guard_init first, before _xt_set_args (which must leave argc and
   argv alone: the crt used to rely on x0/x1 surviving it). */
/* Hidden: clang otherwise reaches it through the GOT, and the in-house linker
   gives a local symbol no GOT entry (rt-checked.c's __xt_ms_fns, the same). */
__attribute__((visibility("hidden"))) unsigned long __xt_stack_guard;
void _xt_stack_guard_init(void){unsigned long g=0;arc4random_buf(&g,sizeof g);g&=~0xFFUL;if(!g)g=0x5854434b53000000UL;__xt_stack_guard=g;}
void __xt_stack_fail(void){fprintf(stderr,"xcc: stack smashing detected (a local array was written past its end)\n");abort();}
void _xt_set_args(int argc,char **argv){xt_argc_v=argc;xt_argv_v=argv;}
int32_t _xt_argc(void){return (int32_t)xt_argc_v;}
const char *_xt_argv(int32_t i){static const char*empty="";if(i<0||i>=xt_argc_v||!xt_argv_v)return empty;return xt_argv_v[i];}
void _xt_exit(int32_t code){fflush(NULL);_exit((int)code);}

// Case-sensitive existence test. macOS filesystems are case-PRESERVING but
// case-insensitive, so a plain fopen("Sort.xc") happily opens a file actually
// named sort.xc — and the preprocessor would then import the user's own source
// as the "Sort library". Listing the directory and comparing the name byte for
// byte is the only way to ask the real question.
#include <dirent.h>
int32_t _xt_file_exists_exact(const char *path){
    const char *slash=strrchr(path,'/');
    const char *name=slash?slash+1:path;
    char dir[1024];
    if(slash){size_t n=(size_t)(slash-path);if(n>=sizeof dir)return 0;memcpy(dir,path,n);dir[n]=0;if(n==0){dir[0]='/';dir[1]=0;}}
    else {dir[0]='.';dir[1]=0;}
    DIR *d=opendir(dir);
    if(!d)return 0;
    struct dirent *e;
    int32_t found=0;
    while((e=readdir(d))!=0){if(strcmp(e->d_name,name)==0){found=1;break;}}
    closedir(d);
    return found;
}


// ── Threading (private:docs/Design/threading.md Phase 2) ──
// The bodies are shared verbatim with the clang-path runtime; see the header of
// the included file for why the include path differs between the two.
#include "../../../support/generic/runtime/xt-threads.c"
