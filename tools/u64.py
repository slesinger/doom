"""Minimal client for the Ultimate REST API (firmware >= 3.11 / C64U 1.x).

Standard library only -- this runs from the Makefile on a bare machine.

The API is documented at
https://1541u-documentation.readthedocs.io/en/latest/api/api_calls.html
and every JSON response carries an ``errors`` array, which this module
turns into an exception so callers never have to check it.

Verified against: product "C64 Ultimate", firmware 1.1.0, FPGA 122,
core 1.49.
"""

from __future__ import annotations

import json
import socket
import time
import urllib.error
import urllib.parse
import urllib.request
from ftplib import FTP

DEFAULT_TIMEOUT = 15


class U64Error(RuntimeError):
    pass


class Ultimate:
    def __init__(self, host: str, password: str | None = None,
                 timeout: int = DEFAULT_TIMEOUT):
        self.host = host
        self.password = password
        self.timeout = timeout

    # -- plumbing ---------------------------------------------------

    def _url(self, path: str, params: dict | None = None) -> str:
        url = f"http://{self.host}{path}"
        if params:
            # quote_via=quote so that ':' and '*' in item paths survive; the
            # firmware matches config items with shell-style wildcards.
            url += "?" + urllib.parse.urlencode(params)
        return url

    def _request(self, method: str, path: str, params: dict | None = None,
                 body: bytes | None = None,
                 content_type: str | None = None) -> bytes:
        req = urllib.request.Request(self._url(path, params), data=body,
                                     method=method)
        if self.password:
            req.add_header("X-Password", self.password)
        if content_type:
            req.add_header("Content-Type", content_type)
        if body is not None:
            req.add_header("Content-Length", str(len(body)))
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return resp.read()
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace").strip()
            if exc.code == 403:
                raise U64Error(
                    f"{method} {path}: 403 Forbidden -- the Ultimate has a "
                    f"Network Password set; pass --password") from None
            raise U64Error(f"{method} {path}: HTTP {exc.code} {detail}") from None
        except (urllib.error.URLError, socket.timeout, OSError) as exc:
            raise U64Error(f"{method} {path}: {exc}") from None

    def _json(self, method: str, path: str, params: dict | None = None,
              body: bytes | None = None,
              content_type: str | None = None) -> dict:
        raw = self._request(method, path, params, body, content_type)
        if not raw.strip():
            return {}
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            raise U64Error(
                f"{method} {path}: response is not JSON: "
                f"{raw[:200]!r}") from None
        errors = data.get("errors") or []
        if errors:
            raise U64Error(f"{method} {path}: {'; '.join(errors)}")
        return data

    # -- about ------------------------------------------------------

    def version(self) -> dict:
        return self._json("GET", "/v1/version")

    def info(self) -> dict:
        return self._json("GET", "/v1/info")

    # -- configuration ----------------------------------------------

    def get_category(self, category: str) -> dict:
        path = "/v1/configs/" + urllib.parse.quote(category)
        return self._json("GET", path).get(category, {})

    def set_item(self, category: str, item: str, value) -> None:
        path = ("/v1/configs/" + urllib.parse.quote(category)
                + "/" + urllib.parse.quote(item))
        self._json("PUT", path, params={"value": str(value)})

    def save_config_to_flash(self) -> None:
        self._json("PUT", "/v1/configs:save_to_flash")

    # -- machine ----------------------------------------------------

    def reset(self) -> None:
        self._json("PUT", "/v1/machine:reset")

    def run_prg(self, data: bytes) -> None:
        """Reset, DMA the PRG into memory, and start it."""
        self._json("POST", "/v1/runners:run_prg", body=data,
                   content_type="application/octet-stream")

    def run_prg_basic(self, data: bytes, settle: float = 5.0) -> None:
        """Start a PRG the way a human would, keeping the cartridge alive.

        ``run_prg`` is the obvious call and it is wrong for anything that
        touches the Ultimate's cartridge personality. It injects the
        program by a path that leaves the cartridge disabled: with "RAM
        Expansion Unit" set to "GeoRAM Mode", the window at $de00 reads
        as open bus for every program started that way. The REU is not a
        cartridge and survives it, which is why this went unnoticed for
        as long as the project only used the REU -- and why a GeoRAM
        probe delivered by ``run_prg`` reports "no device" on a machine
        where memtest64, loaded normally, finds 4 MB.

        This resets, DMAs the program into RAM, fixes BASIC's
        end-of-program pointer so RUN believes in it, and types RUN
        through the keyboard buffer. The machine ends up in exactly the
        state an ordinary load-and-run leaves it in.

        ``settle`` is how long to wait for the KERNAL to finish booting
        before the DMA lands; too short and the reset wipes the program
        back out.
        """
        load = data[0] | (data[1] << 8)
        body = data[2:]
        end = load + len(body)
        self.reset()
        time.sleep(settle)
        self.writemem(load, body)
        self.writemem(0x2D, bytes([end & 0xFF, end >> 8]))  # VARTAB
        self.writemem(0x0277, b"RUN\r")                     # keyboard buffer
        self.writemem(0x00C6, b"\x04")                      # ...and its length

    def readmem(self, address: int, length: int = 256) -> bytes:
        """DMA-read C64 memory. Returns raw bytes, not JSON."""
        return self._request("GET", "/v1/machine:readmem",
                             params={"address": f"{address:04X}",
                                     "length": str(length)})

    def writemem(self, address: int, data: bytes) -> None:
        self._json("POST", "/v1/machine:writemem",
                   params={"address": f"{address:04X}"},
                   body=data, content_type="application/octet-stream")

    # -- files (FTP; the REST file API is still incomplete) ----------

    def ftp_put(self, local_path: str, remote_path: str) -> int:
        """Upload a file, creating parent directories as needed.

        The Ultimate's FTP service allows anonymous login. Returns the
        number of bytes sent.
        """
        remote_path = "/" + remote_path.lstrip("/")
        directory, _, name = remote_path.rpartition("/")
        sent = 0

        def count(block):
            nonlocal sent
            sent += len(block)

        ftp = FTP()
        try:
            ftp.connect(self.host, 21, self.timeout)
            ftp.login()
            if directory:
                for part in directory.strip("/").split("/"):
                    try:
                        ftp.cwd(part)
                    except Exception:
                        ftp.mkd(part)
                        ftp.cwd(part)
            with open(local_path, "rb") as fh:
                ftp.storbinary(f"STOR {name}", fh, callback=count)
        except U64Error:
            raise
        except Exception as exc:
            raise U64Error(f"FTP upload of {remote_path} failed: {exc}") from None
        finally:
            try:
                ftp.quit()
            except Exception:
                pass
        return sent


def add_host_args(parser) -> None:
    """Shared --password / host handling for the u64* command line tools."""
    parser.add_argument("host", nargs="?", default="u64",
                        help="hostname or IP of the Ultimate (default: u64)")
    parser.add_argument("--password", default=None,
                        help="value for the X-Password header, if the "
                             "Ultimate has a Network Password set")
