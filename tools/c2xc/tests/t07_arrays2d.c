#include <stdio.h>
int grid[3][4];
static int rows[2][3] = {{1, 2, 3}, {4, 5, 6}};
int rowsum(int* r, int n)
    {
    int s = 0, i;
    for (i = 0; i < n; i++)
        s += r[i];
    return s;
    }
int main(void)
    {
    int i, j;
    for (i = 0; i < 3; i++)
        for (j = 0; j < 4; j++)
            grid[i][j] = i * 10 + j;
    printf("%d %d %d\n", grid[2][3], rowsum(grid[1], 4), rowsum(rows[1], 3));
    char names[3][8] = {"ab", "cd", "ef"};
    printf("%s %c\n", names[1], names[2][1]);
    return 0;
    }
