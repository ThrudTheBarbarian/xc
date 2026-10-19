/* structs: arrays of structs on the GPU. A struct of one number type is an
   array of that number to a kernel (vec3 here); one that mixes types (body)
   keeps its loops on the CPU. Values exact in float. */
#include <stdio.h>
#define N 65536
struct vec3 { float x, y, z; };
struct body { int id; float m; };
struct vec3 pos[N], vel[N];
struct body bs[N];
int main(void)
{
    for (int i = 0; i < N; i++) {
        pos[i].x = (float)(i % 100); pos[i].y = (float)(i % 37); pos[i].z = 0.5f * (float)(i % 9);
        vel[i].x = 1.0f; vel[i].y = -0.5f; vel[i].z = 0.25f;
        bs[i].id = i; bs[i].m = (float)(i % 4);
    }
    for (int t = 0; t < 8; t++)
        for (int i = 0; i < N; i++) {
            pos[i].x += vel[i].x;
            pos[i].y += vel[i].y;
            pos[i].z += vel[i].z * 2.0f;
        }
    float sx = 0.0f, sy = 0.0f, sz = 0.0f;
    for (int i = 0; i < N; i++) { sx += pos[i].x; sy += pos[i].y; sz += pos[i].z; }
    int ids = 0;
    for (int i = 0; i < N; i++)
        if (bs[i].m > 2.0f)
            ids += bs[i].id & 7;
    printf("%.1f %.1f %.1f %d\n", sx, sy, sz, ids);
    return 0;
}
