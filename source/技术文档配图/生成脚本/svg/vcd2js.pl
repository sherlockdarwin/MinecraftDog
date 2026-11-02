#!/usr/bin/perl
# vcd2js.pl file.vcd t0_ps t1_ps varname=label:fmt ...   -> JS object literal on stdout
# fmt: bit | dec | sdec8 | ascii | hex
use strict; use warnings;
my ($file, $t0, $t1, @sel) = @ARGV;
open my $f, '<', $file or die;
my (%id2name, %want, %fmt, %lab, @order);
for (@sel) { my ($n, $rest) = split /=/, $_, 2; my ($l, $fm) = split /:/, $rest; $want{$n} = 1; $lab{$n} = $l; $fmt{$n} = $fm; push @order, $n; }
my %cur; my %ch; my $t = 0; my %idname;
while (<$f>) {
    if (/^\$var \w+ \d+ (\S+) (\S+)/) { $idname{$1} = $2 if $want{$2}; next; }
    if (/^#(\d+)/) { $t = $1; last if $t > $t1; next; }
    my ($v, $id);
    if (/^b([01xz]+) (\S+)/) { ($v, $id) = ($1, $2); }
    elsif (/^([01xz])(\S+)/) { ($v, $id) = ($1, $2); }
    else { next; }
    next unless exists $idname{$id};
    my $n = $idname{$id};
    my $val = ($v =~ /[xz]/) ? 'null' : oct("0b$v");
    if ($t < $t0) { $cur{$n} = $val; next; }
    push @{$ch{$n}}, [$t, $val];
}
print "{t0:$t0,t1:$t1,sig:[\n";
for my $n (@order) {
    my @c = ([$t0, $cur{$n} // 'null'], @{$ch{$n} // []});
    print "{name:'$lab{$n}',fmt:'$fmt{$n}',c:[", join(',', map { "[$_->[0],$_->[1]]" } @c), "]},\n";
}
print "]}\n";
