import sys
import urllib.request

try:
    with urllib.request.urlopen("http://localhost:5000/", timeout=2) as response:
        sys.exit(0 if response.status == 200 else 1)
except Exception:
    sys.exit(1)
