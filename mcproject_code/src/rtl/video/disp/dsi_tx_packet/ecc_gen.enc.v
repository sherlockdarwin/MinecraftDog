

module ecc_gen (
    input wire       I_clk,
    input wire       I_rst,

    input wire[23:0] I_ecc_data_in,
    output reg[7:0]  O_ecc_data_out
);

`pragma protect begin_protected
`pragma protect version = 1
`pragma protect encrypt_agent = "Anlogic"
`pragma protect encrypt_agent_info = "Anlogic Encryption Tool anlogic_2019"
`pragma protect key_keyowner = "Anlogic", key_keyname = "anlogic-rsa-001"
`pragma protect key_method = "rsa"
`pragma protect encoding = (enctype = "BASE64", line_length = 64, bytes = 128)
`pragma protect key_block
DFpFpqOrCEIi6o5CJ35L00RghJq6/XiguMseyHaJBTOaSHEfc0QHZ2vEtubmKsoy
FqhSQdFCFo/r/fPa6laWHBAqovXl7slXkbFw2wBkcgM7+t4h3mZsZzirvq23cBcv
ZDDcohxcxw5IEk1EyJvIqKCcoZMaWGC7igtcFXfth0w=
`pragma protect key_keyowner = "Cadence Design Systems.", key_keyname = "CDS_RSA_KEY_VER_1"
`pragma protect key_method = "rsa"
`pragma protect encoding = (enctype = "BASE64", line_length = 64, bytes = 256)
`pragma protect key_block
YwN3VX8lTJ73sIPR0NTThNaB/L6bD69gRIunHDJTyejQVShvx6PM3YUz4Nns1CF6
dAjJhRwEjku539DNcbAUz/iS6qKvLRwa4gpQxjKRlBV2h4HQ6tyImPVzGDjNgVBt
4Y6nGiMNXAKRxZ1PGoIGyNP3tIjY4Jd64qtalfN8yCrw5Z6nab2NaqUa4/PIVRnP
6Mz1LnCaVnI5kVa4oMTOsiXkbmNpzsdIEVPKWLmAzHmkm53j4g5NuSoi1SCUH8C1
TCjEuObgF478WN3DSFR0huvPkgt4Wl2Ub9jjrSgC15TVii0qCht803p/BVFWnura
6ehiX/kPVXgiN3aqipRNng==
`pragma protect key_keyowner = "Mentor Graphics Corporation", key_keyname = "MGC-VERIF-SIM-RSA-1"
`pragma protect key_method = "rsa"
`pragma protect encoding = (enctype = "BASE64", line_length = 64, bytes = 128)
`pragma protect key_block
Uo3mg7oK35Qt203yG3prg8uvKlx3bMekOIkg/RtXKwqY3tDgHilNj6QaM1UvTe+q
fR3pQSAcRLEiganspQC1BGAZx1mlB5IqC3EviwluS+LmQJ80pRMb3nMfVBmYx++H
UFzbRmkBWmgGnjfmnbzwXO9q4QySSWhRBLn3kXD1ZgQ=
`pragma protect key_keyowner = "Mentor Graphics Corporation", key_keyname = "MGC-VERIF-SIM-RSA-2"
`pragma protect key_method = "rsa"
`pragma protect encoding = (enctype = "BASE64", line_length = 64, bytes = 256)
`pragma protect key_block
m7S7GewhbJbZRKwtOlzrLH4au5pH9E7ZYXR37OW860a9DOn/vGTU0fvvCYcOzZqn
dJEBCs1Mw1EK5ZS4o5yFNvvo/N7d3LXUQBQpm5rbrzOTV/DtZcKzjKEsNHxMG2p2
mYVYut5chlZSORs/8Uisg+sHGjeCGn4e+UsWd61CpPmTa0xfA7QtelKQHa57x33p
0/W9tuvG/j4/U0+7caB3b5pHwrf7uboUxwuT8CjnnVo7EUQ1G+outZLw1I36QMEH
MR0zAa4Kz+PnUpadXa0C+hDHfJDuIG2tSbuTT50BIdEN50qwnnMraoSJmNwLdqr1
NFj3a6MCjAM529GPOk4m1w==
`pragma protect key_keyowner = "Synopsys", key_keyname = "SNPS-VCS-RSA-2"
`pragma protect key_method = "rsa"
`pragma protect encoding = (enctype = "BASE64", line_length = 64, bytes = 128)
`pragma protect key_block
sjHtb4DlAn6WCWTwEfW+oi1uWpagk3Qyl5HIhoSL5Ffzh9FfBC0wc4NRKIhYhOI8
pzb+cKIFzqzPdwSkQ0jLn5xs5yI/lb+1KL5zQRSD9mzWSHD24/cef2mmM1MfMRGz
Z5zZdpVDhsmTYi1a8O6xOFm631fCiST9XX2pb/C/uis=
`pragma protect data_method = "AES128-CBC"
`pragma protect encoding = (enctype = "BASE64", line_length = 64, bytes = 2000)
`pragma protect data_block
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
`pragma protect end_protected

endmodule