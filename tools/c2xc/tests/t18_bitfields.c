/* bit-fields packed as C packs them: layout, reads, writes, initialisers */
#include <stdio.h>
#include <string.h>
#include <stddef.h>
struct hdr
    {
    signed ef_type : 8;
    unsigned seqno : 12;
    unsigned generation : 12;
    int uid;
    long ts;
    };
struct mix
    {
    char c;
    unsigned a : 3;
    unsigned b : 5;
    short s;
    unsigned int w : 20;
    int z;
    };
static struct hdr tab[3] = {{1, 5, 7, 42, 9}, {-2, 4095, 0, 1, 2}, {0}};
static void dump(const void* p, int n)
    {
    const unsigned char* b = p;
    int i;
    for (i = 0; i < n; i++)
        printf("%02x", b[i]);
    printf("\n");
    }
int main(void)
    {
    struct hdr h;
    struct mix m;
    memset(&h, 0, sizeof h);
    memset(&m, 0, sizeof m);
    printf("%d %d %d %d\n", (int)sizeof(struct hdr), (int)sizeof(struct mix), (int)offsetof(struct hdr, uid), (int)offsetof(struct mix, z));
    h.ef_type = -3;
    h.seqno = 4000;
    h.generation = 4095;
    h.uid = 7;
    h.ts = 8;
    printf("%d %u %u\n", h.ef_type, h.seqno, h.generation);
    h.seqno++;
    h.generation += 2;
    h.ef_type = h.ef_type * 2;
    h.seqno |= 1;
    printf("%d %u %u\n", h.ef_type, h.seqno, h.generation);
    dump(&h, sizeof h);
    m.c = 1;
    m.a = 5;
    m.b = 31;
    m.s = -2;
    m.w = 0xfffff;
    m.z = 3;
    printf("%u %u %u %d\n", m.a, m.b, m.w, m.z);
    dump(&m, sizeof m);
    printf("%d %u %u %d\n", tab[1].ef_type, tab[1].seqno, tab[1].generation, tab[1].uid);
    struct hdr* p = &tab[0];
    p->generation = p->seqno + 1;
    printf("%u %d\n", p->generation, p->ef_type == 1);
    if (p->ef_type != 1 || tab[1].ef_type >= 0)
        printf("bad\n");
    dump(tab, sizeof tab);
    return 0;
    }
