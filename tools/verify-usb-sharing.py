#!/usr/bin/env python3
"""USB delivery assertions for all resolved kernels and NM/native rootfs images."""
import hashlib
from pathlib import Path
import re
import subprocess
import sys

BASE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BASE/'tools'))
import kver
from kver import KERNEL_VERSION, KERNEL_LOCALVERSION

SYMBOLS = ('NF_TABLES', 'NF_CONNTRACK', 'NF_NAT', 'NFT_CT', 'NFT_MASQ', 'NFT_NAT',
           'NFT_REJECT', 'NFT_REJECT_IPV4', 'NF_REJECT_IPV4', 'NFT_REJECT_INET',
           'NFT_REJECT_IPV6', 'NF_REJECT_IPV6')
MODULES = ('net/netfilter/nf_tables.ko', 'net/netfilter/nf_conntrack.ko',
           'net/netfilter/nf_nat.ko', 'net/netfilter/nft_chain_nat.ko',
           'net/netfilter/nft_masq.ko', 'net/netfilter/nft_ct.ko', 'net/netfilter/nft_reject.ko',
           'net/ipv4/netfilter/nf_defrag_ipv4.ko', 'net/ipv6/netfilter/nf_defrag_ipv6.ko',
           'net/netfilter/nft_reject_inet.ko',
           'net/ipv4/netfilter/nft_reject_ipv4.ko', 'net/ipv4/netfilter/nf_reject_ipv4.ko',
           'net/ipv6/netfilter/nft_reject_ipv6.ko', 'net/ipv6/netfilter/nf_reject_ipv6.ko')

def check(condition, message):
    if not condition: raise RuntimeError(message)

def debugfs(image, command):
    p = subprocess.run(['debugfs','-R',command,str(image)],capture_output=True,check=False)
    check(p.returncode == 0, f'{image}: debugfs failed: {p.stderr.decode(errors="replace")}')
    return p.stdout

def stat(image, path):
    s=debugfs(image, 'stat '+path).decode(errors='replace')
    check(re.search(r'^Inode:',s,re.M),f'{image.name}: missing {path}')
    return s

def exists(image, path):
    p=subprocess.run(['debugfs','-R','stat '+path,str(image)],capture_output=True,check=False)
    return re.search(r'^Inode:',p.stdout.decode(errors='replace'),re.M) is not None

def exact_asset(image, path, source):
    stat(image,path)
    data=debugfs(image,'cat '+path)
    check(data==source.read_bytes(),f'{image.name}: stale asset {path}')

try:
    for variant in ('baseline','4g','venus','venus-4g','venus-4g-gpu'):
        # 分层断言，与 tools/build-board-set.sh 的板型表一致：
        #   1) 公共配置里必须有 USB 共享所需符号（所有变体都从它派生）；
        #   2) 该变体的片段不得把符号关掉；
        #   3) 构建树在时（未清理中间产物）再查解析后的完整配置。
        # 构建树是可再生中间态，清掉后自动降级到 1+2，不会误报。
        base_text = kver.KERNEL_BASE_CFG.read_text()
        for symbol in ('NFT_CT', 'NFT_REJECT'):
            check(re.search(rf'^CONFIG_{symbol}=m$', base_text, re.M),
                  f'{kver.KERNEL_BASE_CFG}: CONFIG_{symbol}=m missing')
        frags = [BASE/'source/configs/ufi103s-baseline.config']
        if variant in ('venus', 'venus-4g', 'venus-4g-gpu'):
            frags.append(BASE/'source/configs/ufi103s-venus.config')
        if variant == 'venus-4g-gpu':
            frags.append(BASE/'source/configs/ufi103s-gpu.config')
        for frag in frags:
            for symbol in ('NFT_CT', 'NFT_REJECT'):
                check(not re.search(rf'^# CONFIG_{symbol} is not set$', frag.read_text(), re.M),
                      f'{frag}: turns CONFIG_{symbol} off')
        cfg=BASE/f'build/variant-{KERNEL_VERSION}-board-{variant}/.config'
        if cfg.is_file():
            text=cfg.read_text()
            for symbol in SYMBOLS:
                check(re.search(rf'^CONFIG_{symbol}=[my]$',text,re.M),f'{cfg}: CONFIG_{symbol} missing')
        suffix='' if variant=='baseline' else '-'+variant
        rel=f'{KERNEL_VERSION}{KERNEL_LOCALVERSION}{suffix}-dirty'
        tree=kver.ARTIFACTS_MODULES/f'{rel}/lib/modules/{rel}/kernel'
        for module in MODULES:
            check((tree/module).is_file(), f'{rel}: missing {module}')
        print(f'kernel[{variant}]=USB_NFT_OK')
    images=[Path(p) for p in sys.argv[1:]] or [
        kver.ARTIFACTS_ROOTFS/f'ufi103s-{KERNEL_VERSION}-{flavor}.ext4'
        for flavor in ('max','basic','slim','micro','basic-native','slim-native','micro-native')]
    for image in images:
        check(image.is_file(), f'missing rootfs image: {image}')
        native=image.stem.endswith('-native')
        flavor=image.stem.split(f'{KERNEL_VERSION}-',1)[-1].removesuffix('-native')
        suffix='-venus-4g-gpu' if flavor=='max' else '-4g' if flavor=='basic' else ''
        rel=f'{KERNEL_VERSION}{KERNEL_LOCALVERSION}{suffix}-dirty'
        for path in ('/usr/sbin/nft','/usr/sbin/dnsmasq'):
            s=stat(image,path)
            check(re.search(r'Mode:\s+0[0-7]*[1357][0-7][0-7]',s),f'{image.name}: not executable {path}')
        for module in MODULES:
            path=f'/usr/lib/modules/{rel}/kernel/{module}'
            stat(image,path)
            source=kver.ARTIFACTS_MODULES/f'{rel}/lib/modules/{rel}/kernel/{module}'
            check(hashlib.sha256(debugfs(image,'cat '+path)).digest()==hashlib.sha256(source.read_bytes()).digest(),
                  f'{image.name}: stale module {module}')
        exact_asset(image,'/usr/local/sbin/usb-gadget.sh',BASE/'tools/usb-gadget.sh')
        exact_asset(image,'/etc/systemd/system/usb-gadget.service',BASE/'tools/usb-gadget.service')
        stat(image,'/etc/systemd/system/multi-user.target.wants/usb-gadget.service')
        check('"/dev/null"' in stat(image,'/etc/systemd/system/dnsmasq.service'),f'{image.name}: global dnsmasq not masked')
        for prefix in ('/etc/systemd/system', '/usr/lib/systemd/system'):
            check(not re.search(rb'^Inode:', debugfs(image,'stat '+prefix+'/multi-user.target.wants/nftables.service'),re.M),
                  f'{image.name}: global nftables service competes with sharing owner')
        if native:
            for path,source in (
                ('/etc/systemd/system/native-net.service','native-net.service'),
                ('/etc/nftables.d/nat.nft','nat.nft'),
                ('/etc/dnsmasq.d/usb-share.conf','dnsmasq.conf'),
                ('/usr/local/sbin/usb-share-native.sh','usb-share.sh')):
                exact_asset(image,path,BASE/'tools/net-native'/source)
            stat(image,'/etc/systemd/system/multi-user.target.wants/native-net.service')
            stat(image,'/etc/systemd/system/usb-gadget.service.d/native.conf')
            check(b'Wants=native-net.service' in debugfs(image,'cat /etc/systemd/system/usb-gadget.service.d/native.conf'), 'native gadget restart dependency')
        else:
            exact_asset(image,'/etc/NetworkManager/conf.d/20-usb-managed.conf',BASE/'tools/nm-connections/20-usb-managed.conf')
            connection='/etc/NetworkManager/system-connections/usb-share.nmconnection'
            exact_asset(image,connection,BASE/'tools/nm-connections/usb-share.nmconnection')
            check('Mode:  0600' in stat(image,connection),f'{image.name}: unsafe keyfile mode')
            check(b'firewall-backend=nftables' in debugfs(image,'cat /etc/NetworkManager/NetworkManager.conf'),f'{image.name}: backend not pinned')
        # 交付镜像**不得含预置 Wi-Fi 凭据**（见 build-rootfs.sh 文件头）。
        # 无屏棒子的首入路径是 USB RNDIS；预置 PSK 历史上因裸反斜杠转义
        # 静默写错（11 个空格+口令）导致刷完即失联，所以直接不要预置。
        # 见 docs/ISSUES.md 第 16 条。
        stale='/etc/NetworkManager/system-connections/openstick-wifi.nmconnection'
        check(not exists(image,stale), f'{image.name}: ships a preset Wi-Fi profile ({stale})')
        wifi_conf='/etc/wpa_supplicant/wpa_supplicant-wlan0.conf'
        if exists(image,wifi_conf):
            text=debugfs(image,'cat '+wifi_conf).decode('utf-8',errors='replace')
            for line in text.splitlines():
                stripped=line.strip()
                check(not stripped.startswith(('network=','ssid=','psk=')),
                      f'{image.name}: wpa_supplicant conf ships preset Wi-Fi credentials: {stripped!r}')
        print(f'rootfs[{image.name}]=USB_DELIVERY_OK')
except (RuntimeError, OSError) as e:
    print('USB_CHECK_FAILED: '+str(e),file=sys.stderr)
    sys.exit(1)
