param(
    [string]$Pdf = 'E:\FPGA\reference\02_F02_FC02_PH1P35\02_hardware\HW_MLKPAI-F02-20250425-FC02-20241023\06_芯片手册\01_FPGA\DS1300_PH1P_Datasheet.pdf',
    [string]$OutV = "$PSScriptRoot\..\mcproject_code\src\rtl\video\osd\mc_logo_rom.v",
    [string]$OutHex = "$PSScriptRoot\..\mcproject_code\src\sim\data\logo_480x128.hex",
    [string]$OutPng = "$PSScriptRoot\..\mcproject_code\src\doc\logo_preview.png"
)
# =============================================================================
# 生成屏幕上的安路 Logo（mc_logo_rom.v）：
#   1. 把安路 PH1P 数据手册封面（第 1 页）渲染成大图，自动找出左上角的安路标志（深蓝 "A" + 红色横条）并裁下来；
#   2. 拼成 480×128 的白底横幅：左边标志，右边 "安路科技"（微软雅黑粗体）+ 下面一行 "ANLOGIC"，整体居中；
#   3. 每个像素量化成 4 种颜色之一（0 白、1 深蓝、2 红、3 深蓝和白之间的过渡色），2 位一个像素；
#   4. 写出 mc_logo_rom.v（每个地址 8 个像素 = 16 位，左边的像素在低 2 位，地址 = 行 × 60 + 列 / 8），
#      测试台用的 logo_640x128.hex（一行一个像素），和一张预览图 logo_preview.png（量化以后的样子）。
# 用法（在 Minecraft_MLKfpgacode 目录下）：powershell -ExecutionPolicy Bypass -File tools\gen_logo.ps1
# 改了以后要重新编译 FPGA。颜色值改这里的 $PAL（同时改 mc_osd_logo.v 的调色板参数默认值）。
# =============================================================================
Add-Type -AssemblyName System.Drawing
$W = 480; $H = 128; $WORDS = $W / 8
# 调色板（RGB），和 mc_osd_logo.v 的 C0~C3 一致
$PAL = @(@(255, 255, 255), @(30, 45, 90), @(220, 35, 45), @(150, 158, 182))

# ---- 1. 渲染封面，裁出标志 ----
$tmp = Join-Path $env:TEMP 'mc_logo_cover.png'
& powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\render_pdf.ps1" -Pdf $Pdf -Page 1 -Out $tmp -Scale 4.0 | Out-Null
$cover = [System.Drawing.Bitmap]::FromFile($tmp)
# 标志在封面左上角：在左 1/3、上 1/4 的范围里找不是白色的像素的外框
$x0 = $cover.Width; $y0 = $cover.Height; $x1 = 0; $y1 = 0
for ($y = 0; $y -lt [int]($cover.Height / 4); $y += 1) {
    for ($x = 0; $x -lt [int]($cover.Width / 3); $x += 1) {
        $p = $cover.GetPixel($x, $y)
        if (($p.R + $p.G + $p.B) -lt 600) {
            if ($x -lt $x0) { $x0 = $x }; if ($x -gt $x1) { $x1 = $x }
            if ($y -lt $y0) { $y0 = $y }; if ($y -gt $y1) { $y1 = $y }
        }
    }
}
if ($x1 -le $x0) { throw "emblem not found on the cover page" }
$ew = $x1 - $x0 + 1; $eh = $y1 - $y0 + 1
Write-Host "emblem bbox: x $x0..$x1, y $y0..$y1 ($ew x $eh)"

# ---- 2. 拼横幅 ----
$bmp = New-Object System.Drawing.Bitmap($W, $H)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$g.Clear([System.Drawing.Color]::White)
$dh = 100; $dw = [int]($ew * $dh / $eh)                  # 标志高 100 像素
$ey = [int](($H - $dh) / 2)
$navy = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($PAL[1][0], $PAL[1][1], $PAL[1][2]))
$cn = -join ([char[]](0x5B89, 0x8DEF, 0x79D1, 0x6280))  # 安路科技
$fCn = New-Object System.Drawing.Font('Microsoft YaHei', 50, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$fEn = New-Object System.Drawing.Font('Microsoft YaHei', 26, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$sf = [System.Drawing.StringFormat]::GenericTypographic
$tw = [Math]::Max($g.MeasureString($cn, $fCn, 1000, $sf).Width, $g.MeasureString('A N L O G I C', $fEn, 1000, $sf).Width + 4)
$ex = [int](($W - ($dw + 36 + $tw)) / 2)              # 标志 + 间隔 + 文字整体居中
$g.DrawImage($cover, (New-Object System.Drawing.Rectangle($ex, $ey, $dw, $dh)), (New-Object System.Drawing.Rectangle($x0, $y0, $ew, $eh)), [System.Drawing.GraphicsUnit]::Pixel)
$tx = $ex + $dw + 36
$g.DrawString($cn, $fCn, $navy, [single]$tx, [single]6)
$g.DrawString('A N L O G I C', $fEn, $navy, [single]($tx + 4), [single]78)
$g.Dispose()

# ---- 3. 量化 ----
$px = New-Object 'int[]' ($W * $H)
for ($y = 0; $y -lt $H; $y++) {
    for ($x = 0; $x -lt $W; $x++) {
        $p = $bmp.GetPixel($x, $y); $best = 0; $bd = [int]::MaxValue
        for ($k = 0; $k -lt 4; $k++) {
            $dr = $p.R - $PAL[$k][0]; $dg = $p.G - $PAL[$k][1]; $db = $p.B - $PAL[$k][2]
            $d = $dr * $dr + $dg * $dg + $db * $db
            if ($d -lt $bd) { $bd = $d; $best = $k }
        }
        $px[$y * $W + $x] = $best
    }
}
$bmp.Dispose(); $cover.Dispose()

# ---- 4. 输出 ----
# 预览图（量化后的颜色）
$pv = New-Object System.Drawing.Bitmap($W, $H)
for ($y = 0; $y -lt $H; $y++) { for ($x = 0; $x -lt $W; $x++) {
    $c = $PAL[$px[$y * $W + $x]]; $pv.SetPixel($x, $y, [System.Drawing.Color]::FromArgb($c[0], $c[1], $c[2])) } }
$pv.Save((Resolve-Path -LiteralPath (Split-Path $OutPng)).Path + '\' + (Split-Path $OutPng -Leaf), [System.Drawing.Imaging.ImageFormat]::Png); $pv.Dispose()
# 测试台用：一行一个像素（0~3）
New-Item -ItemType Directory -Force (Split-Path $OutHex) | Out-Null
[System.IO.File]::WriteAllLines([System.IO.Path]::GetFullPath($OutHex), [string[]]($px | ForEach-Object { $_.ToString() }))
# ROM：每个地址 8 个像素，左边的像素在低 2 位
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('`timescale 1ns / 1ps')
[void]$sb.AppendLine('// =============================================================================')
[void]$sb.AppendLine('// mc_logo_rom.v  安路 Logo 位图 ROM（自动生成，请不要手改；生成脚本 tools/gen_logo.ps1）')
[void]$sb.AppendLine('// 480×128 像素，每像素 2 位（0 白 1 深蓝 2 红 3 过渡色，颜色在 mc_osd_logo.v）；标志取自安路 PH1P 数据手册封面。')
[void]$sb.AppendLine('// 地址 = 行 × 60 + 列 / 8，一次给 8 个像素（左边的像素在低 2 位）；输出比地址晚一个时钟。')
[void]$sb.AppendLine('// =============================================================================')
[void]$sb.AppendLine('module mc_logo_rom (')
[void]$sb.AppendLine('    input  wire        I_clk,')
[void]$sb.AppendLine('    input  wire [12:0] I_addr,')
[void]$sb.AppendLine('    output reg  [15:0] O_data')
[void]$sb.AppendLine(');')
[void]$sb.AppendLine('')
# 写成数组 + rom_style（TD 综合手册 4.2.15），否则 TD 把这张表综合成 1000 多个 LUT
[void]$sb.AppendLine(('(* rom_style = "bram" *) reg [15:0] S_mem [0:{0}];' -f ($W * $H / 8 - 1)))
[void]$sb.AppendLine('')
[void]$sb.AppendLine('initial begin')
for ($a = 0; $a -lt $W * $H / 8; $a++) {
    $v = 0
    for ($i = 0; $i -lt 8; $i++) { $v = $v -bor ($px[$a * 8 + $i] -shl (2 * $i)) }
    [void]$sb.AppendLine(("    S_mem[{0}] = 16'h{1:X4};" -f $a, $v))
}
[void]$sb.AppendLine('end')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('always @(posedge I_clk) begin')
[void]$sb.AppendLine('    O_data <= S_mem[I_addr];')
[void]$sb.AppendLine('end')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('endmodule')
[System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($OutV), $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
$cnt = @(0, 0, 0, 0); foreach ($v in $px) { $cnt[$v]++ }
Write-Host ("pixels: white {0}, navy {1}, red {2}, edge {3}" -f $cnt[0], $cnt[1], $cnt[2], $cnt[3])
