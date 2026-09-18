# Color only framework messages. Compiler/tool output passes through unchanged.
BEGIN {
    esc = sprintf("%c", 27)
    reset = esc "[0m"
}
{
    color = ""
    if ($0 ~ /^\[[^]]+\] \[ERROR\]/) color = esc "[31m"
    else if ($0 ~ /^\[[^]]+\] \[WARN\]/) color = esc "[33m"
    else if ($0 ~ /^\[[^]]+\] \[SUCCESS\]/) color = esc "[32m"
    else if ($0 ~ /^\[[^]]+\] \[INFO\]/) color = esc "[36m"
    else if ($0 ~ /^\[[^]]+\] \[DEBUG\]/) color = esc "[90m"
    if (color != "") {
        gsub(/qemu-aarch64/, esc "[35mqemu-aarch64" color)
        gsub(/qemu-x86_64/, esc "[34mqemu-x86_64" color)
        gsub(/qemu-riscv64/, esc "[96mqemu-riscv64" color)
        gsub(/qemu-loongarch64/, esc "[33mqemu-loongarch64" color)
        print color $0 reset
    } else {
        print
    }
    fflush()
}
