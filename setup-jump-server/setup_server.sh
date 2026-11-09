#!/usr/bin/env bash
# 业务服务器交互配置，Ubuntu 24.04，IPv4。sudo bash setup_server.sh
# 可用选项：--status、--rollback、--reset、--help。
# 两端各开一个交互终端，先运行跳板脚本；仅交换公钥，不交换私钥。
# 全新实例使用；不会调用云安全组 API。详见同目录 README.md。
# Python 代码内嵌于本文件，不需要下载其他辅助脚本。
set -euo pipefail
if [[ ${1:-} != --help ]]; then
    ((EUID == 0)) || { printf '%s\n' '请使用 sudo bash 本脚本.sh，或以 root 运行。' >&2; exit 1; }
    . /etc/os-release
    [[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 24.04 ]] || { printf '%s\n' '此脚本仅支持 Ubuntu 24.04。' >&2; exit 1; }
fi
if ! command -v python3 >/dev/null; then
    if [[ ${1:-} == --help ]]; then
        printf '%s\n' '业务服务器交互配置：sudo bash setup_server.sh（Ubuntu 24.04）。选项：--status、--rollback、--reset、--help。'
        exit 0
    fi
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y python3
fi
# -I：不从当前目录导入模块，避免以 root 身份加载同名 .py 文件。
exec python3 -I - "$@" <<'PYTHON_PAIRED_SETUP'
"""Embedded in two standalone Ubuntu 24.04 setup scripts; standard library only."""
import base64
import datetime
import ipaddress
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile

VERSION = 1
TTY = None
STATE_ROOT = Path('/var/lib/paired-ssh-setup')
SSHD_FILE = Path('/etc/ssh/sshd_config.d/00-00-paired-access.conf')
UFW_DIR = Path('/etc/ufw')
UFW_DEFAULT = Path('/etc/default/ufw')
BEGIN = '# BEGIN paired-access-v1'
END = '# END paired-access-v1'


def say(message=''):
    print(message, flush=True)


def fail(message):
    raise RuntimeError(message)


def ask(label, default=None, validate=None):
    while True:
        suffix = f' [{default}]' if default is not None else ''
        print(f'{label}{suffix}：', end='', flush=True)
        line = TTY.readline()
        if not line:
            fail('交互输入已关闭；已完成的步骤会保留，可重新运行脚本继续。')
        value = line.strip()
        if value.lower() == ':quit':
            fail('已停止。重新执行同一脚本可继续。')
        value = value or (str(default) if default is not None else '')
        try:
            if not value:
                raise ValueError('此项不能为空。')
            return validate(value) if validate else value
        except (ValueError, RuntimeError) as exc:
            say(f'输入无效：{exc}')


def yes(label, default=True):
    def parse(value):
        if value.lower() in ('y', 'yes', '是'):
            return True
        if value.lower() in ('n', 'no', '否'):
            return False
        raise ValueError('请输入 y 或 n。')
    return ask(label + ' (y/n)', 'y' if default else 'n', parse)


def pause(message):
    print(message + ' 按回车继续（输入 :quit 可退出）：', end='', flush=True)
    line = TTY.readline()
    if not line or line.strip().lower() == ':quit':
        fail('已停止；重新执行同一脚本可继续。')


def command(args, *, capture=False, check=True, input_text=None, user=None, timeout=None):
    args = list(map(str, args))
    env = os.environ.copy()
    env['LC_ALL'] = 'C.UTF-8'
    env['LANG'] = 'C.UTF-8'
    if user:
        account = pwd.getpwnam(user)
        args = ['runuser', '-u', user, '--', 'env', f'HOME={account.pw_dir}',
                f'PATH={account.pw_dir}/.local/bin:/usr/local/bin:/usr/bin:/bin',
                'LANG=C.UTF-8', 'LC_ALL=C.UTF-8'] + args
    kwargs = dict(text=True, env=env, check=check, timeout=timeout)
    if input_text is None:
        kwargs['stdin'] = subprocess.DEVNULL
    else:
        kwargs['input'] = input_text
    if capture:
        kwargs['stdout'] = subprocess.PIPE
        kwargs['stderr'] = subprocess.PIPE
    result = subprocess.run(args, **kwargs)
    return result


def is_private_v4(value):
    addr = ipaddress.IPv4Address(value)
    return any(addr in ipaddress.IPv4Network(net)
               for net in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'))


def ipv4(value):
    addr = ipaddress.IPv4Address(value)
    if not (addr.is_global or is_private_v4(value)):
        raise ValueError('请填写实际可路由的 IPv4 地址。')
    return str(addr)


def public_ipv4(value):
    value = ipv4(value)
    if not ipaddress.IPv4Address(value).is_global:
        raise ValueError('这里应填写公网 IPv4，例如实例绑定的 EIP。')
    return value


def username(value):
    if not re.fullmatch(r'[a-z_][a-z0-9_-]{0,30}', value) or value == 'root':
        raise ValueError('请使用普通 Linux 账号，例如 ecs-user；不要填写 root。')
    return value


def alias_name(value):
    if not re.fullmatch(r'[a-z][a-z0-9_-]{0,30}', value):
        raise ValueError('别名使用小写字母、数字、短横线或下划线。')
    return value


def port_number(value):
    if isinstance(value, bool):
        raise ValueError('端口须为 1–65535。')
    value = int(value)
    if not 1 <= value <= 65535:
        raise ValueError('端口须为 1–65535。')
    return value


def ensure_dir(path, uid=0, gid=0, mode=0o700):
    path = Path(path)
    if path.is_symlink() or (path.exists() and not path.is_dir()):
        fail(f'路径不是普通目录，已停止：{path}')
    path.mkdir(parents=True, exist_ok=True)
    os.chmod(path, mode)
    os.chown(path, uid, gid)


def write_atomic(path, content, uid=0, gid=0, mode=0o600, backup=True):
    path = Path(path)
    if path.is_symlink() or (path.exists() and not path.is_file()):
        fail(f'路径不是普通文件，已停止：{path}')
    data = content.encode() if isinstance(content, str) else content
    if path.exists() and path.read_bytes() == data:
        os.chmod(path, mode)
        os.chown(path, uid, gid)
        return
    if backup and path.exists():
        stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
        dest = path.with_name(path.name + '.bak.' + stamp)
        shutil.copyfile(path, dest)
        os.chmod(dest, 0o600)
        os.chown(dest, uid, gid)
    fd, temp = tempfile.mkstemp(prefix='.paired-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp, mode)
        os.chown(temp, uid, gid)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def managed_body(old):
    if BEGIN not in old and END not in old:
        return old
    if old.count(BEGIN) != 1 or old.count(END) != 1:
        fail('已有配置中的管理段标记异常，请先检查备份。')
    pattern = re.compile(r'(?ms)^' + re.escape(BEGIN) + r'\n.*?^' + re.escape(END)
                         + r'(?:\n\n|\n|$)')
    result, count = pattern.subn('', old, count=1)
    if count != 1:
        fail('已有管理段格式异常，未覆盖。')
    return result


def managed_text(old, block):
    return BEGIN + '\n' + block.rstrip() + '\n' + END + '\n\n' + managed_body(old)


def validate_public_key(value):
    if not isinstance(value, str):
        raise ValueError('公钥须为一整行文本。')
    value = value.strip()
    parts = value.split()
    if '\n' in value or '\r' in value or len(value) > 12000 or len(parts) < 2:
        raise ValueError('请粘贴一整行 SSH 公钥；不要粘贴私钥。')
    if not re.fullmatch(r'(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(?:256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)', parts[0]):
        raise ValueError('公钥应以 ssh-ed25519、ssh-rsa 或 ecdsa-sha2- 开头。')
    normalized = ' '.join(parts[:2])
    with tempfile.NamedTemporaryFile(mode='w', prefix='paired-public-') as handle:
        handle.write(normalized + '\n')
        handle.flush()
        result = command(['ssh-keygen', '-lf', handle.name], capture=True, check=False)
        if result.returncode:
            raise ValueError('SSH 公钥格式无效。')
    return normalized


def fingerprint(public_key):
    with tempfile.NamedTemporaryFile(mode='w', prefix='paired-fingerprint-') as handle:
        handle.write(public_key + '\n')
        handle.flush()
        return command(['ssh-keygen', '-lf', handle.name], capture=True).stdout.strip()


def default_user():
    candidate = os.environ.get('SUDO_USER', '')
    try:
        return username(candidate)
    except ValueError:
        return 'ecs-user'


def get_account(name):
    username(name)
    try:
        account = pwd.getpwnam(name)
    except KeyError:
        if not yes(f'账号 {name} 不存在，创建普通账号（密码锁定，不新增 sudo 权限）'):
            fail('需要一个普通 Linux 账号。')
        command(['useradd', '--create-home', '--shell', '/bin/bash', name])
        account = pwd.getpwnam(name)
    if account.pw_uid < 1000 or not Path(account.pw_dir).is_dir():
        fail('请选择具有现有 home 目录的普通用户，UID 应不小于 1000。')
    if account.pw_shell.endswith(('nologin', 'false')):
        fail('该账号没有可登录的 shell，请换用已有登录账号。')
    return account


def user_paths(account):
    home = Path(account.pw_dir)
    ensure_dir(home / '.ssh', account.pw_uid, account.pw_gid)
    # 不递归修改已有 home 内容的所有权。
    for path in (home / '.local', home / '.local/state', home / '.local/state/paired-access'):
        if not path.exists():
            ensure_dir(path, account.pw_uid, account.pw_gid)
        elif path.is_symlink() or not path.is_dir():
            fail(f'用户状态路径异常：{path}')
    return home / '.ssh', home / '.local/state/paired-access'


def authorize(account, public_key, source=None):
    ssh_dir, _ = user_paths(account)
    path = ssh_dir / 'authorized_keys'
    old = path.read_text() if path.exists() and not path.is_symlink() else ''
    prefix = f'from="{source}",no-agent-forwarding ' if source else ''
    keys = public_key if isinstance(public_key, list) else [public_key]
    block = '\n'.join(prefix + key + ' paired-access' for key in keys) + '\n'
    write_atomic(path, managed_text(old, block), account.pw_uid, account.pw_gid)


def ensure_pair(account):
    ssh_dir, _ = user_paths(account)
    path = ssh_dir / 'paired_server_ed25519'
    if path.is_symlink() or (path.exists() and not path.is_file()):
        fail('专用私钥路径异常，未覆盖。')
    if not path.exists():
        if Path(str(path) + '.pub').exists():
            fail('专用密钥仅有公钥而无私钥，请先检查备份。')
        command(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', 'jump-to-server', '-f', path], user=account.pw_name)
    os.chmod(path, 0o600)
    os.chown(path, account.pw_uid, account.pw_gid)
    result = command(['ssh-keygen', '-y', '-P', '', '-f', path], user=account.pw_name, capture=True, check=False)
    if result.returncode:
        fail('已有专用私钥无法读取，可能有口令；未重新生成或覆盖。')
    public = validate_public_key(result.stdout)
    if not public.startswith('ssh-ed25519 '):
        fail('已有专用密钥并非 Ed25519，未替换。')
    pub_path = Path(str(path) + '.pub')
    if pub_path.exists() and validate_public_key(pub_path.read_text()) != public:
        fail('专用密钥的公钥与私钥不匹配，未覆盖。')
    write_atomic(pub_path, public + ' jump-to-server\n', account.pw_uid, account.pw_gid)
    return path, public


def write_client_config(account, state, key_path):
    ssh_dir, _ = user_paths(account)
    path = ssh_dir / 'config'
    old = path.read_text() if path.exists() and not path.is_symlink() else ''
    body = managed_body(old)
    for line in body.splitlines():
        try:
            tokens = shlex.split(line.replace('=', ' ', 1), comments=True)
        except ValueError:
            fail(f'{path} 中这一行引号不成对，请先修正：{line.strip()}')
        if tokens and tokens[0].lower() == 'host' and state['alias'] in [s.lower() for s in tokens[1:]]:
            fail(f"已有非本脚本创建的 Host {state['alias']}，请先重命名旧别名。")
    known = ssh_dir / 'paired_server_known_hosts'
    block = f'''Host {state['alias']}
    HostName {state['server_ip']}
    User {state['server_user']}
    Port {state['server_port']}
    IdentityFile "{key_path}"
    IdentitiesOnly yes
    IdentityAgent none
    ForwardAgent no
    ProxyCommand none
    ProxyJump none
    UserKnownHostsFile "{known}"
    StrictHostKeyChecking yes
    UpdateHostKeys no
    ServerAliveInterval 30
    ServerAliveCountMax 3
Host *
'''
    text = managed_text(old, block)
    # 先验证再替换正式配置。
    with tempfile.NamedTemporaryFile(mode='w', dir=ssh_dir, prefix='.paired-config-') as temp:
        temp.write(text)
        temp.flush()
        # 以该账号身份检查：配置中的 Match exec 不以 root 执行，~ 也按该账号的家目录解析。
        os.chown(temp.name, account.pw_uid, account.pw_gid)
        result = command(['ssh', '-G', '-F', temp.name, state['alias']], capture=True, user=account.pw_name)
        effective = dict(line.split(' ', 1) for line in result.stdout.splitlines())
        for k, v in {'hostname': state['server_ip'], 'user': state['server_user'],
                     'port': str(state['server_port']), 'forwardagent': 'no', 'stricthostkeychecking': 'true'}.items():
            if k == 'stricthostkeychecking':
                if effective[k] not in ('true', 'yes'):
                    fail('主机指纹验证设置未生效。')
            elif effective.get(k) != v:
                fail(f'SSH 配置受已有设置影响：{k}，未写入。')
    write_atomic(path, text, account.pw_uid, account.pw_gid)


def make_card(kind, data):
    obj = {'version': VERSION, 'kind': kind, **data}
    raw = json.dumps(obj, sort_keys=True, separators=(',', ':')).encode()
    return ('JUMP1:' if kind == 'jump' else 'SERVER1:') + base64.urlsafe_b64encode(raw).decode()


def parse_card(value, kind):
    prefix = 'JUMP1:' if kind == 'jump' else 'SERVER1:'
    if not value.startswith(prefix) or len(value) > 30000:
        raise ValueError(f'请完整粘贴以 {prefix} 开头的单行信息。')
    try:
        raw = base64.b64decode(value[len(prefix):], altchars=b'-_', validate=True)
        obj = json.loads(raw)
    except (ValueError, UnicodeError) as exc:
        raise ValueError('连接信息不完整或已损坏。') from exc
    if not isinstance(obj, dict) or obj.get('version') != VERSION or obj.get('kind') != kind:
        raise ValueError('连接信息的类型或版本不匹配。')
    required = ['session', 'server_ip', 'server_port', 'server_user', 'jump_source']
    if any(k not in obj for k in required):
        raise ValueError('连接信息缺少字段。')
    if any(not isinstance(obj[k], str) for k in ('session', 'server_ip', 'server_user', 'jump_source')):
        raise ValueError('连接信息的文本字段类型无效。')
    if not isinstance(obj['server_port'], int) or isinstance(obj['server_port'], bool):
        raise ValueError('连接信息中的端口应为整数。')
    if not isinstance(obj['session'], str) or not re.fullmatch(r'[0-9a-f]{32}', obj['session']):
        raise ValueError('会话标识无效。')
    obj['server_ip'] = ipv4(obj['server_ip'])
    obj['jump_source'] = ipv4(obj['jump_source'])
    obj['server_port'] = port_number(obj['server_port'])
    obj['server_user'] = username(obj['server_user'])
    if kind == 'jump':
        if obj.get('network') not in ('private', 'public'):
            raise ValueError('连接方式无效。')
        obj['jump_key'] = validate_public_key(obj.get('jump_key', ''))
        if not obj['jump_key'].startswith('ssh-ed25519 '):
            raise ValueError('跳板专用密钥应为 Ed25519。')
    else:
        if not isinstance(obj.get('nonce'), str) or not re.fullmatch(r'[0-9a-f]{32}', obj['nonce']):
            raise ValueError('验证标识无效。')
        obj['host_key'] = validate_public_key(obj.get('host_key', ''))
        if not obj['host_key'].startswith('ssh-ed25519 '):
            raise ValueError('主机公钥应为 Ed25519。')
    return obj


def state_path(role):
    return STATE_ROOT / role / 'state.json'


def save_state(role, state):
    path = state_path(role)
    ensure_dir(path.parent)
    write_atomic(path, json.dumps(state, ensure_ascii=False, indent=2) + '\n', backup=False)


def load_state(role):
    path = state_path(role)
    if not path.exists():
        return None
    if path.is_symlink() or path.stat().st_uid != 0 or path.stat().st_mode & 0o022:
        fail('状态文件权限不安全，已停止。')
    state = json.loads(path.read_text())
    if state.get('version') != VERSION or state.get('role') != role:
        fail('已有状态文件类型或版本不匹配。')
    return state


def install_packages(role):
    packages = ['openssh-server', 'openssh-client', 'ufw', 'iproute2', 'ca-certificates']
    packages += ['mosh'] if role == 'jump' else ['tmux', 'git', 'curl']
    say('\n安装系统组件（不进行整机升级）……')
    command(['apt-get', 'update'])
    command(['env', 'DEBIAN_FRONTEND=noninteractive', 'apt-get', 'install', '-y', *packages])
    command(['systemctl', 'enable', '--now', 'ssh'])
    command(['/usr/sbin/sshd', '-t'])


def ssh_settings():
    text = command(['/usr/sbin/sshd', '-T'], capture=True).stdout
    result = {}
    for line in text.splitlines():
        name, value = line.split(' ', 1)
        result.setdefault(name, []).append(value)
    return result


def current_ssh_port():
    ports = [int(p) for p in ssh_settings().get('port', [])]
    if not ports:
        fail('未找到 SSH 监听端口。')
    if len(ports) == 1:
        return ports[0]
    selected = ask('本机存在多个 SSH 端口，选择供本方案使用的现有端口', ports[0], port_number)
    if selected not in ports:
        fail('选择的端口不在当前 SSH 配置中。本脚本不修改 SSH 监听端口。')
    return selected


def proof_path(account, kind, nonce):
    if kind not in ('jump', 'server') or not re.fullmatch(r'[0-9a-f]{32}', nonce):
        fail('验证文件参数无效。')
    _, directory = user_paths(account)
    return directory / f'{kind}-proof-{nonce}'


def lock_marker(account, nonce):
    # 服务器收紧完成后写入该普通账号目录，供跳板经 SSH 复核。
    if not re.fullmatch(r'[0-9a-f]{32}', nonce):
        fail('验证文件参数无效。')
    return Path(account.pw_dir) / '.local/state/paired-access' / f'server-locked-{nonce}'


def proof_command(path, nonce, expected_source=None):
    # 验证命令以普通用户运行，公钥/主机指纹检查由外层 SSH 完成。
    # 拼成单行，便于从终端整行复制到 Mac。
    steps = ['set -eu', 'umask 077', 'test -n "${SSH_CONNECTION:-}"', 'set -- $SSH_CONNECTION']
    if expected_source:
        ipv4(expected_source)
        steps.append(f'[ "$1" = {shlex.quote(expected_source)} ] || {{ echo "实际 SSH 来源与配置不符：$1" >&2; exit 23; }}')
    steps += [f'printf "%s\\n%s\\n" {shlex.quote(nonce)} "$SSH_CONNECTION" > {shlex.quote(str(path))}',
              f'printf "PAIR_OK %s %s\\n" {shlex.quote(nonce)} "$1"']
    return '; '.join(steps)


def read_proof(account, kind, nonce, expected_source=None, expected_port=None):
    path = proof_path(account, kind, nonce)
    if not path.is_file() or path.is_symlink() or path.stat().st_uid != account.pw_uid:
        return None
    lines = path.read_text().splitlines()
    if len(lines) != 2 or lines[0] != nonce:
        return None
    connection = lines[1].split()
    if len(connection) != 4:
        return None
    # 来源可能是加速线路或中转的回源地址（如 100.64.0.0/10、IPv6），这里只要求是合法 IP；
    # 需要核对来源时由 expected_source 精确比对。
    try:
        source = str(ipaddress.ip_address(connection[0]))
        port_number(connection[1])
        ipaddress.ip_address(connection[2])
        dest_port = port_number(connection[3])
    except ValueError:
        return None
    if expected_source and source != expected_source:
        return None
    if expected_port and dest_port != expected_port:
        return None
    return connection


def hardening_text(role, user, source=None):
    allowed = user if role == 'jump' else f'{user}@{source}'
    return (BEGIN + '\nPubkeyAuthentication yes\nAuthenticationMethods publickey\n'
            'PasswordAuthentication no\nKbdInteractiveAuthentication no\n'
            f'PermitRootLogin no\nAllowUsers {allowed}\n' + END + '\n')


def firewall_plan(role, state):
    port = state['jump_port'] if role == 'jump' else state['server_port']
    rules = [['allow', f'{port}/tcp'], ['allow', '60000:61000/udp']] if role == 'jump' else [
        ['allow', 'proto', 'tcp', 'from', state['jump_source'], 'to', 'any', 'port', str(port)]]
    return [['ufw', 'default', 'deny', 'incoming'], ['ufw', 'default', 'allow', 'outgoing'],
            *[['ufw', *rule] for rule in rules], ['ufw', '--force', 'enable']]


def reload_ssh():
    command(['/usr/sbin/sshd', '-t'])
    command(['systemctl', 'reload', 'ssh'])


def snapshot_security(role):
    dest = STATE_ROOT / role / 'security-backup'
    if dest.exists():
        fail('已存在安全设置备份；请先用 --rollback 恢复后再重试收紧，避免覆盖恢复点。')
    if SSHD_FILE.exists():
        if SSHD_FILE.is_symlink() or BEGIN not in SSHD_FILE.read_text():
            fail(f'{SSHD_FILE} 已有非本脚本内容，已停止。')
    ensure_dir(dest)
    try:
        active = 'Status: active' in command(['env', 'LC_ALL=C', 'ufw', 'status'], capture=True).stdout
        metadata = {'ufw_active': active, 'sshd_existed': SSHD_FILE.exists()}
        if SSHD_FILE.exists():
            shutil.copy2(SSHD_FILE, dest / 'sshd.conf')
        shutil.copytree(UFW_DIR, dest / 'ufw', symlinks=True)
        shutil.copy2(UFW_DEFAULT, dest / 'ufw.default')
        write_atomic(dest / 'metadata.json', json.dumps(metadata), backup=False)
    except BaseException:
        shutil.rmtree(dest)
        raise


def restore_security(role, state):
    dest = STATE_ROOT / role / 'security-backup'
    metadata_path = dest / 'metadata.json'
    if not metadata_path.exists():
        fail('没有完整的安全设置备份；本脚本尚未应用可回滚的收紧操作。')
    metadata = json.loads(metadata_path.read_text())
    if role == 'server':
        # 先撤下“已收紧”标记，避免跳板复核时误判；失败也不影响恢复。
        try:
            lock_marker(pwd.getpwnam(state['server_user']), state['nonce']).unlink(missing_ok=True)
        except (KeyError, OSError, RuntimeError):
            say('提示：未能删除服务器“已收紧”标记文件，跳板复核时可能误判。')
    if metadata['sshd_existed']:
        shutil.copy2(dest / 'sshd.conf', SSHD_FILE)
    else:
        SSHD_FILE.unlink(missing_ok=True)
    reload_ssh()
    shutil.copytree(dest / 'ufw', UFW_DIR, symlinks=True, dirs_exist_ok=True)
    shutil.copy2(dest / 'ufw.default', UFW_DEFAULT)
    command(['ufw', 'reload'] if metadata['ufw_active'] else ['ufw', '--force', 'disable'])
    state['locked'] = False
    state['lock_started'] = False
    state['finished'] = False
    save_state(role, state)
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    dest.rename(dest.with_name('security-backup-restored-' + stamp))
    say('已恢复脚本收紧前的 sshd 和 UFW 设置；已安装的软件、账号和公钥保留。')


def check_ufw_clean():
    if not shutil.which('ufw'):
        return
    added = command(['env', 'LC_ALL=C', 'ufw', 'show', 'added'], capture=True).stdout
    if any(line.strip().startswith('ufw ') for line in added.splitlines()):
        fail('检测到已有 UFW 自定义规则。脚本不会清空；请检查原规则后再继续。本脚本适用于全新实例。')


def preflight_security(role):
    # 收紧前才会检查的冲突提前检查，避免两端流程走完后才停下。
    if SSHD_FILE.is_symlink() or (SSHD_FILE.exists() and BEGIN not in SSHD_FILE.read_text()):
        fail(f'{SSHD_FILE} 已有非本脚本内容，已停止；请先检查该文件。')
    if (STATE_ROOT / role / 'security-backup').exists():
        fail(f"已存在收紧前的安全设置备份（{STATE_ROOT / role / 'security-backup'}）；请先执行 --rollback。")
    check_ufw_clean()


def reset_state(role):
    state = load_state(role)
    if not state:
        say('本机尚无本脚本配置记录，无需重置。')
        return
    if state.get('locked') or state.get('lock_started') or (STATE_ROOT / role / 'security-backup').exists():
        fail('本机已应用或正在应用收紧设置；请先执行 --rollback，再执行 --reset。')
    say('将清除本机保存的填写内容，下次运行重新询问；旧记录改名保留。')
    say('已安装的软件、账号和专用密钥保留；本脚本写入的公钥和 SSH 配置段会在重新配置时替换。')
    if role == 'jump':
        say('重置后会生成新的连接信息；业务服务器若已粘贴过旧信息，也需在服务器执行 --reset 后重新粘贴。')
    else:
        say('重置后需要重新粘贴跳板机输出的 JUMP1: 信息。')
    if not yes('确认重置本机记录', False):
        fail('未重置。')
    path = state_path(role)
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    path.rename(path.with_name('state.json.reset-' + stamp))
    say('已重置。重新执行 sudo bash 本脚本.sh 即可重新填写。')


def can_sudo(account):
    try:
        listing = command(['sudo', '-n', '-l', '-U', account.pw_name], capture=True, check=False).stdout
        if 'may run the following commands' not in listing:
            return False
        if 'NOPASSWD' in listing:
            return True
        # 需要口令的 sudo 仅在账号口令可用时才有效。
        status = command(['passwd', '-S', account.pw_name], capture=True, check=False).stdout.split()
        return len(status) > 1 and status[1] == 'P'
    except OSError:
        return False


def warn_admin_access(role, account):
    # 收紧后 SSH 只剩这一个账号，提前说明管理入口的变化。
    admin = os.environ.get('SUDO_USER', '')
    if admin and admin not in ('root', account.pw_name):
        say(f'  注意：你当前用于 sudo 的账号 {admin} 收紧后将不能通过 SSH 登录本机。')
    if can_sudo(account):
        return
    where = '' if role == 'jump' else '（且只能从跳板）'
    say(f'  注意：未检测到 {account.pw_name} 可用的 sudo 权限。收紧后 SSH 只能以该账号{where}登录，'
        'root 与其他账号都无法 SSH；之后的管理只能经云控制台（VNC/云助手）。')
    if not yes('仍然继续', False):
        hint = ('执行 --reset 后改用有 sudo 的账号' if role == 'jump'
                else '两端执行 --reset，在跳板改填有 sudo 的服务器账号')
        fail(f'尚未收紧入口。可先为 {account.pw_name} 配置 sudo 后重跑，或{hint}。')


def lock_down(role, state, account, peer):
    if state.get('locked'):
        say('本机已完成收紧；本次保留现有安全设置。')
        return
    say('\n将应用以下设置：')
    if role == 'jump':
        say(f"  SSH 仅允许普通账号 {account.pw_name} 使用公钥登录；关闭 root SSH 与密码登录。")
        say(f"  UFW 入站允许 TCP {state['jump_port']} 与 UDP 60000–61000，支持你切换网络。")
    else:
        say(f"  SSH 仅允许 {account.pw_name} 从 {state['jump_source']} 使用公钥登录。")
        say(f"  UFW 入站仅允许 {state['jump_source']} → TCP {state['server_port']}；其余入站默认拒绝。")
    say('  UFW 出站允许；保留当前终端。出错会尝试恢复，控制台也可执行脚本 --rollback。')
    warn_admin_access(role, account)
    if not yes('现在应用上述设置'):
        fail('尚未收紧入口；已有安装和授权已保留，重新运行可以继续。')
    check_ufw_clean()
    snapshot_security(role)
    state['lock_started'] = True
    save_state(role, state)
    try:
        SSHD_FILE.parent.mkdir(parents=True, exist_ok=True)
        write_atomic(SSHD_FILE, hardening_text(role, account.pw_name, state.get('jump_source')), mode=0o644, backup=False)
        command(['/usr/sbin/sshd', '-t'])
        spec = f'user={account.pw_name},addr={peer},host={peer}'
        effective = command(['/usr/sbin/sshd', '-T', '-C', spec], capture=True).stdout
        settings = dict(line.split(' ', 1) for line in effective.splitlines())
        expected = {'pubkeyauthentication': 'yes', 'authenticationmethods': 'publickey',
                    'passwordauthentication': 'no', 'kbdinteractiveauthentication': 'no',
                    'permitrootlogin': 'no',
                    'allowusers': account.pw_name if role == 'jump' else f"{account.pw_name}@{state['jump_source']}"}
        if any(settings.get(key) != value for key, value in expected.items()):
            fail('新的 SSH 策略未完全生效，可能有较早的配置或 Match 规则。')
        reload_ssh()
        for args in firewall_plan(role, state):
            command(args)
        state['locked'] = True
        state['lock_started'] = False
        save_state(role, state)
    except BaseException:
        say('应用收紧时发生错误，正在恢复原安全设置……')
        restore_security(role, state)
        raise


def cli_start(role):
    global TTY
    args = sys.argv[1:]
    if args == ['--help']:
        say(f"Ubuntu 24.04 交互配置：{'跳板机' if role == 'jump' else '业务服务器'}。")
        say('用法：sudo bash 本脚本.sh；两端各开一个交互终端，先运行跳板脚本。')
        say('可用选项：--status 查看状态；--rollback 恢复脚本收紧前的 sshd/UFW；'
            '--reset 清除本机填写记录以便重填（仅限尚未收紧时）；--help。')
        say('输入 :quit 可以退出，重跑会读取本机状态继续。请勿通过 curl | bash 或非交互发送命令运行。')
        return False
    if args not in ([], ['--status'], ['--rollback'], ['--reset']):
        fail('未知参数，请使用 --help。')
    if os.geteuid() != 0:
        fail('请以 root 运行，或执行 sudo bash 本脚本.sh。')
    if args == ['--status']:
        state = load_state(role)
        say(json.dumps(state, ensure_ascii=False, indent=2) if state else '本机尚无本脚本配置记录。')
        return False
    if args == ['--rollback']:
        state = load_state(role)
        if not state:
            fail('本机没有本脚本的配置记录。')
        restore_security(role, state)
        return False
    try:
        TTY = open('/dev/tty', 'r', encoding='utf-8')
    except OSError:
        fail('需要交互终端。请使用 SSH、VNC 或控制台交互终端运行，而不是非交互“发送命令”。')
    if args == ['--reset']:
        reset_state(role)
        return False
    ensure_dir(STATE_ROOT)
    state = load_state(role)
    if state and state.get('lock_started') and not state.get('locked'):
        say('上次收紧过程未正常完成。')
        if yes('先恢复上次收紧前的安全设置'):
            restore_security(role, state)
        else:
            fail('请先执行 --rollback 或检查本机配置。')
    if not (state and state.get('locked')):
        preflight_security(role)
    say('\n请保留当前 root/可 sudo 的控制台终端，直到两端验证完成。')
    say('脚本不会修改 VPC、网卡、时区、磁盘或云安全组；普通新账号不会自动获得 sudo。')
    return True


def entrypoint(role, function):
    try:
        if cli_start(role):
            function()
    except (RuntimeError, ValueError, KeyError, OSError, subprocess.SubprocessError) as exc:
        say(f'\n未完成：{exc}')
        detail = getattr(exc, 'stderr', None)
        if isinstance(detail, bytes):
            detail = detail.decode(errors='replace')
        if detail and detail.strip():
            say('命令输出：' + detail.strip()[-2000:])
        say('已完成的安装和授权会保留。修复问题后重跑同一脚本；填写有误可用 --reset 重填；收紧设置可用 --rollback 恢复。')
        sys.exit(1)
    except KeyboardInterrupt:
        say('\n已中断；保留现有进度。重新运行同一脚本可继续。')
        sys.exit(130)


def collect_server_settings():
    say('先在跳板机运行 setup_jump.sh，复制其 JUMP1: 开头的完整单行信息。')
    data = ask('粘贴跳板连接信息', validate=lambda s: parse_card(s, 'jump'))
    if data['server_port'] != current_ssh_port():
        fail('连接信息中的服务器端口与本机现有 SSH 端口不符。请修正跳板端填写值。')
    if data['network'] == 'private':
        interfaces = json.loads(command(['ip', '-j', '-4', 'addr', 'show'], capture=True).stdout)
        addresses = [item['local'] for dev in interfaces for item in dev.get('addr_info', [])]
        if data['server_ip'] not in addresses:
            fail('连接信息中的服务器私网 IP 不属于本机，请确认没有在错误机器运行。')
    say('\n配置预览：')
    say(f"  业务服务器账号：{data['server_user']}")
    say(f"  本机连接地址：{data['server_ip']}:{data['server_port']}")
    say(f"  授权的跳板来源：{data['jump_source']}")
    say('  跳板专用公钥指纹：' + fingerprint(data['jump_key']))
    if not yes('以上信息与刚创建的跳板机一致，按此配置本机'):
        fail('未配置账号或授权。')
    return {'version': VERSION, 'role': 'server', 'session': data['session'],
            'server_ip': data['server_ip'], 'server_port': data['server_port'],
            'server_user': data['server_user'], 'jump_source': data['jump_source'],
            'network': data['network'], 'jump_key': data['jump_key'],
            'nonce': secrets.token_hex(16), 'locked': False}


def write_lock_marker(state):
    # 跳板复核时检查该文件；服务器 --rollback 时删除。
    account = pwd.getpwnam(state['server_user'])
    user_paths(account)
    write_atomic(lock_marker(account, state['nonce']), state['nonce'] + '\n',
                 account.pw_uid, account.pw_gid, backup=False)


def server_main():
    state = load_state('server')
    if state and state.get('locked') and state.get('finished'):
        # 补写“已收紧”标记（兼容旧版脚本完成的配置），供跳板复核。
        write_lock_marker(state)
        say(f"业务服务器已配置完成。SSH 账号 {state['server_user']}，仅允许跳板 {state['jump_source']}。")
        say('查看记录用 --status；恢复本机收紧前的设置用 --rollback。')
        return
    if not state:
        install_packages('server')
        state = collect_server_settings()
        save_state('server', state)
    account = get_account(state['server_user'])
    authorize(account, state['jump_key'], state['jump_source'])
    proof_path(account, 'server', state['nonce'])
    # 可从可信控制台导出主机公钥；没有主机私钥出现在连接信息中。
    host_path = Path('/etc/ssh/ssh_host_ed25519_key.pub')
    if not host_path.exists():
        fail('缺少服务器 Ed25519 主机公钥，请先检查 OpenSSH 安装。')
    host_key = validate_public_key(host_path.read_text())
    state['host_key'] = host_key
    save_state('server', state)
    fields =('session', 'server_ip', 'server_port', 'server_user', 'jump_source', 'nonce')
    card = make_card('server', {**{name: state[name] for name in fields}, 'host_key': host_key})
    write_atomic(STATE_ROOT / 'server/server_connection.txt', card + '\n', backup=False)
    proof = read_proof(account, 'server', state['nonce'], state['jump_source'], state['server_port'])
    if proof:
        # 跳板已用本次连接信息登录过（例如 --rollback 后重跑），无需再交换信息。
        say('\n已有跳板登录的验证结果（实际 SSH 来源 ' + proof[0] + '），无需再与跳板交换连接信息。')
    else:
        say('\n业务服务器 SSH 授权已完成；此时还未收紧入口。')
        say('服务器 Ed25519 主机指纹：' + fingerprint(host_key))
        say(f"阿里云安全组：入方向 TCP {state['server_port']}，来源 {state['jump_source']}/32。")
        say('先新增窄规则，验证跳板登录成功后再修改/移除宽泛 SSH 允许规则；出站保持可用。')
        say('\n复制下面整行到【跳板机脚本】等待输入的位置：')
        say(card)
        while True:
            pause('回到跳板机，粘贴上述信息并完成 SSH 测试，再回到这里。')
            proof = read_proof(account, 'server', state['nonce'], state['jump_source'], state['server_port'])
            if proof:
                say('已确认跳板使用专用公钥成功登录；实际 SSH 来源为 ' + proof[0])
                break
            say('尚未发现跳板登录的验证结果；保持此入口，先完成跳板端测试。')
    lock_down('server', state, account, state['jump_source'])
    write_lock_marker(state)
    state['finished'] = True
    save_state('server', state)
    summary = (f"业务服务器已配置完成。账号：{account.pw_name}；跳板来源：{state['jump_source']}。\n"
               '已安装 tmux、Git；SSH 仅密钥登录，系统防火墙限制 SSH 来源。\n'
               '如跳板脚本仍在等待，回到跳板机终端按回车；跳板会再次测试 SSH 并确认本机已收紧。\n'
               '日常登录后，进入项目目录，运行 claude；第一次的账号登录由你本人完成。\n'
               '云安全组仍需按输出规则配置；公网出口应保留供 Claude Code 使用。\n'
               '如需恢复本机收紧前设置，在原控制台执行：sudo bash setup_server.sh --rollback\n')
    write_atomic(STATE_ROOT / 'server/next_steps.txt', summary, backup=False)
    say('\n' + summary)


if __name__ == '__main__':
    entrypoint('server', server_main)

PYTHON_PAIRED_SETUP
