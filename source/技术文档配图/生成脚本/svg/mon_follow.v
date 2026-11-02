module mon_follow;
integer fd;
initial fd = $fopen("follow_loop.csv", "w");
always @(tb_follow.ntick) if (tb_follow.plant)
    $fwrite(fd, "%0d,%0.3f,%0.3f,%0d,%0d,%0d,%0d\n", tb_follow.ntick, tb_follow.yr[0] * 360.0 / 65536.0,
            tb_follow.owner[0] * 360.0 / 65536.0, tb_follow.l0, tb_follow.r0, tb_follow.st0, tb_follow.s0);
endmodule
