"""Exercise the count prompt on a Linux PTY with test data only."""
import fcntl
import os
import select
import subprocess
import sys
import termios
import time


mode, *command = sys.argv[1:]
master, slave = os.openpty()
settings = termios.tcgetattr(slave)
settings[3] |= termios.ICANON
if mode == 'noncanonical':
    settings[3] &= ~termios.ICANON
termios.tcsetattr(slave, termios.TCSANOW, settings)


def controlling_tty():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)


env = os.environ.copy()
env.pop('CLAUDEOS_SHIP_TEST_IMPORTANT', None)
if mode != 'valid':
    env.pop('CLAUDEOS_SHIP_TEST_PASSPHRASE', None)
with subprocess.Popen(command, stdin=slave, stdout=slave, stderr=slave,
                      env=env, preexec_fn=controlling_tty) as child:
    try:
        buf = bytearray()
        sent = False
        deadline = time.monotonic() + 8
        while child.poll() is None or select.select([master], [], [], 0)[0]:
            assert time.monotonic() < deadline, 'CLI did not complete'
            if select.select([master], [], [], 0.05)[0]:
                buf.extend(os.read(master, 4096))
            if not sent and '件数を入力してください'.encode() in buf:
                if mode == 'noncanonical':
                    raise AssertionError('noncanonical TTY must not be prompted')
                data = {'valid': b'0\n', 'incomplete': b'0\x04',
                        'overlong': b'0' * 4500 + b'\n'}[mode]
                while data:
                    data = data[os.write(master, data):]
                sent = True
        status = child.wait()
        assert not select.select([slave], [], [], 0)[0], 'unconsumed input remains'
        if mode == 'valid':
            assert status == 0 and b'attestation_id' in buf
        else:
            expected = {'incomplete': b'IMPORTANT_INPUT_INCOMPLETE',
                        'overlong': b'IMPORTANT_INPUT_TOO_LONG',
                        'noncanonical': b'IMPORTANT_INPUT_TTY_MODE'}[mode]
            assert status != 0 and expected in buf and b'attestation_id' not in buf
            assert 'パスフレーズ:'.encode() not in buf
    except (AssertionError, OSError):
        # Do not echo terminal input or any prompt content into test logs.
        sys.stderr.write('TTY count test failed: ' + mode + '\n')
        raise
    finally:
        if child.poll() is None:
            child.kill()
        os.close(master)
        os.close(slave)
