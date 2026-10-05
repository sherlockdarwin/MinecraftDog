#!/bin/bash
# =============================================================================
# 根据 src/ 下实际存在的文件，重新生成 mcproject_code/MinecraftDog_FPGA.al（TD 工程文件）。
# 什么时候用：往 src/rtl、src/ip、src/pin 里增删了文件，又不想在 TD 里一个个手动 Add 的时候。
# 注意：TD 必须关闭（TD 开着会用内存里的版本覆盖）；会整个重写 .al，TD 里手工改过的工程设置会丢，
#       需要保留的设置写在下面的 <Configurations> / <Runs> 模板里。
# 用法：bash tools/gen_al.sh            （顶层模块默认 mctop，可用 TOP_MODULE=xxx 覆盖）
# =============================================================================
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/../mcproject_code" || exit 1
OUT=MinecraftDog_FPGA.al
TOP_MODULE=${TOP_MODULE:-mctop}

emit_file() { # 路径  design|constraint  编译序号
  local set_name="design_1"; [ "$2" = "constraint" ] && set_name="constraint_1"
  cat <<EOF
            <File Path="$1">
                <FileInfo>
                    <Attr Name="UsedInSyn" Val="true"/>
                    <Attr Name="UsedInP&R" Val="true"/>
                    <Attr Name="BelongTo" Val="$set_name"/>
                    <Attr Name="CompileOrder" Val="$3"/>
                </FileInfo>
            </File>
EOF
}

is_sv() { # 厂商工程里按 SystemVerilog 登记的文件（MIPI D-PHY 封装），其余按 Verilog
  case "$1" in
    *.sv) return 0;;
    src/rtl/video/rx/mipi_dphy_rx/*) return 0;;
    src/rtl/video/disp/mipi_dphy_tx/hs_tx_wrapper_merge.enc.v) return 1;;
    src/rtl/video/disp/mipi_dphy_tx/*) return 0;;
  esac
  return 1
}

ALL=$( (echo src/rtl/mctop.v; find src/rtl -type f \( -name '*.v' -o -name '*.sv' \) ! -path 'src/rtl/mctop.v' | sort) )
{
cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<Project Version="3" Minor="2" Path="E:/FPGA/MinecraftDog/mcproject_code">
    <Project_Created_Time></Project_Created_Time>
    <TD_Version>6.2.175876</TD_Version>
    <Name>MinecraftDog_FPGA</Name>
    <HardWare>
        <Family>PH1</Family>
        <Device>PH1P35MDG324</Device>
        <Speed>-3</Speed>
    </HardWare>
    <Source_Files>
        <Verilog>
EOF
N=0
while read -r f; do is_sv "$f" || { N=$((N+1)); emit_file "$f" design $N; }; done <<< "$ALL"
echo "        </Verilog>"
echo "        <System_Verilog>"
while read -r f; do is_sv "$f" && { N=$((N+1)); emit_file "$f" design $N; }; done <<< "$ALL"
echo "        </System_Verilog>"
echo "        <ADC_FILE>"
C=0; for f in $(find src/pin -type f -name '*.adc' | sort); do C=$((C+1)); emit_file "$f" constraint $C; done
echo "        </ADC_FILE>"
echo "        <SDC_FILE>"
for f in $(find src/pin -type f -name '*.sdc' | sort); do C=$((C+1)); emit_file "$f" constraint $C; done
echo "        </SDC_FILE>"
echo "        <IP_FILE>"
for f in $(find src/ip -maxdepth 2 -type f \( -name '*.xml' -o -name '*.ipc' \) ! -name 'Design*.xml' | sort); do N=$((N+1)); emit_file "$f" design $N; done
echo "        </IP_FILE>"
cat <<EOF
    </Source_Files>
    <FileSets>
        <FileSet Name="design_1" Type="DesignFiles">
        </FileSet>
        <FileSet Name="constraint_1" Type="ConstrainFiles">
        </FileSet>
    </FileSets>
    <TOP_MODULE>
        <LABEL>$TOP_MODULE</LABEL>
        <MODULE>$TOP_MODULE</MODULE>
        <CREATEINDEX>user</CREATEINDEX>
    </TOP_MODULE>
    <Property>
    </Property>
    <Device_Settings>
    </Device_Settings>
    <Configurations>
        <Control0>
            <mclk_freq>33MHz</mclk_freq>
        </Control0>
        <FeatureRow>
            <boot_mode>mspix4</boot_mode>
        </FeatureRow>
    </Configurations>
    <Runs>
        <Run Name="syn_1" Type="Synthesis" ConstraintSet="constraint_1" Description="" Active="true">
            <Strategy Name="Default_Synthesis_Strategy">
            </Strategy>
            <UserParams>
            </UserParams>
        </Run>
        <Run Name="phy_1" Type="PhysicalDesign" ConstraintSet="constraint_1" Description="" SynRun="syn_1" Active="true">
            <Strategy Name="Default_PhysicalDesign_Strategy">
                <BitgenProperty::GeneralOption>
                    <compress>on</compress>
                </BitgenProperty::GeneralOption>
            </Strategy>
            <UserParams>
            </UserParams>
        </Run>
    </Runs>
    <Project_Settings>
    </Project_Settings>
</Project>
EOF
} > "$OUT.new" && mv "$OUT.new" "$OUT"
echo "已生成 $OUT：共 $(grep -c '<File Path' $OUT) 个文件"
