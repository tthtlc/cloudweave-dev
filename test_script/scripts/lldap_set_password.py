#!/usr/bin/env python3
"""Set an LLDAP user's password via a minimal stdlib-only LDAP client.

This replaces the external ``ldappasswd`` / ``openldap-clients`` dependency.
LLDAP's GraphQL API (in the version deployed here) exposes no password
mutation, so the initial password must be set over LDAP. This module speaks
just enough BER/ASN.1 + LDAP (RFC 4511) to:

  1. Bind (simple auth) as the LLDAP admin.
  2. Send a ModifyRequest that *replaces* the target user's ``userPassword``
     attribute with the supplied plaintext value. LLDAP hashes the value
     server-side on write (same behaviour as ``ldappasswd -s``).
  3. Unbind and close.

No third-party packages are required — only the Python standard library.

Configuration is read from environment variables so that secrets (bind
password, new password) do not appear in ``ps``/argv:

  LLDAP_LDAP_HOST   default localhost
  LLDAP_LDAP_PORT   default 3890
  LLDAP_BIND_DN     e.g. uid=admin,ou=people,dc=libcloud,dc=local
  LLDAP_BIND_PW     bind password (required)
  LLDAP_USER_DN     e.g. uid=alice,ou=people,dc=libcloud,dc=local
  LLDAP_NEW_PW      new password (required)

Exit status:
  0  password set successfully
  1  usage / missing env
  2  bind failed (auth)
  3  modify failed (server returned non-success result code)
  4  network / protocol error
"""

import os
import socket
import sys


# --------------------------------------------------------------------------
# BER / ASN.1 primitive encoders
# --------------------------------------------------------------------------

def _enc_length(n: int) -> bytes:
    if n < 0:
        raise ValueError("negative length")
    if n < 0x80:
        return bytes([n])
    out = b""
    while n > 0:
        out = bytes([n & 0xFF]) + out
        n >>= 8
    return bytes([0x80 | len(out)]) + out


def _tlv(tag: int, value: bytes) -> bytes:
    return bytes([tag]) + _enc_length(len(value)) + value


def enc_integer(n: int) -> bytes:
    # Minimal two's-complement encoding; we only need small non-negative values
    # (LDAP version 3, message IDs, the replace(2) operation).
    if n == 0:
        body = b"\x00"
    elif n > 0:
        body = b""
        v = n
        while v > 0:
            body = bytes([v & 0xFF]) + body
            v >>= 8
        if body[0] & 0x80:
            body = b"\x00" + body
    else:
        # Negative path — not used here, but keep it correct for completeness.
        nbytes = (n.bit_length() + 8) // 8 or 1
        body = (n & ((1 << (8 * nbytes)) - 1)).to_bytes(nbytes, "big")
        if not (body[0] & 0x80):
            body = b"\xff" + body
    return _tlv(0x02, body)


def enc_octet_string(s: bytes) -> bytes:
    return _tlv(0x04, s)


def enc_enumerated(n: int) -> bytes:
    # Same encoding as INTEGER, different tag (0x0A).
    if n == 0:
        body = b"\x00"
    else:
        body = b""
        v = n
        while v > 0:
            body = bytes([v & 0xFF]) + body
            v >>= 8
        if n > 0 and (body[0] & 0x80):
            body = b"\x00" + body
    return _tlv(0x0A, body)


def enc_sequence(parts) -> bytes:
    return _tlv(0x30, b"".join(parts))


def enc_set(parts) -> bytes:
    return _tlv(0x31, b"".join(parts))


# --------------------------------------------------------------------------
# BER decoding (cursor over an in-memory buffer)
# --------------------------------------------------------------------------

class _Reader:
    def __init__(self, data: bytes):
        self.data = data
        self.pos = 0

    def at_end(self) -> bool:
        return self.pos >= len(self.data)

    def read_tlv(self):
        if self.at_end():
            raise EOFError("unexpected end of BER data")
        tag = self.data[self.pos]
        self.pos += 1
        first = self.data[self.pos]
        self.pos += 1
        if first < 0x80:
            length = first
        else:
            nbytes = first & 0x7F
            if nbytes == 0:
                raise ValueError("indefinite BER length not supported")
            length = 0
            for _ in range(nbytes):
                length = (length << 8) | self.data[self.pos]
                self.pos += 1
        value = self.data[self.pos:self.pos + length]
        if len(value) != length:
            raise EOFError("truncated BER value")
        self.pos += length
        return tag, value


def _decode_int(body: bytes) -> int:
    if not body:
        return 0
    n = int.from_bytes(body, "big", signed=True)
    return n


# --------------------------------------------------------------------------
# Socket-level BER reader (framed on a streaming socket)
# --------------------------------------------------------------------------

def _sock_read_exact(sock: socket.socket, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError("socket closed mid-message")
        buf += chunk
    return buf


def _sock_read_tlv(sock: socket.socket):
    tag = _sock_read_exact(sock, 1)[0]
    first = _sock_read_exact(sock, 1)[0]
    if first < 0x80:
        length = first
    else:
        nbytes = first & 0x7F
        if nbytes == 0:
            raise ValueError("indefinite BER length not supported")
        length = int.from_bytes(_sock_read_exact(sock, nbytes), "big")
    value = _sock_read_exact(sock, length) if length else b""
    return tag, value


# --------------------------------------------------------------------------
# LDAP message encoding
# --------------------------------------------------------------------------

# Application tags (RFC 4511 §4.
#   BindRequest  [APPLICATION 0]  -> 0x60 (constructed)
#   BindResponse [APPLICATION 1]  -> 0x61 (constructed)
#   UnbindRequest[APPLICATION 2]  -> 0x42 (primitive, NULL)
#   ModifyRequest[APPLICATION 6]  -> 0x66 (constructed)
#   ModifyResponse[APPLICATION 7] -> 0x67 (constructed)
# Context tag for simple auth: [0] primitive -> 0x80

LDAP_RESULT_CODES = {
    0: "success",
    1: "operationsError",
    2: "protocolError",
    7: "authMethodNotSupported",
    8: "strongerAuthRequired",
    14: "saslBindInProgress",
    16: "noSuchAttribute",
    17: "undefinedAttributeType",
    20: "attributeOrValueExists",
    21: "invalidAttributeSyntax",
    32: "noSuchObject",
    48: "inappropriateAuthentication",
    49: "invalidCredentials",
    50: "insufficientAccessRights",
    53: "unwillingToPerform",
    64: "namingViolation",
    65: "objectClassViolation",
    69: "entryCannotBeRemoved",
    80: "other",
}


def _ldap_message(msg_id: int, protocol_op: bytes) -> bytes:
    return enc_sequence([enc_integer(msg_id), protocol_op])


def encode_bind_request(version: int, dn: bytes, password: bytes) -> bytes:
    # [APPLICATION 0] SEQUENCE { version, name, simple } — the APPLICATION tag
    # (0x60) IS the constructed sequence; fields go directly inside it, with no
    # extra 0x30 wrapper. (Double-wrapping is what LLDAP rejects by closing the
    # connection.)
    body = b"".join([
        enc_integer(version),
        enc_octet_string(dn),
        _tlv(0x80, password),  # simple auth, context [0] primitive
    ])
    return _tlv(0x60, body)  # BindRequest [APPLICATION 0] constructed


def encode_modify_request(user_dn: bytes, attr: bytes, new_value: bytes) -> bytes:
    # changes ::= SEQUENCE OF SEQUENCE { operation ENUMERATED, modification SEQUENCE }
    change = enc_sequence([
        enc_enumerated(2),  # replace
        enc_sequence([
            enc_octet_string(attr),
            enc_set([enc_octet_string(new_value)]),
        ]),
    ])
    # [APPLICATION 6] SEQUENCE { object, changes } — fields directly under 0x66.
    body = enc_octet_string(user_dn) + enc_sequence([change])
    return _tlv(0x66, body)  # ModifyRequest [APPLICATION 6] constructed


def encode_unbind_request() -> bytes:
    # UnbindRequest [APPLICATION 2] NULL -> 0x42 0x00
    return bytes([0x42, 0x00])


# --------------------------------------------------------------------------
# LDAP response parsing
# --------------------------------------------------------------------------

def _parse_ldap_result(app_tag: int, value: bytes):
    """Return (resultCode, diagnosticMessage) from a *Response protocolOp.

    The response (e.g. BindResponse [APPLICATION 1]) is an APPLICATION-tagged
    SEQUENCE: the LDAPResult fields (resultCode, matchedDN, diagnosticMessage)
    sit directly inside the APPLICATION tag — there is no inner 0x30 wrapper.
    """
    r = _Reader(value)
    code_tag, code_body = r.read_tlv()  # resultCode ENUMERATED
    if code_tag != 0x0A:
        raise ValueError(f"expected ENUMERATED resultCode, got tag {code_tag:#x}")
    result_code = _decode_int(code_body)
    _matched_dn_tag, _ = r.read_tlv()  # matchedDN OCTET STRING
    diag_tag, diag_body = r.read_tlv()  # diagnosticMessage OCTET STRING
    diagnostic = diag_body.decode("utf-8", "replace") if diag_tag == 0x04 else ""
    return result_code, diagnostic


def _read_response(sock: socket.socket, expected_app_tag: int):
    """Read one LDAPMessage, verify its protocolOp tag, return LDAPResult."""
    tag, value = _sock_read_tlv(sock)
    if tag != 0x30:
        raise ValueError(f"expected LDAPMessage SEQUENCE, got tag {tag:#x}")
    r = _Reader(value)
    _id_tag, _id_body = r.read_tlv()  # messageID
    op_tag, op_value = r.read_tlv()
    if op_tag != expected_app_tag:
        raise ValueError(
            f"expected response tag {expected_app_tag:#x}, got {op_tag:#x}"
        )
    return _parse_ldap_result(op_tag, op_value)


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

def main() -> int:
    host = os.environ.get("LLDAP_LDAP_HOST", "localhost")
    port = int(os.environ.get("LLDAP_LDAP_PORT", "3890"))
    bind_dn = os.environ.get("LLDAP_BIND_DN", "")
    bind_pw = os.environ.get("LLDAP_BIND_PW", "")
    user_dn = os.environ.get("LLDAP_USER_DN", "")
    new_pw = os.environ.get("LLDAP_NEW_PW", "")

    missing = [k for k, v in [
        ("LLDAP_BIND_DN", bind_dn),
        ("LLDAP_BIND_PW", bind_pw),
        ("LLDAP_USER_DN", user_dn),
        ("LLDAP_NEW_PW", new_pw),
    ] if not v]
    if missing:
        print(f"lldap_set_password: missing env: {', '.join(missing)}", file=sys.stderr)
        return 1

    sock = None
    try:
        sock = socket.create_connection((host, port), timeout=10)
        # 1) Bind as the admin.
        sock.sendall(_ldap_message(1, encode_bind_request(3, bind_dn.encode("utf-8"), bind_pw.encode("utf-8"))))
        code, diag = _read_response(sock, 0x61)  # BindResponse
        if code != 0:
            name = LDAP_RESULT_CODES.get(code, str(code))
            print(f"lldap_set_password: bind failed: {name} ({code}): {diag}", file=sys.stderr)
            return 2
        # 2) Modify userPassword (replace). LLDAP hashes the plaintext value.
        sock.sendall(_ldap_message(
            2,
            encode_modify_request(user_dn.encode("utf-8"), b"userPassword", new_pw.encode("utf-8")),
        ))
        code, diag = _read_response(sock, 0x67)  # ModifyResponse
        if code != 0:
            name = LDAP_RESULT_CODES.get(code, str(code))
            print(f"lldap_set_password: modify failed: {name} ({code}): {diag}", file=sys.stderr)
            return 3
        # 3) Unbind (no response expected) and close.
        try:
            sock.sendall(_ldap_message(3, encode_unbind_request()))
        except OSError:
            pass
        print(f"lldap_set_password: OK password set for {user_dn}", file=sys.stderr)
        return 0
    except (OSError, EOFError, ValueError) as exc:
        print(f"lldap_set_password: network/protocol error: {exc}", file=sys.stderr)
        return 4
    finally:
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass


if __name__ == "__main__":
    sys.exit(main())
