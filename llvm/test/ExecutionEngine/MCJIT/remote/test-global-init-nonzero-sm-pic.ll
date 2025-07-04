; RUN: %lli -jit-kind=mcjit -remote-mcjit -mcjit-remote-process=lli-child-target \
; RUN:   -relocation-model=pic -code-model=small %s > /dev/null
; XFAIL: target={{(mips|mipsel)-.*}}, target={{(aarch64|arm).*}}, target={{(i686|i386).*}}
; XFAIL: target={{.*-windows-(gnu|msvc)}}
; REQUIRES: thread_support
; UNSUPPORTED: target=target=powerpc64-unknown-linux-gnu
; Remove UNSUPPORTED for powerpc64-unknown-linux-gnu if problem caused by r266663 is fixed

@count = global i32 1, align 4

define i32 @main() nounwind {
entry:
  %retval = alloca i32, align 4
  %i = alloca i32, align 4
  store i32 0, ptr %retval
  store i32 0, ptr %i, align 4
  br label %for.cond

for.cond:                                         ; preds = %for.inc, %entry
  %0 = load i32, ptr %i, align 4
  %cmp = icmp slt i32 %0, 49
  br i1 %cmp, label %for.body, label %for.end

for.body:                                         ; preds = %for.cond
  %1 = load i32, ptr @count, align 4
  %inc = add nsw i32 %1, 1
  store i32 %inc, ptr @count, align 4
  br label %for.inc

for.inc:                                          ; preds = %for.body
  %2 = load i32, ptr %i, align 4
  %inc1 = add nsw i32 %2, 1
  store i32 %inc1, ptr %i, align 4
  br label %for.cond

for.end:                                          ; preds = %for.cond
  %3 = load i32, ptr @count, align 4
  %sub = sub nsw i32 %3, 50
  ret i32 %sub
}
