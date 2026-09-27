"""Fenced "omarchy-liquid-glass" blocks in your config files.

Every block Liquid Glass writes is recorded by sha256 in
~/.config/omarchy-liquid-glass/blocks.sha256 ("sha256  path" per file). A block
counts as ours only while it is still exactly what we wrote: uninstall removes
only such blocks, and rewriting a block you changed keeps a copy of yours first.

    python3 blocks.py add    FILE PREFIX CONTENT_FILE BACKUP_DIR   # (re)write our block
    python3 blocks.py remove FILE PREFIX                           # exit 3 = kept (you changed it)

Writes go through symlinks and are atomic (temp file + rename).
"""
import hashlib
import os
import re
import sys

BEGIN = "omarchy-liquid-glass >>>"
END = "<<< omarchy-liquid-glass"
HASHES = os.path.join(os.path.expanduser("~"), ".config/omarchy-liquid-glass/blocks.sha256")


def pattern(prefix):
    b, e = re.escape(f"{prefix} {BEGIN}"), re.escape(f"{prefix} {END}")
    return re.compile(r"(?:\n|^)(" + b + r".*?" + e + r")\n?", re.S)


def digest(block):
    return hashlib.sha256(block.encode()).hexdigest()


def _hashes():
    out = {}
    try:
        with open(HASHES) as f:
            for line in f:
                if len(line) > 66:
                    out[line[66:].rstrip("\n")] = line[:64]
    except OSError:
        pass
    return out


def record(path, block):
    """Remember the block we just wrote to path (None = we have no block there)."""
    h = _hashes()
    if block is None:
        h.pop(path, None)
    else:
        h[path] = digest(block)
    write_atomic(HASHES, "".join(f"{v}  {k}\n" for k, v in sorted(h.items())))


def is_ours(path, block):
    return _hashes().get(path) == digest(block)


def write_atomic(path, text):
    real = os.path.realpath(path)
    os.makedirs(os.path.dirname(real), exist_ok=True)
    tmp = f"{real}.tmp-{os.getpid()}"
    with open(tmp, "w") as f:
        f.write(text)
    try:
        os.chmod(tmp, os.stat(real).st_mode & 0o7777)
    except OSError:
        pass
    os.replace(tmp, real)


def keep_copy(path, block, backup_dir):
    """Save a block you changed before we replace it; returns where it went."""
    dest = os.path.join(backup_dir, "changed-blocks") + os.path.abspath(path)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    n, out = 1, dest
    while os.path.exists(out):
        n += 1
        out = f"{dest}.{n}"
    with open(out, "w") as f:
        f.write(block + "\n")
    return out


def add(path, prefix, content, backup_dir):
    text = open(path).read() if os.path.exists(path) else ""
    m = pattern(prefix).search(text)
    if m and not is_ours(path, m.group(1)):
        print(f"!! you changed the Liquid Glass block in {path}; your version is at "
              f"{keep_copy(path, m.group(1), backup_dir)}")
    text = pattern(prefix).sub("", text)
    block = f"{prefix} {BEGIN}\n{content}\n{prefix} {END}"
    write_atomic(path, text + "\n" + block + "\n")
    record(path, block)


def remove(path, prefix):
    """0 = removed or nothing there, 3 = kept because you changed it."""
    if not os.path.exists(path):
        return 0
    text = open(path).read()
    m = pattern(prefix).search(text)
    if not m:
        record(path, None)
        return 0
    if not is_ours(path, m.group(1)):
        return 3
    write_atomic(path, pattern(prefix).sub("", text, count=1))
    record(path, None)
    return 0


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "add":
        _, _, f, prefix, content_file, bk = sys.argv
        add(f, prefix, open(content_file).read().rstrip("\n"), bk)
    elif cmd == "remove":
        sys.exit(remove(sys.argv[2], sys.argv[3]))
    else:
        sys.exit(f"unknown command {cmd}")
