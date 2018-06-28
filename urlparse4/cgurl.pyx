from urlparse4.mozilla_url_parse cimport *
from urlparse4.chromium_gurl cimport GURL
from urlparse4.chromium_url_constant cimport *
from urlparse4.chromium_url_util_internal cimport CompareSchemeComponent
from urlparse4.chromium_url_util cimport IsStandard, Canonicalize
from urlparse4.chromium_url_canon cimport CanonicalizePath, CanonicalizeQuery, CanonicalizeRef
from urlparse4.chromium_url_canon_stdstring cimport StdStringCanonOutput
from urlparse4.chromium_url_canon cimport CharsetConverter

import six
from six.moves.urllib.parse import urlsplit as stdlib_urlsplit
from six.moves.urllib.parse import urljoin as stdlib_urljoin
from six.moves.urllib.parse import urlunsplit as stdlib_urlunsplit
from six.moves.urllib.parse import urlparse as stdlib_urlparse
from six.moves.urllib.parse import urlunparse as stdlib_urlunparse
import string as py_string

cimport cython
from libcpp.string cimport string
from libcpp cimport bool


uses_params = [b'', b'ftp', b'hdl',
               b'prospero', b'http', b'imap',
               b'https', b'shttp', b'rtsp',
               b'rtspu', b'sip', b'sips',
               b'mms', b'sftp', b'tel']

cdef bytes slice_component(bytes pyurl, Component comp):
    if comp.len <= 0:
        return b""

    return pyurl[comp.begin:comp.begin + comp.len]


cdef bytes cslice_component(char * url, Component comp):
    if comp.len <= 0:
        return b""

    # TODO: check if std::string brings any speedups
    return url[comp.begin:comp.begin + comp.len]


cdef bytes build_netloc(bytes url, Parsed parsed):
    if parsed.host.len <= 0:
        return b""

    # Nothing at all
    elif parsed.username.len <= 0 and parsed.password.len <= 0 and parsed.port.len <= 0:
        return url[parsed.host.begin: parsed.host.begin + parsed.host.len]

    # Only port
    elif parsed.username.len <= 0 and parsed.password.len <= 0 and parsed.port.len > 0:
        return url[parsed.host.begin: parsed.host.begin + parsed.host.len + 1 + parsed.port.len]

    # Only username
    elif parsed.username.len > 0 and parsed.password.len <= 0 and parsed.port.len <= 0:
        return url[parsed.username.begin: parsed.username.begin + parsed.host.len + 1 + parsed.username.len]

    # Username + password
    elif parsed.username.len > 0 and parsed.password.len > 0 and parsed.port.len <= 0:
        return url[parsed.username.begin: parsed.username.begin + parsed.host.len + 2 + parsed.username.len + parsed.password.len]

    # Username + port
    elif parsed.username.len > 0 and parsed.password.len <= 0 and parsed.port.len > 0:
        return url[parsed.username.begin: parsed.username.begin + parsed.host.len + 2 + parsed.username.len + parsed.port.len]

    # Username + port + password
    elif parsed.username.len > 0 and parsed.password.len > 0 and parsed.port.len > 0:
        return url[parsed.username.begin: parsed.username.begin + parsed.host.len + 3 + parsed.port.len  + parsed.username.len  + parsed.password.len]

    else:
        raise ValueError


cdef bytes unicode_handling(str):
    cdef bytes bytes_str
    if isinstance(str, unicode):
        bytes_str = <bytes>(<unicode>str).encode('utf8')
    else:
        bytes_str = <bytes>str
    return bytes_str

cdef void parse_input_url(bytes url, Component url_scheme, Parsed * parsed):
    if CompareSchemeComponent(url, url_scheme, kFileScheme):
        ParseFileURL(url, len(url), parsed)
    elif CompareSchemeComponent(url, url_scheme, kFileSystemScheme):
        ParseFileSystemURL(url, len(url), parsed)
    elif IsStandard(url, url_scheme):
        ParseStandardURL(url, len(url), parsed)
    elif CompareSchemeComponent(url, url_scheme, kMailToScheme):
        """
        Discuss: Is this correct?
        """
        ParseMailtoURL(url, len(url), parsed)
    else:
        """
        TODO:
        trim or not to trim?
        """
        ParsePathURL(url, len(url), True, parsed)

cdef object extra_attr(obj, prop, bytes url, Parsed parsed, decoded, params=False):
    if prop == "scheme":
        return obj[0]
    elif prop == "netloc":
        return obj[1]
    elif prop == "path":
        return obj[2]
    elif params and prop == "params":
        return obj[3]
    elif prop == "query":
        if params:
            return obj[4]
        return obj[3]
    elif prop == "fragment":
        if params:
            return obj[5]
        return obj[4]
    elif prop == "port":
        if parsed.port.len > 0:
            port = slice_component(url, parsed.port)
            try:
                port = int(port, 10)
            except ValueError:
                message = f'Port could not be cast to integer value as {port!r}'
                raise ValueError(message) from None
            if not ( 0 <= port <= 65535):
                raise ValueError("Port out of range 0-65535")
            return port
    elif prop == "username":
        username = slice_component(url, parsed.username)
        if decoded:
            return username.decode('utf-8') or None
        return username or None
    elif prop == "password":
        password = slice_component(url, parsed.password)
        if decoded:
            return password.decode('utf-8') or None
        return password or None
    elif prop == "hostname":
        hostname = slice_component(url, parsed.host).lower()
        if len(hostname) > 0 and chr(hostname[0]) == '[':
            hostname = hostname[1:-1]
        if decoded:
            return hostname.decode('utf-8') or None
        return hostname or None

# https://github.com/python/cpython/blob/master/Lib/urllib/parse.py
cdef object _splitparams(string path):
    """
    this function can be modified to enhance the performance?
    """
    cdef char slash_char = b'/'
    cdef string slash_string = b'/'
    cdef string semcol = b';'
    cdef int i

    if path.find(slash_string) != -1:
        i = path.find(semcol, path.rfind(slash_char))
        if i < 0:
            return path, b''
    else:
        i = path.find(semcol)
    return path.substr(0, i), path.substr(i + 1)

cdef string canonicalize_path(char * url, Parsed parsed):
    cdef Component out_path
    cdef string output_string = string()
    cdef StdStringCanonOutput * output = new StdStringCanonOutput(&output_string)
    is_valid = CanonicalizePath(url, parsed.path, output, &out_path)
    output.Complete()

    return output_string

cdef string canonicalize_query(char * url, Parsed parsed):
    cdef Component out_query
    cdef string output_string = string()
    cdef StdStringCanonOutput * output = new StdStringCanonOutput(&output_string)
    CanonicalizeQuery(url, parsed.query, NULL, output, &out_query)
    output.Complete()

    if output_string.length() > 0 and output_string[0] == "?":
        output_string = output_string.substr(1)

    return output_string

cdef string canonicalize_fragment(char * url, Parsed parsed):
    cdef Component out_fragment
    cdef string output_string = string()
    cdef StdStringCanonOutput * output = new StdStringCanonOutput(&output_string)
    CanonicalizeRef(url, parsed.ref, output, &out_fragment)
    output.Complete()

    return output_string

# @cython.freelist(100)
# cdef class SplitResult:

#     cdef Parsed parsed
#     # cdef char * url
#     cdef bytes pyurl

#     def __cinit__(self, char* url):
#         # self.url = url
#         self.pyurl = url
#         if url[0:5] == b"file:":
#             ParseFileURL(url, len(url), &self.parsed)
#         else:
#             ParseStandardURL(url, len(url), &self.parsed)

#     property scheme:
#         def __get__(self):
#             return slice_component(self.pyurl, self.parsed.scheme)

#     property path:
#         def __get__(self):
#             return slice_component(self.pyurl, self.parsed.path)

#     property query:
#         def __get__(self):
#             return slice_component(self.pyurl, self.parsed.query)

#     property fragment:
#         def __get__(self):
#             return slice_component(self.pyurl, self.parsed.ref)

#     property username:
#         def __get__(self):
#             return slice_component(self.pyurl, self.parsed.username)

#     property password:
#         def __get__(self):
#             return slice_component(self.pyurl, self.parsed.password)

#     property port:
#         def __get__(self):
#             return slice_component(self.pyurl, self.parsed.port)

#     # Not in regular urlsplit() !
#     property host:
#         def __get__(self):
#             return slice_component(self.pyurl, self.parsed.host)

#     property netloc:
#         def __get__(self):
#             return build_netloc(self.pyurl, self.parsed)


class SplitResultNamedTuple(tuple):
    """
    There is some repetition in the class,
    we will need to take care of that!
    """

    __slots__ = ()

    def __new__(cls, bytes url, input_scheme, decoded=False):

        cdef Parsed parsed
        cdef Component url_scheme

        if not ExtractScheme(url, len(url), &url_scheme):
            original_url = url.decode('utf-8') if decoded else url
            return stdlib_urlsplit(original_url, input_scheme)

        parse_input_url(url, url_scheme, &parsed)

        def _get_attr(self, prop):
            return extra_attr(self, prop, url, parsed, decoded)

        cls.__getattr__ = _get_attr

        scheme, netloc, path, query, ref = (slice_component(url, parsed.scheme).lower(),
                                            build_netloc(url, parsed),
                                            slice_component(url, parsed.path),
                                            slice_component(url, parsed.query),
                                            slice_component(url, parsed.ref))
        if not scheme and input_scheme:
            scheme = input_scheme.encode('utf-8')

        if decoded:
            return tuple.__new__(cls, (
                <unicode>scheme.decode('utf-8'),
                <unicode>netloc.decode('utf-8'),
                <unicode>path.decode('utf-8'),
                <unicode>query.decode('utf-8'),
                <unicode>ref.decode('utf-8')
            ))

        return tuple.__new__(cls, (scheme, netloc, path, query, ref))

    def geturl(self):
        return stdlib_urlunsplit(self)


class ParsedResultNamedTuple(tuple):
    __slots__ = ()

    def __new__(cls, char * url, input_scheme, decoded=False, canonicalize=False):

        cdef Parsed parsed
        cdef Component url_scheme

        if not ExtractScheme(url, len(url), &url_scheme):
            original_url = url.decode('utf-8') if decoded else url
            return stdlib_urlparse(original_url, input_scheme)

        parse_input_url(url, url_scheme, &parsed)

        def _get_attr(self, prop):
            return extra_attr(self, prop, url, parsed, decoded, True)

        cls.__getattr__ = _get_attr

        scheme, netloc, path, query, ref = (slice_component(url, parsed.scheme).lower(),
                                            build_netloc(url, parsed),
                                            slice_component(url, parsed.path),
                                            slice_component(url, parsed.query),
                                            slice_component(url, parsed.ref))
        if not scheme and input_scheme:
            scheme = input_scheme.encode('utf-8')

        if canonicalize:
            path = canonicalize_path(url, parsed)
            query = canonicalize_query(url, parsed)
            fragment = canonicalize_fragment(url, parsed)

        if scheme in uses_params and b';' in path:
            path, params = _splitparams(path)
        else:
            params = b''

        if decoded:
            return tuple.__new__(cls, (
                <unicode>scheme.decode('utf-8'),
                <unicode>netloc.decode('utf-8'),
                <unicode>path.decode('utf-8'),
                <unicode>params.decode('utf-8'),
                <unicode>query.decode('utf-8'),
                <unicode>ref.decode('utf-8')
            ))

        return tuple.__new__(cls, (scheme, netloc, path, params, query, ref))

    def geturl(self):
        return stdlib_urlunparse(self)


def urlparse(url, scheme='', allow_fragments=True, canonicalize=False):
    """
    This function intends to replace urlparse from urllib
    using urlsplit function from urlparse4 itself.
    Can this function be further enhanced?
    """
    decode = not isinstance(url, bytes)
    url = unicode_handling(url)
    return ParsedResultNamedTuple.__new__(ParsedResultNamedTuple, url,
                                          scheme, decode, canonicalize)

def urlsplit(url, scheme='', allow_fragments=True):
    """
    This function intends to replace urljoin from urllib,
    which uses Urlparse class from GURL Chromium
    """
    decode = not isinstance(url, bytes)
    url = unicode_handling(url)
    return SplitResultNamedTuple.__new__(SplitResultNamedTuple, url, scheme, decode)

def urljoin(base, url, allow_fragments=True):
    """
    This function intends to replace urljoin from urllib,
    which uses Resolve function from class GURL of GURL chromium
    """
    str_input = isinstance(base, str)
    if isinstance(url, str) != str_input:
        raise TypeError("Cannot mix str and non-str arguments")

    decode = not (isinstance(base, bytes) and isinstance(url, bytes))
    if allow_fragments and base:
        base, url = unicode_handling(base), unicode_handling(url)
        """
        this part needs to be profiled to see if creating another GURL instance
        here takes more time than expected?
        """
        if not GURL(base).is_valid():
            fallback = stdlib_urljoin(base, url, allow_fragments=allow_fragments)
            if decode:
                return fallback.decode('utf-8')
            return fallback
        joined_url = GURL(base).Resolve(url).spec()

        if decode:
            return joined_url.decode('utf-8')
        return joined_url

    return stdlib_urljoin(base, url, allow_fragments=allow_fragments)
