unit module HTTP1::StreamParser;

=NAME HTTP1::StreamParser - A modern HTTP/1.x request parser

=begin SYNOPSIS

my $listener = IO::Socket::INET.new(..., :listen);
while my $conn = $listener.accept {
    my $envs = parse-http1-request($conn);
    whenever $envs -> %env {
        my $p = app(%env);
        ...;

        QUIT {
            when X::HTTP::StreamParser::UnsupportedProtocol && .looks-httpish {
                $conn.print("505 HTTP Version Not Supported HTTP/1.1\r\n");
                $conn.print("Content-Length: 26\r\n");
                $conn.print("Content-Type: text/plain\r\n\r\n");
                $conn.print("HTTP Version Not Supported\r\n");
            }

            when X::HTTP1::StreamParser::BadRequest {
                $conn.print("400 Bad Request HTTP/1.1\r\n");
                $conn.print("Content-Length: " ~ .message.encode.bytes ~ \r\n");
                $conn.print("Content-Type: text/plain\r\n\r\n");
                $conn.print(.message);
                $conn.print("\r\n");
            }

            # N.B. This exception should be rarely emitted and indicates that a
            # feature is known to exist in HTTP, but this module does not yet
            # support it.
            when X::HTTP1::StreamParser::ServerError {
                $conn.print("500 Internal Server Error HTTP/1.1\r\n");
                $conn.print("Content-Length: " ~ .message.encode.bytes ~ \r\n");
                $conn.print("Content-Type: text/plain\r\n\r\n");
                $conn.print(.message);
                $conn.print("\r\n");
            }

            warn .message;
            $conn.close;
        }
    };
}

=end SYNOPSIS

=begin DESCRIPTION

B<EXPERIMENTAL:> The API for this module is experimental and may change.

The L<HTTP::Parser> ported from Perl 5 (and the implementation in Perl 5) is
naïve and really only parses a single HTTP frame. That's not how the HTTP/1.1
protocol works by default unless the C<Connection: close> header is present.

This module provides the L</parse-http1-request> routine. Given a L<Supply> or
some other object that coerces to a Supply (such as a file handle or INET
socket), it consumes input from it. It detects the request or requests within
the stream and passes them to the caller.

This is performed with a reactive interface. The routine returns a Supply that
emits L<P6SGI> compatible environments for use by the caller. Any problem with
the stream or if the stream is not being sent as legal HTTP/1.0 or HTTP/1.1,
the stream will quit with an exception.

=end DESCRIPTION

=begin pod

=head1 EXPORTED ROUTINES

=head2 sub parse-http1-request

    sub parse-http1-request(Supply:D() $conn) returns Supply:D

Given a L<Supply> or object that coerces to one, this will react to it whenever
binary data is emitted. It is assumed that each chunk arriving is emitted as a
L<Blob>. This collates the incoming chunks into HTTP frames, which are parsed
to determine the contents of the headers.

Once the headers for a given frame have been read, a partial L<P6SGI> compatible
environment is generated from the headers and emitted to the returned Supply.
The environment will have any header given set, will set the C<REQUEST_METHOD>,
the C<SERVER_PROTOCOL> (to either HTTP/1.1 or HTTP/1.0 as requested), and the
C<REQUEST_URI>. It will also have the C<p6w.input> variable set to a Supply
object that will emit the body as it arrives.

=head1 DIAGNOSTICS

=head2 X::HTTP1::StreamParser::UnsupportedProtocol

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

=head2 X::HTTP1::StreamParser::BadRequest

This exception will be thrown if the HTTP request is incorrectly framed. This
may happen when the request does not specify its content length using a
C<Content-Length> header, chunked C<Transfer-Encoding>, or a
C<multipart/byteranges> content type.

It may also happen on a subsequent frame if an earlier frame does is larger or
smaller than the content length indicated. This is detected when a frame fails
to end with a "\r\n" or when the status line is not found at the start of the
subsequent frame.

=head2 X::HTTP1::StreamParser::ServerError

This exception is thrown when a feature of HTTP/1.0 or HTTP/1.1 is not
implemented. Currently, this includes:

=item C<Transfer-Encoding> on the request is not implemented.

=item C<Content-Type: multipart/byteranges> is not implemented.

=head1 CAVEATS

This interface is built with the intention of making it easier to build HTTP/1.0
and HTTP/1.1 parsers for use with L<P6SGI>. As of this writing, that
specification is unfinished, so the output of this module is experiemental and
will change as that specification changes.

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

Copyright 2015 Sterling Hanenkamp.

This software is licensed under the same terms as Perl 6.

=end pod

my class X::HTTP1::StreamParser::UnsupportedProtocol is Exception {
    has Bool:D $.looks-httpish is required;
    has Supply:D $.input is required;
    method message() {
        $.looks-httpish ?? "HTTP version is not supported."
                        !! "Unknown protocol."
    }
}

my class X::HTTP1::StreamParser::BadRequest is Exception {
    has $.reason is required;
    method message() { $!reason }
}

my class X::HTTP1::StreamParser::ServerError is Exception {
    has $.reason is required;
    method message() { $!reason }
}

# NewConn - starting up
# Head - reading a message header, looking for body start
# Body - reading the message body until end
# Other - no more frames in this connection, read and throw away bytes
my enum StreamState < NewConn Head Body Other >;

my constant CR = 0x0d;
my constant LF = 0x0a;

sub parse-http1-request(Supply:D() $conn) returns Supply:D is export {
    supply {
        my buf8 $buf .= new;
        my $this-length = 0;
        my Bool $close = False;
        my Bool $closed = False;

        my $tick = Supply.interval(0.1);

        whenever $conn -> $chunk {
            unless $closed {
                LAST { done }
                QUIT { .rethrow }

                my $scan-start = $buf.bytes - 3 max 0;
                $buf ~= $chunk;

                my $header-end;
                for $scan-start .. $buf.bytes - 4 -> $i {
                    next unless $buf[$i]   == CR;
                    next unless $buf[$i+1] == LF;
                    next unless $buf[$i+2] == CR;
                    next unless $buf[$i+3] == LF;

                    my $header-buf = $buf.subbuf(0, $i + 4);
                    $buf          .= subbuf($i + 4);

                    my @headers = $header-buf.decode('iso-8859-1').split("\r\n");
                    @headers.pop; @headers.pop;
                    my $request-line = @headers.shift;

                    my ($method, $uri, $http-version) = $request-line.split(' ');

                    # Looks HTTP-ish, but not our thing... quit now!
                    if $http-version !~~ any('HTTP/1.0', 'HTTP/1.1') {
                        X::HTTP1::StreamParser::UnsupportedProtocol.new(
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
                        sub emit-with-xfer-encoding($buf) {
                            if my $cl = %env<CONTENT_LENGTH> {
                                my $need-bytes = $cl - $this-length;

                                if $need-bytes > 0 && $buf.bytes > 0 {
                                    my $output-bytes = $buf.bytes min $need-bytes;
                                    emit $buf.subbuf(0, $output-bytes);
                                    $this-length += $output-bytes;
                                    $buf .= subbuf($output-bytes);
                                    $need-bytes -= $output-bytes;
                                }

                                if $need-bytes == 0 {
                                    done;
                                }
                            }

                            elsif %env<HTTP_TRANSFER_ENCODING> eq 'chunked' {
                                X::HTTP1::StreamParser::ServerError.new(
                                    reason => 'Transfer-Encoding is not supported by this implementation yet',
                                ).throw;
                            }

                            elsif %env<CONTENT_TYPE> ~~ /^ "multipart/byteranges" \>/ {
                                X::HTTP1::StreamParser::ServerError.new(
                                    reason => 'multipart/byteranges is not supported by this implementation yet',
                                ).throw;
                            }

                            else {
                                X::HTTP1::StreamParser::BadRequest.new(
                                    reason => 'client did not specify entity length',
                                ).throw;
                            }
                        }

                        emit-with-xfer-encoding $buf;
                        $buf = buf8.new;

                        whenever $conn -> $chunk {
                            $buf ~= $chunk;
                            emit-with-xfer-encoding $buf;
                        };
                    };

                    emit %env;

                    if $close { done }
                }
            }
        }
    }
}
