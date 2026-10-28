#!/bin/sh
# Unpack xcc and the C benchmark sources, and build each program at each size
# (BENCH_SCALE 1, 4 and 16 times the work): by GCC and by Clang at -O2 and at
# -O3 -march=native, the OpenMP copies (the same files with one pragma on the
# timed loop) by both at -O3 -march=native -fopenmp, and by xcc (whose C path
# needs clang on the PATH), plain and with --par-auto.  Clang's OpenMP needs
# libomp; without it that build is left out, and running it says so.
fail() { echo 1 > ~/install-exit-status; exit 1; }
tar xjf xcc-linux-0.87.3.tar.bz2 || fail
tar xjf xcc-c-bench-sources-0.87.tar.bz2 || fail
src=xcc-c-bench-sources-0.87
mkdir -p bin
for k in 1 4 16
do
    for b in saxpy nbody perlin md5 md5_mask mandelbrot mandel_deep
    do
        [ $b = saxpy ] && [ $k = 16 ] && continue # 2 GB of static arrays: saxpy stops at 4x
        o=bin/$b.x$k
        d="-DBENCH_SCALE=$k"
        gcc   -O2 -w $d -o $o.gcc $src/$b.c -lm || fail
        clang -O2 -w $d -o $o.clang $src/$b.c -lm || fail
        gcc   -O3 -march=native -w $d -o $o.gcc-native $src/$b.c -lm || fail
        clang -O3 -march=native -w $d -o $o.clang-native $src/$b.c -lm || fail
        gcc   -O3 -march=native -fopenmp -w $d -o $o.gcc-openmp $src/openmp/$b.c -lm || fail
        clang -O3 -march=native -fopenmp -w $d -o $o.clang-openmp $src/openmp/$b.c -lm 2>/dev/null
        ./xcc-linux-0.87.3/bin/xcc -q -O3 $d -o $o.xcc $src/$b.c || fail
        ./xcc-linux-0.87.3/bin/xcc -q -O3 --par-auto $d -o $o.xcc-par $src/$b.c || fail
    done
done

cat > xc-c <<'EOS'
#!/bin/sh
# xc-c <benchmark> <build> <size>
# The program prints "<checksum> <best_us> <first_us>" for its eight runs.
bench=$1
build=$2
size=$3
refuse() { echo "$1" > $LOG_FILE; echo 1 > ~/test-exit-status; exit 1; }
# the checksum each program must print, per size (gpu_also: what a GPU may print)
gpu_also=
case "$bench x$size" in
    "saxpy x1")       want=3011510272 ;;
    "nbody x1")       want=42 ;;
    "perlin x1")      want=243 ;;
    "md5 x1")         want=2573682417 ;;
    "md5_mask x1")    want=1683609514 ;;
    "mandelbrot x1")  want=199 ;;
    "mandel_deep x1") want=2738; gpu_also=2739 ;;
    "saxpy x4")       want=3456106496 ;;
    "nbody x4")       want=83 ;;
    "perlin x4")      want=249 ;;
    "md5 x4")         want=3642826323 ;;
    "md5_mask x4")    want=2029290716 ;;
    "mandelbrot x4")  want=797 ;;
    "mandel_deep x4") want=2377 ;;
    "saxpy x16")      refuse "saxpy stops at 4x: 16x would need 2 GB of static arrays, and it is bound by memory, not arithmetic" ;;
    "nbody x16")      want=163 ;;
    "perlin x16")     want=56 ;;
    "md5 x16")        want=2362491763 ;;
    "md5_mask x16")   want=2765936813 ;;
    "mandelbrot x16") want=3189 ;;
    "mandel_deep x16") want=941 ;;
    *) refuse "unknown benchmark or size: $bench x$size" ;;
esac
unset XC_PAR XC_PAR_THREADS XC_PAR_GPU
case $build in
    gcc|clang|gcc-native|clang-native|gcc-openmp|clang-openmp|xcc) bin=bin/$bench.x$size.$build ;;
    xcc-par-cpu)  bin=bin/$bench.x$size.xcc-par; export XC_PAR=cpu ;;
    xcc-par-gpu)  bin=bin/$bench.x$size.xcc-par; export XC_PAR=gpu ;;
    xcc-par-gpus) bin=bin/$bench.x$size.xcc-par; export XC_PAR=gpus ;;
    xcc-par-auto) bin=bin/$bench.x$size.xcc-par ;;
    *)            refuse "unknown build $build" ;;
esac
[ -x $bin ] || refuse "not built: $bin (Clang's OpenMP needs libomp installed)"
# XC_PAR_REPORT names the device each par block used.  A GPU build on a
# machine without a usable GPU runs on the CPU instead, so it is refused
# rather than recorded as a GPU figure.  The result is the last line.
XC_PAR_REPORT=1 ./$bin > out.txt 2>&1
status=$?
cat out.txt > $LOG_FILE
if [ $status -ne 0 ]; then
    echo $status > ~/test-exit-status
    exit $status
fi
case $build in
    xcc-par-gpu|xcc-par-gpus)
        if grep -q "stays on the CPU" out.txt; then
            echo "FAILED: no usable GPU; the block ran on the CPU (see the lines above)" >> $LOG_FILE
            echo 1 > ~/test-exit-status
            exit 1
        fi ;;
esac
set -- $(tail -n 1 out.txt)
# a GPU rounds with fast math, which can move a float result's last digit
ok=0
[ "$1" = "$want" ] && ok=1
case "$build" in
    xcc-par-gpu|xcc-par-gpus|xcc-par-auto)
        for g in $gpu_also; do [ "$1" = "$g" ] && ok=1; done ;;
esac
if [ $ok = 0 ]; then
    echo "FAILED: checksum $1, expected $want" >> $LOG_FILE
    echo 1 > ~/test-exit-status
    exit 1
fi
awk -v b="$2" -v f="$3" 'BEGIN { printf "Best run: %.3f ms\nFirst run: %.3f ms\n", b / 1000, f / 1000 }' >> $LOG_FILE
echo 0 > ~/test-exit-status
EOS
chmod +x xc-c
echo 0 > ~/install-exit-status
