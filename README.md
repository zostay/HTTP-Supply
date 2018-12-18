NAME
====

HTTP::Request::Supply - A modern HTTP/1.x request parser

SYNOPSIS
========

    use HTTP::Request::Supply;

    react {
        whenever IO::Socket::Async.listen('localhost', 8080) -> $conn {
            my $envs = HTTP::Request::Supply.parse-http($conn);
            whenever $envs -> %env {
                my $res = await app(%env);
                handle-response($conn, $res);

                QUIT {
                    when X::HTTP::Request::Supply::UnsupportedProtocol {
                        $conn.print("505 HTTP Version Not Supported HTTP/1.1\r\n");
                        $conn.print("Content-Length: 26\r\n");
                        $conn.print("Content-Type: text/plain\r\n\r\n");
                        $conn.print("HTTP Version Not Supported\r\n");

                        .note;
                        $conn.close;
                    }

                    when X::HTTP::Request::Supply::BadRequest {
                        $conn.print("400 Bad Request HTTP/1.1\r\n");
                        $conn.print("Content-Length: " ~ .message.encode.bytes ~ \r\n");
                        $conn.print("Content-Type: text/plain\r\n\r\n");
                        $conn.print(.message);
                        $conn.print("\r\n");

                        .note;
                        $conn.close;
                    }

                    default {
                        $conn.print("500 Internal Server Error HTTP/1.1\r\n");
                        $conn.print("Content-Length: 22\r\n");
                        $conn.print("Content-Type: text/plain\r\n\r\n");
                        $conn.print("Internal Server Error\r\n");

                        .note;
                        $conn.close;
                    }
                }
            }
        }
    }

DESCRIPTION
===========

**EXPERIMENTAL:** The API for this module is experimental and may change.

This class provides a [Supply](Supply) that is able to parse a series of request frames from an HTTP/1.x connection. Given a [Supply](Supply), it consumes binary input from it. It detects the request frame or frames within the stream and passes them back to any taps on the supply asynchronously as they arrive.

This Supply emits partial [P6WAPI](P6WAPI) compatible environments for use by the caller. If a problem is detected in the stream, it will quit with an exception.

METHODS
=======

sub parse-http
--------------

    sub parse-http(Supply:D() :$conn, :&promise-maker) returns Supply:D

The given [Supply](Supply), `$conn` must emit a stream of bytes. Any other data will result in undefined behavior. The parser assumes that only binary bytes will be sent and makes no particular effort to verify that assumption.

The returned supply will react whenever data is emitted on the input supply. The incoming bytes are collated into HTTP frames, which are parsed to determine the contents of the headers. Headers are encoded into strings via ISO-8859-1 (as per [RFC7230 §3.2.4](https://tools.ietf.org/html/rfc7230#section-3.2.4)).

Once the headers for a given frame have been read, a partial [P6WAPI](P6WAPI) compatible environment is generated from the headers and emitted to the returned Supply. The environment will be filled as follows:

over
====



  * If a `Content-Length` header is present, it will be set in `CONTENT_LENGTH`.

  * If a `Content-Type` header is present, it will be set in `CONTENT_TYPE`.

  * Other headers will be set in `HTTP_*` where the header name is converted to uppercase and dashes are replaced with underscores.

  * The `REQUEST_METHOD` will be set to the method given in the request line.

  * The `SERVER_PROTOCOL` will be set to the protocol given in the request line. (As of this writing, this will always be either HTTP/1.0 or HTTP/1.1 as these are the only protocol versions this module currently supports.)

  * The `REQUEST_URI` will be set to the URI given in the request line.

  * The `p6w.input` variable will be set to a sane [Supply](Supply) that emits chunks of the body as bytes as they arrive. No attempt is made to decode these bytes.

back
====



No other keys will be set. A complete P6WAPI environment must contain many other keys.

DIAGNOSTICS
===========

The following exceptions are thrown by this class while processing input, which will trigger the quit handlers on the Supply.

X::HTTP::Request::Supply::UnsupportedProtocol
---------------------------------------------

This exception will be thrown if the stream does not seem to be HTTP or if the requested HTTP version is not 1.0 or 1.1.

X::HTTP::Request::Supply::BadRequest
------------------------------------

This exception will be thrown if the HTTP request is incorrectly framed. This may happen when the request does not specify its content length using a `Content-Length` header or chunked `Transfer-Encoding`.

CAVEATS
=======

This code aims at providing a minimal implementation that is just enough to decode the HTTP frames and provide the information about the raw requests to the tapping code. It is not safe to assume that anything provided has been validated or processed.

HTTP is complicated and hard. This implementation is not yet complete and not battle tested yet. Please report bugs to github and patches are welcome. Even once this code matures, it will never receive the TLC that a full-blown general web server is going to get as regards hardening and maturity on the Internet. As such, the author always recommends using this code behind an existing, well-known, and well-maintained web server in production. This is only ever intended as a "bare metal" application server interface.

This interface is built with the intention of making it easier to build HTTP/1.0 and HTTP/1.1 parsers for use with [P6WAPI](P6WAPI). As of this writing, that specification is only a proposed draft, so the output of this module is experimental and will change as that specification changes.

Finally, this module only takes responsibility for parsing the incoming HTTP frames. It does not manage the connection and it provides no tools for sending responses back to the user agent.

AUTHOR
======

Sterling Hanenkamp `<hanenkamp@cpan.org> `

COPYRIGHT & LICENSE
===================

Copyright 2016 Sterling Hanenkamp.

This software is licensed under the same terms as Perl 6.

