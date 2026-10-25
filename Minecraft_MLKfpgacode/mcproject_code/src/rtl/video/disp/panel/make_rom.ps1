# make_rom.ps1 : 把屏幕初始化脚本(文本) 转成 TD ROM IP 要用的 .mif / .mif.dat
# 用法（在本目录右键 "使用 PowerShell 运行"，或在终端里）：
#     powershell -ExecutionPolicy Bypass -File make_rom.ps1
#     powershell -ExecutionPolicy Bypass -File make_rom.ps1 -Src other_panel_init.txt -Name mc_other_panel
# 输出到 src/ip/w8_d1024_rom/ ；改了 -Name 的话，还要把 w8_d1024_rom.v 里的 INIT_FILE 路径同步改成新文件名。
param(
    [string]$Src  = (Join-Path $PSScriptRoot 'ili9881c_k101_init.txt'),
    [string]$Name = 'mc_ili9881c_k101',
    [string]$OutDir = (Join-Path $PSScriptRoot '..\..\..\..\ip\w8_d1024_rom'),
    [int]$ClkHz = 10000000          # display_config_wrapper 的时钟（10 MHz），DELAY 按它换算
)
$ErrorActionPreference = 'Stop'
$bytes = New-Object System.Collections.Generic.List[byte]
$lineNo = 0
foreach ($raw in Get-Content -LiteralPath $Src -Encoding UTF8) {
    $lineNo++
    $line = ($raw -replace '#.*$', '').Trim()
    if ($line -eq '') { continue }
    $t = $line -split '\s+'
    $op = $t[0].ToUpper()
    switch ($op) {
        'PAGE'  { $bytes.AddRange([byte[]](0x01,0x04,0xFF,0x98,0x81,[byte][int]$t[1])) }
        'REG'   { $bytes.AddRange([byte[]](0x02,[Convert]::ToByte($t[1],16),[Convert]::ToByte($t[2],16))) }
        'CMD'   { $bytes.AddRange([byte[]](0x03,[Convert]::ToByte($t[1],16))) }
        'LONG'  { $d = $t[1..($t.Count-1)] | ForEach-Object { [Convert]::ToByte($_,16) }
                  $bytes.Add(0x01); $bytes.Add([byte]$d.Count); $bytes.AddRange([byte[]]$d) }
        'DELAY' { $n = [uint32]([int64]$t[1] * ($ClkHz / 1000))
                  $bytes.AddRange([byte[]](0x04, (($n -shr 24) -band 0xFF), (($n -shr 16) -band 0xFF), (($n -shr 8) -band 0xFF), ($n -band 0xFF))) }
        'END'   { $bytes.Add(0x05) }
        default { throw "第 $lineNo 行: 不认识的指令 '$op'" }
    }
}
if ($bytes[$bytes.Count-1] -ne 0x05) { throw "脚本最后必须有 END" }
if ($bytes.Count -gt 1024) { throw "脚本 $($bytes.Count) 字节，超过 ROM 容量 1024" }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$mif = New-Object System.Text.StringBuilder
[void]$mif.Append("DEPTH`t`t    =`t1024;`r`nWIDTH`t`t    =`t8;`r`nADDRESS_RADIX`t=`tDEC;`r`nDATA_RADIX`t    =`tHEX;`r`nCONTENT `t BEGIN`r`n")
for ($i = 0; $i -lt $bytes.Count; $i++) { [void]$mif.Append(("{0}`t: {1:X2};`r`n" -f $i, $bytes[$i])) }
[void]$mif.Append(("[{0}..1023] : 00;`r`nEND;`r`n" -f $bytes.Count))
$dat = New-Object System.Text.StringBuilder
for ($i = 0; $i -lt 1024; $i++) {
    $b = if ($i -lt $bytes.Count) { $bytes[$i] } else { 0 }
    [void]$dat.Append(([Convert]::ToString($b, 2).PadLeft(8, '0')) + "`r`n")
}
$enc = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path (Resolve-Path $OutDir) "$Name.mif"), $mif.ToString(), $enc)
[IO.File]::WriteAllText((Join-Path (Resolve-Path $OutDir) "$Name.mif.dat"), $dat.ToString(), $enc)
$sum = 0; foreach ($b in $bytes) { $sum += $b }
"OK: $($bytes.Count) 字节 -> $Name.mif / .mif.dat  (字节和 = $sum)"
