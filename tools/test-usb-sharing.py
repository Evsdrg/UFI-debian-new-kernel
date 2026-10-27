#!/usr/bin/env python3
"""Unprivileged configfs fault-injection and native lifecycle regression tests."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

BASE = Path(__file__).resolve().parents[1]
MOCK = r'''#!/usr/bin/env python3
import os, pathlib, sys
p = pathlib.Path(sys.argv[1])
g = pathlib.Path(os.environ['USB_GADGET_CONFIGFS']) / 'openstick'
kind = str(p.relative_to(g)) if p != g else '.'
attrs = {
 '.': ['UDC', 'idVendor', 'idProduct', 'bcdDevice', 'bcdUSB'],
 'strings/0x409': ['manufacturer', 'product', 'serialnumber'],
 'configs/c.1': ['MaxPower'],
 'configs/c.1/strings/0x409': ['configuration'],
 'functions/rndis.usb0': ['os_desc/interface.rndis/compatible_id', 'os_desc/interface.rndis/sub_compatible_id'],
}
auto = {'.': ['strings', 'configs', 'functions', 'os_desc'], 'configs/c.1': ['strings'],
        'functions/rndis.usb0': ['os_desc/interface.rndis', 'os_desc']}
if pathlib.Path(sys.argv[0]).name == 'mkdir':
 p.mkdir()
 for d in auto.get(kind, []): (p/d).mkdir(parents=True, exist_ok=True)
 names = attrs.get(kind, []) + (['os_desc/use','os_desc/b_vendor_code','os_desc/qw_sign'] if kind == '.' else [])
 for name in names:
  f=p/name; f.parent.mkdir(parents=True, exist_ok=True)
  if str(f.relative_to(g)) == os.environ.get('MOCK_FAIL_ATTR'):
   f.symlink_to('/dev/full')
  else: f.write_bytes(b'\0'*4096 if name == 'UDC' else b'')
else:
 if kind == os.environ.get('MOCK_FAIL_RMDIR'): sys.exit(1)
 names = attrs.get(kind, []) + (['os_desc/use','os_desc/b_vendor_code','os_desc/qw_sign'] if kind == '.' else [])
 for name in names: (p/name).unlink(missing_ok=True)
 for d in auto.get(kind, []): (p/d).rmdir()
 p.rmdir()
'''

class GadgetTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        cfg, udc, binpath = (self.root/n for n in ('cfg', 'udc', 'bin'))
        for p in (cfg, udc, binpath): p.mkdir()
        (udc/'ci_hdrc.0').mkdir()
        for name in ('mkdir', 'rmdir'):
            p = binpath/name; p.write_text(MOCK); p.chmod(0o755)
        self.g = cfg/'openstick'
        self.env = dict(os.environ, USB_GADGET_CONFIGFS=str(cfg), USB_GADGET_UDCS=str(udc),
                        USB_GADGET_LOCK=str(self.root/'lock'), PATH=f'{binpath}:'+os.environ['PATH'])
    def run_gadget(self, action, rc=0):
        p = subprocess.run(['sh', str(BASE/'tools/usb-gadget.sh'), action], env=self.env,
                           capture_output=True, text=True, timeout=15)
        self.assertEqual(p.returncode, rc, p.stdout+p.stderr)
        return p
    def test_start_status_repeat_stop(self):
        self.run_gadget('start'); self.run_gadget('start')
        self.assertIn('active UDC=ci_hdrc.0', self.run_gadget('status').stdout)
        self.assertFalse((self.g/'functions/rndis.usb0/os_desc/interface.rndis/b_vendor_code').exists())
        self.run_gadget('stop'); self.run_gadget('stop')
        self.run_gadget('status', 3); self.assertFalse(self.g.exists())
    def test_partial_with_nonzero_stat_is_rebuilt(self):
        subprocess.run(['mkdir', str(self.g)], env=self.env, check=True)
        self.assertEqual((self.g/'UDC').stat().st_size, 4096)
        # 已解绑属性禁止重复写空值：实机 configfs 会拒绝；只读模拟捕获回归。
        (self.g/'UDC').chmod(0o444)
        self.run_gadget('status', 3)
        self.run_gadget('start'); self.run_gadget('status'); self.run_gadget('stop')
    def test_failed_attribute_rolls_back(self):
        self.env['MOCK_FAIL_ATTR'] = 'os_desc/b_vendor_code'
        self.run_gadget('start', 1); self.assertFalse(self.g.exists())
        del self.env['MOCK_FAIL_ATTR']
        self.run_gadget('start'); self.run_gadget('stop')
    def test_bound_conflict_is_not_unbound(self):
        self.run_gadget('start'); (self.g/'idProduct').write_text('0xffff\n')
        self.run_gadget('start', 1)
        self.assertEqual((self.g/'UDC').read_text().strip(), 'ci_hdrc.0')
        self.run_gadget('stop')
    def test_stop_failure_is_not_success(self):
        self.run_gadget('start'); self.env['MOCK_FAIL_RMDIR']='functions/rndis.usb0'
        self.run_gadget('stop', 1); self.assertTrue(self.g.exists())
        del self.env['MOCK_FAIL_RMDIR']; self.run_gadget('stop')

    def test_udc_disappeared_gadget_is_rebuilt(self):
        """UDC 消失后 configfs 仍留着旧 UDC 名：这是"断开后不恢复"的典型状态。
        start 必须允许清理重建，而不是报"请先明确停止"。"""
        self.run_gadget('start')
        self.assertIn('active UDC=ci_hdrc.0', self.run_gadget('status').stdout)
        # 模拟内核侧 UDC 注销：目录消失，但 configfs 的 UDC 属性仍写旧名字。
        (self.env['USB_GADGET_UDCS'] and Path(self.env['USB_GADGET_UDCS'])/'ci_hdrc.0').rmdir()
        self.run_gadget('status', 3)
        # UDC 重新出现（枚举/恢复），start 应能重建
        (Path(self.env['USB_GADGET_UDCS'])/'ci_hdrc.0').mkdir()
        self.run_gadget('start')
        self.assertIn('active UDC=ci_hdrc.0', self.run_gadget('status').stdout)
        self.run_gadget('stop')

    def test_bound_conflict_with_live_udc_still_refused(self):
        """UDC 目录还在、但配置不符，仍必须拒绝，避免拆掉别的 gadget。"""
        self.run_gadget('start')
        (self.g/'idProduct').write_text('0xffff\n')
        (self.g/'UDC').chmod(0o644)
        self.run_gadget('start', 1)
        self.assertEqual((self.g/'UDC').read_text().strip(), 'ci_hdrc.0')
        self.run_gadget('stop')

NATIVE_MOCK = r'''#!/usr/bin/env python3
import os, sys, pathlib
root=pathlib.Path(os.environ['MOCK_ROOT']); name=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
with (root/'calls').open('a') as f: f.write(name+' '+' '.join(args)+'\n')
if name=='ip': print('2: usb0    inet 10.42.0.1/24 scope global usb0')
if name=='nft':
 if os.environ.get('MOCK_NFT_FAIL'): sys.exit(1)
 table=root/'table'
 if args==['list','tables']:
  print('table inet unrelated')
  if table.exists(): print('table inet openstick_usb')
 elif args[:1]==['-f']: table.touch()
 elif args==['delete','table','inet','openstick_usb']: table.unlink()
 else: sys.exit(2)
'''

class NativeTests(unittest.TestCase):
    def test_ownership_idempotency_and_errors(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d); env=dict(os.environ, MOCK_ROOT=d)
            for name, var in [('nft','NFT'),('ip','IP'),('sysctl','SYSCTL')]:
                p=root/name; p.write_text(NATIVE_MOCK); p.chmod(0o755); env[var]=str(p)
            env['USB_SHARE_RULES']=str(BASE/'tools/net-native/nat.nft')
            script=BASE/'tools/net-native/usb-share.sh'
            for action in ['stop','start','start','stop','stop']:
                subprocess.run(['sh',str(script),action],env=env,check=True,capture_output=True,timeout=5)
            calls=(root/'calls').read_text()
            self.assertNotIn('flush ruleset',calls)
            self.assertEqual(calls.count('delete table inet openstick_usb'),1)
            env['MOCK_NFT_FAIL']='1'
            for action in ['start','stop']:
                p=subprocess.run(['sh',str(script),action],env=env,capture_output=True,timeout=5)
                self.assertNotEqual(p.returncode,0)

class WatchdogTests(unittest.TestCase):
    """usb-gadget-watchdog.sh：status 失败时重跑 start，成功时静默退出。"""
    def _run(self, active):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            mark = root / 'mark'
            fake = root / 'usb-gadget'
            fake.write_text('#!/bin/sh\ncase "$1" in\n'
                            'status) [ -f "' + str(mark) + '" ] && exit 0 || exit 3 ;;\n'
                            'start) : > "' + str(mark) + '" ;;\n'
                            'esac\n')
            fake.chmod(0o755)
            if active:
                mark.touch()
            env = dict(os.environ, USB_GADGET_BIN=str(fake))
            p = subprocess.run(['sh', str(BASE/'tools/usb-gadget-watchdog.sh')],
                               env=env, capture_output=True, text=True, timeout=10)
            # 必须在 TemporaryDirectory 销毁前取快照，否则 mark 会随目录一起消失。
            return p.returncode, p.stdout, mark.exists()
    def test_inactive_triggers_start(self):
        rc, out, started = self._run(active=False)
        self.assertEqual(rc, 0)
        self.assertTrue(started, 'status 失败时未调用 start')
    def test_active_is_noop(self):
        rc, out, started = self._run(active=True)
        self.assertEqual(rc, 0)
        self.assertEqual(out, '', '已 active 时不应有输出')

if __name__ == '__main__': unittest.main(verbosity=2)
