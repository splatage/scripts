#!/usr/bin/env python3

# SSH-Bench
# v 0.1 by TwoGate inc. https://twogate.com
# MIT license

# A benchmarking script for ssh.
# Tests in various ssh ciphers, MACs, key exchange algorithms.
# You can change settings in "configuration section" in this file.
# Note that result csv file will be overwrote if already exists.
# more details on: https://blog.twogate.com/entry/2020/07/30/073946

import subprocess
import argparse
import time
import os
import csv

parser = argparse.ArgumentParser()
parser.add_argument("host", type=str,
                    help="hostname")
args = parser.parse_args()

host = args.host

#### configuration section ######
# a reason of disabling compression:
#     you can't test with compression enabled.
#     transferred data is absolutly random (high entropy) which can't be compressed.
# a reason of using scp:
#     yes i know that scp is outdated today, but sftp is complex to use from programs.
#     rsync can't write out to /dev/null. that's why i use scp.
transfer_file = "/tmp/ssh-bench-random-data"
ssh_command_prefix = ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "Compression=no"]
ssh_command_suffix = [host, ":"]
scp_command_prefix = ["scp", "-o", "StrictHostKeyChecking=no", "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "Compression=no"]
scp_command_suffix = [transfer_file, "{}:/dev/null".format(host)]
scp_recv_command_suffix = ["{}:{}".format(host, transfer_file), "/dev/null"]
transfer_bytes = 1024 * 1024 * 100
##### END of configuration section #####

ciphers = subprocess.check_output(["ssh","-Q","cipher"]).splitlines()
macs = subprocess.check_output(["ssh","-Q","mac"]).splitlines()
kexes = subprocess.check_output(["ssh","-Q","kex"]).splitlines()


def test_kex():
    print("Testing KexAlgorithms...")
    results = []
    for kex in kexes:
        kex_u = kex.decode('utf8')
        print("***** trying kex algorithm: {} *****".format(kex_u))
        start = time.time()
        result = subprocess.run(ssh_command_prefix + ["-o", "KexAlgorithms={}".format(kex_u)] + ssh_command_suffix)
        elapsed_time = time.time() - start
        print(elapsed_time)
        if result.returncode == 0:
            results.append({"algo": kex_u, "time": elapsed_time, "success": True})
        else:
            results.append({"algo": kex_u, "time": None, "success": False})
    return results

def test_mac(receive=False):
    print("Testing MACs...")
    results = []
    for mac in macs:
        mac_u = mac.decode('utf8')
        print("***** trying mac algorithm: {} *****".format(mac_u))
        start = time.time()
        if receive:
            suffix = scp_recv_command_suffix
        else:
            suffix = scp_command_suffix
        result = subprocess.run(scp_command_prefix + ["-o", "Ciphers=aes256-ctr", "-o", "Macs={}".format(mac_u)] + suffix)
        elapsed_time = time.time() - start
        if result.returncode == 0:
            results.append({"algo": mac_u, "time": elapsed_time, "success": True})
        else:
            results.append({"algo": mac_u, "time": None, "success": False})
    return results

def test_cipher(receive=False):
    print("Testing Ciphers...")
    results = []
    for cip in ciphers:
        cip_u = cip.decode('utf8')
        print("***** trying cipher: {} *****".format(cip_u))
        start = time.time()
        if receive:
            suffix = scp_recv_command_suffix
        else:
            suffix = scp_command_suffix
        result = subprocess.run(scp_command_prefix + ["-o", "Ciphers={}".format(cip_u)] + suffix)
        elapsed_time = time.time() - start
        if result.returncode == 0:
            results.append({"algo": cip_u, "time": elapsed_time, "success": True})
        else:
            results.append({"algo": cip_u, "time": None, "success": False})
    return results

def output_as_tsv(result_type, results):
    with open('./ssh-bench-{}.csv'.format(result_type), 'w') as f:
        writer = csv.writer(f)
        writer.writerow(['algorithm', 'time'])
        for result in results:
            if result['success']:
                writer.writerow([result['algo'], result['time']])


kex_result = test_kex()
print("Generating random data file...")
result = os.system("head -c {} </dev/urandom >{}".format(transfer_bytes, transfer_file))
if result != 0:
    raise("Failed")
mac_result = test_mac()
cipher_result = test_cipher()
print("Generating random data file at remote host...")
result = os.system("ssh {} \"head -c {} </dev/urandom >{}\"".format(host, transfer_bytes, transfer_file))
if result != 0:
    raise("Failed")
mac_r_result = test_mac(True)
cipher_r_result = test_cipher(True)

output_as_tsv("kex", kex_result)
output_as_tsv("mac-send", mac_result)
output_as_tsv("cipher-send", cipher_result)
output_as_tsv("mac-receive", mac_r_result)
output_as_tsv("cipher-receive", cipher_r_result)
