#include <stdio.h>
static const char* kind(int c)
    {
    switch (c)
        {
    case 'a':
    case 'e':
    case 'i':
    case 'o':
    case 'u':
        return "vowel";
    case ' ':
        return "space";
    default:
        if (c >= '0' && c <= '9')
            return "digit";
        switch (c)
            {
        case 'x':
        case 'y':
        case 'z':
            return "late";
            }
        return "other";
        }
    }
int main(void)
    {
    const char* s = "a1 xq9";
    int i, vowels = 0, digits = 0, n = 0;
    for (i = 0; s[i]; i++)
        {
        switch (s[i])
            {
        case 'a':
            vowels++; /* fall through */
        case '1':
        case '9':
            digits++;
            if (s[i] == '9')
                continue;
            n += 10;
            break;
        case ' ':
            continue;
        default:
            n++;
            }
        n += 100;
        printf("%s ", kind(s[i]));
        }
    printf("\n%d %d %d\n", vowels, digits, n);
    int k = 3, total = 0;
    while (k-- > 0)
        {
        switch (k)
            {
        case 0:
            total += 1;
            break;
        case 1:
            {
            int j;
            for (j = 0; j < 4; j++)
                total += j;
            }
            break;
        default:
            total += 100;
            }
        }
    printf("%d\n", total);
    return 0;
    }
