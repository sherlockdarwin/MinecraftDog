#!/usr/bin/perl
# =============================================================================
# 生成仿真用的 FAT32 "TF 卡镜像"（tb_audio 用 $readmemh 读它；每行一个字节，十六进制）。
# 用法：perl mk_sd_test_image.pl <输出.hex> <扇区数/簇> <1=带MBR分区表 0=没有分区表（整盘就是一个 FAT32 卷）> [FAT 份数=2] [根目录起始簇=2] [坏签名=0] [目录填满=0] [ext64=0] [分区类型=12]
#   坏签名（其实是各种"坏引导扇区"）：1 = 卷引导扇区的签名第 2 字节（0xAA）坏，2 = MBR 的签名第 2 字节坏，3 = 卷引导扇区的签名第 1 字节（0x55）坏，
#     4 = MBR 的签名第 1 字节坏，5 = 卷引导扇区里每扇区字节数不是 512，6 = 卷引导扇区里 FAT 大小为 0（用来测挂载失败的各个出口）
#   目录填满：1 = 根目录刚好填满它占的簇（后面没有 0x00 结尾项，要靠簇链的结尾标记才知道目录到头）；
#            2 = 同上，但最后一个目录簇和 4.WAV 的簇链都以"保留簇号 1"结尾（损坏的卡：FAT 项是 1，不是结尾标记，也不是合法的簇号）
#   ptype：MBR 里分区类型（默认 12 = 0x0C FAT32 LBA；11 = 0x0B FAT32 CHS）
#   ext64：1 = 多一个 64.WAV（最大的合法编号）和一个 65.WAV 诱饵（超出范围）；曲目数变成 9
#
# 镜像里有（根目录文件名都是 8.3 短名；用来测 mc_fat32 的目录扫描、簇链跟随、WAV 头解析）：
#   1.WAV   单声道 16 kHz，400 个采样
#   02.WAV  立体声 48 kHz，600 帧（数据 2400 字节，跨 3~5 个簇，簇号故意打乱 = 碎片化，其中有 200、262、131 号簇：落在 FAT 的第 1、2 个扇区）
#   3.WAV   单声道 24 kHz，300 个采样，数据块前面有一个 LIST 块（要被跳过）
#   4.WAV   单声道 44.1 kHz，120 个采样（要重采样到 48.8 kHz）；目录项里写的文件大小 = 16 MB + 实际大小（测大小字段的最高字节；簇链比这短得多，读到簇链结束为止，整个簇都送出来）
#   5.WAV   立体声 32 kHz，100 帧，放在根目录的第 2 个簇里（要跟着簇链找）
#   7.WAV   文件头不是 RIFF/WAVE（应该报"不是 WAV"）
#   10.WAV  单声道 12 kHz，80 个采样（48 / 44.1 / 32 / 24 / 16 / 12 kHz 各有一个文件，测重采样用）
#   8.WAV   单声道 96 kHz（高于 48.8 kHz 的 I2S 帧率，不支持，应该报"格式不支持"）
#   诱饵：卷标项、长文件名项（属性 0x0F）、被删除的 "1.WAV"、子目录、README.TXT、NOTES.WAV（名字不是数字）、99.WAV（编号超出范围 64）、
#         0.WAV（编号 0）、数字名的"卷标"（11.WAV，属性 0x08）、扩展名错一个字符的 14.XAV / 15.WXV / 16.WAX、起始簇为 0 的空文件 17.WAV、
#         1025.WAV（4 位数字，按 10 位算会绕回成 1）、"18     X.WAV"（第 8 个字符不是空格）、01.WAV（1 号曲目的第二个目录项，指向同一个文件，只能算一首）
# 采样值公式（和 tb_audio.v 里一致）：sample(k, ch, n) = (n*131 + ch*7919 + k*5003) & 0xFFFF，k = 曲目号，ch = 0 左 / 1 右
# =============================================================================
use strict;
my ($out, $spc, $mbr, $nfats_a, $root_a, $badsig, $fulldir, $ext64, $ptype) = @ARGV;
$badsig  ||= 0;
$fulldir ||= 0;
$ext64   ||= 0;
$ptype   = 0x0C unless defined $ptype && $ptype ne "";
die "usage: $0 out.hex spc mbr [nfats] [root_cl] [badsig] [fulldir] [ext64] [ptype]\n" unless defined $mbr;

my $part_lba = $mbr ? 2048 : 0;
my $resv     = 32;
my $nfats    = defined $nfats_a ? $nfats_a : 2;
my $fatsz    = 8;                       # 每份 FAT 占 8 个扇区 = 1024 个簇项
my $root_cl  = defined $root_a ? $root_a : 2;
my $data_off = $resv + $nfats * $fatsz; # 数据区相对卷起点的扇区数

my %disk;                                # 扇区号 => 512 字节数组引用（稀疏）
sub sector { my $lba = shift; $disk{$lba} ||= [ (0) x 512 ]; return $disk{$lba}; }
sub put8   { my ($lba, $off, $v) = @_; sector($lba)->[$off] = $v & 0xFF; }
sub put16  { my ($lba, $off, $v) = @_; put8($lba,$off,$v); put8($lba,$off+1,$v>>8); }
sub put32  { my ($lba, $off, $v) = @_; put16($lba,$off,$v); put16($lba,$off+2,$v>>16); }
sub putstr { my ($lba, $off, $s) = @_; my $i = 0; for my $c (split //, $s) { put8($lba, $off+$i, ord($c)); $i++; } }

# 簇号 -> 扇区号
sub cl2lba { my $c = shift; return $part_lba + $data_off + ($c - 2) * $spc; }

# ---------------- FAT 表（内存里的 32 位数组）----------------
my @fat = (0) x ($fatsz * 128);
$fat[0] = 0x0FFFFFF8; $fat[1] = 0x0FFFFFFF;

# 空闲簇分配次序（故意乱序，造成碎片）。02.WAV 最先分配，簇链：每簇 2 扇区的镜像是 4 → 200 → 262；每簇 1 扇区的镜像是 4 → 200 → 262 → 131 → 7。
# 簇号 200、262、131 不在 FAT 的第 0 个扇区里（每个 FAT 扇区 128 项）：第 1、2 个 FAT 扇区、以及簇号的第 6 位为 1（200 = 0xC8）的情况也被测到；真实的卡上簇号都很大。
my @free = (4, 200, 262, 131, 7, 5, 12, 9, 14, 11, 6, 13, 8, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30);
sub alloc_chain {
    my $nbytes = shift;
    my $ncl = int(($nbytes + $spc * 512 - 1) / ($spc * 512));
    $ncl = 1 if $ncl < 1;
    my @c = splice(@free, 0, $ncl);
    for my $i (0 .. $#c) { $fat[$c[$i]] = ($i == $#c) ? 0x0FFFFFFF : $c[$i+1]; }
    return @c;
}
sub write_chain {                        # 把字节数组按簇链写进数据区
    my ($data_ref, @chain) = @_;
    my $pos = 0;
    for my $c (@chain) {
        for my $s (0 .. $spc - 1) {
            for my $b (0 .. 511) {
                last if $pos >= scalar(@$data_ref);
                put8(cl2lba($c) + $s, $b, $data_ref->[$pos]); $pos++;
            }
        }
    }
}

sub smp { my ($k, $ch, $n) = @_; return ($n * 131 + $ch * 7919 + $k * 5003) & 0xFFFF; }

sub wav {                                # 返回文件字节数组
    my (%a) = @_;                        # k ch rate frames list_chunk bad_hdr
    my @pcm;
    for my $n (0 .. $a{frames} - 1) { for my $ch (0 .. $a{ch} - 1) { my $v = smp($a{k}, $ch, $n); push @pcm, $v & 0xFF, $v >> 8; } }
    my @h;
    my $fmt_len = 16;
    my $list_len = $a{list} ? 8 + 30 : 0;
    my $riff_size = 4 + (8 + $fmt_len) + $list_len + (8 + scalar(@pcm));
    push @h, unpack("C*", $a{bad} ? "RIFX" : "RIFF"), (map { ($riff_size >> (8*$_)) & 0xFF } 0..3), unpack("C*", "WAVE");
    push @h, unpack("C*", "fmt "), (16,0,0,0), (1,0), ($a{ch},0);
    push @h, (map { ($a{rate} >> (8*$_)) & 0xFF } 0..3);
    my $brate = $a{rate} * $a{ch} * 2;
    push @h, (map { ($brate >> (8*$_)) & 0xFF } 0..3), ($a{ch}*2, 0), (16, 0);
    if ($a{list}) { push @h, unpack("C*", "LIST"), (30,0,0,0), unpack("C*", "INFOISFT" . ("x" x 22)); }
    push @h, unpack("C*", "data"), (map { (scalar(@pcm) >> (8*$_)) & 0xFF } 0..3);
    return (@h, @pcm);
}

# ---------------- 各个文件 ----------------
my @files;   # [short name (11 字符), attr, 字节数组 或 undef, 已删除?]
my %clip = (
    '1       WAV' => [ wav(k=>1, ch=>1, rate=>16000, frames=>400) ],
    '02      WAV' => [ wav(k=>2, ch=>2, rate=>48000, frames=>600) ],
    '3       WAV' => [ wav(k=>3, ch=>1, rate=>24000, frames=>300, list=>1) ],
    '4       WAV' => [ wav(k=>4, ch=>1, rate=>44100, frames=>120) ],
    '5       WAV' => [ wav(k=>5, ch=>2, rate=>32000, frames=>100) ],
    '7       WAV' => [ wav(k=>7, ch=>1, rate=>16000, frames=>50, bad=>1) ],
    '10      WAV' => [ wav(k=>10, ch=>1, rate=>12000, frames=>80) ],
    '8       WAV' => [ wav(k=>8, ch=>1, rate=>96000, frames=>40) ],
);
$clip{'64      WAV'} = [ wav(k=>64, ch=>1, rate=>16000, frames=>60) ] if $ext64;
my (%start_cl, %nchain);
for my $name (sort keys %clip) {
    my @chain = alloc_chain(scalar(@{$clip{$name}}));
    $fat[$chain[-1]] = ($fulldir == 2 ? 1 : 0x0FFFFFF8) if $name eq '4       WAV';       # 4.WAV 的簇链用最小的结尾标记 0x0FFFFFF8（>= 0x0FFFFFF8 都是结尾）
    $nchain{$name} = scalar(@chain);
    write_chain($clip{$name}, @chain);
    $start_cl{$name} = $chain[0];
}
# 诱饵文件的数据（内容无所谓，别被读到）
my @decoy_cl = alloc_chain(100);
my @readme_cl = alloc_chain(100);
my @notes_cl = alloc_chain(100);
my @n99_cl = alloc_chain(100);

# ---------------- 根目录条目 ----------------
my @ent;   # 每项 32 字节
sub dirent {
    my ($name, $attr, $cl, $size, $deleted) = @_;
    my @e = (0) x 32;
    my @n = unpack("C*", $name);
    @e[0..10] = @n;
    $e[0] = 0xE5 if $deleted;
    $e[11] = $attr;
    $e[20] = ($cl >> 16) & 0xFF; $e[21] = ($cl >> 24) & 0xFF;
    $e[26] = $cl & 0xFF; $e[27] = ($cl >> 8) & 0xFF;
    for my $i (0..3) { $e[28+$i] = ($size >> (8*$i)) & 0xFF; }
    return \@e;
}
push @ent, dirent("MCTEST     ", 0x08, 0, 0);                                   # 卷标
{ my @e = (0x41, unpack("C*", "l\0o\0n\0g\0n"), 0x0F, 0, 0, unpack("C*", "a\0m\0e\0.\0w\0a"), 0, 0, unpack("C*", "v\0")); push @ent, \@e; }  # 长文件名项（属性 0x0F）
push @ent, dirent("SUBDIR     ", 0x10, $decoy_cl[0], 0);                       # 子目录
push @ent, dirent("README  TXT", 0x20, $readme_cl[0], 100);                    # 不是 WAV
push @ent, dirent("1       WAV", 0x20, $start_cl{'1       WAV'}, scalar(@{$clip{'1       WAV'}}));
push @ent, dirent("02      WAV", 0x20, $start_cl{'02      WAV'}, scalar(@{$clip{'02      WAV'}}));
push @ent, dirent("1       WAV", 0x20, $decoy_cl[0], 999, 1);                  # 被删除的 1.WAV（放在真的 1.WAV 后面：如果错误地认了已删除项，就会把真的盖掉）
push @ent, dirent("3       WAV", 0x20, $start_cl{'3       WAV'}, scalar(@{$clip{'3       WAV'}}));
push @ent, dirent("4       WAV", 0x20, $start_cl{'4       WAV'}, scalar(@{$clip{'4       WAV'}}) + 0x01010000);   # 目录项里的大小 = 16 MB + 64 KB + 实际大小：测文件大小的最高字节；簇链短得多，读到簇链结束为止（送出整个簇）
push @ent, dirent("NOTES   WAV", 0x20, $notes_cl[0], 100);                     # 名字不是数字
push @ent, dirent("8       TXT", 0x20, $readme_cl[0], 100);                    # 数字名但扩展名不是 WAV
push @ent, dirent("9       WAV", 0x10, $decoy_cl[0], 0);                       # 数字名 + WAV 的"子目录"（属性 0x10）
push @ent, dirent("99      WAV", 0x20, $n99_cl[0], 100);                       # 编号超出范围
push @ent, dirent("0       WAV", 0x20, $n99_cl[0], 100);                       # 编号 0（没有 0 号曲目）
push @ent, dirent("11      WAV", 0x08, $n99_cl[0], 100);                       # 数字名 + WAV 的"卷标"（属性 0x08）
push @ent, dirent("14      XAV", 0x20, $n99_cl[0], 100);                       # 扩展名第 1 个字符不对
push @ent, dirent("15      WXV", 0x20, $n99_cl[0], 100);                       # 扩展名第 2 个字符不对
push @ent, dirent("16      WAX", 0x20, $n99_cl[0], 100);                       # 扩展名第 3 个字符不对
push @ent, dirent("17      WAV", 0x20, 0, 0);                                  # 起始簇 = 0 的空文件
push @ent, dirent("01      WAV", 0x20, $start_cl{'1       WAV'}, scalar(@{$clip{'1       WAV'}}));   # 1 号曲目的第二个目录项（指向同一个文件）：只能算一首
push @ent, dirent("1025    WAV", 0x20, $n99_cl[0], 100);                       # 4 位数字（超过 3 位要拒绝；如果只按 10 位算，1025 会绕回成 1）
push @ent, dirent("18     XWAV", 0x20, $n99_cl[0], 100);                       # 名字的第 8 个字符不是空格（数字 + 空格 + 一个 X）
if ($ext64) {
    push @ent, dirent("65      WAV", 0x20, $n99_cl[0], 100);                   # 编号 65：超出范围
    push @ent, dirent("64      WAV", 0x20, $start_cl{'64      WAV'}, scalar(@{$clip{'64      WAV'}}));   # 64 号曲目（最大的合法编号）
}
push @ent, dirent("7       WAV", 0x20, $start_cl{'7       WAV'}, scalar(@{$clip{'7       WAV'}}));
push @ent, dirent("10      WAV", 0x20, $start_cl{'10      WAV'}, scalar(@{$clip{'10      WAV'}}));
push @ent, dirent("8       WAV", 0x20, $start_cl{'8       WAV'}, scalar(@{$clip{'8       WAV'}}));
# 填充一批已删除的项，把 5.WAV 挤到根目录的第 2 个簇里
my $per_cluster = $spc * 16;
while (scalar(@ent) < $per_cluster + 3) { push @ent, dirent("OLD     TMP", 0x20, 0, 0, 1); }
push @ent, dirent("5       WAV", 0x20, $start_cl{'5       WAV'}, scalar(@{$clip{'5       WAV'}}));
if ($fulldir) { while (scalar(@ent) % $per_cluster != 0) { push @ent, dirent("OLD     TMP", 0x20, 0, 0, 1); } }   # 填满最后一个簇：后面没有结尾项
# 之后是 0x00 开头的项 = 目录结束（目录填满时没有）

# 根目录占的簇数
my $root_ncl = int((scalar(@ent) + ($fulldir ? 0 : 1) + $per_cluster - 1) / $per_cluster);
my @root_chain = ($root_cl);
if ($root_ncl > 1) {
    # 根目录的第 2 个簇用 @free 里剩下的最后一个（碎片化）
    my $c2 = pop @free;
    push @root_chain, $c2;
}
$fat[$root_chain[0]] = (@root_chain > 1) ? $root_chain[1] : 0x0FFFFFFF;
$fat[$root_chain[1]] = ($fulldir == 2 ? 1 : $fulldir ? 0x0FFFFFF8 : 0x0FFFFFFF) if @root_chain > 1;
# 把根目录条目写进簇
for my $i (0 .. $#ent) {
    my $cl = $root_chain[ int($i / $per_cluster) ];
    my $idx = $i % $per_cluster;
    my $lba = cl2lba($cl) + int($idx / 16);
    for my $b (0..31) { put8($lba, ($idx % 16) * 32 + $b, $ent[$i][$b]); }
}

# ---------------- FAT 表写进扇区 ----------------
for my $f (0 .. $nfats - 1) {
    for my $i (0 .. $#fat) {
        put32($part_lba + $resv + $f * $fatsz + int($i / 128), ($i % 128) * 4, $fat[$i]);
    }
}

# 引导代码区（卷引导扇区的 90~509 字节、MBR 的 0~445 字节）真实的卡里是启动代码，不是 0：这里填非零的杂数，
# 检查读取器只在该取的位置取字段（例如 450 / 454~457 字节在 MBR 里是分区表，在卷引导扇区里只是启动代码）
sub junk { my ($lba, $from, $to, $seed) = @_; for my $i ($from .. $to) { put8($lba, $i, (($i * 61 + $seed) & 0xFF) | 0x41); } }

# ---------------- 卷引导扇区 ----------------
my $vbr = $part_lba;
junk($vbr, 90, 509, 29);
my $total_secs = $data_off + 64 * $spc + 100;
put8($vbr, 0, $mbr ? 0xEB : 0xE9); put8($vbr, 1, 0x58); put8($vbr, 2, 0x90);     # 跳转指令：分区里的卷用 EB，整盘一个卷的用 E9（读取器两种都要认）
putstr($vbr, 3, "MSWIN4.1");
put16($vbr, 11, $badsig == 5 ? 256 : 512); put8($vbr, 13, $spc); put16($vbr, 14, $resv); put8($vbr, 16, $nfats);
put16($vbr, 17, 0); put16($vbr, 19, 0); put8($vbr, 21, 0xF8); put16($vbr, 22, 0);
put16($vbr, 24, 63); put16($vbr, 26, 255); put32($vbr, 28, $part_lba); put32($vbr, 32, $total_secs);
put32($vbr, 36, $badsig == 6 ? 0 : $fatsz); put16($vbr, 40, 0); put16($vbr, 42, 0); put32($vbr, 44, $root_cl);
put16($vbr, 48, 1); put16($vbr, 50, 6);
put8($vbr, 64, 0x80); put8($vbr, 66, 0x29); put32($vbr, 67, 0x12345678);
putstr($vbr, 71, "NO NAME    "); putstr($vbr, 82, "FAT32   ");
put8($vbr, 510, $badsig == 3 ? 0x00 : 0x55); put8($vbr, 511, $badsig == 1 ? 0x00 : 0xAA);

# ---------------- MBR ----------------
if ($mbr) {
    junk(0, 0, 445, 77); put8(0, 0, 0xEB);                   # MBR 的启动代码：第一个字节也是 EB（像 GRUB），但后面的字段不对，不能被当成卷引导扇区
    put8(0, 446, 0x80); put8(0, 447, 0x01); put8(0, 448, 0x01); put8(0, 449, 0x00);
    put8(0, 450, $ptype); put8(0, 451, 0xFE); put8(0, 452, 0xFF); put8(0, 453, 0xFF);
    put32(0, 454, $part_lba); put32(0, 458, $total_secs);
    put8(0, 510, $badsig == 4 ? 0x00 : 0x55); put8(0, 511, $badsig == 2 ? 0x00 : 0xAA);
}

# ---------------- 每首曲目的期望内容（tb 用来逐字节核对）----------------
my $base = $out; $base =~ s/\.hex$//;
for my $name (sort keys %clip) {
    my $num = $name; $num =~ s/\s.*$//; $num =~ s/^0+(?=\d)//;
    my @exp = @{$clip{$name}};
    if ($name eq '4       WAV') {                          # 目录项里的大小 >= 16 MB：读到簇链结束为止，送出整个簇（后面补零）
        my $cb = $nchain{$name} * $spc * 512;
        push @exp, 0 while scalar(@exp) < $cb;
    }
    open(my $cf, ">", "${base}_clip${num}.hex") or die;
    printf $cf "%02X\n", $_ for @exp;
    close $cf;
    open(my $sf, ">", "${base}_clip${num}.size") or die;
    print $sf scalar(@exp), "\n";
    close $sf;
}

# ---------------- 输出：稀疏扇区 → 连续的字节流 ----------------
my $max_lba = 0; for my $l (keys %disk) { $max_lba = $l if $l > $max_lba; }
open(my $fh, ">", $out) or die "cannot write $out";
for my $lba (0 .. $max_lba) {
    my $s = $disk{$lba} || [ (0) x 512 ];
    for my $b (@$s) { printf $fh "%02X\n", $b; }
}
close $fh;
print "wrote $out: ", ($max_lba + 1), " sectors, spc=$spc, mbr=$mbr, root clusters=", scalar(@root_chain), "\n";
