use v6;
unit class HTTP::Request::Supply:ver<0.1.2>:auth<github:zostay>;

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
naïve and really only parses a single HTTP frame (i.e., it provides no
keep-alive support). However, that is not how the HTTP protocol typically works
on the modern web.

This class provides a L<Supply> that is able to parse a series of request frames
from an HTTP/1.x connection. Given a L<Supply>, it consumes binary input from
it. It detects the request frame or frames within the stream and passes them
back to the tapper asynchronously as they arrive.

This Supply emits partial L<P6WAPI> compatible environments for use by the
caller. If a problem is detected in the stream, it will quit with an exception.

=end DESCRIPTION

=begin pod

=head1 METHODS

=head2 sub parse-http

    sub parse-http(Supply:D() :$conn, :&promise-maker) returns Supply:D

The given L<Supply>, C<$conn> must emit a stream of bytes. Any other data will
result in undefined behavior. This parser assumes binary data will be sent.

The returned supply will react whenever data is emitted on the input supply. The
incoming bytes are collated into HTTP frames, which are parsed to determine the
contents of the headers. Headers are encoded into strings via ISO-8859-1 (as per
L<RFC7230 §3.2.4|https://tools.ietf.org/html/rfc7230#section-3.2.4>).

Once the headers for a given frame have been read, a partial L<P6WAPI> compatible
environment is generated from the headers and emitted to the returned Supply.
The environment will be filled as follows:

=item If a C<Content-Length> header is present, it will be set in
C<CONTENT_LENGTH>.

=item If a C<Content-Type> header is present, it will be set in C<CONTENT_TYPE>.

=item Other headers will be set in C<HTTP_*> where the header name is converted
to uppercase and dashes are replaced with underscores.

=item The C<REQUEST_METHOD> will be set to the method set in the request line.

=item The C<SERVER_PROTOCOL> will be set to the protocol set in the request
line.

=item The C<REQUEST_URI> will be set to the URI set in the request line.

=item The C<p6w.input> variable will be set to a sane L<Supply> that emits
chunks of the body as bytes as they arrive. No attempt is made to decode these
bytes.

No other keys will be set. Thus, to create a complete P6WAPI environment, the
caller will need to do some additional work, such as parsing out the components
of the C<REQUEST_URI>.

=head1 DIAGNOSTICS

The following exceptions are thrown by this class while processing input, which
will trigger the quit handlers on the Supply.

=head2 X::HTTP::Request::Supply::UnsupportedProtocol

This exception will be thrown if the stream does not seem to be HTTP or if the
requested HTTP version is not 1.0 or 1.1.

This exception includes two attributes:

=item C<looks-httpish> is a boolean value that is set to True if the data sent
resembles HTTP, but the server protocol string does not match either "HTTP/1.0"
or "HTTP/1.1".

=item C<input> is a L<Supply> that may be tapped to consume the complete stream
including the bytes already read. This allows chaining of modules similar to
this one to handle other protocols that might happen over the web server's
port.

=head2 X::HTTP::Request::Supply::BadRequest

This exception will be thrown if the HTTP request is incorrectly framed. This
may happen when the request does not specify its content length using a
C<Content-Length> header or chunked C<Transfer-Encoding>.

=head2 X::HTTP::Request::Supply::ServerError

This exception may be thrown when a feature of HTTP/1.0 or HTTP/1.1 is not
implemented.

=head1 CAVEATS

HTTP is complicated and hard. This implementation is not yet complete and not
battle tested yet. Please report bugs to github and patches are welcome.

This interface is built with the intention of making it easier to build HTTP/1.0
and HTTP/1.1 parsers for use with L<P6WAPI>. As of this writing, that
specification is only a proposed draft, so the output of this module is
experiemental and will change as that specification changes.

Finally, one limitation of this module is that it is only responsible for
parsing the incoming HTTP frames. It will not manage the connection and it
provides no tools for sending responses back to the user agent.

=head1 AUTHOR

Sterling Hanenkamp C<< <hanenkamp@cpan.org> >>

=head1 COPYRIGHT & LICENSE

Copyright 2016 Sterling Hanenkamp.

This software is licensed under the same terms as Perl 6.

=end pod

package GLOBAL::X::HTTP::Request::Supply {
    class UnsupportedProtocol is Exception {
        has Bool:D $.looks-httpish is required;
        #has Supply:D $.input is required;
        method message() {
            $.looks-httpish ?? "HTTP version is not supported."
                            !! "Unknown protocol."
        }
    }

    class BadRequest is Exception {
        has $.reason is required;
        method message() { $!reason }
    }

    class ServerError is Exception {
        has $.reason is required;
        method message() { $!reason }
    }
}

my constant CR = 0x0d;
my constant LF = 0x0a;

my sub crlf-line(Buf $buf is rw, :$encoding = 'iso-8859-1' --> Str) {
    my $line-end;
    BYTE: for 0..$buf.bytes - 2 -> $i {
        # We haven't found the CRLF yet. Keep going.
        next BYTE unless $buf[$i..$i+1] eqv (CR,LF);

        # Found it. Remember the end index.
        $line-end = $i;
        last BYTE;
    }

    # If we never found the end, we don't have a size yet. Drop out.
    return Nil without $line-end;

    # Consume the size string from buf.
    my $line = $buf.subbuf(0, $line-end);
    $buf .= subbuf($line-end + 2);

    $line.decode($encoding);
}

my sub make-p6wapi-name($name is copy) {
    $name .= trans('-' => '_');
    $name = "HTTP_" ~ $name.uc;
    $name = 'CONTENT_TYPE'   if $name eq 'HTTP_CONTENT_TYPE';
    $name = 'CONTENT_LENGTH' if $name eq 'HTTP_CONTENT_LENGTH';
    return $name;
}

class Body {
    has Supplier $.body-stream;
    has Promise $.left-over;
    has %.env;

    method decode(Supply $body-sink) {
        $body-sink.tap:
            { self.process-bytes($_) },
            done => { self.handle-done },
            quit => { self.handle-quit($_) },
            ;
    }

    method process-bytes(Blob $buf) { ... }
    method handle-done() { }
    method handle-quit($error) { }
}

class Body::ChunkedEncoding is Body {
    my enum <Size Chunk Trailers>;
    has $.expect = Size;
    has buf8 $.acc .= new;
    has UInt $.expected-size where * > 0;
    has Pair $!previous-header;
    has %!trailer;

    enum LoopAction <NeedMoreData TryThisData QuitDecoding>;

    method process-bytes(Blob $buf) {
        # Accumulate the buf.
        $!acc ~= $buf;

        # Process the accumulator until we can't.
        loop {
            my $action = self.process-acc();

            # NeedMoreData
            last unless $action;

            # Let the taps know we got it all
            if $action == QuitDecoding {
                # Emit trailer if present
                $.body-stream.emit: %!trailer if %!trailer;

                # Close the body stream
                $.body-stream.done;

                # Return the rest of the data the HTTP parser
                $.left-over.keep($.acc);

                last;
            }
        }
    }

    method process-acc(--> LoopAction) {
        given $!expect {
            when Size {
                # Not long enough to be a size yet, so drop out.
                return NeedMoreData unless $!acc.bytes > 2;

                # Grab the next line
                my $str-size = crlf-line($!acc);

                # If we did not finda line, we don't have a size yet. Drop out.
                return NeedMoreData without $str-size;

                # throw away extension details, if any
                $str-size .= subst(/';' .*/, '');
                my $parsed-size = try {
                    CATCH {
                        when X::Str::Numeric {
                            die X::HTTP::Request::Supply::BadRequest.new(
                                reason => "encountered non-hexadecimal value when processing chunked encoding",
                            );
                        }
                    }

                    :16($str-size);
                }

                # Zero size means end of chunking
                if $parsed-size == 0 {
                    if %.env<HTTP_TRAILER> {
                        $!expect = Trailers;
                        return TryThisData;
                    }
                    else {
                        return QuitDecoding;
                    }
                }

                # Non-zero size means we need to consume another chunk.
                else {
                    $!expected-size = $parsed-size;
                    $!expect = Chunk;
                    return TryThisData;
                }
            }

            when Chunk {
                # Wait until we get the rest of the chunk
                return NeedMoreData unless $!acc.bytes >= $!expected-size + 2;

                # Collect the chunk
                my $chunk = $!acc.subbuf(0, $!expected-size);

                # Clear the chunk from the input buffer
                $!acc .= subbuf($!expected-size + 2);

                # Ship all the chunk we have.
                $.body-stream.emit: $chunk;

                # Chunk is complete, so look for another size line.
                $!expect = Size;
                return TryThisData;
            }

            # This will probably be never used, but what the heck?
            when Trailers {
                # Grab the next line
                my $line = crlf-line($!acc);

                # We don't have a complete line yet
                return NeedMoreData without $line;

                # Empty line signals end of trailer
                if $line eq '' {
                    return QuitDecoding;
                }

                # Handle trailer folder
                elsif $line.starts-with(' ') {
                    die X::HTTP::Request::Supply::BadRequest.new(
                        reason => 'trailer folding encountered before any trailer was sent',
                    ) without $!previous-header;

                    $!previous-header.value ~= $line.trim-leading;

                    return TryThisData;
                }

                # Handle new trailer
                else {
                    my ($name, $value) = $line.split(": ");

                    # Setup the name for the P6WAPI environment
                    $name = make-p6wapi-name($name);

                    # Save the trailer for emitting
                    if %!trailer{ $name } :exists {
                        # Some trailers could be provided more than once.
                        %!trailer{ $name } ~= ',' ~ $value;
                    }
                    else {
                        # First occurrence of a trailer.
                        %!trailer{ $name } = $value;
                    }

                    # Remember the trailer line for folded lines.
                    $!previous-header = %!trailer{ $name } :p;

                    return TryThisData;
                }
            }
        }
    }
}

class Body::ContentLength is Body {
    has Int $.bytes-read = 0;

    method process-bytes(Blob $buf) {
        # All data received. Anything left-over should be kept.
        if $buf.bytes + $.bytes-read >= %.env<CONTENT_LENGTH> {
            my $bytes-remaining = $.env<CONTENT_LENGTH> - $.bytes-read;

            $.body-stream.emit: $buf.subbuf(0, $bytes-remaining)
                if $bytes-remaining > 0;
            $.body-stream.done;

            $.left-over.keep: $buf.subbuf($bytes-remaining);
        }

        # More data received.
        else {
            $!bytes-read += $buf.bytes;
            $.body-stream.emit: $buf;
        }
    }
}

# I rewrote parse-http and heavily modeled after Cro::HTTP::RequestParser which
# does this exact thing very nicely.

multi method parse-http(Supply:D() $conn, Bool :$debug = False --> Supply:D) {
    sub debug(*@msg) {
        note "# [{now.Rat.fmt("%.5f")}] (#$*THREAD.id()) ", |@msg if $debug
    }

    supply {
        my enum <RequestLine Header Body Close>;
        my $expect;
        my %env;
        my buf8 $acc;
        my Supplier $body-sink;
        my $previous-header;
        my Promise $left-over;

        my sub new-request() {
            $expect = RequestLine;
            $acc = buf8.new;
            $acc ~= .result with $left-over;
            $left-over = Nil;
            $body-sink = Nil;
            %env := %();
            $previous-header = Pair;
        }

        new-request();

        whenever $conn -> $chunk {
            # When expecting a header, add the chunk to the accumulation buffer.
            debug("RECV ", $chunk.perl);
            $acc ~= $chunk if $expect != Body;

            # Otherwise, the chunk will be handled directly below.

            CHUNK_PROCESS: loop {
                given $expect {

                    # Ready to receive a request line
                    when RequestLine {
                        # Decode the request line
                        my $line = crlf-line($acc);

                        # We don't have a complete line yet
                        last CHUNK_PROCESS without $line;
                        debug("REQLINE [$line]");

                        # Break the line up into parts
                        my ($method, $uri, $http-version) = $line.split(' ', 3);

                        # Looks HTTP-ish, but not our thing... quit now!
                        if $http-version ~~ none('HTTP/1.0', 'HTTP/1.1') {
                            if $http-version.defined && $http-version ~~ /^ 'HTTP/' <[0..9]>+ '.' <[0..9]>+ $/ {
                                X::HTTP::Request::Supply::UnsupportedProtocol.new(:looks-httpish).throw;
                            }
                            else {
                                X::HTTP::Request::Supply::BadRequest.new(
                                    reason => 'trailing garbage found after request',
                                ).throw;
                            }
                        }

                        # Save the request line
                        %env<REQUEST_METHOD>  = $method;
                        %env<REQUEST_URI>     = $uri;
                        %env<SERVER_PROTOCOL> = $http-version;

                        # We have the request line, move on to headers
                        $expect = Header;
                    }

                    # Ready to receive a header line
                    when Header {
                        # Decode the next line from the header
                        my $line = crlf-line($acc);

                        # We don't have a complete line yet
                        last CHUNK_PROCESS without $line;

                        # Empty line signals the end of the header
                        if $line eq '' {
                            debug("HEADER END");

                            # Setup the body decoder itself
                            # TODO Someday this could be pluggable.
                            debug("ENV ", %env.perl);
                            my $body-decoder-class = do
                                if %env<HTTP_TRANSFER_ENCODING>.defined
                                && %env<HTTP_TRANSFER_ENCODING> eq 'chunked' {
                                    HTTP::Request::Supply::Body::ChunkedEncoding
                                }
                                elsif %env<CONTENT_LENGTH>.defined {
                                    HTTP::Request::Supply::Body::ContentLength
                                }
                                else {
                                    Nil
                                }

                            debug("DECODER CLASS ", $body-decoder-class.WHAT.^name);

                            # Setup the stream we will send to the P6WAPI env
                            my $body-stream = Supplier::Preserving.new;
                            %env<p6w.input> = $body-stream.Supply;

                            # If we expect a body to decode, setup the decoder
                            if $body-decoder-class ~~ HTTP::Request::Supply::Body {
                                debug("DECODE BODY");

                                # Setup the stream we will send to the body decoder
                                $body-sink = Supplier::Preserving.new;

                                # Setup the promise the body decoder can use to drop
                                # the left-overs
                                $left-over = Promise.new;

                                # Construct the decoder and tap the body-sink
                                my $body-decoder = $body-decoder-class.new(:$body-stream, :$left-over, :%env);
                                $body-decoder.decode($body-sink.Supply);

                                # Get the existing chunks and put them into the
                                # body sink
                                $body-sink.emit: $acc;

                                # Emit the environment, its processing can begin
                                # while we continue to receive the body.
                                emit %env;

                                # Is the body decoder done already?

                                # The request finished and the pipeline is ready
                                # with another request, so begin again.
                                if $left-over.status == Kept {
                                    new-request();
                                    next CHUNK_PROCESS;
                                }

                                # The request is still going. We need more chunks.
                                else {
                                    $expect = Body;
                                    last CHUNK_PROCESS;
                                }
                            }

                            # No body expected. Emit and move on.
                            else {
                                # Emit the completed environment.
                                $body-stream.done;
                                emit %env;

                                # Setup to read the next request.
                                new-request();
                            }

                        }

                        # Lines starting with whitespace are folded. Append the
                        # value to the previous header.
                        elsif $line.starts-with(' ') {
                            debug("CONT HEADER ", $line);

                            die X::HTTP::Request::Supply::BadRequest.new(
                                reason => 'header folding encountered before any header was sent',
                            ) without $previous-header;

                            $previous-header.value ~= $line.trim-leading;
                        }

                        # We have received a new header. Save it.
                        else {
                            debug("START HEADER ", $line);

                            # Break the header line by the :
                            my ($name, $value) = $line.split(": ");

                            # Setup the name for the P6WAPI environment
                            $name = make-p6wapi-name($name);

                            # Save the value into the environment
                            if %env{ $name } :exists {

                                # Some headers can be provided more than once.
                                %env{ $name } ~= ',' ~ $value;
                            }
                            else {

                                # First occurrence of a header.
                                %env{ $name } = $value;
                            }

                            # Remember the header line for folded lines.
                            $previous-header = %env{ $name } :p;
                        }
                    }

                    # Continue to decode the body.
                    when Body {

                        # Send the chunk to the body decoder to continue
                        # decoding.
                        $body-sink.emit: $chunk;

                        # The request finished and the pipeline is ready
                        # with another request, so begin again.
                        if $left-over.status == Kept {
                            new-request();
                            next CHUNK_PROCESS;
                        }

                        # The request is still going. We need more chunks.
                        else {
                            last CHUNK_PROCESS;
                        }
                    }
                }
            }
        }
    }
}
