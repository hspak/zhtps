"""Bring up a private loopback interface and replace this process with a trial."""
import os
import subprocess
import sys

subprocess.run(["ip", "link", "set", "lo", "up"], check=True)
os.execvp(sys.argv[1], sys.argv[1:])
