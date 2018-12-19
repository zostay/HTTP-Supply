use v6;

unit package HTTP::Supply;

use HTTP::Supply::Tools;

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
                            die X::HTTP::Supply::Request::BadRequest.new(
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
                    die X::HTTP::Supply::Request::BadRequest.new(
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
