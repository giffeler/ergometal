#!/usr/bin/env python3
"""Sequential, offline miner comparisons. Never writes the normal tuning cache.

Each output directory must be new. Group names refer to separate binaries.
The local Stratum peer uses public synthetic work and acknowledges test shares;
it never connects to an external pool. These acknowledgements have no value.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import subprocess as sp
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
ART = ROOT / 'DerivedDataToolchainAudit20260916/artifacts'
TARGET = '000000003f00000003f00000003f00000003f00000003f00000003f00000003f'


def wallet():
    # Public secp256k1 generator point, solely an offline protocol fixture.
    body = bytes.fromhex('010279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798')
    value = int.from_bytes(body + hashlib.blake2b(body, digest_size=32).digest()[:4], 'big')
    result = ''
    alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
    while value:
        value, r = divmod(value, 58); result = alphabet[r] + result
    return result


class Peer:
    def __init__(self, height, interval, duration, output):
        self.height, self.interval, self.duration, self.output = height, interval, duration, output
        self.start_time = None
        self.server = socket.socket()
        self.server.bind(('127.0.0.1', 0)); self.server.listen(1)
        self.port = self.server.getsockname()[1]
        self.stop = threading.Event(); self.started = threading.Event()
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.error = None
        self.thread.start()

    def serve(self):
        try:
            with self.server, self.server.accept()[0] as conn, self.output.open('x') as log:
                conn.settimeout(0.1)
                def send(obj):
                    conn.sendall((json.dumps(obj) + '\n').encode())
                def job(index):
                    fields = [f'audit-{index}', self.height + index,
                              hashlib.sha256(f'ergometal-controlled-job-{index}'.encode()).hexdigest(),
                              '', '', 2, '0x' + TARGET, '', True]
                    send(dict(id=None, method='mining.notify', params=fields))
                    log.write(json.dumps(dict(monotonic=time.monotonic(), job=fields))+'\n'); log.flush()
                buf = b''; start = None; next_index = 1
                while not self.stop.is_set():
                    if (start is not None and self.interval and next_index*self.interval < self.duration
                            and time.monotonic()-start >= next_index*self.interval):
                        job(next_index); next_index += 1
                    try:
                        chunk = conn.recv(65536)
                        if not chunk: break
                        buf += chunk
                    except socket.timeout:
                        continue
                    while b'\n' in buf:
                        line, buf = buf.split(b'\n', 1); request = json.loads(line)
                        method = request.get('method')
                        if method == 'mining.subscribe':
                            send(dict(id=request['id'], result=[[['mining.notify', 'audit']], '', 8], error=None))
                        elif method == 'mining.authorize':
                            send(dict(id=request['id'], result=True, error=None))
                            start = time.monotonic(); self.start_time = start
                            job(0); self.started.set()
                        elif method == 'mining.submit':
                            log.write(json.dumps(dict(monotonic=time.monotonic(), submit=request))+'\n'); log.flush()
                            send(dict(id=request['id'], result=True, error=None))
                        else:
                            raise RuntimeError(f'unexpected method {method}')
        except Exception as exc:
            self.error = repr(exc)
            self.started.set()


def temperature(binary):
    return json.loads(sp.check_output([str(binary), 'temperature', '--json']))


def gate(binary, maximum, output):
    start = time.monotonic(); consecutive = 0
    with output.open('x') as out:
        while True:
            sample = temperature(binary); t = sample.get('maximumCelsius')
            out.write(json.dumps(dict(elapsed=time.monotonic()-start, **sample))+'\n'); out.flush()
            if t is None: raise RuntimeError('temperature unavailable; refusing unmatched start')
            consecutive = consecutive + 1 if t <= maximum else 0
            if consecutive >= 3: return sample
            if time.monotonic()-start > 600: raise RuntimeError('temperature gate timed out; run not started')
            time.sleep(5)


def run(args, label, index):
    parts = label.split(':')
    if not 1 <= len(parts) <= 3: raise ValueError('name[:batch[:search-kernel]] expected')
    variant = parts[0]
    batch = int(parts[1]) if len(parts) > 1 else args.batch
    search_kernel = parts[2] if len(parts) > 2 else 'search'
    if search_kernel not in ('search', 'gather-only'): raise ValueError(search_kernel)
    if args.mode == 'mine' and search_kernel != 'search':
        raise ValueError('Diagnostic kernels are permitted only in benchmark mode')
    binary = (args.artifacts / variant).resolve()
    stem = args.output / f'{index:02d}-{variant}-{batch}'
    initial_temp = gate(binary, args.max_temperature, stem.with_suffix('.gate.ndjson'))
    cmd = [str(binary), args.mode, '--profile', 'peak', '--autotune', 'off',
           '--autotune-cache', str(args.output/'unused-cache.json'), '--prebuild', 'off',
           '--batch-nonces', str(batch), '--prebuild-batch-nonces', '131072',
           '--threadgroup-size', '64', '--dataset-threadgroup-size', '256',
           '--build-chunk-elements', '2097152', '--prefetch-chunk-elements', '1048576',
           '--search-pipeline-depth', '2', '--build-pipeline-depth', '2',
           '--dataset-kernel', 'u32pair-inline-m', '--dataset-scheduling', 'overlap',
           '--api-bind', '127.0.0.1:0', '--stats-file', str(stem.with_suffix('.events.ndjson'))]
    peer = None
    if args.mode == 'benchmark':
        cmd += ['--duration', str(args.duration), '--height', str(args.height), '--search-kernel', search_kernel, '--json']
    else:
        peer = Peer(args.height, args.job_interval, args.duration, stem.with_suffix('.peer.ndjson'))
        cmd += ['--pool', f'stratum+tcp://127.0.0.1:{peer.port}', '--wallet', wallet(),
                '--worker', 'offline-audit', '--network', 'mainnet', '--donation', '0', '--stats-interval', '2']
    power_command = ['sudo', '-n', 'powermetrics', '--samplers',
                     'tasks,gpu_power,cpu_power' if args.process_gpu else 'gpu_power,cpu_power',
                     '-i', '1000', '-n', str(args.duration + 120),
                     '-o', str(stem.with_suffix('.power.txt'))]
    if args.process_gpu: power_command += ['--show-process-gpu']
    metadata = dict(variant=variant, batch=batch, search_kernel=search_kernel, command=cmd, start_temperature=initial_temp,
                    monitoring_command=power_command,
                    binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                    mode=args.mode, duration=args.duration, job_interval=args.job_interval,
                    wall_start=time.time())
    stem.with_suffix('.metadata.json').write_text(json.dumps(metadata, indent=2)+'\n')
    print(f'START {index} {label} temperature={initial_temp["maximumCelsius"]:.2f}', flush=True)
    power = sp.Popen(power_command, stdout=sp.DEVNULL, stderr=sp.DEVNULL)
    with stem.with_suffix('.stdout').open('x') as out, stem.with_suffix('.stderr').open('x') as err, \
         stem.with_suffix('.processes.txt').open('x') as processes:
        child = sp.Popen(['/usr/bin/time', '-lp']+cmd, stdout=out, stderr=err, start_new_session=True)
        try:
            if peer:
                if not peer.started.wait(timeout=20): raise RuntimeError('local handshake timeout')
                if peer.error: raise RuntimeError(peer.error)
            deadline = peer.start_time + args.duration if peer else None
            signaled = False; next_process_sample = 0
            while child.poll() is None:
                now = time.monotonic()
                if now >= next_process_sample:
                    processes.write(f'UNIX_TIME {time.time()}\n')
                    processes.write(sp.check_output(['ps', '-axo', 'pid,ppid,%cpu,%mem,comm'], text=True))
                    processes.flush(); next_process_sample = now+10
                if deadline is not None and now >= deadline and not signaled:
                    os.killpg(child.pid, signal.SIGINT); signaled = True
                if deadline is not None and now > deadline+60: raise RuntimeError('graceful exit timeout')
                time.sleep(0.5)
            code = child.returncode
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGINT)
                child.wait(timeout=60)
            # sudo can have a separate privileged child. Signal only this
            # invocation's process tree, child first, using its recorded PID.
            rows = sp.check_output(['ps', '-axo', 'pid,ppid'], text=True).splitlines()[1:]
            children = {int(row.split()[0]): int(row.split()[1]) for row in rows}
            owned = {power.pid}
            while True:
                expanded = owned | {pid for pid, parent in children.items() if parent in owned}
                if expanded == owned: break
                owned = expanded
            for pid in sorted(owned - {power.pid}):
                sp.run(['sudo', '-n', '/bin/kill', '-TERM', str(pid)], capture_output=True)
            try:
                power.wait(timeout=5)
            except sp.TimeoutExpired:
                sp.run(['sudo', '-n', '/bin/kill', '-TERM', str(power.pid)], capture_output=True)
                power.wait(timeout=5)
            if peer:
                peer.stop.set(); peer.thread.join(timeout=3)
    events = [json.loads(s) for s in stem.with_suffix('.events.ndjson').read_text().splitlines()]
    ends = [x for x in events if x['type'] == 'session_ended']
    if code != 0 or len(ends) != 1: raise RuntimeError(f'failed run {code}, {len(ends)} final events')
    if peer and peer.error: raise RuntimeError(peer.error)
    metadata.update(wall_end=time.time(), exit_code=code, final=ends[0])
    stem.with_suffix('.metadata.json').write_text(json.dumps(metadata, indent=2)+'\n')
    f = ends[0]['fields']
    print(f'END {index} {label} active={float(f["average_hashrate"])/1e6:.5f} '
          f'effective={float(f["effective_hashrate"])/1e6:.5f} '
          f'build={f["dataset_build_seconds"]} peak={f.get("soc_temperature_session_peak_celsius")}', flush=True)


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('output', type=Path)
    p.add_argument('--artifacts', type=Path, default=ART)
    p.add_argument('--sequence', required=True, help='comma separated names, optionally name:batch:search-kernel')
    p.add_argument('--mode', choices=['benchmark', 'mine'], default='benchmark')
    p.add_argument('--duration', type=int, default=120)
    p.add_argument('--height', type=int, default=1873775)
    p.add_argument('--batch', type=int, default=1048576)
    p.add_argument('--job-interval', type=int, default=0)
    p.add_argument('--max-temperature', type=float, default=60)
    p.add_argument('--process-gpu', action='store_true', help='Also request per-process GPU time for a diagnostic sustained run')
    args = p.parse_args(); args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    for index, label in enumerate(args.sequence.split(','), 1): run(args, label, index)
