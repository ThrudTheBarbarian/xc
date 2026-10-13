#!/bin/sh
# Unpack xcc and the benchmark sources, and build the four par programs with
# the shipped compiler at -O3, as benchmark/diy.py does.
fail() { echo 1 > ~/install-exit-status; exit 1; }
tar xjf xcc-linux-0.8.tar.bz2 || fail
tar xjf xcc-bench-sources-0.8.tar.bz2 || fail
mkdir -p bin
for b in mandelbrot perlin nbody saxpy
do
    ./xcc-linux-0.8/bin/xcc -O3 -o bin/$b xcc-bench-sources-0.8/benchmark/par/$b.xc || fail
done

cat > xc-par <<'EOF'
#!/bin/sh
# xc-par <benchmark> <device>
# The program prints "<checksum> <best_us> <first_us>" for its eight runs.
bench=$1
device=$2
case $bench in
    mandelbrot) want=199 ;;
    perlin)     want=243 ;;
    nbody)      want=42 ;;
    saxpy)      want=3011510272 ;;
    *)          echo "unknown benchmark $bench" > $LOG_FILE; echo 1 > ~/test-exit-status; exit 1 ;;
esac
unset XC_PAR XC_PAR_THREADS XC_PAR_GPU
case $device in
    serial)       export XC_PAR=cpu XC_PAR_THREADS=1 ;;
    cpu)          export XC_PAR=cpu ;;
    gpu|gpus|all) export XC_PAR=$device ;;
    auto)         ;;
    *)            echo "unknown device $device" > $LOG_FILE; echo 1 > ~/test-exit-status; exit 1 ;;
esac
# XC_PAR_REPORT names the device each run used. A GPU mode on a machine
# without a usable GPU runs on the CPU instead, so it is refused here rather
# than recorded as a GPU figure.
# The report lines and the result share the output; the result is the last line.
XC_PAR_REPORT=1 ./bin/$bench > out.txt 2>&1
status=$?
cat out.txt > $LOG_FILE
if [ $status -ne 0 ]; then
    echo $status > ~/test-exit-status
    exit $status
fi
# Every device without a GPU is the CPU alone, so it is refused as well.
case $device in
    gpu|gpus|all)
        if grep -q "stays on the CPU" out.txt ||
           { [ $device = all ] && ! grep -q "tiles across .*vulkan" out.txt; }; then
            echo "FAILED: no usable GPU; the block ran on the CPU (see the lines above)" >> $LOG_FILE
            echo 1 > ~/test-exit-status
            exit 1
        fi ;;
esac
set -- $(tail -n 1 out.txt)
if [ "$1" != "$want" ]; then
    echo "FAILED: checksum $1, expected $want" >> $LOG_FILE
    echo 1 > ~/test-exit-status
    exit 1
fi
awk -v b="$2" -v f="$3" 'BEGIN { printf "Best run: %.3f ms\nFirst run: %.3f ms\n", b / 1000, f / 1000 }' >> $LOG_FILE
echo 0 > ~/test-exit-status
EOF
chmod +x xc-par
echo 0 > ~/install-exit-status
