#!/usr/bin/perl
# =============================================================================
# 把任意 PCM WAV（16 / 24 / 32 位整数，含 0xFFFE 扩展格式）转成 FPGA 能放的格式：16 位 PCM、48000 Hz。
#   重采样：加窗（Blackman）sinc 多相滤波，每边 16 个输入点，截止 0.45 × min(输入, 输出采样率)。
#   用法：perl tools/wav_to_tf.pl 输入.wav 输出.wav [声道数 1|2]      （不给声道数 = 和输入一样；1 = 左右取平均）
#   例：  perl tools/wav_to_tf.pl ../source/Audio/1.wav ../source/Audio_TF/1.wav 2     背景音乐：立体声
#         perl tools/wav_to_tf.pl ../source/Audio/2.wav ../source/Audio_TF/2.wav 1     音效：单声道
#   有 ffmpeg 的话也可以：ffmpeg -i 输入 -ar 48000 -ac 2 -c:a pcm_s16le 1.wav（audio.md §4）
# =============================================================================
use strict; use warnings;
my ($in, $out, $och) = @ARGV;
die "用法：perl wav_to_tf.pl 输入.wav 输出.wav [1|2]\n" unless defined $out;
my $ORATE = 48000;

open my $fh, '<:raw', $in or die "打不开 $in\n";
local $/; my $buf = <$fh>; close $fh;
die "$in 不是 RIFF/WAVE\n" unless substr($buf, 0, 4) eq 'RIFF' && substr($buf, 8, 4) eq 'WAVE';
my ($tag, $ch, $rate, $bits, $data);
my $p = 12;
while ($p + 8 <= length $buf) {
    my $id = substr($buf, $p, 4); my $sz = unpack('V', substr($buf, $p + 4, 4));
    if ($id eq 'fmt ') {
        ($tag, $ch, $rate, undef, undef, $bits) = unpack('vvVVvv', substr($buf, $p + 8, 16));
        $tag = unpack('v', substr($buf, $p + 8 + 24, 2)) if $tag == 0xFFFE;   # 扩展格式：子格式 GUID 的前两个字节
    } elsif ($id eq 'data') {
        $sz = length($buf) - $p - 8 if $p + 8 + $sz > length $buf;            # 有的文件 data 大小写得不对
        $data = substr($buf, $p + 8, $sz); last;
    }
    $p += 8 + $sz + ($sz & 1);
}
die "$in：没有 fmt / data 块\n" unless defined $tag && defined $data;
die "$in：不是整数 PCM（格式 $tag）\n" unless $tag == 1;
die "$in：只支持 16 / 24 / 32 位（这个是 $bits 位）\n" unless $bits == 16 || $bits == 24 || $bits == 32;
$och ||= $ch; $och = 2 if $och > 2;

# ---- 解码成 [-1, 1) 的浮点，每个声道一个数组 ----
my $bps = $bits / 8; my $n = int(length($data) / ($bps * $ch));
my @x = map { [] } 1 .. $ch;
for my $i (0 .. $n - 1) {
    for my $c (0 .. $ch - 1) {
        my $o = ($i * $ch + $c) * $bps; my $v;
        if    ($bits == 16) { $v = unpack('s<', substr($data, $o, 2)) / 32768; }
        elsif ($bits == 24) { my ($b0, $b1, $b2) = unpack('C3', substr($data, $o, 3)); my $u = $b0 | ($b1 << 8) | ($b2 << 16); $u -= 1 << 24 if $u & 0x800000; $v = $u / 8388608; }
        else                { $v = unpack('l<', substr($data, $o, 4)) / 2147483648; }
        push @{ $x[$c] }, $v;
    }
}
# 声道：要单声道就取平均；要立体声而输入是单声道就复制
my @src;
if ($och == 1) { if ($ch == 1) { @src = ($x[0]); } else { my @m = map { ($x[0][$_] + $x[1][$_]) / 2 } 0 .. $n - 1; @src = (\@m); } }
else           { @src = ($ch == 1) ? ($x[0], $x[0]) : ($x[0], $x[1]); }

# ---- 重采样：输出第 j 个点在输入的 t = j × rate / ORATE 处，用 t 周围 2 × HALF 个输入点加窗 sinc 插值 ----
my $HALF = 16;
my $fc = 0.45 * (($rate < $ORATE) ? 1 : $ORATE / $rate);                     # 截止（相对输入采样率）
my $PI = 4 * atan2(1, 1);
my $NPH = 2048;                                                             # 小数位置量化成 2048 个相位，系数查表
my @tab;
for my $ph (0 .. $NPH) {
    my $f = $ph / $NPH; my @w;
    for my $k (-$HALF + 1 .. $HALF) {
        my $d = $k - $f;                                                    # 输入点 floor(t) + k 到 t 的距离
        my $s = ($d == 0) ? 2 * $fc : sin(2 * $PI * $fc * $d) / ($PI * $d);
        my $u = ($d + $HALF) / (2 * $HALF);                                 # 0~1 的窗位置
        my $win = ($u <= 0 || $u >= 1) ? 0 : 0.42 - 0.5 * cos(2 * $PI * $u) + 0.08 * cos(4 * $PI * $u);
        push @w, $s * $win;
    }
    my $sum = 0; $sum += $_ for @w; @w = map { $_ / $sum } @w;              # 直流增益 = 1
    push @tab, \@w;
}
my $nout = int($n * $ORATE / $rate);
my @y = map { [] } 1 .. $och;
for my $j (0 .. $nout - 1) {
    my $t = $j * $rate / $ORATE; my $i0 = int($t);
    my $w = $tab[int(($t - $i0) * $NPH + 0.5)];
    for my $c (0 .. $och - 1) {
        my $s = 0; my $xs = $src[$c];
        for my $k (0 .. 2 * $HALF - 1) {
            my $i = $i0 + $k - $HALF + 1;
            next if $i < 0 || $i >= $n;
            $s += $w->[$k] * $xs->[$i];
        }
        push @{ $y[$c] }, $s;
    }
}

# ---- 写 16 位 PCM WAV（标准 44 字节头）；原来就接近满幅时重采样会稍微过冲，超过满幅就整体压低，不削顶 ----
my $peak = 0;
for my $c (0 .. $och - 1) { for (@{ $y[$c] }) { my $a = abs $_; $peak = $a if $a > $peak; } }
my $gain = ($peak * 32768 > 32767) ? 32767 / ($peak * 32768) : 1;
my $pcm = '';
my $clip = 0;
for my $j (0 .. $nout - 1) {
    for my $c (0 .. $och - 1) {
        my $s = $y[$c][$j] * $gain;
        my $v = int($s * 32768 + ($s >= 0 ? 0.5 : -0.5));
        if ($v > 32767) { $v = 32767; $clip++ } elsif ($v < -32768) { $v = -32768; $clip++ }
        $pcm .= pack('s<', $v);
    }
}
open my $oh, '>:raw', $out or die "写不了 $out\n";
print $oh 'RIFF', pack('V', 36 + length $pcm), 'WAVE',
          'fmt ', pack('VvvVVvv', 16, 1, $och, $ORATE, $ORATE * $och * 2, $och * 2, 16),
          'data', pack('V', length $pcm), $pcm;
close $oh;
printf "%s → %s：%d Hz %d 位 %d 声道 → 48000 Hz 16 位 %d 声道，%.2f 秒%s\n", $in, $out, $rate, $bits, $ch, $och, $nout / $ORATE,
       ($gain < 1 ? sprintf("（峰值超过满幅，整体压低 %.2f dB）", -20 * log($gain) / log(10)) : '') . ($clip ? "（$clip 个点削顶）" : '');
