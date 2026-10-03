// UXMovie.xc — frames in, a WebM movie out: a VP8 encoder and a Matroska writer, in xc.
//
//     UXMovie* m = UXMovie.make(1280, 832, 25);
//     m.add(img);              // one frame, one tick (1/25 s)
//     m.addHeld(img, 5);       // one frame shown for five ticks
//     UXData* webm = m.finish();
//
// Like UXPng and UXJpeg it is arithmetic, so it is neutral: the same code on every backend, with no
// codec of the platform's behind it.  The file is what a browser's MediaRecorder makes and what VLC
// and every browser play.  (QuickTime does not play WebM.)
//
// WHAT IT WRITES.  Every frame is a VP8 key frame: intra-coded, one partition of tokens, no loop
// filter, the default probabilities (none updated).  Each macroblock takes the best of the four
// whole-block predictions (DC, vertical, horizontal, TrueMotion) for luma and for chroma.  That is
// VP8 at its simplest: larger than an encoder with inter frames would make, but every frame stands
// alone, so a movie of a UI (sharp edges, flat colour) stays sharp and seeks anywhere.  A frame
// added again unchanged is not encoded again: the previous one is held longer.
//
// IT KNOWS WHAT THE DECODER WILL SEE.  The encoder reconstructs each block exactly as a VP8 decoder
// does (the same inverse transforms, the same edge rules) and predicts from that, so nothing drifts;
// reconstruction() hands the last frame back as the decoder will show it, and test_movie checks it
// against ffmpeg's decode byte for byte.
//
// Colour is BT.601, limited range, chroma 4:2:0, which is what a VP8 player assumes.
#import "UXImage.xc"
#import "UXData.xc"

// The coefficient probabilities a key frame starts from (RFC 6386 section 13.5), [type 4][band 8]
// [context 3][node 11], flattened.
u8 gVp8CoefProbs[1056] = {
    128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
    128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
    128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
    253, 136, 254, 255, 228, 219, 128, 128, 128, 128, 128,
    189, 129, 242, 255, 227, 213, 255, 219, 128, 128, 128,
    106, 126, 227, 252, 214, 209, 255, 255, 128, 128, 128,
    1, 98, 248, 255, 236, 226, 255, 255, 128, 128, 128,
    181, 133, 238, 254, 221, 234, 255, 154, 128, 128, 128,
    78, 134, 202, 247, 198, 180, 255, 219, 128, 128, 128,
    1, 185, 249, 255, 243, 255, 128, 128, 128, 128, 128,
    184, 150, 247, 255, 236, 224, 128, 128, 128, 128, 128,
    77, 110, 216, 255, 236, 230, 128, 128, 128, 128, 128,
    1, 101, 251, 255, 241, 255, 128, 128, 128, 128, 128,
    170, 139, 241, 252, 236, 209, 255, 255, 128, 128, 128,
    37, 116, 196, 243, 228, 255, 255, 255, 128, 128, 128,
    1, 204, 254, 255, 245, 255, 128, 128, 128, 128, 128,
    207, 160, 250, 255, 238, 128, 128, 128, 128, 128, 128,
    102, 103, 231, 255, 211, 171, 128, 128, 128, 128, 128,
    1, 152, 252, 255, 240, 255, 128, 128, 128, 128, 128,
    177, 135, 243, 255, 234, 225, 128, 128, 128, 128, 128,
    80, 129, 211, 255, 194, 224, 128, 128, 128, 128, 128,
    1, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128,
    246, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128,
    255, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
    198, 35, 237, 223, 193, 187, 162, 160, 145, 155, 62,
    131, 45, 198, 221, 172, 176, 220, 157, 252, 221, 1,
    68, 47, 146, 208, 149, 167, 221, 162, 255, 223, 128,
    1, 149, 241, 255, 221, 224, 255, 255, 128, 128, 128,
    184, 141, 234, 253, 222, 220, 255, 199, 128, 128, 128,
    81, 99, 181, 242, 176, 190, 249, 202, 255, 255, 128,
    1, 129, 232, 253, 214, 197, 242, 196, 255, 255, 128,
    99, 121, 210, 250, 201, 198, 255, 202, 128, 128, 128,
    23, 91, 163, 242, 170, 187, 247, 210, 255, 255, 128,
    1, 200, 246, 255, 234, 255, 128, 128, 128, 128, 128,
    109, 178, 241, 255, 231, 245, 255, 255, 128, 128, 128,
    44, 130, 201, 253, 205, 192, 255, 255, 128, 128, 128,
    1, 132, 239, 251, 219, 209, 255, 165, 128, 128, 128,
    94, 136, 225, 251, 218, 190, 255, 255, 128, 128, 128,
    22, 100, 174, 245, 186, 161, 255, 199, 128, 128, 128,
    1, 182, 249, 255, 232, 235, 128, 128, 128, 128, 128,
    124, 143, 241, 255, 227, 234, 128, 128, 128, 128, 128,
    35, 77, 181, 251, 193, 211, 255, 205, 128, 128, 128,
    1, 157, 247, 255, 236, 231, 255, 255, 128, 128, 128,
    121, 141, 235, 255, 225, 227, 255, 255, 128, 128, 128,
    45, 99, 188, 251, 195, 217, 255, 224, 128, 128, 128,
    1, 1, 251, 255, 213, 255, 128, 128, 128, 128, 128,
    203, 1, 248, 255, 255, 128, 128, 128, 128, 128, 128,
    137, 1, 177, 255, 224, 255, 128, 128, 128, 128, 128,
    253, 9, 248, 251, 207, 208, 255, 192, 128, 128, 128,
    175, 13, 224, 243, 193, 185, 249, 198, 255, 255, 128,
    73, 17, 171, 221, 161, 179, 236, 167, 255, 234, 128,
    1, 95, 247, 253, 212, 183, 255, 255, 128, 128, 128,
    239, 90, 244, 250, 211, 209, 255, 255, 128, 128, 128,
    155, 77, 195, 248, 188, 195, 255, 255, 128, 128, 128,
    1, 24, 239, 251, 218, 219, 255, 205, 128, 128, 128,
    201, 51, 219, 255, 196, 186, 128, 128, 128, 128, 128,
    69, 46, 190, 239, 201, 218, 255, 228, 128, 128, 128,
    1, 191, 251, 255, 255, 128, 128, 128, 128, 128, 128,
    223, 165, 249, 255, 213, 255, 128, 128, 128, 128, 128,
    141, 124, 248, 255, 255, 128, 128, 128, 128, 128, 128,
    1, 16, 248, 255, 255, 128, 128, 128, 128, 128, 128,
    190, 36, 230, 255, 236, 255, 128, 128, 128, 128, 128,
    149, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128,
    1, 226, 255, 128, 128, 128, 128, 128, 128, 128, 128,
    247, 192, 255, 128, 128, 128, 128, 128, 128, 128, 128,
    240, 128, 255, 128, 128, 128, 128, 128, 128, 128, 128,
    1, 134, 252, 255, 255, 128, 128, 128, 128, 128, 128,
    213, 62, 250, 255, 255, 128, 128, 128, 128, 128, 128,
    55, 93, 255, 128, 128, 128, 128, 128, 128, 128, 128,
    128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
    128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
    128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128,
    202, 24, 213, 235, 186, 191, 220, 160, 240, 175, 255,
    126, 38, 182, 232, 169, 184, 228, 174, 255, 187, 128,
    61, 46, 138, 219, 151, 178, 240, 170, 255, 216, 128,
    1, 112, 230, 250, 199, 191, 247, 159, 255, 255, 128,
    166, 109, 228, 252, 211, 215, 255, 174, 128, 128, 128,
    39, 77, 162, 232, 172, 180, 245, 178, 255, 255, 128,
    1, 52, 220, 246, 198, 199, 249, 220, 255, 255, 128,
    124, 74, 191, 243, 183, 193, 250, 221, 255, 255, 128,
    24, 71, 130, 219, 154, 170, 243, 182, 255, 255, 128,
    1, 182, 225, 249, 219, 240, 255, 224, 128, 128, 128,
    149, 150, 226, 252, 216, 205, 255, 171, 128, 128, 128,
    28, 108, 170, 242, 183, 194, 254, 223, 255, 255, 128,
    1, 81, 230, 252, 204, 203, 255, 192, 128, 128, 128,
    123, 102, 209, 247, 188, 196, 255, 233, 128, 128, 128,
    20, 95, 153, 243, 164, 173, 255, 203, 128, 128, 128,
    1, 222, 248, 255, 216, 213, 128, 128, 128, 128, 128,
    168, 175, 246, 252, 235, 205, 255, 255, 128, 128, 128,
    47, 116, 215, 255, 211, 212, 255, 255, 128, 128, 128,
    1, 121, 236, 253, 212, 214, 255, 255, 128, 128, 128,
    141, 84, 213, 252, 201, 202, 255, 219, 128, 128, 128,
    42, 80, 160, 240, 162, 185, 255, 205, 128, 128, 128,
    1, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128,
    244, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128,
    238, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128};
// The probability that each of those is updated (RFC 6386 section 13.4): the encoder updates none,
// but writes each "no" with its own probability.
u8 gVp8UpdateProbs[1056] = {
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    176, 246, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    223, 241, 252, 255, 255, 255, 255, 255, 255, 255, 255,
    249, 253, 253, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 244, 252, 255, 255, 255, 255, 255, 255, 255, 255,
    234, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    253, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 246, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    239, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    254, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 248, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    251, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    251, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    254, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 254, 253, 255, 254, 255, 255, 255, 255, 255, 255,
    250, 255, 254, 255, 254, 255, 255, 255, 255, 255, 255,
    254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    217, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    225, 252, 241, 253, 255, 255, 254, 255, 255, 255, 255,
    234, 250, 241, 250, 253, 255, 253, 254, 255, 255, 255,
    255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    223, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    238, 253, 254, 254, 255, 255, 255, 255, 255, 255, 255,
    255, 248, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    249, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 253, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    247, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    252, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    253, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 254, 253, 255, 255, 255, 255, 255, 255, 255, 255,
    250, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    186, 251, 250, 255, 255, 255, 255, 255, 255, 255, 255,
    234, 251, 244, 254, 255, 255, 255, 255, 255, 255, 255,
    251, 251, 243, 253, 254, 255, 254, 255, 255, 255, 255,
    255, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    236, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    251, 253, 253, 254, 254, 255, 255, 255, 255, 255, 255,
    255, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    254, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    254, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    248, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    250, 254, 252, 254, 255, 255, 255, 255, 255, 255, 255,
    248, 254, 249, 253, 255, 255, 255, 255, 255, 255, 255,
    255, 253, 253, 255, 255, 255, 255, 255, 255, 255, 255,
    246, 253, 253, 255, 255, 255, 255, 255, 255, 255, 255,
    252, 254, 251, 254, 254, 255, 255, 255, 255, 255, 255,
    255, 254, 252, 255, 255, 255, 255, 255, 255, 255, 255,
    248, 254, 253, 255, 255, 255, 255, 255, 255, 255, 255,
    253, 255, 254, 254, 255, 255, 255, 255, 255, 255, 255,
    255, 251, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    245, 251, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    253, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 251, 253, 255, 255, 255, 255, 255, 255, 255, 255,
    252, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 252, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    249, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 253, 255, 255, 255, 255, 255, 255, 255, 255,
    250, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255};
// The quantizer step for each index, DC and AC (RFC 6386 section 14.1).
i32 gVp8DcQ[128] = {
    4, 5, 6, 7, 8, 9, 10, 10, 11, 12, 13, 14, 15, 16, 17, 17,
    18, 19, 20, 20, 21, 21, 22, 22, 23, 23, 24, 25, 25, 26, 27, 28,
    29, 30, 31, 32, 33, 34, 35, 36, 37, 37, 38, 39, 40, 41, 42, 43,
    44, 45, 46, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58,
    59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74,
    75, 76, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89,
    91, 93, 95, 96, 98, 100, 101, 102, 104, 106, 108, 110, 112, 114, 116, 118,
    122, 124, 126, 128, 130, 132, 134, 136, 138, 140, 143, 145, 148, 151, 154, 157};
i32 gVp8AcQ[128] = {
    4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
    20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35,
    36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51,
    52, 53, 54, 55, 56, 57, 58, 60, 62, 64, 66, 68, 70, 72, 74, 76,
    78, 80, 82, 84, 86, 88, 90, 92, 94, 96, 98, 100, 102, 104, 106, 108,
    110, 112, 114, 116, 119, 122, 125, 128, 131, 134, 137, 140, 143, 146, 149, 152,
    155, 158, 161, 164, 167, 170, 173, 177, 181, 185, 189, 193, 197, 201, 205, 209,
    213, 217, 221, 225, 229, 234, 239, 245, 249, 254, 259, 264, 269, 274, 279, 284};

// Coefficient scan order (zig-zag to raster), and the band each scan position's probabilities are in.
i32 gVp8Zigzag[16] = {0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15};
i32 gVp8Band[17] = {0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 0};
// The extra bits of the large-value token categories (RFC 6386 section 13.2), most significant first.
u8 gVp8Cat3[3] = {173, 148, 140};
u8 gVp8Cat4[4] = {176, 155, 140, 135};
u8 gVp8Cat5[5] = {180, 157, 141, 134, 130};
u8 gVp8Cat6[11] = {254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129};

// The prediction modes a macroblock can take (whole-block ones only; never B_PRED).
#define VP8_DC 0
#define VP8_V 1
#define VP8_H 2
#define VP8_TM 3

// VP8's boolean entropy coder (RFC 6386 section 7.3): each bit is coded with the probability, out of
// 256, that it is 0.
class UXVp8Bits
    {
    u8* buf;
    i32 len;
    i32 cap;
    u32 range;
    u32 bottom;
    i32 count;
    void init(void)
        {
        cap = (i32)65536;
        buf = new u8[(u32)cap];
        len = (i32)0;
        range = (u32)255;
        bottom = (u32)0;
        count = (i32)24;
        }
    void put(u8 b)
        {
        if (len == cap)
            {
            u8* nb = new u8[(u32)(cap * (i32)2)];
            for (i32 i = (i32)0; i < len; i = i + (i32)1)
                {
                nb[i] = buf[i];
                }
            buf = nb;
            cap = cap * (i32)2;
            }
        buf[len] = b;
        len = len + (i32)1;
        }
    // a carry out of bottom: add one to what is already written
    void carry(void)
        {
        i32 i = len - (i32)1;
        while (i >= (i32)0 && buf[i] == (u8)255)
            {
            buf[i] = (u8)0;
            i = i - (i32)1;
            }
        if (i >= (i32)0)
            {
            buf[i] = buf[i] + (u8)1;
            }
        }
    void bit(i32 prob, bool v)
        {
        u32 split = (u32)1 + (((range - (u32)1) * (u32)prob) >> (u32)8);
        if (v)
            {
            bottom = bottom + split;
            range = range - split;
            }
        else
            {
            range = split;
            }
        while (range < (u32)128)
            {
            range = range << (u32)1;
            if ((bottom & (u32)$80000000) != (u32)0)
                {
                self.carry();
                }
            bottom = bottom << (u32)1;
            count = count - (i32)1;
            if (count == (i32)0)
                {
                self.put((u8)(bottom >> (u32)24));
                bottom = bottom & (u32)$00FFFFFF;
                count = (i32)8;
                }
            }
        }
    // an n-bit unsigned value, most significant bit first, each at even odds
    void literal(i32 v, i32 n)
        {
        for (i32 i = n - (i32)1; i >= (i32)0; i = i - (i32)1)
            {
            self.bit((i32)128, ((v >> i) & (i32)1) != (i32)0);
            }
        }
    void flush(void)
        {
        i32 c = count;
        u32 v = bottom;
        if ((v & ((u32)1 << (u32)((i32)32 - c))) != (u32)0)
            {
            self.carry();
            }
        v = v << (u32)(c & (i32)7);
        c = c >> (i32)3;
        c = c - (i32)1;
        while (c >= (i32)0)
            {
            v = v << (u32)8;
            c = c - (i32)1;
            }
        for (i32 k = (i32)0; k < (i32)4; k = k + (i32)1)
            {
            self.put((u8)(v >> (u32)24));
            v = v << (u32)8;
            }
        }
    }

i32 vp8Clamp(i32 v)
    {
    return v < (i32)0 ? (i32)0 : (v > (i32)255 ? (i32)255 : v);
    }
i32 vp8Abs(i32 v)
    {
    return v < (i32)0 ? (i32)0 - v : v;
    }
// a coefficient to its quantized level, rounded to the nearest
i32 vp8Quant(i32 c, i32 q)
    {
    i32 v = (vp8Abs(c) + (q >> (i32)1)) / q;
    if (v > (i32)2114)
        {
        v = (i32)2114; // the largest level a token can carry (DCT_CAT6: 67 + 2047)
        }
    return c < (i32)0 ? (i32)0 - v : v;
    }

// The forward transforms (libvpx's): 4x4 DCT of a residual, and the Walsh-Hadamard transform of the
// sixteen luma DCs.  Any good forward transform would do; the decoder only sees the levels.
void vp8Fdct(i32* ip, i32* op)
    {
    i32 t[16];
    for (i32 i = (i32)0; i < (i32)4; i = i + (i32)1)
        {
        i32* r = ip + (i64)(i * (i32)4);
        i32 a1 = (r[0] + r[3]) * (i32)8;
        i32 b1 = (r[1] + r[2]) * (i32)8;
        i32 c1 = (r[1] - r[2]) * (i32)8;
        i32 d1 = (r[0] - r[3]) * (i32)8;
        t[i * (i32)4] = a1 + b1;
        t[i * (i32)4 + (i32)2] = a1 - b1;
        t[i * (i32)4 + (i32)1] = (c1 * (i32)2217 + d1 * (i32)5352 + (i32)14500) >> (i32)12;
        t[i * (i32)4 + (i32)3] = (d1 * (i32)2217 - c1 * (i32)5352 + (i32)7500) >> (i32)12;
        }
    for (i32 i = (i32)0; i < (i32)4; i = i + (i32)1)
        {
        i32 a1 = t[i] + t[(i32)12 + i];
        i32 b1 = t[(i32)4 + i] + t[(i32)8 + i];
        i32 c1 = t[(i32)4 + i] - t[(i32)8 + i];
        i32 d1 = t[i] - t[(i32)12 + i];
        op[i] = (a1 + b1 + (i32)7) >> (i32)4;
        op[(i32)8 + i] = (a1 - b1 + (i32)7) >> (i32)4;
        op[(i32)4 + i] = ((c1 * (i32)2217 + d1 * (i32)5352 + (i32)12000) >> (i32)16) + (d1 != (i32)0 ? (i32)1 : (i32)0);
        op[(i32)12 + i] = (d1 * (i32)2217 - c1 * (i32)5352 + (i32)51000) >> (i32)16;
        }
    }
void vp8Fwht(i32* ip, i32* op)
    {
    i32 t[16];
    for (i32 i = (i32)0; i < (i32)4; i = i + (i32)1)
        {
        i32* r = ip + (i64)(i * (i32)4);
        i32 a1 = (r[0] + r[2]) * (i32)4;
        i32 d1 = (r[1] + r[3]) * (i32)4;
        i32 c1 = (r[1] - r[3]) * (i32)4;
        i32 b1 = (r[0] - r[2]) * (i32)4;
        t[i * (i32)4] = a1 + d1 + (a1 != (i32)0 ? (i32)1 : (i32)0);
        t[i * (i32)4 + (i32)1] = b1 + c1;
        t[i * (i32)4 + (i32)2] = b1 - c1;
        t[i * (i32)4 + (i32)3] = a1 - d1;
        }
    for (i32 i = (i32)0; i < (i32)4; i = i + (i32)1)
        {
        i32 a1 = t[i] + t[(i32)8 + i];
        i32 d1 = t[(i32)4 + i] + t[(i32)12 + i];
        i32 c1 = t[(i32)4 + i] - t[(i32)12 + i];
        i32 b1 = t[i] - t[(i32)8 + i];
        i32 a2 = a1 + d1;
        i32 b2 = b1 + c1;
        i32 c2 = b1 - c1;
        i32 d2 = a1 - d1;
        a2 = a2 + (a2 < (i32)0 ? (i32)1 : (i32)0);
        b2 = b2 + (b2 < (i32)0 ? (i32)1 : (i32)0);
        c2 = c2 + (c2 < (i32)0 ? (i32)1 : (i32)0);
        d2 = d2 + (d2 < (i32)0 ? (i32)1 : (i32)0);
        op[i] = (a2 + (i32)3) >> (i32)3;
        op[(i32)4 + i] = (b2 + (i32)3) >> (i32)3;
        op[(i32)8 + i] = (c2 + (i32)3) >> (i32)3;
        op[(i32)12 + i] = (d2 + (i32)3) >> (i32)3;
        }
    }
// The decoder's inverse transforms (RFC 6386 section 14.3 and 14.4), exactly: the encoder predicts
// from what these give, as the decoder will.
void vp8Iwht(i32* ip, i32* op)
    {
    i32 t[16];
    for (i32 i = (i32)0; i < (i32)4; i = i + (i32)1)
        {
        i32 a1 = ip[i] + ip[(i32)12 + i];
        i32 b1 = ip[(i32)4 + i] + ip[(i32)8 + i];
        i32 c1 = ip[(i32)4 + i] - ip[(i32)8 + i];
        i32 d1 = ip[i] - ip[(i32)12 + i];
        t[i] = a1 + b1;
        t[(i32)4 + i] = c1 + d1;
        t[(i32)8 + i] = a1 - b1;
        t[(i32)12 + i] = d1 - c1;
        }
    for (i32 i = (i32)0; i < (i32)4; i = i + (i32)1)
        {
        i32 k = i * (i32)4;
        i32 a1 = t[k] + t[k + (i32)3];
        i32 b1 = t[k + (i32)1] + t[k + (i32)2];
        i32 c1 = t[k + (i32)1] - t[k + (i32)2];
        i32 d1 = t[k] - t[k + (i32)3];
        op[k] = (a1 + b1 + (i32)3) >> (i32)3;
        op[k + (i32)1] = (c1 + d1 + (i32)3) >> (i32)3;
        op[k + (i32)2] = (a1 - b1 + (i32)3) >> (i32)3;
        op[k + (i32)3] = (d1 - c1 + (i32)3) >> (i32)3;
        }
    }
i32 vp8MulSin(i32 x)
    {
    return (x * (i32)35468) >> (i32)16;
    }
i32 vp8MulCos(i32 x)
    {
    return x + ((x * (i32)20091) >> (i32)16);
    }
// inverse DCT of dequantized coefficients, added to the prediction in place (a 4x4 at p, row pitch)
void vp8IdctAdd(i32* ip, u8* p, i32 pitch)
    {
    i32 t[16];
    for (i32 i = (i32)0; i < (i32)4; i = i + (i32)1)
        {
        i32 a1 = ip[i] + ip[(i32)8 + i];
        i32 b1 = ip[i] - ip[(i32)8 + i];
        i32 c1 = vp8MulSin(ip[(i32)4 + i]) - vp8MulCos(ip[(i32)12 + i]);
        i32 d1 = vp8MulCos(ip[(i32)4 + i]) + vp8MulSin(ip[(i32)12 + i]);
        t[i] = a1 + d1;
        t[(i32)12 + i] = a1 - d1;
        t[(i32)4 + i] = b1 + c1;
        t[(i32)8 + i] = b1 - c1;
        }
    for (i32 i = (i32)0; i < (i32)4; i = i + (i32)1)
        {
        i32 k = i * (i32)4;
        i32 a1 = t[k] + t[k + (i32)2];
        i32 b1 = t[k] - t[k + (i32)2];
        i32 c1 = vp8MulSin(t[k + (i32)1]) - vp8MulCos(t[k + (i32)3]);
        i32 d1 = vp8MulCos(t[k + (i32)1]) + vp8MulSin(t[k + (i32)3]);
        u8* row = p + (i64)(i * pitch);
        row[0] = (u8)vp8Clamp((i32)row[0] + ((a1 + d1 + (i32)4) >> (i32)3));
        row[3] = (u8)vp8Clamp((i32)row[3] + ((a1 - d1 + (i32)4) >> (i32)3));
        row[1] = (u8)vp8Clamp((i32)row[1] + ((b1 + c1 + (i32)4) >> (i32)3));
        row[2] = (u8)vp8Clamp((i32)row[2] + ((b1 - c1 + (i32)4) >> (i32)3));
        }
    }

// One plane's whole-block prediction, for a block of n x n at (x, y) in a reconstructed plane of the
// given pitch: the four modes, with VP8's edge rules (above the frame is 127, left of it 129; DC uses
// only the edges that exist).  TrueMotion is not offered at the left edge below the top row, where
// decoders differ on the corner pixel.
class UXVp8Pred
    {
    i32 above[16];
    i32 left[16];
    i32 corner;
    bool hasAbove;
    bool hasLeft;
    void edges(u8* plane, i32 pitch, i32 x, i32 y, i32 n)
        {
        hasAbove = y > (i32)0;
        hasLeft = x > (i32)0;
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            above[i] = hasAbove ? (i32)plane[(y - (i32)1) * pitch + x + i] : (i32)127;
            left[i] = hasLeft ? (i32)plane[(y + i) * pitch + x - (i32)1] : (i32)129;
            }
        if (!hasAbove)
            {
            corner = (i32)127;
            }
        else if (!hasLeft)
            {
            corner = (i32)129;
            }
        else
            {
            corner = (i32)plane[(y - (i32)1) * pitch + x - (i32)1];
            }
        }
    bool offers(i32 mode)
        {
        return mode != (i32)VP8_TM || hasAbove == false || hasLeft;
        }
    void predict(i32 mode, i32 n, u8* out)
        {
        if (mode == (i32)VP8_DC)
            {
            i32 sum = (i32)0;
            i32 shift = (i32)0;
            i32 lg = n == (i32)16 ? (i32)3 : (i32)2;
            if (hasAbove)
                {
                for (i32 i = (i32)0; i < n; i = i + (i32)1)
                    {
                    sum = sum + above[i];
                    }
                shift = shift + (i32)1;
                }
            if (hasLeft)
                {
                for (i32 i = (i32)0; i < n; i = i + (i32)1)
                    {
                    sum = sum + left[i];
                    }
                shift = shift + (i32)1;
                }
            i32 dc = (i32)128;
            if (shift > (i32)0)
                {
                shift = shift + lg;
                dc = (sum + ((i32)1 << (shift - (i32)1))) >> shift;
                }
            for (i32 i = (i32)0; i < n * n; i = i + (i32)1)
                {
                out[i] = (u8)dc;
                }
            return;
            }
        for (i32 r = (i32)0; r < n; r = r + (i32)1)
            {
            for (i32 c = (i32)0; c < n; c = c + (i32)1)
                {
                i32 v = (i32)0;
                if (mode == (i32)VP8_V)
                    {
                    v = above[c];
                    }
                else if (mode == (i32)VP8_H)
                    {
                    v = left[r];
                    }
                else
                    {
                    v = vp8Clamp(left[r] + above[c] - corner);
                    }
                out[r * n + c] = (u8)v;
                }
            }
        }
    }

// The VP8 key-frame encoder for one frame size.
class UXVp8Encoder
    {
    i32 w;
    i32 h;
    i32 mbw;
    i32 mbh;
    i32 yp; // luma pitch (mbw * 16), chroma pitch is half
    i32 cp;
    u8* srcY;
    u8* srcU;
    u8* srcV;
    u8* recY;
    u8* recU;
    u8* recV;
    i32 y1dc;
    i32 y1ac;
    i32 y2dc;
    i32 y2ac;
    i32 uvdc;
    i32 uvac;
    i32 qi;
    // which 4x4 blocks above and to the left had a non-zero coefficient (the token context)
    i32* aboveY;
    i32* aboveU;
    i32* aboveV;
    i32* aboveY2;
    i32 leftY[4];
    i32 leftU[2];
    i32 leftV[2];
    i32 leftY2;
    UXVp8Pred* pred;
    u8 predY[256];
    u8 predU[64];
    u8 predV[64];
    u8 tryBuf[256];
    i32 coef[400]; // 25 blocks of 16 levels: Y 0..15, U 16..19, V 20..23, Y2 24
    i32 dct[256];

    static UXVp8Encoder* make(i32 width, i32 height, i32 quantizer)
        {
        UXVp8Encoder* e = new UXVp8Encoder();
        e.w = width;
        e.h = height;
        e.mbw = (width + (i32)15) / (i32)16;
        e.mbh = (height + (i32)15) / (i32)16;
        e.yp = e.mbw * (i32)16;
        e.cp = e.mbw * (i32)8;
        i32 ny = e.yp * e.mbh * (i32)16;
        i32 nc = e.cp * e.mbh * (i32)8;
        e.srcY = new u8[(u32)ny];
        e.srcU = new u8[(u32)nc];
        e.srcV = new u8[(u32)nc];
        e.recY = new u8[(u32)ny];
        e.recU = new u8[(u32)nc];
        e.recV = new u8[(u32)nc];
        e.aboveY = new i32[(u32)(e.mbw * (i32)4)];
        e.aboveU = new i32[(u32)(e.mbw * (i32)2)];
        e.aboveV = new i32[(u32)(e.mbw * (i32)2)];
        e.aboveY2 = new i32[(u32)e.mbw];
        e.pred = new UXVp8Pred();
        e.setQuantizer(quantizer);
        return e;
        }
    // 0 (finest) .. 127 (coarsest)
    void setQuantizer(i32 q)
        {
        qi = q < (i32)0 ? (i32)0 : (q > (i32)127 ? (i32)127 : q);
        y1dc = gVp8DcQ[qi];
        y1ac = gVp8AcQ[qi];
        y2dc = gVp8DcQ[qi] * (i32)2;
        y2ac = gVp8AcQ[qi] * (i32)155 / (i32)100;
        if (y2ac < (i32)8)
            {
            y2ac = (i32)8;
            }
        uvdc = gVp8DcQ[qi] > (i32)132 ? (i32)132 : gVp8DcQ[qi];
        uvac = gVp8AcQ[qi];
        }

    // 0xAARRGGBB pixels (pitch in pixels) to the padded YUV planes, the edge pixels repeated
    void convert(u32* px, i32 pitch)
        {
        i32 ph = mbh * (i32)16;
        for (i32 y = (i32)0; y < ph; y = y + (i32)1)
            {
            i32 sy = y < h ? y : h - (i32)1;
            for (i32 x = (i32)0; x < yp; x = x + (i32)1)
                {
                i32 sx = x < w ? x : w - (i32)1;
                u32 v = px[sy * pitch + sx];
                i32 r = (i32)((v >> (u32)16) & (u32)255);
                i32 g = (i32)((v >> (u32)8) & (u32)255);
                i32 b = (i32)(v & (u32)255);
                srcY[y * yp + x] = (u8)(((((i32)66 * r + (i32)129 * g + (i32)25 * b + (i32)128) >> (i32)8)) + (i32)16);
                }
            }
        for (i32 y = (i32)0; y < ph / (i32)2; y = y + (i32)1)
            {
            for (i32 x = (i32)0; x < cp; x = x + (i32)1)
                {
                i32 rs = (i32)0;
                i32 gs = (i32)0;
                i32 bs = (i32)0;
                for (i32 k = (i32)0; k < (i32)4; k = k + (i32)1)
                    {
                    i32 sy = y * (i32)2 + (k >> (i32)1);
                    i32 sx = x * (i32)2 + (k & (i32)1);
                    sy = sy < h ? sy : h - (i32)1;
                    sx = sx < w ? sx : w - (i32)1;
                    u32 v = px[sy * pitch + sx];
                    rs = rs + (i32)((v >> (u32)16) & (u32)255);
                    gs = gs + (i32)((v >> (u32)8) & (u32)255);
                    bs = bs + (i32)(v & (u32)255);
                    }
                i32 r = (rs + (i32)2) >> (i32)2;
                i32 g = (gs + (i32)2) >> (i32)2;
                i32 b = (bs + (i32)2) >> (i32)2;
                srcU[y * cp + x] = (u8)vp8Clamp((((i32)0 - (i32)38 * r - (i32)74 * g + (i32)112 * b + (i32)128) >> (i32)8) + (i32)128);
                srcV[y * cp + x] = (u8)vp8Clamp(((((i32)112 * r - (i32)94 * g - (i32)18 * b + (i32)128) >> (i32)8)) + (i32)128);
                }
            }
        }

    // the mode whose prediction is closest to the source block (sum of absolute differences)
    i32 choose(u8* src, i32 pitch, i32 x, i32 y, i32 n, u8* out)
        {
        i32 best = (i32)-1;
        i32 bestSad = (i32)0;
        for (i32 m = (i32)0; m < (i32)4; m = m + (i32)1)
            {
            if (!pred.offers(m))
                {
                continue;
                }
            pred.predict(m, n, &tryBuf[0]);
            i32 sad = (i32)0;
            for (i32 r = (i32)0; r < n; r = r + (i32)1)
                {
                for (i32 c = (i32)0; c < n; c = c + (i32)1)
                    {
                    sad = sad + vp8Abs((i32)src[(y + r) * pitch + x + c] - (i32)tryBuf[r * n + c]);
                    }
                }
            if (best < (i32)0 || sad < bestSad)
                {
                best = m;
                bestSad = sad;
                }
            }
        pred.predict(best, n, out);
        return best;
        }

    // one block's levels as tokens; whether any was non-zero (the next blocks' context)
    i32 tokens(UXVp8Bits* bc, i32 type, i32* q, i32 first, i32 ctx)
        {
        i32 last = (i32)-1;
        for (i32 i = first; i < (i32)16; i = i + (i32)1)
            {
            if (q[gVp8Zigzag[i]] != (i32)0)
                {
                last = i;
                }
            }
        i32 base = type * (i32)264;
        i32 p = base + gVp8Band[first] * (i32)33 + ctx * (i32)11;
        if (last < (i32)0)
            {
            bc.bit((i32)gVp8CoefProbs[p], false); // end of block straight away
            return (i32)0;
            }
        bool afterZero = false;
        for (i32 i = first; i <= last; i = i + (i32)1)
            {
            i32 v = q[gVp8Zigzag[i]];
            i32 a = vp8Abs(v);
            if (!afterZero)
                {
                bc.bit((i32)gVp8CoefProbs[p], true); // not the end
                }
            if (a == (i32)0)
                {
                bc.bit((i32)gVp8CoefProbs[p + (i32)1], false);
                afterZero = true;
                p = base + gVp8Band[i + (i32)1] * (i32)33;
                continue;
                }
            afterZero = false;
            bc.bit((i32)gVp8CoefProbs[p + (i32)1], true);
            i32 nctx = (i32)2;
            if (a == (i32)1)
                {
                bc.bit((i32)gVp8CoefProbs[p + (i32)2], false);
                nctx = (i32)1;
                }
            else
                {
                bc.bit((i32)gVp8CoefProbs[p + (i32)2], true);
                if (a <= (i32)4)
                    {
                    bc.bit((i32)gVp8CoefProbs[p + (i32)3], false);
                    if (a == (i32)2)
                        {
                        bc.bit((i32)gVp8CoefProbs[p + (i32)4], false);
                        }
                    else
                        {
                        bc.bit((i32)gVp8CoefProbs[p + (i32)4], true);
                        bc.bit((i32)gVp8CoefProbs[p + (i32)5], a == (i32)4);
                        }
                    }
                else
                    {
                    bc.bit((i32)gVp8CoefProbs[p + (i32)3], true);
                    if (a <= (i32)10)
                        {
                        bc.bit((i32)gVp8CoefProbs[p + (i32)6], false);
                        if (a <= (i32)6)
                            {
                            bc.bit((i32)gVp8CoefProbs[p + (i32)7], false);
                            bc.bit((i32)159, a == (i32)6); // DCT_CAT1: 5..6
                            }
                        else
                            {
                            bc.bit((i32)gVp8CoefProbs[p + (i32)7], true);
                            bc.bit((i32)165, ((a - (i32)7) & (i32)2) != (i32)0); // DCT_CAT2: 7..10
                            bc.bit((i32)145, ((a - (i32)7) & (i32)1) != (i32)0);
                            }
                        }
                    else
                        {
                        bc.bit((i32)gVp8CoefProbs[p + (i32)6], true);
                        if (a <= (i32)34)
                            {
                            bc.bit((i32)gVp8CoefProbs[p + (i32)8], false);
                            if (a <= (i32)18)
                                {
                                bc.bit((i32)gVp8CoefProbs[p + (i32)9], false);
                                self.extra(bc, &gVp8Cat3[0], (i32)3, a - (i32)11);
                                }
                            else
                                {
                                bc.bit((i32)gVp8CoefProbs[p + (i32)9], true);
                                self.extra(bc, &gVp8Cat4[0], (i32)4, a - (i32)19);
                                }
                            }
                        else
                            {
                            bc.bit((i32)gVp8CoefProbs[p + (i32)8], true);
                            if (a <= (i32)66)
                                {
                                bc.bit((i32)gVp8CoefProbs[p + (i32)10], false);
                                self.extra(bc, &gVp8Cat5[0], (i32)5, a - (i32)35);
                                }
                            else
                                {
                                bc.bit((i32)gVp8CoefProbs[p + (i32)10], true);
                                self.extra(bc, &gVp8Cat6[0], (i32)11, a - (i32)67);
                                }
                            }
                        }
                    }
                }
            bc.bit((i32)128, v < (i32)0);
            p = base + gVp8Band[i + (i32)1] * (i32)33 + nctx * (i32)11;
            }
        if (last < (i32)15)
            {
            bc.bit((i32)gVp8CoefProbs[p], false); // end of block
            }
        return (i32)1;
        }
    void extra(UXVp8Bits* bc, u8* probs, i32 n, i32 v)
        {
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            bc.bit((i32)probs[i], ((v >> (n - (i32)1 - i)) & (i32)1) != (i32)0);
            }
        }

    // the residual of a 4x4 at (x, y) of a source plane against a prediction block (pitch pp)
    void residual(u8* src, i32 pitch, i32 x, i32 y, u8* p, i32 pp, i32* out)
        {
        for (i32 r = (i32)0; r < (i32)4; r = r + (i32)1)
            {
            for (i32 c = (i32)0; c < (i32)4; c = c + (i32)1)
                {
                out[r * (i32)4 + c] = (i32)src[(y + r) * pitch + x + c] - (i32)p[r * pp + c];
                }
            }
        }
    // copy an n x n prediction into the reconstructed plane at (x, y)
    void place(u8* p, i32 n, u8* rec, i32 pitch, i32 x, i32 y)
        {
        for (i32 r = (i32)0; r < n; r = r + (i32)1)
            {
            for (i32 c = (i32)0; c < n; c = c + (i32)1)
                {
                rec[(y + r) * pitch + x + c] = p[r * n + c];
                }
            }
        }

    // a chroma plane of one macroblock: modes are chosen by the caller; tokens and reconstruction here
    void chroma(UXVp8Bits* tok, u8* src, u8* rec, u8* p, i32* above, i32* left, i32 mbx, i32 mby, i32 slot)
        {
        i32 x0 = mbx * (i32)8;
        i32 y0 = mby * (i32)8;
        self.place(p, (i32)8, rec, cp, x0, y0);
        i32 res[16];
        i32 deq[16];
        for (i32 b = (i32)0; b < (i32)4; b = b + (i32)1)
            {
            i32 bx = b & (i32)1;
            i32 by = b >> (i32)1;
            i32* q = &coef[(slot + b) * (i32)16];
            self.residual(src, cp, x0 + bx * (i32)4, y0 + by * (i32)4, p + (i64)(by * (i32)32 + bx * (i32)4), (i32)8, &res[0]);
            vp8Fdct(&res[0], &dct[0]);
            for (i32 i = (i32)0; i < (i32)16; i = i + (i32)1)
                {
                q[i] = vp8Quant(dct[i], i == (i32)0 ? uvdc : uvac);
                deq[i] = q[i] * (i == (i32)0 ? uvdc : uvac);
                }
            i32 nz = self.tokens(tok, (i32)2, q, (i32)0, above[mbx * (i32)2 + bx] + left[by]);
            above[mbx * (i32)2 + bx] = nz;
            left[by] = nz;
            vp8IdctAdd(&deq[0], rec + (i64)((y0 + by * (i32)4) * cp + x0 + bx * (i32)4), cp);
            }
        }

    void macroblock(UXVp8Bits* hdr, UXVp8Bits* tok, i32 mbx, i32 mby)
        {
        i32 x0 = mbx * (i32)16;
        i32 y0 = mby * (i32)16;
        pred.edges(recY, yp, x0, y0, (i32)16);
        i32 ym = self.choose(srcY, yp, x0, y0, (i32)16, &predY[0]);
        pred.edges(recU, cp, mbx * (i32)8, mby * (i32)8, (i32)8);
        i32 cm = self.choose(srcU, cp, mbx * (i32)8, mby * (i32)8, (i32)8, &predU[0]);
        pred.edges(recV, cp, mbx * (i32)8, mby * (i32)8, (i32)8);
        pred.predict(cm, (i32)8, &predV[0]); // one chroma mode for both planes: U's choice

        // the modes (key-frame trees, fixed probabilities)
        hdr.bit((i32)145, true); // not B_PRED
        hdr.bit((i32)156, ym == (i32)VP8_H || ym == (i32)VP8_TM);
        hdr.bit(ym == (i32)VP8_H || ym == (i32)VP8_TM ? (i32)128 : (i32)163, ym == (i32)VP8_V || ym == (i32)VP8_TM);
        hdr.bit((i32)142, cm != (i32)VP8_DC);
        if (cm != (i32)VP8_DC)
            {
            hdr.bit((i32)114, cm != (i32)VP8_V);
            if (cm != (i32)VP8_V)
                {
                hdr.bit((i32)183, cm == (i32)VP8_TM);
                }
            }

        // luma: sixteen DCTs, their DCs through the second-order transform
        i32 res[16];
        for (i32 b = (i32)0; b < (i32)16; b = b + (i32)1)
            {
            i32 bx = b & (i32)3;
            i32 by = b >> (i32)2;
            self.residual(srcY, yp, x0 + bx * (i32)4, y0 + by * (i32)4, &predY[by * (i32)64 + bx * (i32)4], (i32)16, &res[0]);
            vp8Fdct(&res[0], &dct[b * (i32)16]);
            }
        i32 dcs[16];
        i32 y2[16];
        for (i32 b = (i32)0; b < (i32)16; b = b + (i32)1)
            {
            dcs[b] = dct[b * (i32)16];
            }
        vp8Fwht(&dcs[0], &y2[0]);
        i32* q2 = &coef[(i32)24 * (i32)16];
        i32 deq2[16];
        for (i32 i = (i32)0; i < (i32)16; i = i + (i32)1)
            {
            q2[i] = vp8Quant(y2[i], i == (i32)0 ? y2dc : y2ac);
            deq2[i] = q2[i] * (i == (i32)0 ? y2dc : y2ac);
            }
        i32 nz2 = self.tokens(tok, (i32)1, q2, (i32)0, aboveY2[mbx] + leftY2);
        aboveY2[mbx] = nz2;
        leftY2 = nz2;
        vp8Iwht(&deq2[0], &dcs[0]);
        self.place(&predY[0], (i32)16, recY, yp, x0, y0);
        i32 deq[16];
        for (i32 b = (i32)0; b < (i32)16; b = b + (i32)1)
            {
            i32 bx = b & (i32)3;
            i32 by = b >> (i32)2;
            i32* q = &coef[b * (i32)16];
            q[0] = (i32)0;
            deq[0] = dcs[b];
            for (i32 i = (i32)1; i < (i32)16; i = i + (i32)1)
                {
                q[i] = vp8Quant(dct[b * (i32)16 + i], y1ac);
                deq[i] = q[i] * y1ac;
                }
            i32 nz = self.tokens(tok, (i32)0, q, (i32)1, aboveY[mbx * (i32)4 + bx] + leftY[by]);
            aboveY[mbx * (i32)4 + bx] = nz;
            leftY[by] = nz;
            vp8IdctAdd(&deq[0], recY + (i64)((y0 + by * (i32)4) * yp + x0 + bx * (i32)4), yp);
            }

        self.chroma(tok, srcU, recU, &predU[0], aboveU, &leftU[0], mbx, mby, (i32)16);
        self.chroma(tok, srcV, recV, &predV[0], aboveV, &leftV[0], mbx, mby, (i32)20);
        }

    // one frame (0xAARRGGBB, pitch in pixels) as a VP8 key frame
    UXData* encode(u32* px, i32 pitch)
        {
        self.convert(px, pitch);
        UXVp8Bits* hdr = new UXVp8Bits();
        UXVp8Bits* tok = new UXVp8Bits();
        hdr.literal((i32)0, (i32)1); // colour space: YUV
        hdr.literal((i32)0, (i32)1); // clamping required
        hdr.literal((i32)0, (i32)1); // no segmentation
        hdr.literal((i32)0, (i32)1); // normal loop filter...
        hdr.literal((i32)0, (i32)6); // ...at level 0: off
        hdr.literal((i32)0, (i32)3); // sharpness
        hdr.literal((i32)0, (i32)1); // no loop-filter deltas
        hdr.literal((i32)0, (i32)2); // one token partition
        hdr.literal(qi, (i32)7);     // the quantizer index
        hdr.literal((i32)0, (i32)5); // no quantizer deltas (y dc, y2 dc, y2 ac, uv dc, uv ac)
        hdr.literal((i32)1, (i32)1); // refresh entropy probabilities
        for (i32 i = (i32)0; i < (i32)1056; i = i + (i32)1)
            {
            hdr.bit((i32)gVp8UpdateProbs[i], false); // no coefficient probability updated
            }
        hdr.literal((i32)0, (i32)1); // no per-macroblock skip flag
        for (i32 i = (i32)0; i < mbw; i = i + (i32)1)
            {
            aboveY2[i] = (i32)0;
            aboveU[i * (i32)2] = (i32)0;
            aboveU[i * (i32)2 + (i32)1] = (i32)0;
            aboveV[i * (i32)2] = (i32)0;
            aboveV[i * (i32)2 + (i32)1] = (i32)0;
            for (i32 k = (i32)0; k < (i32)4; k = k + (i32)1)
                {
                aboveY[i * (i32)4 + k] = (i32)0;
                }
            }
        for (i32 my = (i32)0; my < mbh; my = my + (i32)1)
            {
            leftY2 = (i32)0;
            for (i32 k = (i32)0; k < (i32)4; k = k + (i32)1)
                {
                leftY[k] = (i32)0;
                }
            leftU[0] = (i32)0;
            leftU[1] = (i32)0;
            leftV[0] = (i32)0;
            leftV[1] = (i32)0;
            for (i32 mx = (i32)0; mx < mbw; mx = mx + (i32)1)
                {
                self.macroblock(hdr, tok, mx, my);
                }
            }
        hdr.flush();
        tok.flush();
        UXData* f = UXData.withCapacity((i32)10 + hdr.len + tok.len);
        u32 tag = ((u32)hdr.len << (u32)5) | (u32)$10; // key frame, version 0, shown
        f.appendByte((u8)(tag & (u32)255));
        f.appendByte((u8)((tag >> (u32)8) & (u32)255));
        f.appendByte((u8)((tag >> (u32)16) & (u32)255));
        f.appendByte((u8)$9D);
        f.appendByte((u8)$01);
        f.appendByte((u8)$2A);
        f.appendByte((u8)(w & (i32)255));
        f.appendByte((u8)((w >> (i32)8) & (i32)$3F));
        f.appendByte((u8)(h & (i32)255));
        f.appendByte((u8)((h >> (i32)8) & (i32)$3F));
        f.appendBytes(hdr.buf, hdr.len);
        f.appendBytes(tok.buf, tok.len);
        return f;
        }

    // the last frame as a decoder will show it: I420, cropped to the frame (w x h, then the two
    // chroma planes at (w+1)/2 x (h+1)/2)
    UXData* reconstruction(void)
        {
        i32 cw = (w + (i32)1) / (i32)2;
        i32 ch = (h + (i32)1) / (i32)2;
        UXData* d = UXData.withCapacity(w * h + (i32)2 * cw * ch);
        for (i32 y = (i32)0; y < h; y = y + (i32)1)
            {
            d.appendBytes(recY + (i64)(y * yp), w);
            }
        for (i32 y = (i32)0; y < ch; y = y + (i32)1)
            {
            d.appendBytes(recU + (i64)(y * cp), cw);
            }
        for (i32 y = (i32)0; y < ch; y = y + (i32)1)
            {
            d.appendBytes(recV + (i64)(y * cp), cw);
            }
        return d;
        }
    }

// Matroska's building blocks (EBML): an element is its ID, its size as a variable-length integer,
// and its payload.
class UXWebM
    {
    static void id(UXData* d, u32 v)
        {
        if (v > (u32)$FFFFFF)
            {
            d.appendByte((u8)(v >> (u32)24));
            }
        if (v > (u32)$FFFF)
            {
            d.appendByte((u8)((v >> (u32)16) & (u32)255));
            }
        if (v > (u32)$FF)
            {
            d.appendByte((u8)((v >> (u32)8) & (u32)255));
            }
        d.appendByte((u8)(v & (u32)255));
        }
    // a size, in as few bytes as hold it
    static void sizeOf(UXData* d, i64 n)
        {
        i32 len = (i32)1;
        while (len < (i32)8 && n >= (((i64)1 << (i64)(len * (i32)7)) - (i64)1))
            {
            len = len + (i32)1;
            }
        UXWebM.sizeIn(d, n, len);
        }
    static void sizeIn(UXData* d, i64 n, i32 len)
        {
        for (i32 i = len - (i32)1; i >= (i32)0; i = i - (i32)1)
            {
            i64 b = (n >> (i64)(i * (i32)8)) & (i64)255;
            if (i == len - (i32)1)
                {
                b = b | ((i64)$80 >> (i64)(len - (i32)1));
                }
            d.appendByte((u8)b);
            }
        }
    static void master(UXData* d, u32 v, UXData* payload)
        {
        UXWebM.id(d, v);
        UXWebM.sizeOf(d, (i64)payload.length());
        d.appendData(payload);
        }
    static void uint(UXData* d, u32 v, i64 n)
        {
        i32 len = (i32)1;
        while (len < (i32)8 && (n >> (i64)(len * (i32)8)) != (i64)0)
            {
            len = len + (i32)1;
            }
        UXWebM.id(d, v);
        UXWebM.sizeOf(d, (i64)len);
        for (i32 i = len - (i32)1; i >= (i32)0; i = i - (i32)1)
            {
            d.appendByte((u8)((n >> (i64)(i * (i32)8)) & (i64)255));
            }
        }
    // a fixed eight-byte unsigned integer, for a value written before it is known
    static void uintFixed(UXData* d, u32 v, i64 n)
        {
        UXWebM.id(d, v);
        UXWebM.sizeOf(d, (i64)8);
        for (i32 i = (i32)7; i >= (i32)0; i = i - (i32)1)
            {
            d.appendByte((u8)((n >> (i64)(i * (i32)8)) & (i64)255));
            }
        }
    static void text(UXData* d, u32 v, u8* s)
        {
        i32 n = (i32)0;
        while (s[n] != (u8)0)
            {
            n = n + (i32)1;
            }
        UXWebM.id(d, v);
        UXWebM.sizeOf(d, (i64)n);
        d.appendBytes(s, n);
        }
    // a whole number as an eight-byte IEEE double
    static void wholeFloat(UXData* d, u32 v, i64 n)
        {
        i64 bits = (i64)0;
        if (n > (i64)0)
            {
            i32 e = (i32)0;
            while (e < (i32)62 && (n >> (i64)(e + (i32)1)) != (i64)0)
                {
                e = e + (i32)1;
                }
            i64 mant = (n << (i64)((i32)52 - e)) & (((i64)1 << (i64)52) - (i64)1);
            bits = ((i64)((i32)1023 + e) << (i64)52) | mant;
            }
        UXWebM.uintFixed(d, v, bits);
        }
    }

// The movie: frames in, a WebM file out.
class UXMovie
    {
    i32 w;
    i32 h;
    i32 fps;
    UXVp8Encoder* enc;
    Array* frames;   // UXData: each distinct frame, encoded
    i32* startTick;  // where each frame starts, in ticks
    i32 cap;
    i32 ticks;       // the movie so far, in ticks
    u32* lastPx;     // the last frame added, to hold it rather than encode it again
    bool finished;

    // A movie of width x height pixels at fps ticks a second.
    static UXMovie* make(i32 width, i32 height, i32 framesPerSecond)
        {
        UXMovie* m = new UXMovie();
        m.w = width < (i32)1 ? (i32)1 : (width > (i32)16383 ? (i32)16383 : width);
        m.h = height < (i32)1 ? (i32)1 : (height > (i32)16383 ? (i32)16383 : height);
        m.fps = framesPerSecond < (i32)1 ? (i32)1 : framesPerSecond;
        m.enc = UXVp8Encoder.make(m.w, m.h, (i32)10);
        m.frames = new Array();
        m.cap = (i32)64;
        m.startTick = new i32[(u32)m.cap];
        m.ticks = (i32)0;
        m.lastPx = (u32*)0;
        m.finished = false;
        return m;
        }
    // VP8's quantizer index, 0 (finest, largest) .. 127 (coarsest); 10 by default, where a UI's text
    // and edges stay sharp.
    void setQuantizer(i32 q)
        {
        enc.setQuantizer(q);
        }
    i32 frameCount(void)
        {
        return (i32)frames.count();
        }
    // the movie's length so far, in milliseconds
    i32 durationMs(void)
        {
        return (i32)(((i64)ticks * (i64)1000 + (i64)(fps / (i32)2)) / (i64)fps);
        }

    // One frame, for one tick.  False if the image is not the movie's size or the movie is finished.
    bool add(UXImage* img)
        {
        return self.addHeld(img, (i32)1);
        }
    // One frame, shown for `held` ticks.
    bool addHeld(UXImage* img, i32 held)
        {
        if (img == (UXImage*)0 || img.w != w || img.h != h)
            {
            return false;
            }
        return self._addARGB(img.px, held);
        }
    // One frame from RGBA bytes (four a pixel, rows top first), shown for `held` ticks.
    bool addPixels(u8* rgba, i32 width, i32 height, i32 held)
        {
        if (rgba == (u8*)0 || width != w || height != h)
            {
            return false;
            }
        u32* px = new u32[(u32)(w * h)];
        for (i32 i = (i32)0; i < w * h; i = i + (i32)1)
            {
            u8* p = rgba + (i64)(i * (i32)4);
            px[i] = ((u32)p[3] << (u32)24) | ((u32)p[0] << (u32)16) | ((u32)p[1] << (u32)8) | (u32)p[2];
            }
        return self._addARGB(px, held);
        }
    bool _addARGB(u32* px, i32 held)
        {
        if (finished || held < (i32)1)
            {
            return false;
            }
        i32 n = w * h;
        if (lastPx != (u32*)0)
            {
            bool same = true;
            for (i32 i = (i32)0; i < n && same; i = i + (i32)1)
                {
                same = px[i] == lastPx[i];
                }
            if (same)
                {
                ticks = ticks + held; // the frame before simply lasts longer
                return true;
                }
            }
        else
            {
            lastPx = new u32[(u32)n];
            }
        for (i32 i = (i32)0; i < n; i = i + (i32)1)
            {
            lastPx[i] = px[i];
            }
        i32 k = (i32)frames.count();
        if (k == cap)
            {
            i32* ns = new i32[(u32)(cap * (i32)2)];
            for (i32 i = (i32)0; i < cap; i = i + (i32)1)
                {
                ns[i] = startTick[i];
                }
            startTick = ns;
            cap = cap * (i32)2;
            }
        startTick[k] = ticks;
        frames.add(enc.encode(px, w));
        ticks = ticks + held;
        return true;
        }
    // The last frame added, as a VP8 decoder will show it (I420, cropped to the frame).
    UXData* reconstruction(void)
        {
        return enc.reconstruction();
        }

    i64 _tickMs(i32 t)
        {
        return ((i64)t * (i64)1000 + (i64)(fps / (i32)2)) / (i64)fps;
        }

    // The whole movie as a WebM file.  The movie takes no more frames after this.
    UXData* finish(void)
        {
        finished = true;
        i32 nf = (i32)frames.count();

        UXData* ebml = UXData.withCapacity((i32)64);
        UXData* eh = UXData.withCapacity((i32)64);
        UXWebM.uint(eh, (u32)$4286, (i64)1);  // EBMLVersion
        UXWebM.uint(eh, (u32)$42F7, (i64)1);  // EBMLReadVersion
        UXWebM.uint(eh, (u32)$42F2, (i64)4);  // EBMLMaxIDLength
        UXWebM.uint(eh, (u32)$42F3, (i64)8);  // EBMLMaxSizeLength
        UXWebM.text(eh, (u32)$4282, (u8*)"webm");
        UXWebM.uint(eh, (u32)$4287, (i64)2);  // DocTypeVersion
        UXWebM.uint(eh, (u32)$4285, (i64)2);  // DocTypeReadVersion
        UXWebM.master(ebml, (u32)$1A45DFA3, eh);

        UXData* info = UXData.withCapacity((i32)64);
        UXData* ip = UXData.withCapacity((i32)64);
        UXWebM.uint(ip, (u32)$2AD7B1, (i64)1000000); // TimecodeScale: milliseconds
        UXWebM.wholeFloat(ip, (u32)$4489, self._tickMs(ticks)); // Duration
        UXWebM.text(ip, (u32)$4D80, (u8*)"UXKit UXMovie"); // MuxingApp
        UXWebM.text(ip, (u32)$5741, (u8*)"UXKit UXMovie"); // WritingApp
        UXWebM.master(info, (u32)$1549A966, ip);

        UXData* tracks = UXData.withCapacity((i32)64);
        UXData* te = UXData.withCapacity((i32)64);
        UXWebM.uint(te, (u32)$D7, (i64)1);    // TrackNumber
        UXWebM.uint(te, (u32)$73C5, (i64)1);  // TrackUID
        UXWebM.uint(te, (u32)$83, (i64)1);    // TrackType: video
        UXWebM.uint(te, (u32)$9C, (i64)0);    // FlagLacing
        UXWebM.text(te, (u32)$86, (u8*)"V_VP8");
        UXData* vid = UXData.withCapacity((i32)16);
        UXWebM.uint(vid, (u32)$B0, (i64)w);   // PixelWidth
        UXWebM.uint(vid, (u32)$BA, (i64)h);   // PixelHeight
        UXWebM.master(te, (u32)$E0, vid);
        UXData* tes = UXData.withCapacity((i32)64);
        UXWebM.master(tes, (u32)$AE, te);
        UXWebM.master(tracks, (u32)$1654AE6B, tes);

        // clusters of up to five seconds, each starting with a frame; the last frame is a BlockGroup
        // with its duration, so it is shown for as long as it was held
        UXData* clusters = UXData.withCapacity((i32)1024);
        i32 ncl = (i32)0;
        i64* clusterPos = new i64[(u32)(nf + (i32)1)];
        i64* clusterMs = new i64[(u32)(nf + (i32)1)];
        i32 f = (i32)0;
        while (f < nf)
            {
            i64 c0 = self._tickMs(startTick[f]);
            UXData* cl = UXData.withCapacity((i32)1024);
            UXWebM.uint(cl, (u32)$E7, c0); // Timecode
            while (f < nf && self._tickMs(startTick[f]) - c0 < (i64)5000)
                {
                UXData* fr = (UXData* ?)frames.get((u32)f);
                UXData* blk = UXData.withCapacity(fr.length() + (i32)4);
                i64 rel = self._tickMs(startTick[f]) - c0;
                blk.appendByte((u8)$81); // track 1
                blk.appendByte((u8)((rel >> (i64)8) & (i64)255));
                blk.appendByte((u8)(rel & (i64)255));
                if (f == nf - (i32)1)
                    {
                    blk.appendByte((u8)0);
                    blk.appendData(fr);
                    UXData* bg = UXData.withCapacity(blk.length() + (i32)16);
                    UXWebM.master(bg, (u32)$A1, blk); // Block
                    UXWebM.uint(bg, (u32)$9B, self._tickMs(ticks) - self._tickMs(startTick[f])); // BlockDuration
                    UXWebM.master(cl, (u32)$A0, bg); // BlockGroup
                    }
                else
                    {
                    blk.appendByte((u8)$80); // a key frame
                    blk.appendData(fr);
                    UXWebM.master(cl, (u32)$A3, blk); // SimpleBlock
                    }
                f = f + (i32)1;
                }
            clusterPos[ncl] = (i64)clusters.length();
            clusterMs[ncl] = c0;
            ncl = ncl + (i32)1;
            UXWebM.master(clusters, (u32)$1F43B675, cl);
            }

        // where each part is, from the start of the segment's payload: the seek head is fixed in size
        // (68 bytes: three entries, eight-byte positions), so the others follow from it
        i64 infoAt = (i64)68;
        i64 tracksAt = infoAt + (i64)info.length();
        i64 clustersAt = tracksAt + (i64)tracks.length();
        i64 cuesAt = clustersAt + (i64)clusters.length();

        UXData* cues = UXData.withCapacity((i32)256);
        UXData* cp = UXData.withCapacity((i32)256);
        for (i32 i = (i32)0; i < ncl; i = i + (i32)1)
            {
            UXData* pt = UXData.withCapacity((i32)32);
            UXWebM.uint(pt, (u32)$B3, clusterMs[i]); // CueTime
            UXData* tp = UXData.withCapacity((i32)16);
            UXWebM.uint(tp, (u32)$F7, (i64)1); // CueTrack
            UXWebM.uint(tp, (u32)$F1, clustersAt + clusterPos[i]); // CueClusterPosition
            UXWebM.master(pt, (u32)$B7, tp);
            UXWebM.master(cp, (u32)$BB, pt);
            }
        UXWebM.master(cues, (u32)$1C53BB6B, cp);

        UXData* seek = UXData.withCapacity((i32)68);
        UXData* sp = UXData.withCapacity((i32)64);
        self._seekEntry(sp, (u32)$1549A966, infoAt);
        self._seekEntry(sp, (u32)$1654AE6B, tracksAt);
        self._seekEntry(sp, (u32)$1C53BB6B, cuesAt);
        UXWebM.master(seek, (u32)$114D9B74, sp);

        UXData* seg = UXData.withCapacity((i32)68 + info.length() + tracks.length() + clusters.length() + cues.length());
        seg.appendData(seek);
        seg.appendData(info);
        seg.appendData(tracks);
        seg.appendData(clusters);
        seg.appendData(cues);
        UXData* out = UXData.withCapacity(ebml.length() + seg.length() + (i32)12);
        out.appendData(ebml);
        UXWebM.id(out, (u32)$18538067); // Segment
        UXWebM.sizeIn(out, (i64)seg.length(), (i32)8);
        out.appendData(seg);
        return out;
        }
    void _seekEntry(UXData* d, u32 target, i64 at)
        {
        UXData* e = UXData.withCapacity((i32)20);
        UXData* sid = UXData.withCapacity((i32)4);
        UXWebM.id(sid, target);
        UXWebM.id(e, (u32)$53AB); // SeekID
        UXWebM.sizeOf(e, (i64)4);
        e.appendData(sid);
        UXWebM.uintFixed(e, (u32)$53AC, at); // SeekPosition
        UXWebM.master(d, (u32)$4DBB, e);
        }
    }
