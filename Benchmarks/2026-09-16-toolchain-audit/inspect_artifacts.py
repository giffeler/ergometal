#!/usr/bin/env python3
"""Hash arm64 Mach-O code/Metal sections and record deployment/SDK versions."""
import argparse
import hashlib
import json
from pathlib import Path
import struct


def inspect(path, dump=None):
    data=path.read_bytes()
    magic,cpu=struct.unpack_from('<II',data)
    assert magic==0xfeedfacf and cpu==0x0100000c, 'expected thin arm64 Mach-O'
    result=dict(path=str(path),size=len(data),sha256=hashlib.sha256(data).hexdigest(),sections={})
    offset=32
    version=lambda v:f'{v>>16}.{(v>>8)&255}.{v&255}'
    for _ in range(struct.unpack_from('<I',data,16)[0]):
        command,size=struct.unpack_from('<II',data,offset)
        if command==0x32:
            platform,minimum,sdk=struct.unpack_from('<III',data,offset+8)
            result['build_version']=dict(platform=platform,minimum_os=version(minimum),sdk=version(sdk))
        if command==0x19:
            for i in range(struct.unpack_from('<I',data,offset+64)[0]):
                start=offset+72+i*80
                name=data[start:start+16].split(b'\0')[0].decode()
                count,position=struct.unpack_from('<QI',data,start+40)
                if name in ('__text','__metallib'):
                    section=data[position:position+count]
                    assert len(section)==count
                    result['sections'][name]=dict(size=count,sha256=hashlib.sha256(section).hexdigest())
                    if dump:
                        (dump/(path.name+'.'+name)).write_bytes(section)
        offset+=size
    return result


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('binaries',nargs='+',type=Path)
    p.add_argument('--dump',type=Path)
    a=p.parse_args()
    if a.dump:a.dump.mkdir(parents=True,exist_ok=True)
    print(json.dumps({f.name:inspect(f,a.dump) for f in a.binaries},indent=2))
