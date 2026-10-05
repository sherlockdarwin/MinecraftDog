
///pcaket mode: Non-Brust Mode with Sync Events

module dsi_video_mode_packet (
    input wire        I_clk,
    input wire        I_rst,
 
    input wire        I_vsync,
    input wire        I_hsync,
    input wire        I_de,
    input wire[31:0]  I_data,

    output reg        O_hs_en,
    output reg[31:0]  O_hs_data,
    output reg        O_hs_last
);

    parameter  H_ACTIVE = 1024;

`pragma protect begin_protected
`pragma protect version = 1
`pragma protect encrypt_agent = "Anlogic"
`pragma protect encrypt_agent_info = "Anlogic Encryption Tool anlogic_2019"
`pragma protect key_keyowner = "Anlogic", key_keyname = "anlogic-rsa-001"
`pragma protect key_method = "rsa"
`pragma protect encoding = (enctype = "BASE64", line_length = 64, bytes = 128)
`pragma protect key_block
JUbMKhqfZaoB/J10IipMm5yj4Q+k46xRbtAsFmzfyZ5BGieaUFPSu2ez3+e6+rtQ
kfAmwg1HAmyrLkgiPPdkredaBs5RZZIX4sGKlln3q7OF2SxVFlRchp6MsTpTMpYO
LpLu6yP0jWePNiA6rguO4EVWoyYKXy2btZB6tagIA0A=
`pragma protect key_keyowner = "Cadence Design Systems.", key_keyname = "CDS_RSA_KEY_VER_1"
`pragma protect key_method = "rsa"
`pragma protect encoding = (enctype = "BASE64", line_length = 64, bytes = 256)
`pragma protect key_block
E6IC2iMtqAJWjffCHCDTcWPP6zv5fEbGTU6AC8/iv66NoOOdbMrOz4Szro3iq3Cq
SV4lDymNUy+40bYUfxbHtMctI1s15BRAjl8ySi5THWk/US71QfaS6bZ43Prvl52R
mXp6ALxOPqbAmUUP82W5czTQ77fqPBCQxUKg7ldsM2CqXgZH3eDCg/d4wlzsT8AH
hH2TZnzuxduya5ST/IJXrBLXaSXsbNb9cc/BG0pTel8vyIKcW11AnY4LUl9MyxQU
cuXvxJ4ijsr38pfJwF23Ky20bSLZRr9Ntm7WnF/2lMAAKZcpfX8sGlgvV4PYKxCB
1vds2ybqw9wav1MWDZryYQ==
`pragma protect key_keyowner = "Mentor Graphics Corporation", key_keyname = "MGC-VERIF-SIM-RSA-1"
`pragma protect key_method = "rsa"
`pragma protect encoding = (enctype = "BASE64", line_length = 64, bytes = 128)
`pragma protect key_block
Pc5kxSKC7sfleJLzcp/vcU4xBs3EAb14Ebp3QsjFjmRY8a7I8EvJ00lishUI3Odl
he9YTgdcSTUMsO90Zr3S4bRNxlUUt+98dZBltdGY3XMBEktTFjHgUvogQ0+30g2g
rr0/VnpuS1K5dcsTQrpQcco2Y0EimveRMd5SNswXagg=
`pragma protect key_keyowner = "Mentor Graphics Corporation", key_keyname = "MGC-VERIF-SIM-RSA-2"
`pragma protect key_method = "rsa"
`pragma protect encoding = (enctype = "BASE64", line_length = 64, bytes = 256)
`pragma protect key_block
b/kd9xfnmswmWpiPPcKHEHCDovmuE/6YsZh4M3G6ZtuCCbEK6innNZpL9pOLVCrs
hymO+nLaw7+ju8FlcHPqTmAYSQyMXop+BZ52pCQbknlzFM8eAOsmInqeVqfkgel/
w2ERinhAlK9LXzotQQ2tXCWjzi8P2usFFE9oJo4ns8FlYESBeBS1F2g0hHq1++TF
kbbhfkY0FgZyloPzFPs4omyeiG5dSPyfUCeq25WX9/lpvkfG1/5LwI/NTilMmibo
+3WwCx5W8k9yvujsGg4YmWgxJcNsm+914PlDitwFxDBPYxM123WDOgKe2et000SV
kiBBVXwyJvYgtBzeSpDeIA==
`pragma protect key_keyowner = "Synopsys", key_keyname = "SNPS-VCS-RSA-2"
`pragma protect key_method = "rsa"
`pragma protect encoding = (enctype = "BASE64", line_length = 64, bytes = 128)
`pragma protect key_block
srS6o0fG2syO0zNzffGhGOLiUXbx74NtdOhNqZVt+T2OVQ+831q9DTmxq7XL1sk0
+1BG6XiQWkQVv+cPig3BK4HHpeRwPc4TxlXnPvkJK0huwIg9NVHX+evDmoyzyXeZ
vd4VLOl4f+RUvU7ZVDQdJy+gwgy9gbOLdPpy+NjAaLQ=
`pragma protect data_method = "AES128-CBC"
`pragma protect encoding = (enctype = "BASE64", line_length = 64, bytes = 3584)
`pragma protect data_block
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
`pragma protect end_protected

endmodule