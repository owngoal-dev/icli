#!/usr/bin/env python3
"""Archive a release and write the acceptance report from the recorded evidence.

Everything in the report comes from `.build/acceptance-release.json` (a full
`scripts/acceptance.py` run) and `.build/package-verification.json`. Failed
cases and untested commands stay visible; the script exits nonzero when any exist.
"""
import hashlib
import json
from pathlib import Path
import shutil

root = Path(__file__).resolve().parents[1]
build = root / '.build'
tests = json.loads((build / 'acceptance-release.json').read_text())
packages = json.loads((build / 'package-verification.json').read_text())
consumer = json.loads((build / 'package-consumer-verification.json').read_text())
assert consumer['version'] == tests['version'], 'consumer and acceptance versions differ'
assert consumer['manifest_sha256'] == hashlib.sha256((root / 'Package.swift').read_bytes()).hexdigest(), 'package manifest changed after consumer verification'
assert consumer['device_result']['installed_version'] == tests['version'], 'consumer device smoke test missing or stale'
for path, digest in consumer['source_sha256'].items():
    assert hashlib.sha256((root / path).read_bytes()).hexdigest() == digest, 'source changed after consumer verification: ' + path
assert tests['version'] == packages['version'], 'acceptance and package reports describe different versions'
assert tests['binary_sha256'] == packages['binary_sha256'], 'acceptance and package reports describe different binaries'
assert tests['full_run'], 'acceptance-release.json must come from a full run with --group all, without --case or --skip-reboot'
assert tests['completed_run'] and [case['name'] for case in tests['cases']] == tests['planned_cases'], 'acceptance run did not finish every planned case'
assert hashlib.sha256((root / 'scripts/acceptance.py').read_bytes()).hexdigest() == tests['runner_sha256'], 'acceptance runner changed after the test run'
assert hashlib.sha256((build / 'icli').read_bytes()).hexdigest() == tests['binary_sha256'], '.build/icli changed after the acceptance run'
assert packages['forbidden_process_imports'] == [], 'package verification must check process-launch imports'
for package in packages['packages']:
    assert hashlib.sha256((build / package['file']).read_bytes()).hexdigest() == package['sha256'], 'package changed after verification: ' + package['file']
    assert package['depends'] == 'firmware (>= 16.0)', 'unexpected runtime package dependency'

cases = tests['cases']
passed = {case['name']: case['passed'] for case in cases}
failed = [case for case in cases if not case['passed']]
untested = tests['untested_commands']
covered = {}
for case in cases:
    for trace in case['trace']:
        arguments = trace.get('cli_arguments', [])
        for command in tests['command_inventory']:
            words = command.split()
            if arguments[:len(words)] == words:
                covered.setdefault(command, set()).add(case['name'])

release = build / 'release' / tests['version']
release.mkdir(parents=True, exist_ok=True)
for source, destination in [
    (build / 'icli', release / 'icli'),
    (build / 'acceptance-release.json', release / 'acceptance.json'),
    (build / 'package-verification.json', release / 'package-verification.json'),
    (build / 'package-consumer-verification.json', release / 'package-consumer-verification.json'),
    (build / 'testhost.jpg', release / 'testhost.jpg'),
    (root / 'README.md', release / 'README.md'),
    (root / 'LICENSE', release / 'LICENSE'),
    (root / 'docs/swift-package.md', release / 'docs/swift-package.md'),
    (root / 'docs/entitlements.md', release / 'docs/entitlements.md'),
    (root / 'Resources/icli.entitlements', release / 'Resources/icli.entitlements'),
    (root / 'THIRD_PARTY_NOTICES.md', release / 'THIRD_PARTY_NOTICES.md'),
    (build / 'icli-testhost_1.0_iphoneos-arm64.deb', release / 'test-fixtures/icli-testhost_1.0_iphoneos-arm64.deb'),
    (build / 'install-fixtures/icli-install-fixture.ipa', release / 'test-fixtures/icli-install-fixture.ipa'),
    (build / 'install-fixtures/icli-install-fixture.deb', release / 'test-fixtures/icli-install-fixture.deb'),
]:
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
shutil.copytree(root / 'Resources/Licenses', release / 'Resources/Licenses', dirs_exist_ok=True)
for package in packages['packages']:
    folder = release if package['layout'] == 'rootless' else release / 'experimental-roothide'
    folder.mkdir(exist_ok=True)
    shutil.copy2(build / package['file'], folder / package['file'])

device = tests['device']
screen = tests.get('screen', {})
case_rows = [f"| `{c['name']}` | {'PASS' if c['passed'] else 'FAIL'} | {c['seconds']:.1f} | {c.get('error', '').replace('|', '/')[:160]} |" for c in cases]
command_rows = []
for command in tests['command_inventory']:
    names = sorted(covered.get(command, []))
    status = 'UNTESTED' if not names else ('PASS' if all(passed[n] for n in names) else 'FAIL')
    command_rows.append(f"| `{command}` | {status} | " + ', '.join(f'`{n}`' for n in names) + ' |')
observations = [f"- `{c['name']}`: {o}" for c in cases for o in c.get('observations', [])]
package_rows = [f"| {p['layout']} | `{p['file']}` | `{p['sha256']}` |" for p in packages['packages']]

report = f"""# icli {tests['version']} rootless 验收

本报告由 `scripts/assemble-release.py` 根据 `acceptance.json` 与 `package-verification.json` 生成，不含手工填写的结果。
测试时间：{tests['tested_at']}。用例 {len(cases) - len(failed)}/{len(cases)} 通过；命令入口 {len(tests['command_inventory']) - len(untested)}/{len(tests['command_inventory'])} 被实际执行。
PASS 只表示所列用例在下述设备上通过，不代表其他 iOS 版本、参数组合或物理硬件已经认证。

## 交付与身份

- 版本 `{tests['version']}`，签名 arm64 Mach-O SHA-256：`{tests['binary_sha256']}`。
- 本机构建、设备上执行的文件和两个 DEB 中的文件哈希一致；架构、部署目标、entitlements、系统依赖、属主和仅含 CLI 的包内容由 `package-verification.json` 记录。
- 单二进制自包含：DEB 仅依赖 iOS firmware，第三方归档库静态链接；构建和包检查未发现进程启动导入符号，`environment_report` 用例检查 `spawns_processes: false` 与空的 `external_tools_used`。符号检查覆盖直接链接调用。
- 测试设备：{device['model']}，iOS {device['ios_version']}，{device['jailbreak']['layout']} 布局（`{device['jailbreak']['jbroot']}`）。
- 设备快照、每条命令的参数、退出码、耗时和有界输出记录在 `acceptance.json`。
- `IcliKit` 库已由独立 Swift Package 使用精确版本依赖构建，并在设备上完成环境查询、版本比较与包状态读取；证据见 `package-consumer-verification.json`。完整 entitlements 说明见 `docs/entitlements.md`。

| 布局 | 包 | SHA-256 |
| --- | --- | --- |
{chr(10).join(package_rows)}

## 用例结果

| 用例 | 结果 | 秒 | 错误 |
| --- | --- | --- | --- |
{chr(10).join(case_rows)}

## 命令覆盖

状态来自实际执行记录：某命令被任一失败用例执行过即标记 FAIL，没有用例执行过即 UNTESTED。

| 命令 | 状态 | 用例 |
| --- | --- | --- |
{chr(10).join(command_rows)}

## 观察

{chr(10).join(observations) if observations else '- 无。'}

## 已知边界

- RootHide 运行未验收：experimental-roothide 中的 DEB 只完成了包检查和同二进制检查。
- 剪贴板、亮度、旋转和 Keychain 由 CLI 直接执行，不启动 App、不切换前台。其他 App 程序化读取 icli 写入的剪贴板文本时，iOS 可能弹出系统粘贴许可提示；用户发起的粘贴（如快捷键）不会。
- Keychain 命令只在 `icli.test` 访问组内操作自建条目，不读取其他 App 的凭据。
- 音量按键在 HID 不生效时使用系统音频控制接口；虚拟机没有可用于验收的实体响铃开关。
- IPA 保留原签名并依赖 bootstrap 的执行能力；不提供签名绕过。
- DEB 在进程内解包并维护 dpkg 数据库；维护者脚本与 triggers 不执行，需要脚本配置的包不属于完整安装兼容承诺。仅支持本地 DEB，不提供 APT 下载与依赖解析安装。
- 重启可能在 JSON 返回前切断 SSH，断连本身不代表完成；用户态重启通过系统与 UI 服务进程更换且内核启动信息不变验证，完整重启通过 kernel boot time 与 boot session UUID 变化验证。完整重启清空 `/tmp`。

## 重跑

```sh
make all CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=
./scripts/check-packages.sh
./scripts/build-testhost.sh
./scripts/build-install-fixtures.sh
python3 scripts/acceptance.py --install --report .build/acceptance-release.json
python3 scripts/check-package-consumer.py --device
python3 scripts/assemble-release.py
```

先在设备上安装 `test-fixtures` 中的 TestHost DEB，并把 IPA/DEB 夹具上传到设备 `/tmp`。SSH 密码由 `ICLI_SSH_PASSWORD` 或 SSH key 提供，不写入报告。
"""
(root / 'docs/rootless-acceptance.md').write_text(report)
(release / 'ACCEPTANCE.md').write_text(report)
(release / 'docs/rootless-acceptance.md').write_text(report)
files = sorted(p for p in release.rglob('*') if p.is_file() and p.name != 'SHA256SUMS')
(release / 'SHA256SUMS').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + str(p.relative_to(release)) + '\n' for p in files))
print(release)
for case in failed:
    print('FAIL', case['name'], case.get('error', ''))
for command in untested:
    print('UNTESTED', command)
raise SystemExit(1 if failed or untested else 0)
