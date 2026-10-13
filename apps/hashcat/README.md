# hashcat MD5 in xc

`md5.xc` is hashcat's MD5 workload written in xc: each item hashes one short
candidate through the full MD5 compression (64 rounds over a single 512-bit
block), the way hashcat's `-m 0` kernel does. The hash runs inside a `par`
block, so the compiler chooses the device.

This is a speed exercise. It measures how fast the `par` GPU path runs a real
cryptographic kernel, next to hashcat's own number on the same machine.

## Correctness

The 64 rounds are one body of code, used both by the CPU self-test and by the
GPU block, so passing the self-test proves the kernel the GPU runs.

    xcc -O3 -o build/md5 md5.xc
    ./build/md5 -t

prints the digest of each RFC 1321 test string and checks it:

    md5("") = d41d8cd98f00b204e9800998ecf8427e  ok
    md5("abc") = 900150983cd24fb0d6963f7d28e17f72  ok
    md5("message digest") = f96b697d7cb7938d525a2f31aaf161d0  ok
    md5("abcdefghijklmnopqrstuvwxyz") = c3fcd3d76192e4007dfb496cca67e13b  ok

## Running

The benchmark hashes a batch of candidates eight times and prints
`<checksum> <best_us> <first_us>` to stdout, with the hashes-per-second of the
best run on stderr. The checksum is the exact sum of every candidate's four
digest words, so every device must agree on it.

    XC_PAR=cpu XC_PAR_THREADS=1 ./build/md5    # one CPU thread
    XC_PAR=cpu  ./build/md5                     # every CPU thread
    XC_PAR=gpu  ./build/md5                     # the GPU
    ./build/md5                                 # auto: measures both, keeps the faster

It is also one of the `par` benchmarks: `benchmark/par/run.py --bench md5`
builds and times it on each machine and device.

## The mask variant

`md5_mask.xc` mirrors hashcat's mask attack (`-a 3`): a fixed prefix and one
sweeping mask position, rather than one candidate per item. MD5 round 1 reads
the message words in order, so the steps before the mask word depend only on
the prefix and run once per prefix, not once per candidate — 52 steps instead
of 64. This is why hashcat's optimized kernel beats a full per-candidate MD5.
`md5_mask -t` checks one candidate's digest; the benchmark runs the same three
tokens and `benchmark/par/run.py --bench md5_mask` times it. The hoisted prefix
makes it faster than `md5`, closing most of the gap to hashcat's optimized
kernel.

## Comparing with hashcat

hashcat's own benchmark uses a hand-optimized kernel that drops work it can
reverse from a known target:

    hashcat -b -m 0

Its pure kernel does the full compression, the same work as `md5.xc`. Measure
it with a short attack whose target is outside the keyspace:

    hashcat -m 0 -a 3 <any-md5> '?l?l?l?l?l?l?l?l?l' --runtime=15 \
        --status --status-timer=5 --potfile-disable

and read the `Speed` line.
