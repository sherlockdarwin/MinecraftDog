module crc16_8b (
   input  wire        clk,
   input  wire        rst,
   input  wire        init,
   input  wire [7:0]  din,
   input  wire        din_en,
   output reg  [15:0] crc
);

`pragma protect begin_protected
`pragma protect version = 1
`pragma protect encrypt_agent = "Anlogic"
`pragma protect encrypt_agent_info = "Anlogic Encryption Tool anlogic_2019"
`pragma protect key_keyowner = "Anlogic", key_keyname = "anlogic-rsa-001"
`pragma protect key_method = "rsa"
`pragma protect encoding = (enctype = "BASE64", line_length = 64, bytes = 128)
`pragma protect key_block
pDZZwkD00ZxPDe6yfcs8kt0mz5TryNdi4reWEe/12gJxUyiwl48aPqEQKXRKRgnT
e4G6e8DdgAfj3gpXn829/VY/NKLg2QduJhK64csR7KjhhZoRaKZxKAUXfUJTsCiX
lMbKpEekKTYLwQVjMT6Zi5k4KQAm19Hyb3qJb39TdQs=
`pragma protect key_keyowner = "Cadence Design Systems.", key_keyname = "CDS_RSA_KEY_VER_1"
`pragma protect key_method = "rsa"
`pragma protect encoding = (enctype = "BASE64", line_length = 64, bytes = 256)
`pragma protect key_block
dFOjmC5cmNt5ioADZDL87DcEp4a2hgGYOFCIxrWrtVnY/YluNecHHBHWgZLqDh8y
8uKYCll7XlRa2BRmnDJTeiPIdpT6Vt7ilmE8/tuhoM6jcrNN+7CXJ7Xk9OwfFPQ7
A0eML8cMsAMtSMZc493IJ37ZpUmWmxYIjjaQMB9SKbaRJy4xCijL+zqRWOM7SYx8
FmLJqCMAFwfGO5CEEFK8vh+zJEunpi9WpdjoFE9VIk0g/S1eBipKKWiSK7Qgx2pS
hXb6TqMikiITiAx+J1rqmr6MrWbbsclLNItAos+ofwMJC5r0310G0DCxXXtYbg5v
FFWDL4S2GZnikim6UvUY3g==
`pragma protect key_keyowner = "Mentor Graphics Corporation", key_keyname = "MGC-VERIF-SIM-RSA-1"
`pragma protect key_method = "rsa"
`pragma protect encoding = (enctype = "BASE64", line_length = 64, bytes = 128)
`pragma protect key_block
oReXStkEe2EhUYhS4khzKRSjH9PK7JoC+IFtQ0ZgrNOXYWnOipObx9sYFynpgaIq
hcouSJwCl4cdXB/WI6XUPX5jHp66aJfgQYExyFhjOUhCkovWQSi5as5IH+Vd0Ztc
8wLMtDYLuWQRv79P5jJKSS0tihOXTw1Oko78PRIZLRQ=
`pragma protect key_keyowner = "Mentor Graphics Corporation", key_keyname = "MGC-VERIF-SIM-RSA-2"
`pragma protect key_method = "rsa"
`pragma protect encoding = (enctype = "BASE64", line_length = 64, bytes = 256)
`pragma protect key_block
qQbaiz/ZHFhe7a37bfrYTDqLyCGz1EpaqR9Z1HOYqsN1sfApUxgyrnqyjbdGjGtc
yYQfvvoDL+cy52F6QM+1FnodHUJc2vtl3L2v0UDClF6Rdogs/aXqmjcrE+OufeJP
I4JZyHX0ISbNeRYHcB1bDEfHk63amHeNa3SW6DeMpe+EplfUHLsS3F77Hagb02bX
09kAtSVKM2KEXybMm+it9b4vmWsZrLMC3K+L7sX1to2/AHJ8WUYHdlVrLrBWBVI3
p2pTGVIsLLVnUQzRfyCpq80YDUA+cBoLUvNlwSqnuZgGZgPgQwqs/JhJvLHE3Vjy
Gj0+g2BPEjJCY8JsBliNtQ==
`pragma protect key_keyowner = "Synopsys", key_keyname = "SNPS-VCS-RSA-2"
`pragma protect key_method = "rsa"
`pragma protect encoding = (enctype = "BASE64", line_length = 64, bytes = 128)
`pragma protect key_block
MkONAjITYoaU+rM8abj2aPBflzXDXO0gEIVSv4/yXzP7kokeiYXh1jYTVuFscjbX
YpQ7YqwaHNlXxJWeujEG+2VmZGmkVVHrh5Nc6jC8z9x1r8wSqpq/MIOAKl9+YXQh
ONQpXFOMzGSfwEXlhiNYcVE90AKRgwM79WsLdDgIoF0=
`pragma protect data_method = "AES128-CBC"
`pragma protect encoding = (enctype = "BASE64", line_length = 64, bytes = 2096)
`pragma protect data_block
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
`pragma protect end_protected

endmodule
