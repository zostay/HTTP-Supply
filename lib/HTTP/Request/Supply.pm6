unit class HTTP::Request::Supply;

=NAME HTTP::Request::Supply - A modern HTTP/1.x request parser

=begin SYNOPSIS

    use HTTP::Request::Supply;

    react {
        whenever IO::Socket::Async.listen('localhost', 8080) -> $conn {
            my $envs = HTTP::Request::Supply.parse-http($conn);
            whenever $envs -> %env {
                my $res = await app(%env);
                handle-response($conn, $res);

                QUIT {
                    when X::HTTP::Request::Supply::UnsupportedProtocol && .looks-httpish {
                        $conn.print("505 HTTP Version Not Supported HTTP/1.1\r\n");
                        $conn.print("Content-Length: 26\r\n");
                        $conn.print("Content-Type: text/plain\r\n\r\n");
                        $conn.print("HTTP Version Not Supported\r\n");
                    }

                    when X::HTTP::Request::Supply::BadRequest {
                        $conn.print("400 Bad Request HTTP/1.1\r\n");
                        $conn.print("Content-Length: " ~ .message.encode.bytes ~ \r\n");
                        $conn.print("Content-Type: text/plain\r\n\r\n");
                        $conn.print(.message);
                        $conn.print("\r\n");
                    }

                    # N.B. This exception should be rarely emitted and indicates that a
                    # feature is known to exist in HTTP, but this module does not yet
                    # support it.
                    when X::HTTP::Request::Supply::ServerError {
                        $conn.print("500 Internal Server Error HTTP/1.1\r\n");
                        $conn.print("Content-Length: " ~ .message.encode.bytes ~ \r\n");
                        $conn.print("Content-Type: text/plain\r\n\r\n");
                        $conn.print(.message);
                        $conn.print("\r\n");
                    }

                    warn .message;
                    $conn.close;
                }
            }
        }
    }

=end SYNOPSIS

=begin DESCRIPTION

B<EXPERIMENTAL:> The API for this module is experimental and may change.

The L<HTTP::Parser> ported from Perl 5 (and the implementation in Perl 5) is
naïve and really only parses a single HTTP frame. However, that's not how the
HTTP/1.1 protocol typically works.

This class provides a L<Supply> that can parses a series of requests from an
HTTP/1.x connection. Given a L<Supply> or some other object that coerces to a
Supply (such as a file handle or INET conn), it consumes input from it. It
detects the request or requests within the stream and passes them to the caller.

This Supply emits L<P6SGI> compatible environments for use by the caller. Any
problem with the stream or if the stream is not being sent as legal HTTP/1.0 or
HTTP/1.1, the stream will quit with an exception.

=end DESCRIPTION

=begin pod

=head1 METHODS

=head2 sub parse-http

    sub parse-http(Supply:D() :$conn, :&promise-maker) returns Supply:D

Given a L<Supply> or object that coerces to one, this will react to it whenever
binary data is emitted. It is assumed that each chunk arriving is emitted as a
L<Blob>. This collates the incoming chunks into HTTP frames, which are parsed
to determine the contents of the headers.

Once the headers for a given frame have been read, a partial L<P6SGI> compatible
environment is generated from the headers and emitted to the returned Supply.
The environment will be filled as follows:

=item The C<Content-Length> will be set in C<CONTENT_LENGTH>.

=item The C<Content-Type> will be set in C<CONTENT_TYPE>.

=item Other headers will be set in C<HTTP_*> where the header name is converted to uppercase and dashes are replaced with underscores.

=item The C<REQUEST_METHOD> will be set to the method set in the request line.

=item The C<SERVER_PROTOCOL> will be set to the protocol set in the request line.

=item The C<REQUEST_URI> will be set to the URI set in the request line.

=item The C<p6w.input> variable will be set to a sane, on-demand L<Supply> that emits chunks of the body as C<Blob>s as they arrive.

All other keys are left empty.

=head1 DIAGNOSTICS

The following exceptions are thrown by this class while processing input, which
will trigger the quit handlers on the Supply.

=head2 X::HTTP::Request::Supply::UnsupportedProtocol

This exception will be thrown if the stream does not seem to be HTTP or if the
requested HTTP version is not 1.0 or 1.1.

This exception includes two attributes:

=item C<looks-httpish> is a boolean value that is set to True if the data sent
resembles HTTP, but the server protocol string does not match either "HTTP/1.0"
or "HTTP/1.1", e.g., an HTTP/2 connection preface.

=item C<input> is a L<Supply> that may be tapped to consume the complete stream
including the bytes already read. This allows chaining of modules similar to
this one to handle other protocols that might happen over the web server's
port.

=head2 X::HTTP::Request::Supply::BadRequest

This exception will be thrown if the HTTP request is incorrectly framed. This
may happen when the request does not specify its content length using a
C<Content-Length> header, chunked C<Transfer-Encoding>, or a
C<multipart/byteranges> content type.

It may also happen on a subsequent frame if an earlier frame does is larger or
smaller than the content length indicated. This is detected when a frame fails
to end with a "\r\n" or when the status line is not found at the start of the
subsequent frame.

=head2 X::HTTP::Request::Supply::ServerError

This exception is thrown when a feature of HTTP/1.0 or HTTP/1.1 is not
implemented. Currently, this includes:

=item C<Transfer-Encoding> on the request is not implemented.

=item C<Content-Type: multipart/byteranges> is not implemented.

=head1 CAVEATS

This interface is built with the intention of making it easier to build HTTP/1.0
and HTTP/1.1 parsers for use with L<P6SGI>. As of this writing, that
specification is only a proposed draft, so the output of this module is
experiemental and will change as that specification changes.

This implementation is not complete as fo this writing. Features like
C<Transfer-Encoding>, C<multipart/byteranges>, and C<Connection: Keep-Alive>
are not implemented. (It is possible that the last will never be implemented
unless there is a specific request or patch given to me to add it.)

Finally, the limitation of this module is that it is only responsible for
parsing the incoming HTTP frames. A complete server implementation must make
sure to handle the response frames correctly for HTTP/1.0 or HTTP/1.1 as
appropriate.

=head1 AUTHOR

Sterling Hanenkamp C<< <hanenkamp@cpan.org> >>

=head1 COPYRIGHT & LICENSE

Copyright 2016 Sterling Hanenkamp.

This software is licensed under the same terms as Perl 6.

=end pod

my class X::HTTP::Request::Supply::UnsupportedProtocol is Exception {
    has Bool:D $.looks-httpish is required;
    has Supply:D $.input is required;
    method message() {
        $.looks-httpish ?? "HTTP version is not supported."
                        !! "Unknown protocol."
    }
}

my class X::HTTP::Request::Supply::BadRequest is Exception {
    has $.reason is required;
    method message() { $!reason }
}

my class X::HTTP::Request::Supply::ServerError is Exception {
    has $.reason is required;
    method message() { $!reason }
}

my constant CR = 0x0d;
my constant LF = 0x0a;

multi method parse-http(Supply:D() $conn) returns Supply:D {
    supply {
        my buf8 $buf .= new;
        my $emitted-bytes = 0;
        my Bool $close = False;
        my Bool $closed = False;

        whenever $conn -> $chunk {
            unless $closed {
                LAST { done }
                QUIT { .rethrow }

                my $scan-start = $buf.bytes - 3 max 0;
                $buf ~= $chunk;

                my $header-end;
                for $scan-start .. $buf.bytes - 4 -> $i {
                    next unless $buf[$i..$i+3] eqv (CR,LF,CR,LF);

                    my $header-buf = $buf.subbuf(0, $i + 4);
                    $buf          .= subbuf($i + 4);

                    my @headers = $header-buf.decode('iso-8859-1').split("\r\n");
                    @headers.pop; @headers.pop;
                    my $request-line = @headers.shift;

                    my ($method, $uri, $http-version) = $request-line.split(' ');

                    # Looks HTTP-ish, but not our thing... quit now!
                    if $http-version !~~ any('HTTP/1.0', 'HTTP/1.1') {
                        X::HTTP::Request::Supply::UnsupportedProtocol.new(
                            looks-httpish => True,
                            input         => supply {
                                emit $header-buf;
                                emit $buf if $buf.bytes > 0;

                                $conn => -> $v {
                                    emit $v;
                                    LAST { done }
                                    QUIT { .rethrow }
                                }
                            },
                        ).throw;
                    }

                    my %env =
                        REQUEST_METHOD  => $method,
                        REQUEST_URI     => $uri,
                        SERVER_PROTOCOL => $http-version,
                        ;

                    my $last-header;
                    for @headers -> $header {
                        if $last-header && $header ~~ /^\s+/ {
                            $last-header.value ~= $header.trim-leading;
                        }
                        else {
                            my ($name, $value) = $header.split(": ");
                            $name.=lc.=subst('-', '_');
                            $name = "HTTP_" ~ $name.uc;

                            if %env{ $name } :exists {
                                %env{ $name } ~= ',', $value;
                            }
                            else {
                                %env{ $name } = $value;
                            }

                            $last-header := %env{ $name } :p;
                        }
                    }

                    if my $ct = %env<HTTP_CONTENT_TYPE> :delete :v {
                        %env<CONTENT_TYPE> = $ct;
                    }

                    if my $cl = %env<HTTP_CONTENT_LENGTH> :delete :v {
                        %env<CONTENT_LENGTH> = $cl;
                    }

                    %env<p6w.input> = supply {
                        sub emit-with-xfer-encoding($buf is rw, Bool :$inner = False) {
                            if my $cl = %env<CONTENT_LENGTH> {
                                my $need-bytes = $cl - $emitted-bytes;
                                if $need-bytes > 0 && $buf.bytes > 0 {
                                    my $output-bytes = $buf.bytes min $need-bytes;
                                    emit $buf.subbuf(0, $output-bytes);
                                    $emitted-bytes += $output-bytes;
                                    $buf .= subbuf($output-bytes);
                                    $need-bytes -= $output-bytes;
                                }

                                if $inner and $need-bytes == 0 {
                                    done;
                                }
                            }

                            elsif %env<HTTP_TRANSFER_ENCODING> eq 'chunked' {
                                X::HTTP::Request::Supply::ServerError.new(
                                    reason => 'Transfer-Encoding is not supported by this implementation yet',
                                ).throw;
                            }

                            elsif %env<CONTENT_TYPE> ~~ /^ "multipart/byteranges" \>/ {
                                X::HTTP::Request::Supply::ServerError.new(
                                    reason => 'multipart/byteranges is not supported by this implementation yet',
                                ).throw;
                            }

                            else {
                                X::HTTP::Request::Supply::BadRequest.new(
                                    reason => 'client did not specify entity length',
                                ).throw;
                            }
                        }

                        emit-with-xfer-encoding $buf;

                        whenever $conn -> $chunk {
                            $buf ~= $chunk;
                            emit-with-xfer-encoding $buf, :inner;
                        };
                    };

                    emit %env;

                    if $close { done }
                }
            }
        }
    }
}
