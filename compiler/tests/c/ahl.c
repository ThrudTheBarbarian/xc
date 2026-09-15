#include <math.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/time.h>

int main(int argc, char** argv)
    {
    srandom(1);
    uint16_t reps = 10000;

    float r = 0.0f;
    float s = 0.0f;
    struct timeval stt, end, dt;

    printf("Begin\n");
    gettimeofday(&stt, NULL);

    for (uint16_t rep = 0; rep < reps; rep++)
        for (uint8_t n = 1; n <= 100; n++)
            {
            float a = n;
            for (uint8_t i = 1; i <= 10; i++)
                {
                a = sqrtf(a);
                r += random() / (RAND_MAX + 1.0f);
                }

            for (uint8_t i = 1; i <= 10; i++)
                {
                a = powf(a, 2);
                r += random() / (RAND_MAX + 1.0f);
                }
            s += a;
            }

    gettimeofday(&end, NULL);
    timersub(&end, &stt, &dt);

    printf("Accuracy   %f\n", 1010.0f - s / 5.0f);
    printf("Random     %f\n", fabs(1000.0f - r));
    printf("Time taken %ld.%06d\n", dt.tv_sec, dt.tv_usec);
    }
