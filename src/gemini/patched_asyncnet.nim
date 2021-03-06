import openssl
import strutils

include asyncnet

# this needs more cleaning

#proc SSL_get_verify_result(ssl: SslPtr): clong {.importc, dynlib: DLLSSLName.}

type PX509_STORE_CTX* = SslPtr
proc SSL_CTX_set_verify*(ctx: SslCtx, mode: int, cb: proc(preverify_ok: int, ctx: PX509_STORE_CTX): int {.cdecl.}) {.importc, dynlib: DLLSSLName.}
proc X509_STORE_CTX_get_error(ctx: PX509_STORE_CTX): int {.importc, dynlib: DLLSSLName.}

# certificate verification callback
# return 1 for accepting, 0 for rejecting the certifacte based on the error so far
# current implementation accepts self-signed certificates
proc verify_callback*(preverify: int, x509_ctx: PX509_STORE_CTX): int {.cdecl.} =
  let err = X509_STORE_CTX_get_error(x509_ctx)
  #echo "err: " & $err
  if err == X509_V_ERR_DEPTH_ZERO_SELF_SIGNED_CERT or err == X509_V_ERR_SELF_SIGNED_CERT_IN_CHAIN:
    return 1
  return preverify

proc getSslHandle*(socket: AsyncSocket): SslPtr =
  return socket.sslHandle

proc X509_print(bp: BIO, x: PX509): cint {.cdecl, dynlib: DLLSSLName, importc.}

proc `$`*(certificate: PX509): string =
  ## Get a string representation of an x509 certificate. Note that it's not the best way to inspect its fields.
  if certificate.isNil:
    return "(nil)"
  result = newString(100_000)
  var bp = bioNew(bioSMem())
  if X509_print(bp, certificate) != 0.cint:
    discard BIO_read(bp, result[0].addr, result.len.cint)
    discard BIO_free(bp)

proc X509_digest(data: PX509, digest: EVP_MD, md: cstring, len: ptr cint): cint {.cdecl, dynlib: DLLSSLName, importc.}
proc EVP_sha256(): EVP_MD {.cdecl, dynlib:DLLUtilName, importc: "EVP_sha256".}

proc sha256*(certificate: PX509): string =
  var
    data = newString(EVP_MAX_MD_SIZE)
    length: cint
  if certificate.isNil:
    return ""
  if X509_digest(certificate, EVP_sha256(), data[0].unsafeAddr, length.addr) > 0:
    return data[0..length - 1]
  return ""

proc fingerprint*(certificate: PX509, withColumns=true, computeHash: proc(certificate: PX509): string = sha256): string =
  let digest = computeHash(certificate)
  const HexChars = "0123456789abcdef"
  result = newString(digest.len * 3 - 1)
  for pos, c in digest:
    var n = ord(c)
    result[pos * 3 + 1] = HexChars[n and 0xF]
    n = n shr 4
    result[pos * 3] = HexChars[n]
    if withColumns and pos != digest.len - 1:
      result[pos * 3 + 2] = ':'
 
type PX509_NAME_ENTRY = SslPtr
type PASN1_STRING = SslPtr

proc X509_NAME_get_index_by_NID(name: PX509_NAME, nid: cint, lastpos: cint): cint {.cdecl, dynlib: DLLSSLName, importc.}
proc X509_NAME_get_entry(name: PX509_NAME, loc: cint): PX509_NAME_ENTRY {.cdecl, dynlib: DLLSSLName, importc.}
proc X509_NAME_ENTRY_get_data(ne: PX509_NAME_ENTRY): PASN1_STRING {.cdecl, dynlib: DLLSSLName, importc.}
proc ASN1_STRING_data(x: PASN1_STRING): cstring {.cdecl, dynlib: DLLSSLName, importc.}
proc ASN1_STRING_length(x: PASN1_STRING): cint {.cdecl, dynlib: DLLSSLName, importc.}

const NID_commonName = 13

# adapted from curl's legacy code https://wiki.openssl.org/index.php/Hostname_validation
proc commonName*(certificate: PX509): string =
  let common_name_loc = X509_NAME_get_index_by_NID(X509_get_subject_name(certificate), NID_commonName, -1)
  if common_name_loc < 0:
    return ""

  # Extract the CN field
  let common_name_entry = X509_NAME_get_entry(X509_get_subject_name(certificate), common_name_loc)
  if common_name_entry == nil:
    return ""

  # Convert the CN field to a C string
  let common_name_asn1 = X509_NAME_ENTRY_get_data(common_name_entry)
  if common_name_asn1 == nil:
    return ""
  
  let common_name_str = $ASN1_STRING_data(common_name_asn1)

  # Make sure there isn't an embedded NUL character in the CN
  if ASN1_STRING_length(common_name_asn1) != common_name_str.len:
    return ""

  return common_name_str
