#!/usr/bin/env python3
"""
Generate the Bitcoin Core source-of-truth address vectors for the 39 multisig
output descriptors that passed `getdescriptorinfo` validation.

For each ORIGINAL descriptor string (verbatim, no path reconstruction) we ask
bitcoin-cli `deriveaddresses` for index 0 and record only the chain(s) the
string actually encodes:

  * multipath `<0;1>/*`        -> receive[0] (chain 0) AND change[0] (chain 1)
  * single chain `.../0/*`     -> receive[0] only   (change = null)
  * single chain `.../1/*`     -> change[0] only     (receive = null)
  * anything else (no wildcard / irregular path) -> recorded best-effort with a note

bitcoin-cli requires a checksum, so when the original has none we append the
BIP-380 checksum computed over the *verbatim* string (no h->' normalization).

The daemons run offline (-connect=0 -listen=0 -dnsseed=0) against a throwaway
data directory, on their own RPC port, and are stopped afterwards.

Output: descriptor_address_vectors.json next to this script, with index 0 only.
Run gen_address_ranges.py next to add indexes 0-4:

  python3 birchTests/Fixtures/gen_address_vectors.py
  python3 birchTests/Fixtures/gen_address_ranges.py
"""

import json
import os
import shutil
import subprocess
import tempfile
import time

# --- BIP-380 descriptor checksum (verbatim, matches Bitcoin Core) ---
INPUT_CHARSET = "0123456789()[],'/*abcdefgh@:$%{}IJKLMNOPQRSTUVWXYZ&+-.;<=>?!^_|~ijklmnopqrstuvwxyzABCDEFGH`#\"\\ "
CHECKSUM_CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
GEN = [0xf5dee51989, 0xa9fdca3312, 0x1bab10e32d, 0x3706b1677a, 0x644d626ffd]


def _polymod(symbols):
    chk = 1
    for v in symbols:
        top = chk >> 35
        chk = ((chk & 0x7ffffffff) << 5) ^ v
        for i in range(5):
            chk ^= GEN[i] if ((top >> i) & 1) else 0
    return chk


def descsum_create(s):
    groups, symbols = [], []
    for c in s:
        if c not in INPUT_CHARSET:
            return None
        v = INPUT_CHARSET.index(c)
        symbols.append(v & 31)
        groups.append(v >> 5)
        if len(groups) == 3:
            symbols.append(groups[0] * 9 + groups[1] * 3 + groups[2])
            groups = []
    if len(groups) == 1:
        symbols.append(groups[0])
    elif len(groups) == 2:
        symbols.append(groups[0] * 3 + groups[1])
    checksum = _polymod(symbols + [0] * 8) ^ 1
    return ''.join(CHECKSUM_CHARSET[(checksum >> (5 * (7 - i))) & 31] for i in range(8))


def with_checksum(desc):
    """Return desc with a valid checksum. Preserve an existing one verbatim."""
    if '#' in desc:
        return desc
    return desc + '#' + descsum_create(desc)


# --- bitcoind / bitcoin-cli orchestration (also used by gen_address_ranges.py) ---
RPC_PORT = {'mainnet': 28632, 'testnet4': 28633}
NET_FLAG = {'mainnet': None, 'testnet4': '-testnet4'}


def cli(network, datadir, *args):
    cmd = ['bitcoin-cli', f'-datadir={datadir}', f'-rpcport={RPC_PORT[network]}']
    if NET_FLAG[network]:
        cmd.append(NET_FLAG[network])
    cmd += list(args)
    p = subprocess.run(cmd, capture_output=True, text=True)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def start_daemon(network, datadir):
    cmd = ['bitcoind', '-daemon', f'-datadir={datadir}', f'-rpcport={RPC_PORT[network]}',
           '-connect=0', '-listen=0', '-dnsseed=0', '-maxconnections=0']
    if NET_FLAG[network]:
        cmd.append(NET_FLAG[network])
    subprocess.run(cmd, capture_output=True, text=True)
    for _ in range(30):
        rc, _out, _err = cli(network, datadir, 'getblockcount')
        if rc == 0:
            return True
        time.sleep(1)
    return False


def stop_daemon(network, datadir):
    cli(network, datadir, 'stop')
    time.sleep(3)


# --- The 39 valid descriptors (original index in the vector file -> string) ---
DESCRIPTORS = {
    1: "wsh(sortedmulti(2,xpub6ERApfZwUNrhLCkDtcHTcxd75RbzS1ed54G1LkBUHQVHQKqhMkhgbmJbZRkrgZw4koxb5JaHWkY4ALHY2grBGRjaDMzQLcgJvLJuZZvRcEL/*,xpub68NZiKmJWnxxS6aaHmn81bvJeTESw724CRDs6HbuccFQN9Ku14VQrADWgqbhhTHBaohPX4CjNLf9fq9MYo6oDaPPLPxSb7gwQN3ih19Zm4Y/0/0/*))",
    2: "wsh(sortedmulti(1,xpub661MyMwAqRbcFW31YEwpkMuc5THy2PSt5bDMsktWQcFF8syAmRUapSCGu8ED9W6oDMSgv6Zz8idoc4a6mr8BDzTJY47LJhkJ8UB7WEGuduB/1/0/*,xpub69H7F5d8KSRgmmdJg2KhpAK8SR3DjMwAdkxj3ZuxV27CprR9LgpeyGmXUbC6wb7ERfvrnKZjXoUmmDznezpbZb7ap6r1D3tgFxHmwMkQTPH/0/0/*))",
    3: "wsh(sortedmulti(2,[6738736c/48'/0'/0'/2']xpub6FC1fXFP1GXLX5TKtcjHGT4q89SDRehkQLtbKJ2PzWcvbBHtyDsJPLtpLtkGqYNYZdVVAjRQ5kug9CsapegmmeRutpP7PW4u4wVF9JfkDhw/<0;1>/*,[b2b1f0cf/48'/0'/0'/2']xpub6EWhjpPa6FqrcaPBuGBZRJVjzGJ1ZsMygRF26RwN932Vfkn1gyCiTbECVitBjRCkexEvetLdiqzTcYimmzYxyR1BZ79KNevgt61PDcukmC7/<0;1>/*))",
    4: "wsh(sortedmulti(2,[6738736c/48'/0'/0'/2']xpub6FC1fXFP1GXLX5TKtcjHGT4q89SDRehkQLtbKJ2PzWcvbBHtyDsJPLtpLtkGqYNYZdVVAjRQ5kug9CsapegmmeRutpP7PW4u4wVF9JfkDhw,[b2b1f0cf/48'/0'/0'/2']xpub6EWhjpPa6FqrcaPBuGBZRJVjzGJ1ZsMygRF26RwN932Vfkn1gyCiTbECVitBjRCkexEvetLdiqzTcYimmzYxyR1BZ79KNevgt61PDcukmC7))",
    5: "wsh(sortedmulti(2,03a0434d9e47f3c86235477c7b1ae6ae5d3442d49b1943c2b752a68e2a47e247c7,036d2b085e9e382ed10b69fc311a03f8641ccfff21574de0927513a49d9a688a00,02e8445082a72f29b75ca48748a914df60622a609cacfce8ed0e35804560741d29))#hfj7wz7l",
    6: "wsh(sortedmulti(2,[dc567276/48h/0h/0h/2h]xpub6DiYrfRwNnjeX4vHsWMajJVFKrbEEnu8gAW9vDuQzgTWEsEHE16sGWeXXUV1LBWQE1yCTmeprSNcqZ3W74hqVdgDbtYHUv3eM4W2TEUhpan/<0;1>/*,[f245ae38/48h/0h/0h/2h]xpub6DnT4E1fT8VxuAZW29avMjr5i99aYTHBp9d7fiLnpL5t4JEprQqPMbTw7k7rh5tZZ2F5g8PJpssqrZoebzBChaiJrmEvWwUTEMAbHsY39Ge/<0;1>/*,[c5d87297/48h/0h/0h/2h]xpub6DjrnfAyuonMaboEb3ZQZzhQ2ZEgaKV2r64BFmqymZqJqviLTe1JzMr2X2RfQF892RH7MyYUbcy77R7pPu1P71xoj8cDUMNhAMGYzKR4noZ/<0;1>/*))",
    8: "wsh(sortedmulti(1,xpub661MyMwAqRbcFW31YEwpkMuc5THy2PSt5bDMsktWQcFF8syAmRUapSCGu8ED9W6oDMSgv6Zz8idoc4a6mr8BDzTJY47LJhkJ8UB7WEGuduB/1/0/*,xpub69H7F5d8KSRgmmdJg2KhpAK8SR3DjMwAdkxj3ZuxV27CprR9LgpeyGmXUbC6wb7ERfvrnKZjXoUmmDznezpbZb7ap6r1D3tgFxHmwMkQTPH/0/0/*))",
    10: "wsh(sortedmulti(2,xpub6ERApfZwUNrhLCkDtcHTcxd75RbzS1ed54G1LkBUHQVHQKqhMkhgbmJbZRkrgZw4koxb5JaHWkY4ALHY2grBGRjaDMzQLcgJvLJuZZvRcEL/0/*,xpub68NZiKmJWnxxS6aaHmn81bvJeTESw724CRDs6HbuccFQN9Ku14VQrADWgqbhhTHBaohPX4CjNLf9fq9MYo6oDaPPLPxSb7gwQN3ih19Zm4Y/0/0/*))",
    11: "wsh(sortedmulti(1,[598da155/48h/1h/0h/2h]tpubDFcMAKmwXTqkk19fKuaxFc1P35NYg2efhqsCyZa1h2g5PmYjvzpiM1v2yrTSBxY54v6Zawp96BHQWSC7ZxXbFXNxRY93MnmzSc2Wc9DTRYC/0/*,[0f056943/48h/1h/0h/2h]tpubDF2rnouQaaYrXF4noGTv6rQYmx87cQ4GrUdhpvXkhtChwQPbdGTi8GA88NUaSrwZBwNsTkC9bFkkC8vDyGBVVAQTZ2AS6gs68RQXtXcCvkP/0/*))#rah27k5g",
    12: "wsh(sortedmulti(1,[598da155/48h/1h/0h/2h]tpubDFcMAKmwXTqkk19fKuaxFc1P35NYg2efhqsCyZa1h2g5PmYjvzpiM1v2yrTSBxY54v6Zawp96BHQWSC7ZxXbFXNxRY93MnmzSc2Wc9DTRYC/1/*,[0f056943/48h/1h/0h/2h]tpubDF2rnouQaaYrXF4noGTv6rQYmx87cQ4GrUdhpvXkhtChwQPbdGTi8GA88NUaSrwZBwNsTkC9bFkkC8vDyGBVVAQTZ2AS6gs68RQXtXcCvkP/1/*))#6wyws9pa",
    13: "wsh(sortedmulti(2,[effda333/48'/1'/0'/2']tpubDFS7QGevX3YHQZhsTChSdtxK2Njdoh4BBozoUNQc8qxpReHC2HjoPDpLfqsKvJ9SVzfMinhrGLbjzFxBNQoBvSdyAg8ig3bQE9UYwE6pgVi/0/*,[0F056943/48'/1'/0'/2']tpubDF2rnouQaaYrXF4noGTv6rQYmx87cQ4GrUdhpvXkhtChwQPbdGTi8GA88NUaSrwZBwNsTkC9bFkkC8vDyGBVVAQTZ2AS6gs68RQXtXcCvkP/0/*))",
    14: "wsh(sortedmulti(2,[effda333/48h/1h/0h/2h]tpubDFS7QGevX3YHQZhsTChSdtxK2Njdoh4BBozoUNQc8qxpReHC2HjoPDpLfqsKvJ9SVzfMinhrGLbjzFxBNQoBvSdyAg8ig3bQE9UYwE6pgVi/1/*,[0f056943/48h/1h/0h/2h]tpubDF2rnouQaaYrXF4noGTv6rQYmx87cQ4GrUdhpvXkhtChwQPbdGTi8GA88NUaSrwZBwNsTkC9bFkkC8vDyGBVVAQTZ2AS6gs68RQXtXcCvkP/1/*))#jqhq79dd",
    15: "wsh(sortedmulti(2,[0f056943/48h/1h/0h/2h]tpubDF2rnouQaaYrXF4noGTv6rQYmx87cQ4GrUdhpvXkhtChwQPbdGTi8GA88NUaSrwZBwNsTkC9bFkkC8vDyGBVVAQTZ2AS6gs68RQXtXcCvkP/0/*,[7575334b/44h/1h/0h]tpubDCnmwfrYynsdiqpRZ1UNhuVfpbqvxjXgW9JBoAed7nXeGPGUYFTgJDJ83J6QPqyTc6ARq3Tens739SLbjuQmh8NgJmhBQ9gKfgoT8E36Ebt/0/*))#977ap7x5",
    16: "wsh(sortedmulti(2,[0f056943/48h/1h/0h/2h]tpubDF2rnouQaaYrXF4noGTv6rQYmx87cQ4GrUdhpvXkhtChwQPbdGTi8GA88NUaSrwZBwNsTkC9bFkkC8vDyGBVVAQTZ2AS6gs68RQXtXcCvkP/1/*,[7575334b/44h/1h/0h]tpubDCnmwfrYynsdiqpRZ1UNhuVfpbqvxjXgW9JBoAed7nXeGPGUYFTgJDJ83J6QPqyTc6ARq3Tens739SLbjuQmh8NgJmhBQ9gKfgoT8E36Ebt/1/*))#vkk0fv6f",
    17: "wsh(sortedmulti(2,[6f53d49c/44h/1h/0h]tpubDDjsCRDQ9YzyaAq9rspCfq8RZFrWoBpYnLxK6sS2hS2yukqSczgcYiur8Scx4Hd5AZatxTuzMtJQJhchufv1FRFanLqUP7JHwusSSpfcEp2/<0;1>/*,[e6807791/44h/1h/0h]tpubDDAfvogaaAxaFJ6c15ht7Tq6ZmiqFYfrSmZsHu7tHXBgnjMZSHAeHSwhvjARNA6Qybon4ksPksjRbPDVp7yXA1KjTjSd5x18KHqbppnXP1s/<0;1>/*,[367c9cfa/44h/1h/0h]tpubDDtPnSgWYk8dDnaDwnof4ehcnjuL5VoUt1eW2MoAed1grPHuXPDnkX1fWMvXfcz3NqFxPbhqNZ3QBdYjLz2hABeM9Z2oqMR1Gt2HHYDoCgh/<0;1>/*))",
    18: "wsh(sortedmulti(2,[6f53d49c/44h/1h/0h]tpubDDjsCRDQ9YzyaAq9rspCfq8RZFrWoBpYnLxK6sS2hS2yukqSczgcYiur8Scx4Hd5AZatxTuzMtJQJhchufv1FRFanLqUP7JHwusSSpfcEp2/0/*,[e6807791/44h/1h/0h]tpubDDAfvogaaAxaFJ6c15ht7Tq6ZmiqFYfrSmZsHu7tHXBgnjMZSHAeHSwhvjARNA6Qybon4ksPksjRbPDVp7yXA1KjTjSd5x18KHqbppnXP1s/0/*,[367c9cfa/44h/1h/0h]tpubDDtPnSgWYk8dDnaDwnof4ehcnjuL5VoUt1eW2MoAed1grPHuXPDnkX1fWMvXfcz3NqFxPbhqNZ3QBdYjLz2hABeM9Z2oqMR1Gt2HHYDoCgh/0/*))#av0kxgw0",
    21: "wsh(sortedmulti(2,[0f056943/48h/1h/0h/2h]tpubDF2rnouQaaYrXF4noGTv6rQYmx87cQ4GrUdhpvXkhtChwQPbdGTi8GA88NUaSrwZBwNsTkC9bFkkC8vDyGBVVAQTZ2AS6gs68RQXtXcCvkP/0/*,[122b6f56/44h/1h/0h]tpubDCmC5bJAfQxjCFrRCG9qzBmz4FDy6SVieb4KZaPD5D8AFx5vYjngiRfJSCds4LzKcpy9Mx3he4uSdfdkJHGZBG2gJqz63ndKj9miiVbYzfc/0/*))#zyueunr0",
    22: "wsh(sortedmulti(2,[0f056943/48h/1h/0h/2h]tpubDF2rnouQaaYrXF4noGTv6rQYmx87cQ4GrUdhpvXkhtChwQPbdGTi8GA88NUaSrwZBwNsTkC9bFkkC8vDyGBVVAQTZ2AS6gs68RQXtXcCvkP/1/*,[122b6f56/44h/1h/0h]tpubDCmC5bJAfQxjCFrRCG9qzBmz4FDy6SVieb4KZaPD5D8AFx5vYjngiRfJSCds4LzKcpy9Mx3he4uSdfdkJHGZBG2gJqz63ndKj9miiVbYzfc/1/*))#tv5t5plj",
    23: "wsh(sortedmulti(2,[effda333/48h/1h/0h/2h]tpubDFS7QGevX3YHQZhsTChSdtxK2Njdoh4BBozoUNQc8qxpReHC2HjoPDpLfqsKvJ9SVzfMinhrGLbjzFxBNQoBvSdyAg8ig3bQE9UYwE6pgVi/0/*,[0f056943/48h/1h/0h/2h]tpubDF2rnouQaaYrXF4noGTv6rQYmx87cQ4GrUdhpvXkhtChwQPbdGTi8GA88NUaSrwZBwNsTkC9bFkkC8vDyGBVVAQTZ2AS6gs68RQXtXcCvkP/0/*))#tnyyskcc",
    24: "wsh(sortedmulti(2,[effda333/48h/1h/0h/2h]tpubDFS7QGevX3YHQZhsTChSdtxK2Njdoh4BBozoUNQc8qxpReHC2HjoPDpLfqsKvJ9SVzfMinhrGLbjzFxBNQoBvSdyAg8ig3bQE9UYwE6pgVi/1/*,[0f056943/48h/1h/0h/2h]tpubDF2rnouQaaYrXF4noGTv6rQYmx87cQ4GrUdhpvXkhtChwQPbdGTi8GA88NUaSrwZBwNsTkC9bFkkC8vDyGBVVAQTZ2AS6gs68RQXtXcCvkP/1/*))#jqhq79dd",
    25: "wsh(sortedmulti(2,[0f056943/48'/1'/0'/2']tpubDF2rnouQaaYrXF4noGTv6rQYmx87cQ4GrUdhpvXkhtChwQPbdGTi8GA88NUaSrwZBwNsTkC9bFkkC8vDyGBVVAQTZ2AS6gs68RQXtXcCvkP/0/*,[122b6f56/44'/1'/0']tpubDCmC5bJAfQxjCFrRCG9qzBmz4FDy6SVieb4KZaPD5D8AFx5vYjngiRfJSCds4LzKcpy9Mx3he4uSdfdkJHGZBG2gJqz63ndKj9miiVbYzfc/0/*))#flsx3jj8",
    26: "wsh(multi(2,xprv9s21ZrQH143K31xYSDQpPDxsXRTUcvj2iNHm5NUtrGiGG5e2DtALGdso3pGz6ssrdK4PFmM8NSpSBHNqPqm55Qn3LqFtT2emdEXVYsCzC2U/2147483647'/0,xprv9vHkqa6EV4sPZHYqZznhT2NPtPCjKuDKGY38FBWLvgaDx45zo9WQRUT3dKYnjwih2yJD9mkrocEZXo1ex8G81dwSM1fwqWpWkeS3v86pgKt/1/2/*,xprv9s21ZrQH143K3QTDL4LXw2F7HEK3wJUD2nW2nRk4stbPy6cq3jPPqjiChkVvvNKmPGJxWUtg6LnF5kejMRNNU3TGtRBeJgk33yuGBxrMPHi/10/20/30/40/*'))",
    27: "wsh(sortedmulti(1,tprv8ZgxMBicQKsPdppqwh6vooJ1Du7JdgkXwbp3tvGdwYE58rdVe2Q7sdjiiH7mcanBgkVX9vgNBNzcbZx35fSBK3B6Z19yK2gwh1WDhqfPmgr/48h/1h/1h/0/*,[721143dc/48h/1h/2h]tpubDD2nPnKDRg6NwikecMFyzPZRSBAKjR2FzcSe46mxWBByShLYwQ19zKpFPL8oMuuwibHXNfuRSknD22xWs7rqf9FShjm8d5SzNNTNpx3Z3kM/0/*))#nvk258vn",
    28: "wsh(sortedmulti(1,tprv8ZgxMBicQKsPdppqwh6vooJ1Du7JdgkXwbp3tvGdwYE58rdVe2Q7sdjiiH7mcanBgkVX9vgNBNzcbZx35fSBK3B6Z19yK2gwh1WDhqfPmgr/48h/1h/1h/1/*,[721143dc/48h/1h/2h]tpubDD2nPnKDRg6NwikecMFyzPZRSBAKjR2FzcSe46mxWBByShLYwQ19zKpFPL8oMuuwibHXNfuRSknD22xWs7rqf9FShjm8d5SzNNTNpx3Z3kM/1/*))#sdw5dkct",
    29: "wsh(multi(20,KzoAz5CanayRKex3fSLQ2BwJpN7U52gZvxMyk78nDMHuqrUxuSJy,KwGNz6YCCQtYvFzMtrC6D3tKTKdBBboMrLTsjr2NYVBwapCkn7Mr,KxogYhiNfwxuswvXV66eFyKcCpm7dZ7TqHVqujHAVUjJxyivxQ9X,L2BUNduTSyZwZjwNHynQTF14mv2uz2NRq5n5sYWTb4FkkmqgEE9f,L1okJGHGn1kFjdXHKxXjwVVtmCMR2JA5QsbKCSpSb7ReQjezKeoD,KxDCNSST75HFPaW5QKpzHtAyaCQC7p9Vo3FYfi2u4dXD1vgMiboK,L5edQjFtnkcf5UWURn6UuuoFrabgDQUHdheKCziwN42aLwS3KizU,KzF8UWFcEC7BYTq8Go1xVimMkDmyNYVmXV5PV7RuDicvAocoPB8i,L3nHUboKG2w4VSJ5jYZ5CBM97oeK6YuKvfZxrefdShECcjEYKMWZ,KyjHo36dWkYhimKmVVmQTq3gERv3pnqA4xFCpvUgbGDJad7eS8WE,KwsfyHKRUTZPQtysN7M3tZ4GXTnuov5XRgjdF2XCG8faAPmFruRF,KzCUbGhN9LJhdeFfL9zQgTJMjqxdBKEekRGZX24hXdgCNCijkkap,KzgpMBwwsDLwkaC5UrmBgCYaBD2WgZ7PBoGYXR8KT7gCA9UTN5a3,KyBXTPy4T7YG4q9tcAM3LkvfRpD1ybHMvcJ2ehaWXaSqeGUxEdkP,KzJDe9iwJRPtKP2F2AoN6zBgzS7uiuAwhWCfGdNeYJ3PC1HNJ8M8,L1xbHrxynrqLKkoYc4qtoQPx6uy5qYXR5ZDYVYBSRmCV5piU3JG9,KzRedjSwMggebB3VufhbzpYJnvHfHe9kPJSjCU5QpJdAW3NSZxYS,Kyjtp5858xL7JfeV4PNRCKy2t6XvgqNNepArGY9F9F1SSPqNEMs3,L2D4RLHPiHBidkHS8ftx11jJk1hGFELvxh8LoxNQheaGT58dKenW,KyLPZdwY4td98bKkXqEXTEBX3vwEYTQo1yyLjX2jKXA63GBpmSjv))",
    30: "wsh(multi(16,03669b8afcec803a0d323e9a17f3ea8e68e8abe5a278020a929adbec52421adbd0,0260b2003c386519fc9eadf2b5cf124dd8eea4c4e68d5e154050a9346ea98ce600,0362a74e399c39ed5593852a30147f2959b56bb827dfa3e60e464b02ccf87dc5e8,0261345b53de74a4d721ef877c255429961b7e43714171ac06168d7e08c542a8b8,02da72e8b46901a65d4374fe6315538d8f368557dda3a1dcf9ea903f3afe7314c8,0318c82dd0b53fd3a932d16e0ba9e278fcc937c582d5781be626ff16e201f72286,0297ccef1ef99f9d73dec9ad37476ddb232f1238aff877af19e72ba04493361009,02e502cfd5c3f972fe9a3e2a18827820638f96b6f347e54d63deb839011fd5765d,03e687710f0e3ebe81c1037074da939d409c0025f17eb86adb9427d28f0f7ae0e9,02c04d3a5274952acdbc76987f3184b346a483d43be40874624b29e3692c1df5af,02ed06e0f418b5b43a7ec01d1d7d27290fa15f75771cb69b642a51471c29c84acd,036d46073cbb9ffee90473f3da429abc8de7f8751199da44485682a989a4bebb24,02f5d1ff7c9029a80a4e36b9a5497027ef7f3e73384a4a94fbfe7c4e9164eec8bc,02e41deffd1b7cce11cde209a781adcffdabd1b91c0ba0375857a2bfd9302419f3,02d76625f7956a7fc505ab02556c23ee72d832f1bac391bcd2d3abce5710a13d06,0399eb0a5487515802dc14544cf10b3666623762fbed2ec38a3975716e2c29c232))",
    34: "wsh(sortedmulti(1,[598da155/48'/1'/0'/2']tpubDFcMAKmwXTqkk19fKuaxFc1P35NYg2efhqsCyZa1h2g5PmYjvzpiM1v2yrTSBxY54v6Zawp96BHQWSC7ZxXbFXNxRY93MnmzSc2Wc9DTRYC,[0f056943/48'/1'/0'/2']tpubDF2rnouQaaYrXF4noGTv6rQYmx87cQ4GrUdhpvXkhtChwQPbdGTi8GA88NUaSrwZBwNsTkC9bFkkC8vDyGBVVAQTZ2AS6gs68RQXtXcCvkP))",
    35: "wsh(sortedmulti(2,[dc567276/48h/0h/0h/2h]xpub6DiYrfRwNnjeX4vHsWMajJVFKrbEEnu8gAW9vDuQzgTWEsEHE16sGWeXXUV1LBWQE1yCTmeprSNcqZ3W74hqVdgDbtYHUv3eM4W2TEUhpan,[f245ae38/48h/0h/0h/2h]xpub6DnT4E1fT8VxuAZW29avMjr5i99aYTHBp9d7fiLnpL5t4JEprQqPMbTw7k7rh5tZZ2F5g8PJpssqrZoebzBChaiJrmEvWwUTEMAbHsY39Ge,[c5d87297/48h/0h/0h/2h]xpub6DjrnfAyuonMaboEb3ZQZzhQ2ZEgaKV2r64BFmqymZqJqviLTe1JzMr2X2RfQF892RH7MyYUbcy77R7pPu1P71xoj8cDUMNhAMGYzKR4noZ))",
    37: "wsh(sortedmulti(2,[effda333/48'/1'/0'/2']tpubDFS7QGevX3YHQZhsTChSdtxK2Njdoh4BBozoUNQc8qxpReHC2HjoPDpLfqsKvJ9SVzfMinhrGLbjzFxBNQoBvSdyAg8ig3bQE9UYwE6pgVi/0/*,[0f056943/48h/1h/0h/2h]tpubDF2rnouQaaYrXF4noGTv6rQYmx87cQ4GrUdhpvXkhtChwQPbdGTi8GA88NUaSrwZBwNsTkC9bFkkC8vDyGBVVAQTZ2AS6gs68RQXtXcCvkP/0/*))",
    38: "wsh(sortedmulti(2,[0f056943/48h/0h/0h/2h]xpub6FQgdFZAHcAeAhQX2VvQ42CW2fDdKDhgwzhzXuUhWb4yfArmaZXkLbGS9W1UcgHwNxVESCS1b8BK8tgNYEF8cgmc9zkmsE45QSEvbwdp6Kr/0/*,[2b9f7430/48h/0h/0h/2h]xpub6Esni1Nj4FERhf3mEcWKGDfK7AVdAom4YcQm5g6zQh3Aq7BQRZKECJvcacUm16H9cEgqAFbZYhbVH7Qk8926sH9LhuwwJixZ3dHMQgkwA12/0/*,[88deb18a/48h/0h/0h/2h]xpub6FAz5gG14JMgNGcokjb4ZS7YctPdYmnminC6FSEe9NJcLfu175LKM7tAb5VxVqZTHPpPyZhjyojb3TkHcEnFfek7Aaru4Rn3T5bKTw1gTEL/0/*))#f3e6sh35",
    39: "wsh(sortedmulti(2,xprv9s21ZrQH143K31xYSDQpPDxsXRTUcvj2iNHm5NUtrGiGG5e2DtALGdso3pGz6ssrdK4PFmM8NSpSBHNqPqm55Qn3LqFtT2emdEXVYsCzC2U/2147483647'/0,xprv9vHkqa6EV4sPZHYqZznhT2NPtPCjKuDKGY38FBWLvgaDx45zo9WQRUT3dKYnjwih2yJD9mkrocEZXo1ex8G81dwSM1fwqWpWkeS3v86pgKt/1/2/*))",
    41: "wsh(sortedmulti(2,[6738736c/48'/0'/0'/2']xpub6FC1fXFP1GXLX5TKtcjHGT4q89SDRehkQLtbKJ2PzWcvbBHtyDsJPLtpLtkGqYNYZdVVAjRQ5kug9CsapegmmeRutpP7PW4u4wVF9JfkDhw,[b2b1f0cf/48'/0'/0'/2']xpub6EWhjpPa6FqrcaPBuGBZRJVjzGJ1ZsMygRF26RwN932Vfkn1gyCiTbECVitBjRCkexEvetLdiqzTcYimmzYxyR1BZ79KNevgt61PDcukmC7))",
    43: "wsh(sortedmulti(2,xpub6ERApfZwUNrhLCkDtcHTcxd75RbzS1ed54G1LkBUHQVHQKqhMkhgbmJbZRkrgZw4koxb5JaHWkY4ALHY2grBGRjaDMzQLcgJvLJuZZvRcEL/1/*,xpub68NZiKmJWnxxS6aaHmn81bvJeTESw724CRDs6HbuccFQN9Ku14VQrADWgqbhhTHBaohPX4CjNLf9fq9MYo6oDaPPLPxSb7gwQN3ih19Zm4Y/1/0/*))",
    44: "wsh(sortedmulti(1,xpub661MyMwAqRbcFW31YEwpkMuc5THy2PSt5bDMsktWQcFF8syAmRUapSCGu8ED9W6oDMSgv6Zz8idoc4a6mr8BDzTJY47LJhkJ8UB7WEGuduB/1/0/*,xpub69H7F5d8KSRgmmdJg2KhpAK8SR3DjMwAdkxj3ZuxV27CprR9LgpeyGmXUbC6wb7ERfvrnKZjXoUmmDznezpbZb7ap6r1D3tgFxHmwMkQTPH/0/0/*))",
    45: "wsh(sortedmulti(2,[0f056943/48h/1h/0h/2h]tpubDF2rnouQaaYrXF4noGTv6rQYmx87cQ4GrUdhpvXkhtChwQPbdGTi8GA88NUaSrwZBwNsTkC9bFkkC8vDyGBVVAQTZ2AS6gs68RQXtXcCvkP/1/*,[effda333/48h/1h/0h/2h]tpubDFS7QGevX3YHQZhsTChSdtxK2Njdoh4BBozoUNQc8qxpReHC2HjoPDpLfqsKvJ9SVzfMinhrGLbjzFxBNQoBvSdyAg8ig3bQE9UYwE6pgVi/1/*))",
    47: "wsh(sortedmulti(2,[6738736c/48'/0'/0'/2']xpub6FC1fXFP1GXLX5TKtcjHGT4q89SDRehkQLtbKJ2PzWcvbBHtyDsJPLtpLtkGqYNYZdVVAjRQ5kug9CsapegmmeRutpP7PW4u4wVF9JfkDhw/0/*,[b2b1f0cf/48'/0'/0'/2']xpub6EWhjpPa6FqrcaPBuGBZRJVjzGJ1ZsMygRF26RwN932Vfkn1gyCiTbECVitBjRCkexEvetLdiqzTcYimmzYxyR1BZ79KNevgt61PDcukmC7/0/*))",
    48: "wsh(sortedmulti(2,[6738736c/48'/0'/0'/2']xpub6FC1fXFP1GXLX5TKtcjHGT4q89SDRehkQLtbKJ2PzWcvbBHtyDsJPLtpLtkGqYNYZdVVAjRQ5kug9CsapegmmeRutpP7PW4u4wVF9JfkDhw/1/*,[b2b1f0cf/48'/0'/0'/2']xpub6EWhjpPa6FqrcaPBuGBZRJVjzGJ1ZsMygRF26RwN932Vfkn1gyCiTbECVitBjRCkexEvetLdiqzTcYimmzYxyR1BZ79KNevgt61PDcukmC7/1/*))",
    49: "wsh(sortedmulti(2,[6f53d49c/44h/1h/0h]tpubDDjsCRDQ9YzyaAq9rspCfq8RZFrWoBpYnLxK6sS2hS2yukqSczgcYiur8Scx4Hd5AZatxTuzMtJQJhchufv1FRFanLqUP7JHwusSSpfcEp2/1/*,[e6807791/44h/1h/0h]tpubDDAfvogaaAxaFJ6c15ht7Tq6ZmiqFYfrSmZsHu7tHXBgnjMZSHAeHSwhvjARNA6Qybon4ksPksjRbPDVp7yXA1KjTjSd5x18KHqbppnXP1s/1/*,[367c9cfa/44h/1h/0h]tpubDDtPnSgWYk8dDnaDwnof4ehcnjuL5VoUt1eW2MoAed1grPHuXPDnkX1fWMvXfcz3NqFxPbhqNZ3QBdYjLz2hABeM9Z2oqMR1Gt2HHYDoCgh/1/*))",
    50: "wsh(sortedmulti(2,[0f056943/48h/1h/0h/2h]tpubDF2rnouQaaYrXF4noGTv6rQYmx87cQ4GrUdhpvXkhtChwQPbdGTi8GA88NUaSrwZBwNsTkC9bFkkC8vDyGBVVAQTZ2AS6gs68RQXtXcCvkP/0/*,[7575334b/44h/1h/0h]tpubDCnmwfrYynsdiqpRZ1UNhuVfpbqvxjXgW9JBoAed7nXeGPGUYFTgJDJ83J6QPqyTc6ARq3Tens739SLbjuQmh8NgJmhBQ9gKfgoT8E36Ebt/0/*))#977ap7x5",
}


def is_testnet(desc):
    return ('tpub' in desc) or ('tprv' in desc)


def classify(desc):
    """Return ('multipath'|'receive'|'change'|'fixed'|'irregular')."""
    if '<0;1>/*' in desc:
        return 'multipath'
    if '<1;0>/*' in desc:
        return 'multipath_swapped'
    if '*' not in desc:
        return 'fixed'
    has0 = '/0/*' in desc
    has1 = '/1/*' in desc
    if has0 and not has1:
        return 'receive'
    if has1 and not has0:
        return 'change'
    return 'irregular'


def derive(network, datadir, desc):
    """Return (rc, parsed_json_or_None, raw_text)."""
    checksummed = with_checksum(desc)
    ranged = '*' in desc
    if ranged:
        rc, out, err = cli(network, datadir, 'deriveaddresses', checksummed, '[0,0]')
    else:
        rc, out, err = cli(network, datadir, 'deriveaddresses', checksummed)
    if rc != 0:
        return rc, None, (out + ' ' + err).strip()
    try:
        return rc, json.loads(out), out
    except json.JSONDecodeError:
        return rc, None, out


def process_group(network, datadir, items, results):
    for idx, desc in items:
        kind = classify(desc)
        entry = {
            'index': idx,
            'network': network,
            'descriptor': desc,
            'kind': kind,
            'receive': None,
            'change': None,
            'error': None,
            'note': None,
        }
        rc, parsed, raw = derive(network, datadir, desc)
        if rc != 0 or parsed is None:
            entry['error'] = raw
        elif kind in ('multipath', 'multipath_swapped'):
            # parsed = [[chainA0], [chainB0]]
            try:
                a = parsed[0][0]
                b = parsed[1][0]
                if kind == 'multipath':
                    entry['receive'], entry['change'] = a, b
                else:
                    entry['receive'], entry['change'] = b, a
            except (IndexError, TypeError, KeyError):
                entry['error'] = 'unexpected multipath shape: ' + raw
        elif kind == 'receive':
            entry['receive'] = parsed[0]
        elif kind == 'change':
            entry['change'] = parsed[0]
        elif kind == 'fixed':
            entry['receive'] = parsed[0]
            entry['note'] = 'fixed (no wildcard) — single address, no separate change chain'
        else:  # irregular
            entry['receive'] = parsed[0]
            entry['note'] = 'irregular derivation path — index-0 address recorded under receive'
        results[idx] = entry
        tag = entry['error'] if entry['error'] else f"recv={entry['receive']} chg={entry['change']}"
        print(f"  #{idx:>2} [{kind}] {tag}")


def main():
    groups = {
        'mainnet': sorted((i, d) for i, d in DESCRIPTORS.items() if not is_testnet(d)),
        'testnet4': sorted((i, d) for i, d in DESCRIPTORS.items() if is_testnet(d)),
    }
    results = {}

    for network, items in groups.items():
        datadir = tempfile.mkdtemp(prefix=f'birch-vectors-{network}-')
        print(f">>> {network} daemon")
        try:
            if not start_daemon(network, datadir):
                raise SystemExit(f"could not start {network} bitcoind")
            try:
                process_group(network, datadir, items, results)
            finally:
                stop_daemon(network, datadir)
        finally:
            shutil.rmtree(datadir, ignore_errors=True)

    ordered = [results[i] for i in sorted(results)]
    out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            'descriptor_address_vectors.json')
    with open(out_path, 'w') as f:
        json.dump(ordered, f, indent=2)
        f.write('\n')
    print(f"\nWrote {len(ordered)} vectors -> {out_path}")
    oks = sum(1 for e in ordered if e['error'] is None)
    print(f"derived OK: {oks}   errors: {len(ordered) - oks}")


if __name__ == '__main__':
    main()
