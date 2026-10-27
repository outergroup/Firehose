#!/usr/bin/env python3
import pathlib, subprocess, tempfile, struct
root=pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as temporary:
    work=pathlib.Path(temporary)
    subprocess.run(['cc','-std=gnu17','-O1','-g','-fsanitize=address,undefined',str(root/'Tests/ContainerEventsTest.c'),'-lpthread','-lm','-o',str(work/'test')],check=True)
    subprocess.run([str(work/'test'),str(work/'events.bin')],check=True)
    b=(work/'events.bin').read_bytes()
    def text(offset):
        start,size=struct.unpack_from('<II',b,offset);assert start+size<=len(b);return b[start:start+size].decode()
    assert struct.unpack_from('<I',b,24)[0]==1
    assert struct.unpack_from('<I',b,28)[0]==88
    assert text(72+64)=='Test café' and text(72+72)=='test-container'
    assert struct.unpack_from('<Q',b,72+80)[0]==456
    print('PASS binary event container identity and cgroup ID')
