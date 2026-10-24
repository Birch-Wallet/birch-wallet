#!/usr/bin/env python3
"""
Extend descriptor_address_vectors.json with Bitcoin Core addresses for indexes 0-4.

Companion to gen_address_vectors.py (which records index 0 only). For every
vector whose ORIGINAL descriptor string (verbatim) is ranged and encodes a
receive and/or change chain -- kind `multipath`, `receive` or `change` -- we ask
bitcoin-cli `deriveaddresses "<descriptor>#<checksum>" [0,4]` and add:

  receiveRange: 5 addresses (chain 0, indexes 0-4), or null
  changeRange:  5 addresses (chain 1, indexes 0-4), or null

Index 0 of each range must equal the vector's existing `receive` / `change`
value; the script stops if it does not, so the new data is tied to the
original index-0 run. Nothing else in the file is changed.

sortedmulti re-sorts the derived public keys at every index, so index 0 alone
does not show that key ordering is handled correctly further along the chain.

The daemons run offline (-connect=0 -listen=0 -dnsseed=0) against a throwaway
data directory, on their own RPC port, and are stopped afterwards.

Usage: python3 birchTests/Fixtures/gen_address_ranges.py
"""

import json
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
# No __pycache__ here: this folder is synced into the birchTests bundle.
sys.dont_write_bytecode = True
from gen_address_vectors import cli, start_daemon, stop_daemon, with_checksum  # noqa: E402

VECTORS = os.path.join(HERE, 'descriptor_address_vectors.json')
LAST_INDEX = 4
RANGED_KINDS = ('multipath', 'receive', 'change')


def derive_ranges(network, datadir, entry):
    """Return (receiveRange, changeRange) for one vector, straight from Core."""
    rc, out, err = cli(network, datadir, 'deriveaddresses',
                       with_checksum(entry['descriptor']), f'[0,{LAST_INDEX}]')
    if rc != 0:
        raise SystemExit(f"#{entry['index']}: deriveaddresses failed: {out} {err}")
    parsed = json.loads(out)

    kind = entry['kind']
    if kind == 'multipath':  # [[chain 0 ...], [chain 1 ...]]
        receive, change = parsed[0], parsed[1]
    elif kind == 'receive':
        receive, change = parsed, None
    else:
        receive, change = None, parsed

    for name, addresses, first in (('receive', receive, entry['receive']), ('change', change, entry['change'])):
        if addresses is None:
            continue
        if len(addresses) != LAST_INDEX + 1:
            raise SystemExit(f"#{entry['index']}: expected {LAST_INDEX + 1} {name} addresses, got {len(addresses)}")
        if addresses[0] != first:
            raise SystemExit(f"#{entry['index']}: {name}[0] {addresses[0]} != recorded {first}")
    return receive, change


def main():
    with open(VECTORS) as f:
        vectors = json.load(f)

    ranges = {}
    for network in ('mainnet', 'testnet4'):
        todo = [e for e in vectors if e['network'] == network and e['kind'] in RANGED_KINDS and not e['error']]
        datadir = tempfile.mkdtemp(prefix=f'birch-vectors-{network}-')
        print(f">>> {network} daemon ({len(todo)} ranged vectors)")
        try:
            if not start_daemon(network, datadir):
                raise SystemExit(f"could not start {network} bitcoind")
            try:
                for entry in todo:
                    ranges[entry['index']] = derive_ranges(network, datadir, entry)
                    print(f"  #{entry['index']:>2} [{entry['kind']}] ok")
            finally:
                stop_daemon(network, datadir)
        finally:
            shutil.rmtree(datadir, ignore_errors=True)

    extended = []
    for entry in vectors:
        receive, change = ranges.get(entry['index'], (None, None))
        updated = {}
        for key, value in entry.items():
            if key in ('receiveRange', 'changeRange'):
                continue
            updated[key] = value
            if key == 'change':
                updated['receiveRange'] = receive
                updated['changeRange'] = change
        extended.append(updated)

    with open(VECTORS, 'w') as f:
        json.dump(extended, f, indent=2)
        f.write('\n')
    print(f"\nAdded ranges to {len(ranges)} of {len(extended)} vectors -> {os.path.normpath(VECTORS)}")


if __name__ == '__main__':
    main()
