#!/usr/bin/env python3
"""git.py — dulwich porcelain wrapper (bypasses dulwich CLI's broken `add`).

Usage (run inside the repo directory for add/commit/push/log/status):
  python3 git.py clone <url> [dir]
  python3 git.py init [dir]
  python3 git.py add [path...]        (default: .)
  python3 git.py commit -m <msg>
  python3 git.py push [remote] [refspec]   (default: origin refs/heads/main)
  python3 git.py log
  python3 git.py status
"""
import sys

from dulwich import porcelain


def usage():
    print(__doc__)
    sys.exit(1)


def main():
    argv = sys.argv[1:]
    if not argv:
        usage()
    cmd = argv[0]
    args = argv[1:]

    if cmd == "clone":
        if not args:
            usage()
        url = args[0]
        target = args[1] if len(args) > 1 else None
        porcelain.clone(url, target)
        print("cloned %s -> %s" % (url, target or "."))
    elif cmd == "init":
        path = args[0] if args else "."
        porcelain.init(path)
        print("initialized %s" % path)
    elif cmd == "add":
        paths = args or ["."]
        porcelain.add(".", paths=paths)
        print("added %s" % (paths,))
    elif cmd == "commit":
        msg = None
        if "-m" in args or "--message" in args:
            key = "-m" if "-m" in args else "--message"
            i = args.index(key)
            msg = args[i + 1] if i + 1 < len(args) else None
        if not msg:
            print("error: commit requires -m <msg>")
            sys.exit(1)
        cid = porcelain.commit(".", message=msg)
        if isinstance(cid, bytes):
            cid = cid.decode()
        print("committed %s" % cid)
    elif cmd == "push":
        remote = args[0] if args else "origin"
        refspec = args[1] if len(args) > 1 else "refs/heads/main"
        res = porcelain.push(".", remote, refspec)
        print("pushed to %s %s" % (remote, refspec))
    elif cmd == "log":
        from dulwich.repo import Repo
        r = Repo(".")
        for entry in r.get_walker():
            sha = entry.commit.id
            msg = entry.commit.message
            if isinstance(sha, bytes):
                sha = sha.decode()
            if isinstance(msg, bytes):
                msg = msg.decode()
            print(sha[:12], msg.strip().split("\n")[0])
    elif cmd == "status":
        st = porcelain.status(".")
        print("staged:   %s" % (list(st.staged.keys()) if hasattr(st.staged, "keys") else st.staged))
        print("unstaged: %s" % st.unstaged)
    else:
        usage()


if __name__ == "__main__":
    main()
