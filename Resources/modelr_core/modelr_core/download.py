"""Download utilities for Modelr."""

import hashlib
import ssl
import time
import os
from typing import Callable, Optional
from urllib.request import urlopen, Request
from urllib.error import URLError, HTTPError
import socket


MAX_DOWNLOAD_SIZE = 2 * 1024 * 1024 * 1024  # 2GB


def compute_sha256(filepath: str, chunk_size: int = 8192) -> str:
    sha256_hash = hashlib.sha256()
    with open(filepath, "rb") as f:
        for byte_block in iter(lambda: f.read(chunk_size), b""):
            sha256_hash.update(byte_block)
    return sha256_hash.hexdigest()


def create_secure_ssl_context() -> ssl.SSLContext:
    context = ssl.create_default_context()
    context.check_hostname = True
    context.verify_mode = ssl.CERT_REQUIRED
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    return context


def _retry_download(func):
    def wrapper(*args, **kwargs):
        max_retries = 3
        base_wait = 1.0

        for attempt in range(max_retries):
            try:
                return func(*args, **kwargs)
            except (URLError, HTTPError, socket.timeout, socket.error) as e:
                if attempt < max_retries - 1:
                    wait_time = base_wait * (2**attempt)
                    print(
                        f"Download attempt {attempt + 1} failed: {e}. Retrying in {wait_time:.1f}s...",
                        file=__import__("sys").stderr,
                    )
                    time.sleep(wait_time)
                else:
                    raise
        return False

    return wrapper


@_retry_download
def download_with_progress(
    url: str,
    path: str,
    progress_callback: Optional[Callable[[int, int], None]] = None,
    max_size: int = MAX_DOWNLOAD_SIZE,
) -> bool:
    import sys

    try:
        request = Request(url, headers={"User-Agent": "Mozilla/5.0"})
        context = create_secure_ssl_context()

        print(f"Downloading from {url}", file=sys.stderr)

        with urlopen(request, context=context, timeout=30) as response:
            if response.status != 200:
                raise HTTPError(
                    url,
                    response.status,
                    f"HTTP {response.status}",
                    response.headers,
                    None,
                )

            content_length = int(response.headers.get("Content-Length", 0))
            if content_length > max_size:
                error_msg = f"Download size {content_length} exceeds maximum {max_size}"
                print(f"ERROR: {error_msg}", file=sys.stderr)
                return False

            downloaded = 0
            with open(path, "wb") as f:
                while True:
                    chunk = response.read(8192)
                    if not chunk:
                        break
                    f.write(chunk)
                    downloaded += len(chunk)

                    if progress_callback and content_length > 0:
                        progress_callback(downloaded, content_length)

            if content_length > 0 and os.path.getsize(path) != content_length:
                error_msg = f"Download incomplete. Got {os.path.getsize(path)}, expected {content_length}"
                print(f"ERROR: {error_msg}", file=sys.stderr)
                os.remove(path)
                return False

            print("Download complete", file=sys.stderr)
            return True

    except (URLError, HTTPError, socket.timeout, socket.error) as e:
        print(f"ERROR: Download failed: {e}", file=sys.stderr)
        if os.path.exists(path):
            os.remove(path)
        return False
    except Exception as e:
        print(f"ERROR: Unexpected error during download: {e}", file=sys.stderr)
        if os.path.exists(path):
            os.remove(path)
        return False
