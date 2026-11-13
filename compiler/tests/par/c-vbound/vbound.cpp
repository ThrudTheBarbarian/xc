// Loops bounded by a std::vector's size while storing into it: clang reloads
// the vector's begin and end each pass (a byte store may reach them), and
// xcc reads them once at the call site, guarded. A gather beside it, and a
// sum read back from the stored elements.
#include <cstdio>
#include <vector>
static void fill(std::vector<unsigned char>& img)
    {
    for (size_t i = 0; i < img.size(); i++)
        img[i] = (unsigned char)(i * 7 + (i >> 9));
    }
static void look(const std::vector<unsigned>& t, std::vector<unsigned char>& img)
    {
    const unsigned* p = t.data();
    for (size_t i = 0; i < img.size(); i++)
        img[i] = (unsigned char)(p[(i * 13) & 511] + i);
    }
static unsigned both(std::vector<unsigned char>& img)
    {
    unsigned s = 0;
    for (size_t i = 0; i < img.size(); i++)
        {
        img[i] = (unsigned char)(img[i] ^ 0x5a);
        s += img[i];
        }
    return s;
    }
int main()
    {
    std::vector<unsigned char> img(1 << 20);
    std::vector<unsigned> t(512);
    for (int i = 0; i < 512; i++)
        t[i] = i * 31;
    fill(img);
    unsigned s = 0;
    for (auto c : img)
        s += c;
    look(t, img);
    unsigned s2 = 0;
    for (auto c : img)
        s2 += c;
    unsigned s3 = both(img);
    std::printf("%u %u %u\n", s, s2, s3);
    return 0;
    }
