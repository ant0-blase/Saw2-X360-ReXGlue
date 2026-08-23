cd ~/Saw2-RexGlue

cat > gdb-invalid-func.gdb <<'GDB'
set pagination off
set confirm off
set breakpoint pending on

set logging file logs/gdb-invalid-function.log
set logging overwrite on
set logging enabled on

handle SIGSEGV nostop noprint pass
handle SIGPIPE nostop noprint pass
handle SIGUSR1 nostop noprint pass
handle SIGUSR2 nostop noprint pass

break rex::runtime::InvalidFunctionTrap

commands 1
silent

echo \n========================================\n
echo ===== INVALID GUEST FUNCTION =======\n
echo ========================================\n

echo \n===== CALL STACK =====\n
bt

echo \n===== PPC CONTEXT POINTER =====\n
p/x $rdi

echo \n===== INVALID TARGET =====\n
p/x ((PPCContext*)$rdi)->last_indirect_target

echo \n===== PPC LR / CTR =====\n
p/x ((PPCContext*)$rdi)->lr
p/x ((PPCContext*)$rdi)->ctr

echo \n===== PPC ARGUMENT REGISTERS =====\n
p/x ((PPCContext*)$rdi)->r3.u32
p/x ((PPCContext*)$rdi)->r4.u32
p/x ((PPCContext*)$rdi)->r5.u32
p/x ((PPCContext*)$rdi)->r6.u32
p/x ((PPCContext*)$rdi)->r7.u32
p/x ((PPCContext*)$rdi)->r8.u32
p/x ((PPCContext*)$rdi)->r9.u32
p/x ((PPCContext*)$rdi)->r10.u32
p/x ((PPCContext*)$rdi)->r11.u32
p/x ((PPCContext*)$rdi)->r12.u32

echo \n===== CALLER SOURCE =====\n
frame 1
list

echo \n========================================\n
echo ===== CAPTURE COMPLETE =============\n
echo ========================================\n

set logging enabled off
quit
end

run
GDB

mkdir -p logs

export LD_LIBRARY_PATH="$PWD/out/stage/linux-amd64-relwithdebinfo${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

gdb -q \
  -x "$PWD/gdb-invalid-func.gdb" \
  --args \
  "$PWD/out/stage/linux-amd64-relwithdebinfo/saw2" \
  "--game_data_root=$PWD/game" \
  "--gpu_plugin=xenos" \
  "--input_backend=sdl" \
  "--resolution=720p" \
  "--log_file=$PWD/logs/gdb-invalid-runtime.log"
