"""Local Health MCP decryption. Dependency: pip install cryptography."""
import base64
import gzip
import hashlib
import json
import os
import re
import sys
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

def normalize_key(value: str) -> str:
    alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    key = re.sub(r"[-\s]", "", value.upper())
    if len(key) not in (17, 27) or any(c not in alphabet for c in key[:-1]):
        raise ValueError("Invalid key")
    check = 0
    for c in key[:-1]:
        check = (check * 32 + alphabet.index(c)) % 37
    if (alphabet + "*~$=U")[check] != key[-1]:
        raise ValueError("Invalid key checksum")
    return key

def decrypt(envelope: dict, user_key: str, path: str):
    if envelope.get("v") != 1 or envelope.get("alg") != "A256GCM" or envelope.get("kdf") != "sha256":
        raise ValueError("Unsupported envelope")
    normalized = normalize_key(user_key)
    domain = "healthmcp/v2:" if len(normalized) == 27 else "healthmcp/v1:"
    key = hashlib.sha256((domain + normalized).encode()).digest()
    iv, ciphertext = base64.b64decode(envelope["iv"], validate=True), base64.b64decode(envelope["ct"], validate=True)
    if len(iv) != 12 or len(ciphertext) < 18:
        raise ValueError("Invalid envelope")
    compressed = AESGCM(key).decrypt(iv, ciphertext, path.encode())
    import io
    with gzip.GzipFile(fileobj=io.BytesIO(compressed)) as stream:
        plaintext = stream.read(64 * 1024 * 1024 + 1)
    if len(plaintext) > 64 * 1024 * 1024:
        raise ValueError("Decompressed payload too large")
    return json.loads(plaintext)

if __name__ == "__main__":
    if len(sys.argv) != 3 or "HEALTHMCP_KEY" not in os.environ:
        sys.exit("Usage: HEALTHMCP_KEY=<sandbox secret> python decrypt.py envelope.json <manifest path>")
    with open(sys.argv[1], encoding="utf-8") as file:
        print(json.dumps(decrypt(json.load(file), os.environ["HEALTHMCP_KEY"], sys.argv[2])))
